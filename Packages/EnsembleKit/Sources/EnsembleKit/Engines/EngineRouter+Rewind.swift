import Foundation

// Forwards rewind with choices (`Store/RewindModels.swift`) to the engine that owns each session. An engine with only
// `EngineHistoryControl` gets its one behaviour without a file list; an engine with neither (Gemini today) gets a plan
// whose choices are all unavailable, with the reason. Kept in its own file because the protocol is new; delete this
// file if it moves or is renamed.
extension EngineRouter: EngineRewindControl {
    public func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        if let control = registration.engine as? any EngineRewindControl {
            return try await control.rewindPlan(sessionID, toBeforeMessageID: messageID)
        }
        if let history = registration.engine as? any EngineHistoryControl {
            let items = (try? await registration.engine.transcript(sessionID)) ?? []
            return .basic(restoresFiles: history.rewindRestoresFiles, messagesRemoved: Self.userMessages(in: items, from: messageID))
        }
        return .unavailable(RewindReason.noRewind(registration.name))
    }

    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        if let control = registration.engine as? any EngineRewindControl {
            return try await control.rewind(sessionID, toBeforeMessageID: messageID, scope: scope)
        }
        guard let history = registration.engine as? any EngineHistoryControl else {
            throw EngineRouterError.notSupported(engine: registration.name, feature: "rewind")
        }
        let plan = RewindPlan.basic(restoresFiles: history.rewindRestoresFiles, messagesRemoved: 0)
        if let reason = plan.choice(scope).unavailableReason {
            throw EngineRouterError.notSupported(engine: registration.name, feature: reason.lowercased())
        }
        let items = (try? await registration.engine.transcript(sessionID)) ?? []
        try await history.rewind(sessionID, toBeforeMessageID: messageID)
        return RewindOutcome(scope: scope, messagesRemoved: Self.userMessages(in: items, from: messageID), canRedo: false)
    }

    public func redoRewind(_ sessionID: String) async throws {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        guard let control = registration.engine as? any EngineRewindControl else {
            throw EngineRouterError.notSupported(engine: registration.name, feature: "undo a rewind")
        }
        try await control.redoRewind(sessionID)
    }

    /// Your messages from `messageID` to the end of a transcript.
    static func userMessages(in items: [TranscriptItem], from messageID: String) -> Int {
        let users = items.compactMap { item -> String? in
            if case .user(let id, _, _) = item { return id }
            return nil
        }
        guard let index = users.firstIndex(of: messageID) else { return 0 }
        return users.count - index
    }
}
