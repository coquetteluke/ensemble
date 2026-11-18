import Foundation

// Optional engine abilities for messages sent while an agent works, and for side questions. Like the protocols in
// `EngineCapabilities.swift`, an engine adopts them when it can, and the store checks with `as?`. The answers are per
// session so an engine router can forward each one to the engine that owns the session.

/// How messages held while a turn runs go out once it ends.
public enum QueuedDelivery: String, Sendable {
    /// All held messages as one message, joined by blank lines (one turn).
    case combined
    /// One message per turn, oldest first; the next goes when the previous turn ends.
    case inOrder
}

/// Adds a message to a running turn without stopping it ("Send now").
public protocol EngineSteeringControl: Sendable {
    /// Gives the running turn a new user message. The agent reads it at its next step (after the tool calls in
    /// flight). When no turn is running it starts one, like `prompt`.
    func steer(_ sessionID: String, text: String, files: [URL]) async throws
    /// Whether `steer` reaches this session's running turn. When false, Send now stops the turn and then sends.
    func canSteer(_ sessionID: String) -> Bool
    /// How messages held for this session go out when its turn ends.
    func queuedDelivery(for sessionID: String) -> QueuedDelivery
}

/// Per-session answer to "can this session be forked". Engines that fork every session they own need not adopt it;
/// an engine router adopts it so sessions on engines without `EngineHistoryControl` report false.
public protocol EngineForkAvailability: Sendable {
    func canFork(_ sessionID: String) -> Bool
}
