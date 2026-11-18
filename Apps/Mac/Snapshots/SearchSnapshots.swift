import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the finding pieces with sample data to PNG files (2x), dark and light: the search overlay with
/// results, the command palette, the shortcut overlay, the file viewer pane (alone and in the window), file links
/// in agent text and the Thinking and Verbose transcript views. Call from the `--render-snapshots` flow:
/// `SearchSnapshots.render(to: outputDirectory, zoom: zoom)`. The search index lives in memory.
@MainActor
enum SearchSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(directory.path): \(error.localizedDescription)")
            return []
        }

        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        guard let main = store.session(PreviewData.mainSessionID),
              let index = try? TranscriptSearchIndex(fileURL: nil) else { return [] }
        let indexer = TranscriptSearchIndexer(store: store, index: index) { _ in nil }
        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = true
        let search = SearchCenter()
        search.attach(store, indexer: indexer, startAfter: nil)
        Task { @MainActor in await indexer.pass() }
        spin(0.4)

        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme,
                           grows: Bool = true, @ViewBuilder _ view: () -> V) {
            let width = grows ? baseWidth * zoom : baseWidth
            let height = grows ? baseHeight.map { $0 * zoom } : baseHeight
            let content = SearchSnapshotCanvas(width: width, height: height) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
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

        /// The window with an overlay open over it.
        func windowWithOverlay(_ overlay: SearchCenter.Overlay, query: String = "", palette: String = "", selection: Int = 0) {
            search.overlay = overlay
            search.query = query
            search.paletteQuery = palette
            if overlay == .search {
                search.refresh()
                spin(0.4)
            }
            search.selection = selection
            search.paletteSelection = selection
        }

        let fileLink = FileLink(path: main.directory + "/Apps/Mac/ContextPanel/ContextBar.swift", line: 14)
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            let overlayWindow = { (name: String) in
                save(name + "-\(tone)", width: 1440, height: 900, scheme: scheme, grows: false) {
                    ZStack {
                        MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
                        SearchOverlayHost(search: search, store: store, window: window)
                    }
                }
            }

            windowWithOverlay(.search, query: "sqlite postgres", selection: 1)
            overlayWindow("search-overlay")
            windowWithOverlay(.search, query: "")
            overlayWindow("search-overlay-recent")
            windowWithOverlay(.palette)
            overlayWindow("command-palette")
            windowWithOverlay(.palette, palette: "view", selection: 1)
            overlayWindow("command-palette-filtered")
            windowWithOverlay(.shortcuts)
            overlayWindow("shortcut-overlay")
            search.close()

            let content = FileViewerContent.make(Self.sampleFile, language: "swift", theme: scheme == .dark ? .dark.zoomed(zoom) : .light.zoomed(zoom))
            save("file-viewer-\(tone)", width: FileViewerPane.width, height: 760, scheme: scheme) {
                FileViewerPane(link: fileLink, base: main.directory, onClose: {}, topInset: 0, content: content)
            }
            window.showContextPanel = false
            save("main-window-file-viewer-\(tone)", width: 1440, height: 900, scheme: scheme, grows: false) {
                SnapshotWindowWithViewer(store: store, window: window, zoom: zoom) {
                    FileViewerPane(link: fileLink, base: main.directory, onClose: {}, content: content)
                }
            }
            window.showContextPanel = true

            save("file-links-\(tone)", width: 760, height: nil, scheme: scheme) {
                VStack(alignment: .leading, spacing: 16) {
                    UserBubble(text: "Where is the plan and the Markdown renderer?")
                    MarkdownView(Self.linkMessage)
                }
                .environment(\.sessionDirectory, main.directory)
                .environment(\.fileLinkActions, search.fileLinkActions)
                .padding(28)
            }

            for mode in [TranscriptViewMode.thinking, .verbose] {
                save("transcript-\(mode.rawValue)-\(tone)", width: 800, height: nil, scheme: scheme) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Spacer()
                            TranscriptViewModeMenu()
                        }
                        TranscriptList(items: Self.verboseItems(main.items), resolutions: main.resolutions, agents: store.agents)
                    }
                    .environment(\.transcriptViewMode, mode)
                    .environment(\.sessionDirectory, main.directory)
                    .padding(28)
                }
            }
        }

        written += liveChecks(store: store, search: search, window: window, directory: directory, suffix: suffix, zoom: zoom)
        print("Rendered \(written.count) search snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Live checks

    /// Real windows (never shown): where file link click areas sit over selectable text; the overlay's arrow keys
    /// and Return open a result at the message; the conversation scrolls to the opened message.
    private static func liveChecks(store: SessionStore, search: SearchCenter, window: WindowState, directory: URL,
                                   suffix: String, zoom: CGFloat) -> [String] {
        var written: [String] = []
        guard let main = store.session(PreviewData.mainSessionID) else { return [] }

        // 1. File links: in a live window (selectable text), each link gets a click area over its text. The areas
        //    are tinted here so the capture shows where they sit.
        let links = OffscreenHost(size: CGSize(width: 640 * zoom, height: 150 * zoom)) {
            MarkdownView("docs/PLAN.md holds the plan, and the renderer is `Packages/EnsembleKit/Sources/EnsembleKit/UI/Markdown.swift:42`. The project file is project.yml; ../outside/notes.md is not linked.")
                .environment(\.sessionDirectory, main.directory)
                .environment(\.fileLinkActions, search.fileLinkActions)
                .environment(\.showsFileLinkAreas, true)
                .environment(\.zoom, zoom)
                .ensembleTheme()
                .padding(20 * zoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        if let path = links.capture(to: directory.appendingPathComponent("file-link-areas-live\(suffix).png")) { written.append(path) }
        links.close()

        // 2. Search overlay keys: Down moves the selection, Return opens the session at the message.
        store.select(PreviewData.mainSessionID)
        let overlay = OffscreenHost(size: CGSize(width: 1000, height: 700)) {
            SearchOverlayHost(search: search, store: store, window: window)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray)
        }
        search.show(.search)
        search.query = "postgres server"
        overlay.spin(0.5)
        let firstRow = search.rows.first
        overlay.key(125)
        let moved = search.selection == 1
        if let path = overlay.capture(to: directory.appendingPathComponent("search-overlay-live\(suffix).png")) { written.append(path) }
        overlay.key(36)
        overlay.spin(0.3)
        let openedSession = store.selectedSessionID == firstRow?.sessionID && search.overlay == nil
        let focused = search.transcriptFocus?.itemID == "ba3"
        print("Search keys check: Down selects the next row \(moved), Return opens the session \(openedSession), focuses the message \(focused)")
        overlay.close()

        // 3. The conversation scrolls to the opened message (the first one, far above the newest) and flashes it.
        store.select(PreviewData.mainSessionID)
        let conversation = OffscreenHost(size: CGSize(width: 900, height: 640)) {
            FocusedConversation(store: store, session: main, window: window, search: search)
        }
        conversation.spin(0.6)
        search.debugFocus(sessionID: main.id, itemID: "u1")
        conversation.spin(0.5)
        if let path = conversation.capture(to: directory.appendingPathComponent("conversation-scrolled-to-match\(suffix).png")) { written.append(path) }
        conversation.close()
        return written
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The sample transcript with a thought between its tool calls, so Thinking mode has something to open.
    static func verboseItems(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        var addedThought = false
        for item in items {
            if !addedThought, case .tool = item {
                result.append(.reasoning(id: "snap_thought", text: "The bar needs one segment per category. I will read the model first, then the view.", streaming: false))
                addedThought = true
            }
            result.append(item)
        }
        return result
    }

    static let linkMessage = """
    The plan is in docs/PLAN.md and the renderer is `Packages/EnsembleKit/Sources/EnsembleKit/UI/Markdown.swift:42`. \
    The project file is project.yml. Links that are not files stay as they are: https://github.com/example/docs/PLAN.md, \
    version 2.3.0, and ../outside/notes.md.
    """

    static let sampleFile = """
    import SwiftUI
    import EnsembleKit

    /// The coloured bar at the top of the Context section: one segment per category.
    struct ContextBar: View {
        let breakdown: ContextBreakdown
        let height: CGFloat = 4
        @Environment(\\.theme) private var theme

        var body: some View {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, segment.fraction * proxy.size.width))
                    }
                    Spacer(minLength: 0)
                }
                .background(Capsule().fill(theme.track))
            }
            .frame(height: theme.z(height))
            .clipShape(Capsule())
        }

        /// Categories with their share of the limit, largest first.
        private var segments: [Segment] {
            breakdown.categories
                .filter { $0.tokens > 0 }
                .map { Segment(id: $0.key, color: theme.contextColor(for: $0.key), fraction: Double($0.tokens) / Double(breakdown.limitTokens)) }
        }
    }

    private struct Segment: Identifiable {
        let id: String
        let color: Color
        let fraction: Double
    }
    """
}

private extension Theme {
    func zoomed(_ zoom: CGFloat) -> Theme {
        var theme = self
        theme.scale = zoom
        return theme
    }
}

/// The window with the file viewer where the context panel would be (as the orchestrator wires it in).
private struct SnapshotWindowWithViewer<Pane: View>: View {
    let store: SessionStore
    let window: WindowState
    let zoom: CGFloat
    @ViewBuilder let pane: Pane
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
            VLine()
            pane.frame(width: theme.z(FileViewerPane.width))
        }
    }
}

/// The conversation with the search center's focus, as the window passes it down.
private struct FocusedConversation: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    let search: SearchCenter

    var body: some View {
        ConversationView(store: store, session: session, window: window)
            .environment(\.transcriptFocus, search.transcriptFocus)
    }
}

/// A SwiftUI view in a window that is never shown, for clicks, keys and captures.
@MainActor
private final class OffscreenHost {
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init<V: View>(size: CGSize, @ViewBuilder _ view: () -> V) {
        let root = view()
            .background(Theme.dark.background)
            .ensembleTheme()
            .environment(\.colorScheme, .dark)
            .environment(SnapshotRenderer.power)
        hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        let frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = frame
        spin(0.6)
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func key(_ code: UInt16) {
        let characters: String = switch code {
        case 125: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 36: "\r"
        default: ""
        }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            NSApp.sendEvent(event)
        }
        spin(0.3)
    }

    func capture(to url: URL) -> String? {
        hosting.layoutSubtreeIfNeeded()
        spin(0.3)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return url.path
    }

    func close() { window.close() }

}

/// Fixed-size background for a search snapshot.
private struct SearchSnapshotCanvas<Content: View>: View {
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
