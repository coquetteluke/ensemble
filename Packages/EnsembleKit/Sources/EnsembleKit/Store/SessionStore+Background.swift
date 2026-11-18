import Foundation

/// The one list of background work across every session, rooms included: running subagents (child sessions), the
/// background shells and tasks engines report (`EngineBackgroundTasks`), and the next run of each active schedule:
/// Ensemble's scheduled tasks (`TaskScheduler`) and the engine's own schedules.
extension SessionStore {
    public var backgroundControl: (any EngineBackgroundTasks)? { engine as? any EngineBackgroundTasks }

    // MARK: The list

    /// Every row, ungrouped.
    public var backgroundItems: [BackgroundWorkItem] {
        var items: [BackgroundWorkItem] = []
        for session in sessions where session.info.parentID != nil && session.isWorking && !hiddenSessionIDs.contains(session.id) {
            items.append(BackgroundWorkItem(id: "subagent:\(session.id)", kind: .subagent, title: Self.rowTitle(session.title, fallback: "Subagent"),
                                            detail: session.info.agent, openSessionID: session.id,
                                            rootSessionID: rootSessionID(of: session.id), started: session.workingSince))
        }
        for task in background.tasks {
            items.append(BackgroundWorkItem(id: "task:\(task.id)", kind: task.kind == .shell ? .shell : .task,
                                            title: Self.rowTitle(task.title, fallback: task.kind == .shell ? "Shell command" : "Task"),
                                            openSessionID: byID[task.sessionID] == nil ? nil : task.sessionID,
                                            rootSessionID: rootSessionID(of: task.sessionID), started: task.started, task: task))
        }
        if let scheduler = background.scheduler {
            for task in scheduler.tasks where !task.paused {
                guard let next = scheduler.nextRun(for: task) else { continue }
                let running = scheduler.runs.first { $0.taskID == task.id && $0.status.isActive }
                let folder = Format.folderName(task.continueSessionID.flatMap { byID[$0]?.directory } ?? task.directory)
                items.append(BackgroundWorkItem(id: "scheduled-task:\(task.id.uuidString)", kind: .schedule,
                                                title: Self.rowTitle(task.name, fallback: task.prompt),
                                                detail: running?.status.label ?? folder,
                                                openSessionID: running?.sessionID.flatMap { byID[$0] == nil ? nil : $0 },
                                                nextRun: next, scheduledTaskID: task.id))
            }
        }
        for schedule in schedules where !schedule.paused && !background.pausedScheduleIDs.contains(schedule.id) {
            guard let next = schedule.nextRun else { continue }
            items.append(BackgroundWorkItem(id: "schedule:\(schedule.id)", kind: .schedule,
                                            title: Self.rowTitle(schedule.title, fallback: schedule.prompt),
                                            detail: Format.folderName(schedule.directory), nextRun: next, scheduleID: schedule.id))
        }
        return items
    }

    /// The list grouped by top-level session, newest work first, scheduled runs last. `roomTitles` names the room of
    /// each room agent's session (the store does not know rooms).
    public func backgroundWork(roomTitles: [String: String] = [:]) -> [BackgroundWorkGroup] {
        BackgroundWork.groups(backgroundItems) { root in
            guard let session = byID[root] else { return ("Other sessions", nil, nil) }
            let agentIDs = sessionAgentIDs[root] ?? []
            let subtitle = roomTitles[root] ?? Format.folderName(session.directory)
            return (Self.rowTitle(session.title, fallback: "Untitled session"), subtitle, agentIDs.count == 1 ? agentIDs.first : nil)
        }
    }

    /// Running rows of one session and everything under it (the context panel's Background section).
    public func backgroundWork(forSession sessionID: String) -> [BackgroundWorkItem] {
        let root = rootSessionID(of: sessionID)
        return backgroundItems.filter { $0.isRunning && $0.rootSessionID == root }.sorted(by: BackgroundWork.rowOrder)
    }

    /// Subagents, shells and tasks running now (the toolbar badge). Scheduled runs are not counted.
    public var backgroundRunningCount: Int { backgroundItems.filter(\.isRunning).count }

    /// True while the row's Stop or Pause is in flight.
    public func isStopping(_ item: BackgroundWorkItem) -> Bool { background.stopping.contains(item.id) }

    /// The top-level session above a session (itself when it has no parent, or when its parent is unknown).
    public func rootSessionID(of sessionID: String) -> String {
        var current = sessionID
        var hops = 0
        while let parent = byID[current]?.info.parentID, hops < 32 {
            current = parent
            hops += 1
        }
        return current
    }

    private static func rowTitle(_ title: String, fallback: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? fallback : line
    }

    // MARK: Actions

    /// Asks the engines for their background shells and tasks again.
    public func refreshBackgroundTasks() async {
        guard let control = backgroundControl else { return }
        guard !background.refreshing else { return }
        background.refreshing = true
        defer { background.refreshing = false }
        if let tasks = try? await control.backgroundTasks() {
            if tasks != background.tasks { background.tasks = tasks }
        }
    }

    /// Stops one row: a subagent (only that subagent when the engine can, else its session is interrupted), a background
    /// shell or task, or pauses a schedule.
    public func stopBackground(_ item: BackgroundWorkItem) async {
        guard !background.stopping.contains(item.id) else { return }
        background.stopping.insert(item.id)
        defer { background.stopping.remove(item.id) }
        do {
            switch item.kind {
            case .subagent:
                guard let sessionID = item.openSessionID else { return }
                if let control = backgroundControl {
                    try await control.stopSubagent(sessionID)
                } else {
                    try await engine.interrupt(sessionID)
                }
            case .shell, .task:
                guard let task = item.task else { return }
                guard let control = backgroundControl else {
                    throw EngineRouterError.notSupported(engine: "This engine", feature: "stop background tasks")
                }
                try await control.stopBackgroundTask(task)
                background.tasks.removeAll { $0.id == task.id && $0.sessionID == task.sessionID }
            case .schedule:
                if let taskID = item.scheduledTaskID {
                    background.scheduler?.setPaused(true, taskID: taskID)
                    return
                }
                guard let scheduleID = item.scheduleID else { return }
                try await engine.setSchedulePaused(scheduleID, paused: true)
                background.pausedScheduleIDs.insert(scheduleID)
            }
        } catch {
            lastError = "Could not stop \(item.title): \(error.localizedDescription)"
        }
        scheduleBackgroundRefresh()
    }

    /// Runs one of Ensemble's scheduled tasks now (the row's Run now).
    public func runScheduledTaskNow(_ item: BackgroundWorkItem) async {
        guard let taskID = item.scheduledTaskID, let scheduler = background.scheduler,
              !background.stopping.contains(item.id) else { return }
        background.stopping.insert(item.id)
        defer { background.stopping.remove(item.id) }
        await scheduler.runNow(taskID)
    }

    /// True while the task behind a row has a run starting, working or waiting on you (Run now is off).
    public func scheduledTaskIsRunning(_ item: BackgroundWorkItem) -> Bool {
        guard let taskID = item.scheduledTaskID, let scheduler = background.scheduler else { return false }
        return scheduler.hasActiveRun(taskID)
    }

    /// Fills the background tasks without an engine (previews and snapshots).
    public func seedBackgroundTasks(_ tasks: [BackgroundTask]) {
        background.tasks = tasks
    }

    // MARK: Following events

    /// Runs after every live event (`apply`): background work, the plan limit meter and auto-continue follow the turns.
    func backgroundDidApply(_ event: EngineEvent) {
        switch event {
        case .other(let type):
            if type == ClaudeEventTypes.rateLimit { background.planLimitsRevision &+= 1 }
            if type == ClaudeEventTypes.backgroundTasks || type.hasPrefix("shell.") || type.hasPrefix("job.") || type == "server.connected" {
                scheduleBackgroundRefresh()
            }
        case .executionEnded:
            background.planLimitsRevision &+= 1
            scheduleBackgroundRefresh()
        case .sessionDeleted(let sessionID):
            background.tasks.removeAll { $0.sessionID == sessionID }
        default:
            break
        }
        autoContinueDidApply(event)
    }

    /// Refreshes the background tasks shortly, once for a burst of events.
    func scheduleBackgroundRefresh() {
        guard backgroundControl != nil, background.refreshTask == nil else { return }
        background.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.background.refreshTask = nil
            await self.refreshBackgroundTasks()
        }
    }
}

/// Names of the `.other` events the Claude engine sends.
public enum ClaudeEventTypes {
    /// A `rate_limit_event` arrived (plan use changed).
    public static let rateLimit = "claude.rate_limit"
    /// The process's background tasks changed (`task_started`, `task_updated`, `task_notification`,
    /// `background_tasks_changed`).
    public static let backgroundTasks = "claude.background_tasks"
}
