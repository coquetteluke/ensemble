import Foundation

/// One sidebar row: a session, how far it is indented under the sessions that started it, and whether sessions are
/// nested under it.
public struct SidebarTreeRow: Identifiable, Hashable, Sendable {
    public var entry: SidebarEntry
    /// 0 for a top-level row, 1 under its parent, 2 under a grandparent, and so on.
    public var depth: Int
    public var hasChildren: Bool

    public var id: String { entry.id }

    public init(entry: SidebarEntry, depth: Int = 0, hasChildren: Bool = false) {
        self.entry = entry
        self.depth = depth
        self.hasChildren = hasChildren
    }
}

/// Nests sessions under the session that started them (linked sessions), within one list of the sidebar.
public enum SidebarTree {
    /// Rows for `entries` (already sorted). A session goes under its nearest linked ancestor that is in the same list:
    /// an ancestor that is not in the list (archived, hidden, pinned, in another group, filtered out by search) is
    /// skipped. Children keep the list's order under their parent, to any depth. A cycle or a self link never loops and
    /// never hides a session. Only `parents` (child id to parent id) is used: nothing is nested by title, time or folder.
    public static func rows(_ entries: [SidebarEntry], parents: [String: String]) -> [SidebarTreeRow] {
        guard !parents.isEmpty, entries.count > 1 else { return entries.map { SidebarTreeRow(entry: $0) } }
        var position: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where position[entry.id] == nil { position[entry.id] = index }

        // The nearest ancestor in the list, by position; nil for a top-level row.
        var displayParent: [Int?] = Array(repeating: nil, count: entries.count)
        for (index, entry) in entries.enumerated() {
            var seen: Set<String> = [entry.id]
            var next = parents[entry.id]
            while let id = next, seen.insert(id).inserted {
                if let found = position[id], found != index {
                    displayParent[index] = found
                    break
                }
                next = parents[id]
            }
        }
        // Sessions caught in a cycle have no top-level ancestor: the first of each cycle in the list becomes top level.
        for start in entries.indices {
            var chain: [Int] = []
            var onChain: Set<Int> = []
            var current: Int? = start
            while let index = current, onChain.insert(index).inserted {
                chain.append(index)
                current = displayParent[index]
            }
            if let repeated = current, let loopStart = chain.firstIndex(of: repeated) {
                let first = chain[loopStart...].min()!
                displayParent[first] = nil
            }
        }
        var children: [[Int]] = Array(repeating: [], count: entries.count)
        for (index, parent) in displayParent.enumerated() {
            if let parent { children[parent].append(index) }
        }

        var rows: [SidebarTreeRow] = []
        rows.reserveCapacity(entries.count)
        // Top-level rows in list order, each followed by everything under it.
        for root in entries.indices where displayParent[root] == nil {
            var stack: [(index: Int, depth: Int)] = [(root, 0)]
            while let (index, depth) = stack.popLast() {
                rows.append(SidebarTreeRow(entry: entries[index], depth: depth, hasChildren: !children[index].isEmpty))
                for child in children[index].reversed() { stack.append((child, depth + 1)) }
            }
        }
        return rows
    }

    /// The rows still shown when the sessions under `folded` rows are hidden (every level below a folded row).
    public static func visible(_ rows: [SidebarTreeRow], folded: Set<String>) -> [SidebarTreeRow] {
        guard !folded.isEmpty else { return rows }
        var result: [SidebarTreeRow] = []
        var hideBelow: Int?
        for row in rows {
            if let depth = hideBelow {
                if row.depth > depth { continue }
                hideBelow = nil
            }
            result.append(row)
            if row.hasChildren, folded.contains(row.id) { hideBelow = row.depth }
        }
        return result
    }
}

/// The user's own order for project folders in the sidebar (drag a folder header, or Move Up and Move Down). Applies only
/// when sessions are grouped by project.
public enum SidebarFolderOrder {
    /// Groups in the saved order. Folders not in `saved` (new ones) come first, in the automatic order; folders in
    /// `saved` that have no group are ignored.
    public static func apply(_ groups: [SidebarGroup], saved: [String]) -> [SidebarGroup] {
        guard !saved.isEmpty else { return groups }
        var rank: [String: Int] = [:]
        for (index, id) in saved.enumerated() where rank[id] == nil { rank[id] = index }
        let unknown = groups.filter { rank[$0.id] == nil }
        let known = groups.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return unknown + known
    }

    /// The order to save after `folder` is dropped before (or `after`) `target`. `shown` is every folder in the order
    /// the sidebar shows them now. Saved folders that are not shown now (no sessions in the list at the moment) keep
    /// their place after the folder they followed, so they come back where they were.
    public static func moving(_ folder: String, to target: String, after: Bool, shown: [String], saved: [String]) -> [String] {
        var order = unique(shown)
        guard folder != target, let from = order.firstIndex(of: folder), order.contains(target) else {
            return keepingHidden(order, saved: saved)
        }
        order.remove(at: from)
        guard let targetIndex = order.firstIndex(of: target) else { return keepingHidden(shown, saved: saved) }
        order.insert(folder, at: after ? targetIndex + 1 : targetIndex)
        return keepingHidden(order, saved: saved)
    }

    /// The order to save after `folder` moves one place up (`by: -1`) or down (`by: 1`). Unchanged at the ends.
    public static func moving(_ folder: String, by step: Int, shown: [String], saved: [String]) -> [String] {
        let order = unique(shown)
        guard let index = order.firstIndex(of: folder) else { return keepingHidden(order, saved: saved) }
        let target = index + step
        guard step != 0, order.indices.contains(target) else { return keepingHidden(order, saved: saved) }
        return moving(folder, to: order[target], after: step > 0, shown: order, saved: saved)
    }

    /// True when `folder` can move one place up (`by: -1`) or down (`by: 1`) in `shown`.
    public static func canMove(_ folder: String, by step: Int, shown: [String]) -> Bool {
        guard let index = shown.firstIndex(of: folder) else { return false }
        return step != 0 && shown.indices.contains(index + step)
    }

    private static func keepingHidden(_ order: [String], saved: [String]) -> [String] {
        var result = order
        var present = Set(order)
        for (index, id) in saved.enumerated() where !present.contains(id) {
            let previous = saved[..<index].reversed().first { present.contains($0) }
            if let previous, let at = result.firstIndex(of: previous) {
                result.insert(id, at: at + 1)
            } else {
                result.insert(id, at: 0)
            }
            present.insert(id)
        }
        return result
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen: Set<String> = []
        return list.filter { seen.insert($0).inserted }
    }
}
