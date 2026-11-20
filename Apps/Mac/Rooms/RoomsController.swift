import SwiftUI
import EnsembleKit

/// Owns the open rooms of the app: lists saved rooms, creates and reopens `RoomEngine`s (one per room,
/// held strongly while open), tracks permission prompts from room agents, and keeps live transcripts of
/// the agent sessions the room view opens.
@MainActor
@Observable
final class RoomsController {
    weak static var live: RoomsController?

    let api: any OpenCodeAPI
    let store: any RoomStore
    let git: (any GitOps)?

    /// Every saved room, newest first. Open rooms show their engine's live state instead.
    private(set) var saved: [RoomState] = []
    /// True once the saved rooms have been read.
    private(set) var isLoaded = false
    /// Open engines by room id.
    private(set) var engines: [UUID: RoomEngine] = [:]
    /// The room the window shows.
    var selectedRoomID: UUID?
    /// Models for the new room sheet, per project folder ("" = the engine's default location).
    private(set) var modelsByDirectory: [String: [ModelInfo]] = [:]
    /// Open permission prompts from room agents and their subagents, by the agent's room session id.
    private(set) var permissions: [String: [PermissionRequest]] = [:]
    /// Subagent (child) session id -> the room session it belongs to, so subagent prompts show in the room.
    private(set) var childSessions: [String: String] = [:]
    /// Live transcripts of agent sessions the room view opened, by session id.
    private(set) var transcripts: [String: AgentTranscript] = [:]
    var showNewRoom = false
    /// Folder to preselect in the new room sheet.
    var newRoomDirectory: String?
    var lastError: String?

    /// Snapshot rendering: fixed agent activity and streaming text, by agent id.
    var activityOverride: [UUID: AgentActivity] = [:]
    var liveTextOverride: [UUID: String] = [:]

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Sessions already looked up that belong to no room (ordinary chats), so their prompts are not looked up again.
    @ObservationIgnored private var outsideSessions: Set<String> = []

    /// Rooms share one event connection through `SharedEventsAPI` (see there for why).
    init(api: any OpenCodeAPI, store: any RoomStore = FileRoomStore.standard, git: (any GitOps)? = ProcessGitOps()) {
        self.api = api as? SharedEventsAPI ?? SharedEventsAPI(base: api)
        self.store = store
        self.git = git
    }

    /// The engine under the shared event wrapper.
    var baseAPI: any OpenCodeAPI { (api as? SharedEventsAPI)?.base ?? api }

    // MARK: Loading

    /// Lists saved rooms, loads the model list and follows permission prompts and agent transcripts.
    func start() async {
        Self.live = self
        AgentToolsCenter.shared.rooms = self
        reload()
        guard eventTask == nil else { return }
        let stream = api.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
        await refreshPermissions()
        await loadModels(directory: nil)
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        for engine in engines.values { engine.close() }
    }

    /// Fills the controller with ready-made engines and data, without the engine's event stream (snapshots).
    func seed(engines list: [RoomEngine], models: [ModelInfo], permissions requests: [PermissionRequest] = [],
              transcripts seeded: [AgentTranscript] = []) {
        for engine in list { engines[engine.state.id] = engine }
        saved = list.map(\.state).reversed()
        modelsByDirectory[""] = models
        isLoaded = true
        for request in requests {
            permissions[roomSession(for: request.sessionID) ?? request.sessionID, default: []].append(request)
        }
        for transcript in seeded { transcripts[transcript.sessionID] = transcript }
    }

    func reload() {
        do {
            saved = try store.list().reversed()
            isLoaded = true
        } catch {
            lastError = "Could not read saved rooms: \(error.localizedDescription)"
        }
    }

    func models(for directory: String?) -> [ModelInfo] {
        modelsByDirectory[directory ?? ""] ?? modelsByDirectory[""] ?? []
    }

    /// Models can differ per project folder (a project `opencode.json` can add providers). Through the engine router
    /// the list has every engine's models (Claude, Gemini and OpenCode), so a room can mix them.
    func loadModels(directory: String?) async {
        do {
            let list: [ModelInfo]
            if let folders = api as? any EngineFolderModels, let directory, !directory.isEmpty {
                list = try await folders.models(directory: directory)
            } else {
                list = try await api.models()
            }
            modelsByDirectory[directory ?? ""] = list
        } catch {
            if modelsByDirectory[directory ?? ""] == nil { modelsByDirectory[directory ?? ""] = [] }
        }
    }

    func refreshPermissions() async {
        guard let pending = try? await api.pendingPermissions() else { return }
        if pending.contains(where: { roomSession(for: $0.sessionID) == nil && !outsideSessions.contains($0.sessionID) }) {
            await refreshChildSessions()
        }
        var next: [String: [PermissionRequest]] = [:]
        for request in pending {
            guard let root = roomSession(for: request.sessionID) else { continue }
            next[root, default: []].append(request)
        }
        permissions = next
    }

    /// Learns which sessions are subagents of room agents (for prompts that arrived before Ensemble started).
    func refreshChildSessions() async {
        guard let sessions = try? await api.listSessions() else { return }
        let parents = Dictionary(sessions.compactMap { s in s.parentID.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let roots = roomSessionIDs
        for session in sessions where childSessions[session.id] == nil && !roots.contains(session.id) {
            var current = session.id
            var hops = 0
            var found: String?
            while let parent = parents[current], hops < 16 {
                if roots.contains(parent) {
                    found = parent
                    break
                }
                current = parent
                hops += 1
            }
            if let found { childSessions[session.id] = found } else { outsideSessions.insert(session.id) }
        }
    }

    /// The room session a session belongs to: itself for an agent's session, its agent's for a subagent.
    func roomSession(for sessionID: String) -> String? {
        if roomSessionIDs.contains(sessionID) { return sessionID }
        return childSessions[sessionID]
    }

    // MARK: Rooms

    /// Every room in sidebar order: open rooms with live state, then saved ones.
    var rooms: [RoomState] {
        saved.map { engines[$0.id]?.state ?? $0 }
    }

    func state(_ roomID: UUID) -> RoomState? {
        engines[roomID]?.state ?? saved.first { $0.id == roomID }
    }

    /// The engine for a room, reopening it from disk the first time.
    func engine(for roomID: UUID) -> RoomEngine? {
        if let engine = engines[roomID] { return engine }
        do {
            guard let engine = try RoomEngine.load(roomID: roomID, api: api, store: store, git: git) else { return nil }
            engines[roomID] = engine
            return engine
        } catch {
            lastError = "Could not open the room: \(error.localizedDescription)"
            return nil
        }
    }

    /// The selected room's engine. Safe to read from a view body: `select(_:)` opens the engine.
    var selectedEngine: RoomEngine? {
        selectedRoomID.flatMap { engines[$0] }
    }

    /// Shows a room, reopening its engine from disk the first time.
    func select(_ roomID: UUID?) {
        selectedRoomID = roomID
        if let roomID { _ = engine(for: roomID) }
    }

    func beginNewRoom(in directory: String? = nil) {
        newRoomDirectory = directory
        showNewRoom = true
    }

    /// Creates the room's sessions and briefs its agents. With `userLeads`, the user takes the lead
    /// right after (Team and Round table otherwise fall back to the first agent).
    @discardableResult
    func create(spec: RoomSpec, userLeads: Bool = false) async throws -> RoomEngine {
        let engine: RoomEngine
        do {
            engine = try await RoomEngine.create(spec: spec, api: api, store: store, git: git)
        } catch {
            // The engine saves the room before opening sessions; remove the half-made room and its sessions.
            if let partial = try? store.load(spec.id) {
                for sid in partial.sessions.values { try? await api.deleteSession(sid) }
                try? store.delete(spec.id)
            }
            reload()
            throw error
        }
        if userLeads && spec.mode != .debate { engine.takeOver() }
        engines[spec.id] = engine
        reload()
        selectedRoomID = spec.id
        return engine
    }

    /// Promotes a solo session into a live room with its current model as Participant #1 (Lead) plus 1 to 3
    /// additional models, injecting a compact context handoff summary (capped at 12,000 chars) to every participant.
    @discardableResult
    func promoteSessionToRoom(
        session: SessionModel,
        store: SessionStore,
        title: String,
        additionalModels: [ModelInfo],
        mode: RoomMode,
        starterPrompt: String = ""
    ) async throws -> RoomEngine {
        let leadModel = session.info.model
            ?? store.models.first(where: \.available)?.ref
            ?? ModelRef(providerID: "anthropic", id: "claude-sonnet-4")
        let leadInfo = store.models.first { $0.ref == leadModel }
            ?? ModelInfo(ref: leadModel, name: store.modelName(leadModel), providerName: leadModel.providerID)

        var usedColors: [String] = []
        var usedNames: [String] = []

        let leadColor = RoomPalette.next(after: usedColors)
        usedColors.append(leadColor)
        let leadName = NewRoomDraft.defaultName(for: leadInfo, taken: usedNames)
        usedNames.append(leadName)
        let leadAgent = AgentSpec(
            name: leadName,
            model: leadModel,
            role: "Lead from solo session",
            colorHex: leadColor
        )

        var agents = [leadAgent]
        for model in additionalModels.prefix(3) {
            let color = RoomPalette.next(after: usedColors)
            usedColors.append(color)
            let name = NewRoomDraft.defaultName(for: model, taken: usedNames)
            usedNames.append(name)
            agents.append(
                AgentSpec(
                    name: name,
                    model: model.ref,
                    role: "",
                    colorHex: color
                )
            )
        }

        let folder = store.projectFolder(for: session)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = session.info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomTitle = cleanTitle.isEmpty
            ? (fallbackTitle.isEmpty ? Format.folderName(folder) : fallbackTitle)
            : cleanTitle
        let permMode: PermissionMode = session.permissionMode == .plan ? .ask : session.permissionMode
        let spec = RoomSpec(
            title: roomTitle,
            directory: folder,
            agents: agents,
            mode: mode,
            leadAgentID: mode == .debate ? nil : leadAgent.id,
            permissionMode: permMode
        )

        let engine = try await create(spec: spec, userLeads: false)

        let handoff = RoomHandoffBuilder.build(
            title: roomTitle,
            directory: folder,
            modelName: store.modelName(leadModel),
            items: session.items,
            changedFiles: session.changedFiles
        )
        for agent in spec.agents {
            if let sid = engine.sessionID(for: agent.id) {
                try? await api.injectSynthetic(sid, text: handoff, wake: false)
            }
        }

        syncAgents(into: store)
        let trimmedPrompt = starterPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = trimmedPrompt.isEmpty
            ? "Continue from the handed-off solo conversation context and collaborate on next steps."
            : trimmedPrompt
        await engine.start(task: task)
        return engine
    }

    /// Stops listening to a room. Its sessions, board and file stay.
    func close(_ roomID: UUID) {
        engines[roomID]?.close()
        engines[roomID] = nil
    }

    /// Removes the room's saved file. Its engine sessions stay in the session list.
    func delete(_ roomID: UUID) {
        close(roomID)
        do {
            try store.delete(roomID)
        } catch {
            lastError = "Could not delete the room: \(error.localizedDescription)"
        }
        if selectedRoomID == roomID { selectedRoomID = nil }
        reload()
    }

    // MARK: Status for the sidebar

    func isRunning(_ roomID: UUID) -> Bool {
        guard let engine = engines[roomID] else { return false }
        let state = engine.state
        if state.phase.isRunning && !state.isPaused { return true }
        return state.spec.agents.contains { activity(of: $0.id, in: engine) == .working }
    }

    /// Decisions, room-made pauses and permission prompts waiting on the user.
    func needsYouCount(_ roomID: UUID) -> Int {
        guard let state = state(roomID) else { return 0 }
        let prompts = state.sessions.values.reduce(0) { $0 + (permissions[$1]?.count ?? 0) }
        return prompts + (state.needsUser ? 1 : 0)
    }

    var needsYouTotal: Int {
        rooms.reduce(0) { $0 + needsYouCount($1.id) }
    }

    /// Rooms waiting on a decision from the user (plan approval, a review stalemate, a verdict, a merge, a pause the
    /// room made). Permission prompts are left out: room agents' sessions are in the session list, which counts
    /// their prompts already.
    var decisionsWaiting: Int {
        rooms.filter(\.needsUser).count
    }

    /// Session ids that belong to rooms (the session list may want to hide or tag them).
    var roomSessionIDs: Set<String> {
        Set(rooms.flatMap { $0.sessions.values })
    }

    /// Agents by session id, for name and colour on agent text in the shared transcript views.
    var agentsBySession: [String: AgentSpec] {
        var out: [String: AgentSpec] = [:]
        for room in rooms {
            for agent in room.spec.agents {
                if let sid = room.sessions[agent.id] { out[sid] = agent }
            }
        }
        return out
    }

    /// Gives the session store each room agent's name and colour, so room sessions show them in the session list
    /// and in the normal session view. Call after `start()` and when `rooms` changes.
    func syncAgents(into store: SessionStore) {
        Self.live = self
        AgentToolsCenter.shared.rooms = self
        for room in rooms {
            for agent in room.spec.agents {
                if store.agents[agent.id] != agent { store.agents[agent.id] = agent }
                if let sid = room.sessions[agent.id], store.sessionAgentIDs[sid] != [agent.id] {
                    store.sessionAgentIDs[sid] = [agent.id]
                }
            }
        }
    }

    // MARK: Agents

    func activity(of agentID: UUID, in engine: RoomEngine) -> AgentActivity {
        if let forced = activityOverride[agentID] { return forced }
        if let sid = engine.sessionID(for: agentID), !(permissions[sid] ?? []).isEmpty,
           engine.activity[agentID] != .capped {
            return .waitingForPermission
        }
        let own = engine.activity[agentID] ?? .idle
        // OpenCode runs subagents in the background: the agent's own turn can end while they work.
        if own == .idle, engine.hasWorkingSubagents(agentID) { return .working }
        return own
    }

    func liveText(of agentID: UUID, in engine: RoomEngine) -> String? {
        if let forced = liveTextOverride[agentID] { return forced }
        let text = engine.liveText[agentID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Open prompts from this room's agents, oldest first.
    func pendingPermissions(in engine: RoomEngine) -> [(agent: AgentSpec, request: PermissionRequest)] {
        var out: [(AgentSpec, PermissionRequest)] = []
        for agent in engine.agents {
            guard let sid = engine.sessionID(for: agent.id) else { continue }
            for request in permissions[sid] ?? [] { out.append((agent, request)) }
        }
        return out.sorted { $0.1.created < $1.1.created }
    }

    func reply(to request: PermissionRequest, decision: PermissionDecision) async {
        let root = roomSession(for: request.sessionID) ?? request.sessionID
        permissions[root]?.removeAll { $0.id == request.id }
        if permissions[root]?.isEmpty == true { permissions[root] = nil }
        transcripts[root]?.resolutions[request.id] = PermissionResolution(decision)
        do {
            try await api.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: decision, message: nil)
        } catch {
            if !(permissions[root] ?? []).contains(where: { $0.id == request.id }) {
                permissions[root, default: []].append(request)
            }
            transcripts[root]?.resolutions[request.id] = nil
            lastError = "Could not answer the prompt: \(error.localizedDescription)"
        }
    }

    /// The live transcript of one agent's own session, loading it the first time.
    func transcript(for sessionID: String, agentID: UUID) -> AgentTranscript {
        if let existing = transcripts[sessionID] { return existing }
        let model = AgentTranscript(sessionID: sessionID, agentID: agentID)
        transcripts[sessionID] = model
        Task { await self.loadTranscript(model) }
        return model
    }

    func loadTranscript(_ model: AgentTranscript) async {
        do {
            var items = try await api.transcript(model.sessionID)
            items = items.map { item in
                if case .agentText(let id, let text, nil, let streaming) = item {
                    return .agentText(id: id, text: text, agentID: model.agentID, streaming: streaming)
                }
                return item
            }
            for request in permissions[model.sessionID] ?? [] where !items.contains(where: { $0.id == request.id }) {
                items.append(.permission(request))
            }
            model.items = items
            model.loaded = true
        } catch {
            model.items = [.error(id: "load-\(model.sessionID)", message: "Could not load this session: \(error.localizedDescription)")]
            model.loaded = true
        }
    }

    // MARK: Events

    func apply(_ event: EngineEvent) {
        switch event {
        case .sessionCreated(let session):
            if let parent = session.parentID, let root = roomSession(for: parent) { childSessions[session.id] = root }
        case .permissionAsked(let request):
            guard let root = roomSession(for: request.sessionID) else {
                // Maybe a subagent created before Ensemble started: look it up once.
                guard !outsideSessions.contains(request.sessionID) else { return }
                Task {
                    await self.refreshChildSessions()
                    if self.roomSession(for: request.sessionID) != nil { self.apply(.permissionAsked(request)) }
                }
                return
            }
            if !(permissions[root] ?? []).contains(where: { $0.id == request.id }) {
                permissions[root, default: []].append(request)
            }
            if let model = transcripts[root] { TranscriptReducer.addPermission(&model.items, request) }
        case .permissionReplied(let sid, let requestID):
            let root = roomSession(for: sid) ?? sid
            permissions[root]?.removeAll { $0.id == requestID }
            if permissions[root]?.isEmpty == true { permissions[root] = nil }
            if let model = transcripts[root], model.resolutions[requestID] == nil { model.resolutions[requestID] = .answered }
        case .textDelta(let sid, let item, let delta):
            guard let model = transcripts[sid] else { return }
            TranscriptReducer.appendText(&model.items, itemID: item, delta: delta, agentID: model.agentID)
        case .textEnded(let sid, let item, let text):
            guard let model = transcripts[sid] else { return }
            TranscriptReducer.endText(&model.items, itemID: item, text: text, agentID: model.agentID)
        case .reasoningDelta(let sid, let item, let delta):
            guard let model = transcripts[sid] else { return }
            TranscriptReducer.appendReasoning(&model.items, itemID: item, delta: delta)
        case .toolUpdated(let sid, let tool):
            guard let model = transcripts[sid] else { return }
            TranscriptReducer.upsertTool(&model.items, tool)
        case .executionEnded(let sid, _, _):
            guard let model = transcripts[sid] else { return }
            TranscriptReducer.finishStreaming(&model.items)
            // Room messages (synthetic) reach the session without stream events: reload once the turn ends.
            Task { await self.loadTranscript(model) }
        case .other(let type) where type == "server.connected":
            Task { await self.refreshPermissions() }
        default:
            break
        }
    }
}

/// One agent's own session transcript, shown from the room view with the shared transcript views.
@MainActor
@Observable
final class AgentTranscript {
    let sessionID: String
    let agentID: UUID
    var items: [TranscriptItem] = []
    var resolutions: [String: PermissionResolution] = [:]
    var loaded = false

    init(sessionID: String, agentID: UUID, items: [TranscriptItem] = [], loaded: Bool = false) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.items = items
        self.loaded = loaded
    }
}
