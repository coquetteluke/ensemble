import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots for scheduled tasks and usage: the Scheduled screen in the window (one task's history open), a task card
/// with its full history, the editor with each trigger kind (and Bypass's warning, and a cron error), and the Usage
/// view in the window. Each in dark and light at the requested zoom. Called from `SnapshotRenderer.run`.
@MainActor
enum ScheduleSnapshots {
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        let now = Calendar.current.date(bySettingHour: 14, minute: 20, second: 0, of: Date()) ?? Date()
        let store = SessionStore(engine: PreviewEngine(seed: PreviewData.seed(now: now), delayScale: 0))
        store.seed(PreviewData.seed(now: now))
        store.background.timerEnabled = false

        let samples = ScheduleSamples.contents(now: now)
        let scheduler = TaskScheduler(storage: InMemoryScheduleStorage(samples), now: { now })
        scheduler.seed(tasks: samples.tasks, runs: samples.runs)
        let trust: [UUID: NewSessionTrustLine] = [
            ScheduleSamples.depsID: NewSessionTrustLine(text: "Not trusted. Gemini only starts in folders you trust.", tone: .blocked,
                                                        offersTrust: true),
        ]

        let tracker = UsageTracker(storage: InMemoryUsageStorage(), now: { now })
        tracker.attach(to: store, sampling: false)
        tracker.seed(UsageSamples.ledger(now: now), caps: UsageSamples.caps)
        tracker.setBilling(UsageSamples.billing)

        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = false

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            window.route = .scheduled
            written += save("scheduled-window-\(tone)", to: directory, width: 1440, height: 900, zoom: zoom, scheme: scheme) {
                WindowFrame(store: store, window: window, title: "Scheduled") {
                    ScheduledView(store: store, window: window, scheduler: scheduler, now: now,
                                  initiallyExpanded: [ScheduleSamples.triageID], trustLines: trust)
                }
            }
            written += save("scheduled-history-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                if let task = scheduler.task(ScheduleSamples.triageID) {
                    ScheduleTaskCard(store: store, scheduler: scheduler, task: task, now: now, trustLine: nil,
                                     expanded: .constant(true), onEdit: {}, onDelete: {}, onOpenSession: { _ in })
                        .padding(24)
                }
            }
            for (name, task, confirmed, line) in editorCases(samples: samples, now: now) {
                written += save("schedule-editor-\(name)-\(tone)", to: directory, width: 580, zoom: zoom, scheme: scheme) {
                    ScheduleEditorSheet(store: store, request: ScheduleEditorRequest(task: task, isNew: name == "daily"), now: now,
                                        trustLineOverride: .some(line), bypassConfirmed: confirmed) { _ in }
                }
            }
            // No sidebar row is selected for Usage (the room route without a room highlights none).
            window.route = .room
            written += save("usage-window-\(tone)", to: directory, width: 1440, height: 900, zoom: zoom, scheme: scheme) {
                WindowFrame(store: store, window: window, title: "Usage") {
                    UsageScreen(store: store, tracker: tracker, planLimits: UsageSamples.planLimits(now: now))
                }
            }
            written += save("usage-full-\(tone)", to: directory, width: 900, zoom: zoom, scheme: scheme) {
                UsageScreen(store: store, tracker: tracker, planLimits: UsageSamples.planLimits(now: now), initialRange: .month,
                            showAllSessions: true)
            }
        }
        return written
    }

    /// The editor once per trigger kind: a new daily task, an hourly one, weekdays in Bypass (warning shown), weekly with
    /// an untrusted Gemini folder, a custom cron, and a cron that does not parse.
    static func editorCases(samples: ScheduleFileContents, now: Date)
        -> [(String, ScheduledTask, Bool, NewSessionTrustLine?)] {
        let base = samples.tasks.first { $0.id == ScheduleSamples.triageID } ?? samples.tasks[0]
        var daily = base
        daily.name = ""
        daily.prompt = ""
        daily.trigger = .daily(hour: 9, minute: 0)
        var hourly = base
        hourly.name = "Inbox sweep"
        hourly.prompt = "Check new pull request comments and reply to the ones that are only questions."
        hourly.trigger = .hourly(minute: 15)
        hourly.permissionMode = .acceptEdits
        var weekdays = base
        weekdays.trigger = .weekdays(hour: 8, minute: 30)
        weekdays.permissionMode = .bypass
        var weekly = samples.tasks.first { $0.id == ScheduleSamples.depsID } ?? base
        weekly.paused = false
        var custom = samples.tasks.first { $0.id == ScheduleSamples.nightlyID } ?? base
        custom.trigger = .custom(cron: "0 3 * * 1-5")
        var broken = custom
        broken.trigger = .custom(cron: "0 3 * *")
        let untrusted = NewSessionTrustLine(text: "Not trusted. Gemini only starts in folders you trust.", tone: .blocked, offersTrust: true)
        let trusted = NewSessionTrustLine(text: "Trusted. Agents load this folder's own settings.", tone: .trusted, offersTrust: false)
        return [
            ("daily", daily, false, trusted),
            ("hourly", hourly, false, trusted),
            ("weekdays-bypass", weekdays, false, trusted),
            ("weekly", weekly, false, untrusted),
            ("custom", custom, false, trusted),
            ("custom-error", broken, false, trusted),
        ]
    }

    /// The window around a screen: sidebar, the title row, the screen, and drawn traffic lights.
    private struct WindowFrame<Content: View>: View {
        let store: SessionStore
        let window: WindowState
        let title: String
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            HStack(spacing: 0) {
                SidebarView(store: store, window: window, rooms: nil)
                    .frame(width: theme.z(MainView.sidebarWidth))
                VLine()
                VStack(spacing: 0) {
                    HStack {
                        Text(title)
                            .font(theme.font(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                    .padding(.leading, theme.z(20))
                    .frame(height: 52)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .background(theme.background)
            }
            .background(theme.background)
            .overlay(alignment: .topLeading) { SnapshotWindowChrome(window: window) }
        }
    }

    /// Windows keep 1440 by 900 and zoom their content; single views grow with the zoom.
    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, height: CGFloat? = nil, zoom: CGFloat,
                                      scheme: ColorScheme, @ViewBuilder _ view: () -> V) -> [String] {
        let isWindow = height != nil
        let renderWidth = isWindow ? width : width * zoom
        let content = Canvas(width: renderWidth, height: height) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: renderWidth, height: height)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }

    private struct Canvas<Content: View>: View {
        let width: CGFloat
        let height: CGFloat?
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, height: height, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: height == nil)
                .background(theme.background)
        }
    }
}
