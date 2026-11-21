import Foundation
import Synchronization

/// Fans engine events out to every `events()` subscriber.
final class ACPEventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<EngineEvent>.Continuation]>([:])

    func stream() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(20_000))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ event: EngineEvent) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(event) }
    }
}

/// Whether an ACP tool is installed and signed in, as far as Ensemble can tell without touching credentials.
public struct ACPAuthState: Equatable, Sendable {
    public var installed: Bool
    public var version: String?
    /// nil when unknown (the tool has no sign-in check, or the check failed for another reason).
    public var signedIn: Bool?
    /// Why the check could not tell.
    public var problem: String?

    public init(installed: Bool, version: String? = nil, signedIn: Bool? = nil, problem: String? = nil) {
        self.installed = installed
        self.version = version
        self.signedIn = signedIn
        self.problem = problem
    }
}

/// Runs a coding agent that speaks the Agent Client Protocol (ACP) over stdio: JSON-RPC 2.0, one message per line.
/// One `ACPEngine` serves one tool from `ACPAgentRegistry` (Google's `agy acp` first), and its models are the
/// tool's provider id (`antigravity/gemini-3.8-flash#low`).
///
/// - Processes: one agent process per tool, serving all of its sessions (`session/new`, `session/load`,
///   `session/prompt`, `session/cancel`), plus a second one only for Bypass sessions when the tool has a
///   skip-permissions switch (`agy acp --dangerously-skip-permissions`). Prompts never go in argv.
/// - Sessions: Ensemble's own ids (UUIDs) mapped to the tool's session ids, saved in
///   `~/Library/Application Support/Ensemble/acp-sessions.json`. After a restart a session is reopened with
///   `session/load`, which also replays its history for the transcript (or `session/resume` when only that exists).
/// - Updates map to engine events: message chunks to text deltas, thoughts to reasoning, tool calls to tool cards
///   (with unified diffs from ACP diff content), plans to a task list card, `usage_update` to the context panel,
///   the `session/prompt` usage to token totals, `session_info_update` titles to the session title.
/// - Permissions: `session/request_permission` becomes a permission card. Once and reject pick the matching option.
///   "Always" answers the agent once (its own "always" option would save a rule Ensemble cannot describe) and Ensemble
///   remembers, for the session, exactly the rule the card shows in `alwaysPatterns`: the exact command, the canonical
///   URL, the one file inside the project, or the exact arguments (`ACPToolState.alwaysRule`). Calls with no concrete
///   subject, several paths or a path outside the project are allowed once only, and the card says so. Cancelling a
///   turn answers open prompts with `cancelled`, as the protocol requires.
/// - Permission mode: set on the agent every time a session opens (`session/set_config_option` for the `mode`
///   option, or `session/set_mode`), and the agent must report it back, so the tool's own defaults (for Antigravity,
///   the user's permission preset such as Turbo) never carry over. Antigravity: Ask is `default`, Accept edits is
///   `accept-edits`, Auto is `default` too, with Ensemble answering every prompt itself (`ACPAutoPrompts`; agy's own
///   `auto` sends no prompts at all), Bypass is a process started with `--dangerously-skip-permissions`.
/// - Effort: the agent's `thought_level` config option, offered through `EngineModelOptionsControl`.
/// - Commands: `available_commands_update`, offered through `EngineCommandsControl`; a command runs as a prompt
///   starting with `/name`.
/// - Not adopted: `EngineHistoryControl` (no tested agent can rewind; OpenCode's ACP fork is unstable and agy has
///   none), schedules, API keys (each tool signs in its own way), connectors.
/// - Trust: tools that load a project's own hooks and settings only start in folders in `WorkspaceTrust`
///   (`ACPEngineError.folderNotTrusted` otherwise).
/// - Limits: at most `maxConcurrentTurns` turns run at once (Antigravity: 3); more wait in line.
public final class ACPEngine: OpenCodeAPI, EngineModelOptionsControl, EngineCommandsControl, Sendable {
    public struct Configuration: Sendable {
        public var agent: ACPAgentDefinition
        /// Path to the tool's executable; nil searches the definition's folders and PATH.
        public var executablePath: String?
        public var storeURL: URL
        /// The agent processes' working folder, also used for the throwaway session that reads models and commands.
        /// An empty folder Ensemble owns, so no project settings load there.
        public var workDirectory: URL
        /// Overrides the definition's limit of turns running at once.
        public var maxConcurrentTurns: Int?
        /// Extra launch arguments. The tool's skip-permissions switch is dropped from them.
        public var extraArguments: [String]
        /// The environment the child's allowlist is taken from.
        public var baseEnvironment: [String: String]
        public var trust: WorkspaceTrust
        public var requestTimeout: Duration
        /// How long an interrupted turn may take to answer `cancelled` before Ensemble ends it on its side.
        public var interruptGrace: Duration
        public var clientVersion: String
        /// Ensemble's own MCP server (`AgentToolsServer`), sent in `mcpServers` when a session opens.
        public var agentTools: (any AgentToolsAttaching)? = AgentToolsServer.shared

        public init(agent: ACPAgentDefinition, executablePath: String? = nil, storeURL: URL? = nil, workDirectory: URL? = nil,
                    maxConcurrentTurns: Int? = nil, extraArguments: [String] = [],
                    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, trust: WorkspaceTrust = .shared,
                    requestTimeout: Duration = .seconds(60), interruptGrace: Duration = .seconds(15), clientVersion: String = "1.0") {
            self.agent = agent
            self.executablePath = executablePath
            self.storeURL = storeURL ?? ACPSessionStore.defaultURL
            self.workDirectory = workDirectory ?? ACPEngine.defaultWorkDirectory(agentID: agent.id)
            self.maxConcurrentTurns = maxConcurrentTurns
            self.extraArguments = extraArguments
            self.baseEnvironment = baseEnvironment
            self.trust = trust
            self.requestTimeout = requestTimeout
            self.interruptGrace = interruptGrace
            self.clientVersion = clientVersion
        }
    }

    public static func defaultWorkDirectory(agentID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/acp-work/\(agentID)")
    }

    public let configuration: Configuration
    let broadcaster = ACPEventBroadcaster()
    #if os(macOS)
    let core: ACPEngineCore
    #endif

    public init(configuration: Configuration) {
        self.configuration = configuration
        #if os(macOS)
        core = ACPEngineCore(configuration: configuration, broadcaster: broadcaster)
        #endif
    }

    /// An engine for a registry tool with the default settings.
    public convenience init(agent: ACPAgentDefinition) {
        self.init(configuration: Configuration(agent: agent))
    }

    public var agent: ACPAgentDefinition { configuration.agent }

    public func events() -> AsyncStream<EngineEvent> { broadcaster.stream() }

    #if os(macOS)

    public func serverInfo() async throws -> (version: String, url: URL) {
        guard let url = await core.executableURL() else {
            throw ACPEngineError.notInstalled(agent: agent.displayName, hint: agent.installHint)
        }
        return (await core.version() ?? "unknown", url)
    }

    /// Installed and signed in, from a throwaway ACP session (cached for ten minutes unless `refresh`).
    public func authState(refresh: Bool = false) async -> ACPAuthState { await core.authState(refresh: refresh) }

    // Sessions

    public func listSessions() async throws -> [EngineSession] { await core.listSessions() }

    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                              parentID: String?) async throws -> EngineSession {
        try await core.createSession(directory: directory, model: model, permissionMode: permissionMode, parentID: parentID)
    }

    public func deleteSession(_ sessionID: String) async throws { try await core.deleteSession(sessionID) }
    public func renameSession(_ sessionID: String, title: String) async throws { try await core.rename(sessionID, title: title) }
    public func setArchived(_ sessionID: String, archived: Bool) async throws { try await core.setArchived(sessionID, archived: archived) }
    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { try await core.setPermissionMode(sessionID, mode: mode) }
    public func switchModel(_ sessionID: String, model: ModelRef) async throws { try await core.switchModel(sessionID, model: model) }
    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] { try await core.transcript(sessionID) }
    public func attachedTranscript(_ sessionID: String) async throws -> AttachedTranscript { try await core.attachedTranscript(sessionID) }
    public func children(_ sessionID: String) async throws -> [EngineSession] { [] }

    // Talking

    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        try await core.send(sessionID, text: text, files: files, synthetic: false)
    }

    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        if wake {
            try await core.send(sessionID, text: text, files: [], synthetic: true)
        } else {
            try await core.queueSynthetic(sessionID, text: text)
        }
    }

    public func interrupt(_ sessionID: String) async throws { await core.interrupt(sessionID) }

    /// ACP has no field for a reason, so `message` is not sent to the agent.
    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await core.replyPermission(requestID: requestID, decision: decision)
    }

    public func pendingPermissions() async throws -> [PermissionRequest] { await core.pendingRequests() }

    // Panels

    public func context(_ sessionID: String) async throws -> ContextBreakdown { try await core.context(sessionID) }
    public func changedFiles(_ sessionID: String) async throws -> [FileChange] { try await core.changedFiles(sessionID) }
    public func connectors() async throws -> [ConnectorInfo] { [] }

    // Models and keys

    public func models() async throws -> [ModelInfo] { await core.models() }
    public func providers() async throws -> [ProviderInfo] { await core.providers() }

    public func setAPIKey(providerID: String, key: String) async throws {
        throw ACPEngineError.notSupported("\(agent.displayName) signs in with its own app. \(agent.signInHint)")
    }

    public func removeAPIKey(providerID: String) async throws {
        throw ACPEngineError.notSupported("\(agent.displayName) signs in with its own app.")
    }

    // Schedules

    public func schedules() async throws -> [ScheduleInfo] { [] }

    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        throw ACPEngineError.notSupported("Scheduled tasks are not supported for \(agent.displayName). Use an OpenCode agent for schedules.")
    }

    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {
        throw ACPEngineError.notSupported("Scheduled tasks are not supported for \(agent.displayName).")
    }

    public func deleteSchedule(_ scheduleID: String) async throws {
        throw ACPEngineError.notSupported("Scheduled tasks are not supported for \(agent.displayName).")
    }

    // Effort

    public func modelOptions(for model: ModelRef) async throws -> ModelOptions { await core.modelOptions(for: model) }
    public func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { try await core.setEffort(sessionID, effort: effort) }

    public func setFastMode(_ sessionID: String, enabled: Bool) async throws {
        guard enabled else { return }
        throw ACPEngineError.notSupported("\(agent.displayName) has no fast mode.")
    }

    // Commands

    public func commands(directory: String?) async throws -> [EngineCommand] { await core.commands(directory: directory) }

    /// Sends `/name arguments` as the session's next message; the agent runs the command.
    public func runCommand(_ sessionID: String, name: String, arguments: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ACPEngineError.invalidArgument("Not a command name: \(name)")
        }
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        try await core.send(sessionID, text: "/" + trimmed + (args.isEmpty ? "" : " " + args), files: [], synthetic: false)
    }

    /// Stops the agent processes (for app quit). Sessions reopen with `session/load` on the next prompt.
    public func shutdown() async { await core.shutdown() }

    #else

    // iOS: ACP agents are local processes, so every call explains that they run on the Mac only.
    public func serverInfo() async throws -> (version: String, url: URL) { throw ACPEngineError.unsupportedPlatform }
    public func authState(refresh: Bool = false) async -> ACPAuthState { ACPAuthState(installed: false) }
    public func listSessions() async throws -> [EngineSession] { [] }
    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession { throw ACPEngineError.unsupportedPlatform }
    public func deleteSession(_ sessionID: String) async throws { throw ACPEngineError.unsupportedPlatform }
    public func renameSession(_ sessionID: String, title: String) async throws { throw ACPEngineError.unsupportedPlatform }
    public func setArchived(_ sessionID: String, archived: Bool) async throws { throw ACPEngineError.unsupportedPlatform }
    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { throw ACPEngineError.unsupportedPlatform }
    public func switchModel(_ sessionID: String, model: ModelRef) async throws { throw ACPEngineError.unsupportedPlatform }
    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] { throw ACPEngineError.unsupportedPlatform }
    public func children(_ sessionID: String) async throws -> [EngineSession] { [] }
    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws { throw ACPEngineError.unsupportedPlatform }
    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws { throw ACPEngineError.unsupportedPlatform }
    public func interrupt(_ sessionID: String) async throws { throw ACPEngineError.unsupportedPlatform }
    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws { throw ACPEngineError.unsupportedPlatform }
    public func pendingPermissions() async throws -> [PermissionRequest] { [] }
    public func context(_ sessionID: String) async throws -> ContextBreakdown { throw ACPEngineError.unsupportedPlatform }
    public func changedFiles(_ sessionID: String) async throws -> [FileChange] { [] }
    public func connectors() async throws -> [ConnectorInfo] { [] }
    public func models() async throws -> [ModelInfo] { [] }
    public func providers() async throws -> [ProviderInfo] { [] }
    public func setAPIKey(providerID: String, key: String) async throws { throw ACPEngineError.unsupportedPlatform }
    public func removeAPIKey(providerID: String) async throws { throw ACPEngineError.unsupportedPlatform }
    public func schedules() async throws -> [ScheduleInfo] { [] }
    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo { throw ACPEngineError.unsupportedPlatform }
    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { throw ACPEngineError.unsupportedPlatform }
    public func deleteSchedule(_ scheduleID: String) async throws { throw ACPEngineError.unsupportedPlatform }
    public func modelOptions(for model: ModelRef) async throws -> ModelOptions { ModelOptions() }
    public func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { throw ACPEngineError.unsupportedPlatform }
    public func setFastMode(_ sessionID: String, enabled: Bool) async throws { throw ACPEngineError.unsupportedPlatform }
    public func commands(directory: String?) async throws -> [EngineCommand] { [] }
    public func runCommand(_ sessionID: String, name: String, arguments: String) async throws { throw ACPEngineError.unsupportedPlatform }

    #endif
}

#if os(macOS)
extension ACPEngine: EngineMessageAttachments {}
#endif
