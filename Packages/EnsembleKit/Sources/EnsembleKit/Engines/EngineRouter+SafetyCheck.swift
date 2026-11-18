import Foundation

// Forwards `EngineSafetyCheckSupport` (Store/SafetyCheck.swift). A session's prompts are checked only when the engine
// that owns it adopts the protocol (the OpenCode clients, shared and private); Claude and ACP sessions never are. The
// model call and the model list go to the fallback engine, the shared OpenCode service: its one-off generation uses
// the server's base configuration only, so no folder's own config is involved, and it has every credential (the private
// server for untrusted folders has no browser sign-ins).
extension EngineRouter: EngineSafetyCheckSupport {
    public func safetyCheckApplies(to sessionID: String) -> Bool {
        guard let owner = ownerID(ofSession: sessionID),
              let engine = registration(id: owner)?.engine as? any EngineSafetyCheckSupport else { return false }
        return engine.safetyCheckApplies(to: sessionID)
    }

    public func toolCallID(forPermission requestID: String, sessionID: String) async -> String? {
        guard let engine = await registration(forSession: sessionID)?.engine as? any EngineSafetyCheckSupport else { return nil }
        return await engine.toolCallID(forPermission: requestID, sessionID: sessionID)
    }

    public func generateSafetyCheckText(prompt: String, model: ModelRef) async throws -> String {
        try await safetyCheckEngine().generateSafetyCheckText(prompt: prompt, model: model)
    }

    public func safetyCheckModels() async throws -> [SafetyCheckModel] {
        try await safetyCheckEngine().safetyCheckModels()
    }

    private func safetyCheckEngine() throws -> any EngineSafetyCheckSupport {
        guard let fallback = registrations.first(where: \.isFallback),
              let engine = fallback.engine as? any EngineSafetyCheckSupport else {
            throw EngineRouterError.notSupported(engine: "This engine", feature: "run the safety check")
        }
        return engine
    }
}
