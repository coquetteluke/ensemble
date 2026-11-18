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
}

public extension RemoteHost {
    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot answer questions from the iPhone.")
    }

    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws {
        throw RemoteError(.unknownMessage, "This Mac cannot review plans from the iPhone.")
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
}

/// In-memory `RemoteHost` with sample data. Records every action and applies it to its own state the way
/// the Mac app would, emitting the matching live updates.
public actor DemoRemoteHost: RemoteHost {
    public private(set) var sessions: [SessionSummary]
    public private(set) var permissions: [PermissionRequest]
    public private(set) var transcripts: [String: RemoteTranscript]
    public private(set) var roomList: [RemoteRoom]
    public private(set) var usage: RemoteUsageSummary
    /// Every action received, oldest first.
    public private(set) var recordedActions: [RemoteHostAction] = []

    private var continuations: [UUID: AsyncStream<RemoteUpdate>.Continuation] = [:]
    private var counter = 0

    public init(data: RemoteDemoData = .sample()) {
        sessions = data.sessions
        permissions = data.permissions
        transcripts = data.transcripts
        roomList = data.rooms
        usage = data.usage
    }

    // MARK: RemoteHost

    public func hubSnapshot() async -> RemoteHubSnapshot {
        RemoteHubSnapshot(sessions: sessions, permissions: permissions)
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
            sessionID = room.sessionID
        }
        guard transcripts[sessionID] != nil else { throw RemoteError(.notFound, "No session \(sessionID)") }
        let shown = agent.map { "@\($0) \(text)" } ?? text
        let item = TranscriptItem.user(id: nextID("user"), text: shown, date: Date())
        transcripts[sessionID]?.items.append(item)
        emit(.transcriptUpsert(sessionID: sessionID, item: item))
        setActivity(.working, sessionID: sessionID)
    }

    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws {
        recordedActions.append(.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision))
        guard permissions.contains(where: { $0.id == requestID }) else {
            throw RemoteError(.notFound, "That permission prompt was already answered")
        }
        permissions.removeAll { $0.id == requestID }
        emit(.permissionReplied(sessionID: sessionID, requestID: requestID, decision: decision))
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
