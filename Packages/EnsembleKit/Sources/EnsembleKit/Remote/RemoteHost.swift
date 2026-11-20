import Foundation

/// What the Mac app gives the RemoteServer: its current state, a stream of live changes, and the actions
/// the phone can take. The Mac app's shared state implements this (a `@MainActor` class works, since every
/// requirement is async). `DemoRemoteHost` is an in-memory version for tests and previews.
public protocol RemoteHost: AnyObject, Sendable {
    /// Every Session Hub row plus the open permission prompts.
    func hubSnapshot() async -> RemoteHubSnapshot
    /// One chat (a session, or a room's combined transcript, by the hub row id). Throw if it does not exist.
    func transcript(sessionID: String) async throws -> RemoteTranscript
    func rooms() async -> [RemoteRoom]
    func usageSummary() async -> RemoteUsageSummary

    /// Live changes. The server calls this once per start and fans the updates out to every phone.
    /// Each call returns a new stream; the stream ends when the server stops reading it.
    func updates() async -> AsyncStream<RemoteUpdate>

    /// Sends a user message. In a room, `agent` (a name) addresses one agent; `nil` talks to the room.
    func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws
    func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws
    func interrupt(_ target: RemoteTarget) async throws
    func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws
    /// Answers a question asked in `sessionID`; empty `answers` declines. Must refuse a request of another session.
    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws
    /// Proceed or Keep planning on a plan of `sessionID`. Must refuse a request of another session, and a mode the plan
    /// does not offer.
    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws
    /// Answers what a room waits on (`RemoteRoom.decision`). Must refuse a decision id that is no longer open, a choice
    /// the decision does not offer, and a missing text the choice requires.
    func decideRoom(_ reply: RemoteRoomDecisionReply) async throws
    /// Switches or stages a model in `request.sessionID`.
    func changeModel(_ request: RemoteChangeModel) async throws
    /// Creates a new solo session and returns its Hub summary.
    func createSession(_ request: RemoteCreateSession) async throws -> SessionSummary
    /// Creates a new multi-agent room and returns its remote representation.
    func createRoom(_ request: RemoteCreateRoom) async throws -> RemoteRoom
    /// Returns the working-tree git diff for `sessionID`.
    func sessionDiff(sessionID: String) async throws -> RemoteSessionDiff
    /// Requests a second opinion on a completed assistant reply.
    func requestSecondOpinion(_ request: RemoteSecondOpinionRequest) async throws
    /// Archives or unarchives a solo session.
    func archiveSession(sessionID: String, archived: Bool) async throws
}

public extension RemoteHost {
    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot answer questions from the iPhone.")
    }

    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot review plans from the iPhone.")
    }

    func decideRoom(_ reply: RemoteRoomDecisionReply) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot answer room decisions from the iPhone.")
    }

    func changeModel(_ request: RemoteChangeModel) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot change models from the iPhone.")
    }

    func createSession(_ request: RemoteCreateSession) async throws -> SessionSummary {
        throw RemoteError(.unknownMessage, "This Mac cannot create sessions from the iPhone.")
    }

    func createRoom(_ request: RemoteCreateRoom) async throws -> RemoteRoom {
        throw RemoteError(.unknownMessage, "This Mac cannot create rooms from the iPhone.")
    }

    func sessionDiff(sessionID: String) async throws -> RemoteSessionDiff {
        throw RemoteError(.unknownMessage, "This Mac cannot show diffs on the iPhone.")
    }

    func requestSecondOpinion(_ request: RemoteSecondOpinionRequest) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot request second opinions from the iPhone.")
    }

    func archiveSession(sessionID: String, archived: Bool) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot archive sessions from the iPhone.")
    }
}

/// An action the phone asked for, as `DemoRemoteHost` records it.
public enum RemoteHostAction: Hashable, Sendable {
    case sendMessage(text: String, target: RemoteTarget, agent: String?)
    case replyPermission(sessionID: String, requestID: String, decision: PermissionDecision)
    case setPermissionMode(mode: PermissionMode, target: RemoteTarget)
    case interrupt(target: RemoteTarget)
    case controlRoom(roomID: UUID, action: RemoteRoomAction)
    case answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer])
    case respondToPlan(sessionID: String, requestID: String, decision: PlanDecision)
    case decideRoom(RemoteRoomDecisionReply)
    case changeModel(RemoteChangeModel)
    case createSession(RemoteCreateSession)
    case createRoom(RemoteCreateRoom)
    case sessionDiff(sessionID: String)
    case requestSecondOpinion(RemoteSecondOpinionRequest)
    case archiveSession(sessionID: String, archived: Bool)
}

/// In-memory `RemoteHost` with sample data. Records every action and applies it to its own state the way
/// the Mac app would, emitting the matching live updates.
public actor DemoRemoteHost: RemoteHost {
    public private(set) var sessions: [SessionSummary]
    public private(set) var permissions: [PermissionRequest]
    public private(set) var transcripts: [String: RemoteTranscript]
    public private(set) var roomList: [RemoteRoom]
    public private(set) var usage: RemoteUsageSummary
    public private(set) var availableModels: [RemoteModelOption]
    public private(set) var recentFolders: [String]
    public private(set) var diffs: [String: RemoteSessionDiff]
    /// Every action received, oldest first.
    public private(set) var recordedActions: [RemoteHostAction] = []

    private var continuations: [UUID: AsyncStream<RemoteUpdate>.Continuation] = [:]
    private var stagedModels: [String: (providerID: String, modelID: String, name: String)] = [:]
    private var counter = 0

    public init(data: RemoteDemoData = .sample()) {
        sessions = data.sessions
        permissions = data.permissions
        transcripts = data.transcripts
        roomList = data.rooms
        usage = data.usage
        availableModels = data.availableModels
        recentFolders = data.recentFolders
        diffs = data.diffs
    }

    // MARK: RemoteHost

    public func hubSnapshot() async -> RemoteHubSnapshot {
        RemoteHubSnapshot(sessions: sessions, permissions: permissions,
                          availableModels: availableModels, recentFolders: recentFolders)
    }

    public func transcript(sessionID: String) async throws -> RemoteTranscript {
        guard let t = transcripts[sessionID] else { throw RemoteError(.notFound, "No session \(sessionID)") }
        return t
    }

    public func rooms() async -> [RemoteRoom] { roomList }

    public func usageSummary() async -> RemoteUsageSummary { usage }

    public func updates() async -> AsyncStream<RemoteUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RemoteUpdate>.makeStream(bufferingPolicy: .bufferingNewest(512))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws {
        recordedActions.append(.sendMessage(text: text, target: target, agent: agent))
        let sessionID: String
        switch target {
        case .session(let id): sessionID = id
        case .room(let roomID):
            guard let room = roomList.first(where: { $0.id == roomID }) else { throw RemoteError(.notFound, "No room") }
            if let agent, !room.agents.contains(where: { $0.name.caseInsensitiveCompare(agent) == .orderedSame }) {
                throw RemoteError(.badRequest, "This room has no agent named \(agent).")
            }
            sessionID = room.sessionID
        }
        guard transcripts[sessionID] != nil else { throw RemoteError(.notFound, "No session \(sessionID)") }
        if let staged = stagedModels.removeValue(forKey: sessionID) {
            transcripts[sessionID]?.modelProviderID = staged.providerID
            transcripts[sessionID]?.modelID = staged.modelID
            transcripts[sessionID]?.pendingModelName = nil
            if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[i].modelProviderID = staged.providerID
                sessions[i].modelID = staged.modelID
                sessions[i].pendingModelName = nil
                sessions[i].lastActivity = Date()
                emit(.sessionUpserted(session: sessions[i]))
            }
            let notice = TranscriptItem.notice(id: nextID("notice"), text: "Switched to \(staged.name) for this message")
            transcripts[sessionID]?.items.append(notice)
            emit(.transcriptUpsert(sessionID: sessionID, item: notice))
        }
        let shown = agent.map { "@\($0) \(text)" } ?? text
        let item = TranscriptItem.user(id: nextID("user"), text: shown, date: Date())
        transcripts[sessionID]?.items.append(item)
        emit(.transcriptUpsert(sessionID: sessionID, item: item))
        setActivity(.working, sessionID: sessionID)
        if let t = transcripts[sessionID] {
            emit(.transcriptUpdated(transcript: t))
        }
    }

    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws {
        recordedActions.append(.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision))
        guard permissions.contains(where: { $0.id == requestID }) else {
            throw RemoteError(.notFound, "That permission prompt was already answered")
        }
        permissions.removeAll { $0.id == requestID }
        emit(.permissionReplied(sessionID: sessionID, requestID: requestID, decision: decision))
        for r in roomList.indices where roomList[r].permissions.contains(where: { $0.id == requestID }) {
            roomList[r].permissions.removeAll { $0.id == requestID }
            emit(.roomUpserted(room: roomList[r]))
            upsertRoomRow(roomList[r])
        }
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[i].pendingPermissions = max(0, sessions[i].pendingPermissions - 1)
            if sessions[i].pendingPermissions == 0 {
                sessions[i].pendingAsk = nil
                sessions[i].activity = decision == .reject ? .idle : .working
            }
            sessions[i].lastActivity = Date()
            emit(.sessionUpserted(session: sessions[i]))
        }
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        recordedActions.append(.answerQuestion(sessionID: sessionID, requestID: requestID, answers: answers))
        guard let request = permissions.first(where: { $0.id == requestID && $0.sessionID == sessionID }), request.isQuestion else {
            throw RemoteError(.notFound, "That question was already answered")
        }
        settle(request, decision: answers.isEmpty ? .reject : .once, working: !answers.isEmpty)
    }

    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws {
        recordedActions.append(.respondToPlan(sessionID: sessionID, requestID: requestID, decision: decision))
        guard let request = permissions.first(where: { $0.id == requestID && $0.sessionID == sessionID }), let plan = request.plan else {
            throw RemoteError(.notFound, "That plan was already answered")
        }
        if case .proceed(let mode) = decision {
            guard plan.allowedProceedModes.contains(mode) else { throw RemoteError(.badRequest, "That plan cannot proceed in \(mode.label)") }
            transcripts[sessionID]?.permissionMode = mode
            emit(.permissionModeChanged(target: .session(sessionID), mode: mode))
        }
        settle(request, decision: nil, working: true)
    }

    /// Removes an answered plan or question and updates its Hub row, as the Mac would.
    private func settle(_ request: PermissionRequest, decision: PermissionDecision?, working: Bool) {
        permissions.removeAll { $0.id == request.id }
        emit(.permissionReplied(sessionID: request.sessionID, requestID: request.id, decision: decision))
        if let i = sessions.firstIndex(where: { $0.id == request.sessionID }) {
            sessions[i].pendingPermissions = max(0, sessions[i].pendingPermissions - 1)
            if sessions[i].pendingPermissions == 0 {
                sessions[i].pendingAsk = nil
                sessions[i].activity = working ? .working : .idle
            }
            sessions[i].lastActivity = Date()
            emit(.sessionUpserted(session: sessions[i]))
        }
    }

    public func decideRoom(_ reply: RemoteRoomDecisionReply) async throws {
        recordedActions.append(.decideRoom(reply))
        guard let i = roomList.firstIndex(where: { $0.id == reply.roomID }) else { throw RemoteError(.notFound, "No room") }
        guard let decision = roomList[i].decision, decision.id == reply.decisionID else {
            throw RemoteError(.notFound, "That decision is no longer open in the room.")
        }
        guard let choice = decision.choices.first(where: { $0.id == reply.choice }) else {
            throw RemoteError(.badRequest, "That answer is not offered for this decision.")
        }
        let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if choice.input == .required && text.isEmpty { throw RemoteError(.badRequest, "Write your answer first.") }
        roomList[i].decision = nil
        roomList[i].state = .running
        roomList[i].phaseLabel = "Working"
        roomList[i].lastActivity = Date()
        emit(.roomUpserted(room: roomList[i]))
        upsertRoomRow(roomList[i])
        let sessionID = roomList[i].sessionID
        emit(.transcriptUpsert(sessionID: sessionID, item: .notice(id: nextID("notice"), text: "You chose \(choice.label).")))
        setActivity(.working, sessionID: sessionID)
    }

    /// Keeps a room's Session Hub row in step with the room.
    private func upsertRoomRow(_ room: RemoteRoom) {
        guard let i = sessions.firstIndex(where: { $0.id == room.sessionID }) else { return }
        var row = RemoteRoomBridge.hubRow(room)
        row.usage = sessions[i].usage
        emit(.sessionUpserted(session: row))
    }

    public func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        recordedActions.append(.setPermissionMode(mode: mode, target: target))
        switch target {
        case .session(let id):
            transcripts[id]?.permissionMode = mode
        case .room(let roomID):
            if let i = roomList.firstIndex(where: { $0.id == roomID }) {
                roomList[i].permissionMode = mode
                transcripts[roomList[i].sessionID]?.permissionMode = mode
                emit(.roomUpserted(room: roomList[i]))
            }
        }
        emit(.permissionModeChanged(target: target, mode: mode))
    }

    public func interrupt(_ target: RemoteTarget) async throws {
        recordedActions.append(.interrupt(target: target))
        switch target {
        case .session(let id): setActivity(.idle, sessionID: id)
        case .room(let roomID):
            if let room = roomList.first(where: { $0.id == roomID }) { setActivity(.idle, sessionID: room.sessionID) }
        }
    }

    public func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws {
        recordedActions.append(.controlRoom(roomID: roomID, action: action))
        guard let i = roomList.firstIndex(where: { $0.id == roomID }) else { throw RemoteError(.notFound, "No room") }
        switch action {
        case .pause: roomList[i].state = .paused
        case .resume: roomList[i].state = .running
        case .stop: roomList[i].state = .stopped
        }
        emit(.roomUpserted(room: roomList[i]))
        setActivity(action == .resume ? .working : .idle, sessionID: roomList[i].sessionID)
    }

    public func changeModel(_ request: RemoteChangeModel) async throws {
        recordedActions.append(.changeModel(request))
        guard var transcript = transcripts[request.sessionID] else {
            throw RemoteError(.notFound, "No session \(request.sessionID)")
        }
        let option = availableModels.first { $0.providerID == request.providerID && $0.modelID == request.modelID }
        let displayName = option?.name ?? request.modelID
        let hasHistory = !transcript.items.isEmpty
        if hasHistory {
            stagedModels[request.sessionID] = (request.providerID, request.modelID, displayName)
            transcript.pendingModelName = displayName
        } else {
            stagedModels.removeValue(forKey: request.sessionID)
            transcript.modelProviderID = request.providerID
            transcript.modelID = request.modelID
            transcript.pendingModelName = nil
        }
        transcripts[request.sessionID] = transcript
        if let i = sessions.firstIndex(where: { $0.id == request.sessionID }) {
            if hasHistory {
                sessions[i].pendingModelName = displayName
            } else {
                sessions[i].modelProviderID = request.providerID
                sessions[i].modelID = request.modelID
                sessions[i].pendingModelName = nil
            }
            emit(.sessionUpserted(session: sessions[i]))
        }
        emit(.transcriptUpdated(transcript: transcript))
    }

    public func createSession(_ request: RemoteCreateSession) async throws -> SessionSummary {
        recordedActions.append(.createSession(request))
        let dir = request.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { throw RemoteError(.badRequest, "Pick a project folder first.") }
        let rawTitle = (request.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "New session" : rawTitle
        let id = nextID("demo-session")
        let summary = SessionSummary(
            id: id, title: title, directory: dir, activity: .idle, lastActivity: Date(),
            modelProviderID: request.providerID, modelID: request.modelID
        )
        let transcript = RemoteTranscript(
            sessionID: id, title: title, items: [], activity: .idle, permissionMode: .ask,
            modelProviderID: request.providerID, modelID: request.modelID
        )
        sessions.insert(summary, at: 0)
        transcripts[id] = transcript
        if !recentFolders.contains(dir) { recentFolders.insert(dir, at: 0) }
        emit(.sessionUpserted(session: summary))
        emit(.hubUpdated(hub: await hubSnapshot()))
        return summary
    }

    public func createRoom(_ request: RemoteCreateRoom) async throws -> RemoteRoom {
        recordedActions.append(.createRoom(request))
        let dir = request.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { throw RemoteError(.badRequest, "Pick a project folder first.") }
        guard !title.isEmpty else { throw RemoteError(.badRequest, "Give the room a title.") }
        guard !request.agents.isEmpty else { throw RemoteError(.badRequest, "Add at least one agent.") }
        let palette = ["#D97757", "#6A9BCC", "#788C5D", "#9B7BD4"]
        let roomID = UUID()
        let sessionID = RemoteRoomBridge.sessionID(for: roomID)
        let agents: [RemoteAgent] = request.agents.enumerated().map { idx, spec in
            RemoteAgent(
                id: UUID(), name: spec.name, model: "\(spec.providerID)/\(spec.modelID)",
                colorHex: palette[idx % palette.count], activity: .idle,
                sessionID: nextID("demo-room-agent")
            )
        }
        let room = RemoteRoom(
            id: roomID, title: title, directory: dir, mode: request.mode, agents: agents,
            leadAgentID: agents.first?.id, state: .running, permissionMode: .ask,
            sessionID: sessionID, lastActivity: Date(), phaseLabel: "Starting"
        )
        roomList.insert(room, at: 0)
        let row = RemoteRoomBridge.hubRow(room)
        sessions.insert(row, at: 0)
        transcripts[sessionID] = RemoteTranscript(
            sessionID: sessionID, title: title, items: [], activity: .idle,
            permissionMode: .ask, roomID: roomID, agents: agents
        )
        if !recentFolders.contains(dir) { recentFolders.insert(dir, at: 0) }
        emit(.roomUpserted(room: room))
        emit(.sessionUpserted(session: row))
        emit(.hubUpdated(hub: await hubSnapshot()))
        return room
    }

    public func sessionDiff(sessionID: String) async throws -> RemoteSessionDiff {
        recordedActions.append(.sessionDiff(sessionID: sessionID))
        if let existing = diffs[sessionID] { return existing }
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw RemoteError(.notFound, "No session \(sessionID)")
        }
        return RemoteSessionDiff(sessionID: sessionID, directory: session.directory, files: [], truncated: false)
    }

    public func requestSecondOpinion(_ request: RemoteSecondOpinionRequest) async throws {
        recordedActions.append(.requestSecondOpinion(request))
        guard var transcript = transcripts[request.sessionID] else {
            throw RemoteError(.notFound, "No session \(request.sessionID)")
        }
        let option = availableModels.first { $0.providerID == request.providerID && $0.modelID == request.modelID }
        let modelName = option?.name ?? request.modelID
        let makerName = option?.makerName ?? request.providerID
        let opinion = RemoteSecondOpinion(
            id: UUID(),
            itemID: request.itemID,
            modelName: modelName,
            makerName: makerName,
            status: "ready",
            verdict: "Looks solid",
            summary: "\(modelName) reviewed this reply and agrees with the main fix.",
            concerns: ["Double check edge cases with a quick regression test."],
            details: "Reviewed assistant reply \(request.itemID) in demo mode."
        )
        transcript.secondOpinions.append(opinion)
        transcripts[request.sessionID] = transcript
        emit(.transcriptUpdated(transcript: transcript))
    }

    public func archiveSession(sessionID: String, archived: Bool) async throws {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw RemoteError(.notFound, "No session \(sessionID)")
        }
        guard sessions[idx].roomID == nil else {
            throw RemoteError(.badRequest, "Rooms cannot be archived from here.")
        }
        recordedActions.append(.archiveSession(sessionID: sessionID, archived: archived))
        sessions[idx].archived = archived
        emit(.sessionUpserted(session: sessions[idx]))
    }

    // MARK: Driving it from tests and previews

    /// Pushes an update to every subscriber and applies it to the demo state.
    public func emit(_ update: RemoteUpdate) {
        apply(update)
        for c in continuations.values { c.yield(update) }
    }

    /// Number of live update streams (the server holds one while running).
    public var subscriberCount: Int { continuations.count }

    private func apply(_ update: RemoteUpdate) {
        switch update {
        case .sessionUpserted(let s):
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
        case .transcriptUpsert(let sid, let item):
            if let i = transcripts[sid]?.items.firstIndex(where: { $0.id == item.id }) {
                transcripts[sid]?.items[i] = item
            } else if transcripts[sid]?.items.contains(item) == false {
                transcripts[sid]?.items.append(item)
            }
        case .activity(let sid, let a):
            transcripts[sid]?.activity = a
            if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].activity = a }
        case .permissionAsked(let p):
            if !permissions.contains(where: { $0.id == p.id }) { permissions.append(p) }
        case .roomUpserted(let r):
            if let i = roomList.firstIndex(where: { $0.id == r.id }) { roomList[i] = r } else { roomList.append(r) }
        case .roomRemoved(let id):
            roomList.removeAll { $0.id == id }
        case .usageSummary(let u):
            usage = u
        case .usage(let sid, let u):
            if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].usage = u }
        case .hubUpdated(let hub):
            sessions = hub.sessions
            permissions = hub.permissions
            availableModels = hub.availableModels
            recentFolders = hub.recentFolders
        case .transcriptUpdated(let t):
            transcripts[t.sessionID] = t
        case .sessionReplaced(let oldID, let newSession):
            sessions.removeAll { $0.id == oldID }
            if let i = sessions.firstIndex(where: { $0.id == newSession.id }) {
                sessions[i] = newSession
            } else {
                sessions.insert(newSession, at: 0)
            }
        case .textDelta, .permissionReplied, .permissionModeChanged:
            break
        }
    }

    private func setActivity(_ activity: SessionActivity, sessionID: String) {
        emit(.activity(sessionID: sessionID, activity: activity))
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)-\(UUID().uuidString.prefix(6))"
    }
}
