import Foundation
import Observation

/// Shared app state for the Mac and iPhone apps: sessions, transcripts, permissions, usage and panel data.
/// It reads everything through `OpenCodeAPI` and applies the engine's live events, so the preview engine
/// and the real client are interchangeable.
@Observable @MainActor
public final class SessionStore {
    public let engine: any OpenCodeAPI

    /// Every known session, including subagents (child sessions).
    public private(set) var sessions: [SessionModel] = []
    public private(set) var selectedSessionID: String?
    public private(set) var models: [ModelInfo] = []
    public private(set) var providers: [ProviderInfo] = []
    public private(set) var connectors: [ConnectorInfo] = []
    public private(set) var schedules: [ScheduleInfo] = []
    public private(set) var engineVersion: String?
    public private(set) var engineURL: URL?
    public private(set) var isLoaded = false
    /// Last failed action, in a line. Views may show it and clear it.
    public var lastError: String?

    /// Room agents by id, so agent text can show a name and colour.
    public var agents: [UUID: AgentSpec] = [:]
    /// Agents in each session (sidebar colour dots).
    public var sessionAgentIDs: [String: [UUID]] = [:]
    /// Folders a session can use besides its project folder.
    public var extraFolders: [String: [String]] = [:]
    /// Used for new sessions when nothing else is chosen.
    public var defaultModel: ModelRef?
    public var defaultPermissionMode: PermissionMode = .auto

    /// Effort and fast-mode options per model (`ModelRef.description`), from `EngineModelOptionsControl`.
    public internal(set) var modelOptions: [String: ModelOptions] = [:]
    /// The engine's slash commands and skills per project folder, from `EngineCommandsControl`.
    public internal(set) var engineCommands: [String: [EngineCommand]] = [:]
    /// Messages sent while the agent works, per session, oldest first (`SessionStore+Queue.swift`).
    public internal(set) var queues: [String: [QueuedMessage]] = [:]
    /// Open side questions, by the session they ask about (`SideQuestion.swift`).
    public internal(set) var sideQuestions: [String: SideQuestion] = [:]
    /// Temporary sessions behind side questions. Left out of the sidebar until kept.
    public internal(set) var hiddenSessionIDs: Set<String> = []
    /// How each answered plan or question was resolved, by request id (`SessionStore+Interactions.swift`).
    public internal(set) var interactionOutcomes: [String: InteractionOutcome] = [:]
    /// Whether each session can use Plan mode, from `EngineInteractionControl` (loaded with `loadPlanModeSupport`).
    public internal(set) var planSupport: [String: PlanModeSupport] = [:]
    /// Line comments being written on open plans, by request id, then by line index. Kept here so they survive the
    /// card scrolling out of view.
    public var planCommentDrafts: [String: [Int: String]] = [:]
    /// The mode each session was in before it switched to Plan; Proceed returns to it.
    @ObservationIgnored var modeBeforePlan: [String: PermissionMode] = [:]
    /// Background shells, plan limit stops and auto-continue (`SessionStore+Background.swift`, `AutoContinue+Store.swift`).
    public let background = SessionBackgroundState()

    @ObservationIgnored var byID: [String: SessionModel] = [:]
    @ObservationIgnored private(set) var eventTask: Task<Void, Never>?
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
    /// When the user last changed a field of a session here. Events stamped earlier are echoes of older
    /// changes that arrived late through the stream; they must not undo the newer local value.
    @ObservationIgnored private var localEdits: [String: [EditableField: Date]] = [:]
    /// Sessions deleted here or by the engine. Late events for them are dropped so they cannot reappear.
    @ObservationIgnored private var deletedSessionIDs: Set<String> = []
    /// Sessions whose permission rules were checked against the current rules this launch.
    @ObservationIgnored var permissionRulesChecked: Set<String> = []
    /// The launch-time check of every session's permission rules (tests await it).
    @ObservationIgnored var permissionSyncTask: Task<Void, Never>?
    @ObservationIgnored var queueRuntime: [String: QueueRuntime] = [:]
    /// Where side questions' hidden copies are remembered until deleted or kept, so copies left by a quit app are
    /// deleted at the next start. Nil remembers nothing (previews, test runners).
    @ObservationIgnored public var sideQuestionRecordURL: URL?
    /// The start-time deletion of copies left by an earlier run (tests await it).
    @ObservationIgnored var sideQuestionCleanupTask: Task<Void, Never>?
    /// Trust cards put away, messages refused in untrusted folders, trust errors (`SessionStore+Trust.swift`).
    public let trustNotes = SessionTrustNotes()
    /// The rewind sheet and the notices left after rewinds (`Rewind+Store.swift`).
    public let rewinds = SessionRewindState()
    /// Sessions that work in their own git worktree (`SessionWorktree+Store.swift`).
    public let worktrees = SessionWorktrees()

    private enum EditableField: Hashable { case title, archived, model }

    public init(engine: any OpenCodeAPI) {
        self.engine = engine
        self.sideQuestionRecordURL = Self.defaultSideQuestionRecordURL(isPreview: engine is PreviewEngine)
        worktrees.configure(fileURL: SessionWorktrees.defaultURL(isPreview: engine is PreviewEngine))
    }

    /// True when the store runs on sample data instead of a real engine.
    public var isPreview: Bool { engine is PreviewEngine }

    // MARK: - Loading

    /// Loads sessions, models, providers, connectors and pending permissions, then follows live events.
    public func start() async {
        guard eventTask == nil else { return }
        listen()
        do {
            let (version, url) = try await engine.serverInfo()
            engineVersion = version
            engineURL = url
        } catch {
            lastError = "Engine not reachable: \(error.localizedDescription)"
        }
        hideLeftoverSideQuestionCopies()
        await reloadSessions()
        sideQuestionCleanupTask = Task { [weak self] in await self?.deleteLeftoverSideQuestionCopies() }
        async let models = try? engine.models()
        async let providers = try? engine.providers()
        async let connectors = try? engine.connectors()
        async let pending = try? engine.pendingPermissions()
        async let schedules = try? engine.schedules()
        self.models = await models ?? []
        self.providers = await providers ?? []
        self.connectors = await connectors ?? []
        self.schedules = await schedules ?? []
        for request in await pending ?? [] {
            apply(.permissionAsked(request))
        }
        if defaultModel == nil { defaultModel = self.models.first(where: \.available)?.ref }
        isLoaded = true
        if selectedSessionID == nil, let first = sidebarOrder.first {
            select(first.id)
        }
        permissionSyncTask = Task { [weak self] in await self?.syncAllPermissionRules() }
    }

    /// Stops following live events.
    public func stopListening() {
        eventTask?.cancel()
        eventTask = nil
    }

    private func listen() {
        let stream = engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    public func reloadSessions() async {
        // Only sessions known before the request can be missing from its answer; one created by a live
        // event while the list was in flight must stay.
        let knownBefore = Set(byID.keys)
        do {
            let list = try await engine.listSessions()
            for info in list where !deletedSessionIDs.contains(info.id) { upsertSession(info) }
            let listed = Set(list.map(\.id))
            for id in knownBefore.subtracting(listed) { removeSession(id, remember: false) }
        } catch {
            lastError = "Could not load sessions: \(error.localizedDescription)"
        }
    }

    /// Fills the store synchronously (previews and snapshot rendering).
    public func seed(_ seed: StoreSeed) {
        for info in seed.sessions {
            let model = SessionModel(info: info, permissionMode: seed.modes[info.id] ?? defaultPermissionMode)
            model.items = seed.transcripts[info.id] ?? []
            model.transcriptLoaded = true
            model.activity = seed.activities[info.id] ?? .idle
            if model.isWorking { model.workingSince = Date().addingTimeInterval(-42) }
            model.context = seed.contexts[info.id]
            model.changedFiles = seed.changes[info.id] ?? []
            insert(model)
        }
        for request in seed.permissions {
            byID[request.sessionID]?.pendingPermissions.append(request)
        }
        connectors = seed.connectors
        models = seed.models
        providers = seed.providers
        schedules = seed.schedules
        agents = Dictionary(seed.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        sessionAgentIDs = seed.sessionAgentIDs
        extraFolders = seed.extraFolders
        for (sessionID, ids) in seed.sessionAgentIDs where ids.count == 1 {
            byID[sessionID]?.agentID = ids.first
        }
        defaultModel = models.first(where: \.available)?.ref
        engineVersion = "2.3.0"
        isLoaded = true
        selectedSessionID = seed.selectedSessionID ?? sidebarOrder.first?.id
    }

    // MARK: - Queries

    public func session(_ id: String) -> SessionModel? { byID[id] }

    public var selected: SessionModel? { selectedSessionID.flatMap { byID[$0] } }

    /// Top-level, non-archived sessions grouped by folder, most recent project first. A session in its own copy
    /// (`SessionWorktree+Store.swift`) is listed under the project folder the copy was made from.
    public var projects: [ProjectGroup] {
        let visible = sessions.filter { $0.info.parentID == nil && !$0.info.archived && !hiddenSessionIDs.contains($0.id) }
        let grouped = Dictionary(grouping: visible, by: { projectFolder(for: $0) })
        return grouped.map { directory, list in
            ProjectGroup(id: directory, directory: directory, name: Format.folderName(directory),
                         sessions: list.sorted { $0.info.updated > $1.info.updated })
        }
        .sorted { ($0.sessions.first?.info.updated ?? .distantPast) > ($1.sessions.first?.info.updated ?? .distantPast) }
    }

    /// Sessions in sidebar order (Cmd-1 to Cmd-9).
    public var sidebarOrder: [SessionModel] { projects.flatMap(\.sessions) }

    public func children(of sessionID: String) -> [SessionModel] {
        sessions.filter { $0.info.parentID == sessionID }.sorted { $0.info.created < $1.info.created }
    }

    /// Open permission prompts in a session and its subagents.
    public func needsYouCount(_ sessionID: String) -> Int {
        guard let model = byID[sessionID] else { return 0 }
        return model.pendingPermissions.count + children(of: sessionID).reduce(0) { $0 + needsYouCount($1.id) }
    }

    /// True if the session or one of its subagents is working.
    public func isRunning(_ sessionID: String) -> Bool {
        guard let model = byID[sessionID] else { return false }
        return model.isWorking || children(of: sessionID).contains { isRunning($0.id) }
    }

    /// Open permission prompts across all sessions.
    public var needsYouTotal: Int {
        sessions.reduce(0) { $0 + $1.pendingPermissions.count }
    }

    public func model(for ref: ModelRef?) -> ModelInfo? {
        guard let ref else { return nil }
        return models.first { $0.ref.providerID == ref.providerID && $0.ref.id == ref.id }
    }

    /// Human name for a model reference.
    public func modelName(_ ref: ModelRef?) -> String {
        guard let ref else { return "Default model" }
        return model(for: ref)?.name ?? ref.id
    }

    /// Context use for a session, falling back to an empty breakdown sized to its model.
    public func contextBreakdown(for session: SessionModel) -> ContextBreakdown {
        if let context = session.context { return context }
        let limit = model(for: session.info.model)?.contextLimit ?? 200_000
        return ContextBreakdown(usedTokens: 0, limitTokens: limit, categories: [])
    }

    // MARK: - Selection

    /// Selects a session and loads its transcript and panel data the first time.
    public func select(_ sessionID: String?) {
        selectedSessionID = sessionID
        guard let sessionID, let model = byID[sessionID] else { return }
        if !model.transcriptLoaded, loadTasks[sessionID] == nil {
            loadTasks[sessionID] = Task { [weak self] in
                await self?.loadSession(sessionID)
                self?.loadTasks[sessionID] = nil
            }
        } else {
            Task { [weak self] in await self?.refreshPanels(sessionID) }
        }
        if eventTask != nil, !permissionRulesChecked.contains(model.info.parentID ?? sessionID) {
            let topLevel = model.info.parentID ?? sessionID
            Task { [weak self] in await self?.syncPermissionRules(topLevel) }
        }
    }

    /// Loads the full transcript, context and changed files for a session.
    public func loadSession(_ sessionID: String) async {
        guard let model = byID[sessionID] else { return }
        do {
            var items = try await engine.transcript(sessionID)
            for request in model.pendingPermissions where !items.contains(where: { $0.id == request.id }) {
                items.append(.permission(request))
            }
            model.items = items
            model.transcriptLoaded = true
            model.touch()
        } catch {
            model.items.append(.error(id: "load-\(UUID().uuidString)", message: "Could not load this session: \(error.localizedDescription)"))
            model.touch()
        }
        if let kids = try? await engine.children(sessionID) {
            for child in kids where !deletedSessionIDs.contains(child.id) { upsertSession(child) }
        }
        await refreshPanels(sessionID)
    }

    public func refreshPanels(_ sessionID: String) async {
        guard let model = byID[sessionID] else { return }
        if let context = try? await engine.context(sessionID) { model.context = context }
        if let files = try? await engine.changedFiles(sessionID) { model.changedFiles = files }
    }

    public func refreshConnectors() async {
        if let list = try? await engine.connectors() { connectors = list }
    }

    public func refreshProviders() async {
        if let list = try? await engine.providers() { providers = list }
        if let list = try? await engine.models() { models = list }
    }

    // MARK: - Events

    /// Applies one live engine event.
    public func apply(_ event: EngineEvent) {
        defer {
            afterApply(event)
            backgroundDidApply(event)
        }
        switch event {
        case .sessionCreated(let info), .sessionUpdated(let info):
            guard !deletedSessionIDs.contains(info.id) else { return }
            upsertSession(info)

        case .sessionDeleted(let sessionID):
            removeSession(sessionID)

        case .activity(let sessionID, let activity):
            guard let model = byID[sessionID] else { return }
            model.setActivity(activity)
            if activity == .idle || activity == .failed {
                TranscriptReducer.finishStreaming(&model.items)
                model.touch()
            }

        case .textDelta(let sessionID, let itemID, let delta):
            guard let model = byID[sessionID] else { return }
            TranscriptReducer.appendText(&model.items, itemID: itemID, delta: delta, agentID: model.agentID)
            model.touch()

        case .textEnded(let sessionID, let itemID, let text):
            guard let model = byID[sessionID] else { return }
            TranscriptReducer.endText(&model.items, itemID: itemID, text: text, agentID: model.agentID)
            model.touch()

        case .reasoningDelta(let sessionID, let itemID, let delta):
            guard let model = byID[sessionID] else { return }
            TranscriptReducer.appendReasoning(&model.items, itemID: itemID, delta: delta)
            model.touch()

        case .toolUpdated(let sessionID, let tool):
            guard let model = byID[sessionID] else { return }
            TranscriptReducer.upsertTool(&model.items, tool)
            model.touch()

        case .permissionAsked(let asked):
            guard let model = byID[asked.sessionID] else { return }
            let request = prepared(asked)
            if !model.pendingPermissions.contains(where: { $0.id == request.id }) {
                model.pendingPermissions.append(request)
            }
            TranscriptReducer.addPermission(&model.items, request)
            if model.activity == .working { model.setActivity(.waitingForPermission) }
            model.touch()

        case .permissionReplied(let sessionID, let requestID):
            guard let model = byID[sessionID] else { return }
            model.pendingPermissions.removeAll { $0.id == requestID }
            if model.resolutions[requestID] == nil { model.resolutions[requestID] = .answered }
            if model.activity == .waitingForPermission, model.pendingPermissions.isEmpty {
                model.setActivity(.working)
            }
            model.touch()

        case .usageUpdated(let sessionID, let usage):
            guard let model = byID[sessionID] else { return }
            model.usage = usage
            model.info.usage = usage

        case .executionEnded(let sessionID, let outcome, let error):
            guard let model = byID[sessionID] else { return }
            TranscriptReducer.finishStreaming(&model.items)
            if let error, !error.isEmpty {
                model.items.append(.error(id: "error-\(UUID().uuidString)", message: error))
            } else if outcome == "interrupted" {
                model.items.append(.notice(id: "notice-\(UUID().uuidString)", text: "Interrupted"))
            }
            model.setActivity((error?.isEmpty == false || outcome == "failed") ? .failed : .idle)
            model.info.updated = Date()
            model.touch()
            Task { [weak self] in await self?.refreshPanels(sessionID) }

        case .filesChanged:
            if let selected = selectedSessionID {
                Task { [weak self] in await self?.refreshPanels(selected) }
            }

        case .connectorsChanged:
            Task { [weak self] in await self?.refreshConnectors() }

        case .other:
            break
        }
    }

    // MARK: - Actions

    /// Creates a session in `directory` and selects it.
    @discardableResult
    public func newSession(directory: String, model: ModelRef?, permissionMode: PermissionMode) async throws -> SessionModel {
        let info = try await engine.createSession(directory: directory, model: model ?? defaultModel, agent: nil,
                                                  permissionMode: permissionMode, parentID: nil)
        let session = upsertSession(info)
        session.permissionMode = permissionMode
        session.transcriptLoaded = true
        permissionRulesChecked.insert(session.id)
        select(session.id)
        return session
    }

    /// Sends a message to the selected session.
    public func send(_ text: String, files: [URL] = []) async {
        guard let session = selected else { return }
        await send(text, files: files, to: session.id)
    }

    /// While the agent works the message is held in the session's queue and goes out when the turn ends.
    public func send(_ text: String, files: [URL] = [], to sessionID: String) async {
        if enqueueIfBusy(text, files: files, to: sessionID) { return }
        await deliver(text, files: files, to: sessionID)
    }

    /// Shows the message in the transcript and hands it to the engine now.
    func deliver(_ text: String, files: [URL] = [], to sessionID: String) async {
        // Over its provider's daily spending cap (`UsageCaps.swift`): shown as not sent, nothing reaches the engine.
        // Every send goes through here, queued messages and auto-continue included.
        if refuseOverSpendingCap(text, files: files, to: sessionID) { return }
        guard let session = byID[sessionID] else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        var shown = trimmed
        if !files.isEmpty {
            let names = files.map(\.lastPathComponent).joined(separator: ", ")
            shown += shown.isEmpty ? "Attached: \(names)" : "\n\nAttached: \(names)"
        }
        session.items.append(.user(id: "user-\(UUID().uuidString)", text: shown, date: Date()))
        session.setActivity(.working)
        session.info.updated = Date()
        session.touch()
        queueRuntime[sessionID]?.held = false
        do {
            try await engine.prompt(sessionID, text: trimmed, files: files)
        } catch {
            session.items.append(.error(id: "error-\(UUID().uuidString)", message: "Could not send: \(error.localizedDescription)"))
            session.setActivity(.failed)
            session.touch()
            noteSendFailure(error, text: trimmed, files: files, sessionID: sessionID)
        }
    }

    /// Interrupts the selected session.
    public func stop() async {
        guard let session = selected else { return }
        holdQueue(session.id)
        do { try await engine.interrupt(session.id) } catch { lastError = "Could not stop: \(error.localizedDescription)" }
    }

    public func reply(to request: PermissionRequest, decision: PermissionDecision) async {
        if request.isInteraction {
            // Plans and questions have their own answers; Reject keeps planning or declines.
            await replyToInteraction(request, decision: decision)
            return
        }
        guard let session = byID[request.sessionID] else { return }
        session.resolutions[request.id] = PermissionResolution(decision)
        session.pendingPermissions.removeAll { $0.id == request.id }
        if session.activity == .waitingForPermission, session.pendingPermissions.isEmpty {
            session.setActivity(.working)
        }
        session.touch()
        do {
            try await engine.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: decision, message: nil)
        } catch {
            session.resolutions[request.id] = nil
            if !session.pendingPermissions.contains(where: { $0.id == request.id }) {
                session.pendingPermissions.append(request)
            }
            lastError = "Could not answer the prompt: \(error.localizedDescription)"
            session.touch()
        }
    }

    public func switchModel(_ model: ModelRef, for sessionID: String? = nil) async {
        guard let session = sessionID.flatMap({ byID[$0] }) ?? selected else { return }
        let previous = session.info.model
        session.info.model = model
        let edit = noteLocalEdit(session.id, .model)
        do { try await engine.switchModel(session.id, model: model) } catch {
            dropLocalEdit(session.id, .model, at: edit)
            session.info.model = previous
            lastError = "Could not switch model: \(error.localizedDescription)"
        }
    }

    public func setPermissionMode(_ mode: PermissionMode, for sessionID: String? = nil) async {
        guard let session = sessionID.flatMap({ byID[$0] }) ?? selected else { return }
        let previous = session.permissionMode
        if mode == .plan, previous != .plan {
            // Only engines with a real plan mode get one (`EngineInteractionControl`).
            let support = await loadPlanModeSupport(for: session.id)
            guard support.isSupported else {
                lastError = support.reason ?? "This agent has no plan mode."
                return
            }
        }
        session.permissionMode = mode
        permissionRulesChecked.insert(session.id)
        if mode == .plan, previous != .plan { modeBeforePlan[session.id] = previous }
        do { try await engine.setPermissionMode(session.id, mode: mode) } catch {
            session.permissionMode = previous
            lastError = "Could not change permissions: \(error.localizedDescription)"
        }
    }

    public func rename(_ sessionID: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = byID[sessionID], !trimmed.isEmpty else { return }
        let previous = session.info.title
        session.info.title = trimmed
        let edit = noteLocalEdit(sessionID, .title)
        do { try await engine.renameSession(sessionID, title: trimmed) } catch {
            dropLocalEdit(sessionID, .title, at: edit)
            session.info.title = previous
            lastError = "Could not rename: \(error.localizedDescription)"
        }
    }

    public func archive(_ sessionID: String, archived: Bool = true) async {
        guard let session = byID[sessionID] else { return }
        session.info.archived = archived
        let edit = noteLocalEdit(sessionID, .archived)
        if archived, selectedSessionID == sessionID { selectNeighbour(of: sessionID) }
        do { try await engine.setArchived(sessionID, archived: archived) } catch {
            dropLocalEdit(sessionID, .archived, at: edit)
            session.info.archived = !archived
            lastError = "Could not archive: \(error.localizedDescription)"
        }
    }

    public func delete(_ sessionID: String) async {
        do {
            try await engine.deleteSession(sessionID)
            removeSession(sessionID)
        } catch {
            lastError = "Could not delete: \(error.localizedDescription)"
        }
    }

    public func setAPIKey(providerID: String, key: String) async throws {
        try await engine.setAPIKey(providerID: providerID, key: key)
        await refreshProviders()
    }

    public func removeAPIKey(providerID: String) async throws {
        try await engine.removeAPIKey(providerID: providerID)
        await refreshProviders()
    }

    // MARK: - Internals

    @discardableResult
    func upsertSession(_ info: EngineSession) -> SessionModel {
        if let existing = byID[info.id] {
            existing.info = merge(info, over: existing.info)
            if info.usage != .zero { existing.usage = info.usage }
            return existing
        }
        let model = SessionModel(info: info, permissionMode: defaultPermissionMode)
        insert(model)
        return model
    }

    private func insert(_ model: SessionModel) {
        byID[model.id] = model
        sessions.append(model)
    }

    /// Takes the engine's copy of a session, except fields the user changed here after the engine
    /// stamped it (a late echo of an older change). Edits the engine has caught up with are forgotten.
    private func merge(_ incoming: EngineSession, over current: EngineSession) -> EngineSession {
        var result = incoming
        result.updated = max(incoming.updated, current.updated)
        guard var edits = localEdits[incoming.id] else { return result }
        for (field, editedAt) in edits {
            // Only an event stamped strictly after the local edit may override it (equal stamps happen
            // within the clock's resolution and carry the same value).
            if incoming.updated <= editedAt {
                switch field {
                case .title: result.title = current.title
                case .archived: result.archived = current.archived
                case .model: result.model = current.model
                }
            } else {
                edits[field] = nil
            }
        }
        localEdits[incoming.id] = edits.isEmpty ? nil : edits
        return result
    }

    private func noteLocalEdit(_ sessionID: String, _ field: EditableField) -> Date {
        let now = Date()
        localEdits[sessionID, default: [:]][field] = now
        return now
    }

    /// Forgets a local edit whose engine call failed, unless a newer edit replaced it meanwhile.
    private func dropLocalEdit(_ sessionID: String, _ field: EditableField, at time: Date) {
        if localEdits[sessionID]?[field] == time { localEdits[sessionID]?[field] = nil }
    }

    /// Removes a session. `remember` keeps its id so late events cannot bring it back (deletes);
    /// a session that is only missing from a list reload is not remembered.
    private func removeSession(_ sessionID: String, remember: Bool = true) {
        if remember { deletedSessionIDs.insert(sessionID) }
        localEdits[sessionID] = nil
        guard byID[sessionID] != nil else { return }
        if selectedSessionID == sessionID { selectNeighbour(of: sessionID) }
        byID[sessionID] = nil
        sessions.removeAll { $0.id == sessionID }
        sessionAgentIDs[sessionID] = nil
    }

    private func selectNeighbour(of sessionID: String) {
        let order = sidebarOrder.filter { $0.id != sessionID && !$0.info.archived }
        selectedSessionID = nil
        if let next = order.first { select(next.id) }
    }
}
