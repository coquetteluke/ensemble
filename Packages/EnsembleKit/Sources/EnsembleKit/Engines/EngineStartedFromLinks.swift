import Foundation

/// Engines that know which of their sessions were started from another session by a different app (for example the
/// Claude desktop app's linked sessions). Optional: an engine that does not adopt it has no such links.
public protocol EngineStartedFromLinks: Sendable {
    /// Child session id to the id of the session that started it, both as this engine names its sessions. Links the
    /// user cut in that app are left out. Reads files off the main thread.
    func startedFromLinks() async -> [String: String]
}
