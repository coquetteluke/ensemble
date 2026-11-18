import Foundation

/// Who a bridge serves.
public enum AgentToolsTarget: Hashable, Sendable {
    /// One session: Claude (one `claude` process per session) and ACP agents (`mcpServers` in `session/new`).
    case session(String)
    /// Every OpenCode session in one folder on one OpenCode server. OpenCode 2.3 has no per-session MCP servers (they
    /// belong to a location), so each call names its session in `_meta["ai.opencode/sessionID"]`, which OpenCode itself
    /// fills in, and Ensemble checks that the session is one of its own in that folder.
    case folder(String, server: String)
}

/// What an engine needs to start the bridge for one target: the helper's path and its environment.
public struct AgentToolsAttachment: Equatable, Sendable {
    public var executable: String
    public var socketPath: String
    public var key: String

    public init(executable: String, socketPath: String, key: String) {
        self.executable = executable
        self.socketPath = socketPath
        self.key = key
    }

    /// The server's name in every engine: Claude shows the tools as `mcp__ensemble__<tool>`, OpenCode as
    /// `ensemble_<tool>`.
    public static let serverName = AgentToolsMCP.serverName

    public var environment: [String: String] {
        [AgentToolsBridge.socketVariable: socketPath, AgentToolsBridge.keyVariable: key]
    }

    /// A Claude `--mcp-config` file.
    public var claudeConfig: JSONValue {
        let env = JSONValue.object(environment.mapValues { .string($0) })
        return ["mcpServers": .object([Self.serverName: ["type": "stdio", "command": .string(executable), "args": [], "env": env]])]
    }

    /// An ACP `McpServer` (stdio) for `session/new` and `session/load`.
    public var acpServer: JSONValue {
        let env = environment.keys.sorted().map { key -> JSONValue in ["name": .string(key), "value": .string(environment[key] ?? "")] }
        return ["name": .string(Self.serverName), "command": .string(executable), "args": [], "env": .array(env)]
    }

    /// The milliseconds OpenCode lets one call run: long enough for the user to answer a browser permission card.
    public static let openCodeExecutionTimeout = 600_000

    /// An OpenCode `Mcp.LocalConfig` for `PUT /api/experimental/mcp/ensemble`. `codemode` is off so the tools appear
    /// to the model as ordinary tools (`ensemble_propose_session`) rather than inside OpenCode's `execute` scripts.
    public var openCodeConfig: JSONValue {
        [
            "type": "local",
            "command": [.string(executable)],
            "environment": .object(environment.mapValues { .string($0) }),
            "codemode": false,
            "timeout": ["execution": .number(Double(Self.openCodeExecutionTimeout))],
        ]
    }
}

/// Hands engines the bridge for a session or folder. Engines read it through their configuration; nil when Ensemble's
/// agent tools are not running (tests, the iPhone app), and then nothing is attached.
public protocol AgentToolsAttaching: Sendable {
    /// False while nothing would be attached, so engines skip the lookups an attachment needs.
    var isAttaching: Bool { get }
    func attachment(for target: AgentToolsTarget) -> AgentToolsAttachment?
    /// Ties a key to the engine process it is handed to (`AgentToolsBinding`).
    func expect(_ binding: AgentToolsBinding, for target: AgentToolsTarget)
    /// Lets a folder key speak for an OpenCode session on that server.
    func allow(openCodeSession sessionID: String, on target: AgentToolsTarget)
}
