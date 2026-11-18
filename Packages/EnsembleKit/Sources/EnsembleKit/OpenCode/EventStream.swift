import Foundation

/// One Server-Sent Events message.
struct SSEMessage: Equatable, Sendable {
    var event: String?
    var data: String
    var id: String?
}

/// Line-based Server-Sent Events parser (WHATWG rules: `data:` lines join with newlines, a blank line ends the
/// message, lines starting with `:` are comments such as OpenCode's `: heartbeat`).
struct SSEParser {
    private var dataLines: [String] = []
    private var event: String?
    private var id: String?
    private var pendingBytes: [UInt8] = []
    private(set) var lastEventID: String?

    /// Feeds one line (without its line ending). Returns a message when the line completes one.
    mutating func feed(line: String) -> SSEMessage? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "event": event = String(value)
        case "id":
            if !value.contains("\u{0}") {
                id = String(value)
                lastEventID = id
            }
        default: break
        }
        return nil
    }

    /// Feeds raw bytes. Returns every message they complete.
    mutating func feed(byte: UInt8) -> SSEMessage? {
        if byte == UInt8(ascii: "\n") {
            if pendingBytes.last == UInt8(ascii: "\r") { pendingBytes.removeLast() }
            let line = String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll(keepingCapacity: true)
            return feed(line: line)
        }
        pendingBytes.append(byte)
        return nil
    }

    /// Feeds a whole chunk of text (used by tests and fixtures).
    mutating func feed(text: String) -> [SSEMessage] {
        var messages: [SSEMessage] = []
        for byte in text.utf8 {
            if let message = feed(byte: byte) { messages.append(message) }
        }
        return messages
    }

    /// Ends the stream; returns a final message that had no trailing blank line.
    mutating func finish() -> SSEMessage? {
        if !pendingBytes.isEmpty {
            let line = String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll()
            _ = feed(line: line)
        }
        return dispatch()
    }

    private mutating func dispatch() -> SSEMessage? {
        defer {
            dataLines.removeAll()
            event = nil
            id = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEMessage(event: event, data: dataLines.joined(separator: "\n"), id: id)
    }
}

/// Turns OpenCode event JSON (`{"id","created","type","data",...}`) into `EngineEvent`s.
///
/// It keeps a little state: `session.tool.called`, `.progress`, `.success` and `.failed` do not repeat the tool
/// name or input, so they are remembered from `session.tool.input.started` and `session.tool.called`.
struct EngineEventDecoder {
    enum Output: Equatable, Sendable {
        case event(EngineEvent)
        /// The session changed (renamed, archived, model switched, ...). Fetch it and emit `.sessionUpdated`.
        case refreshSession(id: String, type: String)
    }

    private struct ToolTrack {
        var name: String
        var input: JSONValue?
        var childSessionID: String?
        var order: Int
    }

    private var tools: [String: ToolTrack] = [:]
    private var counter = 0
    private let maxTrackedTools = 1000
    private let decoder = JSONDecoder()

    private struct Head: Decodable {
        let type: String
        let created: Double?
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T
        let location: Wire.LocationRef?
        let created: Double?
    }

    private struct SessionRef: Decodable { let sessionID: String }
    private struct Delta: Decodable { let sessionID: String; let assistantMessageID: String; let ordinal: Int; let delta: String }
    private struct Ended: Decodable { let sessionID: String; let assistantMessageID: String; let ordinal: Int; let text: String }
    private struct ToolInputStarted: Decodable { let sessionID: String; let id: String; let name: String }
    private struct ToolCalled: Decodable { let sessionID: String; let id: String; let input: JSONValue? }
    private struct ToolProgress: Decodable { let sessionID: String; let id: String; let metadata: JSONValue? }
    private struct ToolFinished: Decodable {
        let sessionID: String
        let id: String
        let content: [Wire.ToolContent]?
        let metadata: JSONValue?
        let error: Wire.StructuredError?
    }
    private struct UsageUpdated: Decodable { let sessionID: String; let cost: Double?; let tokens: Wire.Tokens? }
    private struct ExecutionFailed: Decodable { let sessionID: String; let error: Wire.StructuredError? }
    private struct ExecutionInterrupted: Decodable { let sessionID: String; let reason: String? }
    private struct StatusUpdated: Decodable {
        struct Status: Decodable { let type: String }
        let sessionID: String
        let status: Status
    }
    private struct SessionCreated: Decodable {
        let sessionID: String
        let parentID: String?
        let title: String?
        let agent: String?
        let model: Wire.ModelRef?
        let location: Wire.LocationRef?
    }
    private struct PermissionReplied: Decodable { let sessionID: String; let requestID: String; let reply: String? }
    private struct FormCreated: Decodable { let form: OpenCodeForms.Form }
    private struct FormSettled: Decodable { let id: String; let sessionID: String }
    private struct FileChanged: Decodable { let file: String; let event: String? }

    /// Event types that change a session's stored facts; the stream refetches the session for these.
    static let sessionRefreshTypes: Set<String> = [
        "session.renamed", "session.archived", "session.unarchived", "session.model.selected", "session.agent.selected",
        "session.moved", "session.metadata.updated", "session.permissions",
    ]

    mutating func decode(_ text: String) -> [Output] {
        guard let data = text.data(using: .utf8) else { return [] }
        return decode(data)
    }

    mutating func decode(_ data: Data) -> [Output] {
        guard let head = try? decoder.decode(Head.self, from: data) else { return [] }
        let type = head.type
        func payload<T: Decodable>(_: T.Type) -> T? {
            try? decoder.decode(Envelope<T>.self, from: data).data
        }
        let created = head.created.map(Wire.date) ?? Date()

        switch type {
        case "session.created":
            guard let e = payload(SessionCreated.self) else { break }
            let session = EngineSession(id: e.sessionID, parentID: e.parentID, title: e.title ?? "", directory: e.location?.directory ?? "",
                                        model: e.model.map(ModelRef.init(wire:)), agent: e.agent, created: created, updated: created)
            return [.event(.sessionCreated(session))]

        case "session.deleted":
            guard let e = payload(SessionRef.self) else { break }
            return [.event(.sessionDeleted(sessionID: e.sessionID))]

        case _ where Self.sessionRefreshTypes.contains(type):
            guard let e = payload(SessionRef.self) else { break }
            return [.refreshSession(id: e.sessionID, type: type)]

        case "session.execution.started":
            guard let e = payload(SessionRef.self) else { break }
            return [.event(.activity(sessionID: e.sessionID, .working))]

        case "session.execution.succeeded":
            guard let e = payload(SessionRef.self) else { break }
            return [.event(.executionEnded(sessionID: e.sessionID, outcome: "succeeded", error: nil)),
                    .event(.activity(sessionID: e.sessionID, .idle))]

        case "session.execution.failed":
            guard let e = payload(ExecutionFailed.self) else { break }
            return [.event(.executionEnded(sessionID: e.sessionID, outcome: "failed", error: e.error?.message ?? "Failed")),
                    .event(.activity(sessionID: e.sessionID, .failed))]

        case "session.execution.interrupted":
            guard let e = payload(ExecutionInterrupted.self) else { break }
            return [.event(.executionEnded(sessionID: e.sessionID, outcome: "interrupted", error: nil)),
                    .event(.activity(sessionID: e.sessionID, .idle))]

        case "session.status":
            guard let e = payload(StatusUpdated.self) else { break }
            let activity: SessionActivity = e.status.type == "idle" ? .idle : .working
            return [.event(.activity(sessionID: e.sessionID, activity))]

        case "session.idle":
            guard let e = payload(SessionRef.self) else { break }
            return [.event(.activity(sessionID: e.sessionID, .idle))]

        case "session.text.delta":
            guard let e = payload(Delta.self) else { break }
            return [.event(.textDelta(sessionID: e.sessionID, itemID: TranscriptIDs.text(messageID: e.assistantMessageID, ordinal: e.ordinal),
                                      delta: e.delta))]

        case "session.text.ended":
            guard let e = payload(Ended.self) else { break }
            return [.event(.textEnded(sessionID: e.sessionID, itemID: TranscriptIDs.text(messageID: e.assistantMessageID, ordinal: e.ordinal),
                                      text: e.text))]

        case "session.reasoning.delta":
            guard let e = payload(Delta.self) else { break }
            return [.event(.reasoningDelta(sessionID: e.sessionID,
                                           itemID: TranscriptIDs.reasoning(messageID: e.assistantMessageID, ordinal: e.ordinal),
                                           delta: e.delta))]

        case "session.tool.input.started":
            guard let e = payload(ToolInputStarted.self) else { break }
            track(e.id) { $0.name = e.name }
            let info = ToolCallInfo(id: e.id, name: e.name, title: e.name, status: .pending)
            return [.event(.toolUpdated(sessionID: e.sessionID, info))]

        case "session.tool.called":
            guard let e = payload(ToolCalled.self) else { break }
            track(e.id) { $0.input = e.input }
            let state = Wire.ToolState(status: "running", input: e.input, content: nil, metadata: nil, error: nil)
            return [.event(.toolUpdated(sessionID: e.sessionID, card(id: e.id, state: state)))]

        case "session.tool.progress":
            guard let e = payload(ToolProgress.self) else { break }
            if let child = ToolCards.childSessionID(metadata: e.metadata) { track(e.id) { $0.childSessionID = child } }
            let state = Wire.ToolState(status: "running", input: tools[e.id]?.input, content: nil, metadata: e.metadata, error: nil)
            return [.event(.toolUpdated(sessionID: e.sessionID, card(id: e.id, state: state)))]

        case "session.tool.success", "session.tool.failed":
            guard let e = payload(ToolFinished.self) else { break }
            let status = type == "session.tool.success" ? "completed" : "error"
            let state = Wire.ToolState(status: status, input: tools[e.id]?.input, content: e.content, metadata: e.metadata, error: e.error)
            let info = card(id: e.id, state: state)
            tools[e.id] = nil
            return [.event(.toolUpdated(sessionID: e.sessionID, info))]

        case "permission.asked":
            guard let e = payload(Wire.PermissionRequest.self) else { break }
            return [.event(.permissionAsked(PermissionRequest(wire: e, created: created))),
                    .event(.activity(sessionID: e.sessionID, .waitingForPermission))]

        case "permission.replied":
            guard let e = payload(PermissionReplied.self) else { break }
            return [.event(.permissionReplied(sessionID: e.sessionID, requestID: e.requestID)),
                    .event(.activity(sessionID: e.sessionID, .working))]

        case "form.created":
            // Questions (`OpenCodeForms`); a form with nothing Ensemble can answer stays an unknown event.
            guard let e = payload(FormCreated.self), let request = OpenCodeForms.request(e.form, created: created) else { break }
            return [.event(.permissionAsked(request)), .event(.activity(sessionID: request.sessionID, .waitingForPermission))]

        case "form.replied":
            guard let e = payload(FormSettled.self) else { break }
            return [.event(.permissionReplied(sessionID: e.sessionID, requestID: e.id)),
                    .event(.activity(sessionID: e.sessionID, .working))]

        case "form.cancelled":
            // Also sent when a turn is interrupted, so the activity is left to the execution events.
            guard let e = payload(FormSettled.self) else { break }
            return [.event(.permissionReplied(sessionID: e.sessionID, requestID: e.id))]

        case "session.usage.updated":
            guard let e = payload(UsageUpdated.self) else { break }
            return [.event(.usageUpdated(sessionID: e.sessionID, Usage(tokens: e.tokens, cost: e.cost)))]

        case "filesystem.changed":
            guard let e = payload(FileChanged.self) else { break }
            return [.event(.filesChanged(paths: [e.file]))]

        case "mcp.status.changed", "mcp.resources.changed":
            return [.event(.connectorsChanged)]

        default:
            break
        }
        return [.event(.other(type: type))]
    }

    private mutating func track(_ id: String, _ update: (inout ToolTrack) -> Void) {
        counter += 1
        var entry = tools[id] ?? ToolTrack(name: "", input: nil, childSessionID: nil, order: counter)
        update(&entry)
        tools[id] = entry
        if tools.count > maxTrackedTools {
            let oldest = tools.sorted { $0.value.order < $1.value.order }.prefix(tools.count - maxTrackedTools)
            for (key, _) in oldest { tools[key] = nil }
        }
    }

    private func card(id: String, state: Wire.ToolState) -> ToolCallInfo {
        let tracked = tools[id]
        let name = (tracked?.name.isEmpty == false ? tracked?.name : nil) ?? "tool"
        var info = ToolCards.make(id: id, name: name, state: state)
        if info.childSessionID == nil { info.childSessionID = tracked?.childSessionID }
        return info
    }
}
