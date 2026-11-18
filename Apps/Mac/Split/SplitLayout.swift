import Foundation

/// Sessions shown side by side in the main window: 2 to 4 panes, each with its own transcript and composer. One pane is
/// focused; the window's selected session is always the focused pane's, so the side pane (context, file, review), the
/// menu bar's Send and Stop, and Command-1 to 9 act on it. Saved per window (`WindowState.restoreSplit`).
struct SplitLayout: Codable, Equatable {
    struct Pane: Codable, Equatable, Hashable, Identifiable {
        var id: UUID
        var sessionID: String
    }

    static let maxPanes = 4
    /// The narrowest a pane gets while resizing, before zoom.
    static let minPaneWidth: CGFloat = 320

    private(set) var panes: [Pane] = []
    /// Each pane's share of the width, in pane order, adding up to 1.
    private(set) var fractions: [Double] = []
    private(set) var focusedID: UUID?

    /// True when the window shows two or more sessions side by side.
    var isActive: Bool { panes.count >= 2 }
    var isFull: Bool { panes.count >= Self.maxPanes }
    var focused: Pane? { panes.first { $0.id == focusedID } }

    func pane(_ id: UUID) -> Pane? { panes.first { $0.id == id } }
    func pane(showing sessionID: String) -> Pane? { panes.first { $0.sessionID == sessionID } }
    func contains(sessionID: String) -> Bool { pane(showing: sessionID) != nil }

    // MARK: Changes

    /// Starts a split with `first` on the left and `second` beside it, focused.
    mutating func start(_ first: String, beside second: String) {
        let left = Pane(id: UUID(), sessionID: first)
        let right = Pane(id: UUID(), sessionID: second)
        panes = [left, right]
        fractions = [0.5, 0.5]
        focusedID = right.id
    }

    /// Adds a pane showing `sessionID` right of `paneID` (else at the end) and focuses it. The new pane gets an equal
    /// share; the others keep their proportions. Returns nil when the split is full or not started.
    @discardableResult
    mutating func insert(_ sessionID: String, after paneID: UUID?) -> Pane? {
        guard isActive, !isFull else { return nil }
        let pane = Pane(id: UUID(), sessionID: sessionID)
        let index = paneID.flatMap { id in panes.firstIndex { $0.id == id } }.map { $0 + 1 } ?? panes.count
        let share = 1 / Double(panes.count + 1)
        fractions = fractions.map { $0 * (1 - share) }
        panes.insert(pane, at: index)
        fractions.insert(share, at: index)
        focusedID = pane.id
        return pane
    }

    /// Removes a pane; its width goes to the others in proportion. A focused pane hands focus to its left neighbour
    /// (else the right one). With one pane left the split ends and that pane's session is returned.
    @discardableResult
    mutating func remove(_ paneID: UUID) -> String? {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return nil }
        let wasFocused = focusedID == paneID
        panes.remove(at: index)
        fractions.remove(at: index)
        normalize()
        if panes.count < 2 {
            let remaining = panes.first?.sessionID
            clear()
            return remaining
        }
        if wasFocused { focusedID = panes[max(0, index - 1)].id }
        return nil
    }

    mutating func focus(_ paneID: UUID) {
        guard pane(paneID) != nil else { return }
        focusedID = paneID
    }

    /// Shows another session in a pane.
    mutating func show(_ sessionID: String, in paneID: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        panes[index].sessionID = sessionID
    }

    /// Moves the divider right of pane `index` by `delta` (a share of the width) from the `start` fractions, keeping
    /// both neighbours at least `minFraction` wide.
    mutating func resize(divider index: Int, from start: [Double], by delta: Double, minFraction: Double) {
        guard start.count == panes.count, index >= 0, index + 1 < start.count else { return }
        let pair = start[index] + start[index + 1]
        let floor = min(minFraction, pair / 2)
        let left = min(max(start[index] + delta, floor), pair - floor)
        var next = start
        next[index] = left
        next[index + 1] = pair - left
        fractions = next
    }

    /// Gives every pane the same width.
    mutating func equalize() {
        guard !panes.isEmpty else { return }
        fractions = Array(repeating: 1 / Double(panes.count), count: panes.count)
    }

    mutating func clear() {
        panes = []
        fractions = []
        focusedID = nil
    }

    /// Drops panes whose session `isValid` rejects (deleted, archived, or a duplicate). Ends the split, returning the
    /// last valid session, when fewer than two panes are left.
    @discardableResult
    mutating func keepPanes(where isValid: (String) -> Bool) -> String? {
        var seen: Set<String> = []
        let invalid = panes.filter { !isValid($0.sessionID) || !seen.insert($0.sessionID).inserted }.map(\.id)
        guard !invalid.isEmpty else { return nil }
        for id in invalid {
            if let remaining = remove(id) { return isValid(remaining) ? remaining : nil }
            if !isActive { return nil }
        }
        return nil
    }

    /// Restored layouts are checked before use: matching counts, at most four panes, a valid focus, shares that add up.
    var isWellFormed: Bool {
        panes.count >= 2 && panes.count <= Self.maxPanes && fractions.count == panes.count
            && fractions.allSatisfy { $0 > 0 && $0.isFinite } && focused != nil
    }

    private mutating func normalize() {
        let total = fractions.reduce(0, +)
        guard total > 0 else { equalize(); return }
        fractions = fractions.map { $0 / total }
    }
}
