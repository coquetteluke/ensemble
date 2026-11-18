import Foundation

/// Facts from the CLI's `system/init` line (sent at the start of every turn).
struct ClaudeInitInfo: Equatable, Sendable {
    var cliSessionID: String?
    var model: String?
    var permissionMode: String?
    var cwd: String?
    var version: String?
    var connectors: [ConnectorInfo]
    var skills: [String] = []
    /// Commands that only work in the terminal.
    var terminalCommands: [String] = []
}

/// How a turn ended, from the CLI's `result` line.
struct ClaudeTurnSummary: Equatable, Sendable {
    /// `succeeded`, `failed` or `interrupted` (the same words OpenCode uses).
    var outcome: String
    var error: String?
    /// Prompts still waiting in the CLI's queue after this turn.
    var queuedTurns: Int
    var terminalReason: String?
}

/// Turns `claude -p --output-format stream-json --verbose --include-partial-messages` lines into Ensemble events.
///
/// One decoder per root session (one CLI process). Lines from subagents carry `parent_tool_use_id`; they are routed to
/// the subagent's synthetic session id (`ClaudeSessionIDs.child`). Text and thinking rows use the API message id plus
/// the content block index, so live rows and rows rebuilt from the transcript file share ids.
struct ClaudeStreamDecoder {
    enum Output: Equatable, Sendable {
        case event(EngineEvent)
        /// The agent asks to run a tool. The engine either answers it from an "always" rule or shows it.
        case permission(ClaudePermissionPrompt)
        /// The CLI asks something Ensemble does not handle; the engine answers with an error so it never waits.
        case unsupportedControl(requestID: String, subtype: String)
        case controlResponse(requestID: String, success: Bool, payload: JSONValue)
        /// The CLI withdrew a permission prompt (for example after an interrupt).
        case controlCancel(requestID: String)
        case initialized(ClaudeInitInfo)
        case turnEnded(ClaudeTurnSummary)
        case rateLimit(ClaudePlanLimits)
    }

    private enum BlockKind: Equatable {
        case text
        case thinking
        case tool(id: String)
        case other
    }

    private struct Block {
        var kind: BlockKind
        var text = ""
    }

    private struct StreamState {
        var messageID: String?
        var blocks: [Int: Block] = [:]
    }

    private struct Tool {
        var name: String
        var sessionID: String
        var input: JSONValue?
        var inputBuffer = ""
        var childSessionID: String?
        var finished = false
    }

    let rootID: String
    var directory: String
    /// Cumulative usage of the session (seeded from the saved record).
    var usage: Usage
    /// Tokens in the context after the newest model call (input + cache + output).
    var lastContextTokens: Int?
    /// Context windows the CLI reported, by model id.
    var contextWindows: [String: Int] = [:]
    /// Set by the engine right before it sends an interrupt, so the turn ends as `interrupted`.
    var interruptRequested = false
    /// False for agents on the user's Claude plan: the CLI's dollar figure is what the same tokens would cost on the
    /// API, not money the user pays, so it is dropped (tokens are kept; plan limits come from `rate_limit_event`).
    var reportsCost = true

    private var streams: [String: StreamState] = [:]
    private var assistantCounters: [String: Int] = [:]
    private var tools: [String: Tool] = [:]
    private var endedItems: Set<String> = []
    private var streamedItems: Set<String> = []
    private(set) var children: [String: EngineSession] = [:]
    private var lastProcessCost: Double = 0

    init(rootID: String, directory: String, usage: Usage = .zero) {
        self.rootID = rootID
        self.directory = directory
        self.usage = usage
    }

    /// Ids of tool calls that started and have no result yet.
    var openToolIDs: [String] { tools.filter { !$0.value.finished }.map(\.key) }

    mutating func decode(line: String) -> [Output] {
        guard let json = JSONValue.parse(line: line), let type = json["type"]?.stringValue else { return [] }
        return decode(json, type: type)
    }

    private func sessionID(for json: JSONValue) -> String {
        if let parent = json["parent_tool_use_id"]?.stringValue, !parent.isEmpty {
            return ClaudeSessionIDs.child(root: rootID, toolUseID: parent)
        }
        return rootID
    }

    mutating func decode(_ json: JSONValue, type: String) -> [Output] {
        switch type {
        case "system": return system(json)
        case "stream_event": return streamEvent(json)
        case "assistant": return assistant(json)
        case "user": return user(json)
        case "result": return result(json)
        case "rate_limit_event": return rateLimit(json)
        case "control_request": return controlRequest(json)
        case "control_response":
            guard let response = json["response"], let id = response["request_id"]?.stringValue else { return [] }
            if response["subtype"]?.stringValue == "success" {
                return [.controlResponse(requestID: id, success: true, payload: response["response"] ?? .object([:]))]
            }
            return [.controlResponse(requestID: id, success: false, payload: .string(response["error"]?.stringValue ?? "error"))]
        case "control_cancel_request":
            guard let id = json["request_id"]?.stringValue else { return [] }
            return [.controlCancel(requestID: id)]
        default:
            return []
        }
    }

    // MARK: system

    private mutating func system(_ json: JSONValue) -> [Output] {
        switch json["subtype"]?.stringValue {
        case "init":
            let connectors = (json["mcp_servers"]?.arrayValue ?? []).compactMap { server -> ConnectorInfo? in
                guard let name = server["name"]?.stringValue else { return nil }
                let state: ConnectorInfo.State
                switch server["status"]?.stringValue {
                case "connected": state = .connected
                case "needs-auth", "needs_auth": state = .needsAuth
                case "failed": state = .failed
                case "disabled": state = .disabled
                default: state = .connecting
                }
                let tools = (json["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
                let prefix = "mcp__" + name.replacingOccurrences(of: " ", with: "_") + "__"
                return ConnectorInfo(id: name, name: name, state: state, toolCount: tools.filter { $0.hasPrefix(prefix) }.count)
            }
            if let cwd = json["cwd"]?.stringValue, !cwd.isEmpty, directory.isEmpty { directory = cwd }
            let info = ClaudeInitInfo(cliSessionID: json["session_id"]?.stringValue, model: json["model"]?.stringValue,
                                      permissionMode: json["permissionMode"]?.stringValue, cwd: json["cwd"]?.stringValue,
                                      version: json["claude_code_version"]?.stringValue, connectors: connectors,
                                      skills: (json["skills"]?.arrayValue ?? []).compactMap(\.stringValue),
                                      terminalCommands: (json["terminal_slash_commands"]?.arrayValue ?? []).compactMap(\.stringValue))
            return [.initialized(info), .event(.activity(sessionID: rootID, .working))]

        case "task_started":
            guard let toolID = json["tool_use_id"]?.stringValue else { return [] }
            let childID = ClaudeSessionIDs.child(root: rootID, toolUseID: toolID)
            var out: [Output] = []
            if children[childID] == nil {
                let parent = tools[toolID]?.sessionID ?? rootID
                let session = EngineSession(id: childID, parentID: parent, title: json["description"]?.stringValue ?? "Subagent",
                                            directory: directory, agent: json["subagent_type"]?.stringValue)
                children[childID] = session
                out.append(.event(.sessionCreated(session)))
            }
            out.append(.event(.activity(sessionID: childID, .working)))
            return out

        case "task_notification":
            guard let toolID = json["tool_use_id"]?.stringValue else { return [] }
            let childID = ClaudeSessionIDs.child(root: rootID, toolUseID: toolID)
            let status = json["status"]?.stringValue ?? "completed"
            let outcome: String
            switch status {
            case "completed": outcome = "succeeded"
            case "failed", "error": outcome = "failed"
            default: outcome = "interrupted"
            }
            let error = outcome == "failed" ? (json["summary"]?.stringValue ?? "The subagent failed") : nil
            return [.event(.executionEnded(sessionID: childID, outcome: outcome, error: error)),
                    .event(.activity(sessionID: childID, outcome == "failed" ? .failed : .idle))]

        case "compact_boundary":
            return [.event(.other(type: "claude.compacted"))]

        default:
            return []
        }
    }

    // MARK: streaming deltas

    private mutating func streamEvent(_ json: JSONValue) -> [Output] {
        guard let event = json["event"], let kind = event["type"]?.stringValue else { return [] }
        let session = sessionID(for: json)
        var state = streams[session] ?? StreamState()
        defer { streams[session] = state }

        switch kind {
        case "message_start":
            state.messageID = event["message"]?["id"]?.stringValue ?? json["api_message_id"]?.stringValue
            state.blocks = [:]
            return []

        case "content_block_start":
            guard let index = event["index"]?.intValue, let block = event["content_block"] else { return [] }
            switch block["type"]?.stringValue {
            case "text":
                state.blocks[index] = Block(kind: .text)
            case "thinking":
                state.blocks[index] = Block(kind: .thinking)
            case "tool_use", "server_tool_use":
                guard let id = block["id"]?.stringValue else { return [] }
                let name = block["name"]?.stringValue ?? "tool"
                state.blocks[index] = Block(kind: .tool(id: id))
                if tools[id] == nil { tools[id] = Tool(name: name, sessionID: session) }
                var info = ToolCallInfo(id: id, name: name, title: name, status: .pending)
                if ClaudeFormatting.agentToolNames.contains(name) {
                    info.childSessionID = ClaudeSessionIDs.child(root: rootID, toolUseID: id)
                    tools[id]?.childSessionID = info.childSessionID
                }
                return [.event(.toolUpdated(sessionID: session, info))]
            default:
                state.blocks[index] = Block(kind: .other)
            }
            return []

        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"] else { return [] }
            let messageID = state.messageID ?? json["api_message_id"]?.stringValue ?? "message"
            let itemID = ClaudeSessionIDs.block(messageID: messageID, index: index)
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
                state.blocks[index, default: Block(kind: .text)].text += text
                streamedItems.insert(itemID)
                return [.event(.textDelta(sessionID: session, itemID: itemID, delta: text))]
            case "thinking_delta":
                guard let text = delta["thinking"]?.stringValue, !text.isEmpty else { return [] }
                state.blocks[index, default: Block(kind: .thinking)].text += text
                streamedItems.insert(itemID)
                return [.event(.reasoningDelta(sessionID: session, itemID: itemID, delta: text))]
            case "input_json_delta":
                if case .tool(let id)? = state.blocks[index]?.kind, let part = delta["partial_json"]?.stringValue {
                    tools[id]?.inputBuffer += part
                }
                return []
            default:
                return []
            }

        case "content_block_stop":
            guard let index = event["index"]?.intValue, let block = state.blocks[index] else { return [] }
            let messageID = state.messageID ?? json["api_message_id"]?.stringValue ?? "message"
            let itemID = ClaudeSessionIDs.block(messageID: messageID, index: index)
            switch block.kind {
            case .text:
                guard !endedItems.contains(itemID), !block.text.isEmpty else { return [] }
                endedItems.insert(itemID)
                return [.event(.textEnded(sessionID: session, itemID: itemID, text: block.text))]
            case .tool(let id):
                guard var tool = tools[id], tool.input == nil, !tool.inputBuffer.isEmpty,
                      let input = JSONValue.parse(line: tool.inputBuffer) else { return [] }
                tool.input = input
                tools[id] = tool
                return [.event(.toolUpdated(sessionID: session, card(id: id, status: .running)))]
            default:
                return []
            }

        default:
            return []
        }
    }

    // MARK: complete messages

    private mutating func assistant(_ json: JSONValue) -> [Output] {
        guard let message = json["message"], let content = message["content"]?.arrayValue else { return [] }
        let session = sessionID(for: json)
        let messageID = message["id"]?.stringValue ?? json["uuid"]?.stringValue ?? UUID().uuidString
        let base = assistantCounters[messageID] ?? 0
        assistantCounters[messageID] = base + content.count
        var out: [Output] = []
        for (offset, block) in content.enumerated() {
            let itemID = ClaudeSessionIDs.block(messageID: messageID, index: base + offset)
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.isEmpty, !endedItems.contains(itemID) else { continue }
                endedItems.insert(itemID)
                out.append(.event(.textEnded(sessionID: session, itemID: itemID, text: text)))
            case "thinking":
                guard let text = block["thinking"]?.stringValue, !text.isEmpty, !streamedItems.contains(itemID) else { continue }
                streamedItems.insert(itemID)
                out.append(.event(.reasoningDelta(sessionID: session, itemID: itemID, delta: text)))
            case "tool_use", "server_tool_use":
                guard let id = block["id"]?.stringValue else { continue }
                let name = block["name"]?.stringValue ?? tools[id]?.name ?? "tool"
                var tool = tools[id] ?? Tool(name: name, sessionID: session)
                tool.name = name
                tool.input = block["input"] ?? tool.input
                if ClaudeFormatting.agentToolNames.contains(name) {
                    let childID = ClaudeSessionIDs.child(root: rootID, toolUseID: id)
                    tool.childSessionID = childID
                    if children[childID] == nil {
                        let child = EngineSession(id: childID, parentID: session,
                                                  title: tool.input?["description"]?.stringValue ?? "Subagent",
                                                  directory: directory, agent: tool.input?["subagent_type"]?.stringValue)
                        children[childID] = child
                        out.append(.event(.sessionCreated(child)))
                    }
                }
                tools[id] = tool
                if !tool.finished { out.append(.event(.toolUpdated(sessionID: session, card(id: id, status: .running)))) }
            case "web_search_tool_result":
                guard let id = block["tool_use_id"]?.stringValue else { continue }
                tools[id]?.finished = true
                var info = card(id: id, status: .succeeded)
                info.outputPreview = "Search results received"
                out.append(.event(.toolUpdated(sessionID: session, info)))
            default:
                continue
            }
        }
        return out
    }

    private mutating func user(_ json: JSONValue) -> [Output] {
        guard let content = json["message"]?["content"]?.arrayValue else { return [] }
        var out: [Output] = []
        for block in content where block["type"]?.stringValue == "tool_result" {
            guard let id = block["tool_use_id"]?.stringValue else { continue }
            let isError = block["is_error"]?.boolValue ?? false
            var tool = tools[id] ?? Tool(name: "tool", sessionID: sessionID(for: json))
            tool.finished = true
            tools[id] = tool
            var info = card(id: id, status: isError ? .failed : .succeeded)
            let text = ClaudeFormatting.resultText(block["content"])
            info.outputPreview = text.isEmpty ? nil : ClaudeFormatting.trimmed(text)
            if !isError, case .object? = json["tool_use_result"] {
                info.diff = ClaudeFormatting.diff(toolName: tool.name, input: tool.input, result: json["tool_use_result"], directory: directory)
            }
            out.append(.event(.toolUpdated(sessionID: tool.sessionID, info)))
        }
        return out
    }

    private func card(id: String, status: ToolStatus) -> ToolCallInfo {
        let tool = tools[id]
        let name = tool?.name ?? "tool"
        return ToolCallInfo(id: id, name: name, title: ClaudeFormatting.title(name: name, input: tool?.input, directory: directory),
                            inputJSON: ClaudeFormatting.inputJSON(tool?.input), status: status, childSessionID: tool?.childSessionID)
    }

    // MARK: end of turn

    private mutating func result(_ json: JSONValue) -> [Output] {
        var turn = Usage.zero
        if let perModel = json["model_usage_since_last_result"]?.objectValue {
            for (_, entry) in perModel { turn = turn + Self.usage(modelEntry: entry) }
        } else {
            // Older CLIs: `usage` is this turn, `total_cost_usd` is the whole process so far.
            let u = json["usage"]
            let total = json["total_cost_usd"]?.doubleValue ?? 0
            turn = Usage(inputTokens: u?["input_tokens"]?.intValue ?? 0, outputTokens: u?["output_tokens"]?.intValue ?? 0,
                         reasoningTokens: u?["output_tokens_details"]?["thinking_tokens"]?.intValue ?? 0,
                         cacheReadTokens: u?["cache_read_input_tokens"]?.intValue ?? 0,
                         cacheWriteTokens: u?["cache_creation_input_tokens"]?.intValue ?? 0,
                         costUSD: max(0, total - lastProcessCost))
            lastProcessCost = max(lastProcessCost, total)
        }
        for (model, entry) in json["modelUsage"]?.objectValue ?? [:] {
            if let window = entry["contextWindow"]?.intValue, window > 0 {
                contextWindows[model] = window
                if let canonical = entry["canonicalModel"]?.stringValue { contextWindows[canonical] = window }
            }
        }
        if let last = json["usage"]?["iterations"]?.arrayValue?.last {
            let tokens = (last["input_tokens"]?.intValue ?? 0) + (last["cache_read_input_tokens"]?.intValue ?? 0)
                + (last["cache_creation_input_tokens"]?.intValue ?? 0) + (last["output_tokens"]?.intValue ?? 0)
            if tokens > 0 { lastContextTokens = tokens }
        }

        let isError = json["is_error"]?.boolValue ?? (json["subtype"]?.stringValue != "success")
        let terminal = json["terminal_reason"]?.stringValue
        let outcome: String
        if !isError {
            outcome = "succeeded"
        } else if interruptRequested || (terminal?.contains("abort") ?? false) {
            outcome = "interrupted"
        } else {
            outcome = "failed"
        }
        interruptRequested = false
        var error: String?
        if outcome == "failed" {
            let text = json["result"]?.stringValue
            let errors = (json["errors"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.hasPrefix("[ede_diagnostic]") }
            error = Self.friendlyError(text?.isEmpty == false ? text! : (errors.first ?? json["api_error_status"]?.stringValue ?? "The turn failed"))
        }
        let queued = json["queued_turn_count"]?.intValue ?? 0
        if !reportsCost { turn.costUSD = 0 }
        var out: [Output] = []
        if turn != .zero {
            usage = usage + turn
            out.append(.event(.usageUpdated(sessionID: rootID, usage)))
        }
        out.append(.event(.executionEnded(sessionID: rootID, outcome: outcome, error: error)))
        out.append(.event(.activity(sessionID: rootID, outcome == "failed" ? .failed : .idle)))
        if queued > 0 { out.append(.event(.activity(sessionID: rootID, .working))) }
        out.append(.turnEnded(ClaudeTurnSummary(outcome: outcome, error: error, queuedTurns: queued, terminalReason: terminal)))
        return out
    }

    static func usage(modelEntry entry: JSONValue) -> Usage {
        Usage(inputTokens: entry["inputTokens"]?.intValue ?? 0, outputTokens: entry["outputTokens"]?.intValue ?? 0,
              reasoningTokens: entry["thinkingTokens"]?.intValue ?? 0, cacheReadTokens: entry["cacheReadInputTokens"]?.intValue ?? 0,
              cacheWriteTokens: entry["cacheCreationInputTokens"]?.intValue ?? 0, costUSD: entry["costUSD"]?.doubleValue ?? 0)
    }

    /// Plain wording for errors the user can act on.
    static func friendlyError(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || (lower.contains("oauth") && lower.contains("expired")) {
            return "Claude Code is not signed in. Run `claude auth login` in Terminal. (\(text))"
        }
        if lower.contains("usage limit") || (lower.contains("rate limit") && lower.contains("plan")) {
            return "Your Claude plan's usage limit is reached. (\(text))"
        }
        if lower.contains("credit balance is too low") {
            return "The Anthropic API key has no credit left. (\(text))"
        }
        if lower.contains("invalid api key") || lower.contains("invalid x-api-key") {
            return "The Anthropic API key was rejected. (\(text))"
        }
        return text
    }

    // MARK: plan limits

    private func rateLimit(_ json: JSONValue) -> [Output] {
        guard let info = json["rate_limit_info"] else { return [] }
        func date(_ value: JSONValue?) -> Date? { value?.doubleValue.map { Date(timeIntervalSince1970: $0) } }
        var windows: [ClaudePlanLimits.Window] = []
        for (name, window) in (info["unifiedWindows"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            windows.append(.init(name: name, utilization: window["utilization"]?.doubleValue ?? 0,
                                 resetsAt: date(window["resetsAt"]), status: window["status"]?.stringValue))
        }
        let limits = ClaudePlanLimits(status: info["status"]?.stringValue ?? "allowed", limitType: info["rateLimitType"]?.stringValue,
                                      utilization: info["utilization"]?.doubleValue, resetsAt: date(info["resetsAt"]), windows: windows)
        return [.rateLimit(limits), .event(.other(type: "claude.rate_limit"))]
    }

    // MARK: control

    private func controlRequest(_ json: JSONValue) -> [Output] {
        guard let id = json["request_id"]?.stringValue, let request = json["request"] else { return [] }
        let subtype = request["subtype"]?.stringValue ?? ""
        guard subtype == "can_use_tool" else { return [.unsupportedControl(requestID: id, subtype: subtype)] }
        return [.permission(ClaudePermissionPrompt(requestID: id, sessionID: rootID, body: request, directory: directory))]
    }
}
