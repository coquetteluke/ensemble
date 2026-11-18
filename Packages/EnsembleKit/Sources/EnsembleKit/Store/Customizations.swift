import Foundation

// The Customizations screen's data: for one folder, what each engine loads (rules and memory, skills, commands and
// agents, MCP servers, hooks and plugins) and what it skips because the folder is not trusted. Built by
// `CustomizationsDiscovery` from files only (nothing is run), optionally merged with what the OpenCode server reports
// (`CustomizationsLive`). Everything shown from a config file goes through `CustomizationRedaction` first.

/// The engines the screen compares.
public enum CustomizationEngine: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, openCode, gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openCode: "OpenCode"
        case .gemini: "Gemini"
        }
    }
}

/// Where an item comes from.
public enum CustomizationScope: Hashable, Sendable {
    /// The user's own config (`~/.claude`, `~/.config/opencode`, `~/.gemini`).
    case user
    /// The folder or a folder above it.
    case project
    /// The user's private notes and settings for this folder (`CLAUDE.local.md`, `settings.local.json`, Claude's
    /// local-scope MCP servers in `~/.claude.json`). Treated like project items for trust.
    case local
    /// An installed plugin, by name.
    case plugin(String)
    /// Shipped with the engine.
    case builtIn

    public var label: String {
        switch self {
        case .user: "User"
        case .project: "Project"
        case .local: "Local"
        case .plugin(let name): "Plugin \(name)"
        case .builtIn: "Built in"
        }
    }

    /// Engines only load these in folders the user trusts.
    public var isProject: Bool { self == .project || self == .local }
}

/// Whether the engine uses an item in this folder now.
public enum CustomizationStatus: Hashable, Sendable {
    /// Loaded at the start of every session here.
    case loaded
    /// Loaded only when something triggers it (the reason says what).
    case onDemand(String)
    /// A project item the engine skips because the folder is not trusted.
    case skippedUntrusted
    /// The engine does not start in this folder at all until it is trusted (Gemini).
    case notStarted
    /// Turned off in its own config (the reason says how).
    case disabled(String)

    public var label: String {
        switch self {
        case .loaded: "Loaded"
        case .onDemand: "On demand"
        case .skippedUntrusted: "Skipped"
        case .notStarted: "Not started"
        case .disabled: "Off"
        }
    }

    /// The longer explanation shown next to the label, if any.
    public var detail: String? {
        switch self {
        case .loaded: nil
        case .onDemand(let reason): reason
        case .skippedUntrusted: "Folder not trusted"
        case .notStarted: "Gemini only starts in folders you trust"
        case .disabled(let reason): reason
        }
    }

    /// Loaded now or when triggered.
    public var isActive: Bool {
        switch self {
        case .loaded, .onDemand: true
        case .skippedUntrusted, .notStarted, .disabled: false
        }
    }
}

/// An instruction file: memory (`CLAUDE.md`), rules (`.claude/rules`, `.agents/rules`) or instructions (`AGENTS.md`,
/// `GEMINI.md`, OpenCode's `instructions` entries).
public struct CustomizationRule: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case memory, rule, instructions }

    public var engine: CustomizationEngine
    public var kind: Kind
    public var scope: CustomizationScope
    /// Absolute path, or for an OpenCode `instructions` entry that is not a file, the entry itself (a pattern or a
    /// redacted URL).
    public var path: String
    /// False for patterns and URLs: there is nothing to open or reveal.
    public var isFile: Bool
    /// Bytes.
    public var size: Int?
    /// The first non-empty lines after any front matter, redacted, at most 160 characters each.
    public var firstLines: [String]
    public var status: CustomizationStatus
    /// Where it came from when that is not obvious ("From opencode.json instructions").
    public var note: String?

    public var id: String { "\(engine.rawValue)|rule|\(path)" }

    public init(engine: CustomizationEngine, kind: Kind, scope: CustomizationScope, path: String, isFile: Bool = true,
                size: Int? = nil, firstLines: [String] = [], status: CustomizationStatus, note: String? = nil) {
        self.engine = engine
        self.kind = kind
        self.scope = scope
        self.path = path
        self.isFile = isFile
        self.size = size
        self.firstLines = firstLines
        self.status = status
        self.note = note
    }
}

/// A skill, slash command or subagent definition.
public struct CustomizationEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case skill, command, agent

        public var label: String {
            switch self {
            case .skill: "Skill"
            case .command: "Command"
            case .agent: "Agent"
            }
        }
    }

    public var engine: CustomizationEngine
    public var kind: Kind
    public var name: String
    /// From the file's front matter (`description`), redacted and cut to 300 characters.
    public var summary: String
    /// The defining file (`SKILL.md`, a command's `.md`, an agent's `.md`), a config file for config-defined entries,
    /// or `skill://<name>` for OpenCode's built-in skills.
    public var path: String
    public var scope: CustomizationScope
    public var status: CustomizationStatus
    public var note: String?

    public var id: String { "\(engine.rawValue)|\(kind.rawValue)|\(path)|\(name)" }

    /// True when `path` is a file on disk.
    public var isFile: Bool { path.hasPrefix("/") }

    public init(engine: CustomizationEngine, kind: Kind, name: String, summary: String = "", path: String,
                scope: CustomizationScope, status: CustomizationStatus, note: String? = nil) {
        self.engine = engine
        self.kind = kind
        self.name = name
        self.summary = summary
        self.path = path
        self.scope = scope
        self.status = status
        self.note = note
    }
}

/// What a running engine says about an MCP server.
public struct CustomizationLiveStatus: Hashable, Sendable {
    public var state: ConnectorInfo.State
    /// The engine's error text, if any (redacted).
    public var message: String?

    public init(state: ConnectorInfo.State, message: String? = nil) {
        self.state = state
        self.message = message
    }

    public var label: String {
        switch state {
        case .connected: "Connected"
        case .needsAuth: "Needs sign-in"
        case .failed: "Failed"
        case .disabled: "Disabled"
        case .connecting: "Connecting"
        }
    }
}

/// One MCP server from a config file (or reported by the engine). Never carries secret values: environment variables
/// and headers are listed by name only, and the command line and URL are redacted.
public struct CustomizationMCPServer: Identifiable, Hashable, Sendable {
    public enum Transport: String, Sendable {
        case stdio, http, sse, unknown

        public var label: String {
            switch self {
            case .stdio: "stdio"
            case .http: "HTTP"
            case .sse: "SSE"
            case .unknown: "Unknown"
            }
        }
    }

    public var engine: CustomizationEngine
    public var scope: CustomizationScope
    public var name: String
    public var transport: Transport
    /// The command line or URL, redacted.
    public var target: String
    /// Names of the environment variables the config sets (values are never read into this type).
    public var environmentKeys: [String]
    /// Names of the HTTP headers the config sets.
    public var headerKeys: [String]
    /// The config file, or nil for a server only the engine reported.
    public var sourcePath: String?
    public var status: CustomizationStatus
    /// From the engine, when it reports status (OpenCode).
    public var live: CustomizationLiveStatus?
    /// OpenCode's integration for the server's sign-in.
    public var integrationID: String?

    public var id: String { "\(engine.rawValue)|mcp|\(sourcePath ?? "engine")|\(name)" }

    public init(engine: CustomizationEngine, scope: CustomizationScope, name: String, transport: Transport, target: String,
                environmentKeys: [String] = [], headerKeys: [String] = [], sourcePath: String?, status: CustomizationStatus,
                live: CustomizationLiveStatus? = nil, integrationID: String? = nil) {
        self.engine = engine
        self.scope = scope
        self.name = name
        self.transport = transport
        self.target = target
        self.environmentKeys = environmentKeys
        self.headerKeys = headerKeys
        self.sourcePath = sourcePath
        self.status = status
        self.live = live
        self.integrationID = integrationID
    }

    /// OpenCode can reconnect a server it runs.
    public var canRestart: Bool { engine == .openCode && live != nil && live?.state != .disabled && status.isActive }

    /// OpenCode can start the server's browser sign-in.
    public var canAuthenticate: Bool { engine == .openCode && status.isActive && live?.state == .needsAuth && integrationID != nil }
}

/// A hook (a command the engine runs at a point in its loop) or an OpenCode plugin.
public struct CustomizationHook: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case hook, plugin }

    public var engine: CustomizationEngine
    public var kind: Kind
    public var scope: CustomizationScope
    /// `PreToolUse`, `SessionStart`, ... or `Plugin`.
    public var event: String
    /// The tool pattern the hook applies to, if any.
    public var matcher: String?
    /// An agy hook's name, or a plugin's id.
    public var name: String?
    /// `command`, `http`, `prompt`, `agent`, `mcp_tool`; for plugins `package` or `file`.
    public var handler: String
    /// The command, URL, prompt start or plugin source, redacted.
    public var command: String
    public var sourcePath: String?
    public var status: CustomizationStatus

    public var id: String { "\(engine.rawValue)|\(kind.rawValue)|\(sourcePath ?? "")|\(name ?? "")|\(event)|\(matcher ?? "")|\(command)" }

    public init(engine: CustomizationEngine, kind: Kind = .hook, scope: CustomizationScope, event: String, matcher: String? = nil,
                name: String? = nil, handler: String = "command", command: String, sourcePath: String?, status: CustomizationStatus) {
        self.engine = engine
        self.kind = kind
        self.scope = scope
        self.event = event
        self.matcher = matcher
        self.name = name
        self.handler = handler
        self.command = command
        self.sourcePath = sourcePath
        self.status = status
    }
}

/// What trusting the folder would change, per engine.
public struct CustomizationTrustSummary: Hashable, Sendable {
    public struct EngineNote: Identifiable, Hashable, Sendable {
        public var engine: CustomizationEngine
        public var headline: String
        public var detail: String
        /// Project files the engine skips now, relative to the folder (`../` for folders above it).
        public var skipped: [String]
        public var id: String { engine.rawValue }

        public init(engine: CustomizationEngine, headline: String, detail: String, skipped: [String]) {
            self.engine = engine
            self.headline = headline
            self.detail = detail
            self.skipped = skipped
        }
    }

    public var folder: String
    public var trusted: Bool
    /// False for the home folder and folders above it, which `WorkspaceTrust` refuses to trust.
    public var canBeTrusted: Bool
    public var notes: [EngineNote]

    public init(folder: String, trusted: Bool, canBeTrusted: Bool = true, notes: [EngineNote]) {
        self.folder = folder
        self.trusted = trusted
        self.canBeTrusted = canBeTrusted
        self.notes = notes
    }

    public func note(for engine: CustomizationEngine) -> EngineNote? { notes.first { $0.engine == engine } }

    /// True when some engine skips something now.
    public var skipsAnything: Bool { notes.contains { !$0.skipped.isEmpty } }
}

/// Everything the screen shows for one folder.
public struct CustomizationsReport: Hashable, Sendable {
    /// The folder, resolved with `realpath`.
    public var folder: String
    public var trusted: Bool
    public var rules: [CustomizationRule]
    public var entries: [CustomizationEntry]
    public var mcpServers: [CustomizationMCPServer]
    public var hooks: [CustomizationHook]
    public var trust: CustomizationTrustSummary
    /// Set when OpenCode's own lists (skills, MCP status, plugins) were merged in, naming the server that answered.
    public var openCodeServer: String?

    public init(folder: String, trusted: Bool, rules: [CustomizationRule] = [], entries: [CustomizationEntry] = [],
                mcpServers: [CustomizationMCPServer] = [], hooks: [CustomizationHook] = [],
                trust: CustomizationTrustSummary? = nil, openCodeServer: String? = nil) {
        self.folder = folder
        self.trusted = trusted
        self.rules = rules
        self.entries = entries
        self.mcpServers = mcpServers
        self.hooks = hooks
        self.trust = trust ?? CustomizationTrustSummary(folder: folder, trusted: trusted, notes: [])
        self.openCodeServer = openCodeServer
    }

    public func rules(for engine: CustomizationEngine) -> [CustomizationRule] { rules.filter { $0.engine == engine } }
    public func entries(for engine: CustomizationEngine) -> [CustomizationEntry] { entries.filter { $0.engine == engine } }
    public func mcpServers(for engine: CustomizationEngine) -> [CustomizationMCPServer] { mcpServers.filter { $0.engine == engine } }
    public func hooks(for engine: CustomizationEngine) -> [CustomizationHook] { hooks.filter { $0.engine == engine } }

    /// Item counts per engine, for the section headers and the dry run.
    public struct Counts: Hashable, Sendable {
        public var rules = 0
        public var skills = 0
        public var commands = 0
        public var agents = 0
        public var mcpServers = 0
        public var hooks = 0
        public var plugins = 0
        public var skipped = 0
    }

    public func counts(for engine: CustomizationEngine) -> Counts {
        var counts = Counts()
        let rules = rules(for: engine), entries = entries(for: engine), servers = mcpServers(for: engine), hooks = hooks(for: engine)
        counts.rules = rules.count
        counts.skills = entries.filter { $0.kind == .skill }.count
        counts.commands = entries.filter { $0.kind == .command }.count
        counts.agents = entries.filter { $0.kind == .agent }.count
        counts.mcpServers = servers.count
        counts.hooks = hooks.filter { $0.kind == .hook }.count
        counts.plugins = hooks.filter { $0.kind == .plugin }.count
        let statuses = rules.map(\.status) + entries.map(\.status) + servers.map(\.status) + hooks.map(\.status)
        counts.skipped = statuses.filter { $0 == .skippedUntrusted || $0 == .notStarted }.count
        return counts
    }
}
