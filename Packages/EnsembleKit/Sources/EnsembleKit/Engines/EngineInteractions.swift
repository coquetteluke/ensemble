import Foundation

/// Whether a session can run in Plan mode. Engines without a real plan mode say so; Ensemble never fakes one.
public enum PlanModeSupport: Hashable, Sendable {
    case supported
    /// Shown in the mode menu instead of the Plan choice.
    case unsupported(reason: String)

    public var isSupported: Bool { self == .supported }

    public var reason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

/// Plans and questions (`InteractionKind`). An engine adopts this when it can run Plan mode and pass answers back
/// through its own channel: Claude's control protocol, OpenCode's forms and plan agent, ACP elicitation and modes.
public protocol EngineInteractionControl: Sendable {
    func planModeSupport(sessionID: String) async -> PlanModeSupport

    /// Answers the questions of an open request. Empty `answers` declines them. The request must belong to
    /// `sessionID`; engines refuse otherwise.
    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws

    /// Proceed (switching to the given mode first) or keep planning. Returns a message the caller sends next as the
    /// user, for engines whose plan ends the turn; nil when the agent carries on within the same turn.
    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String?
}

// Kept in its own file because the protocol is new; forwards to the engine that owns the session.
extension EngineRouter: EngineInteractionControl {
    public func planModeSupport(sessionID: String) async -> PlanModeSupport {
        guard let registration = await registration(forSession: sessionID) else {
            return .unsupported(reason: "This session is not running on any engine.")
        }
        guard let control = registration.engine as? any EngineInteractionControl else {
            return .unsupported(reason: "\(registration.name) has no plan mode.")
        }
        return await control.planModeSupport(sessionID: sessionID)
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        try await interactionControl(for: sessionID, feature: "answer questions")
            .answerQuestion(sessionID: sessionID, requestID: requestID, answers: answers)
    }

    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        try await interactionControl(for: sessionID, feature: "review plans")
            .respondToPlan(sessionID: sessionID, requestID: requestID, decision: decision)
    }

    private func interactionControl(for sessionID: String, feature: String) async throws -> any EngineInteractionControl {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        guard let control = registration.engine as? any EngineInteractionControl else {
            throw EngineRouterError.notSupported(engine: registration.name, feature: feature)
        }
        return control
    }
}
