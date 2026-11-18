import Foundation

/// Scheduled runs through the store, so they follow the same rules as sessions you start yourself: the engine router
/// picks the engine for the model, untrusted folders get the same treatment (Claude without the folder's settings,
/// OpenCode on the private server, Gemini refuses), and the transcript, permission prompts and Hub work as usual.
extension SessionStore: ScheduleRunner {
    public func scheduleRefusal(for task: ScheduledTask) -> String? {
        var model = task.model ?? defaultModel
        if let sessionID = task.continueSessionID {
            guard let session = byID[sessionID] else { return "The session it continues was deleted." }
            if isRunning(sessionID) || !(queues[sessionID] ?? []).isEmpty { return "The session it continues was busy." }
            model = session.info.model ?? model
        }
        return spendingCapRefusal(model: model)?.message
    }

    public func startScheduledRun(_ task: ScheduledTask, title: String) async throws -> ScheduleRunStart {
        if let sessionID = task.continueSessionID {
            guard let session = byID[sessionID] else { throw ScheduleRunError.sessionGone }
            var restore: PermissionMode?
            if session.permissionMode != task.permissionMode {
                restore = session.permissionMode
                await setPermissionMode(task.permissionMode, for: sessionID)
                guard session.permissionMode == task.permissionMode else { throw ScheduleRunError.modeNotSet }
            }
            await send(task.prompt, to: sessionID)
            return ScheduleRunStart(sessionID: sessionID, restoreMode: restore)
        }
        let session = try await createScheduledSession(directory: task.directory, model: task.model,
                                                       permissionMode: task.permissionMode, title: title)
        await send(task.prompt, to: session.id)
        return ScheduleRunStart(sessionID: session.id)
    }

    public func scheduledRunState(sessionID: String) -> ScheduleRunState {
        guard let session = byID[sessionID] else { return .missing }
        if needsYouCount(sessionID) > 0 { return .needsYou }
        if isRunning(sessionID) { return .working }
        if session.activity == .failed {
            let message = session.items.reversed().lazy.compactMap { item -> String? in
                if case .error(_, let text) = item { text } else { nil }
            }.first
            return .failed(message)
        }
        return .idle
    }

    public func scheduledRunDidEnd(_ run: ScheduleRun, task: ScheduledTask?) {
        guard let sessionID = run.sessionID, let restore = run.restoreMode, let applied = run.appliedMode,
              let session = byID[sessionID], session.permissionMode == applied, !isRunning(sessionID) else { return }
        Task { [weak self] in await self?.setPermissionMode(restore, for: sessionID) }
    }

    /// Creates a session for a scheduled run without selecting it (whatever you are looking at stays on screen).
    func createScheduledSession(directory: String, model: ModelRef?, permissionMode: PermissionMode,
                                title: String) async throws -> SessionModel {
        let info = try await engine.createSession(directory: directory, model: model ?? defaultModel, agent: nil,
                                                  permissionMode: permissionMode, parentID: nil)
        let session = upsertSession(info)
        session.permissionMode = permissionMode
        session.transcriptLoaded = true
        permissionRulesChecked.insert(session.id)
        await rename(session.id, to: title)
        return session
    }
}

public enum ScheduleRunError: Error, Equatable, LocalizedError {
    case sessionGone
    case modeNotSet

    public var errorDescription: String? {
        switch self {
        case .sessionGone: "The session it continues was deleted."
        case .modeNotSet: "The session's permission mode could not be set to the task's mode."
        }
    }
}
