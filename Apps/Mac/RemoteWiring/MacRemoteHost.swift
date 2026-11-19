import Foundation
import Observation
import Synchronization
import EnsembleKit

enum MacRemoteHostError: LocalizedError {
    case sessionNotFound
    case requestNotOpen
    /// An Allow from an iPhone app that predates plans and questions.
    case needsOwnAnswer(plan: Bool)
    case notAnswered(String?)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: "That session is not on this Mac anymore."
        case .requestNotOpen: "That question or plan is no longer open in this session."
        case .needsOwnAnswer(let plan):
            plan ? "Choose Proceed or Keep planning on the plan. Update Ensemble on the iPhone to do that here."
                : "Choose an answer to the question. Update Ensemble on the iPhone to do that here."
        case .notAnswered(let reason): reason ?? "The Mac could not pass the answer on."
        }
    }
}

/// Gives the iPhone remote the Mac's sessions and rooms and carries out what the phone asks for, through the same
/// `SessionStore` and `RoomsController` the window uses. Only paired phones get here: the `RemoteServer` hands this
/// host nothing before a phone has proved the pairing token, and every room action is checked again against the
/// room as it is now (the room exists, the agent is in it, the decision is still the one the phone showed).
@MainActor
final class MacRemoteHost: RemoteHost {
    private let store: SessionStore
    /// The app's rooms. `AppEngine` sets this right after it makes the rooms controller.
    weak var rooms: RoomsController?

    init(store: SessionStore, rooms: RoomsController? = nil) {
        self.store = store
        self.rooms = rooms
    }

    // MARK: Snapshots

    private func summary(_ s: SessionModel) -> SessionSummary {
        let lastText = s.items.reversed().compactMap { item -> String? in
            if case .agentText(_, let text, _, _) = item { return text }
            return nil
        }.first
        let asked = lastText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") } ?? false
        return SessionSummary(
            id: s.id,
            title: s.title,
            directory: s.directory,
            activity: s.activity,
            lastActivity: s.info.updated,
            pendingAsk: s.pendingPermissions.first.map(Self.askText),
            pendingPermissions: s.pendingPermissions.count,
            endedWithQuestion: s.activity != .working && asked,
            archived: s.info.archived,
            usage: s.usage
        )
    }

    private func session(_ id: String) -> SessionModel? {
        store.sessions.first { $0.id == id }
    }

    /// The Hub row's line for what the session waits on.
    static func askText(_ request: PermissionRequest) -> String {
        RemoteRoomBridge.askText(request)
    }

    /// The open request `requestID` of `sessionID` as the store holds it. A request id from another session is never
    /// found, so an answer only ever reaches the session that asked.
    private func openRequest(_ requestID: String, in sessionID: String) throws -> PermissionRequest {
        guard let session = session(sessionID) else { throw MacRemoteHostError.sessionNotFound }
        guard let request = session.pendingPermissions.first(where: { $0.id == requestID }), request.sessionID == sessionID else {
            throw MacRemoteHostError.requestNotOpen
        }
        return request
    }

    /// Room agents' own sessions. Like on the Mac's Session Hub they show inside their room's row, not on their own.
    private var roomAgentSessionIDs: Set<String> {
        guard let rooms, rooms.isLoaded else { return [] }
        return rooms.roomSessionIDs
    }

    func hubSnapshot() async -> RemoteHubSnapshot {
        let hidden = roomAgentSessionIDs
        let roots = store.sessions.filter { !$0.isSubagent && !store.isSideQuestionSession($0.id) && !hidden.contains($0.id) }
        var permissions = store.sessions.flatMap(\.pendingPermissions)
        let known = Set(permissions.map(\.id))
        // Prompts the rooms know about that the session list has not loaded (subagents of room agents).
        // Prompts held or filtered out by the store's safety check for loaded sessions must stay hidden.
        permissions += (rooms?.permissions.values.flatMap { $0 } ?? []).filter {
            !known.contains($0.id) && session($0.sessionID) == nil && !store.safetyCheck.isHolding($0.id)
        }
        return RemoteHubSnapshot(sessions: roots.map(summary) + remoteRooms().map(\.row), permissions: permissions)
    }

    func transcript(sessionID: String) async throws -> RemoteTranscript {
        if let mapped = remoteRoom(sessionID: sessionID) { return RemoteRoomBridge.transcript(mapped.state, room: mapped.room) }
        guard let s = session(sessionID) else { throw MacRemoteHostError.sessionNotFound }
        if !s.transcriptLoaded { await store.loadSession(sessionID) }
        return RemoteTranscript(sessionID: s.id, title: s.title, items: s.items, activity: s.activity,
                                permissionMode: s.permissionMode)
    }

    func rooms() async -> [RemoteRoom] { remoteRooms().map(\.room) }

    /// Every room as the phone sees it, with its Hub row.
    private func remoteRooms() -> [(room: RemoteRoom, state: RoomState, row: SessionSummary)] {
        guard let rooms, rooms.isLoaded else { return [] }
        return rooms.rooms.map { state in
            let room = remoteRoom(state, rooms: rooms)
            return (room, state, RemoteRoomBridge.hubRow(room, pausedForUser: state.isPaused && !state.cappedAgents.isEmpty))
        }
    }

    private func remoteRoom(_ state: RoomState, rooms: RoomsController) -> RemoteRoom {
        var permissions: [PermissionRequest] = []
        var visibleRootIDs = Set<String>()
        for sid in state.sessions.values {
            let visible = (rooms.permissions[sid] ?? []).filter { !isSuppressedRoomPermission($0) }
            if !visible.isEmpty { visibleRootIDs.insert(sid) }
            permissions += visible
        }
        var activity: [UUID: AgentActivity] = [:]
        // Saved rooms that are not open have no live engine: their agents are idle (or capped).
        if let engine = rooms.engines[state.id] {
            for agent in state.spec.agents {
                var current = rooms.activity(of: agent.id, in: engine)
                if current == .waitingForPermission, let sid = state.sessions[agent.id], !visibleRootIDs.contains(sid) {
                    current = .working
                }
                activity[agent.id] = current
            }
        }
        return RemoteRoomBridge.room(state, activity: activity, permissions: permissions, running: rooms.isRunning(state.id))
    }

    private func isSuppressedRoomPermission(_ request: PermissionRequest) -> Bool {
        if store.safetyCheck.isHolding(request.id) { return true }
        if let session = session(request.sessionID) {
            return !session.pendingPermissions.contains { $0.id == request.id }
        }
        return false
    }

    /// The room whose Hub row or transcript id this is.
    private func remoteRoom(sessionID: String) -> (room: RemoteRoom, state: RoomState)? {
        guard let id = UUID(uuidString: sessionID), let rooms, rooms.isLoaded, let state = rooms.state(id) else { return nil }
        return (remoteRoom(state, rooms: rooms), state)
    }

    func usageSummary() async -> RemoteUsageSummary {
        let today = Calendar.current.startOfDay(for: Date())
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let all = store.sessions.filter { !$0.isSubagent && !store.isSideQuestionSession($0.id) }
        let todayUsage = all.filter { $0.info.updated >= today }.map(\.usage).reduce(.zero, +)
        let weekUsage = all.filter { $0.info.updated >= weekAgo }.map(\.usage).reduce(.zero, +)
        var byProvider: [String: Usage] = [:]
        for s in all where s.info.updated >= weekAgo {
            byProvider[s.info.model?.providerID ?? "other", default: .zero] = byProvider[s.info.model?.providerID ?? "other", default: .zero] + s.usage
        }
        let rows = byProvider.sorted { $0.value.costUSD > $1.value.costUSD }
            .map { RemoteUsageSummary.Row(id: $0.key, label: $0.key, usage: $0.value) }
        // Claude plan and Google AI plan limits (`RemotePlanSummaries`, Usage/PlanUsageSections.swift).
        return RemoteUsageSummary(today: todayUsage, week: weekUsage, providers: rows, plans: await RemotePlanSummaries.plans(store: store))
    }

    // MARK: Live updates

    func updates() async -> AsyncStream<RemoteUpdate> {
        let events = store.engine.events()
        let visiblePermissions = store.safetyCheck.visiblePermissions()
        return AsyncStream { continuation in
            let eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self else { break }
                    let hidden = self.roomAgentSessionIDs
                    for update in await self.translate(event) {
                        // Room agents' sessions are part of their room's row.
                        if case .sessionUpserted(let s) = update, hidden.contains(s.id) { continue }
                        continuation.yield(update)
                    }
                }
                continuation.finish()
            }
            let permissionTask = Task { @MainActor [weak self] in
                for await request in visiblePermissions {
                    guard let self else { break }
                    continuation.yield(.permissionAsked(request: request))
                    if let s = self.session(request.sessionID),
                       !s.isSubagent,
                       !self.store.isSideQuestionSession(s.id),
                       !self.roomAgentSessionIDs.contains(s.id) {
                        continuation.yield(.sessionUpserted(session: self.summary(s)))
                    }
                }
            }
            let roomTask = Task { @MainActor [weak self] in
                await self?.watchRooms { continuation.yield($0) }
            }
            continuation.onTermination = { _ in
                eventTask.cancel()
                permissionTask.cancel()
                roomTask.cancel()
            }
        }
    }

    /// What the phone has of the rooms, to send only what changed.
    private struct RoomsSeen {
        var rooms: [UUID: RemoteRoom] = [:]
        var rows: [String: SessionSummary] = [:]
        var items: [String: [TranscriptItem]] = [:]
    }

    private func roomsSeen() -> RoomsSeen {
        var seen = RoomsSeen()
        for (room, state, row) in remoteRooms() {
            seen.rooms[room.id] = room
            seen.rows[row.id] = row
            seen.items[room.sessionID] = RemoteRoomBridge.transcriptItems(state, permissions: room.permissions)
        }
        return seen
    }

    /// Follows the rooms (state, decisions, agents, prompts, board) and yields what changed: room upserts, their Hub
    /// rows, and new or changed rows of each room's transcript (the server sends those only to phones that have the
    /// room open). Runs until the task is cancelled.
    private func watchRooms(_ yield: @escaping @MainActor (RemoteUpdate) -> Void) async {
        var last = roomsSeen()
        while !Task.isCancelled {
            await Self.waitForChange(timeout: .seconds(5)) { [weak self] in _ = self?.roomsSeen() }
            // Let a burst of changes (a turn ending posts, saves and updates activity) settle into one update.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let next = roomsSeen()
            for (id, room) in next.rooms where last.rooms[id] != room { yield(.roomUpserted(room: room)) }
            for (id, room) in last.rooms where next.rooms[id] == nil {
                yield(.roomRemoved(roomID: id))
                yield(.sessionRemoved(sessionID: room.sessionID))
            }
            for (id, row) in next.rows where last.rows[id] != row { yield(.sessionUpserted(session: row)) }
            for (sessionID, items) in next.items {
                let before = Dictionary((last.items[sessionID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for item in items where before[item.id] != item { yield(.transcriptUpsert(sessionID: sessionID, item: item)) }
            }
            last = next
        }
    }

    /// Returns once anything `read` reads changes, or after `timeout` (so cancellation is noticed).
    private static func waitForChange(timeout: Duration, _ read: @escaping @MainActor () -> Void) async {
        let gate = ChangeGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arm(continuation)
            withObservationTracking { read() } onChange: { gate.open() }
            Task {
                try? await Task.sleep(for: timeout)
                gate.open()
            }
        }
    }

    /// Lets the store apply the same event first, then reads its updated summary.
    private func refreshedSummary(_ sessionID: String) async -> SessionSummary? {
        try? await Task.sleep(for: .milliseconds(80))
        return session(sessionID).map(summary)
    }

    private func translate(_ event: EngineEvent) async -> [RemoteUpdate] {
        switch event {
        case .textDelta(let sid, let item, let delta), .reasoningDelta(let sid, let item, let delta):
            return [.textDelta(sessionID: sid, itemID: item, delta: delta)]
        case .textEnded(let sid, let item, let text):
            return [.transcriptUpsert(sessionID: sid, item: .agentText(id: item, text: text, agentID: nil, streaming: false))]
        case .toolUpdated(let sid, let tool):
            return [.transcriptUpsert(sessionID: sid, item: .tool(tool))]
        case .permissionAsked(let request):
            let summary = await refreshedSummary(request.sessionID)
            // Prompts for sessions managed by SessionStore arrive via `visiblePermissions()` after the safety check.
            if store.isListening, session(request.sessionID) != nil { return [] }
            guard !store.safetyCheck.isHolding(request.id) else { return [] }
            if let s = session(request.sessionID) {
                guard let shown = s.pendingPermissions.first(where: { $0.id == request.id }) else { return [] }
                return [.permissionAsked(request: shown)] + (summary.map { [.sessionUpserted(session: $0)] } ?? [])
            }
            var out: [RemoteUpdate] = [.permissionAsked(request: request)]
            if let summary { out.append(.sessionUpserted(session: summary)) }
            return out
        case .permissionReplied(let sid, let rid):
            var out: [RemoteUpdate] = [.permissionReplied(sessionID: sid, requestID: rid, decision: nil)]
            if let s = await refreshedSummary(sid) { out.append(.sessionUpserted(session: s)) }
            return out
        case .activity(let sid, let activity):
            let summary = await refreshedSummary(sid)
            if activity == .waitingForPermission, let s = session(sid), s.pendingPermissions.isEmpty {
                return []
            }
            var out: [RemoteUpdate] = [.activity(sessionID: sid, activity: activity)]
            if let summary { out.append(.sessionUpserted(session: summary)) }
            return out
        case .usageUpdated(let sid, let usage):
            return [.usage(sessionID: sid, usage: usage)]
        case .executionEnded(let sid, _, _):
            var out: [RemoteUpdate] = [.activity(sessionID: sid, activity: .idle)]
            if let s = await refreshedSummary(sid) { out.append(.sessionUpserted(session: s)) }
            return out
        case .sessionCreated(let info), .sessionUpdated(let info):
            guard info.parentID == nil, let s = await refreshedSummary(info.id) else { return [] }
            return [.sessionUpserted(session: s)]
        case .sessionDeleted(let sid):
            return [.sessionRemoved(sessionID: sid)]
        case .filesChanged, .connectorsChanged, .other:
            return []
        }
    }

    // MARK: Actions

    /// A room's engine, opening a saved room the first time. Refuses an id that is not one of this Mac's rooms.
    private func roomEngine(_ roomID: UUID) throws -> RoomEngine {
        guard let rooms, rooms.isLoaded, rooms.state(roomID) != nil, let engine = rooms.engine(for: roomID) else {
            throw RemoteError(.notFound, "That room is not on this Mac anymore.")
        }
        return engine
    }

    func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws {
        switch target {
        case .room(let roomID):
            try await sendToRoom(roomID, text: text, agent: agent)
        case .session(let id):
            // A phone may address a room by its Hub row id.
            if let mapped = remoteRoom(sessionID: id) {
                try await sendToRoom(mapped.room.id, text: text, agent: agent)
                return
            }
            guard session(id) != nil else { throw MacRemoteHostError.sessionNotFound }
            await store.send(text, to: id)
        }
    }

    /// The user's words to the whole room, or to one agent by name. A name the room does not have is refused rather
    /// than sent to everyone.
    private func sendToRoom(_ roomID: UUID, text: String, agent: String?) async throws {
        let engine = try roomEngine(roomID)
        guard let agent else {
            await engine.send(text)
            return
        }
        guard let spec = engine.agents.first(where: { $0.name.compare(agent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw RemoteError(.badRequest, "This room has no agent named \(agent).")
        }
        await engine.send(text, to: [spec.id])
    }

    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws {
        if let request = session(sessionID)?.pendingPermissions.first(where: { $0.id == requestID }) {
            if request.isInteraction, decision != .reject { throw MacRemoteHostError.needsOwnAnswer(plan: request.isPlan) }
            await store.reply(to: request, decision: decision)
        } else if let rooms, let request = rooms.permissions.values.flatMap({ $0 }).first(where: { $0.id == requestID && $0.sessionID == sessionID }) {
            // A room agent's subagent the session list has not loaded.
            await rooms.reply(to: request, decision: decision)
        } else {
            try await store.engine.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision, message: nil)
        }
    }

    func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        switch target {
        case .room:
            throw RemoteError(.badRequest, "A room keeps the permission mode it was made with.")
        case .session(let id):
            if remoteRoom(sessionID: id) != nil { throw RemoteError(.badRequest, "A room keeps the permission mode it was made with.") }
            await store.setPermissionMode(mode, for: id)
        }
    }

    func interrupt(_ target: RemoteTarget) async throws {
        switch target {
        case .room(let roomID):
            // Stopping a room's turn from the phone pauses the room, like Pause on the Mac.
            try await roomEngine(roomID).pause()
        case .session(let id):
            if let mapped = remoteRoom(sessionID: id) {
                try await roomEngine(mapped.room.id).pause()
                return
            }
            try await store.engine.interrupt(id)
        }
    }

    func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws {
        let engine = try roomEngine(roomID)
        switch action {
        case .pause:
            await engine.pause()
        case .resume:
            guard engine.state.isPaused else { throw RemoteError(.badRequest, "The room is not paused.") }
            await engine.resume()
            if engine.state.isPaused { throw RemoteError(.failed, engine.lastError ?? "The room could not resume.") }
        case .stop:
            await engine.stop()
        }
    }

    func decideRoom(_ reply: RemoteRoomDecisionReply) async throws {
        try await RemoteRoomBridge.decide(reply, engine: roomEngine(reply.roomID))
    }

    func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        let request = try openRequest(requestID, in: sessionID)
        guard request.isQuestion else { throw MacRemoteHostError.requestNotOpen }
        let done = answers.isEmpty ? await store.declineQuestion(request) : await store.answerQuestion(request, answers: answers)
        guard done else { throw MacRemoteHostError.notAnswered(store.lastError) }
    }

    func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws {
        let request = try openRequest(requestID, in: sessionID)
        guard request.isPlan else { throw MacRemoteHostError.requestNotOpen }
        // The store also refuses a mode the plan card does not offer.
        guard await store.respondToPlan(request, decision: decision) else { throw MacRemoteHostError.notAnswered(store.lastError) }
    }
}

/// Resumes a waiting task once, from whichever comes first: an observed change or the timeout.
private final class ChangeGate: Sendable {
    private let waiting = Mutex<CheckedContinuation<Void, Never>?>(nil)

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        waiting.withLock { $0 = continuation }
    }

    func open() {
        waiting.withLock { $0.take() }?.resume()
    }
}
