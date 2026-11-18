import Foundation

// MARK: Background work and plan limit stops

extension ClaudeCodeEngine: EngineBackgroundTasks, EngineUsageLimitReporting {
    #if os(macOS)
    /// Background shells (`Bash` with `run_in_background`), workflows and other tasks the running `claude` processes
    /// reported (`ClaudeTaskTracker`). Subagents are child sessions and are not listed here.
    public func backgroundTasks() async throws -> [BackgroundTask] { await core.backgroundTasks() }

    /// Sends `stop_task` for the task to the process of the session that started it.
    public func stopBackgroundTask(_ task: BackgroundTask) async throws {
        try await core.stopTask(task.id, root: ClaudeSessionIDs.root(of: task.sessionID))
    }

    /// Sends `stop_task` for the subagent's task: the subagent ends and its parent's turn goes on. A CLI that sent no
    /// task id for it (older than task events) only offers stopping the whole turn.
    public func stopSubagent(_ sessionID: String) async throws {
        let root = ClaudeSessionIDs.root(of: sessionID)
        if let taskID = await core.subagentTaskID(sessionID) {
            try await core.stopTask(taskID, root: root)
        } else {
            try await interrupt(root)
        }
    }

    public func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? { await core.usageLimitStop(sessionID) }
    #else
    public func backgroundTasks() async throws -> [BackgroundTask] { [] }
    public func stopBackgroundTask(_ task: BackgroundTask) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func stopSubagent(_ sessionID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }
    public func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? { nil }
    #endif
}
