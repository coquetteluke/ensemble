import Foundation

/// The tabs of a side panel: which panes are open, in the order they were opened, and which one is in front.
/// Closing the front tab brings its left neighbour forward (the right one when it was first).
public struct PaneTabs<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var tabs: [ID] = []
    public private(set) var active: ID?

    public init() {}

    public var isEmpty: Bool { tabs.isEmpty }

    public func contains(_ id: ID) -> Bool { tabs.contains(id) }

    /// Opens a tab at the end, or brings an open one forward.
    public mutating func open(_ id: ID) {
        if !tabs.contains(id) { tabs.append(id) }
        active = id
    }

    /// Brings an open tab forward. Returns false when it is not open.
    @discardableResult
    public mutating func select(_ id: ID) -> Bool {
        guard tabs.contains(id) else { return false }
        active = id
        return true
    }

    /// Closes a tab. Returns the tab now in front: unchanged when another tab was closed, the neighbour when the
    /// front one was, nil when none are left.
    @discardableResult
    public mutating func close(_ id: ID) -> ID? {
        guard let index = tabs.firstIndex(of: id) else { return active }
        tabs.remove(at: index)
        if active == id {
            active = tabs.isEmpty ? nil : tabs[max(0, index - 1)]
        }
        return active
    }

    /// The tab `step` places from the front one, wrapping; nil with fewer than two tabs.
    public func neighbour(_ step: Int) -> ID? {
        guard tabs.count > 1, let active, let index = tabs.firstIndex(of: active) else { return nil }
        let count = tabs.count
        return tabs[((index + step) % count + count) % count]
    }

    public mutating func closeAll() {
        tabs.removeAll()
        active = nil
    }
}
