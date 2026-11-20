import SwiftUI
import AppKit
import EnsembleKit

/// Ensemble's tools for agents in the Mac app: the MCP server every engine attaches (`AgentToolsServer.shared`, through
/// the `ensemble-agent-tools` helper in Contents/MacOS) and the coordinator that answers it with proposal cards, browser
/// permission cards and the browser pane.
///
/// Wiring (see the report for exact lines): `AgentToolsCenter.shared.start(store:)` once the store exists,
/// `onShowBrowser` from the window, `close(sessions:)` when sessions are archived or deleted.
@Observable @MainActor
final class AgentToolsCenter {
    static let shared = AgentToolsCenter()

    let server: AgentToolsServer
    /// Answers tool calls; nil until `start(store:)` (or a snapshot seeds one).
    private(set) var coordinator: AgentToolsCoordinator?
    /// Inline second-opinion cards per session and message item id.
    let secondOpinions = SecondOpinionStore()
    /// Why the server is not running, if it is not.
    private(set) var problem: String?
    /// Shows a session's browser pane. Set by the main window; without it the card still shows in the conversation.
    @ObservationIgnored var onShowBrowser: ((String) -> Void)?
    @ObservationIgnored weak var rooms: RoomsController?
    @ObservationIgnored private weak var store: SessionStore?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    private struct SecondOpinionRun {
        let runID: UUID
        let sessionID: String
        let task: Task<Void, Never>
    }

    private static let maxConcurrentSecondOpinions = 3

    @ObservationIgnored private var activeHelperSessionIDs: Set<String> = []
    @ObservationIgnored private var secondOpinionTasks: [UUID: SecondOpinionRun] = [:]

    init(server: AgentToolsServer = .shared) {
        self.server = server
    }

    /// Starts the server and the coordinator for the app's sessions. Does nothing in snapshots or a second time.
    func start(store: SessionStore) {
        guard coordinator == nil else { return }
        self.store = store
        let coordinator = AgentToolsCoordinator(environment: Self.environment(store: store, center: self))
        self.coordinator = coordinator
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: AgentToolsBridge.executableName) else {
            problem = "The \(AgentToolsBridge.executableName) helper is missing from the app."
            return
        }
        do {
            try server.start(host: coordinator, executable: helper.path)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.stop() }
        }
    }

    /// Snapshots: a coordinator with sample cards and no server.
    func installForSnapshot(_ coordinator: AgentToolsCoordinator) {
        self.coordinator = coordinator
    }

    /// Sessions that were archived or deleted: their keys stop working and their cards go.
    func close(sessions: [String]) {
        var closed = Set(sessions)
        if let store {
            for id in sessions {
                closed.insert(store.primarySessionID(for: id))
            }
        }
        for (opinionID, run) in secondOpinionTasks where closed.contains(run.sessionID) {
            run.task.cancel()
            secondOpinionTasks[opinionID] = nil
        }
        for id in sessions {
            coordinator?.forget(id)
            server.revoke(.session(id))
            secondOpinions.remove(sessionID: id)
        }
    }

    /// Opens the session in the window (a started proposal's Open button or an exchange card's Open button).
    func open(_ sessionID: String) {
        if let store {
            let primaryID = store.primarySessionID(for: sessionID)
            if store.session(primaryID) != nil {
                store.select(primaryID)
                return
            }
        }
        if let roomID = UUID(uuidString: sessionID), let rooms {
            rooms.select(roomID)
        }
    }

    // MARK: Second opinion

    func requestSecondOpinion(in session: SessionModel, itemID: String, replyText: String, model ref: ModelRef) {
        guard let store else { return }
        let option = SecondOpinionModels.options(from: store.models, current: nil)
            .first { $0.ref == ref }
        let modelName = option?.name ?? store.modelName(ref)
        let makerName = option?.makerName ?? ref.providerID
        let entry = secondOpinions.begin(
            sessionID: session.id,
            itemID: itemID,
            replyText: replyText,
            model: ref,
            modelName: modelName,
            makerName: makerName
        )
        runSecondOpinion(entry, directory: session.directory, fallbackChanges: session.changedFiles)
    }

    func retrySecondOpinion(_ opinion: SecondOpinion, in session: SessionModel) {
        guard let refreshed = secondOpinions.prepareRetry(id: opinion.id, sessionID: opinion.sessionID, itemID: opinion.itemID) else {
            return
        }
        runSecondOpinion(refreshed, directory: session.directory, fallbackChanges: session.changedFiles)
    }

    func dismissSecondOpinion(_ opinion: SecondOpinion) {
        secondOpinionTasks.removeValue(forKey: opinion.id)?.task.cancel()
        secondOpinions.dismiss(id: opinion.id, sessionID: opinion.sessionID, itemID: opinion.itemID)
    }

    private func runSecondOpinion(_ opinion: SecondOpinion, directory: String, fallbackChanges: [FileChange]) {
        secondOpinionTasks.removeValue(forKey: opinion.id)?.task.cancel()
        guard secondOpinionTasks.count < Self.maxConcurrentSecondOpinions else {
            secondOpinions.markFailed(
                id: opinion.id,
                sessionID: opinion.sessionID,
                itemID: opinion.itemID,
                error: "At most \(Self.maxConcurrentSecondOpinions) second opinions can run at once. Wait for one to finish or dismiss it."
            )
            return
        }
        let runID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return }
            defer {
                if self.secondOpinionTasks[opinion.id]?.runID == runID {
                    self.secondOpinionTasks[opinion.id] = nil
                }
            }

            let isTrusted = WorkspaceTrust.shared.isTrusted(directory)
            if let refusal = ModelTrustPolicy.refusal(
                for: opinion.model,
                directory: directory,
                isTrusted: isTrusted,
                providersNeedingTrust: Self.providersNeedingTrust(store: store)
            ) {
                self.secondOpinions.markFailed(id: opinion.id, sessionID: opinion.sessionID, itemID: opinion.itemID, error: refusal)
                return
            }

            let diff = await GitDiffSummaryLoader.diffSummary(
                in: directory,
                isTrusted: isTrusted,
                fallbackChanges: fallbackChanges
            )
            guard !Task.isCancelled else { return }

            let prompt = SecondOpinionPromptBuilder.build(
                replyText: opinion.replyText,
                diffSummary: diff,
                directory: directory
            )
            let outcome = await OneShotPromptRunner.run(
                api: store.engine,
                directory: directory,
                model: opinion.model,
                prompt: prompt,
                onSessionCreated: { [weak self, weak store] helperID in
                    await MainActor.run {
                        store?.registerHiddenHelperSession(helperID)
                        self?.activeHelperSessionIDs.insert(helperID)
                    }
                },
                onSessionFinished: { [weak self, weak store] helperID in
                    await MainActor.run {
                        store?.unregisterHiddenHelperSession(helperID)
                        self?.activeHelperSessionIDs.remove(helperID)
                    }
                }
            )
            guard !Task.isCancelled else { return }
            switch outcome {
            case .answered(let raw):
                self.secondOpinions.markAnswered(id: opinion.id, sessionID: opinion.sessionID, itemID: opinion.itemID, rawText: raw)
            case .failed(let message):
                self.secondOpinions.markFailed(id: opinion.id, sessionID: opinion.sessionID, itemID: opinion.itemID, error: message)
            }
        }
        secondOpinionTasks[opinion.id] = SecondOpinionRun(runID: runID, sessionID: opinion.sessionID, task: task)
    }

    private static func providersNeedingTrust(store: SessionStore) -> Set<String> {
        (store.engine as? EngineRouter)?.providersNeedingTrustedFolders ?? []
    }

    // MARK: The app's side

    static func environment(store: SessionStore, center: AgentToolsCenter) -> AgentToolsEnvironment {
        AgentToolsEnvironment(
            session: { [weak store] id in
                guard let store else { return nil }
                let primaryID = store.primarySessionID(for: id)
                guard !store.hiddenSessionIDs.contains(id), !store.hiddenSessionIDs.contains(primaryID) else { return nil }
                guard let model = store.session(primaryID) else { return nil }
                return info(model, store: store)
            },
            browser: { [weak store] id in
                guard let store else { return nil }
                let primaryID = store.primarySessionID(for: id)
                guard let session = store.session(primaryID) else { return nil }
                return BrowserCenter.shared.page(for: session)
            },
            isTrusted: { WorkspaceTrust.shared.isTrusted($0) },
            knownFolders: { [weak store] in Array(Set(store?.sessions.map(\.directory) ?? [])) },
            resolveModel: { [weak store] asked, session in
                guard let store else { return (session.model, "Default model", false) }
                return resolveModel(asked, session: session, store: store)
            },
            showBrowser: { [weak store, weak center] id in
                let primaryID = store?.primarySessionID(for: id) ?? id
                center?.onShowBrowser?(primaryID)
            },
            log: { [weak store] id, text in
                guard let store else { return }
                let primaryID = store.primarySessionID(for: id)
                store.addNotice(text, to: primaryID)
            },
            startSession: { [weak store] proposal, session in
                guard let store else { throw AgentToolsCenterError.noStore }
                // The user stays where they are; the card's Open button goes to the new session. The folder (resolved,
                // checked again by the coordinator just now) and the mode (Ask, never the proposer's) come from the card.
                let previous = store.selectedSessionID
                let created = try await store.newSession(directory: proposal.folder, model: proposal.model ?? session.model,
                                                         permissionMode: proposal.permissionMode)
                if let previous { store.select(previous) }
                await store.send(proposal.brief, to: created.id)
                return created.id
            },
            send: { [weak store] id, text in
                guard let store else { return }
                let primaryID = store.primarySessionID(for: id)
                await store.send(text, to: primaryID)
            },
            // Ensemble has no per-folder default mode yet, so proposed sessions start in Ask (`ProposalMode`).
            folderMode: { _ in nil },
            availableModels: { [weak store] in store?.models ?? [] },
            listAgents: { [weak store, weak center] excludeID, ownRoomID in
                guard let store else { return [] }
                let primaryExcludeID = store.primarySessionID(for: excludeID)
                return directoryEntries(
                    excluding: primaryExcludeID,
                    ownRoomID: ownRoomID,
                    store: store,
                    rooms: center?.rooms,
                    helpers: center?.activeHelperSessionIDs ?? []
                )
            },
            ownRoomID: { [weak store, weak center] sessionID in
                let primaryID = store?.primarySessionID(for: sessionID) ?? sessionID
                return ownRoom(for: primaryID, rooms: center?.rooms)
                    ?? ownRoom(for: sessionID, rooms: center?.rooms)
            },
            latestItemID: { [weak store] sessionID in
                guard let store else { return nil }
                let primaryID = store.primarySessionID(for: sessionID)
                return store.session(primaryID)?.items.last?.id
            },
            deliverAgentMessage: { [weak store, weak center] targetID, formatted in
                guard let store else { return .refused("The app is not ready.") }
                return await deliverMessage(
                    to: targetID,
                    formattedMessage: formatted,
                    store: store,
                    rooms: center?.rooms
                )
            },
            askAgent: { [weak store, weak center] request in
                guard let store, let center else { return .failed("The app is not ready.") }
                return await performAskAgent(request, store: store, center: center)
            },
            gitDiff: { [weak store] directory in
                let isTrusted = WorkspaceTrust.shared.isTrusted(directory)
                let fallback = store?.sessions.first { $0.directory == directory }?.changedFiles ?? []
                return await GitDiffSummaryLoader.diffSummary(in: directory, isTrusted: isTrusted, fallbackChanges: fallback)
            },
            providersNeedingTrust: { [weak store] in
                guard let store else { return [] }
                return providersNeedingTrust(store: store)
            },
            targetPermissionMode: { [weak store, weak center] targetID in
                if let store {
                    let primaryID = store.primarySessionID(for: targetID)
                    if let session = store.session(primaryID) { return session.permissionMode }
                }
                if let roomID = UUID(uuidString: targetID), let state = center?.rooms?.state(roomID) {
                    return state.spec.permissionMode
                }
                return nil
            },
            targetDirectory: { [weak store, weak center] targetID in
                if let store {
                    let primaryID = store.primarySessionID(for: targetID)
                    if let session = store.session(primaryID) { return session.directory }
                }
                if let roomID = UUID(uuidString: targetID), let state = center?.rooms?.state(roomID) {
                    return state.spec.directory
                }
                return nil
            },
            roomMemberSessionIDs: { [weak center] targetID in
                guard let roomID = UUID(uuidString: targetID), let rooms = center?.rooms else { return [] }
                if let engine = rooms.engines[roomID] {
                    return Array(engine.state.sessions.values)
                }
                if let state = rooms.state(roomID) {
                    return Array(state.sessions.values)
                }
                return []
            }
        )
    }

    /// The coordinator's view of a session. A subagent's root is its top-level parent; the turn is the number of user
    /// messages, so a new message from the user starts a new turn.
    static func info(_ model: SessionModel, store: SessionStore) -> AgentToolsEnvironment.Session {
        var root = model
        var hops = 0
        while let parentID = root.info.parentID,
              let parent = store.session(store.primarySessionID(for: parentID)),
              hops < 16 {
            root = parent
            hops += 1
        }
        return AgentToolsEnvironment.Session(
            id: model.id,
            rootID: root.id,
            directory: model.directory,
            model: model.info.model,
            permissionMode: model.permissionMode,
            archived: model.info.archived,
            turn: String(userTurnCount(model)),
            title: sessionTitle(model),
            modelName: store.modelName(model.info.model)
        )
    }

    /// The agent's suggestion matched against the app's models (id, `provider/id` or name, ignoring case), else the
    /// session's own model.
    static func resolveModel(_ asked: String?, session: AgentToolsEnvironment.Session, store: SessionStore)
        -> (model: ModelRef?, name: String, matched: Bool) {
        let outcome = ProposalModelMatch.resolve(
            asked: asked,
            models: store.models,
            current: session.model,
            currentName: store.modelName(session.model),
            preferOther: false
        )
        return (outcome.model, outcome.name, outcome.matched)
    }

    // MARK: Cross-session directory & delivery helpers

    private static func userTurnCount(_ session: SessionModel) -> Int {
        session.items.reduce(0) { count, item in
            if case .user = item { return count + 1 }
            return count
        }
    }

    private static func sessionTitle(_ session: SessionModel) -> String {
        let trimmed = session.info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New session" : trimmed
    }

    private static func ownRoom(for sessionID: String, rooms: RoomsController?) -> UUID? {
        guard let rooms else { return nil }
        for engine in rooms.engines.values where engine.state.sessions.values.contains(sessionID) {
            return engine.state.id
        }
        for saved in rooms.saved where saved.sessions.values.contains(sessionID) {
            return saved.id
        }
        return nil
    }

    private static func directoryEntries(
        excluding excludeID: String,
        ownRoomID: UUID?,
        store: SessionStore,
        rooms: RoomsController?,
        helpers: Set<String>
    ) -> [AgentDirectoryEntry] {
        var roomSessionIDs: Set<String> = []
        if let rooms {
            for saved in rooms.saved {
                let state = rooms.state(saved.id) ?? saved
                roomSessionIDs.formUnion(state.sessions.values)
            }
            for engine in rooms.engines.values {
                roomSessionIDs.formUnion(engine.state.sessions.values)
            }
        }

        var entries: [AgentDirectoryEntry] = []
        for session in store.sessions {
            guard !session.isSubagent,
                  !session.info.archived,
                  session.id != excludeID,
                  !helpers.contains(session.id),
                  !store.hiddenSessionIDs.contains(session.id),
                  !store.hiddenLinkedSessionIDs.contains(session.id),
                  !roomSessionIDs.contains(session.id) else { continue }
            entries.append(
                AgentDirectoryEntry(
                    id: session.id,
                    kind: .session,
                    title: sessionTitle(session),
                    model: store.modelName(session.info.model),
                    folder: session.directory,
                    activity: session.activity.rawValue
                )
            )
        }

        if let rooms {
            for saved in rooms.saved {
                guard saved.id != ownRoomID else { continue }
                let state = rooms.state(saved.id) ?? saved
                let modelSummary = state.spec.agents.map(\.name).joined(separator: ", ")
                entries.append(
                    AgentDirectoryEntry(
                        id: state.id.uuidString,
                        kind: .room,
                        title: state.spec.title,
                        model: modelSummary,
                        folder: state.spec.directory,
                        activity: rooms.isRunning(state.id) ? "working" : "idle"
                    )
                )
            }
        }
        return entries
    }

    private static func deliverMessage(
        to targetID: String,
        formattedMessage: String,
        store: SessionStore,
        rooms: RoomsController?
    ) async -> AgentDeliveryResult {
        let payload = AgentToolText.isUntrustedPeerFrame(formattedMessage)
            ? formattedMessage
            : AgentToolText.untrusted(formattedMessage, source: "Message from another Ensemble agent")

        let primaryTargetID = store.primarySessionID(for: targetID)
        if let target = store.session(primaryTargetID) {
            guard !target.info.archived else { return .refused("The target session is archived.") }
            let queued = target.isWorking
            await store.send(payload, to: target.id)
            return .delivered(
                targetSessionID: target.id,
                targetTitle: sessionTitle(target),
                targetModelName: store.modelName(target.info.model),
                targetTurn: String(userTurnCount(target)),
                queued: queued
            )
        }

        if let roomID = UUID(uuidString: targetID), let rooms, let engine = rooms.engine(for: roomID) {
            let queued = rooms.isRunning(roomID)
            await engine.send(payload)
            let names = engine.state.spec.agents.map(\.name).joined(separator: ", ")
            return .delivered(
                targetSessionID: roomID.uuidString,
                targetTitle: engine.state.spec.title,
                targetModelName: names,
                targetTurn: "room",
                queued: queued
            )
        }

        return .refused("No active session or room has id \(targetID).")
    }

    private static func performAskAgent(
        _ request: AskAgentRequest,
        store: SessionStore,
        center: AgentToolsCenter
    ) async -> AskAgentResult {
        let isTrusted = WorkspaceTrust.shared.isTrusted(request.directory)
        if let refusal = ModelTrustPolicy.refusal(
            for: request.model,
            directory: request.directory,
            isTrusted: isTrusted,
            providersNeedingTrust: providersNeedingTrust(store: store)
        ) {
            return .refused(refusal)
        }

        let folder = AgentDirectoryEntry.folderBasename(request.directory)
        var promptParts = [
            "You are answering a read-only question from another Ensemble session in \"\(folder)\".",
            "Do not use tools, edit files, or run commands. Keep your reply concise and direct.",
            "",
            "Question:",
            request.question
        ]
        if let diff = request.diffSummary, !diff.isEmpty {
            promptParts += ["", "Working-tree diff excerpt:", diff]
        }

        let outcome = await OneShotPromptRunner.run(
            api: store.engine,
            directory: request.directory,
            model: request.model,
            prompt: promptParts.joined(separator: "\n"),
            onSessionCreated: { [weak store, weak center] helperID in
                await MainActor.run {
                    store?.registerHiddenHelperSession(helperID)
                    center?.activeHelperSessionIDs.insert(helperID)
                    center?.coordinator?.registerHelperLease(sessionID: helperID, lease: request.hopLease)
                }
            },
            onSessionFinished: { [weak store, weak center] helperID in
                await MainActor.run {
                    store?.unregisterHiddenHelperSession(helperID)
                    center?.activeHelperSessionIDs.remove(helperID)
                }
            }
        )
        switch outcome {
        case .answered(let text): return .answered(text)
        case .failed(let message): return .failed(message)
        }
    }
}

enum AgentToolsCenterError: Error, LocalizedError {
    case noStore

    var errorDescription: String? { "The app is not ready." }
}

/// Opens the browser pane when an agent in the session on screen uses the browser (its permission card shows there
/// and above the composer). Attached to the main window.
struct AgentToolsWindowSync: ViewModifier {
    let store: SessionStore
    let window: WindowState
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        content.onAppear {
            guard !isSnapshot else { return }
            AgentToolsCenter.shared.onShowBrowser = { [weak store, weak window] sessionID in
                guard let store, let window, store.selectedSessionID == sessionID, window.route != .room, !window.browserOpen else { return }
                window.openSidePane(.browser)
            }
        }
    }
}
