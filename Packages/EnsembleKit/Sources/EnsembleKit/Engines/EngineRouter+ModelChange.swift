import Foundation

/// A model that runs on a different engine than the session (a Claude model picked in an OpenCode session).
public struct EngineChange: Equatable, Sendable {
    /// "OpenCode".
    public var sessionEngine: String
    /// "Claude".
    public var modelEngine: String

    public init(sessionEngine: String, modelEngine: String) {
        self.sessionEngine = sessionEngine
        self.modelEngine = modelEngine
    }
}

/// Engines that can say, before a switch, whether a model can run in an existing session.
public protocol EngineModelChangeCheck: Sendable {
    /// Nil when `switchModel(sessionID, model:)` stays on the session's engine; otherwise which engines differ.
    func engineChange(forSession sessionID: String, to model: ModelRef) async -> EngineChange?
}

extension EngineRouter: EngineModelChangeCheck {
    /// A session stays on the engine it was created on, so a model of another engine needs a new session. The engine
    /// for untrusted folders serves the same providers as the fallback, so it counts as the same engine.
    public func engineChange(forSession sessionID: String, to model: ModelRef) async -> EngineChange? {
        guard let current = await registration(forSession: sessionID) else { return nil }
        let target = registration(forProvider: model.providerID)
        if Self.sameEngine(current: current, target: target, untrustedID: untrustedFolderRegistration?.id) { return nil }
        return EngineChange(sessionEngine: current.name, modelEngine: target.name)
    }

    static func sameEngine(current: Registration, target: Registration, untrustedID: String?) -> Bool {
        current.id == target.id || (target.isFallback && current.id == untrustedID)
    }
}
