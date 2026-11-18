import Foundation
import Synchronization
import EnsembleKit

/// Wraps an engine so every room shares one live event connection.
///
/// `OpenCodeClient.events()` opens a new `GET /api/event` connection per call, and URLSession allows 6
/// connections per host (checked against OpenCode 2.3: of 9 streams on one client, only 6 connected). The
/// session store, the remote host, the rooms controller and every open `RoomEngine` each call `events()`, so the
/// fourth or fifth open room would silently get no events. Here one upstream stream fans out to any number of
/// subscribers. Every other call goes straight to the wrapped engine, including the optional abilities (history,
/// rewind with choices, effort, commands, billing, steering, session rules, folder models, worktree access): a call the wrapped engine
/// cannot serve fails as it would on an engine router without that ability.
final class SharedEventsAPI: OpenCodeAPI, Sendable {
    let base: any OpenCodeAPI

    private struct Hub {
        var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
        /// The running upstream and its id (a finished pump only clears its own entry).
        var upstream: (id: UUID, task: Task<Void, Never>)?
        var connectedOnce = false
    }

    private let hub = Mutex(Hub())

    init(base: any OpenCodeAPI) {
        self.base = base
    }

    /// Subscribers currently listening (for tests and diagnostics).
    var subscriberCount: Int { hub.withLock { $0.subscribers.count } }

    func events() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(20_000))
        let id = UUID()
        let joinedLate = hub.withLock { state -> Bool in
            state.subscribers[id] = continuation
            startUpstreamIfNeeded(&state)
            return state.connectedOnce
        }
        // Late subscribers missed the connect event; it tells them to refresh their state.
        if joinedLate { continuation.yield(.other(type: "server.connected")) }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return stream
    }

    private func startUpstreamIfNeeded(_ state: inout Hub) {
        guard state.upstream == nil, !state.subscribers.isEmpty else { return }
        let id = UUID()
        state.upstream = (id, Task { [weak self] in await self?.pump(id) })
    }

    private func pump(_ id: UUID) async {
        for await event in base.events() {
            let targets = hub.withLock { state -> [AsyncStream<EngineEvent>.Continuation] in
                guard state.upstream?.id == id else { return [] }
                if case .other(let type) = event, type == "server.connected" { state.connectedOnce = true }
                return Array(state.subscribers.values)
            }
            for continuation in targets { continuation.yield(event) }
        }
        // The engine's stream ends only when cancelled. If it ended on its own, end the subscribers' streams too,
        // as the engine would have.
        let ended = hub.withLock { state -> [AsyncStream<EngineEvent>.Continuation] in
            guard state.upstream?.id == id else { return [] }
            state.upstream = nil
            state.connectedOnce = false
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for continuation in ended { continuation.finish() }
    }

    private func unsubscribe(_ id: UUID) {
        let task = hub.withLock { state -> Task<Void, Never>? in
            state.subscribers[id] = nil
            guard state.subscribers.isEmpty, let upstream = state.upstream else { return nil }
            state.upstream = nil
            state.connectedOnce = false
            return upstream.task
        }
        task?.cancel()
    }

    // MARK: Forwarded calls

    func serverInfo() async throws -> (version: String, url: URL) { try await base.serverInfo() }
    func listSessions() async throws -> [EngineSession] { try await base.listSessions() }
    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                       parentID: String?) async throws -> EngineSession {
        try await base.createSession(directory: directory, model: model, agent: agent, permissionMode: permissionMode, parentID: parentID)
    }
    func deleteSession(_ sessionID: String) async throws { try await base.deleteSession(sessionID) }
    func renameSession(_ sessionID: String, title: String) async throws { try await base.renameSession(sessionID, title: title) }
    func setArchived(_ sessionID: String, archived: Bool) async throws { try await base.setArchived(sessionID, archived: archived) }
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { try await base.setPermissionMode(sessionID, mode: mode) }
    func switchModel(_ sessionID: String, model: ModelRef) async throws { try await base.switchModel(sessionID, model: model) }
    func transcript(_ sessionID: String) async throws -> [TranscriptItem] { try await base.transcript(sessionID) }
    func children(_ sessionID: String) async throws -> [EngineSession] { try await base.children(sessionID) }
    func prompt(_ sessionID: String, text: String, files: [URL]) async throws { try await base.prompt(sessionID, text: text, files: files) }
    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        try await base.injectSynthetic(sessionID, text: text, wake: wake)
    }
    func interrupt(_ sessionID: String) async throws { try await base.interrupt(sessionID) }
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await base.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision, message: message)
    }
    func pendingPermissions() async throws -> [PermissionRequest] { try await base.pendingPermissions() }
    func context(_ sessionID: String) async throws -> ContextBreakdown { try await base.context(sessionID) }
    func changedFiles(_ sessionID: String) async throws -> [FileChange] { try await base.changedFiles(sessionID) }
    func connectors() async throws -> [ConnectorInfo] { try await base.connectors() }
    func models() async throws -> [ModelInfo] { try await base.models() }
    func providers() async throws -> [ProviderInfo] { try await base.providers() }
    func setAPIKey(providerID: String, key: String) async throws { try await base.setAPIKey(providerID: providerID, key: key) }
    func removeAPIKey(providerID: String) async throws { try await base.removeAPIKey(providerID: providerID) }
    func schedules() async throws -> [ScheduleInfo] { try await base.schedules() }
    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        try await base.createSchedule(title: title, prompt: prompt, directory: directory, schedule: schedule, model: model)
    }
    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { try await base.setSchedulePaused(scheduleID, paused: paused) }
    func deleteSchedule(_ scheduleID: String) async throws { try await base.deleteSchedule(scheduleID) }
}

// MARK: Optional abilities

extension SharedEventsAPI {
    /// The wrapped engine as `C`, or the error an engine router gives for an engine without that ability.
    private func ability<C>(_ type: C.Type, _ feature: String) throws -> C {
        guard let control = base as? C else {
            throw EngineRouterError.notSupported(engine: String(describing: Swift.type(of: base)), feature: feature)
        }
        return control
    }
}

extension SharedEventsAPI: EngineHistoryControl, EngineForkAvailability {
    func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        try await ability((any EngineHistoryControl).self, "be forked").fork(sessionID, atMessageID: messageID)
    }

    func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws {
        try await ability((any EngineHistoryControl).self, "be rewound").rewind(sessionID, toBeforeMessageID: messageID)
    }

    var rewindRestoresFiles: Bool { (base as? any EngineHistoryControl)?.rewindRestoresFiles ?? false }

    func canFork(_ sessionID: String) -> Bool {
        if let availability = base as? any EngineForkAvailability { return availability.canFork(sessionID) }
        return base is any EngineHistoryControl
    }
}

/// Rewind with choices (`Store/RewindModels.swift`), so room sessions get the full rewind sheet. The wrapped engine router
/// answers for engines without it (one choice, or none with the reason).
extension SharedEventsAPI: EngineRewindControl {
    func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan {
        if let control = base as? any EngineRewindControl {
            return try await control.rewindPlan(sessionID, toBeforeMessageID: messageID)
        }
        if let history = base as? any EngineHistoryControl {
            return .basic(restoresFiles: history.rewindRestoresFiles, messagesRemoved: 0)
        }
        return .unavailable("This engine cannot rewind")
    }

    func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome {
        try await ability((any EngineRewindControl).self, "be rewound").rewind(sessionID, toBeforeMessageID: messageID, scope: scope)
    }

    func redoRewind(_ sessionID: String) async throws {
        try await ability((any EngineRewindControl).self, "undo a rewind").redoRewind(sessionID)
    }
}

extension SharedEventsAPI: EngineModelOptionsControl {
    func modelOptions(for model: ModelRef) async throws -> ModelOptions {
        try await ability((any EngineModelOptionsControl).self, "change effort or fast mode").modelOptions(for: model)
    }

    func setEffort(_ sessionID: String, effort: EffortLevel?) async throws {
        try await ability((any EngineModelOptionsControl).self, "change effort").setEffort(sessionID, effort: effort)
    }

    func setFastMode(_ sessionID: String, enabled: Bool) async throws {
        try await ability((any EngineModelOptionsControl).self, "use fast mode").setFastMode(sessionID, enabled: enabled)
    }
}

extension SharedEventsAPI: EngineCommandsControl {
    func commands(directory: String?) async throws -> [EngineCommand] {
        guard let control = base as? any EngineCommandsControl else { return [] }
        return try await control.commands(directory: directory)
    }

    func runCommand(_ sessionID: String, name: String, arguments: String) async throws {
        try await ability((any EngineCommandsControl).self, "run slash commands").runCommand(sessionID, name: name, arguments: arguments)
    }
}

extension SharedEventsAPI: EngineModelBilling {
    func modelBilling() async throws -> [String: ModelBilling] {
        guard let billing = base as? any EngineModelBilling else { return [:] }
        return try await billing.modelBilling()
    }
}

extension SharedEventsAPI: EngineSteeringControl {
    func steer(_ sessionID: String, text: String, files: [URL]) async throws {
        try await ability((any EngineSteeringControl).self, "take messages during a turn").steer(sessionID, text: text, files: files)
    }

    func canSteer(_ sessionID: String) -> Bool { (base as? any EngineSteeringControl)?.canSteer(sessionID) ?? false }

    func queuedDelivery(for sessionID: String) -> QueuedDelivery {
        (base as? any EngineSteeringControl)?.queuedDelivery(for: sessionID) ?? .inOrder
    }
}

extension SharedEventsAPI: EngineSessionRulesReading {
    func permissionRules(_ sessionID: String) async throws -> [PermissionRule] {
        try await ability((any EngineSessionRulesReading).self, "report their permission rules").permissionRules(sessionID)
    }
}

extension SharedEventsAPI: EngineFolderModels {
    func models(directory: String?) async throws -> [ModelInfo] {
        guard let folders = base as? any EngineFolderModels else { return try await base.models() }
        return try await folders.models(directory: directory)
    }
}

extension SharedEventsAPI: EngineWorktreeAccess {
    func allowWorktreeEdits(_ sessionID: String, worktreePath: String) async throws -> Bool {
        guard let access = base as? any EngineWorktreeAccess else { return false }
        return try await access.allowWorktreeEdits(sessionID, worktreePath: worktreePath)
    }
}
