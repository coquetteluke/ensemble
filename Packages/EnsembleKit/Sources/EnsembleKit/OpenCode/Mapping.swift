import Foundation

/// Stable ids for transcript rows built from engine messages. Streaming events use the same ids,
/// so a row fetched with `transcript(_:)` and a live `textDelta` for it line up.
///
/// OpenCode numbers text and reasoning blocks per kind inside one assistant message
/// (`ordinal` in `session.text.*` and `session.reasoning.*` events).
public enum TranscriptIDs {
    public static func text(messageID: String, ordinal: Int) -> String { "\(messageID):text:\(ordinal)" }
    public static func reasoning(messageID: String, ordinal: Int) -> String { "\(messageID):reasoning:\(ordinal)" }
    public static func error(messageID: String) -> String { "\(messageID):error" }
}

extension ModelRef {
    init(wire: Wire.ModelRef) {
        // The engine reports the implicit variant as "default"; Ensemble treats that as no variant.
        let variant = (wire.variant == nil || wire.variant == "default") ? nil : wire.variant
        self.init(providerID: wire.providerID, id: wire.id, variant: variant)
    }

    var wire: [String: String] {
        var body = ["providerID": providerID, "id": id]
        if let variant { body["variant"] = variant }
        return body
    }
}

extension Usage {
    init(tokens: Wire.Tokens?, cost: Double?) {
        self.init(inputTokens: Int(tokens?.input ?? 0), outputTokens: Int(tokens?.output ?? 0),
                  reasoningTokens: Int(tokens?.reasoning ?? 0), cacheReadTokens: Int(tokens?.cache.read ?? 0),
                  cacheWriteTokens: Int(tokens?.cache.write ?? 0), costUSD: cost ?? 0)
    }
}

extension EngineSession {
    init(wire: Wire.Session) {
        self.init(id: wire.id, parentID: wire.parentID, title: wire.title ?? "", directory: wire.location?.directory ?? "",
                  model: wire.model.map(ModelRef.init(wire:)), agent: wire.agent, usage: Usage(tokens: wire.tokens, cost: wire.cost),
                  created: Wire.date(wire.time.created), updated: Wire.date(wire.time.updated), archived: wire.time.archived != nil)
    }
}

extension PermissionRequest {
    init(wire: Wire.PermissionRequest, created: Date = Date()) {
        let title = wire.resources.isEmpty ? wire.action : wire.resources.joined(separator: "\n")
        var detail: [String] = []
        if let message = wire.message, !message.isEmpty { detail.append(message) }
        let save = (wire.save ?? []).filter { !$0.isEmpty }
        self.init(id: wire.id, sessionID: wire.sessionID, kind: wire.action, title: title,
                  detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                  alwaysPatterns: save.isEmpty ? nil : save, created: created)
    }
}

// MARK: Tool cards

enum ToolCards {
    static let previewLimit = 4000

    static func status(_ engineStatus: String) -> ToolStatus {
        switch engineStatus {
        case "streaming": .pending
        case "running": .running
        case "completed": .succeeded
        case "error": .failed
        default: .running
        }
    }

    /// Short card title from the tool input: the command, path, pattern, URL or task label.
    static func title(name: String, input: JSONValue?) -> String {
        guard let input, case .object(let object) = input else { return name }
        func string(_ key: String) -> String? {
            guard let value = object[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        let candidates: [String]
        switch name {
        case "shell", "bash": candidates = ["command"]
        case "edit", "write", "read", "patch": candidates = ["path", "filePath"]
        case "glob", "grep": candidates = ["pattern", "query"]
        case "webfetch": candidates = ["url"]
        case "websearch": candidates = ["query"]
        case "subagent", "task": candidates = ["description", "prompt"]
        case "skill": candidates = ["id", "name"]
        case "question":
            if let first = object["questions"]?.arrayValue?.first?["question"]?.stringValue { return first }
            candidates = []
        case "execute": return "Run code"
        default: candidates = ["description", "command", "path", "url", "query", "pattern"]
        }
        for key in candidates {
            if let value = string(key) { return value }
        }
        return name
    }

    static func outputPreview(content: [Wire.ToolContent]?, error: Wire.StructuredError?) -> String? {
        var pieces: [String] = []
        if let error { pieces.append(error.message) }
        for item in content ?? [] {
            if item.type == "text", let text = item.text { pieces.append(text) }
            else if item.type == "file" { pieces.append("[file: \(item.name ?? item.uri ?? "attachment")]") }
        }
        let joined = pieces.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return trimmed(joined)
    }

    static func trimmed(_ text: String) -> String {
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit)) + "\n..."
    }

    /// Edits report their patch in `metadata.files[].patch`.
    static func diff(metadata: JSONValue?) -> String? {
        guard let files = metadata?["files"]?.arrayValue else { return nil }
        let patches = files.compactMap { $0["patch"]?.stringValue }.filter { !$0.isEmpty }
        return patches.isEmpty ? nil : patches.joined(separator: "\n")
    }

    /// Subagent calls report the child session in `metadata.sessionID`.
    static func childSessionID(metadata: JSONValue?) -> String? {
        guard let id = metadata?["sessionID"]?.stringValue, id.hasPrefix("ses") else { return nil }
        return id
    }

    static func inputJSON(_ input: JSONValue?) -> String {
        guard let input else { return "{}" }
        if case .string(let raw) = input { return raw.isEmpty ? "{}" : raw }
        return input.prettyJSONText
    }

    static func make(id: String, name: String, state: Wire.ToolState) -> ToolCallInfo {
        var input = state.input
        if case .string(let raw)? = input, let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
            input = parsed
        }
        return ToolCallInfo(id: id, name: name, title: title(name: name, input: input), inputJSON: inputJSON(state.input),
                            status: status(state.status), outputPreview: outputPreview(content: state.content, error: state.error),
                            diff: diff(metadata: state.metadata), childSessionID: childSessionID(metadata: state.metadata))
    }
}

// MARK: Transcript

enum TranscriptMapper {
    static func items(from messages: [Wire.Message]) -> [TranscriptItem] {
        messages.flatMap { items(from: $0) }
    }

    /// The transcript with each user message's files beside it instead of as "Attached: name" lines. `savePicture`
    /// turns a picture's stored bytes (base64 text, media type) into a file and returns its path.
    static func attached(from messages: [Wire.Message], savePicture: ((String, String?) -> String?)? = nil) -> AttachedTranscript {
        var result = AttachedTranscript()
        for message in messages {
            result.items += items(from: message, attachmentsApart: true)
            let files = attachments(of: message, savePicture: savePicture)
            if !files.isEmpty { result.attachments[message.id] = files }
        }
        return result
    }

    /// A user message's files. A file is shown from its own place on this Mac while it is still there. A picture
    /// whose file is gone (deleted, or a pasted picture cleaned out of the cache) is saved again from the bytes the
    /// engine keeps in the message.
    static func attachments(of message: Wire.Message, savePicture: ((String, String?) -> String?)? = nil) -> [MessageAttachment] {
        guard message.type == "user" else { return [] }
        return (message.files ?? []).enumerated().map { index, file in
            let url = file.source?.uri.flatMap { URL(string: $0) }
            let local = url.flatMap { $0.isFileURL ? $0 : nil }
            let fileName = file.name ?? url?.lastPathComponent
            let mime = file.mime ?? (fileName as NSString?).flatMap { MessageAttachments.imageMediaTypes[$0.pathExtension.lowercased()] }
            let isPicture = mime?.hasPrefix("image/") == true
            var path = local.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
            if path == nil, isPicture, let data = file.data, !data.isEmpty { path = savePicture?(data, mime) }
            return MessageAttachment(id: "\(message.id):\(index)", kind: isPicture ? .image : .file,
                                     name: MessageAttachments.displayName(fileName), mediaType: mime, path: path)
        }
    }

    static func items(from message: Wire.Message, attachmentsApart: Bool = false) -> [TranscriptItem] {
        let date = Wire.date(message.time.created)
        switch message.type {
        case "user":
            var text = message.text ?? ""
            let names = (message.files ?? []).compactMap { $0.name ?? $0.source?.uri.map { URL(string: $0)?.lastPathComponent ?? $0 } }
            if !names.isEmpty, !attachmentsApart {
                text += (text.isEmpty ? "" : "\n\n") + names.map { "Attached: \($0)" }.joined(separator: "\n")
            }
            return [.user(id: message.id, text: text, date: date)]

        case "synthetic":
            if message.metadata?["source"]?.stringValue == "subagent" {
                let label = message.description ?? message.metadata?["agent"]?.stringValue ?? "Subagent"
                let state = message.metadata?["state"]?.stringValue ?? "reported"
                return [.notice(id: message.id, text: "Subagent \(label): \(state)")]
            }
            return [.notice(id: message.id, text: message.text ?? "")]

        case "system":
            guard let description = message.description, !description.isEmpty else { return [] }
            return [.notice(id: message.id, text: description)]

        case "skill":
            return [.notice(id: message.id, text: "Loaded skill \(message.name ?? "")")]

        case "shell":
            let status: ToolStatus
            switch message.status {
            case "running": status = .running
            case "exited": status = .succeeded
            default: status = .failed
            }
            let command = message.command ?? "shell"
            let info = ToolCallInfo(id: message.id, name: "shell", title: command,
                                    inputJSON: JSONValue.object(["command": .string(command)]).prettyJSONText,
                                    status: status, outputPreview: message.output.map { ToolCards.trimmed($0.output) })
            return [.tool(info)]

        case "assistant":
            return assistantItems(message)

        case "compaction":
            switch message.status {
            case "running": return [.notice(id: message.id, text: "Compacting conversation")]
            case "failed": return [.error(id: message.id, message: "Compaction failed: \(message.error?.message ?? "unknown error")")]
            default: return [.notice(id: message.id, text: "Conversation compacted")]
            }

        case "idle":
            switch message.outcome {
            case "failed": return [.error(id: message.id, message: message.error?.message ?? "The agent stopped with an error")]
            case "interrupted": return [.notice(id: message.id, text: "Interrupted")]
            default: return []
            }

        case "agent-switched":
            return [.notice(id: message.id, text: "Switched to agent \(message.agent ?? "")")]

        case "model-switched":
            let model = message.model.map { ModelRef(wire: $0).description } ?? ""
            return [.notice(id: message.id, text: "Switched model to \(model)")]

        case "location-switched":
            return [.notice(id: message.id, text: "Moved to \(message.location?.directory ?? "")")]

        default:
            return []
        }
    }

    static func assistantItems(_ message: Wire.Message) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        let finished = message.time.completed != nil || message.finish != nil
        var textOrdinal = 0
        var reasoningOrdinal = 0
        for part in message.content ?? [] {
            switch part {
            case .text(let text):
                items.append(.agentText(id: TranscriptIDs.text(messageID: message.id, ordinal: textOrdinal), text: text,
                                        agentID: nil, streaming: !finished))
                textOrdinal += 1
            case .reasoning(let text, let completed):
                items.append(.reasoning(id: TranscriptIDs.reasoning(messageID: message.id, ordinal: reasoningOrdinal), text: text,
                                        streaming: !(completed || finished)))
                reasoningOrdinal += 1
            case .tool(let tool):
                items.append(.tool(ToolCards.make(id: tool.id, name: tool.name, state: tool.state)))
            case .unknown:
                break
            }
        }
        if let error = message.error, error.type != "aborted" {
            items.append(.error(id: TranscriptIDs.error(messageID: message.id), message: error.message))
        }
        return items
    }
}

// MARK: Context

enum ContextEstimator {
    /// Rough token count for text (about four characters per token).
    static func tokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    /// Builds the context panel numbers from the messages the engine will send next turn
    /// (`GET /api/session/{id}/context`) and the model's limits.
    ///
    /// The engine does not report a breakdown, so: `used` comes from the newest assistant step's real token
    /// count (input + cache + output). Messages, tools and skills are estimated from their text. The rest of the
    /// real prompt (system prompt, tool definitions, skill list, instructions) is reported as `systemPrompt`.
    /// `buffer` is the space kept free for the reply and compaction, `free` is what is left.
    static func breakdown(messages: [Wire.Message], contextLimit: Int?, outputLimit: Int?) -> ContextBreakdown {
        var messageTokens = 0
        var toolTokens = 0
        var skillTokens = 0
        var lastStepTokens: Int?

        for message in messages {
            switch message.type {
            case "user", "synthetic":
                messageTokens += tokens(message.text ?? "")
            case "skill":
                skillTokens += tokens(message.text ?? "")
            case "shell":
                toolTokens += tokens(message.command ?? "") + tokens(message.output?.output ?? "")
            case "compaction":
                messageTokens += tokens(message.summary ?? "")
            case "assistant":
                for part in message.content ?? [] {
                    switch part {
                    case .text(let text): messageTokens += tokens(text)
                    case .reasoning(let text, _): messageTokens += tokens(text)
                    case .tool(let tool):
                        toolTokens += tokens(tool.state.input?.jsonText ?? "")
                        for item in tool.state.content ?? [] { toolTokens += tokens(item.text ?? "") }
                        if let error = tool.state.error { toolTokens += tokens(error.message) }
                    case .unknown: break
                    }
                }
                if let t = message.tokens {
                    let total = Int(t.input + t.cache.read + t.cache.write + t.output)
                    if total > 0 { lastStepTokens = total }
                }
            default:
                break
            }
        }

        let estimated = messageTokens + toolTokens + skillTokens
        let used = max(lastStepTokens ?? estimated, estimated)
        let systemPrompt = max(0, used - estimated)
        let limit = max(contextLimit ?? 0, 0)
        var buffer = 0
        if limit > 0 {
            let output = (outputLimit ?? 0) > 0 ? outputLimit! : limit / 5
            buffer = min(output, 32_000, max(0, limit - used))
        }
        let free = max(0, limit - used - buffer)

        var categories: [ContextBreakdown.Category] = [
            .init(key: "messages", label: "Messages", tokens: messageTokens),
            .init(key: "tools", label: "Tools", tokens: toolTokens),
            .init(key: "systemPrompt", label: "System prompt", tokens: systemPrompt),
        ]
        if skillTokens > 0 { categories.append(.init(key: "skills", label: "Skills", tokens: skillTokens)) }
        if limit > 0 {
            categories.append(.init(key: "buffer", label: "Autocompact buffer", tokens: buffer))
            categories.append(.init(key: "free", label: "Free space", tokens: free))
        }
        return ContextBreakdown(usedTokens: used, limitTokens: limit, categories: categories)
    }
}

// MARK: Panels and lists

extension FileChange {
    init(wire: Wire.FileDiff) {
        let kind: Kind
        switch wire.status {
        case "added": kind = .added
        case "deleted": kind = .deleted
        default: kind = .modified
        }
        self.init(path: wire.file, kind: kind, additions: wire.additions ?? 0, deletions: wire.deletions ?? 0,
                  diff: (wire.patch?.isEmpty ?? true) ? nil : wire.patch)
    }
}

extension ConnectorInfo {
    init(wire: Wire.McpServer) {
        let state: State
        switch wire.status.status {
        case "connected": state = .connected
        case "needs_auth": state = .needsAuth
        case "failed": state = .failed
        case "disabled": state = .disabled
        default: state = .connecting
        }
        self.init(id: wire.name, name: wire.title ?? wire.name, state: state, toolCount: 0)
    }
}

extension ModelInfo {
    init(wire: Wire.Model, providerName: String?) {
        let variants = (wire.variants ?? []).map(\.id).filter { $0 != "default" }
        self.init(ref: ModelRef(providerID: wire.providerID, id: wire.id), name: wire.name,
                  providerName: providerName ?? wire.providerID, contextLimit: wire.limit?.context,
                  variants: variants, available: wire.enabled ?? true)
    }
}

enum ProviderList {
    /// Providers shown first in Settings, in this order.
    static let featured = ["anthropic", "openai", "xai", "google", "openrouter"]

    /// Integrations that take an API key, featured ones first, then connected ones, then by name.
    static func providers(from integrations: [Wire.Integration]) -> [ProviderInfo] {
        let usable = integrations.filter { integration in
            integration.methods.contains { $0.type == "key" }
        }
        let infos = usable.map { ProviderInfo(id: $0.id, name: $0.name, connected: !$0.connections.isEmpty) }
        return infos.sorted { a, b in
            let fa = featured.firstIndex(of: a.id) ?? Int.max
            let fb = featured.firstIndex(of: b.id) ?? Int.max
            if fa != fb { return fa < fb }
            if a.connected != b.connected { return a.connected }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

enum ScheduleText {
    /// Turns the `schedule` text used by `ScheduleInfo` into the engine's `when` object.
    /// Accepts a cron expression (`0 9 * * 1-5`), `every 5 minutes`, `in 90 seconds` or `at 2026-12-01T09:00`.
    static func when(from text: String, timeZone: String? = TimeZone.current.identifier) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        var when: [String: String]
        if lower.hasPrefix("every ") {
            when = ["every": String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)]
        } else if lower.hasPrefix("in ") {
            when = ["in": String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)]
        } else if lower.hasPrefix("at ") {
            when = ["at": String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)]
        } else {
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard (5...6).contains(fields.count) else { return nil }
            when = ["cron": fields.joined(separator: " ")]
        }
        if let timeZone { when["tz"] = timeZone }
        return when
    }

    static func text(from when: Wire.ScheduleWhen) -> String {
        switch when.type {
        case "cron": when.cron ?? ""
        case "every": "every \(when.every ?? "")"
        case "in": "in \(when.in ?? "")"
        case "at": "at \(when.at ?? "")"
        default: when.type
        }
    }
}

extension ScheduleInfo {
    init(wire: Wire.Schedule, directory: String) {
        let prompt = wire.action?.prompt ?? ""
        let title = (wire.name?.isEmpty == false ? wire.name : nil) ?? String(prompt.prefix(60))
        self.init(id: wire.id, title: title, prompt: prompt, directory: directory, schedule: ScheduleText.text(from: wire.when),
                  paused: wire.status == "paused", nextRun: wire.status == "done" ? nil : Wire.date(wire.nextDueAt))
    }
}
