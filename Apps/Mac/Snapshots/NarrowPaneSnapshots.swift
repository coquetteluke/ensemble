import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots for narrow split panes, in dark and light at the requested zoom:
/// - two, three and four sessions side by side, with the sidebar and the context panel and without either;
/// - the composer and the status line at widths from 760 down to 190 pt (before zoom), one per row level;
/// - every card above the composer and in the transcript in a 320 pt pane: permission, plan, question, plan limit,
///   trust and the pull request bar in each state.
/// Also checks the narrowest pane the composer fits and that every visible pane counts as on screen for alerts.
/// Called from `SnapshotRenderer.run`. Nothing here runs git or gh.
@MainActor
enum NarrowPaneSnapshots {
    /// The pane width the cards are drawn in, before zoom.
    static let paneWidth: CGFloat = 320
    /// Widths for the composer ladder, before zoom.
    static let ladder: [CGFloat] = [760, 600, 520, 460, 420, 380, 340, 320, 300, 260, 220, 190]
    static let freshID = "ses_narrow_fresh"

    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(directory.path): \(error.localizedDescription)")
            return []
        }
        let now = Date()
        let seed = seed(now: now)
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0))
        store.seed(seed)
        let ensemble = NSHomeDirectory() + "/Ensemble"
        store.worktrees.seedPreview(
            availability: [ensemble: ""],
            currentBranch: [PreviewData.mainSessionID: "main", "ses_sse_reconnect": "fix/sse-reconnect-after-sleep",
                            "ses_ring_plan": "ensemble/usage-ring-next-to-the-composer", "ses_icons": "main", freshID: "main",
                            "ses_db_debate": "main", "ses_lint": "main"])
        // Effort and fast mode chips, as the app shows them, and two messages queued in the working session.
        for session in store.sessions {
            guard let model = session.info.model else { continue }
            Task { @MainActor in await store.loadModelOptions(for: model) }
        }
        Task { @MainActor in
            await store.send("Also add a test for the empty state", to: PreviewData.mainSessionID)
            await store.send("Then update the README screenshot", to: PreviewData.mainSessionID)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        var written: [String] = []
        func save<V: View>(_ name: String, width: CGFloat, height: CGFloat?, scheme: ColorScheme, @ViewBuilder _ view: () -> V) {
            let content = view()
                .frame(width: width, height: height, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: height == nil)
                .modifier(NarrowBackground())
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(\.interactionStore, store)
                .environment(AttentionCenter(marks: SessionAttentionMarks(fileURL: nil), canStart: false))
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = directory.appendingPathComponent(name + suffix + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        // Split windows: with the sidebar and the context panel, and with neither.
        let layouts: [(name: String, sessions: [String], focused: Int)] = [
            ("2", [PreviewData.mainSessionID, "ses_icons"], 1),
            ("3", [PreviewData.mainSessionID, "ses_ring_plan", "ses_icons"], 0),
            ("4", [PreviewData.mainSessionID, "ses_ring_plan", "ses_icons", freshID], 2),
        ]
        for layout in layouts {
            for (chrome, panels) in [("panels", true), ("bare", false)] {
                let window = WindowState()
                window.showSidebar = panels
                window.showContextPanel = panels
                window.showSplitForSnapshot(layout.sessions, focused: layout.focused, store: store)
                for scheme in [ColorScheme.dark, .light] {
                    save("narrow-split-\(layout.name)-\(chrome)-\(tone(scheme))", width: 1440, height: 900, scheme: scheme) {
                        MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
                    }
                }
            }
        }
        store.select(PreviewData.mainSessionID)

        // The composer and status line at each width, and every card in a 320 pt pane.
        let meter = PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0.6, resetsAt: now.addingTimeInterval(8200)),
                                             .init(name: "seven_day", utilization: 0.31, resetsAt: now.addingTimeInterval(277_000))])
        let window = WindowState()
        for scheme in [ColorScheme.dark, .light] {
            save("narrow-composer-ladder-\(tone(scheme))", width: 800 * zoom, height: nil, scheme: scheme) {
                ComposerLadder(store: store, window: window, meter: meter, widths: ladder)
            }
            save("narrow-cards-\(tone(scheme))", width: paneWidth * zoom, height: nil, scheme: scheme) {
                CardsColumn(store: store, window: window, now: now)
            }
            save("narrow-trust-cards-\(tone(scheme))", width: paneWidth * zoom, height: nil, scheme: scheme) {
                CaptionedColumn(items: TrustSnapshots.cases().map { item in
                    (item.title, AnyView(TrustCardView(prompt: item.prompt, error: item.error, onTrust: {}, onDismiss: {})))
                }, docked: true)
            }
            save("narrow-pull-request-bar-\(tone(scheme))", width: paneWidth * zoom, height: nil, scheme: scheme) {
                CaptionedColumn(items: GitHubSnapshots.cases().map { item in
                    (item.title, AnyView(PullRequestBar(controller: item.controller)))
                }, docked: true)
            }
        }

        if zoom == 1 {
            checkFit(store: store)
            checkAlerts(store: store)
        }
        print("Rendered \(written.count) narrow pane snapshots:")
        for path in written { print(path) }
        return written
    }

    private static func tone(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    /// The Hub's sample sessions (a plan and a question waiting) plus a new session in a git repository, which shows
    /// the "Work in a copy" switch.
    static func seed(now: Date) -> StoreSeed {
        var seed = HubSplitSnapshots.seed(now: now)
        seed.sessions.append(EngineSession(id: freshID, title: "Tidy the snapshot scripts", directory: NSHomeDirectory() + "/Ensemble",
                                           model: ModelRef(providerID: "anthropic", id: "claude-opus-5-5"),
                                           created: now.addingTimeInterval(-60), updated: now.addingTimeInterval(-60)))
        seed.transcripts[freshID] = []
        return seed
    }

    // MARK: Checks

    /// The narrowest conversation (before zoom) whose composer and status line fit without being cut, found by drawing
    /// it at each width: the main sample session (effort and fast mode chips, a permission waiting) and a new session
    /// with the "Work in a copy" switch. Also where the row is still one line.
    private static func checkFit(store: SessionStore) {
        func fits(_ session: SessionModel, width: CGFloat) -> (fits: Bool, height: CGFloat) {
            let probe = ConversationView(store: store, session: session, window: WindowState())
                .ensembleTheme()
                .environment(\.isSnapshot, true)
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: probe)
            renderer.proposedSize = ProposedViewSize(width: width, height: 2000)
            guard let image = renderer.cgImage else { return (false, 0) }
            return (CGFloat(image.width) / renderer.scale <= width + 0.5, CGFloat(image.height) / renderer.scale)
        }
        var parts: [String] = []
        for id in [PreviewData.mainSessionID, freshID] {
            guard let session = store.session(id) else { continue }
            var low: CGFloat = 120
            var high: CGFloat = 800
            while high - low > 2 {
                let mid = ((low + high) / 2).rounded()
                if fits(session, width: mid).fits { high = mid } else { low = mid }
            }
            parts.append("\(session.title) from \(Int(high)) pt")
        }
        // The row is on two lines once the composer and status line grow taller than at full width.
        func bottomHeight(_ session: SessionModel, width: CGFloat) -> CGFloat {
            // A short draft, so the placeholder's wrapping does not count.
            let renderer = ImageRenderer(content: PaneBottom(store: store, session: session, window: WindowState(), draft: "Go")
                .frame(width: width)
                .ensembleTheme()
                .environment(\.isSnapshot, true)
                .environment(SnapshotRenderer.power))
            return renderer.cgImage.map { CGFloat($0.height) / renderer.scale } ?? 0
        }
        // A session without queued messages, whose strip has its own narrow layout.
        let oneLine = store.session(NarrowPaneSnapshots.freshID).map { session in
            let wide = bottomHeight(session, width: 760)
            return ladder.filter { bottomHeight(session, width: $0) <= wide + 1 }.min() ?? 0
        } ?? 0
        print("Narrow pane check: the composer and status line fit at 100% for " + parts.joined(separator: ", ")
              + "; the row stays on one line down to \(Int(oneLine)) pt")
    }

    /// Every split pane on screen counts as seen; nothing does while Ensemble is in the background or its window is hidden.
    private static func checkAlerts(store: SessionStore) {
        let window = WindowState()
        window.showSplitForSnapshot([PreviewData.mainSessionID, "ses_icons", PreviewData.childSessionID], focused: 0, store: store)
        let all = AttentionCenter.visibleSessions(store: store, window: window, appActive: true, windowShown: true)
        let everyPane = all == [PreviewData.mainSessionID, "ses_icons"]
        let background = AttentionCenter.visibleSessions(store: store, window: window, appActive: false, windowShown: true).isEmpty
        let hidden = AttentionCenter.visibleSessions(store: store, window: window, appActive: true, windowShown: false).isEmpty
        window.route = .hub
        let otherScreen = AttentionCenter.visibleSessions(store: store, window: window, appActive: true, windowShown: true).isEmpty
        let single = WindowState()
        store.select("ses_icons")
        let one = AttentionCenter.visibleSessions(store: store, window: single, appActive: true, windowShown: true) == ["ses_icons"]
        store.select(PreviewData.mainSessionID)
        print("Alert check: every visible pane on screen \(everyPane), a subagent pane counts as its parent \(everyPane), "
              + "none in the background \(background), none with the window hidden \(hidden), none on another screen \(otherScreen), "
              + "one session without a split \(one)")
    }
}

/// The window background behind a snapshot.
private struct NarrowBackground: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View { content.background(theme.background) }
}

/// The bottom of a conversation (composer and status line) at each width, under a caption with the width. The first
/// session shows the effort and fast mode chips, the second (new, in a git repository) the "Work in a copy" switch.
private struct ComposerLadder: View {
    let store: SessionStore
    let window: WindowState
    let meter: PlanLimitMeter
    let widths: [CGFloat]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(18)) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                let session = store.session(index % 2 == 0 ? PreviewData.mainSessionID : NarrowPaneSnapshots.freshID)
                VStack(alignment: .leading, spacing: theme.z(4)) {
                    Text("\(Int(width)) pt")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    if let session {
                        PaneBottom(store: store, session: session, window: window, meter: meter)
                            .frame(width: theme.z(width))
                            .background(RoundedRectangle(cornerRadius: theme.z(6)).strokeBorder(theme.border.opacity(0.6)))
                            .clipped()
                    }
                }
            }
        }
        .padding(theme.z(16))
    }
}

/// A pane's composer and status line, with the pane's side padding.
private struct PaneBottom: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    var meter: PlanLimitMeter?
    var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ComposerView(store: store, session: session, window: window, snapshotDraft: draft)
            StatusLine(store: store, session: session, window: window, planMeter: meter)
        }
        .modifier(AdaptiveInsetModifier(wide: 20, narrow: 10, maxContentWidth: ConversationView.columnWidth + 24))
        .padding(.vertical, 8)
    }
}

/// Transcript cards with the pane's transcript padding, then the cards docked above the composer.
private struct CardsColumn: View {
    let store: SessionStore
    let window: WindowState
    let now: Date
    @Environment(\.theme) private var theme

    var body: some View {
        let main = store.session(PreviewData.mainSessionID)
        let permission = main?.pendingPermissions.first
            ?? PermissionRequest(id: "p", sessionID: PreviewData.mainSessionID, kind: "bash", title: "swift test --parallel",
                                 alwaysPatterns: ["swift test *"])
        let edit = PermissionRequest(id: "p_edit", sessionID: PreviewData.mainSessionID, kind: "edit",
                                     title: "src/components/ThemeToggle.tsx",
                                     detail: "Create a toggle that stores the choice in localStorage.")
        let plan = store.session("ses_ring_plan")?.items.compactMap { item -> PermissionRequest? in
            if case .permission(let request) = item, request.isPlan { return request }
            return nil
        }.first
        let twoModes = plan.map { request in
            var copy = request
            copy.plan = PlanProposal(markdown: PlanQuestionSnapshots.plan, proceedMode: .acceptEdits)
            return copy
        }
        let reset = BackgroundSnapshots.resetDate(now)
        let waiting = UsageLimitStop(id: "card", sessionID: "s", resetsAt: reset, window: "five_hour", message: "")
        var sent = waiting
        sent.state = .sent
        sent.sentAt = now.addingTimeInterval(-120)
        let question = store.session("ses_icons").flatMap { store.openQuestion(in: $0.id) }

        return VStack(alignment: .leading, spacing: 0) {
            CaptionedColumn(items: [
                ("Permission, command", AnyView(PermissionCardView(request: permission)
                    .environment(\.transcriptActions, TranscriptActions(shortcutPermissionID: permission.id)))),
                ("Permission, edit", AnyView(PermissionCardView(request: edit))),
                ("Plan", AnyView(Group { if let twoModes { PlanCardView(request: twoModes) } })),
                ("Plan limit reached", AnyView(UsageLimitCard(stop: waiting, now: now))),
                ("Plan limit, sent", AnyView(UsageLimitCard(stop: sent, now: now))),
            ], docked: false)
            CaptionedColumn(items: [
                ("Question, docked", AnyView(Group {
                    if let question {
                        QuestionCardView(request: question, onAnswer: { _ in }, onDecline: {})
                    }
                })),
                ("Question, two steps", AnyView(Group {
                    if let question {
                        QuestionCardView(request: twoStep(question), step: 1, selections: [:], others: [:],
                                         onAnswer: { _ in }, onDecline: {})
                    }
                })),
            ], docked: true)
        }
    }

    private func twoStep(_ question: PermissionRequest) -> PermissionRequest {
        var copy = question
        copy.questions = (question.questions ?? []) + [
            AgentQuestion(id: "Which states should change the ring's colour?", header: "Colours",
                          text: "Which states should change the ring's colour?",
                          options: [.init(label: "Over 80% used"), .init(label: "Limit reached")],
                          multiSelect: true, allowsOther: true),
        ]
        return copy
    }
}

/// Views under small captions, with a pane's transcript padding or, when `docked`, the composer column's.
private struct CaptionedColumn: View {
    let items: [(String, AnyView)]
    let docked: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(14)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: theme.z(5)) {
                    Text(item.0)
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    item.1
                }
            }
        }
        .padding(.vertical, theme.z(14))
        .modifier(AdaptiveInsetModifier(wide: docked ? 20 : 32, narrow: docked ? 10 : 16))
    }
}
