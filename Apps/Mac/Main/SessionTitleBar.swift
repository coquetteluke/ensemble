import SwiftUI
import AppKit
import EnsembleKit

/// The session's title in the window's title row. Click the title to rename it in place; the arrow beside it opens
/// the session's menu (`SessionMenu`): split, pin, marks, rename, fork, copy, reveal, archive, delete.
struct SessionTitleControl: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    /// Snapshots draw the rename field without a click.
    var snapshotRenaming = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    /// Snapshots inject their own; the app uses `AttentionCenter.shared`.
    @Environment(AttentionCenter.self) private var injectedAttention: AttentionCenter?
    @State private var renaming = false
    @State private var draft = ""
    @State private var showMenu = false
    @State private var confirmDelete = false
    @State private var hoveringTitle = false
    @FocusState private var fieldFocused: Bool

    private var attention: AttentionCenter { injectedAttention ?? .shared }

    var body: some View {
        HStack(spacing: theme.z(2)) {
            if renaming || snapshotRenaming {
                field
            } else {
                titleButton
            }
            menuButton
        }
        .onChange(of: session.id) {
            renaming = false
            showMenu = false
        }
        .onChange(of: window.renameRequestToken) { beginRename() }
        .onChange(of: fieldFocused) { _, focused in
            // Clicking anywhere else saves, like a Finder rename. The keyboard stays where the click put it.
            if !focused && renaming { commitRename(returnKeyboard: false) }
        }
        // Escape cancels the rename or closes the menu. Without this it would reach Session > Stop while the agent
        // works, because menu shortcuts are tried before a field or a popover sees the key. The menu's letter keys
        // are read here too, so its list never takes the keyboard away from the message box.
        .background(EscapeKeyMonitor(isActive: renaming || showMenu, onEscape: {
            if showMenu { showMenu = false } else { cancelRename() }
        }, onKey: { key in
            guard showMenu, let item = SessionMenu.item(forKey: key, in: menuState) else { return false }
            showMenu = false
            run(item.action)
            return true
        }))
        .confirmationDialog("Delete this session?", isPresented: deleteShown) {
            Button("Delete", role: .destructive) { Task { await store.delete(session.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(session.title)\u{201D} and its messages are removed for good.")
        }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { confirmDelete && !isSnapshot }, set: { confirmDelete = $0 })
    }

    // MARK: Title and rename

    private var titleButton: some View {
        Button(action: beginRename) {
            Text(session.title)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, theme.z(6))
                .frame(height: theme.z(24))
                .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(hoveringTitle ? theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringTitle = $0 }
        .help("Rename")
        .accessibilityLabel("\(session.title), rename session")
        // The hover fill's padding should not push the title right of where plain text sat.
        .padding(.leading, -theme.z(6))
    }

    private var field: some View {
        Group {
            if isSnapshot {
                Text(session.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $draft, prompt: Text("Title").foregroundStyle(theme.textTertiary))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commitRename(returnKeyboard: true) }
            }
        }
        .font(theme.font(size: 13, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, theme.z(6))
        .frame(width: fieldWidth, height: theme.z(24))
        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).strokeBorder(theme.accent.opacity(0.7), lineWidth: 1))
        .padding(.leading, -theme.z(6))
    }

    /// Wide enough for the text being typed, between a short and a long limit.
    private var fieldWidth: CGFloat {
        let text = (isSnapshot ? session.title : draft)
        return theme.z(min(max(160, CGFloat(text.count) * 7.8 + 28), 440))
    }

    private func beginRename() {
        guard !isSnapshot else { return }
        showMenu = false
        draft = session.title
        renaming = true
        fieldFocused = true
    }

    /// `returnKeyboard`: Return ends the rename, so typing goes on in the message box. Without it the keyboard
    /// would fall to the window's first field, the sidebar search.
    private func commitRename(returnKeyboard: Bool) {
        guard renaming else { return }
        renaming = false
        if let title = SessionMenu.cleanedTitle(draft, current: session.title) {
            let id = session.id
            Task { await store.rename(id, to: title) }
        }
        if returnKeyboard { window.composerFocusToken &+= 1 }
    }

    private func cancelRename() {
        renaming = false
        fieldFocused = false
        window.composerFocusToken &+= 1
    }

    // MARK: Menu

    private var menuButton: some View {
        Button {
            showMenu.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(theme.font(size: 9.5, weight: .semibold))
                .foregroundStyle(showMenu ? theme.textPrimary : theme.textTertiary)
                .frame(width: theme.z(20), height: theme.z(24))
                .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(showMenu ? theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Session menu")
        .accessibilityLabel("Session menu")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            SessionMenuList(sections: SessionMenu.sections(menuState)) { item in
                showMenu = false
                run(item.action)
            }
            .ensembleTheme()
        }
    }

    /// The menu's state for the session on screen. From the title row "Open in Split" brings the next session in
    /// beside this one, so it follows the same rule as the palette's command.
    var menuState: SessionMenuState {
        let id = session.id
        let canSplit = window.split.isActive
            ? !window.split.isFull
            : store.sessions.contains { !$0.isSubagent && !$0.info.archived && $0.id != id }
        return SessionMenuState(
            pinned: attention.marks.isPinned(id),
            unread: attention.marks.isUnread(id),
            completed: attention.marks.isCompleted(id),
            archived: session.info.archived,
            canFork: store.supportsHistory,
            canOpenBeside: canSplit,
            shownInSplit: false,
            isSubagent: session.isSubagent
        )
    }

    private func run(_ action: SessionMenuAction) {
        let id = session.id
        let state = menuState
        switch action {
        case .openInSplit:
            window.openNextBeside(store: store)
        case .pin:
            attention.setPinned(id, !state.pinned)
        case .markUnread:
            attention.setUnread(id, !state.unread)
        case .markCompleted:
            attention.setCompleted(id, !state.completed)
        case .rename:
            // After the popover has closed, or its closing takes the keyboard back from the field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { beginRename() }
        case .fork:
            Task { if await store.fork(id, atMessageID: nil) != nil { window.composerFocusToken &+= 1 } }
        case .copyMarkdown:
            SessionTitleControl.copyMarkdown(of: id, store: store)
        case .revealFolder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
        case .archive:
            Task { await store.archive(id, archived: !state.archived) }
        case .delete:
            confirmDelete = true
        }
    }

    /// Puts the whole transcript on the clipboard as Markdown, loading it first when it has not been opened yet.
    static func copyMarkdown(of sessionID: String, store: SessionStore) {
        Task {
            if let session = store.session(sessionID), !session.transcriptLoaded { await store.loadSession(sessionID) }
            guard let current = store.session(sessionID) else { return }
            let markdown = TranscriptExport.markdown(
                title: current.title,
                directory: current.directory,
                modelName: store.modelName(current.info.model),
                items: current.items,
                agents: store.agents
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
    }
}

/// The session menu's rows, as the popover shows them: a symbol, the title and the key that picks the row while the
/// menu is open (`SessionTitleControl` reads those keys). Lines separate the groups.
struct SessionMenuList: View {
    let sections: [[SessionMenuItem]]
    let onPick: (SessionMenuItem) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, rows in
                if index > 0 {
                    HLine(color: theme.border)
                        .padding(.vertical, theme.z(4))
                        .padding(.horizontal, theme.z(6))
                }
                ForEach(rows) { item in
                    row(item)
                }
            }
        }
        .padding(theme.z(6))
        .frame(width: theme.z(236))
        .background(theme.popover)
    }

    private func row(_ item: SessionMenuItem) -> some View {
        Button {
            onPick(item)
        } label: {
            HStack(spacing: theme.z(10)) {
                Image(systemName: item.symbol)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(item.destructive ? theme.danger : theme.textSecondary)
                    .frame(width: theme.z(18))
                Text(item.title)
                    .font(theme.font(size: 13))
                    .foregroundStyle(item.destructive ? theme.danger : theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(8))
                if let key = item.key {
                    Text(String(key).uppercased())
                        .font(theme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(14))
                }
            }
            .padding(.horizontal, theme.z(10))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: false, cornerRadius: theme.z(7), raised: true))
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.45)
    }
}

/// Takes a bare Escape while `isActive`, so cancelling a rename or closing a popover never reaches Session > Stop
/// (which is also Escape). `onKey` gets any other key pressed without a modifier and says whether it used it; a
/// popover that reads its keys this way does not have to take the keyboard from the field that had it.
struct EscapeKeyMonitor: View {
    let isActive: Bool
    let onEscape: () -> Void
    var onKey: ((Character) -> Bool)? = nil
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .onAppear(perform: sync)
            .onChange(of: isActive) { sync() }
            .onDisappear(perform: remove)
    }

    private func sync() {
        if isActive && !isSnapshot { install() } else { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty else { return event }
            if event.keyCode == 53 {
                MainActor.assumeIsolated { onEscape() }
                return nil
            }
            guard let onKey, let key = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            return MainActor.assumeIsolated { onKey(key) } ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
