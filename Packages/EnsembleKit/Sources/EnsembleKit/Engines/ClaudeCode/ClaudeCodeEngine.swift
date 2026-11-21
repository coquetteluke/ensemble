import Foundation
import Synchronization

/// Fans engine events out to every `events()` subscriber.
final class ClaudeEventBroadcaster: Sendable {
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

/// Runs Claude agents on the user's own Claude Pro or Max plan by starting the official, unmodified `claude` CLI
/// headless, one long-lived process per Ensemble session, with stream-json in and out.
///
/// - Login: Ensemble never reads, copies or stores the CLI's login. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
///   `ANTHROPIC_BASE_URL` are removed from the child environment unless the agent uses API-key billing
///   (`ClaudeModels.apiKeyProviderID`), in which case only that agent's process gets the key from Ensemble's own
///   Keychain item.
/// - Never `--bare` (it ignores the subscription login); extra arguments that would turn it on or skip permissions
///   are dropped (`ClaudeCLI.forbiddenArguments`).
/// - Permission prompts arrive as `can_use_tool` control requests on stdout (`--permission-prompts host
///   --permission-prompt-tool stdio`) and are answered on stdin from Ensemble's UI. This was chosen over an MCP prompt
///   tool because it stays on the process's own pipes (no port, helper or config file another process could use),
///   carries the CLI's suggestions and reasons, is withdrawn on interrupt, and does not time out while a person
///   decides (see `ClaudePermissionPrompt`). "Always" answers are remembered and matched by Ensemble only
///   (`ClaudePermissionRules`); the CLI is never handed rules.
/// - Usage: tokens per turn from the `result` line. For plan agents the CLI's dollar estimate is dropped (it is not
///   money the user pays); plan limits come from `rate_limit_event` (`planLimits()`).
/// - Fork and rewind, as far as the CLI supports them: fork is `--resume <id> --fork-session --session-id <new>`, at a
///   message with `--resume-session-at <entry>` (the flag behind the Agent SDK's `resumeSessionAt`, hidden from
///   `--help`). Rewind resumes the next launch at the entry before the message; the old branch stays in the CLI's
///   transcript file and Ensemble shows only the active chain. Files go back through the SDK's file checkpointing
///   (`CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING`, `rewind_files` control request, dry run first). That restores
///   files changed by the CLI's own edit tools only, not changes made by shell commands, and is best effort.
/// - One subscription serves only its owner: this engine only runs on the owner's Mac for the owner's sessions.
public final class ClaudeCodeEngine: OpenCodeAPI, EngineModelOptionsControl, EngineHistoryControl, EngineCommandsControl, Sendable {
    public struct Configuration: Sendable {
        /// Path to `claude`; nil searches `~/.local/bin`, Homebrew and PATH.
        public var executablePath: String?
        /// The session list (`~/Library/Application Support/Ensemble/claude-sessions.json`).
        public var storeURL: URL
        /// The CLI's transcripts (`~/.claude/projects`, or `$CLAUDE_CONFIG_DIR/projects`).
        public var projectsDirectory: URL
        /// Which settings files agents load. `.all` (default) keeps the user's own hooks, skills, plugins and CLAUDE.md,
        /// like their own `claude` sessions. A project's own settings are only loaded when `trust` trusts its folder.
        public var settingSources: ClaudeSettingSources
        /// Folders whose own Claude settings may run (shared with the other engines and the UI).
        public var trust: WorkspaceTrust
        /// `summarized` streams a summary of the model's thinking; nil leaves the CLI default (token counts only).
        public var thinkingDisplay: String?
        /// Snapshot files before edits so rewind can restore them.
        public var fileCheckpointing: Bool
        /// Keychain service for the optional API key.
        public var keychainService: String
        public var extraArguments: [String]
        /// The environment the child's allowlist is taken from.
        public var baseEnvironment: [String: String]
        /// Ensemble's own MCP server (`AgentToolsServer`), attached to every agent with a private `--mcp-config` file.
        public var agentTools: (any AgentToolsAttaching)? = AgentToolsServer.shared
        /// Where pictures taken out of transcripts are kept as files (`MessagePictureCache`). The app's caches folder
        /// with the default session list; next to the session list otherwise, so a test engine stays in its own folder.
        public var pictureCacheDirectory: URL

        public init(executablePath: String? = nil, storeURL: URL? = nil, projectsDirectory: URL? = nil,
                    settingSources: ClaudeSettingSources = .all, thinkingDisplay: String? = "summarized",
                    fileCheckpointing: Bool = true, keychainService: String = "Ensemble Claude API key",
                    extraArguments: [String] = [], baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                    trust: WorkspaceTrust = .shared, pictureCacheDirectory: URL? = nil) {
            self.executablePath = executablePath
            self.trust = trust
            self.storeURL = storeURL ?? ClaudeSessionStore.defaultURL
            self.pictureCacheDirectory = pictureCacheDirectory
                ?? storeURL.map { $0.deletingLastPathComponent().appendingPathComponent("pictures", isDirectory: true) }
                ?? MessagePictureCache.appDirectory
            self.projectsDirectory = projectsDirectory ?? ClaudeTranscriptFiles.defaultProjectsDirectory(environment: baseEnvironment)
            self.settingSources = settingSources
            self.thinkingDisplay = thinkingDisplay
            self.fileCheckpointing = fileCheckpointing
            self.keychainService = keychainService
            self.extraArguments = extraArguments
            self.baseEnvironment = baseEnvironment
        }
    }

    public let configuration: Configuration
    let broadcaster = ClaudeEventBroadcaster()
    #if os(macOS)
    let core: ClaudeEngineCore
    #endif

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        #if os(macOS)
        core = ClaudeEngineCore(configuration: configuration, broadcaster: broadcaster)
        #endif
    }

    public var rewindRestoresFiles: Bool { configuration.fileCheckpointing }

    public func events() -> AsyncStream<EngineEvent> { broadcaster.stream() }

    #if os(macOS)

    // MARK: Server

    public func serverInfo() async throws -> (version: String, url: URL) {
        let state = await core.authState(refresh: false)
        guard state.installed, let url = await core.executableURL() else { throw ClaudeCodeError.notInstalled }
        return (state.version ?? "unknown", url)
    }

    /// Sign-in state from `claude auth status` (cached for a minute unless `refresh`).
    public func authState(refresh: Bool = false) async -> ClaudeAuthState { await core.authState(refresh: refresh) }

    /// The newest plan usage the CLI reported (five-hour and weekly windows), or nil before the first turn.
    public func planLimits() async -> ClaudePlanLimits? { await core.currentPlanLimits() }

    /// True when the folder has Claude settings or MCP servers of its own that agents leave out because the folder is
    /// not trusted (the UI can offer "Trust this folder?").
    public func ignoresProjectSettings(directory: String) -> Bool {
        !configuration.trust.isTrusted(directory) && ClaudeProjectSettings.hasOwnSettings(directory: directory)
    }

    /// Agrees to a trusted folder's own Claude settings as they are now (after
    /// `ClaudeCodeError.projectOverridesAPISettings`), for API-key and subscription agents. Agents then get a private
    /// copy of exactly these values, so later edits to the files have no effect; the agreement lapses when they change.
    public func confirmProjectAPISettings(directory: String) async throws {
        try await core.confirmProjectAPISettings(directory: directory)
    }

    // MARK: Sessions

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

    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        let source = try await core.transcriptSource(sessionID)
        guard let file = source.file else { return [] }
        let data = ClaudeTranscriptFiles.read(file)
        let chain = data.activeChain(leafOverride: source.leafOverride, includeSidechains: source.builder.includeSidechains)
        return source.builder.items(from: chain)
    }

    public func children(_ sessionID: String) async throws -> [EngineSession] {
        await core.children(of: sessionID)
    }

    /// The transcript with each message's pictures and files beside it (`EngineMessageAttachments`). A picture in the
    /// CLI's transcript is base64 text inside its line; it is copied once into the picture cache so it can be shown.
    public func attachedTranscript(_ sessionID: String) async throws -> AttachedTranscript {
        var source = try await core.transcriptSource(sessionID)
        guard let file = source.file else { return AttachedTranscript() }
        source.builder.attachmentsApart = true
        let data = ClaudeTranscriptFiles.read(file)
        let chain = data.activeChain(leafOverride: source.leafOverride, includeSidechains: source.builder.includeSidechains)
        let built = source.builder.build(from: chain)
        let cache = MessagePictureCache(directory: configuration.pictureCacheDirectory)
        var table: [String: [MessageAttachment]] = [:]
        for (rowID, entries) in built.attached {
            table[rowID] = entries.enumerated().map { index, entry in
                switch entry {
                case .picture(let mediaType, let base64):
                    return MessageAttachment(id: "\(rowID):\(index)", kind: .image, mediaType: mediaType,
                                             path: cache.store(base64: base64, mediaType: mediaType)?.path)
                case .file(let path):
                    var attachment = MessageAttachments.forFiles([URL(fileURLWithPath: path)])[0]
                    attachment.id = "\(rowID):\(index)"
                    return attachment
                }
            }
        }
        return AttachedTranscript(items: built.items, attachments: table)
    }

    // MARK: Talking

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

    public func interrupt(_ sessionID: String) async throws { try await core.interrupt(sessionID) }

    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await core.replyPermission(requestID: requestID, decision: decision, message: message)
    }

    public func pendingPermissions() async throws -> [PermissionRequest] { await core.pendingRequests() }

    // MARK: Panels

    public func context(_ sessionID: String) async throws -> ContextBreakdown { try await core.context(sessionID) }

    public func changedFiles(_ sessionID: String) async throws -> [FileChange] {
        let sources = try await core.changedFileSources(sessionID)
        var merged: [String: FileChange] = [:]
        var order: [String] = []
        for source in sources {
            let data = ClaudeTranscriptFiles.read(source.file)
            let chain = data.activeChain(leafOverride: source.leafOverride, includeSidechains: source.builder.includeSidechains)
            for change in source.builder.changedFiles(from: chain) {
                if var existing = merged[change.path] {
                    existing.additions += change.additions
                    existing.deletions += change.deletions
                    existing.diff = [existing.diff, change.diff].compactMap { $0 }.joined(separator: "\n")
                    merged[change.path] = existing
                } else {
                    order.append(change.path)
                    merged[change.path] = change
                }
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// MCP servers from the newest `system/init` of any running agent.
    public func connectors() async throws -> [ConnectorInfo] { await core.currentConnectors() }

    // MARK: Models and keys

    public func models() async throws -> [ModelInfo] { await core.models() }
    public func providers() async throws -> [ProviderInfo] { await core.providers() }

    /// Stores the API key for Claude agents set to API billing (provider `claude-code` or `claude-code-api`).
    public func setAPIKey(providerID: String, key: String) async throws {
        guard ClaudeModels.isClaudeProvider(providerID) else { throw ClaudeCodeError.invalidArgument("Unknown provider \(providerID).") }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeCodeError.invalidArgument("The API key is empty.") }
        try ClaudeKeychain(service: configuration.keychainService).save(trimmed)
    }

    public func removeAPIKey(providerID: String) async throws {
        guard ClaudeModels.isClaudeProvider(providerID) else { throw ClaudeCodeError.invalidArgument("Unknown provider \(providerID).") }
        try ClaudeKeychain(service: configuration.keychainService).delete()
    }

    // MARK: Schedules

    public func schedules() async throws -> [ScheduleInfo] { [] }

    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        throw ClaudeCodeError.notSupported("Scheduled tasks are not supported by the Claude engine. Use an OpenCode agent for schedules.")
    }

    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {
        throw ClaudeCodeError.notSupported("Scheduled tasks are not supported by the Claude engine.")
    }

    public func deleteSchedule(_ scheduleID: String) async throws {
        throw ClaudeCodeError.notSupported("Scheduled tasks are not supported by the Claude engine.")
    }

    // MARK: Effort and fast mode

    public func modelOptions(for model: ModelRef) async throws -> ModelOptions { await core.modelOptions(for: model) }
    public func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { try await core.setEffort(sessionID, effort: effort?.rawValue) }
    public func setFastMode(_ sessionID: String, enabled: Bool) async throws { try await core.setFastMode(sessionID, enabled: enabled) }

    // MARK: Fork and rewind

    public func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        let source = try await core.historySource(sessionID)
        var keep: String?
        if let messageID {
            let chain = ClaudeTranscriptFiles.read(source.file).activeChain(leafOverride: source.leafOverride)
            guard let point = ClaudeHistory.forkPoint(at: messageID, in: chain) else {
                throw ClaudeCodeError.invalidArgument("That message is not in this session's history.")
            }
            keep = point
        }
        return try await core.createFork(of: sessionID, keep: keep)
    }

    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws {
        let source = try await core.historySource(sessionID)
        let chain = ClaudeTranscriptFiles.read(source.file).activeChain(leafOverride: source.leafOverride)
        guard let cut = ClaudeHistory.cut(before: messageID, in: chain) else {
            throw ClaudeCodeError.invalidArgument("That message is not in this session's history.")
        }
        try await core.applyRewind(sessionID, cut: cut)
    }

    // MARK: Slash commands and skills

    public func commands(directory: String?) async throws -> [EngineCommand] { try await core.commands(directory: directory) }

    /// Sends `/name arguments` as the session's next message; the CLI runs the command or skill.
    public func runCommand(_ sessionID: String, name: String, arguments: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ClaudeCodeError.invalidArgument("Not a command name: \(name)")
        }
        guard !ClaudeInitializeInfo.hiddenCommands.contains(trimmed) else {
            throw ClaudeCodeError.notSupported("/\(trimmed) is not available in Ensemble; use Ensemble's own control for it.")
        }
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        try await core.send(sessionID, text: "/" + trimmed + (args.isEmpty ? "" : " " + args), files: [], synthetic: false)
    }

    /// Stops every agent process (for app quit). Sessions resume on the next prompt.
    public func shutdown() async { await core.shutdown() }

    #else

    // iOS: the engine needs a local `claude` process, so every call explains that it runs on the Mac only.
    public func serverInfo() async throws -> (version: String, url: URL) { throw ClaudeCodeError.unsupportedPlatform }
    public func listSessions() async throws -> [EngineSession] { [] }
    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession { throw ClaudeCodeError.unsupportedPlatform }
    public func deleteSession(_ sessionID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func renameSession(_ sessionID: String, title: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func setArchived(_ sessionID: String, archived: Bool) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func switchModel(_ sessionID: String, model: ModelRef) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] { throw ClaudeCodeError.unsupportedPlatform }
    public func children(_ sessionID: String) async throws -> [EngineSession] { [] }
    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func interrupt(_ sessionID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func pendingPermissions() async throws -> [PermissionRequest] { [] }
    public func context(_ sessionID: String) async throws -> ContextBreakdown { throw ClaudeCodeError.unsupportedPlatform }
    public func changedFiles(_ sessionID: String) async throws -> [FileChange] { [] }
    public func connectors() async throws -> [ConnectorInfo] { [] }
    public func models() async throws -> [ModelInfo] { [] }
    public func providers() async throws -> [ProviderInfo] { [] }
    public func setAPIKey(providerID: String, key: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func removeAPIKey(providerID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func schedules() async throws -> [ScheduleInfo] { [] }
    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo { throw ClaudeCodeError.unsupportedPlatform }
    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func deleteSchedule(_ scheduleID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func modelOptions(for model: ModelRef) async throws -> ModelOptions { ModelOptions() }
    public func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func setFastMode(_ sessionID: String, enabled: Bool) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession { throw ClaudeCodeError.unsupportedPlatform }
    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func commands(directory: String?) async throws -> [EngineCommand] { [] }
    public func runCommand(_ sessionID: String, name: String, arguments: String) async throws { throw ClaudeCodeError.unsupportedPlatform }

    #endif
}

#if os(macOS)
extension ClaudeCodeEngine: EngineMessageAttachments {}
#endif
