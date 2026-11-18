import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots for background work and plan limits: the Background popover under its toolbar button (subagents, shells,
/// a room's work and scheduled runs), the context panel's Background section, the plan limit ring at 0%, 60%, 95% and
/// used up, and the limit card in its states. Each in dark and light at the requested zoom. Called from
/// `SnapshotRenderer.run`.
@MainActor
enum BackgroundSnapshots {
    static let roomSessionID = "ses_design_room_opus"
    static let roomSubagentID = "ses_design_room_survey"
    static let limitErrorID = "error_plan_limit"

    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        let now = Date()
        let store = makeStore(now: now)
        let window = WindowState()
        guard let main = store.session(PreviewData.mainSessionID) else { return [] }
        let roomTitles = [roomSessionID: "Design review"]

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            written += save("background-popover-\(suffix)", to: directory, width: 440, zoom: zoom, scheme: scheme) {
                PopoverSnapshot(store: store, window: window, roomTitles: roomTitles, now: now)
            }
            written += save("background-context-panel-\(suffix)", to: directory, width: MainView.panelWidth, zoom: zoom, scheme: scheme) {
                ContextPanelView(store: store, session: main, remoteControl: .constant(true), topInset: 15, backgroundNow: now)
                    .frame(height: 760 * zoom, alignment: .top)
                    .clipped()
            }
            written += save("plan-ring-\(suffix)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                RingSnapshot(store: store, session: main, window: window, now: now)
            }
            written += save("limit-card-\(suffix)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                LimitCardSnapshot(store: store, now: now)
            }
        }
        return written
    }

    /// The sample data plus: the main session's subagent working, a room agent's session with a working subagent,
    /// three background tasks, and a plan limit stop on a session's last error row.
    static func makeStore(now: Date) -> SessionStore {
        var seed = PreviewData.seed()
        let directory = seed.sessions.first { $0.id == PreviewData.mainSessionID }?.directory ?? "/tmp"
        seed.sessions.append(EngineSession(id: roomSessionID, title: "Opus: settings screen review", directory: directory,
                                           created: now.addingTimeInterval(-900), updated: now.addingTimeInterval(-60)))
        seed.sessions.append(EngineSession(id: roomSubagentID, parentID: roomSessionID, title: "Survey every settings screen",
                                           directory: directory, agent: "Explore", created: now.addingTimeInterval(-200)))
        seed.sessionAgentIDs[roomSessionID] = [PreviewData.opusAgentID]
        seed.activities[PreviewData.childSessionID] = .working
        seed.activities[roomSubagentID] = .working
        seed.permissions.removeAll { $0.sessionID == PreviewData.childSessionID }
        seed.transcripts["ses_rate_limit", default: []] += [
            .user(id: "u_limit", text: "Run the rate limiter tests again and fix the flaky one", date: now.addingTimeInterval(-600)),
            .agentText(id: "a_limit", text: "Running the suite with the race detector on.", agentID: nil, streaming: false),
            .error(id: limitErrorID, message: "Your Claude plan's usage limit is reached. (You've hit your 5-hour limit \u{00B7} resets 4pm)"),
        ]
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0))
        store.seed(seed)
        store.seedBackgroundTasks([
            BackgroundTask(id: "bash_dev", sessionID: PreviewData.mainSessionID, kind: .shell, title: "npm run dev -- --port 5173",
                           started: now.addingTimeInterval(-754)),
            BackgroundTask(id: "bash_watch", sessionID: "ses_sse_reconnect", kind: .shell,
                           title: "swift test --parallel --filter EventStreamTests", started: now.addingTimeInterval(-95)),
            BackgroundTask(id: "wf_review", sessionID: roomSessionID, kind: .task, title: "Review workflow, 3 of 4 agents",
                           started: now.addingTimeInterval(-310)),
        ])
        store.seedUsageLimitStop(UsageLimitStop(id: limitErrorID, sessionID: "ses_rate_limit", resetsAt: resetDate(now),
                                                window: "five_hour", message: "You've hit your 5-hour limit \u{00B7} resets 4pm"))
        return store
    }

    /// A reset two hours away, on the hour.
    static func resetDate(_ now: Date) -> Date {
        let later = now.addingTimeInterval(2 * 3600)
        return Calendar.current.dateInterval(of: .hour, for: later)?.start ?? later
    }

    /// The toolbar's right-hand buttons with the Background popover open under them.
    private struct PopoverSnapshot: View {
        let store: SessionStore
        let window: WindowState
        let roomTitles: [String: String]
        let now: Date
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    BackgroundToolbarButton(store: store, window: window)
                    IconButton("plus.forwardslash.minus", help: "Changes") {}
                    IconButton("sidebar.right", help: "Context panel") {}
                }
                BackgroundListView(store: store, roomTitles: roomTitles, now: now) { _ in }
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The status line with the plan ring at 0%, 60%, 95% and used up, each with its tooltip text underneath.
    private struct RingSnapshot: View {
        let store: SessionStore
        let session: SessionModel
        let window: WindowState
        let now: Date
        @Environment(\.theme) private var theme

        var body: some View {
            let reset5h = now.addingTimeInterval(2 * 3600 + 17 * 60)
            let resetWeek = now.addingTimeInterval(3 * 24 * 3600 + 5 * 3600)
            let meters: [(String, PlanLimitMeter)] = [
                ("0%", PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0, resetsAt: reset5h),
                                                .init(name: "seven_day", utilization: 0, resetsAt: resetWeek)])),
                ("60%", PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0.6, resetsAt: reset5h),
                                                 .init(name: "seven_day", utilization: 0.31, resetsAt: resetWeek)])),
                ("95%", PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0.42, resetsAt: reset5h),
                                                 .init(name: "seven_day", utilization: 0.95, resetsAt: resetWeek)])),
                ("Used up", PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 1, resetsAt: reset5h, status: "rejected"),
                                                     .init(name: "seven_day", utilization: 0.64, resetsAt: resetWeek)],
                                           isLimited: true)),
            ]
            VStack(alignment: .leading, spacing: 14) {
                ForEach(meters, id: \.0) { name, meter in
                    VStack(alignment: .leading, spacing: 4) {
                        StatusLine(store: store, session: session, window: window, planMeter: meter)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.panel))
                        Text("\(name): \(PlanLimitStatusItem.tooltip(meter, now: now).replacingOccurrences(of: "\n", with: "  |  "))")
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.leading, 10)
                    }
                }
            }
            .padding(24)
        }
    }

    /// The limit card in the transcript (from the store, switch on), then switched off, sent, after a newer turn, and
    /// with no reset time.
    private struct LimitCardSnapshot: View {
        let store: SessionStore
        let now: Date
        @Environment(\.theme) private var theme

        var body: some View {
            let reset = BackgroundSnapshots.resetDate(now)
            let base = UsageLimitStop(id: "card", sessionID: "s", resetsAt: reset, window: "five_hour", message: "")
            var off = base
            off.autoContinue = false
            var sent = base
            sent.resetsAt = now.addingTimeInterval(-3 * 60)
            sent.window = "seven_day"
            sent.state = .sent
            sent.sentAt = now.addingTimeInterval(-2 * 60)
            var superseded = base
            superseded.state = .superseded
            let unknown = UsageLimitStop(id: "unknown", sessionID: "s", resetsAt: nil, message: "")
            return VStack(alignment: .leading, spacing: 16) {
                if let session = store.session("ses_rate_limit") {
                    TranscriptList(items: Array(session.items.suffix(3)), resolutions: session.resolutions, agents: store.agents)
                        .environment(\.interactionStore, store)
                }
                caption("Switched off")
                UsageLimitCard(stop: off, now: now)
                caption("After the reset")
                UsageLimitCard(stop: sent, now: now)
                caption("A newer turn started")
                UsageLimitCard(stop: superseded, now: now)
                caption("Reset time not reported")
                UsageLimitCard(stop: unknown, now: now)
            }
            .padding(24)
        }

        private func caption(_ text: String) -> some View {
            Text(text)
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, -10)
        }
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let content = Canvas(width: width * zoom) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width * zoom, height: nil)
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
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.background)
        }
    }
}
