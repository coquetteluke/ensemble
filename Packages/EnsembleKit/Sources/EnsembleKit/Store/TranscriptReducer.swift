import Foundation

/// Pure transcript edits driven by engine events. `SessionStore` and `PreviewEngine` both use these,
/// so the preview's saved transcript and the live view stay the same shape.
public enum TranscriptReducer {
    /// Appends a text delta to the streaming agent text item `itemID`, creating it if needed.
    public static func appendText(_ items: inout [TranscriptItem], itemID: String, delta: String, agentID: UUID?) {
        finishReasoning(&items)
        if let index = items.lastIndex(where: { $0.id == itemID }),
           case .agentText(let id, let text, let agent, _) = items[index] {
            items[index] = .agentText(id: id, text: text + delta, agentID: agent ?? agentID, streaming: true)
        } else {
            items.append(.agentText(id: itemID, text: delta, agentID: agentID, streaming: true))
        }
    }

    /// Finalises agent text `itemID` with the engine's full text (keeps the streamed text if `text` is empty).
    public static func endText(_ items: inout [TranscriptItem], itemID: String, text: String, agentID: UUID?) {
        if let index = items.lastIndex(where: { $0.id == itemID }),
           case .agentText(let id, let streamed, let agent, _) = items[index] {
            items[index] = .agentText(id: id, text: text.isEmpty ? streamed : text, agentID: agent ?? agentID, streaming: false)
        } else if !text.isEmpty {
            finishReasoning(&items)
            items.append(.agentText(id: itemID, text: text, agentID: agentID, streaming: false))
        }
    }

    /// Appends a reasoning delta to the "Thinking" item `itemID`, creating it if needed.
    public static func appendReasoning(_ items: inout [TranscriptItem], itemID: String, delta: String) {
        if let index = items.lastIndex(where: { $0.id == itemID }),
           case .reasoning(let id, let text, _) = items[index] {
            items[index] = .reasoning(id: id, text: text + delta, streaming: true)
        } else {
            items.append(.reasoning(id: itemID, text: delta, streaming: true))
        }
    }

    /// Replaces the tool card with the same id, or appends it.
    public static func upsertTool(_ items: inout [TranscriptItem], _ tool: ToolCallInfo) {
        finishReasoning(&items)
        if let index = items.lastIndex(where: { $0.id == tool.id }), case .tool = items[index] {
            items[index] = .tool(tool)
        } else {
            items.append(.tool(tool))
        }
    }

    /// Adds a permission card unless it is already there.
    public static func addPermission(_ items: inout [TranscriptItem], _ request: PermissionRequest) {
        finishReasoning(&items)
        guard !items.contains(where: { $0.id == request.id }) else { return }
        items.append(.permission(request))
    }

    /// Stops every streaming item (end of a turn).
    public static func finishStreaming(_ items: inout [TranscriptItem]) {
        for index in items.indices {
            switch items[index] {
            case .agentText(let id, let text, let agent, true):
                items[index] = .agentText(id: id, text: text, agentID: agent, streaming: false)
            case .reasoning(let id, let text, true):
                items[index] = .reasoning(id: id, text: text, streaming: false)
            default:
                break
            }
        }
    }

    /// Stops streaming reasoning near the end once something else arrives.
    static func finishReasoning(_ items: inout [TranscriptItem]) {
        var index = items.count - 1
        var checked = 0
        while index >= 0, checked < 6 {
            if case .reasoning(let id, let text, true) = items[index] {
                items[index] = .reasoning(id: id, text: text, streaming: false)
            }
            index -= 1
            checked += 1
        }
    }
}

/// What happened to a permission prompt after it was answered.
public enum PermissionResolution: String, Sendable, Hashable, Codable {
    case allowedOnce
    case allowedAlways
    case rejected
    /// Answered somewhere else (another window, the iPhone); the engine does not say how.
    case answered

    public init(_ decision: PermissionDecision) {
        switch decision {
        case .once: self = .allowedOnce
        case .always: self = .allowedAlways
        case .reject: self = .rejected
        }
    }

    public var label: String {
        switch self {
        case .allowedOnce: "Allowed once"
        case .allowedAlways: "Always allowed"
        case .rejected: "Rejected"
        case .answered: "Answered"
        }
    }
}
