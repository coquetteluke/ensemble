import Foundation

// MARK: Messages sent while the agent works

extension OpenCodeClient: EngineSteeringControl {
    /// `POST /api/session/{id}/prompt` with `delivery: steer`. Checked live with the mock model: a prompt that arrives
    /// while a tool runs joins that run (one execution), and the model's next step answers it. A prompt without
    /// `delivery` behaves the same; `queue` waits until the run's last reply and then continues in the same execution.
    /// On an idle session it starts a turn like any prompt.
    public func steer(_ sessionID: String, text: String, files: [URL]) async throws {
        try await prompt(sessionID, text: text, files: files, delivery: .steer)
    }

    public func canSteer(_ sessionID: String) -> Bool { true }

    /// One prompt per turn, oldest first: each held message gets its own reply, as if sent after the previous one
    /// finished, and the queue strip keeps showing the ones still waiting. (Handing OpenCode several prompts at once
    /// would also run them one after another, but they would leave the strip at once.)
    public func queuedDelivery(for sessionID: String) -> QueuedDelivery { .inOrder }
}
