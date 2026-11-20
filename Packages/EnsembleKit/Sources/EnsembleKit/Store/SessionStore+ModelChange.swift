import Foundation

/// What happened when a model was picked for a session (`SessionStore.changeModel`).
public enum ModelChangeResult: Equatable, Sendable {
    /// The session runs the new model now.
    case switched
    /// The model runs on another engine and the session was empty: it was started over on that engine, in the same
    /// folder and permission mode, and the empty one was deleted. The caller moves its draft to `to`.
    case restarted(from: String, to: String)
    /// The model change was staged and will take effect on the next sent message.
    case stagedForNextMessage(ModelRef)
    /// Kept for source compatibility.
    case needsNewSession(EngineChange)
    /// The switch failed (`lastError` says why).
    case failed
}

extension SessionStore {
    /// The model staged to take effect on the next message for `sessionID`, if any.
    public func stagedModel(for sessionID: String) -> ModelRef? {
        pendingNextModel[primarySessionID(for: sessionID)]
    }

    /// The model shown for `session`: the staged next-message model when present, otherwise its active model.
    public func effectiveModel(for session: SessionModel) -> ModelRef? {
        pendingNextModel[session.id] ?? session.info.model
    }

    /// Cancels any staged next-message model switch for `sessionID`.
    public func clearStagedModel(for sessionID: String) {
        pendingNextModel[primarySessionID(for: sessionID)] = nil
    }

    /// Picks a model for a session.
    /// - Empty sessions switching across engines restart cleanly on the target engine (`.restarted`).
    /// - Same-engine idle sessions without an active switch switch immediately (`.switched`).
    /// - Working same-engine sessions and cross-engine sessions with history stage the model for the next message
    ///   (`.stagedForNextMessage`). Picking the active model again clears any staged switch.
    public func changeModel(_ model: ModelRef, for sessionID: String) async -> ModelChangeResult {
        guard let session = byID[sessionID] else { return .failed }
        let primaryID = session.id
        let activeBackingID = backingSessionID(for: primaryID)
        let check = engine as? any EngineModelChangeCheck
        let change = await check?.engineChange(forSession: activeBackingID, to: model)

        if change != nil, await canStartOver(session) {
            do {
                let worktree = worktree(for: primaryID)
                let replacement = try await newSession(directory: session.directory, model: model, permissionMode: session.permissionMode)
                if var worktree {
                    // The copy goes with the session that replaces the empty one.
                    worktree.sessionID = replacement.id
                    worktrees.upsert(worktree)
                }
                if let extra = extraFolders[primaryID] { extraFolders[replacement.id] = extra }
                pendingNextModel[primaryID] = nil
                await delete(primaryID)
                return .restarted(from: primaryID, to: replacement.id)
            } catch {
                if !askToTrust(after: error, model: model, retry: .changeModel(sessionID: primaryID, model: model)) {
                    lastError = "Could not start a session with \(modelName(model)): \(error.localizedDescription)"
                }
                return .failed
            }
        }

        // Picking the model already active on the current backing session cancels any staged switch.
        if change == nil, session.info.model == model {
            pendingNextModel[primaryID] = nil
            return .switched
        }

        // Same engine as the active backing session while idle switches immediately.
        if change == nil, !session.isWorking {
            pendingNextModel[primaryID] = nil
            let before = lastError
            lastError = nil
            await switchModel(model, for: primaryID)
            if lastError != nil { return .failed }
            lastError = before
            return .switched
        }

        // Working same-engine session or cross-engine switch with history: stage for the next sent message.
        pendingNextModel[primaryID] = model
        return .stagedForNextMessage(model)
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
            if !askToTrust(after: error, model: model, retry: .startLike(sessionID: sessionID, model: model)) {
                lastError = "Could not start a session with \(modelName(model)): \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// True for a top-level, idle session with nothing in it yet: no messages, no prompts, no queue, no subagents,
    /// and not an agent of a room.
    func canStartOver(_ session: SessionModel) async -> Bool {
        guard !session.isSubagent, !session.isWorking, session.pendingPermissions.isEmpty,
              queue(for: session.id).isEmpty, (sessionAgentIDs[session.id] ?? []).isEmpty,
              children(of: session.id).isEmpty, !threadLinks.hasLinks(for: session.id) else { return false }
        if !session.transcriptLoaded { await loadSession(session.id) }
        return !session.items.contains { item in
            switch item {
            case .notice, .error: false
            default: true
            }
        }
    }
}
