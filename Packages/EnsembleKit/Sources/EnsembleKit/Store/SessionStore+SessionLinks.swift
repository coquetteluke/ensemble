import Foundation

// Links between sessions started from one another (`SessionLinks.swift`), for nesting in the sidebar.
extension SessionStore {
    /// Child session id to the session that started it, for `SidebarArrangement.arrange(parents:)`.
    public var sessionParents: [String: String] { sessionLinks.parents }

    /// Remembers that `childID` was started from `parentID` (an agent's proposed session, a fork).
    public func recordStartedFrom(child childID: String, parent parentID: String) {
        sessionLinks.record(child: primarySessionID(for: childID), parent: primarySessionID(for: parentID))
    }

    /// Reads the links other apps keep for the engines' sessions again (`EngineStartedFromLinks`).
    func refreshImportedSessionLinks() async {
        guard let source = engine as? any EngineStartedFromLinks else { return }
        sessionLinks.setImported(await source.startedFromLinks())
    }
}
