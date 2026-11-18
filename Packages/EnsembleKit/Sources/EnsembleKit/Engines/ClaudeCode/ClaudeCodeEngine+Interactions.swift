import Foundation

// MARK: Plan mode and questions (`ClaudeInteractionTools`, `ClaudePlanGuard`)

extension ClaudeCodeEngine: EngineInteractionControl {
    #if os(macOS)
    public func planModeSupport(sessionID: String) async -> PlanModeSupport {
        await core.planModeSupport(sessionID: sessionID)
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        try await core.answerQuestion(sessionID: sessionID, requestID: requestID, answers: answers)
    }

    /// The agent carries on in the same turn after both answers, so there is never a message to send.
    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        try await core.respondToPlan(sessionID: sessionID, requestID: requestID, decision: decision)
        return nil
    }
    #else
    public func planModeSupport(sessionID: String) async -> PlanModeSupport {
        .unsupported(reason: "Claude agents run on the Mac.")
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        throw ClaudeCodeError.unsupportedPlatform
    }

    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        throw ClaudeCodeError.unsupportedPlatform
    }
    #endif
}
