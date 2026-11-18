import Foundation

/// A transcript row as drawn: a single item, or a run of activity steps collapsed into one summary row.
public enum TranscriptBlock: Identifiable, Equatable {
    case single(TranscriptItem)
    case activity(id: String, items: [TranscriptItem])

    public var id: String {
        switch self {
        case .single(let item): item.id
        case .activity(let id, _): id
        }
    }
}

/// Collapses consecutive tool calls (with the thinking and answered permission prompts between them)
/// into activity groups, like "Ran a command, read 3 files, finished a background task".
public enum TranscriptGrouping {
    public static func blocks(_ items: [TranscriptItem], resolutions: [String: PermissionResolution] = [:]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var run: [TranscriptItem] = []

        func flush() {
            let tools = run.filter { if case .tool = $0 { true } else { false } }.count
            if run.count >= 2, tools >= 1 {
                blocks.append(.activity(id: "group-" + run[0].id, items: run))
            } else {
                blocks += run.map { .single($0) }
            }
            run.removeAll()
        }

        for item in items {
            if isStep(item, resolutions: resolutions) {
                run.append(item)
            } else {
                flush()
                blocks.append(.single(item))
            }
        }
        flush()
        return blocks
    }

    static func isStep(_ item: TranscriptItem, resolutions: [String: PermissionResolution]) -> Bool {
        switch item {
        case .tool, .reasoning: true
        // Answered plans and questions stay on their own rows, so the plan and the answer remain readable.
        case .permission(let request): resolutions[request.id] != nil && !request.isInteraction
        default: false
        }
    }

    /// One-line summary of a group, e.g. "Ran a command, read 3 files, finished a background task".
    public static func summary(_ items: [TranscriptItem]) -> String {
        var order: [ToolCategory] = []
        var counts: [ToolCategory: (done: Int, running: Int, paths: Set<String>)] = [:]
        var failed = 0
        for item in items {
            guard case .tool(let tool) = item else { continue }
            let category = ToolCategory(tool.name)
            if counts[category] == nil { order.append(category) }
            var entry = counts[category] ?? (0, 0, [])
            switch tool.status {
            case .running, .pending: entry.running += 1
            case .succeeded: entry.done += 1
            case .failed:
                entry.done += 1
                failed += 1
            }
            entry.paths.insert(tool.title)
            counts[category] = entry
        }
        var phrases: [String] = []
        for category in order {
            guard let entry = counts[category] else { continue }
            phrases += category.phrases(done: entry.done, running: entry.running, distinct: entry.paths.count)
        }
        if failed > 0 { phrases.append("\(failed) failed") }
        guard var text = phrases.first else { return "Thought" }
        if phrases.count > 1 { text = phrases.joined(separator: ", ") }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// True while any step in the group is still running.
    public static func isRunning(_ items: [TranscriptItem]) -> Bool {
        items.contains { item in
            switch item {
            case .tool(let tool): tool.status == .running || tool.status == .pending
            case .reasoning(_, _, let streaming): streaming
            default: false
            }
        }
    }
}

/// What kind of work a tool call is, for summaries and icons.
public enum ToolCategory: Hashable, Sendable {
    case command, read, edit, create, search, web, webSearch, subagent, plan, other

    public init(_ name: String) {
        switch name.lowercased() {
        case "bash", "shell", "run", "command": self = .command
        case "read", "view": self = .read
        case "edit", "multiedit", "patch", "apply_patch": self = .edit
        case "write", "create": self = .create
        case "grep", "glob", "search", "find", "list", "ls": self = .search
        case "webfetch", "fetch": self = .web
        case "websearch": self = .webSearch
        case "task", "agent", "subagent": self = .subagent
        case "todowrite", "todoread", "todo", "todo_write": self = .plan
        default: self = .other
        }
    }

    func phrases(done: Int, running: Int, distinct: Int) -> [String] {
        let total = done + running
        switch self {
        case .command:
            if total == 1 { return [running > 0 ? "running a command" : "ran a command"] }
            return ["ran \(total) commands"]
        case .read:
            return [distinct == 1 ? "read a file" : "read \(distinct) files"]
        case .edit:
            return [distinct == 1 ? "edited a file" : "edited \(distinct) files"]
        case .create:
            return [distinct == 1 ? "created a file" : "created \(distinct) files"]
        case .search:
            return [total == 1 ? "searched the code" : "searched \(total) times"]
        case .web:
            return [total == 1 ? "fetched a page" : "fetched \(total) pages"]
        case .webSearch:
            return [total == 1 ? "searched the web" : "searched the web \(total) times"]
        case .subagent:
            var parts: [String] = []
            if done > 0 { parts.append(done == 1 ? "finished a background task" : "finished \(done) background tasks") }
            if running > 0 { parts.append(running == 1 ? "started a background task" : "started \(running) background tasks") }
            return parts
        case .plan:
            return ["updated the plan"]
        case .other:
            return [total == 1 ? "used a tool" : "used \(total) tools"]
        }
    }
}

// MARK: - Task lists

/// One entry of an agent's todo list (OpenCode `todowrite`, Claude Code `TodoWrite`).
public struct TodoItem: Hashable, Sendable {
    public enum Status: String, Sendable { case pending, inProgress, completed, cancelled }
    public var content: String
    public var status: Status
    /// Present-tense label for the item in progress ("Running the tests"), when the engine gives one.
    public var activeForm: String?

    public init(content: String, status: Status, activeForm: String? = nil) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
}

public enum TodoParser {
    public static func isTodoTool(_ name: String) -> Bool {
        ["todowrite", "todo_write", "todo"].contains(name.lowercased())
    }

    /// The list from a todo tool's input: `{"todos": [{"content": ..., "status": ...}]}`.
    public static func parse(_ inputJSON: String) -> [TodoItem]? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let todos = object["todos"] as? [[String: Any]] else { return nil }
        let items = todos.compactMap { entry -> TodoItem? in
            guard let content = (entry["content"] as? String) ?? (entry["text"] as? String), !content.isEmpty else { return nil }
            return TodoItem(content: content, status: status(entry["status"] as? String),
                            activeForm: entry["activeForm"] as? String)
        }
        return items
    }

    static func status(_ raw: String?) -> TodoItem.Status {
        switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "in_progress", "inprogress", "active", "running": .inProgress
        case "completed", "complete", "done": .completed
        case "cancelled", "canceled": .cancelled
        default: .pending
        }
    }

    /// The current list: the input of the newest todo tool call.
    public static func latest(in items: [TranscriptItem]) -> [TodoItem]? {
        for item in items.reversed() {
            if case .tool(let tool) = item, isTodoTool(tool.name), let todos = parse(tool.inputJSON) {
                return todos
            }
        }
        return nil
    }
}
