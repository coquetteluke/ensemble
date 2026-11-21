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
        if TodoParser.isPlanTool(name) {
            self = .plan
            return
        }
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

/// One entry of an agent's task list. Every engine's plan or todo tool ends up as these (`TodoParser`).
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

/// Reads the task list out of a transcript's tool calls. Engines keep their list in different ways:
///
/// - `todowrite` (OpenCode), `TodoWrite` (the Claude CLI) and the ACP plan (mapped to `todowrite`) send the whole
///   list every time: `{"todos": [{"content", "status", "activeForm"}]}`.
/// - `update_plan` (the Claude desktop app's `mcp__ccd_turn__update_plan`, which sessions imported from that app
///   use) sends the whole list once as `items`, then small steps: `{"advance": true}` finishes the step in progress
///   and starts the next one, `{"done": [2], "start": 4}` marks steps by their place in the list, counted from 1.
///   Its partner `wrap_up` closes the turn and checks off whatever is left. Codex-style `{"plan": [{"step",
///   "status"}]}` is read the same way as `items`.
/// - `TaskCreate` and `TaskUpdate` (the Claude CLI's newer task tools) add one task at a time and change it by id.
///
/// So the list is rebuilt by replaying the calls in order, not by reading the newest call alone.
public enum TodoParser {
    /// Tools that send the whole list as `todos`.
    public static func isTodoTool(_ name: String) -> Bool {
        ["todowrite", "todo_write", "todo"].contains(name.lowercased())
    }

    /// Any tool that changes the task list (for summaries and icons).
    public static func isPlanTool(_ name: String) -> Bool { kind(name) != nil }

    enum Kind { case wholeList, updatePlan, wrapUp, taskCreate, taskUpdate }

    /// The MCP server whose tools keep the task list in sessions from the Claude desktop app.
    static let planServer = "ccd_turn"

    /// An engine's own plan tools go by their bare names. MCP tools are named `mcp__<server>__<tool>`: only the plan
    /// server's count, because another server's `task_create` or `update_plan` (an issue tracker, say) is about
    /// something else and nothing would ever finish its steps.
    static func kind(_ name: String) -> Kind? {
        let lower = name.lowercased()
        if lower.hasPrefix("mcp__") {
            switch lower {
            case "mcp__\(planServer)__update_plan": return .updatePlan
            case "mcp__\(planServer)__wrap_up": return .wrapUp
            default: return nil
            }
        }
        switch lower {
        case "todowrite", "todo_write", "todo": return .wholeList
        case "update_plan", "updateplan": return .updatePlan
        case "taskcreate", "task_create": return .taskCreate
        case "taskupdate", "task_update": return .taskUpdate
        default: return nil
        }
    }

    /// The list from a tool input that carries a whole list: `{"todos": [...]}`, `{"items": [...]}` or `{"plan": [...]}`.
    public static func parse(_ inputJSON: String) -> [TodoItem]? {
        object(inputJSON).flatMap(wholeList)
    }

    static func object(_ inputJSON: String) -> [String: Any]? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func wholeList(_ object: [String: Any]) -> [TodoItem]? {
        guard let entries = (object["todos"] ?? object["items"] ?? object["plan"]) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry -> TodoItem? in
            guard let content = text(entry, "content", "text", "step", "subject", "title") else { return nil }
            return TodoItem(content: content, status: status(entry["status"] as? String),
                            activeForm: text(entry, "activeForm", "active_form"))
        }
    }

    private static func text(_ entry: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = entry[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func status(_ raw: String?) -> TodoItem.Status {
        switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "in_progress", "inprogress", "active", "running": .inProgress
        case "completed", "complete", "done": .completed
        case "cancelled", "canceled": .cancelled
        default: .pending
        }
    }

    /// The current list: every plan and todo tool call replayed in order. Nil when the transcript has none.
    /// A call that failed changed nothing, so it is skipped.
    public static func latest(in items: [TranscriptItem]) -> [TodoItem]? {
        // Walk back to the newest call that sends a whole list, then replay forward from it. Task tools never send
        // a whole list, so a transcript that only uses them is replayed from its start.
        var calls: [(kind: Kind, input: [String: Any], output: String?)] = []
        for item in items.reversed() {
            guard case .tool(let tool) = item, tool.status != .failed, let kind = kind(tool.name) else { continue }
            let input = object(tool.inputJSON) ?? [:]
            calls.append((kind, input, tool.outputPreview))
            if kind == .wholeList || kind == .updatePlan, wholeList(input) != nil { break }
        }
        guard !calls.isEmpty else { return nil }
        var list = Replay()
        for call in calls.reversed() { list.apply(call.kind, input: call.input, output: call.output) }
        return list.started ? list.items : nil
    }

    /// The list while the calls are replayed. `ids` runs beside `items` for the task tools, which name tasks by id.
    struct Replay {
        var items: [TodoItem] = []
        var ids: [String] = []
        /// True once a call has set or added to the list (steps on an unknown list show nothing).
        var started = false

        mutating func apply(_ kind: Kind, input: [String: Any], output: String?) {
            switch kind {
            case .wholeList:
                guard let list = TodoParser.wholeList(input) else { return }
                replace(with: list)
            case .updatePlan:
                if let list = TodoParser.wholeList(input) { replace(with: list) }
                // Places count from 1.
                for place in TodoParser.integers(input["done"]) { set(place - 1, .completed) }
                if let place = TodoParser.integers(input["start"]).first { set(place - 1, .inProgress) }
                if input["advance"] as? Bool == true { advance() }
            case .wrapUp:
                for index in items.indices where items[index].status == .pending || items[index].status == .inProgress {
                    items[index].status = .completed
                }
            case .taskCreate:
                guard let subject = TodoParser.text(input, "subject", "content", "title", "description") else { return }
                items.append(TodoItem(content: subject, status: .pending, activeForm: TodoParser.text(input, "activeForm")))
                ids.append(TodoParser.createdTaskID(output) ?? String(items.count))
                started = true
            case .taskUpdate:
                guard let id = TodoParser.identifier(input["taskId"] ?? input["task_id"] ?? input["id"]),
                      // The newest task with this id: a forked session can number its tasks from 1 again.
                      let index = ids.lastIndex(of: id) else { return }
                let raw = (input["status"] as? String)?.lowercased()
                if raw == "deleted" {
                    items.remove(at: index)
                    ids.remove(at: index)
                    return
                }
                if raw != nil { items[index].status = TodoParser.status(raw) }
                if let subject = TodoParser.text(input, "subject") { items[index].content = subject }
                if let active = TodoParser.text(input, "activeForm") { items[index].activeForm = active }
            }
        }

        private mutating func replace(with list: [TodoItem]) {
            items = list
            ids = list.indices.map { String($0 + 1) }
            started = true
        }

        private mutating func set(_ index: Int, _ status: TodoItem.Status) {
            guard items.indices.contains(index) else { return }
            items[index].status = status
        }

        /// Finishes the step in progress and starts the next one that is still to do.
        private mutating func advance() {
            let current = items.firstIndex { $0.status == .inProgress }
            if let current { items[current].status = .completed }
            let after = current.map { $0 + 1 } ?? 0
            if let next = items.indices.first(where: { $0 >= after && items[$0].status == .pending })
                ?? items.firstIndex(where: { $0.status == .pending }) {
                items[next].status = .inProgress
            }
        }
    }

    /// Whole numbers from a JSON value that is a number or a list of numbers.
    static func integers(_ value: Any?) -> [Int] {
        if let list = value as? [Any] { return list.flatMap(integers) }
        return number(value).map { [$0] } ?? []
    }

    static func identifier(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return number(value).map(String.init)
    }

    /// A JSON number as an integer. JSON `true` and `false` also arrive as `NSNumber` (and 0 and 1 cast to `Bool`),
    /// so the two are told apart by their Core Foundation type.
    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// The id in a `TaskCreate` result ("Task #3 created successfully").
    static func createdTaskID(_ output: String?) -> String? {
        guard let output, let hash = output.range(of: "Task #") else { return nil }
        let digits = output[hash.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}
