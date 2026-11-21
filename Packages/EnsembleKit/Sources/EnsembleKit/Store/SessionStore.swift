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
    /// A session an engine would not start because its folder is not trusted, waiting for the user to trust it
    /// (`SessionStore+Trust.swift`). Views ask, then call `trustAndRetry` or clear it.
    public var pendingFolderTrust: PendingFolderTrust?

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
    /// Cross-engine backing sessions linked under a primary conversation; hidden from sidebar and Hub lists.
    public var hiddenLinkedSessionIDs: Set<String> { threadLinks.hiddenLinkedSessionIDs }
    /// Model staged for the next sent message, keyed by primary session id.
    public internal(set) var pendingNextModel: [String: ModelRef] = [:]
    /// Persisted mapping between primary conversations and their cross-engine backing sessions.
    public let threadLinks = SessionThreadLinks()
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
    /// Which session started which, for nesting in the sidebar (`SessionLinks.swift`).
    public let sessionLinks = SessionLinks()

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
    /// The safety check for Auto: decides OpenCode permission prompts before they are shown (`SafetyCheck+Store.swift`).
    public let safetyCheck = SafetyCheckState()
    /// Goals that keep a session working until a condition is met (`GoalStore.swift`).
    public let goals = SessionGoals()
    /// Backing session id that emitted each open permission/interaction request id.
    @ObservationIgnored var permissionBackingSessions: [String: String] = [:]
    /// Per-backing-session usage accumulated into a primary thread.
    @ObservationIgnored var backingUsage: [String: [String: Usage]] = [:]
    /// Primary session ids currently executing `deliver(...)` (including pre-send model/engine switches).
    @ObservationIgnored var deliveringSessionIDs: Set<String> = []
    /// Primary session ids currently restarting onto another engine in `changeModel(...)`.
    @ObservationIgnored var restartingSessionIDs: Set<String> = []
    /// Called with the primary session id when a user message is delivered to the engine.
    /// Messages another agent delivered (`message_agent`, framed as untrusted peer data) are not the user's turn, so
    /// they never reach this hook: otherwise each delivery would reset the agent-to-agent hop limit.
    @ObservationIgnored public var onUserMessageSent: (@MainActor @Sendable (String) -> Void)?

    func noteUserMessageSent(_ primaryID: String, text: String) {
        guard !AgentToolText.isUntrustedPeerFrame(text) else { return }
        onUserMessageSent?(primaryID)
    }

    private enum EditableField: Hashable { case title, archived, model }

    public init(engine: any OpenCodeAPI) {
        self.engine = engine
        self.sideQuestionRecordURL = Self.defaultSideQuestionRecordURL(isPreview: engine is PreviewEngine)
        worktrees.configure(fileURL: SessionWorktrees.defaultURL(isPreview: engine is PreviewEngine))
        threadLinks.configure(fileURL: SessionThreadLinks.defaultURL(isPreview: engine is PreviewEngine))
        sessionLinks.configure(fileURL: SessionLinks.defaultURL(isPreview: engine is PreviewEngine))
        syncRouterThreadLinks()
    }

    public convenience init(engine: any OpenCodeAPI, threadLinksURL: URL?) {
        self.init(engine: engine)
        threadLinks.configure(fileURL: threadLinksURL)
        syncRouterThreadLinks()
    }

    /// True when the store runs on sample data instead of a real engine.
    public var isPreview: Bool { engine is PreviewEngine }

    /// True while the store is reading live events from `engine.events()`.
    public var isListening: Bool { eventTask != nil }

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
        let knownBefore = Set(byID.values.map(\.id))
        do {
            let list = try await engine.listSessions()
            let visible = list.filter { !deletedSessionIDs.contains($0.id) }
            // Pass 1: primary and regular sessions first so `byID[primaryID]` exists for linked backing sessions.
            for info in visible where !hiddenLinkedSessionIDs.contains(info.id) {
                upsertSession(info)
            }
            // Pass 2: fold linked backing sessions' timestamps and usage into their primary thread.
            for info in visible where hiddenLinkedSessionIDs.contains(info.id) {
                upsertSession(info)
            }
            let listed = Set(list.map(\.id))
            for id in knownBefore.subtracting(listed) { removeSession(id, remember: false) }
        } catch {
            lastError = "Could not load sessions: \(error.localizedDescription)"
        }
        await refreshImportedSessionLinks()
    }

    /// Fills the store synchronously (previews and snapshot rendering).
    public func seed(_ seed: StoreSeed) {
        for info in seed.sessions {
            let model = SessionModel(info: info, permissionMode: seed.modes[info.id] ?? defaultPermissionMode)
            model.items = seed.transcripts[info.id] ?? []
            let rowIDs = Set(model.items.map(\.id))
            model.attachments = seed.attachments.filter { rowIDs.contains($0.key) }
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

    public func session(_ id: String) -> SessionModel? {
        hiddenLinkedSessionIDs.contains(id) ? nil : byID[id]
    }

    /// Resolves `id` even when it is a hidden cross-engine backing session, returning its owning primary session.
    public func sessionIncludingLinked(_ id: String) -> SessionModel? {
        byID[primarySessionID(for: id)]
    }

    public var selected: SessionModel? { selectedSessionID.flatMap { byID[$0] } }

    /// Top-level, non-archived sessions grouped by folder, most recent project first. A session in its own copy
    /// (`SessionWorktree+Store.swift`) is listed under the project folder the copy was made from.
    public var projects: [ProjectGroup] {
        let visible = sessions.filter {
            $0.info.parentID == nil && !$0.info.archived && !hiddenSessionIDs.contains($0.id) && !hiddenLinkedSessionIDs.contains($0.id)
        }
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
        let resolvedID = sessionID.map { primarySessionID(for: $0) }
        selectedSessionID = resolvedID
        guard let resolvedID, let model = byID[resolvedID] else { return }
        if !model.transcriptLoaded {
            _ = loadTask(for: resolvedID)
        } else {
            Task { [weak self] in await self?.refreshPanels(resolvedID) }
        }
        if eventTask != nil, !permissionRulesChecked.contains(model.info.parentID ?? resolvedID) {
            let topLevel = model.info.parentID ?? resolvedID
            Task { [weak self] in await self?.syncPermissionRules(topLevel) }
        }
    }

    /// Loads the full transcript, context and changed files for a session, coalescing concurrent loads.
    public func loadSession(_ sessionID: String) async {
        let primaryID = primarySessionID(for: sessionID)
        guard byID[primaryID] != nil else { return }
        await loadTask(for: primaryID).value
    }

    private func loadTask(for primaryID: String) -> Task<Void, Never> {
        if let existing = loadTasks[primaryID] { return existing }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadTasks[primaryID] = nil }
            await self.performLoadSession(primaryID)
        }
        loadTasks[primaryID] = task
        return task
    }

    private func performLoadSession(_ primaryID: String) async {
        guard let model = byID[primaryID] else { return }
        let itemsBeforeLoad = model.items
        do {
            let links = threadLinks.links(for: primaryID)
            let fetched = links.isEmpty
                ? try await fetchTranscript(primaryID, for: primaryID)
                : try await loadMergedTranscript(for: primaryID, links: links)
            guard byID[primaryID] === model else { return }
            model.items = Self.mergeLoadedTranscript(
                fetched: fetched,
                beforeLoad: itemsBeforeLoad,
                current: model.items,
                pendingPermissions: model.pendingPermissions,
                isWorking: model.isWorking
            )
            model.transcriptLoaded = true
            model.touch()
        } catch {
            guard byID[primaryID] === model else { return }
            model.items.append(.error(id: "load-\(UUID().uuidString)", message: "Could not load this session: \(error.localizedDescription)"))
            model.touch()
        }
        for id in threadLinks.allBackingIDs(for: primaryID) {
            if let kids = try? await engine.children(id) {
                for child in kids where !deletedSessionIDs.contains(child.id) { upsertSession(child) }
            }
        }
        await refreshPanels(primaryID)
    }

    /// One engine session's transcript. When the engine keeps the pictures and files attached to messages
    /// (`EngineMessageAttachments`) they are noted on the conversation `primaryID` shows, by message row id.
    func fetchTranscript(_ sessionID: String, for primaryID: String) async throws -> [TranscriptItem] {
        guard let source = engine as? any EngineMessageAttachments else { return try await engine.transcript(sessionID) }
        let fetched = try await source.attachedTranscript(sessionID)
        if !fetched.attachments.isEmpty, let model = byID[primaryID] {
            model.attachments.merge(fetched.attachments) { _, new in new }
        }
        return fetched.items
    }

    /// Merges a fetched transcript with live or optimistic items appended before or during the fetch so
    /// streaming replies, active tools, and newly sent turns are never wiped by a late transcript load.
    private static func mergeLoadedTranscript(
        fetched: [TranscriptItem],
        beforeLoad: [TranscriptItem],
        current: [TranscriptItem],
        pendingPermissions: [PermissionRequest],
        isWorking: Bool
    ) -> [TranscriptItem] {
        var merged = fetched
        var indexByID: [String: Int] = [:]
        for (index, item) in merged.enumerated() {
            indexByID[item.id] = index
        }
        for request in pendingPermissions where indexByID[request.id] == nil {
            indexByID[request.id] = merged.count
            merged.append(.permission(request))
        }

        let beforeByID = Dictionary(beforeLoad.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for item in current {
            let beforeItem = beforeByID[item.id]
            let wasPresentBefore = beforeItem != nil
            let changedDuringLoad = !wasPresentBefore || beforeItem != item
            let isActivelyLive = isLiveTranscriptItem(item)

            if let existingIndex = indexByID[item.id] {
                if changedDuringLoad || isActivelyLive {
                    merged[existingIndex] = item
                }
                continue
            }

            if !wasPresentBefore || isActivelyLive {
                indexByID[item.id] = merged.count
                merged.append(item)
            } else if isWorking, isOptimisticUserItem(item), !isDuplicateOptimisticUser(item, in: fetched) {
                indexByID[item.id] = merged.count
                merged.append(item)
            }
        }
        return merged
    }

    private static func isLiveTranscriptItem(_ item: TranscriptItem) -> Bool {
        switch item {
        case .agentText(_, _, _, let streaming): streaming
        case .reasoning(_, _, let streaming): streaming
        case .tool(let tool): tool.status == .running || tool.status == .pending
        default: false
        }
    }

    private static func isOptimisticUserItem(_ item: TranscriptItem) -> Bool {
        if case .user(let id, _, _) = item {
            return id.hasPrefix("user-")
        }
        return false
    }

    private static func isDuplicateOptimisticUser(_ item: TranscriptItem, in fetched: [TranscriptItem]) -> Bool {
        guard case .user(_, let text, _) = item else { return false }
        for candidate in fetched.reversed() {
            if case .user(_, let fetchedText, _) = candidate {
                return CrossEngineHandoff.stripHandoff(from: fetchedText) == text
            }
        }
        return false
    }

    public func refreshPanels(_ sessionID: String) async {
        let primaryID = primarySessionID(for: sessionID)
        guard let model = byID[primaryID] else { return }
        let activeBackingID = backingSessionID(for: primaryID)
        if let context = try? await engine.context(activeBackingID) { model.context = context }
        let linked = threadLinks.allBackingIDs(for: primaryID)
        if linked.count <= 1 {
            if let files = try? await engine.changedFiles(activeBackingID) { model.changedFiles = files }
        } else {
            var merged: [FileChange] = []
            var indexByPath: [String: Int] = [:]
            for id in linked {
                guard let files = try? await engine.changedFiles(id) else { continue }
                for file in files {
                    if let existing = indexByPath[file.path] {
                        merged[existing] = file
                    } else {
                        indexByPath[file.path] = merged.count
                        merged.append(file)
                    }
                }
            }
            model.changedFiles = merged
        }
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
        let resolvedEvent = resolveLinkedEvent(event)
        var shouldNotifyHooks = true
        defer {
            if shouldNotifyHooks {
                afterApply(resolvedEvent)
                backgroundDidApply(resolvedEvent)
                goalDidApply(resolvedEvent)
            }
        }
        switch event {
        case .sessionCreated(let info), .sessionUpdated(let info):
            guard !deletedSessionIDs.contains(info.id) else { return }
            upsertSession(info)

        case .sessionDeleted(let sessionID):
            removeSession(sessionID)

        case .activity(let sourceID, let activity):
            let primaryID = primarySessionID(for: sourceID)
            guard let model = byID[primaryID] else { return }
            if (activity == .idle || activity == .failed),
               threadLinks.hasLinks(for: primaryID),
               sourceID != backingSessionID(for: primaryID),
               model.isWorking {
                shouldNotifyHooks = false
                return
            }
            if activity == .waitingForPermission, model.pendingPermissions.isEmpty {
                // Prompts held or already answered by the safety check must not flash the session into waiting state.
                shouldNotifyHooks = false
                return
            }
            model.setActivity(activity)
            if activity == .idle || activity == .failed {
                TranscriptReducer.finishStreaming(&model.items)
                model.touch()
            }

        case .textDelta(let sourceID, let itemID, let delta):
            guard let model = byID[primarySessionID(for: sourceID)] else { return }
            TranscriptReducer.appendText(&model.items, itemID: itemID, delta: delta, agentID: model.agentID)
            model.touch()

        case .textEnded(let sourceID, let itemID, let text):
            guard let model = byID[primarySessionID(for: sourceID)] else { return }
            TranscriptReducer.endText(&model.items, itemID: itemID, text: text, agentID: model.agentID)
            model.touch()

        case .reasoningDelta(let sourceID, let itemID, let delta):
            guard let model = byID[primarySessionID(for: sourceID)] else { return }
            TranscriptReducer.appendReasoning(&model.items, itemID: itemID, delta: delta)
            model.touch()

        case .toolUpdated(let sourceID, let tool):
            guard let model = byID[primarySessionID(for: sourceID)] else { return }
            TranscriptReducer.upsertTool(&model.items, tool)
            model.touch()

        case .permissionAsked(let asked):
            let primaryID = primarySessionID(for: asked.sessionID)
            guard let model = byID[primaryID] else { return }
            permissionBackingSessions[asked.id] = asked.sessionID
            if hiddenSessionIDs.contains(asked.sessionID) || model.info.parentID.map(hiddenSessionIDs.contains) == true {
                // Hidden helper sessions (side questions, one-shot drafts) must never flash permission cards or alerts.
                return
            }
            // The safety check for Auto may answer it first; it is then shown only if the check leaves it to the user.
            if safetyCheckHolds(asked) { return }
            let request = prepared(asked)
            let isNew = !model.pendingPermissions.contains(where: { $0.id == request.id })
            if isNew {
                model.pendingPermissions.append(request)
            }
            TranscriptReducer.addPermission(&model.items, request)
            if model.activity == .working || safetyCheck.released.contains(request.id) {
                model.setActivity(.waitingForPermission)
            }
            model.touch()
            if isNew {
                safetyCheck.notifyPermissionVisible(request)
            }

        case .permissionReplied(let sourceID, let requestID):
            permissionBackingSessions.removeValue(forKey: requestID)
            guard let model = byID[primarySessionID(for: sourceID)] else { return }
            model.pendingPermissions.removeAll { $0.id == requestID }
            if model.resolutions[requestID] == nil { model.resolutions[requestID] = .answered }
            if model.activity == .waitingForPermission, model.pendingPermissions.isEmpty {
                model.setActivity(.working)
            }
            model.touch()

        case .usageUpdated(let sourceID, let usage):
            let primaryID = primarySessionID(for: sourceID)
            guard let model = byID[primaryID] else { return }
            foldUsage(usage, from: sourceID, into: model)

        case .executionEnded(let sourceID, let outcome, let error):
            let primaryID = primarySessionID(for: sourceID)
            guard let model = byID[primaryID] else { return }
            if threadLinks.hasLinks(for: primaryID),
               sourceID != backingSessionID(for: primaryID),
               model.isWorking {
                shouldNotifyHooks = false
                return
            }
            TranscriptReducer.finishStreaming(&model.items)
            if let error, !error.isEmpty {
                model.items.append(.error(id: "error-\(UUID().uuidString)", message: error))
            } else if outcome == "interrupted" {
                model.items.append(.notice(id: "notice-\(UUID().uuidString)", text: "Interrupted"))
            }
            model.setActivity((error?.isEmpty == false || outcome == "failed") ? .failed : .idle)
            model.info.updated = Date()
            model.touch()
            Task { [weak self] in await self?.refreshPanels(primaryID) }

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

    private func resolveLinkedEvent(_ event: EngineEvent) -> EngineEvent {
        switch event {
        case .activity(let sessionID, let activity):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .activity(sessionID: mapped, activity)
        case .textDelta(let sessionID, let itemID, let delta):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .textDelta(sessionID: mapped, itemID: itemID, delta: delta)
        case .textEnded(let sessionID, let itemID, let text):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .textEnded(sessionID: mapped, itemID: itemID, text: text)
        case .reasoningDelta(let sessionID, let itemID, let delta):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .reasoningDelta(sessionID: mapped, itemID: itemID, delta: delta)
        case .toolUpdated(let sessionID, let tool):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .toolUpdated(sessionID: mapped, tool)
        case .permissionReplied(let sessionID, let requestID):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .permissionReplied(sessionID: mapped, requestID: requestID)
        case .usageUpdated(let sessionID, let usage):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .usageUpdated(sessionID: mapped, usage)
        case .executionEnded(let sessionID, let outcome, let error):
            let mapped = primarySessionID(for: sessionID)
            return mapped == sessionID ? event : .executionEnded(sessionID: mapped, outcome: outcome, error: error)
        case .sessionCreated, .sessionUpdated, .sessionDeleted, .permissionAsked, .filesChanged, .connectorsChanged, .other:
            return event
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
        // `/goal` is Ensemble's own command wherever the text comes from (composer, phone, queue).
        if files.isEmpty, let command = SlashCommands.parse(text), command.name.lowercased() == "goal" {
            runGoalCommand(command.arguments, in: sessionID)
            return
        }
        if enqueueIfBusy(text, files: files, to: sessionID) { return }
        await deliver(text, files: files, to: sessionID)
    }

    /// Shows the message in the transcript and hands it to the engine now.
    func deliver(_ text: String, files: [URL] = [], to sessionID: String) async {
        let primaryID = primarySessionID(for: sessionID)
        guard let session = byID[primaryID] else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        deliveringSessionIDs.insert(primaryID)
        defer { deliveringSessionIDs.remove(primaryID) }
        // The row shows what was typed; attached pictures and files hang on it (`SessionModel.attachments`).
        let shown = trimmed
        let attached = MessageAttachments.forFiles(files)
        func appendUserRow() {
            let id = "user-\(UUID().uuidString)"
            session.items.append(.user(id: id, text: shown, date: Date()))
            if !attached.isEmpty { session.attachments[id] = attached }
        }

        // Over its provider's daily spending cap (`UsageCaps.swift`): shown as not sent, nothing reaches the engine.
        // Every send goes through here, queued messages and auto-continue included.
        if let refusal = spendingCapRefusal(model: effectiveModel(for: session)) {
            appendUserRow()
            session.items.append(.error(id: "cap-\(UUID().uuidString)", message: "Not sent. " + refusal.message))
            session.touch()
            return
        }

        var targetBackingID = backingSessionID(for: primaryID)
        var promptText = trimmed
        var preparedSwitch: PreparedCrossEngineSwitch?

        if let staged = pendingNextModel[primaryID] {
            let check = engine as? any EngineModelChangeCheck
            let change = await check?.engineChange(forSession: targetBackingID, to: staged)
            if change == nil {
                if session.info.model != staged {
                    let previous = session.info.model
                    let beforeError = lastError
                    lastError = nil
                    await switchModel(staged, for: primaryID)
                    if lastError != nil {
                        let errorMessage = lastError ?? "Could not switch model."
                        session.info.model = previous
                        appendUserRow()
                        session.items.append(.error(id: "error-\(UUID().uuidString)", message: errorMessage))
                        session.setActivity(.failed)
                        session.touch()
                        return
                    }
                    lastError = beforeError
                    session.items.append(.notice(id: "notice-\(UUID().uuidString)", text: "Switched to \(modelName(staged))"))
                }
                pendingNextModel[primaryID] = nil
            } else {
                do {
                    let prepared = try await prepareCrossEngineBackingSession(
                        for: session,
                        currentBackingID: targetBackingID,
                        targetModel: staged,
                        userText: trimmed
                    )
                    preparedSwitch = prepared
                    targetBackingID = prepared.backingSessionID
                    promptText = prepared.promptText
                } catch {
                    appendUserRow()
                    session.items.append(.error(id: "error-\(UUID().uuidString)", message: "Could not send: \(error.localizedDescription)"))
                    session.setActivity(.failed)
                    session.touch()
                    noteSendFailure(error, text: trimmed, files: files, sessionID: primaryID)
                    _ = askToTrust(after: error, model: staged, retry: .changeModel(sessionID: primaryID, model: staged))
                    return
                }
            }
        }

        appendUserRow()
        session.setActivity(.working)
        session.info.updated = Date()
        session.touch()
        queueRuntime[primaryID]?.held = false
        noteUserMessageSent(primaryID, text: trimmed)
        do {
            try await engine.prompt(targetBackingID, text: promptText, files: files)
        } catch {
            if let preparedSwitch {
                await rollbackCrossEngineSwitch(preparedSwitch, for: session)
            }
            session.items.append(.error(id: "error-\(UUID().uuidString)", message: "Could not send: \(error.localizedDescription)"))
            session.setActivity(.failed)
            session.touch()
            noteSendFailure(error, text: trimmed, files: files, sessionID: primaryID)
        }
    }

    private struct PreparedCrossEngineSwitch {
        let backingSessionID: String
        let promptText: String
        let createdNewBackingSession: Bool
        let previousThreadRecord: SessionThreadRecord?
        let previousModel: ModelRef?
        let previousModelEditTime: Date
        let stagedModel: ModelRef
        let switchNoticeID: String
        let previousPlanSupport: PlanModeSupport?
    }

    /// Reverts a cross-engine switch whose first prompt failed so retrying preserves the full handoff context.
    private func rollbackCrossEngineSwitch(_ prepared: PreparedCrossEngineSwitch, for session: SessionModel) async {
        let primaryID = session.id
        threadLinks.restoreRecord(prepared.previousThreadRecord, for: primaryID)
        if prepared.createdNewBackingSession {
            deletedSessionIDs.insert(prepared.backingSessionID)
            byID.removeValue(forKey: prepared.backingSessionID)
            sessions.removeAll { $0.id == prepared.backingSessionID }
        }
        dropLocalEdit(primaryID, .model, at: prepared.previousModelEditTime)
        session.info.model = prepared.previousModel
        pendingNextModel[primaryID] = prepared.stagedModel
        if let previousPlanSupport = prepared.previousPlanSupport {
            planSupport[primaryID] = previousPlanSupport
        } else {
            planSupport.removeValue(forKey: primaryID)
        }
        session.items.removeAll { $0.id == prepared.switchNoticeID }
        syncRouterThreadLinks()
        if prepared.createdNewBackingSession {
            try? await engine.deleteSession(prepared.backingSessionID)
        }
    }

    /// Creates or reuses a backing session on the engine for `targetModel`, builds a compact handoff,
    /// inserts the inline switch divider, updates thread links, and returns the prepared switch state.
    private func prepareCrossEngineBackingSession(
        for session: SessionModel,
        currentBackingID: String,
        targetModel: ModelRef,
        userText: String
    ) async throws -> PreparedCrossEngineSwitch {
        let primaryID = session.id
        if let router = engine as? EngineRouter {
            try router.validateTrust(directory: session.directory, model: targetModel)
        }

        let previousRecord = threadLinks.record(for: primaryID)
        let previousModel = session.info.model
        let previousPlanSupport = planSupport[primaryID]
        let itemsBeforeSwitch = session.items
        let lastAnchorID = CrossEngineHandoff.lastAnchorItemID(in: itemsBeforeSwitch)
        let currentEngineID = await engineRegistrationID(forSession: currentBackingID, fallbackModel: session.info.model)

        var createdBackingID: String?
        do {
            threadLinks.ensurePrimaryLink(
                primaryID: primaryID,
                engineID: currentEngineID,
                model: session.info.model,
                permissionMode: session.permissionMode,
                handedOffCount: itemsBeforeSwitch.count,
                handedOffItemID: lastAnchorID
            )
            threadLinks.updateHandedOffCount(
                itemsBeforeSwitch.count,
                lastItemID: lastAnchorID,
                forBackingID: currentBackingID,
                primaryID: primaryID
            )

            let targetID: String
            let handoffPrefix: String
            let createdNewBackingSession: Bool

            if let reusable = await findReusableBackingLink(
                for: primaryID,
                excluding: currentBackingID,
                targetModel: targetModel,
                directory: session.directory
            ) {
                targetID = reusable.backingSessionID
                createdNewBackingSession = false
                if reusable.model != targetModel {
                    try await engine.switchModel(targetID, model: targetModel)
                }
                if reusable.permissionMode != session.permissionMode {
                    try await engine.setPermissionMode(targetID, mode: session.permissionMode)
                }
                let deltaItems = CrossEngineHandoff.deltaItems(
                    from: itemsBeforeSwitch,
                    lastHandedOffItemID: reusable.lastHandedOffItemID,
                    lastHandedOffItemCount: reusable.lastHandedOffItemCount
                )
                handoffPrefix = CrossEngineHandoff.build(items: deltaItems, maxChars: CrossEngineHandoff.defaultMaxChars, isDelta: true)

                var updated = reusable
                updated.model = targetModel
                updated.permissionMode = session.permissionMode
                updated.lastHandedOffItemCount = itemsBeforeSwitch.count
                updated.lastHandedOffItemID = lastAnchorID
                threadLinks.upsertLink(updated, forPrimary: primaryID, makeActive: true)
            } else {
                handoffPrefix = CrossEngineHandoff.build(items: itemsBeforeSwitch, maxChars: CrossEngineHandoff.defaultMaxChars, isDelta: false)
                let created = try await engine.createSession(
                    directory: session.directory,
                    model: targetModel,
                    agent: nil,
                    permissionMode: session.permissionMode,
                    parentID: nil
                )
                createdBackingID = created.id
                createdNewBackingSession = true
                // Keep the backing session hidden from top-level lists even if `.sessionCreated` raced ahead.
                sessions.removeAll { $0.id == created.id }
                byID[created.id] = session
                targetID = created.id

                let targetEngineID = await engineRegistrationID(forSession: targetID, fallbackModel: targetModel)
                let link = ThreadBackingLink(
                    engineID: targetEngineID,
                    backingSessionID: targetID,
                    model: targetModel,
                    permissionMode: session.permissionMode,
                    lastHandedOffItemCount: itemsBeforeSwitch.count,
                    lastHandedOffItemID: lastAnchorID
                )
                threadLinks.upsertLink(link, forPrimary: primaryID, makeActive: true)
            }

            syncRouterThreadLinks()
            planSupport.removeValue(forKey: primaryID)
            let switchNoticeID = "notice-\(UUID().uuidString)"
            session.items.append(.notice(id: switchNoticeID, text: "Switched to \(modelName(targetModel)) for this message"))
            session.info.model = targetModel
            let modelEditTime = noteLocalEdit(primaryID, .model)
            pendingNextModel[primaryID] = nil

            let body = userText.isEmpty ? "(See attached files)" : userText
            let promptText = handoffPrefix.isEmpty ? userText : handoffPrefix + CrossEngineHandoff.promptSeparator + body
            return PreparedCrossEngineSwitch(
                backingSessionID: targetID,
                promptText: promptText,
                createdNewBackingSession: createdNewBackingSession,
                previousThreadRecord: previousRecord,
                previousModel: previousModel,
                previousModelEditTime: modelEditTime,
                stagedModel: targetModel,
                switchNoticeID: switchNoticeID,
                previousPlanSupport: previousPlanSupport
            )
        } catch {
            threadLinks.restoreRecord(previousRecord, for: primaryID)
            if let createdBackingID {
                deletedSessionIDs.insert(createdBackingID)
                byID.removeValue(forKey: createdBackingID)
                sessions.removeAll { $0.id == createdBackingID }
            }
            syncRouterThreadLinks()
            if let createdBackingID {
                try? await engine.deleteSession(createdBackingID)
            }
            throw error
        }
    }

    private func engineRegistrationID(forSession sessionID: String, fallbackModel: ModelRef?) async -> String {
        if let router = engine as? EngineRouter {
            if let registration = await router.registration(forSession: sessionID) {
                return registration.id
            }
            if let fallbackModel {
                return router.registration(forProvider: fallbackModel.providerID).id
            }
        }
        return fallbackModel?.providerID ?? "default"
    }

    private func findReusableBackingLink(
        for primaryID: String,
        excluding currentBackingID: String,
        targetModel: ModelRef,
        directory: String
    ) async -> ThreadBackingLink? {
        let links = threadLinks.links(for: primaryID)
        for link in links where link.backingSessionID != currentBackingID {
            if let router = engine as? EngineRouter {
                if await router.canReuseSession(link.backingSessionID, in: directory, model: targetModel) {
                    return link
                }
            } else if let check = engine as? any EngineModelChangeCheck {
                if await check.engineChange(forSession: link.backingSessionID, to: targetModel) == nil {
                    return link
                }
            }
        }
        return nil
    }

    /// Interrupts the selected session.
    public func stop() async {
        guard let session = selected else { return }
        await stop(session.id)
    }

    /// Interrupts `sessionID` (or its active cross-engine backing session) and holds its queued messages.
    public func stop(_ sessionID: String) async {
        let primaryID = primarySessionID(for: sessionID)
        holdQueue(primaryID)
        let targetID = backingSessionID(for: primaryID)
        do { try await engine.interrupt(targetID) } catch { lastError = "Could not stop: \(error.localizedDescription)" }
    }

    public func reply(to request: PermissionRequest, decision: PermissionDecision) async {
        if request.isInteraction {
            // Plans and questions have their own answers; Reject keeps planning or declines.
            await replyToInteraction(request, decision: decision)
            return
        }
        let primaryID = primarySessionID(for: request.sessionID)
        guard let session = byID[primaryID] else { return }
        session.resolutions[request.id] = PermissionResolution(decision)
        session.pendingPermissions.removeAll { $0.id == request.id }
        if session.activity == .waitingForPermission, session.pendingPermissions.isEmpty {
            session.setActivity(.working)
        }
        session.touch()
        let targetSessionID = backingSessionID(forPermissionID: request.id, fallback: request.sessionID)
        do {
            try await engine.replyPermission(sessionID: targetSessionID, requestID: request.id, decision: decision, message: nil)
            permissionBackingSessions.removeValue(forKey: request.id)
        } catch {
            session.resolutions[request.id] = nil
            if !hiddenSessionIDs.contains(request.sessionID),
               !session.pendingPermissions.contains(where: { $0.id == request.id }) {
                session.pendingPermissions.append(request)
            }
            lastError = "Could not answer the prompt: \(error.localizedDescription)"
            session.touch()
        }
    }

    public func switchModel(_ model: ModelRef, for sessionID: String? = nil) async {
        guard let session = sessionID.flatMap({ byID[$0] }) ?? selected else { return }
        let primaryID = session.id
        let targetID = backingSessionID(for: primaryID)
        let previous = session.info.model
        session.info.model = model
        let edit = noteLocalEdit(primaryID, .model)
        do {
            try await engine.switchModel(targetID, model: model)
            threadLinks.updateModel(model, forBackingID: targetID, primaryID: primaryID)
        } catch {
            dropLocalEdit(primaryID, .model, at: edit)
            session.info.model = previous
            lastError = "Could not switch model: \(error.localizedDescription)"
        }
    }

    public func setPermissionMode(_ mode: PermissionMode, for sessionID: String? = nil) async {
        guard let session = sessionID.flatMap({ byID[$0] }) ?? selected else { return }
        let primaryID = session.id
        let targetID = backingSessionID(for: primaryID)
        let previous = session.permissionMode
        if mode == .plan, previous != .plan {
            // Only engines with a real plan mode get one (`EngineInteractionControl`).
            let support = await loadPlanModeSupport(for: targetID)
            guard support.isSupported else {
                lastError = support.reason ?? "This agent has no plan mode."
                return
            }
        }
        session.permissionMode = mode
        permissionRulesChecked.insert(primaryID)
        if mode == .plan, previous != .plan {
            modeBeforePlan[primaryID] = previous
            if targetID != primaryID { modeBeforePlan[targetID] = previous }
        }
        do {
            try await engine.setPermissionMode(targetID, mode: mode)
            threadLinks.updatePermissionMode(mode, forBackingID: targetID, primaryID: primaryID)
        } catch {
            session.permissionMode = previous
            lastError = "Could not change permissions: \(error.localizedDescription)"
        }
    }

    public func rename(_ sessionID: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = byID[sessionID], !trimmed.isEmpty else { return }
        let primaryID = session.id
        let previous = session.info.title
        session.info.title = trimmed
        let edit = noteLocalEdit(primaryID, .title)
        do { try await engine.renameSession(primaryID, title: trimmed) } catch {
            dropLocalEdit(primaryID, .title, at: edit)
            session.info.title = previous
            lastError = "Could not rename: \(error.localizedDescription)"
        }
    }

    public func archive(_ sessionID: String, archived: Bool = true) async {
        guard let session = byID[sessionID] else { return }
        let primaryID = session.id
        session.info.archived = archived
        let edit = noteLocalEdit(primaryID, .archived)
        if archived, selectedSessionID == primaryID { selectNeighbour(of: primaryID) }
        do {
            try await engine.setArchived(primaryID, archived: archived)
            for backingID in threadLinks.allBackingIDs(for: primaryID) where backingID != primaryID {
                try? await engine.setArchived(backingID, archived: archived)
            }
        } catch {
            dropLocalEdit(primaryID, .archived, at: edit)
            session.info.archived = !archived
            lastError = "Could not archive: \(error.localizedDescription)"
        }
    }

    public func delete(_ sessionID: String) async {
        let primaryID = primarySessionID(for: sessionID)
        let extraBackingIDs = threadLinks.allBackingIDs(for: primaryID).filter { $0 != primaryID }
        do {
            try await engine.deleteSession(primaryID)
            for backingID in extraBackingIDs {
                try? await engine.deleteSession(backingID)
            }
            removeSession(primaryID)
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

    private func foldUsage(_ usage: Usage, from sourceID: String, into primary: SessionModel) {
        let primaryID = primary.id
        if sourceID == primaryID && !threadLinks.hasLinks(for: primaryID) {
            backingUsage[primaryID] = [primaryID: usage]
            primary.usage = usage
            primary.info.usage = usage
            return
        }
        var bySource = backingUsage[primaryID] ?? [:]
        if sourceID != primaryID, bySource[primaryID] == nil, primary.usage != .zero {
            bySource[primaryID] = primary.usage
        }
        bySource[sourceID] = usage
        backingUsage[primaryID] = bySource
        let total = bySource.values.reduce(.zero, +)
        primary.usage = total
        primary.info.usage = total
    }

    @discardableResult
    func upsertSession(_ info: EngineSession) -> SessionModel {
        if let primaryID = threadLinks.primarySessionID(for: info.id) {
            if let primary = byID[primaryID] {
                byID[info.id] = primary
                primary.info.updated = max(primary.info.updated, info.updated)
                if info.usage != .zero {
                    foldUsage(info.usage, from: info.id, into: primary)
                }
                return primary
            }
            // Primary session has not arrived yet; keep the backing session out of `sessions`.
            return SessionModel(info: info, permissionMode: defaultPermissionMode)
        }
        var incoming = info
        if let parentID = incoming.parentID, let primaryParent = threadLinks.primarySessionID(for: parentID) {
            incoming.parentID = primaryParent
        }
        if threadLinks.activeBackingID(for: incoming.id) != nil,
           threadLinks.activeBackingID(for: incoming.id) != incoming.id,
           let activeModel = threadLinks.activeModel(for: incoming.id) {
            incoming.model = activeModel
        }
        if let existing = byID[incoming.id] {
            existing.info = merge(incoming, over: existing.info)
            if incoming.usage != .zero {
                foldUsage(incoming.usage, from: incoming.id, into: existing)
            }
            for backingID in threadLinks.allBackingIDs(for: incoming.id) where backingID != incoming.id {
                byID[backingID] = existing
            }
            return existing
        }
        let model = SessionModel(info: incoming, permissionMode: defaultPermissionMode)
        insert(model)
        if incoming.usage != .zero {
            foldUsage(incoming.usage, from: incoming.id, into: model)
        }
        for backingID in threadLinks.allBackingIDs(for: incoming.id) where backingID != incoming.id {
            byID[backingID] = model
        }
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
        if let primaryID = threadLinks.primarySessionID(for: sessionID) {
            let wasActive = threadLinks.activeBackingID(for: primaryID) == sessionID
            let primaryLinkModel = threadLinks.link(forBackingID: primaryID, primaryID: primaryID)?.model
            byID.removeValue(forKey: sessionID)
            threadLinks.unlinkBackingSession(sessionID)
            if wasActive, let primary = byID[primaryID] {
                if let fallbackModel = threadLinks.activeModel(for: primaryID) ?? primaryLinkModel {
                    primary.info.model = fallbackModel
                    localEdits[primaryID]?[.model] = nil
                }
                planSupport.removeValue(forKey: primaryID)
            }
            syncRouterThreadLinks()
            return
        }
        guard byID[sessionID] != nil else { return }
        if selectedSessionID == sessionID { selectNeighbour(of: sessionID) }
        for backingID in threadLinks.allBackingIDs(for: sessionID) where backingID != sessionID {
            byID[backingID] = nil
            if remember { deletedSessionIDs.insert(backingID) }
        }
        pendingNextModel[sessionID] = nil
        backingUsage[sessionID] = nil
        threadLinks.removeThread(primaryID: sessionID)
        (engine as? EngineRouter)?.setActiveBackingSession(nil, forPrimary: sessionID)
        syncRouterThreadLinks()
        byID[sessionID] = nil
        sessions.removeAll { $0.id == sessionID }
        sessionAgentIDs[sessionID] = nil
        if remember { sessionLinks.remove(sessionID) }
    }

    private func selectNeighbour(of sessionID: String) {
        let order = sidebarOrder.filter { $0.id != sessionID && !$0.info.archived }
        selectedSessionID = nil
        if let next = order.first { select(next.id) }
    }
}
