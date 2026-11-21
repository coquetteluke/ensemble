import SwiftUI
import EnsembleKit

/// Window state for finding things: the search overlay (Command-K), the command palette (Command-Shift-P), the
/// shortcut overlay (Command-slash), the file viewer pane and the message a search result scrolls to.
/// One per window, created next to `WindowState`.
@Observable @MainActor
final class SearchCenter {
    enum Overlay: Equatable {
        case search, palette, shortcuts
    }

    /// One selectable line of the search results: a session, or one of its matched messages. On the start screen
    /// (nothing typed) a row can also be an action such as New session; `sessionID` is empty then.
    struct Row: Identifiable, Hashable {
        let sessionID: String
        let itemID: String?
        var command: AppCommandID? = nil
        var id: String { command.map { "command|" + $0.rawValue } ?? sessionID + "|" + (itemID ?? "") }
    }

    var overlay: Overlay?

    // Search
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var filter: TranscriptSearchFilter = .all { didSet { if filter != oldValue { scheduleSearch(delay: .zero) } } }
    private(set) var results: [TranscriptSearchResult] = []
    /// True once a search for the current text has finished.
    private(set) var hasSearched = false
    var selection = 0

    // Start screen
    /// What the overlay lists before anything is typed: sessions that need you, working ones and recent ones
    /// (`SearchPanel` keeps it current), followed by `startActions`.
    private(set) var start = SearchStart()
    /// Actions offered under the sessions on the start screen.
    static let startActions: [AppCommandID] = [.newSession, .newRoom, .openHub, .openScheduled, .commandPalette]

    /// True while the overlay shows the start screen instead of results: nothing typed and every session in scope.
    var showsStart: Bool { TranscriptSearchQuery(query).isEmpty && filter == .all && !start.sections.isEmpty }

    /// The start screen's action rows; New room only while rooms exist.
    var startActionRows: [Row] {
        Self.startActions.filter { $0 != .newRoom || rooms != nil }.map { Row(sessionID: "", itemID: nil, command: $0) }
    }

    /// Takes the sessions as the sidebar sees them and rebuilds the start screen's groups.
    func updateStart(_ entries: [SidebarEntry]) {
        let rebuilt = SearchStart.build(entries)
        guard rebuilt != start else { return }
        start = rebuilt
        if showsStart { selection = min(selection, max(0, rows.count - 1)) }
    }

    // Palette
    var paletteQuery = "" { didSet { paletteSelection = 0 } }
    var paletteSelection = 0

    /// The window whose right-hand pane shows files. Its `WindowState.sidePane` is the one record of what that pane
    /// shows (context panel, file or review), so the file viewer never fights the other panes.
    @ObservationIgnored weak var window: WindowState?
    /// The app's rooms, for the palette's New room.
    @ObservationIgnored weak var rooms: RoomsController?
    /// The file shown without a window (snapshots), and the last file opened (keeps its column).
    private var detachedPreview: FileLink?
    @ObservationIgnored private var lastOpened: FileLink?

    /// The file shown in the viewer pane: the window's side pane while it shows a file.
    var filePreview: FileLink? {
        get {
            guard let window else { return detachedPreview }
            guard window.showContextPanel, case .file(let path, let line) = window.sidePane else { return nil }
            if let last = lastOpened, last.path == path, last.line == line { return last }
            return FileLink(path: path, line: line)
        }
        set {
            if let newValue { openFile(newValue) } else { closeFile() }
        }
    }

    /// The message the transcript scrolls to and flashes (cleared a few seconds later).
    private(set) var transcriptFocus: TranscriptFocus?

    private(set) var indexer: TranscriptSearchIndexer?
    @ObservationIgnored private weak var store: SessionStore?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var focusToken = 0

    init() {}

    /// Connects to the store and starts indexing in the background a little after launch (a search opened
    /// sooner starts it at once). `startAfter` nil leaves indexing to the caller (snapshots).
    func attach(_ store: SessionStore, indexer: TranscriptSearchIndexer? = nil, startAfter delay: Duration? = .seconds(8)) {
        guard self.store !== store else { return }
        self.store = store
        self.indexer?.stop()
        self.indexer = indexer ?? TranscriptSearchIndexer.makeDefault(store: store)
        if let delay { self.indexer?.start(after: delay) }
    }

    /// The folder "This folder" means: the session on screen.
    var currentFolder: String? { store?.selected?.directory }

    // MARK: Overlays

    func show(_ overlay: Overlay) {
        self.overlay = overlay
        switch overlay {
        case .search:
            selection = 0
            indexer?.refreshSoon()
            scheduleSearch(delay: .zero)
        case .palette:
            paletteQuery = ""
            paletteSelection = 0
        case .shortcuts:
            break
        }
    }

    /// Opens the overlay, or closes it when it is already open (the same shortcut does both).
    func toggle(_ overlay: Overlay) {
        if self.overlay == overlay { close() } else { show(overlay) }
    }

    func close() {
        overlay = nil
    }

    // MARK: Search

    /// Every selectable row in order: each session, then its matched messages. On the start screen: the sessions
    /// of each group, then the actions.
    var rows: [Row] {
        if showsStart {
            return start.entries.map { Row(sessionID: $0.id, itemID: nil) } + startActionRows
        }
        return results.flatMap { result in
            [Row(sessionID: result.id, itemID: nil)] + result.matches.map { Row(sessionID: result.id, itemID: $0.itemID) }
        }
    }

    func moveSelection(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func nextFilter() {
        let all = TranscriptSearchFilter.allCases
        var next = all[((all.firstIndex(of: filter) ?? 0) + 1) % all.count]
        if next == .folder, currentFolder == nil { next = all[((all.firstIndex(of: next) ?? 0) + 1) % all.count] }
        filter = next
    }

    /// Runs the search again (the index changed while the overlay is open).
    func refresh() { scheduleSearch(delay: .zero) }

    private func scheduleSearch(delay: Duration = .milliseconds(90)) {
        searchTask?.cancel()
        guard let indexer else { return }
        let text = query
        let filter = filter
        let folder = currentFolder
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await indexer.search(text, filter: filter, folder: folder)
            guard !Task.isCancelled, let self else { return }
            let previous = self.rows.indices.contains(self.selection) ? self.rows[self.selection] : nil
            self.results = found
            self.hasSearched = true
            // Keep the selected row when it is still there (the index refreshed); otherwise start at the top.
            if let previous, let index = self.rows.firstIndex(of: previous) { self.selection = index } else { self.selection = 0 }
        }
    }

    /// Opens the selected row.
    func openSelected(window: WindowState) {
        let rows = rows
        guard rows.indices.contains(selection) else { return }
        open(rows[selection], window: window)
    }

    /// Opens the session; a message row (or a session with matches) scrolls to that message.
    func open(_ row: Row, window: WindowState) {
        guard let store else { return }
        if let command = row.command {
            close()
            CommandRegistry.run(command, CommandContext(store: store, window: window, search: self))
            return
        }
        let result = results.first { $0.id == row.sessionID }
        let itemID = row.itemID ?? result?.matches.first?.itemID
        close()
        window.open(row.sessionID, store: store)
        guard let itemID else { return }
        focusToken &+= 1
        let token = focusToken
        transcriptFocus = TranscriptFocus(sessionID: row.sessionID, itemID: itemID, token: token)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.transcriptFocus?.token == token { self?.transcriptFocus = nil }
        }
    }

    /// Scrolls the open transcript to a message and flashes it (the outline's rows), like opening a search result.
    func jump(to itemID: String, in sessionID: String) {
        focusToken &+= 1
        let token = focusToken
        transcriptFocus = TranscriptFocus(sessionID: sessionID, itemID: itemID, token: token)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.transcriptFocus?.token == token { self?.transcriptFocus = nil }
        }
    }

    /// Scrolls the transcript to a message without opening a result (snapshots).
    func debugFocus(sessionID: String, itemID: String) {
        focusToken &+= 1
        transcriptFocus = TranscriptFocus(sessionID: sessionID, itemID: itemID, token: focusToken)
    }

    // MARK: Files

    /// The folder on screen for file containment checks: the active room's folder in room view,
    /// otherwise the selected session's folder.
    private var activeFileBase: String? {
        if window?.route == .room, let dir = rooms?.selectedEngine?.state.spec.directory, !dir.isEmpty {
            return dir
        }
        if let dir = store?.selected?.directory, !dir.isEmpty {
            return dir
        }
        return nil
    }

    func openFile(_ link: FileLink) {
        if store != nil || rooms != nil {
            guard let base = activeFileBase, FileLinkCache.diskCheck(link.path, base: base) else { return }
        }
        lastOpened = link
        guard let window else {
            withAnimation(.easeOut(duration: 0.18)) { detachedPreview = link }
            return
        }
        window.openSidePane(.file(path: link.path, line: link.line))
    }

    func closeFile() {
        guard let window else {
            withAnimation(.easeOut(duration: 0.18)) { detachedPreview = nil }
            return
        }
        if case .file = window.sidePane { window.closeSidePane() }
    }

    /// What file links in agent text do: open the viewer, with the right-click menu from `FileActions`.
    var fileLinkActions: FileLinkActions {
        FileLinkActions(open: { [weak self] link in self?.openFile(link) },
                        menu: { [weak self] link in
                            guard let self else { return [] }
                            if self.store != nil || self.rooms != nil {
                                guard let base = self.activeFileBase,
                                      FileLinkCache.diskCheck(link.path, base: base) else { return [] }
                            }
                            return FileActions.menu(for: link) { self.openFile($0) }
                        })
    }
}
