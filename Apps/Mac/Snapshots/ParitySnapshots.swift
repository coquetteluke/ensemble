import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the screens added from the comparison in `docs/PARITY.md` to PNG files (2x), dark and light, with
/// sample data. Call from the `--render-snapshots` flow: `ParitySnapshots.render(to: outputDirectory, zoom: zoom)`.
/// `--render-snapshots <dir> --only parity` renders these alone.
@MainActor
enum ParitySnapshots {
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
        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = true
        // The engine's slash commands (the Context card's Compact button needs to know there is one) load asynchronously.
        if let main = store.selected {
            Task { @MainActor in await store.loadCommands(directory: main.directory) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        // Marks in memory, never the user's saved ones.
        let marks = SessionAttentionMarks(fileURL: nil)
        marks.replace(pinned: [:], unread: ["ses_readme"], completed: [:])
        let center = AttentionCenter(marks: marks, canStart: false)
        var written: [String] = []

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme,
                           grows: Bool = true, @ViewBuilder _ view: () -> V) {
            // Whole windows keep their size and zoom their content; single views grow with the zoom.
            let width = grows ? baseWidth * zoom : baseWidth
            let height = grows ? baseHeight.map { $0 * zoom } : baseHeight
            let content = ParitySnapshotCanvas(width: width, height: height) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(center)
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = directory.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        // The search overlay's start screen, with the second row selected.
        let startSearch = SearchCenter()
        startSearch.updateStart(store.sidebarEntries(marks: marks))
        startSearch.overlay = .search
        startSearch.selection = 1

        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            // The card under a finished turn, in its three shapes.
            save("next-step-\(tone)\(suffix)", width: 760, height: nil, scheme: scheme) {
                NextStepSnapshot()
            }
            // The side panel as tabs: Changes, Browser and Terminal open, Terminal in front; then filling the window.
            for (name, fills) in [("side-tabs", false), ("side-tabs-fill", true)] {
                let tabbed = WindowState()
                tabbed.showSidebar = true
                tabbed.openSidePane(.review)
                tabbed.openSidePane(.browser)
                tabbed.openSidePane(.terminal)
                if fills { tabbed.toggleSidePaneMaximized() }
                save("\(name)-\(tone)\(suffix)", width: 1440, height: 900, scheme: scheme, grows: false) {
                    MainView(store: store, window: tabbed, remoteControlOverride: true, zoomOverride: zoom)
                }
            }
            // The outline: your messages in a session, with two pinned as chapters.
            save("outline-\(tone)\(suffix)", width: 468, height: nil, scheme: scheme) {
                VStack(alignment: .leading, spacing: 18) {
                    SnapshotPopoverCard {
                        SessionOutlineList(entries: Self.outlineEntries, now: Self.now, onJump: { _ in }, onPin: { _ in })
                    }
                    SnapshotPopoverCard {
                        SessionOutlineList(entries: Self.outlineEntries, now: Self.now, initiallyChaptersOnly: true,
                                           onJump: { _ in }, onPin: { _ in })
                    }
                }
                .padding(24)
            }
            // Search before anything is typed: what needs you, what is working, recent sessions, actions.
            save("search-start-\(tone)\(suffix)", width: SearchPanel.width + 48, height: nil, scheme: scheme) {
                SearchPanel(search: startSearch, store: store, window: window)
                    .padding(24)
            }
            // Background work with a Finished group under what runs.
            save("background-finished-\(tone)\(suffix)", width: 420, height: nil, scheme: scheme) {
                SnapshotPopoverCard {
                    BackgroundListView(store: store, now: Self.now, history: Self.finishedHistory) { _ in }
                }
                .padding(20)
            }
            if let main = store.selected {
                // The Context card's foot: room left before compacting, and Compact.
                save("context-compact-\(tone)\(suffix)", width: MainView.panelWidth, height: 620, scheme: scheme) {
                    ContextPanelView(store: store, session: main, remoteControl: .constant(true), topInset: 15)
                }
            }
            if let main = store.selected {
                // The title row: the title you click to rename, the menu beside it drawn open, and the rename field.
                save("title-menu-\(tone)\(suffix)", width: 760, height: nil, scheme: scheme) {
                    TitleMenuSnapshot(store: store, session: main, window: window)
                }
            }
        }

        print("Rendered \(written.count) parity snapshots:")
        for path in written { print(path) }
        return written
    }
}

extension ParitySnapshots {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A session's outline: six turns, two of them pinned as chapters.
    static var outlineEntries: [OutlineEntry] {
        let turns: [(String, Double, Int)] = [
            ("Build the context panel like the reference: environment, context, outputs, connectors", 190, 4),
            ("The bar should size each part by the limit, not by what is used", 164, 2),
            ("Run the tests", 150, 0),
            ("Now the Outputs list, with file icons and the added and removed counts", 96, 3),
            ("/compact", 41, 0),
            ("Show connector status and an Authenticate button", 6, 1),
        ]
        let items: [TranscriptItem] = turns.enumerated().flatMap { index, turn -> [TranscriptItem] in
            let edits: [TranscriptItem] = (0..<turn.2).map {
                .tool(ToolCallInfo(id: "t\(index)-\($0)", name: "edit", title: "File\($0).swift", status: .succeeded))
            }
            return [.user(id: "u\(index)", text: turn.0, date: now.addingTimeInterval(-turn.1 * 60))] + edits
        }
        return TranscriptOutline.entries(items, pinned: ["u0", "u3"])
    }

    /// Three rows that ran and ended: a subagent, a command and a task.
    static var finishedHistory: BackgroundHistory {
        var history = BackgroundHistory()
        let rows = [
            BackgroundWorkItem(id: "subagent:done", kind: .subagent, title: "Check the relay handshake", detail: "general-purpose",
                               rootSessionID: "ses_main", started: now.addingTimeInterval(-611)),
            BackgroundWorkItem(id: "task:tests", kind: .shell, title: "swift test --parallel", rootSessionID: "ses_main",
                               started: now.addingTimeInterval(-185)),
            BackgroundWorkItem(id: "task:watch", kind: .task, title: "Watch the build log", rootSessionID: "ses_main",
                               started: now.addingTimeInterval(-42)),
        ]
        history.update(running: rows, at: now.addingTimeInterval(-700))
        history.update(running: [], at: now)
        return history
    }
}

private struct ParitySnapshotCanvas<Content: View>: View {
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

/// A popover's content on a card with the popover's border and shadow.
struct SnapshotPopoverCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).strokeBorder(theme.border))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.14), radius: theme.z(14), y: theme.z(6))
    }
}

/// The window's title row with the session menu open under the title, then the same row while renaming.
private struct TitleMenuSnapshot: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CenterHeader(store: store, window: window)
            SnapshotPopoverCard {
                SessionMenuList(sections: SessionMenu.sections(SessionMenuState(pinned: false, unread: false))) { _ in }
            }
            .padding(.leading, theme.z(120))
            .padding(.bottom, theme.z(22))
            HLine()
            HStack(spacing: theme.z(8)) {
                SessionTitleControl(store: store, session: session, window: window, snapshotRenaming: true)
                Text(Format.abbreviatedPath(session.directory))
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            .padding(.leading, theme.z(20))
            .frame(height: theme.z(52))
        }
    }
}

/// The next-step card: a turn that changed files, one that also ends with a yes-or-no question, and a question alone.
private struct NextStepSnapshot: View {
    @Environment(\.theme) private var theme

    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    private static let diff = "--- a/ContextBar.swift\n+++ b/ContextBar.swift\n" + String(repeating: "+let width = 1\n", count: 48)
        + String(repeating: "-let width = 0\n", count: 12)

    private static func step(_ items: [TranscriptItem]) -> NextStep? {
        NextStepBuilder.build(items: [.user(id: "u", text: "Go", date: date)] + items, isWorking: false, hasOpenPrompt: false)
    }

    private static let steps: [NextStep] = [
        step([
            .tool(ToolCallInfo(id: "t1", name: "edit", title: "Sources/ContextBar.swift", status: .succeeded, diff: diff)),
            .tool(ToolCallInfo(id: "t2", name: "edit", title: "Sources/ContextPanelView.swift", status: .succeeded)),
            .tool(ToolCallInfo(id: "t3", name: "write", title: "Tests/ContextBarTests.swift", status: .succeeded)),
            .tool(ToolCallInfo(id: "t4", name: "bash", title: "swift test", status: .succeeded)),
            .agentText(id: "a", text: "The bar is sized by the limit now and the tests pass.", agentID: nil, streaming: false),
        ]),
        step([
            .tool(ToolCallInfo(id: "t1", name: "write", title: "README.md", status: .succeeded)),
            .tool(ToolCallInfo(id: "t2", name: "bash", title: "markdownlint README.md", status: .succeeded)),
            .agentText(id: "a", text: "The README covers install, the engine and the iPhone app.\n\nShould I commit it on this branch?",
                       agentID: nil, streaming: false),
        ]),
        step([
            .agentText(id: "a", text: "Nothing is changed yet. Want me to run the full test suite before I touch the relay?",
                       agentID: nil, streaming: false),
        ]),
    ].compactMap { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(18)) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { _, step in
                NextStepCard(step: step, onAction: { _ in }, onDismiss: {})
            }
        }
        .padding(theme.z(24))
    }
}
