import Foundation

/// What the engine says a session is doing right now.
public enum SessionActivity: String, Codable, Sendable {
    case idle
    case working
    case waitingForPermission
    case failed
}

public enum ToolStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

/// One tool call shown as a card in the transcript.
public struct ToolCallInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Engine tool name, e.g. `bash`, `edit`, `read`, `grep`, `webfetch`, `task`.
    public var name: String
    /// Short human title, e.g. the command or the file path.
    public var title: String
    /// Raw input as JSON text (for the expanded card).
    public var inputJSON: String
    public var status: ToolStatus
    /// First part of the output, trimmed for display.
    public var outputPreview: String?
    /// Unified diff for edits, when the engine provides one.
    public var diff: String?
    /// Child session started by this call (subagents).
    public var childSessionID: String?

    public init(id: String, name: String, title: String, inputJSON: String = "{}", status: ToolStatus,
                outputPreview: String? = nil, diff: String? = nil, childSessionID: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.inputJSON = inputJSON
        self.status = status
        self.outputPreview = outputPreview
        self.diff = diff
        self.childSessionID = childSessionID
    }
}

public enum PermissionDecision: String, Codable, Sendable {
    case once
    case always
    case reject
}

/// An agent asking to do something (run a command, edit a file, ...).
public struct PermissionRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    /// e.g. `bash`, `edit`, `webfetch`, `external_directory`.
    public var kind: String
    /// What it wants to do, in a line: the command, the file, the URL.
    public var title: String
    /// Extra detail for the expanded card. May contain text the agent wrote.
    public var detail: String?
    /// What "Always allow" saves, one entry per rule, as the engine reports it. Kept apart from
    /// `detail` so text the agent wrote can never pose as the saved rule.
    public var alwaysPatterns: [String]?
    public var created: Date

    public init(id: String, sessionID: String, kind: String, title: String, detail: String? = nil,
                alwaysPatterns: [String]? = nil, created: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.alwaysPatterns = alwaysPatterns
        self.created = created
    }
}

/// One row in a transcript.
public enum TranscriptItem: Codable, Hashable, Sendable, Identifiable {
    case user(id: String, text: String, date: Date)
    /// Agent text. `agentID` is set in rooms so the UI can show name and colour.
    case agentText(id: String, text: String, agentID: UUID?, streaming: Bool)
    case reasoning(id: String, text: String, streaming: Bool)
    case tool(ToolCallInfo)
    case permission(PermissionRequest)
    /// A message one agent sent to the room board (other agents receive it).
    case board(id: String, fromAgentID: UUID, toAgentIDs: [UUID], text: String, date: Date)
    case error(id: String, message: String)
    /// Small grey status line ("Compacting conversation", "Lead assigned the plan").
    case notice(id: String, text: String)

    public var id: String {
        switch self {
        case .user(let id, _, _), .agentText(let id, _, _, _), .reasoning(let id, _, _),
             .board(let id, _, _, _, _), .error(let id, _), .notice(let id, _):
            id
        case .tool(let t): t.id
        case .permission(let p): p.id
        }
    }
}
