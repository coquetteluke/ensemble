import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// `Ensemble --render-snapshots <dir>` renders key views with sample data to PNG files (2x) and quits.
/// Lets the look be checked without screen recording permission and without opening windows.
@MainActor
enum SnapshotRenderer {
    /// `--zoom <percent>` (for example 80, 100, 150); defaults to 100.
    static var requestedZoom: CGFloat {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--zoom"), index + 1 < arguments.count,
              let percent = Double(arguments[index + 1]) else { return 1 }
        return CGFloat(percent / 100)
    }

    static func requestedDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-snapshots") else { return nil }
        let path = index + 1 < arguments.count ? arguments[index + 1] : "test-output/snapshots"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// A power controller that is never started, so the Keep awake button draws in its off state.
    static let power = PowerController(backend: MacPowerBackend(), defaults: UserDefaults(suiteName: "ensemble-snapshots") ?? .standard)

    static func run(outputDirectory: URL) {
        let zoom = requestedZoom
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(outputDirectory.path): \(error.localizedDescription)")
            return
        }

        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = true
        guard let main = store.selected else {
            print("No sample session to render")
            return
        }
        // Effort, fast mode and the engine's slash commands come from the preview engine asynchronously.
        Task { @MainActor in
            await store.loadModelOptions(for: main.info.model)
            await store.loadCommands(directory: main.directory)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        var written: [String] = []
        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme = .dark,
                           @ViewBuilder _ view: () -> V) {
            // Whole windows keep their size and zoom their content; single views grow with the zoom.
            let isWindow = baseWidth == 1440
            let width = isWindow ? baseWidth : baseWidth * zoom
            let height = isWindow ? baseHeight : baseHeight.map { $0 * zoom }
            let content = SnapshotCanvas(width: width, height: height) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = outputDirectory.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                print("Failed to write \(name)")
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        // Full window, dark and light.
        save("main-window-dark", width: 1440, height: 900) {
            MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
        }
        save("main-window-light", width: 1440, height: 900, scheme: .light) {
            MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
        }

        // Context panel alone, collapsed and with connectors open.
        save("context-panel", width: MainView.panelWidth, height: 1000) {
            ContextPanelView(store: store, session: main, remoteControl: .constant(true), topInset: 15)
        }
        save("context-panel-connectors", width: MainView.panelWidth, height: 1180) {
            ContextPanelView(store: store, session: main, remoteControl: .constant(true), topInset: 15, connectorsInitiallyExpanded: true)
        }

        // Composer with the permission mode menu open above it, and the model menu.
        save("composer-mode-menu", width: 820, height: nil) {
            ComposerMenuSnapshot(store: store, session: main, window: window)
        }

        // Settings, Accounts tab.
        save("settings-accounts", width: 640, height: 780) {
            VStack(spacing: 0) {
                SettingsTabStrip(selected: "Accounts")
                AccountsSettingsView(store: store)
            }
        }

        // Single cards.
        let permission = main.pendingPermissions.first
            ?? PermissionRequest(id: "p", sessionID: main.id, kind: "bash", title: "swift test --parallel")
        save("permission-card", width: 760, height: nil) {
            PermissionCardView(request: permission)
                .padding(24)
        }
        let editTool = main.items.compactMap { item -> ToolCallInfo? in
            if case .tool(let tool) = item, tool.diff != nil { return tool }
            return nil
        }.first
        if let editTool {
            save("tool-card-diff", width: 760, height: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    ToolCardView(tool: editTool, expanded: true)
                    ForEach(main.items.compactMap { item -> ToolCallInfo? in
                        if case .tool(let tool) = item, tool.diff == nil { return tool }
                        return nil
                    }) { tool in
                        if tool.name == "task" {
                            SubagentCardView(tool: tool)
                        } else {
                            ToolCardView(tool: tool, expanded: tool.name == "bash")
                        }
                    }
                }
                .environment(\.sessionDirectory, main.directory)
                .padding(24)
            }
        }

        // Room transcript with agent names and a board message.
        if let room = store.session("ses_db_debate") {
            save("room-transcript", width: 800, height: nil) {
                TranscriptList(items: room.items, resolutions: room.resolutions, agents: store.agents)
                    .padding(28)
            }
        }

        // Activity groups, inline visuals, an SVG image, the task list and the working row.
        save("transcript-polish", width: 800, height: nil) {
            PolishSnapshot(main: main)
                .environment(\.sessionDirectory, main.directory)
                .padding(28)
        }

        // Hover actions under your messages: idle, while the agent works, and on an engine without history.
        save("message-actions", width: 800, height: nil) {
            MessageActionsSnapshot()
                .padding(28)
        }

        // The / menu above the composer (Ensemble's commands, the engine's commands and skills), and the effort menu.
        save("composer-slash-menu", width: 820, height: nil) {
            ComposerSlashSnapshot(store: store, session: main, window: window, draft: "/")
        }
        save("composer-slash-filtered", width: 820, height: nil) {
            ComposerSlashSnapshot(store: store, session: main, window: window, draft: "/re")
        }
        if let options = store.options(for: main.info.model) {
            save("composer-effort-menu", width: 820, height: nil) {
                ComposerEffortSnapshot(store: store, session: main, window: window, options: options)
            }
        }

        // A subagent's own transcript, opened from its card.
        store.select(PreviewData.childSessionID)
        save("subagent-session", width: 1440, height: 900) {
            MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
        }
        store.select(PreviewData.mainSessionID)

        // The live view hierarchy (real scroll views and text view) in windows that are never shown.
        // Rooms in the window: the Rooms section in the sidebar, then a room open, dark and light.
        let roomSeed = RoomSeed()
        let roomWindow = WindowState()
        roomWindow.showSidebar = true
        roomWindow.showContextPanel = true
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            roomWindow.route = .session
            save("main-window-rooms-\(tone)", width: 1440, height: 900, scheme: scheme) {
                MainView(store: store, window: roomWindow, rooms: roomSeed.controller, remoteControlOverride: true, zoomOverride: zoom)
            }
            roomWindow.openRoom(roomSeed.team.state.id, rooms: roomSeed.controller)
            save("main-window-room-\(tone)", width: 1440, height: 900, scheme: scheme) {
                MainView(store: store, window: roomWindow, rooms: roomSeed.controller, remoteControlOverride: true, zoomOverride: zoom)
            }
        }
        // A room without the sidebar and its panel (the header leaves room for the window's buttons).
        roomWindow.showSidebar = false
        roomWindow.showContextPanel = false
        save("main-window-room-bare", width: 1440, height: 900) {
            MainView(store: store, window: roomWindow, rooms: roomSeed.controller, remoteControlOverride: true, zoomOverride: zoom)
        }

        // The file viewer in the window's right-hand pane, for a session and in a room.
        let fileWindow = WindowState()
        fileWindow.showSidebar = true
        fileWindow.showContextPanel = true
        fileWindow.openSidePane(.file(path: main.directory + "/Apps/Mac/ContextPanel/ContextBar.swift", line: 14))
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            var fileTheme = scheme == .dark ? Theme.dark : Theme.light
            fileTheme.scale = zoom
            let content = FileViewerContent.make(SearchSnapshots.sampleFile, language: "swift", theme: fileTheme)
            fileWindow.route = .session
            save("main-window-file-pane-\(tone)", width: 1440, height: 900, scheme: scheme) {
                MainView(store: store, window: fileWindow, rooms: roomSeed.controller, remoteControlOverride: true,
                         zoomOverride: zoom, snapshotFileContent: content)
            }
            if scheme == .dark {
                fileWindow.openRoom(roomSeed.team.state.id, rooms: roomSeed.controller)
                save("main-window-room-file-pane-dark", width: 1440, height: 900, scheme: scheme) {
                    MainView(store: store, window: fileWindow, rooms: roomSeed.controller, remoteControlOverride: true,
                             zoomOverride: zoom, snapshotFileContent: content)
                }
            }
        }

        // The command palette opened through the window's own search center (`searchLayer` in MainView).
        let paletteSearch = SearchCenter()
        paletteSearch.rooms = roomSeed.controller
        paletteSearch.show(.palette)
        save("main-window-palette-dark", width: 1440, height: 900) {
            MainView(store: store, window: WindowState(), rooms: roomSeed.controller, search: paletteSearch,
                     remoteControlOverride: true, zoomOverride: zoom)
        }
        checkSidePane()

        // The review pane in the window's right-hand pane, for a session and for a room.
        let reviewWindow = WindowState()
        reviewWindow.showSidebar = true
        reviewWindow.showContextPanel = true
        reviewWindow.openSidePane(.review)
        let sessionReview = ReviewSnapshots.sessionModel()
        let roomReview = ReviewSnapshots.roomModel()
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            reviewWindow.route = .session
            save("main-window-review-\(tone)", width: 1440, height: 900, scheme: scheme) {
                MainView(store: store, window: reviewWindow, rooms: roomSeed.controller, remoteControlOverride: true,
                         zoomOverride: zoom, snapshotReview: sessionReview)
            }
            reviewWindow.openRoom(roomSeed.team.state.id, rooms: roomSeed.controller)
            save("main-window-room-review-\(tone)", width: 1440, height: 900, scheme: scheme) {
                MainView(store: store, window: reviewWindow, rooms: roomSeed.controller, remoteControlOverride: true,
                         zoomOverride: zoom, snapshotReview: roomReview)
            }
        }

        written += renderLiveWindows(outputDirectory: outputDirectory, seededStore: store)
        written += AttentionSnapshots.render(to: outputDirectory, zoom: zoom)
        ComposerQueueSnapshots.render(to: outputDirectory, zoom: zoom)
        PlanQuestionSnapshots.render(to: outputDirectory, zoom: zoom)
        written += GitHubSnapshots.render(to: outputDirectory, zoom: zoom)
        written += SearchSnapshots.render(to: outputDirectory, zoom: zoom)
        written += RoomSnapshots.render(to: outputDirectory, zoom: zoom)
        written += ReviewSnapshots.render(to: outputDirectory, zoom: zoom)
        written += ImportSnapshots.render(to: outputDirectory, zoom: zoom)
        written += TrustSnapshots.render(to: outputDirectory, zoom: zoom)
        written += BackgroundSnapshots.render(to: outputDirectory, zoom: zoom)
        written += RewindSnapshots.render(to: outputDirectory, zoom: zoom)
        written += ScheduleSnapshots.render(to: outputDirectory, zoom: zoom)
        written += CustomizationsSnapshots.render(to: outputDirectory, zoom: zoom)
        written += HubSplitSnapshots.render(to: outputDirectory, zoom: zoom)
        written += BrowserSnapshots.render(to: outputDirectory, zoom: zoom)
        written += TerminalSnapshots.render(to: outputDirectory, zoom: zoom)
        written += PhoneAlertsSnapshots.render(to: outputDirectory, zoom: zoom)
        written += NarrowPaneSnapshots.render(to: outputDirectory, zoom: zoom)
        written += SafetyCheckSnapshots.render(to: outputDirectory, zoom: zoom)
        written += SwarmSnapshots.render(to: outputDirectory, zoom: zoom)
        written += AgentToolsSnapshots.render(to: outputDirectory, zoom: zoom)
        written += ModelPickerSnapshots.render(to: outputDirectory, zoom: zoom)
        written += ConstellationSnapshots.render(to: outputDirectory, zoom: zoom)
        written += PlanUsageSnapshots.render(to: outputDirectory, zoom: zoom)
        written += RelaySnapshots.render(to: outputDirectory, zoom: zoom)
        written += LinkedSessionsSnapshots.render(to: outputDirectory, zoom: zoom)
        written += TranscriptParitySnapshots.render(to: outputDirectory, zoom: zoom)

        print("Rendered \(written.count) snapshots:")
        for path in written { print(path) }
    }

    /// Live captures: the seeded window, then a started store streaming a real turn through
    /// `PreviewEngine.events()` (mid-stream and after the permission prompt is answered).
    private static func renderLiveWindows(outputDirectory: URL, seededStore: SessionStore) -> [String] {
        var paths: [String] = []
        let live = LiveWindow(store: seededStore)
        if let path = live.capture(to: outputDirectory.appendingPathComponent("main-window-live.png")) { paths.append(path) }
        // The real / menu (scroll view and all) above the real composer.
        if let sessionID = seededStore.selectedSessionID {
            live.window.drafts[sessionID] = "/"
            live.spin(0.5)
            if let path = live.capture(to: outputDirectory.appendingPathComponent("main-window-live-slash.png")) { paths.append(path) }
            live.window.drafts[sessionID] = ""
        }
        live.close()

        let engine = PreviewEngine(delayScale: 0.5)
        let store = SessionStore(engine: engine)
        let streaming = LiveWindow(store: store)
        Task { @MainActor in
            await store.start()
            store.select(PreviewData.mainSessionID)
            await store.loadSession(PreviewData.mainSessionID)
            streaming.window.drafts[PreviewData.mainSessionID] = "Look for TODOs and fix the easy ones"
            streaming.window.sendDraft(store: store)
        }
        streaming.spin(2.2)
        if let path = streaming.capture(to: outputDirectory.appendingPathComponent("main-window-live-streaming.png")) { paths.append(path) }
        if let session = store.session(PreviewData.mainSessionID) {
            if let request = session.pendingPermissions.last {
                Task { @MainActor in await store.reply(to: request, decision: .once) }
            }
            streaming.spin(6)
            if let request = session.pendingPermissions.last {
                Task { @MainActor in await store.reply(to: request, decision: .once) }
                streaming.spin(6)
            }
        }
        if let path = streaming.capture(to: outputDirectory.appendingPathComponent("main-window-live-finished.png")) { paths.append(path) }
        checkComposer(streaming, store: store)
        streaming.close()
        store.stopListening()
        return paths
    }
}

/// The context panel, the file viewer and the review pane share the window's one side pane: opening one replaces the
/// other, and closing a file or the review brings the context panel back only if it was open.
@MainActor
private func checkSidePane() {
    // Option-Command-I saves the panel's state; keep the user's saved choice as it was.
    let saved = UserDefaults.standard.object(forKey: "showContextPanel")
    defer { UserDefaults.standard.set(saved, forKey: "showContextPanel") }
    let window = WindowState()
    window.showContextPanel = true
    let search = SearchCenter()
    search.window = window
    let link = FileLink(path: "/tmp/a.swift", line: 3, column: 2)
    search.openFile(link)
    let fileOpens = window.sidePane == .file(path: "/tmp/a.swift", line: 3) && window.showContextPanel && search.filePreview == link
    window.toggleReview()
    let reviewReplacesFile = window.reviewOpen && search.filePreview == nil
    window.toggleReview()
    let contextBack = window.contextPanelVisible
    window.toggleContextPanel()
    search.openFile(link)
    search.closeFile()
    let staysClosed = !window.showContextPanel && window.sidePane == .context
    window.openSidePane(.review)
    window.toggleContextPanel()
    let shortcutShowsContext = window.contextPanelVisible
    window.toggleContextPanel()
    print("Side pane check: file opens \(fileOpens), review replaces it \(reviewReplacesFile), context panel returns \(contextBack), "
          + "closed pane stays closed \(staysClosed), Option-Command-I shows the context panel \(shortcutShowsContext)")
}

/// Types into the real composer text view and presses Return, then checks the message reached the session.
@MainActor
private func checkComposer(_ live: LiveWindow, store: SessionStore) {
    guard let session = store.selected, let textView = live.composerTextView() else {
        print("Composer check: text view not found")
        return
    }
    textView.window?.makeFirstResponder(textView)
    textView.insertText("Second message", replacementRange: NSRange(location: NSNotFound, length: 0))
    live.spin(0.2)
    let draftUpdated = live.window.draft(for: session.id) == "Second message"
    textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    live.spin(0.4)
    let sent = session.items.contains { if case .user(_, "Second message", _) = $0 { true } else { false } }
    let cleared = live.window.draft(for: session.id).isEmpty && textView.string.isEmpty
    Task { @MainActor in await store.stop() }
    live.spin(0.4)
    let stopped = !session.isWorking
    print("Composer check: draft follows typing \(draftUpdated), Return sends \(sent), field clears \(cleared), stop ends the turn \(stopped)")
}

/// `MainView` hosted in a window that is never ordered on screen, drawn with `cacheDisplay`.
@MainActor
private final class LiveWindow {
    let window = WindowState()
    private let hosting: NSHostingView<AnyView>
    private let offscreen: NSWindow

    init(store: SessionStore) {
        let root = MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: SnapshotRenderer.requestedZoom)
            .ensembleTheme()
            .environment(\.colorScheme, .dark)
            .environment(SnapshotRenderer.power)
        hosting = NSHostingView(rootView: AnyView(root))
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        offscreen = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .resizable],
                             backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.titlebarAppearsTransparent = true
        offscreen.appearance = NSAppearance(named: .darkAqua)
        offscreen.contentView = hosting
        hosting.frame = frame
        spin(1.0)
    }

    /// Runs the main run loop so SwiftUI updates and main-actor tasks proceed.
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func capture(to url: URL) -> String? {
        hosting.layoutSubtreeIfNeeded()
        spin(0.4)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    func close() { offscreen.close() }

    func composerTextView() -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(hosting)
    }
}

/// Fixed-size background for a snapshot.
private struct SnapshotCanvas<Content: View>: View {
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

/// The composer with the mode menu drawn open, like the real popover.
private struct ComposerMenuSnapshot: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 16) {
                menuCard { ModeMenuContent(current: session.permissionMode) { _ in } }
                    .padding(.leading, 40)
                Spacer()
                menuCard {
                    ModelMenuContent(models: store.models, current: session.info.model) { _ in }
                }
                .padding(.trailing, 10)
            }
            ComposerView(store: store, session: session, window: window, snapshotDraft: "Run the tests and fix anything that fails")
            StatusLine(store: store, session: session, window: window)
        }
        .padding(24)
    }

    private func menuCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// Tab strip resembling the Settings window toolbar.
private struct SettingsTabStrip: View {
    let selected: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach([("General", "gearshape"), ("Accounts", "person.crop.circle"), ("Alerts", "bell.badge"), ("Models", "cpu"), ("Engine", "server.rack"), ("Power", "cup.and.saucer")], id: \.0) { title, symbol in
                VStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 16))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(title == selected ? theme.accent : theme.textSecondary)
                .frame(width: 72, height: 46)
                .background(RoundedRectangle(cornerRadius: 7).fill(title == selected ? theme.selection : .clear))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(theme.sidebar)
        .overlay(alignment: .bottom) { HLine() }
    }
}

/// The transcript pieces added for the Claude Code look, each in its main states.
private struct PolishSnapshot: View {
    let main: SessionModel

    var body: some View {
        let steps = main.items.filter { item in
            if case .tool(let tool) = item { return !TodoParser.isTodoTool(tool.name) }
            return false
        }
        var running = steps
        running.append(.tool(ToolCallInfo(id: "w_test", name: "bash", title: "swift test --filter RemoteProtocolTests",
                                          inputJSON: #"{"command": "swift test --filter RemoteProtocolTests"}"#, status: .running)))
        let turn: [TranscriptItem] = [.user(id: "w_u", text: "Check the remote protocol", date: Date())] + running
        return VStack(alignment: .leading, spacing: 18) {
            ActivityGroupView(items: steps)
            ActivityGroupView(items: running, expanded: true)
            MarkdownView(Self.visualMessage)
            WidgetBlockView(source: Self.widget, collapsed: true)
            WidgetBlockView(source: Self.widget, pending: true)
            TaskListCard(items: TodoParser.latest(in: main.items) ?? [])
            WorkingRow(items: turn, since: Date().addingTimeInterval(-69), waitingForPermission: false, expanded: true)
            WorkingRow(items: turn, since: Date().addingTimeInterval(-975), waitingForPermission: true)
        }
    }

    static let widget = """
    <div style="display:flex;gap:8px;align-items:flex-end;height:120px">
      <div style="flex:1;height:40%;background:var(--accent)"></div>
      <div style="flex:1;height:75%;background:var(--blue)"></div>
      <div style="flex:1;height:55%;background:var(--teal)"></div>
    </div>
    """

    static let visualMessage = """
    Here is the context use per category:

    ```widget
    \(widget)
    ```

    And the icon as an SVG:

    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 96" width="240" height="96">
      <rect x="4" y="4" width="88" height="88" rx="20" fill="#8B7CF6"/>
      <circle cx="30" cy="34" r="7" fill="#fff"/><circle cx="66" cy="30" r="5" fill="#fff"/>
      <circle cx="48" cy="64" r="9" fill="#fff"/>
      <path d="M30 34 L66 30 L48 64 Z" fill="none" stroke="#fff" stroke-width="2" opacity="0.7"/>
      <text x="108" y="58" font-family="-apple-system, sans-serif" font-size="26" fill="#A0A0A0">Ensemble</text>
    </svg>
    ```
    """
}

/// Your messages with their action bar drawn as if hovered.
private struct MessageActionsSnapshot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            UserBubble(id: "m1", text: "Run the tests and fix anything that fails", date: Date().addingTimeInterval(-300), alwaysShowActions: true)
                .environment(\.transcriptActions, TranscriptActions(historySupported: true))
            UserBubble(id: "m2", text: "Now update the README", date: Date().addingTimeInterval(-20), alwaysShowActions: true)
                .environment(\.transcriptActions, TranscriptActions(historySupported: true, workingAgentName: "Claude Opus 5.5"))
            UserBubble(id: "m3", text: "Engine without fork and rewind", date: Date().addingTimeInterval(-7200), alwaysShowActions: true)
                .environment(\.transcriptActions, TranscriptActions(historySupported: false))
        }
    }
}

/// The composer with a / draft; the command menu draws in the space above it.
private struct ComposerSlashSnapshot: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    let draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 360)
            ComposerView(store: store, session: session, window: window, snapshotDraft: draft)
            StatusLine(store: store, session: session, window: window)
        }
        .padding(24)
    }
}

/// The effort menu drawn open above its chip.
private struct ComposerEffortSnapshot: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    let options: ModelOptions
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            EffortMenuContent(levels: options.effortLevels, current: session.effort ?? options.defaultEffort) { _ in }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(.trailing, 90)
            ComposerView(store: store, session: session, window: window, snapshotDraft: "Make the tests faster")
            StatusLine(store: store, session: session, window: window)
        }
        .padding(24)
    }
}
