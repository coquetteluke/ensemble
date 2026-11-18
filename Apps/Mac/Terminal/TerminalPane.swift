import SwiftUI
import AppKit
import EnsembleKit

/// Whose terminal tabs the pane shows: the selected session's, or the room's on the room screen.
struct TerminalOwner: Equatable {
    /// Key in `TerminalCenter`: the session ID, or `room:` and the room's ID.
    let key: String
    let directory: String
    /// The session "Send to agent" sends to; nil in a room.
    let sessionID: String?

    @MainActor
    static func current(store: SessionStore?, rooms: RoomsController?, route: Route) -> TerminalOwner? {
        if route == .room, let room = rooms?.selectedEngine {
            return TerminalOwner(key: "room:" + room.state.id.uuidString, directory: room.state.spec.directory, sessionID: nil)
        }
        guard let session = store?.selected else { return nil }
        return TerminalOwner(key: session.id, directory: session.directory, sessionID: session.id)
    }
}

/// The terminal pane on the right of the window: tabs with the user's own shells in the session's folder.
/// Command-T opens a tab and Command-W closes one while the terminal has focus; Control-backquote shows and hides
/// the pane. Tabs stay with their session while the app runs, also while the pane is closed.
struct TerminalPane: View {
    let store: SessionStore
    var rooms: RoomsController?
    let route: Route
    let onClose: () -> Void
    /// Space left for the title bar (the window's toolbar buttons sit there).
    var topInset: CGFloat = 52

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var focusToken = 0
    /// The session (or room) on screen when the pane opened: it gets a shell straight away if it has none. Other
    /// sessions shown while the pane stays open start theirs with New tab, so clicking through sessions never
    /// starts shells.
    @State private var openedFor: String?

    static let width: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            if let owner = TerminalOwner.current(store: store, rooms: rooms, route: route) {
                TerminalTabsView(list: TerminalCenter.shared.list(for: owner.key), owner: owner, store: store,
                                 startsShell: openedFor == owner.key, focusToken: $focusToken, onClose: onClose)
                    .id(owner.key)
            } else {
                header
                HLine()
                Text("No session selected")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
        .onAppear { openedFor = TerminalOwner.current(store: store, rooms: rooms, route: route)?.key }
    }

    private var header: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "terminal")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text("Terminal")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: theme.z(4))
            IconButton("xmark", help: "Close the terminal (Control-`)", size: 26, action: onClose)
        }
        .padding(.leading, theme.z(14))
        .padding(.trailing, theme.z(8))
        .frame(height: theme.z(42))
    }
}

/// The tab strip and the terminal of one session (or room).
private struct TerminalTabsView: View {
    let list: TerminalTabList
    let owner: TerminalOwner
    let store: SessionStore
    /// Open a shell on appearing when there is none (the pane was just opened for this session).
    let startsShell: Bool
    @Binding var focusToken: Int
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var renaming: UUID?
    @State private var renameDraft = ""
    @State private var sent = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            HLine()
            content
        }
        .onAppear {
            guard !isSnapshot else { return }
            if list.tabs.isEmpty {
                if startsShell { newTab() }
            } else {
                focusToken &+= 1
            }
        }
        .onChange(of: startsShell) { _, starts in
            // The pane's first appearance sets which session it opened for, just after this view appeared.
            if starts, list.tabs.isEmpty, !isSnapshot { newTab() }
        }
        .onChange(of: list.lastTabClosures) { _, _ in onClose() }
        .onChange(of: list.selectedID) { _, _ in focusToken &+= 1 }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: theme.z(4)) {
            // The tabs, scrolling sideways once they no longer fit (snapshots cannot draw scroll views).
            if isSnapshot {
                tabButtons
            } else {
                ViewThatFits(in: .horizontal) {
                    tabButtons
                    ScrollView(.horizontal, showsIndicators: false) { tabButtons }
                }
            }
            IconButton("plus", help: "New tab (Command-T)", size: 26) { newTab() }
            Spacer(minLength: 0)
            if owner.sessionID != nil, let tab = list.selected, tab.hasSelection || sent {
                sendButton(tab)
            }
            IconButton("xmark", help: "Close the terminal (Control-`)", size: 26, action: onClose)
        }
        .padding(.trailing, theme.z(8))
        .frame(height: theme.z(42))
    }

    private var tabButtons: some View {
        HStack(spacing: theme.z(2)) {
            ForEach(list.tabs) { tab in
                TerminalTabButton(tab: tab, selected: tab.id == list.selected?.id, renaming: renaming == tab.id,
                                  draft: $renameDraft,
                                  select: { list.select(tab) },
                                  close: { close(tab) },
                                  beginRename: { beginRename(tab) },
                                  commitRename: { commitRename(tab) },
                                  cancelRename: { renaming = nil })
            }
        }
        .padding(.leading, theme.z(8))
    }

    private func sendButton(_ tab: TerminalTab) -> some View {
        Button {
            sendSelection(of: tab)
        } label: {
            HStack(spacing: theme.z(5)) {
                Image(systemName: sent ? "checkmark" : "arrow.up")
                    .font(theme.font(size: 10.5, weight: .semibold))
                Text(sent ? "Sent" : "Send to agent")
                    .font(theme.font(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, theme.z(10))
            .frame(height: theme.z(26))
            .background(Capsule().fill(theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(sent)
        .help("Send the selected output to the agent as a quoted message")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let tab = list.selected {
            ZStack(alignment: .bottom) {
                surface(tab)
                if case .failed(let message) = tab.status {
                    failureBar(message, tab: tab)
                }
            }
        } else {
            empty
        }
    }

    @ViewBuilder private func surface(_ tab: TerminalTab) -> some View {
        let palette = TerminalPalette(theme: theme)
        if isSnapshot {
            TerminalSnapshotSurface(tab: tab, palette: palette, fontSize: theme.z(12))
        } else {
            TerminalSurface(tab: tab, palette: palette, fontSize: theme.z(12), focusToken: focusToken,
                            actions: TerminalViewActions(newTab: newTab, closeTab: { close(tab) },
                                                         sendSelection: owner.sessionID == nil ? nil : { sendSelection(of: tab) }))
        }
    }

    private func failureBar(_ message: String, tab: TerminalTab) -> some View {
        HStack(spacing: theme.z(10)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
            Text(message)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: theme.z(8))
            Button("Restart") { tab.restart() }
                .buttonStyle(SecondaryButtonStyle())
            Button("Close tab") { close(tab) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(10))
        .background(theme.elevated)
        .overlay(alignment: .top) { HLine() }
    }

    private var empty: some View {
        VStack(spacing: theme.z(10)) {
            Image(systemName: "terminal")
                .font(theme.font(size: 26, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("No terminal tabs")
                .font(theme.font(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Text(Format.abbreviatedPath(owner.directory))
                .font(theme.font(size: 12, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Button("New tab") { newTab() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, theme.z(4))
        }
        .padding(theme.z(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(cgColor: TerminalPalette(theme: theme).background))
    }

    // MARK: Actions

    private func newTab() {
        list.newTab(directory: owner.directory)
        focusToken &+= 1
    }

    private func close(_ tab: TerminalTab) {
        TerminalCenter.shared.requestClose(tab, in: list, window: NSApp.keyWindow)
    }

    private func beginRename(_ tab: TerminalTab) {
        renameDraft = tab.title
        renaming = tab.id
    }

    private func commitRename(_ tab: TerminalTab) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = name.isEmpty || name == Format.folderName(tab.directory) ? nil : name
        renaming = nil
        focusToken &+= 1
    }

    private func sendSelection(of tab: TerminalTab) {
        guard let sessionID = owner.sessionID, let text = tab.selectedText else { return }
        let message = TerminalQuote.message(text, folder: tab.directory)
        Task { await store.send(message, to: sessionID) }
        tab.clearSelection()
        sent = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            sent = false
        }
    }
}

/// One tab in the strip: its folder (or the name it was given), the program running in it, and a close button.
private struct TerminalTabButton: View {
    let tab: TerminalTab
    let selected: Bool
    let renaming: Bool
    @Binding var draft: String
    let select: () -> Void
    let close: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: theme.z(6)) {
            if tab.runningProgram != nil {
                Circle()
                    .fill(theme.accent)
                    .frame(width: theme.z(6), height: theme.z(6))
            }
            if renaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(theme.font(size: 12))
                    .frame(width: theme.z(120))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
            } else {
                Text(tab.title)
                    .font(theme.font(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                if let program = tab.runningProgram {
                    Text(program)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: theme.z(16), height: theme.z(16))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(selected || hovering ? 1 : 0)
            .help("Close tab (Command-W)")
        }
        .padding(.leading, theme.z(10))
        .padding(.trailing, theme.z(5))
        .frame(height: theme.z(28))
        .background(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .fill(selected ? theme.elevated : (hovering ? theme.hover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .strokeBorder(selected ? theme.border : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: beginRename)
        .onTapGesture(perform: select)
        .help(Format.abbreviatedPath(tab.directory))
        .contextMenu {
            Button("Rename Tab", action: beginRename)
            Button("Close Tab", action: close)
        }
    }
}

/// Snapshots: the screen drawn into an image, since `ImageRenderer` cannot draw AppKit views. The tab's snapshot
/// script is written for the size the pane gives it.
private struct TerminalSnapshotSurface: View {
    let tab: TerminalTab
    let palette: TerminalPalette
    let fontSize: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let metrics = TerminalMetrics(size: fontSize)
            if let image = render(size: proxy.size, metrics: metrics) {
                Image(decorative: image, scale: 2)
            }
        }
        .background(Color(cgColor: palette.background))
    }

    private func render(size: CGSize, metrics: TerminalMetrics) -> CGImage? {
        let grid = metrics.grid(for: size)
        let emulator: TerminalEmulator
        if let script = tab.snapshotScript {
            emulator = TerminalEmulator(columns: grid.columns, rows: grid.rows)
            emulator.feed(script(grid.columns, grid.rows))
        } else {
            emulator = tab.emulator
        }
        let failed = if case .failed = tab.status { true } else { false }
        return TerminalRenderer.screenImage(emulator: emulator, size: size, scale: 2, metrics: metrics, palette: palette,
                                            cursorFocused: true, showsCursor: !failed)
    }
}

/// The message "Send to agent" sends: the selected output in a fenced block, with the folder it came from.
enum TerminalQuote {
    static func message(_ text: String, folder: String) -> String {
        let body = text.trimmingCharacters(in: .newlines)
        // A fence longer than any run of backticks in the output, so the output cannot close it.
        var longest = 0
        var run = 0
        for character in body {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "Output from my terminal in \(Format.abbreviatedPath(folder)):\n\n\(fence)\n\(body)\n\(fence)"
    }
}
