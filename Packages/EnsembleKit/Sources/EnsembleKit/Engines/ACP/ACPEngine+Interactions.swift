import Foundation

// MARK: Plan mode and questions (`ACPElicitation`, `ACPPlanArtifact`)

extension ACPEngine: EngineInteractionControl {
    #if os(macOS)
    public func planModeSupport(sessionID: String) async -> PlanModeSupport {
        await core.planModeSupport(sessionID: sessionID)
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        try await core.answerQuestion(sessionID: sessionID, requestID: requestID, answers: answers)
    }

    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        try await core.respondToPlan(sessionID: sessionID, requestID: requestID, decision: decision)
    }
    #else
    public func planModeSupport(sessionID: String) async -> PlanModeSupport {
        .unsupported(reason: "ACP agents run on the Mac.")
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        throw ACPEngineError.unsupportedPlatform
    }

    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        throw ACPEngineError.unsupportedPlatform
    }
    #endif
}
