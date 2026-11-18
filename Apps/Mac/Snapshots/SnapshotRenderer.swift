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

        // Settings, Providers tab.
        save("settings-providers", width: 640, height: 780) {
            VStack(spacing: 0) {
                SettingsTabStrip(selected: "Providers")
                ProvidersSettingsView(store: store)
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

        // A subagent's own transcript, opened from its card.
        store.select(PreviewData.childSessionID)
        save("subagent-session", width: 1440, height: 900) {
            MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
        }
        store.select(PreviewData.mainSessionID)

        // The live view hierarchy (real scroll views and text view) in windows that are never shown.
        written += renderLiveWindows(outputDirectory: outputDirectory, seededStore: store)

        print("Rendered \(written.count) snapshots:")
        for path in written { print(path) }
    }

    /// Live captures: the seeded window, then a started store streaming a real turn through
    /// `PreviewEngine.events()` (mid-stream and after the permission prompt is answered).
    private static func renderLiveWindows(outputDirectory: URL, seededStore: SessionStore) -> [String] {
        var paths: [String] = []
        let live = LiveWindow(store: seededStore)
        if let path = live.capture(to: outputDirectory.appendingPathComponent("main-window-live.png")) { paths.append(path) }
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
            ForEach([("General", "gearshape"), ("Providers", "key"), ("Models", "cpu"), ("Engine", "server.rack")], id: \.0) { title, symbol in
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
