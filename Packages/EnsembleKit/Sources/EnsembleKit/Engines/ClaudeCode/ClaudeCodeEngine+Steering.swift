import Foundation

// MARK: Messages sent while the agent works

extension ClaudeCodeEngine: EngineSteeringControl {
    #if os(macOS)
    /// Writes the message to the running `claude` process with queue priority `next`: the CLI takes it into the
    /// current turn after the tool calls in flight, the way typing during a turn works in the CLI itself. If the model
    /// is already writing its last reply, the CLI runs the message as the next turn instead.
    public func steer(_ sessionID: String, text: String, files: [URL]) async throws {
        try await core.steer(sessionID, text: text, files: files)
    }

    public func canSteer(_ sessionID: String) -> Bool { !ClaudeSessionIDs.isChild(sessionID) }
    #else
    public func steer(_ sessionID: String, text: String, files: [URL]) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func canSteer(_ sessionID: String) -> Bool { false }
    #endif

    /// One combined message: the CLI merges user messages that arrive close together into a single turn anyway
    /// (its `result` lists every merged message in `user_message_uuids`), so sending them one by one would not give
    /// one reply each, and one message keeps one prompt per `result`.
    public func queuedDelivery(for sessionID: String) -> QueuedDelivery { .combined }
}
