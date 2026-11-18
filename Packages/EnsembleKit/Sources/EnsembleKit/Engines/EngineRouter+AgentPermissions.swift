import Foundation

// Forwards `EngineAgentPermissionSupport` (Store/SafetyCheckAgents.swift) to the engine that owns the session. Only
// engines that adopt it (ACP agents) can say yes; a session the router does not know is never decided by Ensemble, so
// its prompts are shown as they come.
extension EngineRouter: EngineAgentPermissionSupport {
    public func decidesAutoPrompts(for sessionID: String) -> Bool {
        guard let owner = ownerID(ofSession: sessionID),
              let engine = registration(id: owner)?.engine as? any EngineAgentPermissionSupport else { return false }
        return engine.decidesAutoPrompts(for: sessionID)
    }

    public func autoPromptSubject(forPermission requestID: String, sessionID: String) async -> AgentPermissionSubject? {
        guard let engine = await registration(forSession: sessionID)?.engine as? any EngineAgentPermissionSupport else { return nil }
        return await engine.autoPromptSubject(forPermission: requestID, sessionID: sessionID)
    }
}
