#if os(macOS)
import Foundation
import Observation

/// A side task an agent proposed with `propose_session`, shown as a card in its session.
public struct SessionProposal: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case pending
        case starting
        case started(sessionID: String)
        case sentHere
        case dismissed
        case failed(String)

        public var isOpen: Bool {
            switch self {
            case .pending, .failed: true
            default: false
            }
        }
    }

    public let id: String
    /// The session the card belongs to.
    public let sessionID: String
    public var title: String
    public var brief: String
    /// The folder with every symlink resolved (`ProposalFolder`); checked again before Start.
    public var folder: String
    /// The mode a new session starts in (`ProposalMode`): Ask, or the folder's own default; never the proposer's.
    public var permissionMode: PermissionMode
    /// The model a new session gets (nil keeps the default) and its name.
    public var model: ModelRef?
    public var modelName: String
    /// What the agent asked for when it matched no model.
    public var unmatchedModel: String?
    public var state: State
    public let created: Date

    public init(id: String = UUID().uuidString, sessionID: String, title: String, brief: String, folder: String,
                permissionMode: PermissionMode = .ask, model: ModelRef?, modelName: String, unmatchedModel: String? = nil,
                state: State = .pending, created: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.brief = brief
        self.folder = folder
        self.permissionMode = permissionMode
        self.model = model
        self.modelName = modelName
        self.unmatchedModel = unmatchedModel
        self.state = state
        self.created = created
    }

    /// The message Do it here sends to the session.
    public var hereMessage: String { "Go ahead with the task you proposed: \(title)\n\n\(brief)" }
}

/// A browser call waiting for the user: Allow once, Always for this site (Claude sessions in trusted folders only), or Deny.
public struct BrowserPermissionRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let tool: AgentToolName
    public let summary: String
    /// `http://localhost:5173`: what "Always" covers.
    public let origin: String
    /// The page's full address.
    public let address: String
    /// The text a `browser_type` call would enter.
    public let typedText: String?
    /// Only for Claude sessions (the one engine whose bridge is tied to its own process) in trusted folders.
    public let allowsAlways: Bool
    /// Why "Always" is not offered, for the card; nil when it is.
    public let alwaysNote: String?

    public static let untrustedNote = "This folder is not trusted, so each browser action asks."
    public static let claudeOnlyNote = "Always is only offered for Claude sessions, so each browser action asks."

    public init(id: String = UUID().uuidString, sessionID: String, tool: AgentToolName, summary: String, origin: String,
                address: String, typedText: String? = nil, allowsAlways: Bool, alwaysNote: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.summary = summary
        self.origin = origin
        self.address = address
        self.typedText = typedText
        self.allowsAlways = allowsAlways
        self.alwaysNote = allowsAlways ? nil : (alwaysNote ?? Self.untrustedNote)
    }

    /// The site as people read it: `localhost:5173`.
    public var site: String {
        guard let url = URL(string: origin), let host = url.host(percentEncoded: false) else { return origin }
        let port = url.port.map { ":\($0)" } ?? ""
        return (host.contains(":") ? "[\(host)]" : host) + port
    }
}

public enum BrowserPermissionAnswer: String, Sendable {
    case once, always, deny
}

/// The agent's use of one session's browser.
public struct AgentBrowserState: Equatable, Sendable {
    public enum Pause: Equatable, Sendable {
        /// Stop: browser calls are refused for the rest of this turn.
        case stopped(turn: String)
        /// Take over: refused until the user hands the browser back.
        case tookOver
        /// A sign-in page: the agent may read it but not act on it until the user hands the browser back.
        case signIn
    }

    public var pause: Pause?
    /// The newest action, for the bar.
    public var lastAction: String?
    public var lastActivity: Date?
    /// A call is running now.
    public var running = false

    public init(pause: Pause? = nil, lastAction: String? = nil, lastActivity: Date? = nil, running: Bool = false) {
        self.pause = pause
        self.lastAction = lastAction
        self.lastActivity = lastActivity
        self.running = running
    }

    /// The user holds the browser (Take over or a sign-in page).
    public var userHasControl: Bool {
        switch pause {
        case .tookOver?, .signIn?: true
        default: false
        }
    }
}

/// Outcome of delivering a cross-session message from `message_agent`.
public enum AgentDeliveryResult: Equatable, Sendable {
    case delivered(targetSessionID: String?, targetTitle: String, targetModelName: String, targetTurn: String, queued: Bool)
    case refused(String)
}

/// Request sent to `AgentToolsEnvironment.askAgent` for a read-only cross-model question.
public struct AskAgentRequest: Equatable, Sendable {
    public var directory: String
    public var model: ModelRef
    public var modelName: String
    public var question: String
    public var diffSummary: String?
    public var hopLease: AgentExchangeLimiter.HopLease

    public init(directory: String, model: ModelRef, modelName: String, question: String, diffSummary: String?,
                hopLease: AgentExchangeLimiter.HopLease) {
        self.directory = directory
        self.model = model
        self.modelName = modelName
        self.question = question
        self.diffSummary = diffSummary
        self.hopLease = hopLease
    }
}

/// Outcome of a read-only `ask_agent` run.
public enum AskAgentResult: Equatable, Sendable {
    case answered(String)
    case refused(String)
    case failed(String)
}

/// What the coordinator needs from the app, as closures so it can be tested without windows.
@MainActor
public struct AgentToolsEnvironment {
    public struct Session: Equatable, Sendable {
        public var id: String
        /// The top-level session (a subagent's calls show up in its parent's cards and browser).
        public var rootID: String
        public var directory: String
        public var model: ModelRef?
        public var permissionMode: PermissionMode
        public var archived: Bool
        /// Changes when the user sends a message: the number of user messages so far.
        public var turn: String
        public var title: String
        public var modelName: String

        public init(id: String, rootID: String, directory: String, model: ModelRef?, permissionMode: PermissionMode,
                    archived: Bool, turn: String, title: String = "", modelName: String = "") {
            self.id = id
            self.rootID = rootID
            self.directory = directory
            self.model = model
            self.permissionMode = permissionMode
            self.archived = archived
            self.turn = turn
            self.title = title
            self.modelName = modelName
        }
    }

    public var session: (String) -> Session?
    /// The session's browser (made on first use), or nil when there is none.
    public var browser: (String) -> (any AgentBrowserSurface)?
    public var isTrusted: (String) -> Bool
    /// Folders of the app's sessions, for `propose_session`'s folder rule.
    public var knownFolders: () -> [String]
    /// The model for a proposal: the agent's suggestion matched against the app's models, else the session's.
    public var resolveModel: (String?, Session) -> (model: ModelRef?, name: String, matched: Bool)
    /// Shows the session's browser pane (so the user sees the page and its permission card).
    public var showBrowser: (String) -> Void
    /// Adds a line to the session's transcript.
    public var log: (String, String) -> Void
    /// Creates a session for a proposal and sends its brief; returns the new session's id.
    public var startSession: (SessionProposal, Session) async throws -> String
    /// Sends a message to a session.
    public var send: (String, String) async -> Void
    /// A folder's own default permission mode, if it has one (`ProposalMode`).
    public var folderMode: (String) -> PermissionMode?
    /// All known models, used for fuzzy matching and prioritizing alternate makers in `ask_agent`.
    public var availableModels: () -> [ModelInfo]
    /// Open top-level sessions and rooms visible to `list_agents`.
    public var listAgents: (_ excludeSessionID: String, _ ownRoomID: UUID?) -> [AgentDirectoryEntry]
    /// The room a session belongs to, if any.
    public var ownRoomID: (String) -> UUID?
    /// Latest transcript item id in a session, for anchoring inline exchange cards.
    public var latestItemID: (String) -> String?
    /// Delivers a cross-session message to a session or room id.
    public var deliverAgentMessage: (_ targetID: String, _ formattedMessage: String) async -> AgentDeliveryResult
    /// Executes a read-only `ask_agent` question against another model.
    public var askAgent: (AskAgentRequest) async -> AskAgentResult
    /// Loads a compact working-tree git diff summary when `include_diff` is true.
    public var gitDiff: (String) async -> String?
    /// Providers whose browser sign-in requires a trusted folder.
    public var providersNeedingTrust: () -> Set<String>
    /// Permission mode of a target session or room id, for privilege-escalation checks.
    public var targetPermissionMode: (String) -> PermissionMode?
    /// Full directory path of a target session or room id, for trust and cross-folder checks.
    public var targetDirectory: (String) -> String?
    /// Active member session ids belonging to a room id, for hop-limit propagation.
    public var roomMemberSessionIDs: (String) -> [String]

    public init(session: @escaping (String) -> Session?, browser: @escaping (String) -> (any AgentBrowserSurface)?,
                isTrusted: @escaping (String) -> Bool, knownFolders: @escaping () -> [String],
                resolveModel: @escaping (String?, Session) -> (model: ModelRef?, name: String, matched: Bool),
                showBrowser: @escaping (String) -> Void, log: @escaping (String, String) -> Void,
                startSession: @escaping (SessionProposal, Session) async throws -> String, send: @escaping (String, String) async -> Void,
                folderMode: @escaping (String) -> PermissionMode? = { _ in nil },
                availableModels: @escaping () -> [ModelInfo] = { [] },
                listAgents: @escaping (_ excludeSessionID: String, _ ownRoomID: UUID?) -> [AgentDirectoryEntry] = { _, _ in [] },
                ownRoomID: @escaping (String) -> UUID? = { _ in nil },
                latestItemID: @escaping (String) -> String? = { _ in nil },
                deliverAgentMessage: @escaping (_ targetID: String, _ formattedMessage: String) async -> AgentDeliveryResult = { _, _ in
                    .refused("Cross-session messaging is not configured.")
                },
                askAgent: @escaping (AskAgentRequest) async -> AskAgentResult = { _ in
                    .failed("Cross-model ask is not configured.")
                },
                gitDiff: @escaping (String) async -> String? = { _ in nil },
                providersNeedingTrust: @escaping () -> Set<String> = { [] },
                targetPermissionMode: @escaping (String) -> PermissionMode? = { _ in nil },
                targetDirectory: @escaping (String) -> String? = { _ in nil },
                roomMemberSessionIDs: @escaping (String) -> [String] = { _ in [] }) {
        self.session = session
        self.browser = browser
        self.isTrusted = isTrusted
        self.knownFolders = knownFolders
        self.resolveModel = resolveModel
        self.showBrowser = showBrowser
        self.log = log
        self.startSession = startSession
        self.send = send
        self.folderMode = folderMode
        self.availableModels = availableModels
        self.listAgents = listAgents
        self.ownRoomID = ownRoomID
        self.latestItemID = latestItemID
        self.deliverAgentMessage = deliverAgentMessage
        self.askAgent = askAgent
        self.gitDiff = gitDiff
        self.providersNeedingTrust = providersNeedingTrust
        self.targetPermissionMode = targetPermissionMode
        self.targetDirectory = targetDirectory
        self.roomMemberSessionIDs = roomMemberSessionIDs
    }
}

/// The app side of the agent tools: proposal cards, browser permission cards with per-site grants, the agent's
/// browser state (Stop, Take over, sign-in pauses), and the transcript log. `AgentToolsServer` calls it for every
/// tool call it accepted.
@Observable @MainActor
public final class AgentToolsCoordinator: AgentToolsHost {
    public private(set) var proposals: [SessionProposal] = []
    public private(set) var permissionRequests: [BrowserPermissionRequest] = []
    public private(set) var browserStates: [String: AgentBrowserState] = [:]
    public private(set) var exchanges: [AgentExchange] = []
    public private(set) var grants = BrowserGrants()

    @ObservationIgnored public var environment: AgentToolsEnvironment
    @ObservationIgnored private var limiter = ProposalLimiter()
    @ObservationIgnored private var exchangeLimiter = AgentExchangeLimiter()
    @ObservationIgnored private var waiters: [String: CheckedContinuation<BrowserPermissionAnswer, Never>] = [:]
    private struct QueueWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private var queued: [String: [QueueWaiter]] = [:]
    /// How long a permission card waits before the call is denied.
    @ObservationIgnored public var permissionTimeout: Duration = .seconds(300)

    public init(environment: AgentToolsEnvironment) {
        self.environment = environment
    }

    // MARK: AgentToolsHost

    public func handle(_ call: AgentToolCall, caller: AgentToolsCaller) async -> AgentToolResult {
        guard let own = environment.session(caller.sessionID) else {
            return .refused("Ensemble has no session for this call.")
        }
        let session = own.rootID == own.id ? own : (environment.session(own.rootID) ?? own)
        guard !session.archived else { return .refused("This session is archived.") }
        switch call {
        case .propose(let input):
            return propose(input, session: session)
        case .listAgents:
            return listAgents(session: session, own: own)
        case .messageAgent(let input):
            return await messageAgent(input, session: session, own: own)
        case .askAgent(let input):
            return await askAgent(input, session: session)
        case .browser(let action):
            return await browser(action, session: session, siteGrants: caller.canUseSiteGrants)
        }
    }

    public func session(_ sessionID: String, isIn folder: String, server: String) async -> Bool {
        guard let session = environment.session(sessionID) else { return false }
        let a = WorkspaceTrust.resolvedPath(session.directory) ?? session.directory
        let b = WorkspaceTrust.resolvedPath(folder) ?? folder
        return a == b
    }

    public func rootSession(of sessionID: String) async -> String? {
        environment.session(sessionID)?.rootID
    }

    public func record(_ entry: AgentToolsLogEntry) async {
        environment.log(entry.sessionID, entry.transcriptText)
    }

    // MARK: Proposals

    public func proposals(for sessionID: String) -> [SessionProposal] {
        proposals.filter { $0.sessionID == sessionID && $0.state != .dismissed }
    }

    func propose(_ input: SessionProposalInput, session: AgentToolsEnvironment.Session) -> AgentToolResult {
        let folder: String
        switch ProposalFolder.resolve(input.folder, sessionFolder: session.directory, knownFolders: environment.knownFolders()) {
        case .success(let resolved): folder = resolved
        case .failure(let problem): return .refused(problem.message)
        }
        guard limiter.admit(session: session.id, turn: session.turn) else {
            return .refused("You already proposed \(limiter.limit) sessions this turn. Mention further ideas in your reply instead.")
        }
        let model = environment.resolveModel(input.model, session)
        proposals.append(SessionProposal(sessionID: session.id, title: input.title, brief: input.brief, folder: folder,
                                         permissionMode: ProposalMode.mode(folderDefault: environment.folderMode(folder)),
                                         model: model.model, modelName: model.name,
                                         unmatchedModel: model.matched ? nil : input.model))
        return .text("The user sees your proposal \"\(input.title)\" as a card with Start, Do it here and Dismiss. Nothing starts until they choose. Carry on with your current task; if they choose Do it here, the brief comes back to you as a message.")
    }

    /// Start: a new session in the proposal's folder, in the proposal's mode, with its brief as the first message. The
    /// folder is checked again first: if a link in its path now leads elsewhere, nothing starts.
    public func start(_ proposalID: String) async {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }), proposals[index].state.isOpen else { return }
        var proposal = proposals[index]
        guard let session = environment.session(proposal.sessionID) else {
            update(proposalID) { $0.state = .failed("The session that proposed this is gone.") }
            return
        }
        if let problem = ProposalFolder.recheck(proposal.folder, sessionFolder: session.directory, knownFolders: environment.knownFolders()) {
            update(proposalID) { $0.state = .failed(problem.message) }
            return
        }
        // The mode is the proposal's own, whatever the proposing session uses now; never Bypass.
        proposal.permissionMode = ProposalMode.mode(folderDefault: proposal.permissionMode)
        update(proposalID) { $0.state = .starting }
        do {
            let newID = try await environment.startSession(proposal, session)
            update(proposalID) { $0.state = .started(sessionID: newID) }
        } catch {
            update(proposalID) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// Do it here: the brief goes to the proposing session as a message.
    public func doItHere(_ proposalID: String) async {
        guard let proposal = proposals.first(where: { $0.id == proposalID }), proposal.state.isOpen else { return }
        update(proposalID) { $0.state = .sentHere }
        await environment.send(proposal.sessionID, proposal.hereMessage)
    }

    public func dismiss(_ proposalID: String) {
        update(proposalID) { $0.state = .dismissed }
    }

    private func update(_ proposalID: String, _ change: (inout SessionProposal) -> Void) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        change(&proposals[index])
    }

    // MARK: Cross-session messaging & ask_agent

    public func exchanges(for sessionID: String) -> [AgentExchange] {
        exchanges.filter { $0.isVisible(in: sessionID) }
    }

    public func dismissExchange(_ exchangeID: String, for sessionID: String) {
        guard let index = exchanges.firstIndex(where: { $0.id == exchangeID }) else { return }
        exchanges[index].dismissedBy.insert(sessionID)
    }

    public func noteUserTurn(in sessionID: String) {
        exchangeLimiter.reset(session: sessionID)
        if let root = environment.session(sessionID)?.rootID, root != sessionID {
            exchangeLimiter.reset(session: root)
        }
        if let ownRoom = environment.ownRoomID(sessionID) {
            exchangeLimiter.reset(session: ownRoom.uuidString)
            for memberID in environment.roomMemberSessionIDs(ownRoom.uuidString) {
                exchangeLimiter.reset(session: memberID)
            }
        }
        for memberID in environment.roomMemberSessionIDs(sessionID) {
            exchangeLimiter.reset(session: memberID)
        }
    }

    public func registerHelperLease(sessionID: String, lease: AgentExchangeLimiter.HopLease, turn: String = "0") {
        exchangeLimiter.attachHelper(sessionID, lease: lease, turn: turn)
    }

    func listAgents(session: AgentToolsEnvironment.Session, own: AgentToolsEnvironment.Session) -> AgentToolResult {
        guard environment.isTrusted(session.directory) else {
            return .refused("list_agents is disabled in untrusted folders. Trust this folder first.")
        }
        let ownRoom = environment.ownRoomID(session.id)
        let excluded: Set<String> = [session.id, own.id]
        let entries = environment.listAgents(session.id, ownRoom).filter { entry in
            if excluded.contains(entry.id) { return false }
            if let ownRoom, entry.kind == .room,
               entry.id.caseInsensitiveCompare(ownRoom.uuidString) == .orderedSame {
                return false
            }
            if let targetDir = environment.targetDirectory(entry.id) ?? environment.session(entry.id)?.directory {
                if !targetDir.isEmpty && !environment.isTrusted(targetDir) { return false }
            } else if !entry.folder.isEmpty && !environment.isTrusted(entry.folder) {
                return false
            }
            return true
        }
        return .text(AgentDirectoryEntry.encodeList(entries))
    }

    func messageAgent(
        _ input: AgentMessageInput,
        session: AgentToolsEnvironment.Session,
        own: AgentToolsEnvironment.Session
    ) async -> AgentToolResult {
        guard environment.isTrusted(session.directory) else {
            return .refused("message_agent is disabled in untrusted folders. Trust this folder first.")
        }
        let requestedTarget = input.targetSessionID
        let ownRoom = environment.ownRoomID(session.id)
        if requestedTarget == session.id || requestedTarget == own.id {
            return .refused("You cannot message your own session.")
        }
        if let ownRoom, requestedTarget.caseInsensitiveCompare(ownRoom.uuidString) == .orderedSame {
            return .refused("You cannot message your own room with message_agent.")
        }

        let directSession = environment.session(requestedTarget)
        if let directSession {
            if directSession.id == session.id || directSession.rootID == session.id {
                return .refused("You cannot message your own session.")
            }
            if directSession.archived {
                return .refused("That session is archived.")
            }
            if let targetRoom = environment.ownRoomID(directSession.rootID) ?? environment.ownRoomID(directSession.id) {
                if let ownRoom, targetRoom == ownRoom {
                    return .refused("You cannot message another member of your own room with message_agent. Address them on the room board instead.")
                }
                return .refused("Cannot message a room member session directly. Message the room id \(targetRoom.uuidString) instead.")
            }
        }
        let openEntries = environment.listAgents(session.id, ownRoom)
        let matchedRoom = openEntries.first {
            $0.kind == .room && $0.id.caseInsensitiveCompare(requestedTarget) == .orderedSame
        }
        guard directSession != nil || matchedRoom != nil else {
            return .refused("No active session or room has id \(requestedTarget).")
        }

        let canonicalTargetID = directSession?.rootID ?? matchedRoom?.id ?? requestedTarget
        let targetSessionForLimiter = directSession.map { environment.session($0.rootID) ?? $0 }

        let targetFolder = environment.targetDirectory(canonicalTargetID)
            ?? targetSessionForLimiter?.directory
            ?? directSession?.directory
            ?? ""
        guard !targetFolder.isEmpty else {
            return .refused("Blocked: could not verify the target folder. Use propose_session or ask the user.")
        }
        guard environment.isTrusted(targetFolder) else {
            return .refused("Blocked: target session or room is in an untrusted folder.")
        }
        let callerResolved = WorkspaceTrust.resolvedPath(session.directory)
        let targetResolved = WorkspaceTrust.resolvedPath(targetFolder)
        guard let callerResolved, let targetResolved, callerResolved == targetResolved else {
            let callerName = AgentDirectoryEntry.folderBasename(session.directory)
            return .refused("Blocked: an agent in \(callerName) cannot message a session in another folder directly. Use propose_session or ask the user.")
        }

        let callerMode = own.permissionMode.autonomyRank <= session.permissionMode.autonomyRank
            ? own.permissionMode
            : session.permissionMode
        let targetMode = environment.targetPermissionMode(canonicalTargetID)
            ?? targetSessionForLimiter?.permissionMode
            ?? directSession?.permissionMode
        guard let targetMode else {
            return .refused("Blocked: could not verify the target's permission mode. Use propose_session or ask the user.")
        }
        if targetMode.autonomyRank > callerMode.autonomyRank {
            return .refused("Blocked: an agent in \(callerMode.shortLabel) mode cannot message a target in looser \(targetMode.shortLabel) mode directly. Use propose_session or ask the user.")
        }

        let sourceAliases = ownRoom.map { [$0.uuidString] } ?? []
        let targetAliases = matchedRoom != nil ? environment.roomMemberSessionIDs(canonicalTargetID) : []
        let lease: AgentExchangeLimiter.HopLease
        switch exchangeLimiter.beginHop(
            from: session.id,
            sourceTurn: session.turn,
            to: canonicalTargetID,
            targetTurn: targetSessionForLimiter?.turn,
            sourceAliases: sourceAliases,
            targetAliases: targetAliases
        ) {
        case .success(let granted):
            lease = granted
        case .failure(let refusal):
            return .refused(refusal.message)
        }

        let fromTitle = session.title.isEmpty ? "Session" : session.title
        let fromModel = session.modelName.isEmpty ? (session.model?.description ?? "Agent") : session.modelName
        let initialTargetTitle = targetSessionForLimiter?.title.isEmpty == false
            ? (targetSessionForLimiter?.title ?? "Agent")
            : (matchedRoom?.title ?? "Agent")
        let initialTargetModel = targetSessionForLimiter?.modelName.isEmpty == false
            ? (targetSessionForLimiter?.modelName ?? "Agent")
            : (matchedRoom?.model ?? "Agent")

        var anchors: [String: String] = [:]
        if let sourceAnchor = environment.latestItemID(session.id) {
            anchors[session.id] = sourceAnchor
        }
        let exchange = AgentExchange(
            kind: .message,
            fromSessionID: session.id,
            fromTitle: fromTitle,
            fromModelName: fromModel,
            toSessionID: canonicalTargetID,
            toTitle: initialTargetTitle,
            toModelName: initialTargetModel,
            message: input.message,
            status: .sending,
            anchors: anchors
        )
        exchanges.append(exchange)

        let senderLabel = AgentToolText.clean("\(fromModel) (\(fromTitle))", limit: 160)
        let formatted = AgentToolText.untrusted(input.message, source: "Message from \(senderLabel)")
        let outcome = await environment.deliverAgentMessage(canonicalTargetID, formatted)
        switch outcome {
        case .delivered(let targetSessionID, let deliveredTitle, let deliveredModel, _, let queued):
            if matchedRoom != nil {
                let postMembers = environment.roomMemberSessionIDs(canonicalTargetID)
                if !postMembers.isEmpty {
                    exchangeLimiter.propagate(lease: lease, to: postMembers)
                }
            }
            let resolvedTarget = targetSessionID ?? canonicalTargetID
            updateExchange(exchange.id) { item in
                item.toSessionID = resolvedTarget
                item.toTitle = deliveredTitle
                item.toModelName = deliveredModel
                item.status = queued ? .queued : .delivered
                if let targetSessionID, let targetAnchor = environment.latestItemID(targetSessionID) {
                    item.anchors[targetSessionID] = targetAnchor
                }
            }
            return .text(
                "Delivered message to \(deliveredTitle) (\(deliveredModel))"
                    + (queued ? " (queued while busy)." : ".")
            )
        case .refused(let reason):
            updateExchange(exchange.id) { $0.status = .failed(reason) }
            return .refused(reason)
        }
    }

    func askAgent(_ input: AskAgentInput, session: AgentToolsEnvironment.Session) async -> AgentToolResult {
        let models = environment.availableModels()
        let resolvedModel: ModelRef?
        let resolvedName: String
        let matched: Bool
        if !models.isEmpty {
            let outcome = ProposalModelMatch.resolve(
                asked: input.model,
                models: models,
                current: session.model,
                preferOther: true
            )
            resolvedModel = outcome.model
            resolvedName = outcome.name
            matched = outcome.matched
        } else {
            let fallback = environment.resolveModel(input.model, session)
            resolvedModel = fallback.model
            resolvedName = fallback.name
            matched = fallback.matched
        }
        guard matched, let targetModel = resolvedModel else {
            return .refused("No available model matches \"\(input.model)\".")
        }

        let isTrusted = environment.isTrusted(session.directory)
        if let trustRefusal = ModelTrustPolicy.refusal(
            for: targetModel,
            directory: session.directory,
            isTrusted: isTrusted,
            providersNeedingTrust: environment.providersNeedingTrust()
        ) {
            return .refused(trustRefusal)
        }

        let sourceAliases = environment.ownRoomID(session.id).map { [$0.uuidString] } ?? []
        let lease: AgentExchangeLimiter.HopLease
        switch exchangeLimiter.beginHop(from: session.id, sourceTurn: session.turn, sourceAliases: sourceAliases) {
        case .success(let granted):
            lease = granted
        case .failure(let refusal):
            return .refused(refusal.message)
        }

        var diffSummary: String?
        if input.includeDiff, isTrusted {
            diffSummary = await environment.gitDiff(session.directory)
        }

        let fromTitle = session.title.isEmpty ? "Session" : session.title
        let fromModel = session.modelName.isEmpty ? (session.model?.description ?? "Agent") : session.modelName
        var anchors: [String: String] = [:]
        if let sourceAnchor = environment.latestItemID(session.id) {
            anchors[session.id] = sourceAnchor
        }
        let exchange = AgentExchange(
            kind: .ask,
            fromSessionID: session.id,
            fromTitle: fromTitle,
            fromModelName: fromModel,
            toSessionID: nil,
            toTitle: resolvedName,
            toModelName: resolvedName,
            message: input.question,
            status: .sending,
            anchors: anchors
        )
        exchanges.append(exchange)

        let request = AskAgentRequest(
            directory: session.directory,
            model: targetModel,
            modelName: resolvedName,
            question: input.question,
            diffSummary: diffSummary,
            hopLease: lease
        )
        let answer = await environment.askAgent(request)
        switch answer {
        case .answered(let text):
            let cleaned = AgentToolText.clean(text, limit: 8000, multiline: true)
            updateExchange(exchange.id) {
                $0.status = .answered
                $0.replyPreview = cleaned
            }
            return .text(cleaned)
        case .refused(let reason), .failed(let reason):
            updateExchange(exchange.id) { $0.status = .failed(reason) }
            return .refused(reason)
        }
    }

    private func updateExchange(_ id: String, _ change: (inout AgentExchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    // MARK: Browser

    public func browserState(_ sessionID: String) -> AgentBrowserState {
        browserStates[sessionID] ?? AgentBrowserState()
    }

    public func permissionRequest(for sessionID: String) -> BrowserPermissionRequest? {
        permissionRequests.first { $0.sessionID == sessionID }
    }

    /// One browser call. `siteGrants` is false for bridges that cannot be tied to one engine process (agy and OpenCode,
    /// `AgentToolsBinding.isExact`): then "Always for this site" is neither offered nor used, and every call asks.
    func browser(_ action: BrowserAgentAction, session: AgentToolsEnvironment.Session, siteGrants: Bool) async -> AgentToolResult {
        // One browser call at a time per session, in order.
        guard await acquire(session.id) else {
            return .refused("The call was cancelled.")
        }
        defer { release(session.id) }
        guard !Task.isCancelled else { return .refused("The call was cancelled.") }
        let activeSession = environment.session(session.id) ?? session
        if let refusal = pauseRefusal(action, session: activeSession) { return .refused(refusal) }
        guard let surface = environment.browser(session.id) else {
            return .refused("This session has no browser pane.")
        }
        let target: URL?
        if case .navigate(let url) = action { target = url } else { target = surface.agentURL }
        if let refusal = BrowserAgentOrigin.refusal(for: target) { return .refused(refusal) }
        guard let target, let origin = BrowserAgentOrigin.origin(of: target) else { return .refused("No page is open.") }
        // Name the element for the card; stale refs, file pickers and password or payment fields are refused here.
        let element: String?
        switch await BrowserAgentDriver.target(of: action, on: surface, expectedOrigin: origin) {
        case .success(let described): element = described
        case .failure(let refusal): return .refused(refusal.message)
        }
        guard !Task.isCancelled else { return .refused("The call was cancelled.") }
        let summary = action.summary(element: element)

        // "Always" covers exactly the origin it was granted for, only through bridges tied to their engine process,
        // and only while the session's folder remains trusted.
        let currentSession = environment.session(session.id) ?? activeSession
        let folderTrusted = environment.isTrusted(currentSession.directory)
        if !(siteGrants && folderTrusted && grants.allows(origin, session: session.id)) {
            let request = BrowserPermissionRequest(sessionID: session.id, tool: action.tool, summary: summary, origin: origin,
                                                   address: target.absoluteString, typedText: action.typedText,
                                                   allowsAlways: siteGrants && folderTrusted,
                                                   alwaysNote: siteGrants ? BrowserPermissionRequest.untrustedNote
                                                       : BrowserPermissionRequest.claudeOnlyNote)
            environment.showBrowser(session.id)
            touch(session.id, action: summary)
            let answer = await ask(request)
            switch answer {
            case .deny:
                touch(session.id, action: nil)
                return .refused(Task.isCancelled ? "The call was cancelled." : "The user denied this browser action (\(summary) on \(request.site)).")
            case .always:
                if request.allowsAlways { grants.grant(origin, session: session.id) }
            case .once:
                break
            }
            // The user may have pressed Stop or Take over while the card was open.
            if let refusal = pauseRefusal(action, session: environment.session(session.id) ?? currentSession) { return .refused(refusal) }
        }

        guard !Task.isCancelled else {
            touch(session.id, action: nil)
            return .refused("The call was cancelled.")
        }

        // The page may have moved while the card waited or the element was looked up (a redirect, page script, a link):
        // the action runs only on the origin the user approved. The page scripts check it again inside the page.
        if case .navigate = action {
        } else if let moved = BrowserAgentDriver.originChange(expected: origin, on: surface) {
            touch(session.id, action: nil)
            return .refused(moved)
        }

        environment.showBrowser(session.id)
        touch(session.id, action: summary, running: true)
        let outcome = await BrowserAgentDriver.perform(action, on: surface, expectedOrigin: origin)
        touch(session.id, action: summary, running: false)
        if outcome.signIn { browserStates[session.id, default: AgentBrowserState()].pause = .signIn }
        return outcome.result
    }

    /// Why a call must not run now, or nil.
    private func pauseRefusal(_ action: BrowserAgentAction, session: AgentToolsEnvironment.Session) -> String? {
        switch browserStates[session.id]?.pause {
        case .stopped(let turn)?:
            if turn == session.turn { return "The user stopped your browser use for this turn." }
            browserStates[session.id]?.pause = nil
            return nil
        case .tookOver?:
            return "The user took over the browser. Wait until they hand it back, or ask them in your reply."
        case .signIn?:
            if action.tool.readsOnly { return nil }
            return BrowserAgentDriver.signInNotice + " Wait until the user hands the browser back."
        case nil:
            return nil
        }
    }

    private func touch(_ sessionID: String, action: String?, running: Bool = false) {
        var state = browserStates[sessionID] ?? AgentBrowserState()
        if let action { state.lastAction = action }
        state.lastActivity = Date()
        state.running = running
        browserStates[sessionID] = state
    }

    /// Shows a permission card and waits for the answer (deny on timeout or when the call is cancelled).
    func ask(_ request: BrowserPermissionRequest) async -> BrowserPermissionAnswer {
        permissionRequests.append(request)
        let timeout = permissionTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.answer(request.id, .deny)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Already answered (cancelled or timed out before this point): deny.
                if Task.isCancelled || !permissionRequests.contains(where: { $0.id == request.id }) {
                    permissionRequests.removeAll { $0.id == request.id }
                    continuation.resume(returning: .deny)
                } else {
                    waiters[request.id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(request.id, .deny) }
        }
    }

    /// The user's answer to a permission card.
    public func answer(_ requestID: String, _ answer: BrowserPermissionAnswer) {
        permissionRequests.removeAll { $0.id == requestID }
        waiters.removeValue(forKey: requestID)?.resume(returning: answer)
    }

    /// Stop: denies the open card and refuses browser calls for the rest of this turn.
    public func stop(_ sessionID: String) {
        let turn = environment.session(sessionID)?.turn ?? ""
        browserStates[sessionID, default: AgentBrowserState()].pause = .stopped(turn: turn)
        denyRequests(sessionID)
    }

    /// Take over: denies the open card and refuses browser calls until Hand back.
    public func takeOver(_ sessionID: String) {
        browserStates[sessionID, default: AgentBrowserState()].pause = .tookOver
        denyRequests(sessionID)
    }

    /// Hand back: the agent may use the browser again.
    public func handBack(_ sessionID: String) {
        browserStates[sessionID]?.pause = nil
    }

    /// A session was archived or deleted: its cards, grants and state go.
    public func forget(_ sessionID: String) {
        denyRequests(sessionID)
        grants.revoke(session: sessionID)
        browserStates[sessionID] = nil
        proposals.removeAll { $0.sessionID == sessionID }
        exchangeLimiter.reset(session: sessionID)
        for index in exchanges.indices {
            exchanges[index].dismissedBy.insert(sessionID)
        }
        exchanges.removeAll { item in
            let fromHidden = item.dismissedBy.contains(item.fromSessionID)
            let toHidden = item.toSessionID.map { item.dismissedBy.contains($0) } ?? true
            return fromHidden && toHidden
        }
    }

    private func denyRequests(_ sessionID: String) {
        for request in permissionRequests where request.sessionID == sessionID { answer(request.id, .deny) }
    }

    // MARK: Per-session order

    /// Acquires the per-session browser lock. Returns false if cancelled before acquiring.
    private func acquire(_ sessionID: String) async -> Bool {
        if Task.isCancelled { return false }
        if !busy.contains(sessionID) {
            busy.insert(sessionID)
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if !busy.contains(sessionID) {
                    busy.insert(sessionID)
                    continuation.resume(returning: true)
                    return
                }
                queued[sessionID, default: []].append(QueueWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueuedWaiter(sessionID: sessionID, waiterID: waiterID)
            }
        }
    }

    private func cancelQueuedWaiter(sessionID: String, waiterID: UUID) {
        guard var waiting = queued[sessionID],
              let index = waiting.firstIndex(where: { $0.id == waiterID }) else { return }
        let removed = waiting.remove(at: index)
        queued[sessionID] = waiting.isEmpty ? nil : waiting
        removed.continuation.resume(returning: false)
    }

    private func release(_ sessionID: String) {
        if var waiting = queued[sessionID], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queued[sessionID] = waiting.isEmpty ? nil : waiting
            next.continuation.resume(returning: true)
        } else {
            busy.remove(sessionID)
        }
    }

    // MARK: Snapshots

    /// Puts cards and state in place for snapshots and previews.
    public func seedForSnapshot(proposals: [SessionProposal] = [], requests: [BrowserPermissionRequest] = [],
                                states: [String: AgentBrowserState] = [:], exchanges: [AgentExchange] = []) {
        self.proposals = proposals
        permissionRequests = requests
        browserStates = states
        self.exchanges = exchanges
    }
}

// MARK: - One-shot read-only helper & safe git diff

/// Result of running a disposable one-shot helper turn (`ask_agent` and `Second opinion`).
public enum OneShotPromptResult: Equatable, Sendable {
    case answered(String)
    case failed(String)
}

/// Runs a single read-only prompt in a disposable helper session and deletes it on finish or cancel.
public enum OneShotPromptRunner {
    private actor Collector {
        private var order: [String] = []
        private var deltasByItem: [String: String] = [:]
        private var finishedByItem: [String: String] = [:]
        private var done = false
        private var errorMessage: String?
        private var continuation: CheckedContinuation<Void, Never>?

        func appendDelta(itemID: String, delta: String) {
            if !order.contains(itemID) { order.append(itemID) }
            deltasByItem[itemID, default: ""] += delta
        }

        func finishText(itemID: String, text: String) {
            if !order.contains(itemID) { order.append(itemID) }
            finishedByItem[itemID] = text
        }

        func complete(outcome: String, error: String?) {
            guard !done else { return }
            if let error, !error.isEmpty {
                errorMessage = error
            } else if outcome == "failed" || outcome == "interrupted" {
                errorMessage = outcome == "interrupted" ? "Cancelled." : "The helper run failed."
            }
            done = true
            continuation?.resume()
            continuation = nil
        }

        func waitUntilDone() async {
            if done { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func snapshot() -> OneShotPromptResult {
            if let errorMessage {
                return .failed(errorMessage)
            }
            for itemID in order.reversed() {
                let raw = finishedByItem[itemID] ?? deltasByItem[itemID] ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return .answered(trimmed)
                }
            }
            return .failed("The model returned no text.")
        }
    }

    public static func run(
        api: any OpenCodeAPI,
        directory: String,
        model: ModelRef,
        prompt: String,
        timeout: Duration = .seconds(180),
        onSessionCreated: (@Sendable (String) async -> Void)? = nil,
        onSessionFinished: (@Sendable (String) async -> Void)? = nil
    ) async -> OneShotPromptResult {
        let session: EngineSession
        do {
            session = try await api.createSession(
                directory: directory,
                model: model,
                agent: nil,
                permissionMode: .plan,
                parentID: nil
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        let sessionID = session.id
        if let onSessionCreated {
            await onSessionCreated(sessionID)
        }
        try? await api.setArchived(sessionID, archived: true)

        let collector = Collector()
        let stream = api.events()
        let eventTask = Task {
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let sid, let itemID, let delta) where sid == sessionID:
                    await collector.appendDelta(itemID: itemID, delta: delta)
                case .textEnded(let sid, let itemID, let text) where sid == sessionID:
                    await collector.finishText(itemID: itemID, text: text)
                case .permissionAsked(let request) where request.sessionID == sessionID:
                    Task {
                        try? await api.replyPermission(
                            sessionID: sessionID,
                            requestID: request.id,
                            decision: .reject,
                            message: "Read-only helper: do not run commands or edit files."
                        )
                    }
                case .executionEnded(let sid, let outcome, let error) where sid == sessionID:
                    await collector.complete(outcome: outcome, error: error)
                default:
                    break
                }
            }
            await collector.complete(outcome: "failed", error: "The helper stream closed early.")
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            try? await api.interrupt(sessionID)
            await collector.complete(outcome: "failed", error: "Timed out waiting for a reply.")
        }

        do {
            try await api.prompt(sessionID, text: prompt, files: [])
        } catch {
            await collector.complete(outcome: "failed", error: error.localizedDescription)
        }

        await withTaskCancellationHandler {
            await collector.waitUntilDone()
        } onCancel: {
            Task { await collector.complete(outcome: "interrupted", error: "Cancelled.") }
        }

        let result = await collector.snapshot()
        eventTask.cancel()
        timeoutTask.cancel()
        await Task.detached {
            try? await api.interrupt(sessionID)
            try? await api.deleteSession(sessionID)
            if let onSessionFinished {
                await onSessionFinished(sessionID)
            }
        }.value
        return result
    }
}

/// Collects a bounded working-tree diff summary using `GitRunner` in trusted repositories.
public enum GitDiffSummaryLoader {
    public static func diffSummary(
        in directory: String,
        isTrusted: Bool,
        fallbackChanges: [FileChange] = [],
        maxCharacters: Int = 4000
    ) async -> String? {
        if isTrusted, GitSafety.repositoryFolder(containing: directory) != nil {
            let runner = GitRunner()
            let headCheck = await runner.run(["rev-parse", "--verify", "HEAD"], in: directory)
            let diffArgs = headCheck.succeeded
                ? ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD"]
                : ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
            let diffOut = await runner.run(diffArgs, in: directory)
            if diffOut.succeeded {
                let text = diffOut.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return capped(text, limit: maxCharacters)
                }
            }
            let statusOut = await runner.run(["status", "--short"], in: directory)
            if statusOut.succeeded {
                let status = statusOut.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !status.isEmpty {
                    return capped("Working tree status:\n" + status, limit: maxCharacters)
                }
            }
        }

        let patches = fallbackChanges.compactMap { change -> String? in
            let name = Format.relativePath(change.path, base: directory)
            if let diff = change.diff?.trimmingCharacters(in: .whitespacesAndNewlines), !diff.isEmpty {
                return "\(name):\n\(diff)"
            }
            return "\(change.kind.rawValue): \(name)"
        }
        guard !patches.isEmpty else { return nil }
        return capped(patches.joined(separator: "\n\n"), limit: maxCharacters)
    }

    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 24 else { return String(text.prefix(limit)) }
        return String(text.prefix(limit - 18)) + "\n...(truncated)"
    }
}

public extension SessionStore {
    /// Marks a temporary helper session as hidden so it never flashes in the sidebar, Hub, or iPhone remote.
    func registerHiddenHelperSession(_ sessionID: String) {
        hiddenSessionIDs.insert(sessionID)
    }

    /// Removes a finished temporary helper session from the hidden set.
    func unregisterHiddenHelperSession(_ sessionID: String) {
        hiddenSessionIDs.remove(sessionID)
    }
}
#endif
