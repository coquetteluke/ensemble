import Foundation

/// Errors from the Claude Code engine.
public enum ClaudeCodeError: Error, LocalizedError, Equatable, Sendable {
    /// The `claude` command was not found.
    case notInstalled
    /// `claude auth status` says nobody is signed in.
    case notSignedIn
    /// The engine only runs on macOS (it starts a local process).
    case unsupportedPlatform
    /// The feature does not exist in this engine (schedules, for example).
    case notSupported(String)
    case unknownSession(String)
    case invalidArgument(String)
    /// The `claude` process could not be started or ended unexpectedly.
    case processFailed(String)
    /// A control request (interrupt, set mode, context) was refused or timed out.
    case controlFailed(String)
    case keychain(String)
    /// The project folder is not in `WorkspaceTrust` and the agent needs it to be (an API-key agent in a folder whose
    /// Claude settings set where requests go). The UI can ask "Trust this folder?", call `WorkspaceTrust.trust`, and
    /// try again.
    case folderNotTrusted(String)
    /// A trusted folder's own Claude settings hold something that needs the user's say first: for an API-key agent
    /// any `env` value outside a short safe list, hooks, MCP servers, plugins, helpers or allow rules; for a
    /// subscription agent anything that can redirect requests or the login (`ANTHROPIC_BASE_URL`, proxies, CA files,
    /// `NODE_OPTIONS`, `apiKeyHelper`, ...). The UI shows the keys (never values) and, if the user agrees, calls
    /// `ClaudeCodeEngine.confirmProjectAPISettings(directory:)`.
    case projectOverridesAPISettings(directory: String, keys: [String])
    /// Plan mode's read-only rules could not be put in place (`ClaudePlanGuard`), so nothing was sent to the agent.
    case planGuardFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The claude command is not installed. Install Claude Code from claude.com/claude-code, then sign in with `claude auth login`."
        case .notSignedIn:
            "Claude Code is not signed in. Run `claude auth login` in Terminal and sign in with your own Claude account."
        case .unsupportedPlatform:
            "Claude agents run on the Mac only."
        case .notSupported(let what):
            what
        case .unknownSession(let id):
            "No Claude session with id \(id)."
        case .invalidArgument(let message):
            message
        case .processFailed(let message):
            "Claude Code stopped: \(message)"
        case .controlFailed(let message):
            "Claude Code did not accept the request: \(message)"
        case .keychain(let message):
            "Keychain error: \(message)"
        case .folderNotTrusted(let directory):
            "\(directory) is not a trusted folder. Its Claude settings change where requests and your API key go, so Ensemble only starts an API-key agent here after you trust the folder and confirm those settings."
        case .planGuardFailed(let reason):
            "Plan mode could not be made read-only, so nothing was sent to the agent (\(reason)). Try again, or choose another mode."
        case .projectOverridesAPISettings(let directory, let keys):
            "The Claude settings in \(directory) set \(keys.joined(separator: ", ")). These can change where requests, your API key or your Claude login go, or run programs while the agent works. Confirm them to start the agent."
        }
    }
}

/// Who pays for a Claude agent.
public enum ClaudeBilling: String, Codable, Sendable, CaseIterable {
    /// The signed-in Claude Pro or Max plan of the Mac's user (the default). Ensemble never touches the login.
    case subscription
    /// An Anthropic API key stored in Ensemble's own Keychain item, passed only to that agent's process.
    case apiKey
}

/// Which of the user's Claude settings files a headless agent loads (`--setting-sources`).
///
/// Project and local settings (`.claude/settings*.json`, and with them the project's `.mcp.json` servers) are only
/// loaded for folders in `WorkspaceTrust`; for any other folder the sources are narrowed with `effective(trusted:)`.
public enum ClaudeSettingSources: String, Codable, Sendable, CaseIterable {
    /// User, project and local settings: the user's own hooks, skills, plugins, CLAUDE.md and permission rules apply,
    /// exactly like their own `claude` sessions (the default, since it is their own Claude).
    case all
    /// The user's own settings (`~/.claude/settings.json`) only: what an untrusted folder gets under `.all`.
    case userOnly
    /// Project and local settings only. The user's global hooks and settings (`~/.claude/settings.json`) are skipped.
    case projectOnly
    /// No settings files at all.
    case none

    /// The `--setting-sources` value, or nil to leave the CLI default.
    var argument: String? {
        switch self {
        case .all: nil
        case .userOnly: "user"
        case .projectOnly: "project,local"
        case .none: ""
        }
    }

    /// The sources for a session folder: unchanged when it is trusted, without project and local settings otherwise.
    public func effective(trusted: Bool) -> ClaudeSettingSources {
        guard !trusted else { return self }
        switch self {
        case .all, .userOnly: return .userOnly
        case .projectOnly, .none: return .none
        }
    }
}

/// Plan usage from the CLI's `rate_limit_event` (subscription limits, not dollars).
public struct ClaudePlanLimits: Codable, Hashable, Sendable {
    public struct Window: Codable, Hashable, Sendable {
        /// `five_hour`, `seven_day`, ...
        public var name: String
        /// 0...1.
        public var utilization: Double
        public var resetsAt: Date?
        /// `allowed`, `allowed_warning`, `rejected`.
        public var status: String?
    }

    /// `allowed`, `allowed_warning` (near a limit) or `rejected` (limit reached).
    public var status: String
    /// The window the status is about (`five_hour`, `seven_day`, ...).
    public var limitType: String?
    public var utilization: Double?
    public var resetsAt: Date?
    public var windows: [Window]
    public var updated: Date

    public init(status: String, limitType: String? = nil, utilization: Double? = nil, resetsAt: Date? = nil,
                windows: [Window] = [], updated: Date = Date()) {
        self.status = status
        self.limitType = limitType
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windows = windows
        self.updated = updated
    }

    /// True when the plan refuses new work until `resetsAt`.
    public var isLimited: Bool { status == "rejected" }
}

/// Model ids and names for Claude agents.
public enum ClaudeModels {
    /// Provider id for agents on the user's Claude subscription.
    public static let subscriptionProviderID = "claude-code"
    /// Provider id for Claude agents billed to an Anthropic API key (same CLI, `ANTHROPIC_API_KEY` set for that agent only).
    public static let apiKeyProviderID = "claude-code-api"

    public static let subscriptionProviderName = "Claude (your subscription)"
    public static let apiKeyProviderName = "Claude (API key)"

    /// Effort levels accepted by `claude --effort`, offered as model variants.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    struct Entry: Sendable {
        let id: String
        let name: String
        /// What the CLI resolved the alias to on 2026-11-18 (claude 2.1.319), for display.
        let resolves: String?
        let contextLimit: Int?
    }

    /// The current models, one entry each, as the CLI's `initialize` answer lists them (claude 2.1.319, 2026-11-18).
    /// Aliases track the newest model of a family: opus -> claude-opus-5-5, sonnet -> claude-sonnet-5-5,
    /// haiku -> claude-haiku-5-5, fable -> claude-fable-5-1. The newest Fable (5.2) has no alias yet, so it is listed by
    /// its full id. Every one has a 1M window with the plain id (`get_context_usage` answers 1,000,000 for each; the
    /// `[1m]` suffix changes nothing for them). Used when the CLI cannot be asked. Notes:
    /// `docs/reference/claude-code-engine-notes.md`.
    static let catalog: [Entry] = [
        Entry(id: "opus", name: "Opus 5.5", resolves: "claude-opus-5-5", contextLimit: 1_000_000),
        Entry(id: "claude-fable-5-2", name: "Fable 5.2", resolves: "claude-fable-5-2", contextLimit: 1_000_000),
        Entry(id: "sonnet", name: "Sonnet 5.5", resolves: "claude-sonnet-5-5", contextLimit: 1_000_000),
        Entry(id: "haiku", name: "Haiku 5.5", resolves: "claude-haiku-5-5", contextLimit: 1_000_000),
        Entry(id: "fable", name: "Fable 5.1", resolves: "claude-fable-5-1", contextLimit: 1_000_000),
    ]

    /// Context windows of the other models the CLI lists, from `get_context_usage` with each id (no prompt sent).
    /// The 4.6 models and Haiku 4.5 have 200k; their `[1m]` ids have 1M.
    static let knownContextWindows: [String: Int] = [
        "claude-opus-5": 1_000_000, "claude-sonnet-5": 1_000_000, "claude-fable-5": 1_000_000,
        "claude-opus-4-8": 1_000_000, "claude-opus-4-7": 1_000_000,
        "claude-opus-4-6": 200_000, "claude-sonnet-4-6": 200_000, "claude-haiku-4-5-20251001": 200_000,
    ]

    static func isClaudeProvider(_ providerID: String) -> Bool {
        providerID == subscriptionProviderID || providerID == apiKeyProviderID
    }

    static func billing(for model: ModelRef?) -> ClaudeBilling {
        model?.providerID == apiKeyProviderID ? .apiKey : .subscription
    }

    /// Context window for a model id or alias when known: what a turn reported (`observed`, from the CLI's
    /// `modelUsage.contextWindow`), else the catalog. An id ending in `[1m]` asks for 1M. `default` is whatever the
    /// CLI picks for the account, which is the first model it lists.
    static func contextLimit(for id: String, observed: [String: Int]) -> Int? {
        let base = id.hasSuffix("[1m]") ? String(id.dropLast(4)) : id
        if let value = observed[id] { return value }
        if base != id { return 1_000_000 }
        if let value = observed[base] { return value }
        if base == "default", let first = catalog.first { return contextLimit(for: first.id, observed: observed) }
        if let entry = catalog.first(where: { $0.id == base }) {
            if let resolved = entry.resolves, let value = observed[resolved] { return value }
            return entry.contextLimit
        }
        if let entry = catalog.first(where: { $0.resolves == base }) { return entry.contextLimit }
        return knownContextWindows[base]
    }
}

/// Ids for Claude agent sessions.
public enum ClaudeSessionIDs {
    /// Subagent sessions have synthetic, stable ids built from the root session and the Agent tool call that started
    /// them: `<root session uuid>.<tool use id>`. The same id comes back from live events and from reloading the
    /// transcript, and it can be routed to the root session without any stored state.
    public static func child(root: String, toolUseID: String) -> String { "\(root).\(toolUseID)" }

    /// The root session of any id (itself for a root).
    public static func root(of sessionID: String) -> String {
        guard let dot = sessionID.firstIndex(of: ".") else { return sessionID }
        return String(sessionID[..<dot])
    }

    /// The Agent tool call behind a subagent session id, or nil for a root session.
    public static func toolUseID(of sessionID: String) -> String? {
        guard let dot = sessionID.firstIndex(of: ".") else { return nil }
        let rest = sessionID[sessionID.index(after: dot)...]
        return rest.isEmpty ? nil : String(rest)
    }

    public static func isChild(_ sessionID: String) -> Bool { toolUseID(of: sessionID) != nil }

    /// Ids of text and thinking rows: the API message id plus the content block index, the same in live
    /// `stream_event`s and in the CLI's transcript file (`apiBlockIndex`).
    static func block(messageID: String, index: Int) -> String { "\(messageID):\(index)" }
}

/// How Ensemble's permission modes map onto Claude Code's `--permission-mode`.
public enum ClaudePermissionModes {
    /// - ask: Claude's `default` mode; anything that needs approval is sent to Ensemble as a prompt.
    /// - acceptEdits: file edits in the project run without asking; commands still ask.
    /// - auto: Claude Code's own auto mode. Headless it does not prompt for most actions: an AI classifier approves or
    ///   blocks each one (tested 2026-11-18: `echo hi > out.txt` and `git push --force origin main` both ran without a
    ///   prompt, the second approved by the classifier). This is looser than Ensemble's allowlist-based Auto for
    ///   OpenCode agents.
    /// - bypass: `bypassPermissions`; the process must be launched with `--allow-dangerously-skip-permissions`.
    /// - plan: Claude Code's `plan` mode. The agent ends with an `ExitPlanMode` call, which arrives as a permission
    ///   request. The CLI's plan mode alone is not read-only (tested 2026-11-18: `echo hi > shell.txt` ran without a
    ///   prompt, approved by the classifier), so the engine adds an ask rule for Bash while in plan and refuses file
    ///   edits itself (`ClaudePlanGuard`).
    public static func cliMode(_ mode: PermissionMode) -> String {
        switch mode {
        case .ask: "default"
        case .acceptEdits: "acceptEdits"
        case .plan: "plan"
        case .auto: "auto"
        case .bypass: "bypassPermissions"
        }
    }

    static func ensembleMode(_ cliMode: String) -> PermissionMode? {
        switch cliMode {
        case "default", "manual": .ask
        case "acceptEdits": .acceptEdits
        case "plan": .plan
        case "auto": .auto
        case "bypassPermissions": .bypass
        default: nil
        }
    }
}
