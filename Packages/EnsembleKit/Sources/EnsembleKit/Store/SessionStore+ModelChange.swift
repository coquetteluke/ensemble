import Foundation

/// What happened when a model was picked for a session (`SessionStore.changeModel`).
public enum ModelChangeResult: Equatable, Sendable {
    /// The session runs the new model now.
    case switched
    /// The model runs on another engine and the session was empty: it was started over on that engine, in the same
    /// folder and permission mode, and the empty one was deleted. The caller moves its draft to `to`.
    case restarted(from: String, to: String)
    /// The model runs on another engine and the session has history, which cannot move. The caller offers to start a
    /// new session with the model (`startSession(like:model:)`).
    case needsNewSession(EngineChange)
    /// The switch failed (`lastError` says why).
    case failed
}

extension SessionStore {
    /// Picks a model for a session. A model of the session's own engine is switched in place. A model of another
    /// engine starts an empty session over on that engine, and for a session with history returns `.needsNewSession`
    /// instead of failing.
    public func changeModel(_ model: ModelRef, for sessionID: String) async -> ModelChangeResult {
        guard let session = byID[sessionID] else { return .failed }
        guard let check = engine as? any EngineModelChangeCheck,
              let change = await check.engineChange(forSession: sessionID, to: model) else {
            let before = lastError
            lastError = nil
            await switchModel(model, for: sessionID)
            if lastError != nil { return .failed }
            lastError = before
            return .switched
        }
        guard await canStartOver(session) else { return .needsNewSession(change) }
        do {
            let worktree = worktree(for: sessionID)
            let replacement = try await newSession(directory: session.directory, model: model, permissionMode: session.permissionMode)
            if var worktree {
                // The copy goes with the session that replaces the empty one.
                worktree.sessionID = replacement.id
                worktrees.upsert(worktree)
            }
            if let extra = extraFolders[sessionID] { extraFolders[replacement.id] = extra }
            await delete(sessionID)
            return .restarted(from: sessionID, to: replacement.id)
        } catch {
            lastError = "Could not start a session with \(modelName(model)): \(error.localizedDescription)"
            return .failed
        }
    }

    /// A new session with `model` in the same project folder and permission mode as `sessionID`, selected. The old
    /// session stays as it is (a session in its own copy keeps the copy; the new one starts in the project folder).
    @discardableResult
    public func startSession(like sessionID: String, model: ModelRef) async -> SessionModel? {
        guard let session = byID[sessionID] else { return nil }
        do {
            let replacement = try await newSession(directory: projectFolder(for: session), model: model,
                                                   permissionMode: session.permissionMode)
            if let extra = extraFolders[sessionID] { extraFolders[replacement.id] = extra }
            return replacement
        } catch {
            lastError = "Could not start a session with \(modelName(model)): \(error.localizedDescription)"
            return nil
        }
    }

    /// True for a top-level, idle session with nothing in it yet: no messages, no prompts, no queue, no subagents,
    /// and not an agent of a room.
    func canStartOver(_ session: SessionModel) async -> Bool {
        guard !session.isSubagent, !session.isWorking, session.pendingPermissions.isEmpty,
              queue(for: session.id).isEmpty, (sessionAgentIDs[session.id] ?? []).isEmpty,
              children(of: session.id).isEmpty else { return false }
        if !session.transcriptLoaded { await loadSession(session.id) }
        return !session.items.contains { item in
            switch item {
            case .notice, .error: false
            default: true
            }
        }
    }
}
