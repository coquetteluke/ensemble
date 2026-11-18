import Foundation

/// The background tasks of one `claude` process, from its `system` lines (claude 2.1.319 SDK schema):
/// - `task_started`: `task_id`, `tool_use_id`, `description`, `task_type` (`local_agent`, `remote_agent`,
///   `in_process_teammate` for subagents; `local_bash` for a shell command; `local_workflow`, `monitor_mcp`, `mcp_task`
///   and others), `is_backgrounded` (false while the tool call that started it blocks on it);
/// - `task_updated`: `task_id` and a `patch` with `status` (`pending`, `running`, `completed`, `failed`, `killed`,
///   `paused`) and `is_backgrounded`;
/// - `task_notification`: `task_id`, `status` (`completed`, `failed`, `stopped`) when it ends;
/// - `background_tasks_changed`: the full set of live background tasks (replace, not merge).
/// The control request `{"subtype":"stop_task","task_id":...}` stops one (`ClaudeCodeEngine.stopBackgroundTask`).
/// Subagents also become child sessions (`ClaudeStreamDecoder`); the rest are listed as background work.
struct ClaudeTaskTracker: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var id: String
        var type: String?
        var toolUseID: String?
        var description: String
        /// The session whose tool call started it (the root or a subagent).
        var sessionID: String
        var started: Date
        /// Nil when the CLI did not say.
        var backgrounded: Bool?
        var ended = false
    }

    static let agentTypes: Set<String> = ["local_agent", "remote_agent", "in_process_teammate"]

    /// Subagent tasks (and tasks from CLIs that do not send a type) become child sessions.
    static func isAgent(_ type: String?) -> Bool {
        guard let type else { return true }
        return agentTypes.contains(type)
    }

    private(set) var entries: [String: Entry] = [:]
    /// Ids from the newest `background_tasks_changed`; nil before the first one.
    private(set) var live: Set<String>?

    mutating func start(id: String, type: String?, toolUseID: String?, description: String, sessionID: String,
                        backgrounded: Bool?, at date: Date = Date()) {
        if var existing = entries[id] {
            existing.type = type ?? existing.type
            existing.toolUseID = toolUseID ?? existing.toolUseID
            if !description.isEmpty { existing.description = description }
            existing.backgrounded = backgrounded ?? existing.backgrounded
            existing.ended = false
            entries[id] = existing
        } else {
            entries[id] = Entry(id: id, type: type, toolUseID: toolUseID, description: description, sessionID: sessionID,
                                started: date, backgrounded: backgrounded)
        }
    }

    /// Applies a `task_updated` patch. Returns true when the list of background work may have changed.
    @discardableResult
    mutating func update(id: String, patch: JSONValue) -> Bool {
        guard var entry = entries[id] else { return false }
        if let backgrounded = patch["is_backgrounded"]?.boolValue { entry.backgrounded = backgrounded }
        if let description = patch["description"]?.stringValue, !description.isEmpty { entry.description = description }
        if let status = patch["status"]?.stringValue, ["completed", "failed", "killed", "stopped"].contains(status) {
            entry.ended = true
        }
        entries[id] = entry
        return true
    }

    mutating func end(id: String) {
        entries[id]?.ended = true
        live?.remove(id)
    }

    /// Takes a `background_tasks_changed` list as the live set; tasks first seen here are added.
    mutating func replaceLive(_ tasks: [JSONValue], rootID: String, at date: Date = Date()) {
        var ids = Set<String>()
        for task in tasks {
            guard let id = task["task_id"]?.stringValue else { continue }
            ids.insert(id)
            if entries[id] == nil {
                entries[id] = Entry(id: id, type: task["task_type"]?.stringValue, toolUseID: nil,
                                    description: task["description"]?.stringValue ?? "", sessionID: rootID, started: date,
                                    backgrounded: true)
            } else {
                entries[id]?.backgrounded = true
                entries[id]?.ended = false
            }
        }
        live = ids
    }

    /// True for a task that is not a subagent.
    func isBackgroundTask(_ id: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return !Self.isAgent(entry.type)
    }

    /// The task id behind a subagent session (`<root>.<tool use id>`).
    func taskID(forChild childID: String) -> String? {
        guard let toolUseID = ClaudeSessionIDs.toolUseID(of: childID) else { return nil }
        return entries.values.first { Self.isAgent($0.type) && $0.toolUseID == toolUseID && !$0.ended }?.id
    }

    /// Background shells and tasks running now (subagents are left out: they are child sessions).
    func running() -> [BackgroundTask] {
        entries.values
            .filter { entry in
                guard !entry.ended, !Self.isAgent(entry.type) else { return false }
                if let live { return live.contains(entry.id) }
                return entry.backgrounded != false
            }
            .sorted { ($0.started, $0.id) < ($1.started, $1.id) }
            .map { entry in
                BackgroundTask(id: entry.id, sessionID: entry.sessionID, kind: entry.type == "local_bash" ? .shell : .task,
                               title: entry.description.isEmpty ? (entry.type ?? "Task") : entry.description, started: entry.started)
            }
    }
}

/// Recognises a plan limit at the end of a turn.
enum ClaudeUsageLimit {
    /// The limit behind a failed `result` line, or nil when the turn failed for another reason. `lastRateLimit` is the
    /// newest `rate_limit_event` of the process (it says when the limit resets).
    static func stop(result json: JSONValue, text: String, lastRateLimit: ClaudePlanLimits?) -> UsageLimitInfo? {
        let typed = json["api_error"]?.stringValue == "usage_limit_reached"
        let status429 = json["api_error_status"]?.intValue == 429
        let rejected = lastRateLimit?.isLimited == true
        guard typed || UsageLimitText.isUsageLimit(text) || (status429 && rejected) else { return nil }
        var info = UsageLimitInfo(message: text)
        if let limits = lastRateLimit, limits.isLimited {
            info.resetsAt = limits.resetsAt ?? limits.windows.first { $0.status == "rejected" }?.resetsAt
            info.window = limits.limitType ?? limits.windows.first { $0.status == "rejected" }?.name
        }
        if info.resetsAt == nil { info.resetsAt = UsageLimitText.legacyResetDate(text) }
        return info
    }
}
