import Foundation
import ImageIO
import UniformTypeIdentifiers
import Observation
import Synchronization
import SystemConfiguration
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
    private var updateContinuations: [UUID: AsyncStream<RemoteUpdate>.Continuation] = [:]
    /// Tracks reasoning item ids already announced via `.transcriptUpsert`, keyed by primary session id.
    private var seenReasoningItems: [String: Set<String>] = [:]
    private let attachmentInbox = RemoteAttachmentInbox()

    init(store: SessionStore, rooms: RoomsController? = nil) {
        self.store = store
        self.rooms = rooms
    }

    private func broadcast(_ update: RemoteUpdate) {
        for continuation in updateContinuations.values {
            continuation.yield(update)
        }
    }

    // MARK: Snapshots

    private func summary(_ s: SessionModel) -> SessionSummary {
        let lastText = s.items.reversed().compactMap { item -> String? in
            if case .agentText(_, let text, _, _) = item { return text }
            return nil
        }.first
        let asked = lastText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") } ?? false
        let staged = store.stagedModel(for: s.id)
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
            usage: s.usage,
            modelProviderID: s.info.model?.providerID,
            modelID: s.info.model?.id,
            pendingModelName: staged.map { store.modelName($0) }
        )
    }

    private func availableModelOptions() -> [RemoteModelOption] {
        let folders = ModelCatalog.folders(store.models, billing: nil)
        var out: [RemoteModelOption] = []
        var seen = Set<String>()
        for folder in folders {
            for choice in folder.all where choice.available {
                guard let route = choice.primary else { continue }
                let key = "\(route.ref.providerID)/\(route.ref.id)"
                guard seen.insert(key).inserted else { continue }
                out.append(RemoteModelOption(
                    providerID: route.ref.providerID,
                    modelID: route.ref.id,
                    name: choice.name,
                    makerName: folder.maker.name,
                    engineLabel: route.providerName
                ))
            }
        }
        return out
    }

    private func isHiddenSession(_ id: String) -> Bool {
        store.isSideQuestionSession(id)
            || store.hiddenSessionIDs.contains(id)
            || store.hiddenLinkedSessionIDs.contains(id)
    }

    private func recentFolders() -> [String] {
        var dirs: [String] = []
        var seen = Set<String>()
        let sortedSessions = store.sessions.sorted { $0.info.updated > $1.info.updated }
        for s in sortedSessions where !s.isSubagent && !isHiddenSession(s.id) {
            let folder = store.projectFolder(for: s)
            if !folder.isEmpty, seen.insert(folder).inserted {
                dirs.append(folder)
                if dirs.count >= 16 { return dirs }
            }
        }
        if let rooms, rooms.isLoaded {
            for state in rooms.rooms {
                let folder = state.spec.directory
                if !folder.isEmpty, seen.insert(folder).inserted {
                    dirs.append(folder)
                    if dirs.count >= 16 { return dirs }
                }
            }
        }
        return dirs
    }

    private func remoteSecondOpinions(for sessionID: String) -> [RemoteSecondOpinion] {
        AgentToolsCenter.shared.secondOpinions.opinions(for: sessionID).values
            .flatMap { $0 }
            .sorted { $0.created < $1.created }
            .map { opinion in
            let status: String
            let error: String?
            switch opinion.status {
            case .loading:
                status = "running"
                error = nil
            case .answered:
                status = "ready"
                error = nil
            case .failed(let message):
                status = "failed"
                error = message
            }
            return RemoteSecondOpinion(
                id: opinion.id,
                itemID: opinion.itemID,
                modelName: opinion.modelName,
                makerName: opinion.makerName,
                status: status,
                verdict: opinion.status == .answered ? opinion.verdict.label : nil,
                summary: opinion.summary.isEmpty ? nil : opinion.summary,
                concerns: opinion.concerns,
                details: opinion.fullText.isEmpty ? nil : opinion.fullText,
                error: error
            )
        }
    }

    private func remotePermission(_ request: PermissionRequest) -> PermissionRequest {
        let primaryID = store.primarySessionID(for: request.sessionID)
        guard primaryID != request.sessionID else { return request }
        var mapped = request
        mapped.sessionID = primaryID
        return mapped
    }

    private func remoteTranscript(for s: SessionModel) -> RemoteTranscript {
        let staged = store.stagedModel(for: s.id)
        let mappedItems = s.items.map { item -> TranscriptItem in
            if case .permission(let p) = item { return .permission(remotePermission(p)) }
            return item
        }
        // Attachments go to the phone as names and kinds only (`RemoteTranscript.remoteRows`).
        let rows = RemoteTranscript.remoteRows(mappedItems, attachments: s.attachments)
        return RemoteTranscript(
            sessionID: s.id,
            title: s.title,
            items: rows.items,
            activity: s.activity,
            permissionMode: s.permissionMode,
            modelProviderID: s.info.model?.providerID,
            modelID: s.info.model?.id,
            pendingModelName: staged.map { store.modelName($0) },
            secondOpinions: remoteSecondOpinions(for: s.id),
            attachments: rows.attachments
        )
    }

    private func session(_ id: String) -> SessionModel? {
        let primaryID = store.primarySessionID(for: id)
        return store.sessions.first { $0.id == primaryID }
    }

    /// The Hub row's line for what the session waits on.
    static func askText(_ request: PermissionRequest) -> String {
        RemoteRoomBridge.askText(request)
    }

    /// The open request `requestID` of `sessionID` as the store holds it. A request id from another session is never
    /// found, so an answer only ever reaches the session that asked.
    private func openRequest(_ requestID: String, in sessionID: String) throws -> PermissionRequest {
        let primaryID = store.primarySessionID(for: sessionID)
        guard let session = session(primaryID) else { throw MacRemoteHostError.sessionNotFound }
        guard let request = session.pendingPermissions.first(where: { $0.id == requestID }),
              store.primarySessionID(for: request.sessionID) == primaryID else {
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
        let roots = store.sessions.filter { !$0.isSubagent && !isHiddenSession($0.id) && !hidden.contains($0.id) }
        var permissions = store.sessions
            .filter { !isHiddenSession($0.id) }
            .flatMap(\.pendingPermissions)
            .map(remotePermission)
        let known = Set(permissions.map(\.id))
        // Prompts the rooms know about that the session list has not loaded (subagents of room agents).
        // Prompts held or filtered out by the store's safety check for loaded sessions must stay hidden.
        permissions += (rooms?.permissions.values.flatMap { $0 } ?? []).filter {
            !known.contains($0.id) && session($0.sessionID) == nil && !store.safetyCheck.isHolding($0.id)
        }
        return RemoteHubSnapshot(
            sessions: roots.map(summary) + remoteRooms().map(\.row),
            permissions: permissions,
            availableModels: availableModelOptions(),
            recentFolders: recentFolders()
        )
    }

    func transcript(sessionID: String) async throws -> RemoteTranscript {
        if let mapped = remoteRoom(sessionID: sessionID) { return RemoteRoomBridge.transcript(mapped.state, room: mapped.room) }
        guard let s = session(sessionID) else { throw MacRemoteHostError.sessionNotFound }
        if !s.transcriptLoaded { await store.loadSession(sessionID) }
        return remoteTranscript(for: s)
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
        let all = store.sessions.filter { !$0.isSubagent && !isHiddenSession($0.id) }
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
            let streamID = UUID()
            updateContinuations[streamID] = continuation
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
                    let mapped = self.remotePermission(request)
                    continuation.yield(.permissionAsked(request: mapped))
                    if let s = self.session(mapped.sessionID),
                       !s.isSubagent,
                       !self.isHiddenSession(s.id),
                       !self.roomAgentSessionIDs.contains(s.id) {
                        continuation.yield(.sessionUpserted(session: self.summary(s)))
                    }
                }
            }
            let roomTask = Task { @MainActor [weak self] in
                await self?.watchRooms { continuation.yield($0) }
            }
            let opinionsTask = Task { @MainActor [weak self] in
                await self?.watchSecondOpinions { continuation.yield($0) }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.updateContinuations[streamID] = nil }
                eventTask.cancel()
                permissionTask.cancel()
                roomTask.cancel()
                opinionsTask.cancel()
            }
        }
    }

    private func secondOpinionsSnapshot() -> [String: [RemoteSecondOpinion]] {
        var result: [String: [RemoteSecondOpinion]] = [:]
        for s in store.sessions {
            let opinions = remoteSecondOpinions(for: s.id)
            if !opinions.isEmpty { result[s.id] = opinions }
        }
        return result
    }

    private func watchSecondOpinions(_ yield: @escaping @MainActor (RemoteUpdate) -> Void) async {
        var last = secondOpinionsSnapshot()
        while !Task.isCancelled {
            await Self.waitForChange(timeout: .seconds(5)) { [weak self] in _ = self?.secondOpinionsSnapshot() }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let next = secondOpinionsSnapshot()
            let changedIDs = Set(last.keys).union(next.keys).filter { last[$0] != next[$0] }
            for sid in changedIDs {
                if let s = session(sid) {
                    yield(.transcriptUpdated(transcript: remoteTranscript(for: s)))
                }
            }
            last = next
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
        let primaryID = store.primarySessionID(for: sessionID)
        guard !isHiddenSession(primaryID) else { return nil }
        return session(primaryID).map(summary)
    }

    private func translate(_ event: EngineEvent) async -> [RemoteUpdate] {
        switch event {
        case .textDelta(let sid, let item, let delta):
            let primaryID = store.primarySessionID(for: sid)
            return [.textDelta(sessionID: primaryID, itemID: item, delta: delta)]
        case .reasoningDelta(let sid, let item, let delta):
            let primaryID = store.primarySessionID(for: sid)
            if seenReasoningItems[primaryID, default: []].insert(item).inserted {
                if (seenReasoningItems[primaryID]?.count ?? 0) > 128 {
                    seenReasoningItems[primaryID] = [item]
                }
                return [.transcriptUpsert(sessionID: primaryID, item: .reasoning(id: item, text: delta, streaming: true))]
            }
            return [.textDelta(sessionID: primaryID, itemID: item, delta: delta)]
        case .textEnded(let sid, let item, let text):
            let primaryID = store.primarySessionID(for: sid)
            return [.transcriptUpsert(sessionID: primaryID, item: .agentText(id: item, text: text, agentID: nil, streaming: false))]
        case .toolUpdated(let sid, let tool):
            let primaryID = store.primarySessionID(for: sid)
            return [.transcriptUpsert(sessionID: primaryID, item: .tool(tool))]
        case .permissionAsked(let request):
            let primaryID = store.primarySessionID(for: request.sessionID)
            let summary = await refreshedSummary(primaryID)
            // Prompts for sessions managed by SessionStore arrive via `visiblePermissions()` after the safety check.
            if store.isListening, session(primaryID) != nil { return [] }
            guard !store.safetyCheck.isHolding(request.id) else { return [] }
            if let s = session(primaryID) {
                guard let shown = s.pendingPermissions.first(where: { $0.id == request.id }) else { return [] }
                return [.permissionAsked(request: remotePermission(shown))] + (summary.map { [.sessionUpserted(session: $0)] } ?? [])
            }
            var out: [RemoteUpdate] = [.permissionAsked(request: remotePermission(request))]
            if let summary { out.append(.sessionUpserted(session: summary)) }
            return out
        case .permissionReplied(let sid, let rid):
            let primaryID = store.primarySessionID(for: sid)
            var out: [RemoteUpdate] = [.permissionReplied(sessionID: primaryID, requestID: rid, decision: nil)]
            if let s = await refreshedSummary(primaryID) { out.append(.sessionUpserted(session: s)) }
            return out
        case .activity(let sid, let activity):
            let primaryID = store.primarySessionID(for: sid)
            let summary = await refreshedSummary(primaryID)
            if activity == .waitingForPermission, let s = session(primaryID), s.pendingPermissions.isEmpty {
                return []
            }
            var out: [RemoteUpdate] = [.activity(sessionID: primaryID, activity: activity)]
            if let summary { out.append(.sessionUpserted(session: summary)) }
            return out
        case .usageUpdated(let sid, let usage):
            let primaryID = store.primarySessionID(for: sid)
            return [.usage(sessionID: primaryID, usage: session(primaryID)?.usage ?? usage)]
        case .executionEnded(let sid, _, _):
            let primaryID = store.primarySessionID(for: sid)
            seenReasoningItems.removeValue(forKey: primaryID)
            var out: [RemoteUpdate] = [.activity(sessionID: primaryID, activity: .idle)]
            if let s = await refreshedSummary(primaryID) { out.append(.sessionUpserted(session: s)) }
            return out
        case .sessionCreated(let info), .sessionUpdated(let info):
            guard info.parentID == nil, !isHiddenSession(info.id) else { return [] }
            let primaryID = store.primarySessionID(for: info.id)
            guard !isHiddenSession(primaryID), let s = await refreshedSummary(primaryID) else { return [] }
            return [.sessionUpserted(session: s)]
        case .sessionDeleted(let sid):
            seenReasoningItems.removeValue(forKey: sid)
            guard !isHiddenSession(sid) else { return [] }
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

    func receiveAttachmentChunk(_ chunk: RemoteAttachmentChunk) async throws {
        try await attachmentInbox.receive(chunk)
    }

    func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws {
        try await sendMessage(text, to: target, agent: agent, attachmentIDs: [])
    }

    func sendMessage(_ text: String, to target: RemoteTarget, agent: String?, attachmentIDs: [String]) async throws {
        let staged = try await attachmentInbox.claim(attachmentIDs)
        let urls = staged.map(\.url)
        switch target {
        case .room(let roomID):
            let roomText = roomMessageText(text, files: urls)
            try await sendToRoom(roomID, text: roomText, agent: agent)
        case .session(let id):
            // A phone may address a room by its Hub row id.
            if let mapped = remoteRoom(sessionID: id) {
                let roomText = roomMessageText(text, files: urls)
                try await sendToRoom(mapped.room.id, text: roomText, agent: agent)
                return
            }
            guard let s = session(id) else { throw MacRemoteHostError.sessionNotFound }
            await store.send(text, files: urls, to: s.id)
            broadcast(.transcriptUpdated(transcript: remoteTranscript(for: s)))
            broadcast(.sessionUpserted(session: summary(s)))
        }
    }

    func attachmentPreview(sessionID: String, attachmentID: String) async throws -> RemoteAttachmentPreview {
        guard let s = session(sessionID) else { throw MacRemoteHostError.sessionNotFound }
        let match = s.attachments.values
            .flatMap { $0 }
            .first { $0.id == attachmentID && $0.kind == .image }
        guard let url = match?.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw RemoteError(.notFound, "That picture is no longer on this Mac.")
        }
        guard let previewData = Self.makeJPEGPreview(for: url, maxPixelSize: 960) else {
            throw RemoteError(.failed, "Could not prepare a preview for that picture.")
        }
        return RemoteAttachmentPreview(attachmentID: attachmentID, mediaType: "image/jpeg", data: previewData)
    }

    private static func makeJPEGPreview(for url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for quality in [0.80, 0.62, 0.45] {
            let output = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            let data = output as Data
            if data.count <= 512 * 1024 { return data }
        }
        return nil
    }

    private func roomMessageText(_ text: String, files: [URL]) -> String {
        guard !files.isEmpty else { return text }
        let listing = "Attached files (read them with your tools):\n" + files.map(\.path).joined(separator: "\n")
        return text.isEmpty ? listing : "\(text)\n\n\(listing)"
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
        } else if let rooms, let request = rooms.permissions.values.flatMap({ $0 }).first(where: {
            $0.id == requestID && $0.sessionID == sessionID && !isSuppressedRoomPermission($0)
        }) {
            // A room agent's subagent the session list has not loaded.
            await rooms.reply(to: request, decision: decision)
        } else {
            throw MacRemoteHostError.requestNotOpen
        }
    }

    func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        switch target {
        case .room:
            throw RemoteError(.badRequest, "A room keeps the permission mode it was made with.")
        case .session(let id):
            if remoteRoom(sessionID: id) != nil { throw RemoteError(.badRequest, "A room keeps the permission mode it was made with.") }
            guard let s = session(id), !s.isSubagent, !isHiddenSession(s.id), !roomAgentSessionIDs.contains(s.id) else {
                throw MacRemoteHostError.sessionNotFound
            }
            await store.setPermissionMode(mode, for: s.id)
            let current = session(s.id) ?? s
            guard current.permissionMode == mode else {
                throw RemoteError(.failed, store.lastError ?? "Could not change permission mode.")
            }
            broadcast(.permissionModeChanged(target: .session(s.id), mode: current.permissionMode))
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
            guard let s = session(id) else { throw MacRemoteHostError.sessionNotFound }
            await store.stop(s.id)
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

    /// Validates a folder requested by the phone before creating a session or room in it.
    /// Rejects broad, system, or sensitive dot-directories and requires the folder to be trusted or already known.
    private func validatedRemoteFolder(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemoteError(.badRequest, "Pick a project folder first.") }
        guard let resolved = WorkspaceTrust.resolvedPath(trimmed) else {
            throw RemoteError(.badRequest, "That folder does not exist on this Mac.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw RemoteError(.badRequest, "That folder does not exist on this Mac.")
        }

        let resolvedParts = resolved.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let home = WorkspaceTrust.resolvedPath(NSHomeDirectory()) ?? WorkspaceTrust.shared.homeFolder
        let homeParts = home.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let isRootOrHomeAncestor = resolved == "/"
            || resolved == home
            || (resolvedParts.count <= homeParts.count && Array(homeParts.prefix(resolvedParts.count)) == resolvedParts)
        let blockedRoots = ["/System", "/Library", "/etc", "/private/etc"]
        let isBlockedRoot = blockedRoots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
        let sensitiveDotDirs: Set<String> = [".ssh", ".gnupg", ".aws", ".claude", ".config"]
        let hasSensitiveDotDir = resolvedParts.contains { sensitiveDotDirs.contains($0) }
        guard !isRootOrHomeAncestor, !isBlockedRoot, !hasSensitiveDotDir else {
            throw RemoteError(.badRequest, "That folder cannot be used from the iPhone.")
        }

        var knownFolders = Set<String>()
        for s in store.sessions where !s.isSubagent && !isHiddenSession(s.id) {
            if let r = WorkspaceTrust.resolvedPath(store.projectFolder(for: s)) {
                knownFolders.insert(r)
            }
        }
        if let rooms, rooms.isLoaded {
            for state in rooms.rooms {
                if let r = WorkspaceTrust.resolvedPath(state.spec.directory) {
                    knownFolders.insert(r)
                }
            }
        }
        guard WorkspaceTrust.shared.isTrusted(resolved) || knownFolders.contains(resolved) else {
            throw RemoteError(.badRequest, "Choose a trusted or existing project folder on your Mac.")
        }
        return resolved
    }

    func changeModel(_ request: RemoteChangeModel) async throws {
        if remoteRoom(sessionID: request.sessionID) != nil {
            throw RemoteError(.badRequest, "Switch models for individual agents inside the room on your Mac.")
        }
        guard let targetSession = session(request.sessionID) else { throw MacRemoteHostError.sessionNotFound }
        let ref = ModelRef(providerID: request.providerID, id: request.modelID)
        let result = await store.changeModel(ref, for: targetSession.id)
        switch result {
        case .switched, .stagedForNextMessage:
            if let updated = session(targetSession.id) {
                broadcast(.sessionUpserted(session: summary(updated)))
                broadcast(.transcriptUpdated(transcript: remoteTranscript(for: updated)))
            }
        case .restarted(let from, let to):
            if let replacement = session(to) {
                broadcast(.sessionReplaced(oldSessionID: from, newSession: summary(replacement)))
                broadcast(.hubUpdated(hub: await hubSnapshot()))
            }
        case .needsNewSession, .failed:
            throw RemoteError(.failed, store.lastError ?? "Could not switch model for this session.")
        }
    }

    func createSession(_ request: RemoteCreateSession) async throws -> SessionSummary {
        let dir = try validatedRemoteFolder(request.directory)
        let ref = ModelRef(providerID: request.providerID, id: request.modelID)
        let created = try await store.newSession(directory: dir, model: ref, permissionMode: .ask)
        let customTitle = String((request.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if !customTitle.isEmpty {
            await store.rename(created.id, to: customTitle)
        }
        let row = summary(created)
        broadcast(.sessionUpserted(session: row))
        broadcast(.hubUpdated(hub: await hubSnapshot()))
        return row
    }

    func createRoom(_ request: RemoteCreateRoom) async throws -> RemoteRoom {
        guard let rooms, rooms.isLoaded else {
            throw RemoteError(.failed, "Rooms are not ready on this Mac yet.")
        }
        let dir = try validatedRemoteFolder(request.directory)
        let title = String(request.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !title.isEmpty else { throw RemoteError(.badRequest, "Give the room a title.") }
        guard request.agents.count >= 2 && request.agents.count <= 6 else {
            throw RemoteError(.badRequest, "A room needs between 2 and 6 agents.")
        }
        let palette = ["#D97757", "#6A9BCC", "#788C5D", "#9B7BD4"]
        let specs: [AgentSpec] = request.agents.enumerated().map { idx, agent in
            let rawName = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String((rawName.isEmpty ? "Agent \(idx + 1)" : rawName).prefix(48))
            let role = String(agent.role.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            return AgentSpec(
                name: name,
                model: ModelRef(providerID: agent.providerID, id: agent.modelID),
                role: role,
                colorHex: palette[idx % palette.count]
            )
        }
        let spec = RoomSpec(
            title: title,
            directory: dir,
            agents: specs,
            mode: request.mode,
            leadAgentID: request.mode == .debate ? nil : specs.first?.id,
            permissionMode: .ask
        )
        let engine = try await rooms.create(spec: spec)
        rooms.syncAgents(into: store)
        let remote = remoteRoom(engine.state, rooms: rooms)
        let row = RemoteRoomBridge.hubRow(remote)
        broadcast(.roomUpserted(room: remote))
        broadcast(.sessionUpserted(session: row))
        broadcast(.hubUpdated(hub: await hubSnapshot()))
        return remote
    }

    func sessionDiff(sessionID: String) async throws -> RemoteSessionDiff {
        let directory: String
        if let mapped = remoteRoom(sessionID: sessionID) {
            directory = mapped.state.spec.directory
        } else if let s = session(sessionID) {
            directory = s.directory
        } else {
            throw MacRemoteHostError.sessionNotFound
        }
        let service = GitReviewService()
        let root: String
        do {
            guard let repoRoot = try service.trustedRepository(directory) else {
                return RemoteSessionDiff(sessionID: sessionID, directory: directory, files: [], truncated: false)
            }
            root = repoRoot
        } catch is GitUntrustedError {
            throw RemoteError(.badRequest, "Trust this folder on your Mac before inspecting git diffs.")
        }
        let base: String
        if let head = await service.head(root) {
            base = head
        } else {
            base = await service.emptyTree(root)
        }
        let target = try await service.snapshotTree(root)
        let rawDiffs = try await service.diff(from: base, to: target, root: root)
        let maxFiles = 200
        let byteBudget = 120_000
        var usedBytes = 0
        var truncated = false
        var files: [RemoteDiffFile] = []
        for diff in rawDiffs {
            if files.count >= maxFiles {
                truncated = true
                break
            }
            let patchText: String
            if diff.isBinary {
                patchText = "(Binary file changed)"
                usedBytes += patchText.utf8.count
            } else {
                let remaining = max(0, byteBudget - usedBytes)
                if remaining == 0 {
                    truncated = true
                    break
                }
                let patchBytes = diff.patch.utf8.count
                if patchBytes <= remaining {
                    patchText = diff.patch
                    usedBytes += patchBytes
                } else {
                    truncated = true
                    patchText = String(decoding: diff.patch.utf8.prefix(remaining), as: UTF8.self) + "\n... (diff truncated)"
                    usedBytes = byteBudget
                }
            }
            files.append(RemoteDiffFile(
                path: diff.path,
                status: diff.kind.label,
                additions: diff.additions,
                deletions: diff.deletions,
                diffText: patchText
            ))
            if usedBytes >= byteBudget {
                if files.count < rawDiffs.count { truncated = true }
                break
            }
        }
        return RemoteSessionDiff(sessionID: sessionID, directory: root, files: files, truncated: truncated)
    }

    /// What the details panel shows, from the same sources as `ContextPanelView`. A room answers with its lead agent's
    /// context and folders and the files every agent changed.
    func sessionDetails(sessionID: String) async throws -> RemoteSessionDetails {
        let directory: String
        let lead: SessionModel?
        var changed: [SessionModel] = []
        if let mapped = remoteRoom(sessionID: sessionID) {
            let state = mapped.state
            directory = state.spec.directory
            let leadID = state.spec.leadAgentID ?? state.spec.agents.first?.id
            lead = leadID.flatMap { state.sessions[$0] }.flatMap { session($0) }
            changed = state.spec.agents.compactMap { state.sessions[$0.id] }.compactMap { session($0) }
        } else if let s = session(sessionID), !isHiddenSession(s.id) {
            if !s.transcriptLoaded { await store.loadSession(s.id) }
            directory = s.directory
            lead = s
            changed = [s]
        } else {
            throw MacRemoteHostError.sessionNotFound
        }
        var seen = Set<String>()
        var outputs: [FileChange] = []
        for s in changed {
            for file in s.changedFiles where seen.insert(file.path).inserted {
                var slim = file
                slim.diff = nil
                outputs.append(slim)
            }
        }
        let context = lead.map { store.contextBreakdown(for: $0) }.flatMap { breakdown in
            breakdown.usedTokens > 0 || !breakdown.categories.isEmpty ? breakdown : nil
        }
        return RemoteSessionDetails(
            sessionID: sessionID,
            macName: Self.macName,
            directory: directory,
            extraFolders: lead.map { store.extraFolders[$0.id] ?? [] } ?? [],
            context: context,
            outputs: outputs,
            connectors: store.connectors
        )
    }

    /// The computer name the phone saw when it paired.
    private static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ContextPanelView.hostName
    }

    func requestSecondOpinion(_ request: RemoteSecondOpinionRequest) async throws {
        if remoteRoom(sessionID: request.sessionID) != nil {
            throw RemoteError(.badRequest, "Second opinions are only available in solo sessions.")
        }
        guard let s = session(request.sessionID) else { throw MacRemoteHostError.sessionNotFound }
        if !s.transcriptLoaded { await store.loadSession(s.id) }
        let authoritativeReply: String? = s.items.compactMap { item -> String? in
            guard case .agentText(let id, let text, _, let streaming) = item, id == request.itemID, !streaming else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
        guard let replyText = authoritativeReply else {
            throw RemoteError(.badRequest, "That assistant reply is not available for a second opinion.")
        }
        let ref = ModelRef(providerID: request.providerID, id: request.modelID)
        let beforeCount = AgentToolsCenter.shared.secondOpinions.opinions(for: s.id)[request.itemID]?.count ?? 0
        AgentToolsCenter.shared.requestSecondOpinion(
            in: s,
            itemID: request.itemID,
            replyText: replyText,
            model: ref
        )
        let afterCount = AgentToolsCenter.shared.secondOpinions.opinions(for: s.id)[request.itemID]?.count ?? 0
        guard afterCount > beforeCount else {
            throw RemoteError(.failed, "Second opinions are not ready on this Mac yet.")
        }
        broadcast(.transcriptUpdated(transcript: remoteTranscript(for: s)))
    }

    // MARK: Fonts

    /// Merges the iPhone's font choices and added fonts with this Mac's (`FontSync`).
    private let fonts = FontSyncHost()

    func syncFonts(_ phone: RemoteFontSettings) async throws -> RemoteFontSettings {
        fonts.sync(phone)
    }

    func fontChunk(_ request: RemoteFontFileRequest) async throws -> RemoteFontChunk {
        try fonts.chunk(request)
    }

    func receiveFontChunk(_ chunk: RemoteFontChunk) async throws {
        try fonts.receive(chunk)
    }

    func fontSettingsUpdates() async -> AsyncStream<RemoteFontSettings> {
        fonts.updates()
    }

    func archiveSession(sessionID: String, archived: Bool) async throws {
        if remoteRoom(sessionID: sessionID) != nil {
            throw RemoteError(.badRequest, "Rooms cannot be archived from the iPhone.")
        }
        guard let s = session(sessionID), !s.isSubagent, !isHiddenSession(s.id) else {
            throw MacRemoteHostError.sessionNotFound
        }
        if roomAgentSessionIDs.contains(s.id) {
            throw RemoteError(.badRequest, "Room sessions cannot be archived from the iPhone.")
        }
        await store.archive(s.id, archived: archived)
        if let updated = session(s.id) {
            guard updated.info.archived == archived else {
                throw RemoteError(.failed, store.lastError ?? "Could not archive session.")
            }
            broadcast(.sessionUpserted(session: summary(updated)))
        } else {
            broadcast(.sessionRemoved(sessionID: s.id))
        }
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
