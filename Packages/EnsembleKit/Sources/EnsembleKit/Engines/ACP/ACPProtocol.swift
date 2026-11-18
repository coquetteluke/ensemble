import Foundation

// Agent Client Protocol v1 types, decoded leniently from `JSONValue` (unknown fields are ignored, missing optional
// fields fall back to defaults), following schema/v1 of agentclientprotocol/agent-client-protocol (schema 1.32,
// 2026-11-14) and what `agy acp` 1.5.10 and `opencode acp` 2.3.0 actually send. Differences from the schema that the
// decoder accepts on purpose are noted where they are handled.

/// The ACP protocol version Ensemble speaks. v2 (a different prompt lifecycle) is not supported yet; agents that answer
/// `initialize` with another version are refused.
let acpProtocolVersion = 1

/// What the agent said in answer to `initialize`.
struct ACPAgentInfo: Equatable, Sendable {
    var protocolVersion: Int
    var name: String?
    var version: String?
    var loadSession: Bool
    var resumeSession: Bool
    var closeSession: Bool
    var listSessions: Bool
    var deleteSession: Bool
    var forkSession: Bool
    var promptImage: Bool
    var promptEmbeddedContext: Bool
    var authMethods: [String]

    init(result: JSONValue) {
        protocolVersion = result["protocolVersion"]?.acpInt ?? 0
        name = result["agentInfo"]?["name"]?.acpText
        version = result["agentInfo"]?["version"]?.acpText
        let caps = result["agentCapabilities"] ?? .null
        // Antigravity also sends snake_case copies (`load_session`, `session_capabilities`); the camelCase ones win.
        let sessionCaps = caps["sessionCapabilities"] ?? caps["session_capabilities"] ?? .null
        func has(_ key: String) -> Bool {
            if let value = sessionCaps[key], value != .null { return true }
            return false
        }
        loadSession = caps["loadSession"]?.acpBool ?? caps["load_session"]?.acpBool ?? has("load")
        resumeSession = has("resume")
        closeSession = has("close")
        listSessions = has("list")
        deleteSession = has("delete")
        forkSession = has("fork")
        promptImage = caps["promptCapabilities"]?["image"]?.acpBool ?? false
        promptEmbeddedContext = caps["promptCapabilities"]?["embeddedContext"]?.acpBool ?? false
        authMethods = (result["authMethods"]?.arrayValue ?? []).compactMap { $0["id"]?.acpText }
    }
}

/// One choice of a select config option (`model`, `thought_level`, `mode`, ...).
struct ACPConfigChoice: Equatable, Sendable {
    var value: String
    var name: String
    var description: String?
}

/// A session config option (`configOptions` in `session/new`, `config_option_update`).
struct ACPConfigOption: Equatable, Sendable {
    var id: String
    var name: String
    /// `mode`, `model`, `model_config`, `speed`, `thought_level` or an agent's own word.
    var category: String?
    /// `select` or `boolean`.
    var type: String
    var currentValue: String?
    var currentBool: Bool?
    var choices: [ACPConfigChoice]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.acpText else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        category = json["category"]?.acpText
        type = json["type"]?.stringValue ?? "select"
        currentValue = json["currentValue"]?.stringValue
        currentBool = json["currentValue"]?.acpBool
        var flat: [ACPConfigChoice] = []
        for entry in json["options"]?.arrayValue ?? [] {
            if let value = entry["value"]?.stringValue {
                flat.append(ACPConfigChoice(value: value, name: entry["name"]?.stringValue ?? value, description: entry["description"]?.acpText))
            } else if let group = entry["options"]?.arrayValue {
                // Grouped select options.
                for inner in group {
                    guard let value = inner["value"]?.stringValue else { continue }
                    flat.append(ACPConfigChoice(value: value, name: inner["name"]?.stringValue ?? value, description: inner["description"]?.acpText))
                }
            }
        }
        choices = flat
    }

    static func list(_ json: JSONValue?) -> [ACPConfigOption]? {
        guard let array = json?.arrayValue else { return nil }
        return array.compactMap(ACPConfigOption.init)
    }
}

/// A permission mode the agent offers (`modes.availableModes`).
struct ACPMode: Equatable, Sendable {
    var id: String
    var name: String
}

/// What `session/new`, `session/load` and `session/resume` answer: the session id (new only), modes, models and
/// config options. Antigravity also sends `models` (the older unstable SessionModelState, removed from the schema);
/// it is kept as a fallback for agents without a `model` config option.
struct ACPSessionSetup: Equatable, Sendable {
    var sessionID: String?
    var currentModeID: String?
    var modes: [ACPMode]
    var currentModelID: String?
    var models: [ACPConfigChoice]
    var configOptions: [ACPConfigOption]?

    init(result: JSONValue) {
        sessionID = result["sessionId"]?.acpText
        currentModeID = result["modes"]?["currentModeId"]?.acpText
        modes = (result["modes"]?["availableModes"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["id"]?.acpText else { return nil }
            return ACPMode(id: id, name: entry["name"]?.stringValue ?? id)
        }
        currentModelID = result["models"]?["currentModelId"]?.acpText
        models = (result["models"]?["availableModels"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["modelId"]?.acpText else { return nil }
            return ACPConfigChoice(value: id, name: entry["name"]?.stringValue ?? id, description: entry["description"]?.acpText)
        }
        configOptions = ACPConfigOption.list(result["configOptions"])
    }
}

/// Where a tool call works.
struct ACPLocation: Equatable, Sendable {
    var path: String
    var line: Int?
}

/// One piece of a tool call's content.
enum ACPToolContent: Equatable, Sendable {
    case text(String)
    /// A file change. `oldText` nil means a new file. Antigravity's `edit_file` sends only the replaced fragment here,
    /// not the whole file.
    case diff(path: String, oldText: String?, newText: String)
    case terminal(id: String)
    case other

    init(_ json: JSONValue) {
        switch json["type"]?.stringValue {
        case "content":
            self = ACPContentBlock.text(of: json["content"]).map(ACPToolContent.text) ?? .other
        case "diff":
            self = .diff(path: json["path"]?.stringValue ?? "", oldText: json["oldText"]?.stringValue, newText: json["newText"]?.stringValue ?? "")
        case "terminal":
            self = .terminal(id: json["terminalId"]?.stringValue ?? "")
        default:
            self = .other
        }
    }
}

/// A `tool_call` or `tool_call_update`. In an update every field but the id is optional and only present fields
/// change. Antigravity adds a non-standard `args` copy of `rawInput`, which is ignored.
struct ACPToolCallUpdate: Equatable, Sendable {
    var id: String
    var title: String?
    /// The agent's own tool name (`write_file`, `run_command`, `shell`, ...). In the unstable schema.
    var name: String?
    /// read, edit, delete, move, search, execute, think, fetch, switch_mode, other.
    var kind: String?
    /// pending, in_progress, completed, failed.
    var status: String?
    var content: [ACPToolContent]?
    var locations: [ACPLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?

    init?(_ json: JSONValue) {
        guard let id = json["toolCallId"]?.acpText else { return nil }
        self.id = id
        title = json["title"]?.stringValue
        name = json["name"]?.acpText
        kind = json["kind"]?.acpText
        status = json["status"]?.acpText
        content = json["content"]?.arrayValue?.map(ACPToolContent.init)
        locations = json["locations"]?.arrayValue?.compactMap { entry in
            guard let path = entry["path"]?.acpText else { return nil }
            return ACPLocation(path: path, line: entry["line"]?.acpInt)
        }
        if let raw = json["rawInput"], raw != .null { rawInput = raw }
        if let raw = json["rawOutput"], raw != .null { rawOutput = raw }
    }
}

/// A plan entry (`plan` session update).
struct ACPPlanEntry: Equatable, Sendable {
    var content: String
    /// high, medium, low.
    var priority: String
    /// pending, in_progress, completed.
    var status: String
}

/// A slash command the agent offers.
struct ACPCommand: Equatable, Sendable {
    var name: String
    var description: String
    var hint: String?
}

/// Token use for one turn (`usage` in the `session/prompt` answer, unstable schema).
struct ACPTurnUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var thoughtTokens: Int
    var cachedReadTokens: Int
    var cachedWriteTokens: Int

    init?(_ json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        inputTokens = json["inputTokens"]?.acpInt ?? 0
        outputTokens = json["outputTokens"]?.acpInt ?? 0
        thoughtTokens = json["thoughtTokens"]?.acpInt ?? 0
        cachedReadTokens = json["cachedReadTokens"]?.acpInt ?? 0
        cachedWriteTokens = json["cachedWriteTokens"]?.acpInt ?? 0
    }

    var usage: Usage {
        Usage(inputTokens: inputTokens, outputTokens: outputTokens, reasoningTokens: thoughtTokens,
              cacheReadTokens: cachedReadTokens, cacheWriteTokens: cachedWriteTokens)
    }
}

/// A `session/update` notification's payload.
enum ACPSessionUpdate: Equatable, Sendable {
    case userMessage(text: String, messageID: String?)
    case agentMessage(text: String, messageID: String?)
    case agentThought(text: String, messageID: String?)
    case toolCall(ACPToolCallUpdate)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableCommands([ACPCommand])
    case currentMode(String)
    case configOptions([ACPConfigOption])
    case sessionInfo(title: String?)
    /// Context window use: tokens in the context and the window size; `costUSD` is the session's cumulative cost when
    /// the agent reports one in US dollars.
    case usage(used: Int, size: Int, costUSD: Double?)
    case other(kind: String)

    init?(_ update: JSONValue) {
        guard let kind = update["sessionUpdate"]?.stringValue else { return nil }
        switch kind {
        case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
            // Non-text chunks (images, resources) are shown as a short placeholder.
            let text = ACPContentBlock.text(of: update["content"]) ?? ACPContentBlock.placeholder(of: update["content"])
            let messageID = update["messageId"]?.acpText
            switch kind {
            case "user_message_chunk": self = .userMessage(text: text, messageID: messageID)
            case "agent_message_chunk": self = .agentMessage(text: text, messageID: messageID)
            default: self = .agentThought(text: text, messageID: messageID)
            }
        case "tool_call":
            guard let call = ACPToolCallUpdate(update) else { return nil }
            self = .toolCall(call)
        case "tool_call_update":
            guard let call = ACPToolCallUpdate(update) else { return nil }
            self = .toolCallUpdate(call)
        case "plan":
            self = .plan((update["entries"]?.arrayValue ?? []).compactMap { entry in
                guard let content = entry["content"]?.acpText else { return nil }
                return ACPPlanEntry(content: content, priority: entry["priority"]?.stringValue ?? "medium",
                                    status: entry["status"]?.stringValue ?? "pending")
            })
        case "available_commands_update":
            self = .availableCommands((update["availableCommands"]?.arrayValue ?? []).compactMap { entry in
                guard let name = entry["name"]?.acpText else { return nil }
                return ACPCommand(name: name, description: entry["description"]?.stringValue ?? "", hint: entry["input"]?["hint"]?.acpText)
            })
        case "current_mode_update":
            guard let mode = update["currentModeId"]?.acpText else { return nil }
            self = .currentMode(mode)
        case "config_option_update":
            self = .configOptions(ACPConfigOption.list(update["configOptions"]) ?? [])
        case "session_info_update":
            self = .sessionInfo(title: update["title"]?.stringValue)
        case "usage_update":
            var cost: Double?
            if let amount = update["cost"]?["amount"]?.doubleValue, (update["cost"]?["currency"]?.stringValue ?? "USD").uppercased() == "USD" {
                cost = amount
            }
            self = .usage(used: update["used"]?.acpInt ?? 0, size: update["size"]?.acpInt ?? 0, costUSD: cost)
        default:
            self = .other(kind: kind)
        }
    }
}

/// A `session/request_permission` request from the agent.
struct ACPPermissionAsk: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        var id: String
        var name: String
        /// allow_once, allow_always, reject_once, reject_always.
        var kind: String
    }

    var agentSessionID: String
    var toolCall: ACPToolCallUpdate?
    var options: [Option]

    init?(params: JSONValue) {
        guard let session = params["sessionId"]?.acpText else { return nil }
        agentSessionID = session
        toolCall = params["toolCall"].flatMap(ACPToolCallUpdate.init)
        options = (params["options"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["optionId"]?.acpText else { return nil }
            return Option(id: id, name: entry["name"]?.stringValue ?? id, kind: entry["kind"]?.stringValue ?? "")
        }
    }

    /// The option that answers `decision`. "Once" never picks an "always" option unless the agent offers nothing else
    /// that allows; "reject" prefers the one-time rejection. The engine never sends the agent's "always" option itself
    /// (it answers "always" with `.once` and remembers its own rule).
    func option(for decision: PermissionDecision) -> Option? {
        func first(_ kinds: [String]) -> Option? {
            for kind in kinds { if let match = options.first(where: { $0.kind == kind }) { return match } }
            return nil
        }
        switch decision {
        case .once: return first(["allow_once", "allow_always"])
        case .always: return first(["allow_always", "allow_once"])
        case .reject: return first(["reject_once", "reject_always"])
        }
    }

    var offersAlways: Bool { options.contains { $0.kind == "allow_always" } }

    /// The JSON-RPC result that answers the request.
    static func outcome(optionID: String?) -> JSONValue {
        guard let optionID else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]
    }
}

/// How a turn ended (`stopReason`).
enum ACPStopReason: Equatable, Sendable {
    case endTurn, maxTokens, maxTurnRequests, refusal, cancelled
    case other(String)

    init(_ raw: String?) {
        switch raw {
        case "end_turn", nil: self = .endTurn
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        case "cancelled": self = .cancelled
        case let other?: self = .other(other)
        }
    }

    /// Ensemble's outcome word (the same OpenCode and the Claude engine use) and an error for the transcript.
    var outcome: (outcome: String, error: String?) {
        switch self {
        case .endTurn: ("succeeded", nil)
        case .cancelled: ("interrupted", nil)
        case .maxTokens: ("failed", "The agent stopped: it reached its output limit.")
        case .maxTurnRequests: ("failed", "The agent stopped: it reached its limit of steps for one message.")
        case .refusal: ("failed", "The model refused to continue.")
        case .other(let raw): ("failed", "The agent stopped (\(raw)).")
        }
    }
}

/// ACP content blocks (prompt input and message chunks).
enum ACPContentBlock {
    static func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }

    static func image(data: Data, mimeType: String, uri: String?) -> JSONValue {
        var block: [String: JSONValue] = ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        if let uri { block["uri"] = .string(uri) }
        return .object(block)
    }

    /// A link to a local file the agent reads with its own tools. Every ACP agent must accept `resource_link`.
    static func resourceLink(_ url: URL) -> JSONValue {
        ["type": "resource_link", "uri": .string(url.absoluteString), "name": .string(url.lastPathComponent)]
    }

    /// The text of a text block, or the text of an embedded text resource.
    static func text(of block: JSONValue?) -> String? {
        guard let block else { return nil }
        switch block["type"]?.stringValue {
        case "text": return block["text"]?.stringValue
        case "resource": return block["resource"]?["text"]?.stringValue
        default: return nil
        }
    }

    static func placeholder(of block: JSONValue?) -> String {
        switch block?["type"]?.stringValue {
        case "image": "[image]"
        case "audio": "[audio]"
        case "resource_link": block?["name"]?.stringValue.map { "[\($0)]" } ?? "[file]"
        case "resource": "[file]"
        default: ""
        }
    }
}
