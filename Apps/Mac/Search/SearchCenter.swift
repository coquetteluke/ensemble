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

    /// One selectable line of the search results: a session, or one of its matched messages.
    struct Row: Identifiable, Hashable {
        let sessionID: String
        let itemID: String?
        var id: String { sessionID + "|" + (itemID ?? "") }
    }

    var overlay: Overlay?

    // Search
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var filter: TranscriptSearchFilter = .all { didSet { if filter != oldValue { scheduleSearch(delay: .zero) } } }
    private(set) var results: [TranscriptSearchResult] = []
    /// True once a search for the current text has finished.
    private(set) var hasSearched = false
    var selection = 0

    // Palette
    var paletteQuery = "" { didSet { paletteSelection = 0 } }
    var paletteSelection = 0

    /// The file shown in the viewer pane.
    var filePreview: FileLink?

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

    /// Every selectable row in order: each session, then its matched messages.
    var rows: [Row] {
        results.flatMap { result in
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

    /// Scrolls the transcript to a message without opening a result (snapshots).
    func debugFocus(sessionID: String, itemID: String) {
        focusToken &+= 1
        transcriptFocus = TranscriptFocus(sessionID: sessionID, itemID: itemID, token: focusToken)
    }

    // MARK: Files

    func openFile(_ link: FileLink) {
        withAnimation(.easeOut(duration: 0.18)) { filePreview = link }
    }

    func closeFile() {
        withAnimation(.easeOut(duration: 0.18)) { filePreview = nil }
    }

    /// What file links in agent text do: open the viewer, with the right-click menu from `FileActions`.
    var fileLinkActions: FileLinkActions {
        FileLinkActions(open: { [weak self] link in self?.openFile(link) },
                        menu: { [weak self] link in FileActions.menu(for: link) { self?.openFile($0) } })
    }
}
