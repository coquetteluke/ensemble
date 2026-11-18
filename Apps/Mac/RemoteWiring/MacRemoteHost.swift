import Foundation
import EnsembleKit

enum MacRemoteHostError: LocalizedError {
    case sessionNotFound
    case roomsNotAvailable
    case requestNotOpen
    /// An Allow from an iPhone app that predates plans and questions.
    case needsOwnAnswer(plan: Bool)
    case notAnswered(String?)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: "That session is not on this Mac anymore."
        case .roomsNotAvailable: "Rooms are not available from the iPhone yet."
        case .requestNotOpen: "That question or plan is no longer open in this session."
        case .needsOwnAnswer(let plan):
            plan ? "Choose Proceed or Keep planning on the plan. Update Ensemble on the iPhone to do that here."
                : "Choose an answer to the question. Update Ensemble on the iPhone to do that here."
        case .notAnswered(let reason): reason ?? "The Mac could not pass the answer on."
        }
    }
}

/// Gives the iPhone remote the Mac's sessions and carries out what the phone asks for, through the
/// same `SessionStore` the window uses. Rooms join once the room screen is wired in.
@MainActor
final class MacRemoteHost: RemoteHost {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
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
        if request.isPlan { return "Plan ready: \(request.plan?.title ?? request.title)" }
        if request.isQuestion { return "Question: \(request.questions?.first?.text ?? request.title)" }
        return "Approve: \(request.title)"
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

    func hubSnapshot() async -> RemoteHubSnapshot {
        let roots = store.sessions.filter { !$0.isSubagent && !store.isSideQuestionSession($0.id) }
        return RemoteHubSnapshot(sessions: roots.map(summary), permissions: store.sessions.flatMap(\.pendingPermissions))
    }

    func transcript(sessionID: String) async throws -> RemoteTranscript {
        guard let s = session(sessionID) else { throw MacRemoteHostError.sessionNotFound }
        if !s.transcriptLoaded { await store.loadSession(sessionID) }
        return RemoteTranscript(sessionID: s.id, title: s.title, items: s.items, activity: s.activity,
                                permissionMode: s.permissionMode)
    }

    func rooms() async -> [RemoteRoom] { [] }

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
        return RemoteUsageSummary(today: todayUsage, week: weekUsage, providers: rows)
    }

    // MARK: Live updates

    func updates() async -> AsyncStream<RemoteUpdate> {
        let events = store.engine.events()
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self else { break }
                    for update in await self.translate(event) { continuation.yield(update) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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
            // The store's copy, with what it adds (the mode a plan's Proceed switches to).
            let shown = session(request.sessionID)?.pendingPermissions.first { $0.id == request.id } ?? request
            var out: [RemoteUpdate] = [.permissionAsked(request: shown)]
            if let summary { out.append(.sessionUpserted(session: summary)) }
            return out
        case .permissionReplied(let sid, let rid):
            var out: [RemoteUpdate] = [.permissionReplied(sessionID: sid, requestID: rid, decision: nil)]
            if let s = await refreshedSummary(sid) { out.append(.sessionUpserted(session: s)) }
            return out
        case .activity(let sid, let activity):
            var out: [RemoteUpdate] = [.activity(sessionID: sid, activity: activity)]
            if let s = await refreshedSummary(sid) { out.append(.sessionUpserted(session: s)) }
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

    func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws {
        guard case .session(let id) = target else { throw MacRemoteHostError.roomsNotAvailable }
        guard session(id) != nil else { throw MacRemoteHostError.sessionNotFound }
        await store.send(text, to: id)
    }

    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws {
        if let request = session(sessionID)?.pendingPermissions.first(where: { $0.id == requestID }) {
            if request.isInteraction, decision != .reject { throw MacRemoteHostError.needsOwnAnswer(plan: request.isPlan) }
            await store.reply(to: request, decision: decision)
        } else {
            try await store.engine.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision, message: nil)
        }
    }

    func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        guard case .session(let id) = target else { throw MacRemoteHostError.roomsNotAvailable }
        await store.setPermissionMode(mode, for: id)
    }

    func interrupt(_ target: RemoteTarget) async throws {
        guard case .session(let id) = target else { throw MacRemoteHostError.roomsNotAvailable }
        try await store.engine.interrupt(id)
    }

    func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws {
        throw MacRemoteHostError.roomsNotAvailable
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
