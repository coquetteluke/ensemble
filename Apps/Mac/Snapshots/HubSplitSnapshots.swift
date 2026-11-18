import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots for the Session Hub and split view, each in dark and light at the requested zoom:
/// - the Hub in the window (1440 x 900) and the whole board, with every bucket, quick actions on a short command, a
///   plan, a question and room decisions, an inline reply open and a card selected from the keyboard;
/// - two, three and four sessions side by side in the window.
/// Also checks the split layout and the pane states (`checkSplit`). Called from `SnapshotRenderer.run`. Uses its own
/// marks in memory and never saves a layout.
@MainActor
enum HubSplitSnapshots {
    static let planID = "hub_plan"
    static let questionID = "hub_question"
    static let replySessionID = "ses_lint"

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
        let store = SessionStore(engine: PreviewEngine(seed: seed(now: now), delayScale: 0))
        store.seed(seed(now: now))
        let marks = SessionAttentionMarks(fileURL: nil)
        marks.replace(unread: ["ses_readme"], completed: ["ses_old_done": now.addingTimeInterval(-86_400)])
        let center = AttentionCenter(marks: marks, canStart: false)
        let rooms = RoomSeed().controller
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        var written: [String] = []

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme,
                           grows: Bool, options: HubSnapshotOptions? = nil, @ViewBuilder _ view: () -> V) {
            let width = grows ? baseWidth * zoom : baseWidth
            let height = grows ? baseHeight.map { $0 * zoom } : baseHeight
            let content = view()
                .frame(width: width, height: height, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: height == nil)
                .modifier(SnapshotBackground())
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(\.hubSnapshotOptions, options)
                .environment(center)
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            if let path = write(image, to: directory.appendingPathComponent(name + suffix + ".png")) { written.append(path) }
        }

        // The Hub: a card selected from the keyboard and the reply box open on another.
        let hubWindow = WindowState()
        hubWindow.showSidebar = true
        hubWindow.showContextPanel = true
        hubWindow.route = .hub
        hubWindow.drafts[replySessionID] = "Yes, turn them on and fix whatever breaks"
        hubWindow.openHubReply(replySessionID)
        let options = HubSnapshotOptions(now: now, selection: PreviewData.mainSessionID)
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            save("hub-window-\(tone)", width: 1440, height: 900, scheme: scheme, grows: false, options: options) {
                MainView(store: store, window: hubWindow, rooms: rooms, remoteControlOverride: true, zoomOverride: zoom)
            }
            save("hub-board-\(tone)", width: 1000, height: nil, scheme: scheme, grows: true, options: options) {
                HubView(store: store, window: hubWindow, rooms: rooms)
            }
        }

        // Two to four sessions side by side, with each model's effort and fast mode chips as the app shows them.
        for id in [PreviewData.mainSessionID, "ses_sse_reconnect", "ses_dark_mode", "ses_db_debate"] {
            guard let model = store.session(id)?.info.model else { continue }
            Task { @MainActor in await store.loadModelOptions(for: model) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let layouts: [(name: String, sessions: [String], focused: Int, sidebar: Bool, panel: Bool)] = [
            ("split-2", [PreviewData.mainSessionID, "ses_sse_reconnect"], 0, true, true),
            ("split-3", [PreviewData.mainSessionID, "ses_sse_reconnect", "ses_dark_mode"], 1, true, false),
            ("split-4", [PreviewData.mainSessionID, "ses_sse_reconnect", "ses_dark_mode", "ses_db_debate"], 2, false, false),
        ]
        for layout in layouts {
            let window = WindowState()
            window.showSidebar = layout.sidebar
            window.showContextPanel = layout.panel
            window.showSplitForSnapshot(layout.sessions, focused: layout.focused, store: store)
            for scheme in [ColorScheme.dark, .light] {
                let tone = scheme == .dark ? "dark" : "light"
                save("\(layout.name)-\(tone)", width: 1440, height: 900, scheme: scheme, grows: false) {
                    MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
                }
            }
        }
        store.select(PreviewData.mainSessionID)

        if zoom == 1 { checkSplit() }
        print("Rendered \(written.count) hub and split snapshots:")
        for path in written { print(path) }
        return written
    }

    /// The sample sessions plus one for every Hub state the preview data lacks: a plan, a question, a closing question,
    /// old, completed and archived sessions.
    static func seed(now: Date) -> StoreSeed {
        var seed = PreviewData.seed(now: now)
        let home = NSHomeDirectory()
        let ensemble = home + "/Ensemble"
        let site = home + "/Developer/portfolio-site"
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let opus = ModelRef(providerID: "anthropic", id: "claude-opus-5-5")
        let sonnet = ModelRef(providerID: "anthropic", id: "claude-sonnet-5")
        let gpt = ModelRef(providerID: "openai", id: "gpt-5.5")

        seed.sessions += [
            EngineSession(id: "ses_ring_plan", title: "Usage ring next to the composer", directory: ensemble, model: opus,
                          created: ago(3600), updated: ago(240)),
            EngineSession(id: "ses_icons", title: "Pick the toolbar icons", directory: ensemble, model: sonnet,
                          created: ago(5400), updated: ago(900)),
            EngineSession(id: replySessionID, title: "Fix the SwiftLint warnings", directory: ensemble, model: gpt,
                          created: ago(7200), updated: ago(1500)),
            EngineSession(id: "ses_old_cleanup", title: "Remove the old preview code", directory: ensemble, model: sonnet,
                          created: ago(86_400 * 10), updated: ago(86_400 * 9)),
            EngineSession(id: "ses_old_done", title: "Update the app icon sizes", directory: ensemble, model: sonnet,
                          created: ago(86_400 * 2), updated: ago(86_400 * 2)),
            EngineSession(id: "ses_archived", title: "Try a Tauri prototype", directory: site, model: gpt,
                          created: ago(86_400 * 20), updated: ago(86_400 * 18), archived: true),
        ]
        let plan = PermissionRequest(
            id: planID, sessionID: "ses_ring_plan", kind: InteractionKind.plan, title: "Add a usage ring next to the composer",
            created: ago(240),
            plan: PlanProposal(markdown: PlanQuestionSnapshots.plan, proceedMode: .acceptEdits))
        let question = PermissionRequest(
            id: questionID, sessionID: "ses_icons", kind: InteractionKind.question, title: "Which icon set should the toolbar use?",
            created: ago(900),
            questions: [AgentQuestion(id: "Which icon set should the toolbar use?", header: "Icons",
                                      text: "Which icon set should the toolbar use?",
                                      options: [.init(label: "SF Symbols", detail: "Match the rest of macOS"),
                                                .init(label: "Lucide", detail: "Thinner lines, closer to the web app"),
                                                .init(label: "Draw our own")],
                                      multiSelect: false, allowsOther: true)])
        seed.permissions += [plan, question]
        seed.activities["ses_ring_plan"] = .waitingForPermission
        seed.activities["ses_icons"] = .waitingForPermission
        seed.modes["ses_ring_plan"] = .plan
        seed.transcripts["ses_ring_plan"] = [
            .user(id: "rp_u", text: "Plan a usage ring for the composer before touching anything", date: ago(600)),
            .agentText(id: "rp_a", text: "I read the composer and the plan-limits code. Here is the plan.", agentID: nil, streaming: false),
            .permission(plan),
        ]
        seed.transcripts["ses_icons"] = [
            .user(id: "ic_u", text: "The toolbar icons look mismatched. Pick one set.", date: ago(1200)),
            .permission(question),
        ]
        seed.transcripts[replySessionID] = [
            .user(id: "ln_u", text: "Fix the SwiftLint warnings in the Mac app", date: ago(2400)),
            .tool(ToolCallInfo(id: "ln_t", name: "bash", title: "swiftlint --quiet Apps/Mac", status: .succeeded)),
            .agentText(id: "ln_a", text: "Fixed all 23 warnings: unused closures, long lines and two force casts.\n\nWant me to turn on the strict rules too?",
                       agentID: nil, streaming: false),
        ]
        seed.transcripts["ses_old_cleanup"] = [
            .agentText(id: "oc_a", text: "Removed the old preview views and their assets.", agentID: nil, streaming: false),
        ]
        seed.transcripts["ses_old_done"] = [
            .agentText(id: "od_a", text: "Regenerated the icon at every size from the 1024 master.", agentID: nil, streaming: false),
        ]
        return seed
    }

    private static func write(_ image: CGImage, to url: URL) -> String? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }
}

/// The window background behind a snapshot.
private struct SnapshotBackground: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View { content.background(theme.background) }
}

// MARK: - Checks

/// The split layout and the pane states behave as the split view needs, printed like the other snapshot checks.
@MainActor
private func checkSplit() {
    var layout = SplitLayout()
    layout.start("a", beside: "b")
    let starts = layout.isActive && layout.focused?.sessionID == "b" && layout.fractions == [0.5, 0.5]
    layout.insert("c", after: layout.panes[0].id)
    layout.insert("d", after: nil)
    let fourMax = layout.panes.map(\.sessionID) == ["a", "c", "b", "d"] && layout.isFull && layout.insert("e", after: nil) == nil
        && abs(layout.fractions.reduce(0, +) - 1) < 0.0001
    layout.equalize()
    let start = layout.fractions
    layout.resize(divider: 0, from: start, by: -0.5, minFraction: 0.2)
    let clamps = abs(layout.fractions[0] - 0.2) < 0.0001 && abs(layout.fractions[0] + layout.fractions[1] - 0.5) < 0.0001
    layout.focus(layout.panes[1].id)
    layout.remove(layout.panes[1].id)
    let focusMovesLeft = layout.focused?.sessionID == "a" && layout.panes.count == 3
    layout.remove(layout.panes[2].id)
    let remaining = layout.remove(layout.panes[1].id)
    let endsWithOne = !layout.isActive && remaining == "a" && layout.panes.isEmpty
    var pruned = SplitLayout()
    pruned.start("a", beside: "gone")
    pruned.insert("a", after: nil)
    let left = pruned.keepPanes { $0 != "gone" }
    let pruneEnds = left == "a" && !pruned.isActive
    let saved = (try? JSONEncoder().encode({ var l = SplitLayout(); l.start("x", beside: "y"); return l }()))
        .flatMap { try? JSONDecoder().decode(SplitLayout.self, from: $0) }
    let roundTrip = saved?.isWellFormed == true && saved?.panes.map(\.sessionID) == ["x", "y"]

    // Pane states: drafts are shared, composer focus is per pane, Send uses the pane's own session.
    let store = SessionStore(engine: PreviewEngine(delayScale: 0))
    store.seed(PreviewData.seed())
    let window = WindowState()
    window.openBeside("ses_readme", store: store)
    let begins = window.split.isActive && store.selectedSessionID == "ses_readme"
        && window.split.panes.first?.sessionID == PreviewData.mainSessionID
    guard let firstPane = window.split.panes.first, let secondPane = window.split.panes.last else {
        print("Split check: split did not start")
        return
    }
    let first = window.paneState(firstPane.id)
    let second = window.paneState(secondPane.id)
    first.drafts[PreviewData.mainSessionID] = "From the left pane"
    let sharedDrafts = window.drafts[PreviewData.mainSessionID] == "From the left pane"
    let before = (first.composerFocusToken, second.composerFocusToken)
    window.composerFocusToken &+= 1
    let focusGoesToFocused = first.composerFocusToken == before.0 && second.composerFocusToken == before.1 + 1
    first.requestedMenu = .model
    let menusPerPane = second.requestedMenu == nil && window.requestedMenu == nil
    first.requestedMenu = nil
    // The left pane is focused (so selected); the right pane's composer still sends to its own session.
    window.focusPane(firstPane.id, store: store)
    let focusSelects = store.selectedSessionID == PreviewData.mainSessionID
    let itemsBefore = store.session("ses_readme")?.items.count ?? 0
    second.drafts["ses_readme"] = "From the right pane"
    second.sendDraft(store: store)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let sentToPane = (store.session("ses_readme")?.items.count ?? 0) == itemsBefore + 1
        && window.draft(for: "ses_readme").isEmpty && window.draft(for: PreviewData.mainSessionID) == "From the left pane"
    first.route = .hub
    let routeShared = window.route == .hub
    window.route = .session
    window.followSelection("ses_dark_mode")
    let followsSelection = window.split.focused?.sessionID == "ses_dark_mode" && window.split.panes.count == 2
        && window.split.focusedID == firstPane.id
    window.closePane(firstPane.id, store: store)
    let closesToOne = !window.split.isActive && store.selectedSessionID == "ses_readme"
    Task { @MainActor in await store.stop() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    // The narrowest each composer gets (the widest permission mode labels), for `SplitPaneView.composerMinWidth`.
    var needs: [String] = []
    for id in [PreviewData.mainSessionID, "ses_rate_limit"] {
        guard let session = store.session(id) else { continue }
        // With the model's effort and fast mode chips, as the app shows them.
        Task { @MainActor in await store.loadModelOptions(for: session.info.model) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let probe = ConversationView(store: store, session: session, window: WindowState())
            .ensembleTheme()
            .environment(\.isSnapshot, true)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: probe)
        renderer.proposedSize = ProposedViewSize(width: 60, height: 600)
        if let image = renderer.cgImage { needs.append("\(session.permissionMode.label) \(Int(CGFloat(image.width) / renderer.scale)) pt") }
    }
    print("Split pane check: a conversation needs " + needs.joined(separator: ", ") + " at 100%")

    print("Split check: starts \(starts), four panes at most \(fourMax), resize clamps \(clamps), focus moves left \(focusMovesLeft), "
          + "one pane ends it \(endsWithOne), prune ends it \(pruneEnds), saves and restores \(roundTrip), Open in Split \(begins), "
          + "drafts shared \(sharedDrafts), focus goes to the focused pane \(focusGoesToFocused), menus per pane \(menusPerPane), "
          + "Send uses the pane's session \(sentToPane), route shared \(routeShared), follows selection \(followsSelection), "
          + "focus selects \(focusSelects), closing to one pane \(closesToOne)")
}
