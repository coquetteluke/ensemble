import Foundation

// Forwards `EngineStartedFromLinks` to every registered engine that has it. Kept in its own file because the protocol
// is new; delete this file if it moves or is renamed.
extension EngineRouter: EngineStartedFromLinks {
    /// Every engine's started-from links, merged. An engine without the capability adds none.
    public func startedFromLinks() async -> [String: String] {
        let sources = registrations.compactMap { $0.engine as? any EngineStartedFromLinks }
        var merged: [String: String] = [:]
        for source in sources {
            merged.merge(await source.startedFromLinks()) { first, _ in first }
        }
        return merged
    }
}
