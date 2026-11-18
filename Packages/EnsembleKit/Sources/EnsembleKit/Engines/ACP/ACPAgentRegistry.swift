import Foundation

/// A coding tool that speaks the Agent Client Protocol over stdio, and how Ensemble starts and checks it.
///
/// Ensemble only ever starts the tool's own official binary as itself, signed in the way the tool signs in. It never
/// reads, copies or passes the tool's credentials, never calls the tool's servers itself, and drops API key variables
/// from the child environment so a stray key in Ensemble's environment cannot switch a subscription agent to key
/// billing.
public struct ACPAgentDefinition: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable {
        /// Tested end to end with Ensemble's ACP client (see `verifiedVersion`).
        case verified
        /// Launch command taken from the tool's documentation and the ACP registry; not tested with Ensemble yet.
        case unverified
    }

    /// How the tool treats a project's own settings (hooks, plugins, rules, MCP servers in the project folder), which can
    /// run code as soon as an agent starts there.
    public enum WorkspaceSettings: Sendable, Hashable {
        /// The tool always loads them and cannot be told not to: Ensemble only starts it in folders the user trusts.
        case alwaysLoaded
        /// These extra arguments make the tool skip them, so untrusted folders run with them added.
        case skippable(arguments: [String])
    }

    /// How Ensemble can tell whether the user is signed in, without touching credentials.
    public enum SignInCheck: Sendable, Hashable {
        /// Open a throwaway ACP session in an empty folder: an auth error (-32000) means signed out.
        case acpSession
        /// No check; the first prompt reports a sign-in error if there is one.
        case none
    }

    /// Also the provider id of the tool's models in Ensemble (`antigravity/gemini-3.8-flash#low`).
    public var id: String
    public var displayName: String
    /// Shown as the provider in the model picker.
    public var providerName: String
    /// Executable names searched in `searchDirectories`, then in PATH.
    public var executableNames: [String]
    /// Extra folders to look in (`~` is expanded).
    public var searchDirectories: [String]
    /// Arguments that start the ACP stdio server.
    public var arguments: [String]
    /// Arguments that approve every tool call, used only for sessions in Bypass mode (they get their own process).
    /// nil: the tool has no such switch, and Ensemble approves each request itself in Bypass.
    public var bypassArguments: [String]?
    /// The tool's session mode for each Ensemble permission mode. Missing entries are guessed from the mode ids the
    /// agent offers (`ACPModes.guess`).
    public var modeIDs: [PermissionMode: String]
    /// True when Ensemble decides the tool's prompts in Auto (`SafetyCheckAgents.swift`): `modeIDs[.auto]` is then a
    /// mode that asks before every edit and command, and Ensemble answers each prompt itself. False leaves Auto to the
    /// tool's own mode.
    public var ensembleDecidesAuto: Bool
    public var installHint: String
    public var signInHint: String
    public var signInCheck: SignInCheck
    public var status: Status
    /// The version Ensemble was tested with.
    public var verifiedVersion: String?
    /// At most this many turns run at once across the tool's sessions; more wait in line. nil: no limit.
    public var maxConcurrentTurns: Int?
    public var workspaceSettings: WorkspaceSettings
    /// Variables passed through from Ensemble's environment on top of `ACPEnvironment.passThrough`.
    public var environmentPassThrough: [String]
    /// Who pays for the tool's models.
    public var billing: ModelBilling
    /// What the tool does differently, for the docs and the Accounts screen.
    public var notes: String
    /// Arguments that make the tool print its plan use without starting a turn (agy: `-p /usage --output-format json`),
    /// read by `ACPEngine.planStatus()`. nil: the tool reports none.
    public var planUsageArguments: [String]?

    public init(id: String, displayName: String, providerName: String, executableNames: [String], searchDirectories: [String] = [],
                arguments: [String], bypassArguments: [String]? = nil, modeIDs: [PermissionMode: String] = [:],
                ensembleDecidesAuto: Bool = false, installHint: String, signInHint: String, signInCheck: SignInCheck = .none, status: Status,
                verifiedVersion: String? = nil, maxConcurrentTurns: Int? = nil, workspaceSettings: WorkspaceSettings = .alwaysLoaded,
                environmentPassThrough: [String] = [], billing: ModelBilling = .subscription, notes: String = "",
                planUsageArguments: [String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.providerName = providerName
        self.executableNames = executableNames
        self.searchDirectories = searchDirectories
        self.arguments = arguments
        self.bypassArguments = bypassArguments
        self.modeIDs = modeIDs
        self.ensembleDecidesAuto = ensembleDecidesAuto
        self.installHint = installHint
        self.signInHint = signInHint
        self.signInCheck = signInCheck
        self.status = status
        self.verifiedVersion = verifiedVersion
        self.maxConcurrentTurns = maxConcurrentTurns
        self.workspaceSettings = workspaceSettings
        self.environmentPassThrough = environmentPassThrough
        self.billing = billing
        self.notes = notes
        self.planUsageArguments = planUsageArguments
    }

    /// True when the tool needs the project folder to be trusted before it may start there.
    public var requiresTrustedFolder: Bool {
        if case .alwaysLoaded = workspaceSettings { return true }
        return false
    }
}

/// Where a tool is installed, if anywhere.
public struct ACPAgentInstallation: Sendable, Hashable {
    public var definition: ACPAgentDefinition
    public var executable: URL?
    public var installed: Bool { executable != nil }
}

/// The ACP tools Ensemble knows. The app lists only tools that are installed and verified
/// (`ACPAgentRegistry.available()`); unverified entries are kept so they can be tested and promoted.
public enum ACPAgentRegistry {
    /// Google Antigravity CLI (`agy`), on the user's Google AI Pro or Ultra plan. Verified with agy 1.5.10 on
    /// 2026-11-18. Google has suspended accounts whose Antigravity sign-in was used by unofficial tools, so Ensemble
    /// only runs the official `agy` binary, never touches its sign-in, never calls Google's servers itself, and runs at
    /// most three agy turns at once by default.
    public static let antigravity = ACPAgentDefinition(
        id: "antigravity",
        displayName: "Google Antigravity",
        providerName: "Gemini (your Google AI subscription)",
        executableNames: ["agy"],
        searchDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"],
        arguments: ["acp"],
        bypassArguments: ["--dangerously-skip-permissions"],
        // Auto runs in `default`, which asks before every edit and command, and Ensemble answers each prompt: agy's own
        // `auto` sends no prompts at all (it ran `rm -rf`, a curl to the internet and a `BypassSandbox` retry unasked).
        modeIDs: [.ask: "default", .acceptEdits: "accept-edits", .plan: "plan", .auto: "default", .bypass: "auto"],
        ensembleDecidesAuto: true,
        installHint: "Install the Antigravity CLI with `brew install --cask antigravity-cli`.",
        signInHint: "Run `agy` once in Terminal and sign in with your Google account (it shares the Antigravity app's sign-in).",
        signInCheck: .acpSession,
        status: .verified,
        verifiedVersion: "1.5.10",
        maxConcurrentTurns: 3,
        workspaceSettings: .alwaysLoaded,
        notes: """
        agy acp loads the project's .agents/ hooks, rules, skills and plugins and GEMINI.md/AGENTS.md even in a folder \
        it was never told to trust (tested: a SessionStart hook ran), and `agy acp` has no switch to skip them \
        (`--settings` is not accepted there), so Ensemble starts it only in trusted folders. Permission prompts offer \
        allow once and deny only; "always" is remembered by Ensemble. The user's own Antigravity permission preset \
        (for example Turbo) does not apply to ACP sessions once Ensemble sets the session mode: in `default` mode shell \
        commands, file writes and reads outside the project all ask. agy's own `auto` mode sends no prompts at all, so \
        Ensemble's Auto runs in `default` and Ensemble answers each prompt itself.
        """,
        // agy answers its own `/usage` command in print mode without a turn (ACP has no such command: a "/usage" prompt
        // goes to the model).
        planUsageArguments: ["-p", "/usage", "--output-format", "json"])

    /// OpenCode's own ACP server, tested to show the client is generic. Its models are the user's OpenCode providers.
    public static let openCode = ACPAgentDefinition(
        id: "opencode-acp",
        displayName: "OpenCode (ACP)",
        providerName: "OpenCode via ACP",
        executableNames: ["opencode"],
        searchDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "~/.opencode/bin", "~/.local/bin"],
        arguments: ["acp"],
        bypassArguments: nil,
        modeIDs: [:],
        installHint: "Install OpenCode with `brew install opencode`.",
        signInHint: "Run `opencode auth login` in Terminal to add a provider.",
        signInCheck: .none,
        status: .verified,
        verifiedVersion: "2.3.0",
        workspaceSettings: .alwaysLoaded,
        environmentPassThrough: ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR"],
        billing: .apiKey,
        notes: """
        Modes are OpenCode agents (build, plan), not permission levels, and the default ruleset allows every tool: \
        prompts only appear for actions the user's or project's opencode.json sets to "ask". A rejected prompt ends \
        the turn as cancelled. The project's opencode.json (providers, MCP servers, plugins) is loaded, so it needs a \
        trusted folder.
        """)

    // Unverified: documented launch commands from each tool's docs and the ACP registry (agentclientprotocol/registry,
    // 2026-11-18). Not installed on the test Mac, not tested with Ensemble.

    public static let geminiCLI = ACPAgentDefinition(
        id: "gemini-cli", displayName: "Gemini CLI", providerName: "Gemini CLI (Workspace or Code Assist account)",
        executableNames: ["gemini"], arguments: ["--acp"],
        installHint: "Install with `npm install -g @google/gemini-cli`.",
        signInHint: "Run `gemini` once in Terminal and sign in with a Google Workspace or Gemini Code Assist account (personal accounts use Antigravity).",
        status: .unverified)

    public static let qwenCode = ACPAgentDefinition(
        id: "qwen-code", displayName: "Qwen Code", providerName: "Qwen Code",
        executableNames: ["qwen"], arguments: ["--acp"],
        installHint: "Install with `npm install -g @qwen-code/qwen-code`.",
        signInHint: "Run `qwen` once in Terminal and sign in.",
        status: .unverified)

    public static let codexACP = ACPAgentDefinition(
        id: "codex-acp", displayName: "Codex (ACP adapter)", providerName: "Codex (your ChatGPT plan)",
        executableNames: ["codex-acp"], arguments: [],
        installHint: "Install with `npm install -g @agentclientprotocol/codex-acp` (needs the Codex CLI).",
        signInHint: "Run `codex login` in Terminal.",
        status: .unverified)

    public static let cursorCLI = ACPAgentDefinition(
        id: "cursor-cli", displayName: "Cursor CLI", providerName: "Cursor (your Cursor plan)",
        executableNames: ["cursor-agent"], searchDirectories: ["~/.local/bin"], arguments: ["acp"],
        installHint: "Install with `curl https://cursor.com/install -fsS | bash`.",
        signInHint: "Run `cursor-agent login` in Terminal.",
        status: .unverified)

    public static let kiroCLI = ACPAgentDefinition(
        id: "kiro-cli", displayName: "Kiro CLI", providerName: "Kiro (your Kiro plan)",
        executableNames: ["kiro-cli"], searchDirectories: ["~/.local/bin"], arguments: ["acp", "--agent-engine=v3"],
        installHint: "Install the Kiro CLI from kiro.dev.",
        signInHint: "Run `kiro-cli login` in Terminal.",
        status: .unverified)

    public static let goose = ACPAgentDefinition(
        id: "goose", displayName: "goose", providerName: "goose",
        executableNames: ["goose"], searchDirectories: ["~/.local/bin"], arguments: ["acp"],
        installHint: "Install with `brew install block-goose-cli`.",
        signInHint: "Run `goose configure` in Terminal to pick a provider.",
        status: .unverified, billing: .apiKey)

    /// Every known tool, verified first.
    public static let all: [ACPAgentDefinition] = [antigravity, openCode, geminiCLI, qwenCode, codexACP, cursorCLI, kiroCLI, goose]

    public static var verified: [ACPAgentDefinition] { all.filter { $0.status == .verified } }

    public static func definition(id: String) -> ACPAgentDefinition? { all.first { $0.id == id } }

    /// Where the tool's executable is, or nil when it is not installed.
    public static func locate(_ definition: ACPAgentDefinition, override: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var directories = definition.searchDirectories.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in directories where !directory.isEmpty {
            for name in definition.executableNames {
                let path = (directory as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    public static func installation(_ definition: ACPAgentDefinition,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> ACPAgentInstallation {
        ACPAgentInstallation(definition: definition, executable: locate(definition, environment: environment))
    }

    /// The tools Ensemble offers: verified and installed.
    public static func available(environment: [String: String] = ProcessInfo.processInfo.environment) -> [ACPAgentInstallation] {
        verified.map { installation($0, environment: environment) }.filter(\.installed)
    }
}

/// Mapping Ensemble's permission modes onto an agent's session modes.
enum ACPModes {
    /// Mode ids tried, in order, when a tool's definition has no entry for a permission mode.
    static let candidates: [PermissionMode: [String]] = [
        .ask: ["default", "ask", "manual", "normal"],
        .acceptEdits: ["accept-edits", "acceptEdits", "accept_edits", "auto-edit", "autoEdit"],
        // No guess for Plan: a mode called "plan" is not necessarily read-only (OpenCode's ACP `plan` agent runs shell
        // commands without asking), so only a definition that names its plan mode gets one.
        .auto: ["auto", "smart"],
        .bypass: ["bypassPermissions", "bypass", "yolo", "auto"],
    ]

    /// The agent mode id for `mode`, or nil when the agent has no matching mode.
    static func modeID(for mode: PermissionMode, definition: ACPAgentDefinition, available: [String]) -> String? {
        if let wanted = definition.modeIDs[mode] {
            return available.isEmpty || available.contains(wanted) ? wanted : nil
        }
        guard !available.isEmpty else { return nil }
        for candidate in candidates[mode] ?? [] {
            if let match = available.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return match }
        }
        return nil
    }
}

/// The child environment for ACP tools.
enum ACPEnvironment {
    /// Variables passed through from Ensemble's own environment. Everything else is dropped, in particular API keys
    /// (`GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY`, ...) that would switch a tool from the user's sign-in to key
    /// billing, and variables of whatever shell or agent started Ensemble.
    static let passThrough: Set<String> = [
        "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TMPDIR", "SHELL", "SSH_AUTH_SOCK",
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy", "__CF_USER_TEXT_ENCODING",
    ]

    static func environment(base: [String: String], definition: ACPAgentDefinition) -> [String: String] {
        var env: [String: String] = [:]
        let allowed = passThrough.union(definition.environmentPassThrough)
        for (key, value) in base where allowed.contains(key) { env[key] = value }
        let home = env["HOME"] ?? NSHomeDirectory()
        env["HOME"] = home
        var path = (base["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }
}
