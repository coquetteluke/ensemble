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

        public init(id: String, rootID: String, directory: String, model: ModelRef?, permissionMode: PermissionMode,
                    archived: Bool, turn: String) {
            self.id = id
            self.rootID = rootID
            self.directory = directory
            self.model = model
            self.permissionMode = permissionMode
            self.archived = archived
            self.turn = turn
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

    public init(session: @escaping (String) -> Session?, browser: @escaping (String) -> (any AgentBrowserSurface)?,
                isTrusted: @escaping (String) -> Bool, knownFolders: @escaping () -> [String],
                resolveModel: @escaping (String?, Session) -> (model: ModelRef?, name: String, matched: Bool),
                showBrowser: @escaping (String) -> Void, log: @escaping (String, String) -> Void,
                startSession: @escaping (SessionProposal, Session) async throws -> String, send: @escaping (String, String) async -> Void,
                folderMode: @escaping (String) -> PermissionMode? = { _ in nil }) {
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
    public private(set) var grants = BrowserGrants()

    @ObservationIgnored public var environment: AgentToolsEnvironment
    @ObservationIgnored private var limiter = ProposalLimiter()
    @ObservationIgnored private var waiters: [String: CheckedContinuation<BrowserPermissionAnswer, Never>] = [:]
    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private var queued: [String: [CheckedContinuation<Void, Never>]] = [:]
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
        await acquire(session.id)
        defer { release(session.id) }
        if let refusal = pauseRefusal(action, session: session) { return .refused(refusal) }
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
        let summary = action.summary(element: element)

        // "Always" covers exactly the origin it was granted for, and only through bridges tied to their engine process.
        if !(siteGrants && grants.allows(origin, session: session.id)) {
            let request = BrowserPermissionRequest(sessionID: session.id, tool: action.tool, summary: summary, origin: origin,
                                                   address: target.absoluteString, typedText: action.typedText,
                                                   allowsAlways: siteGrants && environment.isTrusted(session.directory),
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
            if let refusal = pauseRefusal(action, session: environment.session(session.id) ?? session) { return .refused(refusal) }
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
    }

    private func denyRequests(_ sessionID: String) {
        for request in permissionRequests where request.sessionID == sessionID { answer(request.id, .deny) }
    }

    // MARK: Per-session order

    private func acquire(_ sessionID: String) async {
        if !busy.contains(sessionID) {
            busy.insert(sessionID)
            return
        }
        await withCheckedContinuation { queued[sessionID, default: []].append($0) }
    }

    private func release(_ sessionID: String) {
        if var waiting = queued[sessionID], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queued[sessionID] = waiting.isEmpty ? nil : waiting
            next.resume()
        } else {
            busy.remove(sessionID)
        }
    }

    // MARK: Snapshots

    /// Puts cards and state in place for snapshots and previews.
    public func seedForSnapshot(proposals: [SessionProposal] = [], requests: [BrowserPermissionRequest] = [],
                                states: [String: AgentBrowserState] = [:]) {
        self.proposals = proposals
        permissionRequests = requests
        browserStates = states
    }
}
#endif
