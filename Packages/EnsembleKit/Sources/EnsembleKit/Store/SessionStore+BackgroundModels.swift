import Foundation
import Observation

// Types for the one list of background work (toolbar popover and context panel): running subagents, background shells
// and tasks the engines report, and upcoming scheduled runs. The store builds the list in `SessionStore+Background.swift`.

/// Work an engine runs in the background for a session, other than subagents (those are child sessions): shell commands
/// started in the background, and other long tasks the engine reports (the Claude CLI's workflows and monitors).
public struct BackgroundTask: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A shell command running in the background.
        case shell
        /// Another kind of long task (a workflow, a monitor).
        case task
    }

    /// The engine's own id (the Claude CLI's task id, OpenCode's shell id). Unique within its engine.
    public var id: String
    /// The session that started it (a top-level session or a subagent).
    public var sessionID: String
    public var kind: Kind
    /// The command, or the engine's description of the task.
    public var title: String
    public var started: Date?

    public init(id: String, sessionID: String, kind: Kind, title: String, started: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.started = started
    }
}

/// Lists and stops background work. An engine adopts it when it can report background shells or stop one subagent
/// without ending its parent's turn; the store checks with `as?`. Without it, Stop on a subagent interrupts the
/// subagent's session.
public protocol EngineBackgroundTasks: Sendable {
    /// Background shells and tasks running now, across the engine's sessions.
    func backgroundTasks() async throws -> [BackgroundTask]
    /// Ends one background shell or task.
    func stopBackgroundTask(_ task: BackgroundTask) async throws
    /// Ends one subagent. Its parent keeps going and hears that the subagent stopped.
    func stopSubagent(_ sessionID: String) async throws
}

/// One row of the background list.
public struct BackgroundWorkItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case subagent
        case shell
        case task
        /// A schedule's next run (Pause instead of Stop).
        case schedule
    }

    /// `subagent:<session id>`, `task:<task id>`, `schedule:<schedule id>` or `scheduled-task:<task id>`.
    public var id: String
    public var kind: Kind
    public var title: String
    /// The subagent's type ("general-purpose"), when the engine names it.
    public var detail: String?
    /// The session Open shows: the subagent itself, or the session that started a shell or task.
    public var openSessionID: String?
    /// The top-level session the row belongs to; nil for schedules.
    public var rootSessionID: String?
    /// When it started running (subagents, shells and tasks).
    public var started: Date?
    /// A schedule's next run.
    public var nextRun: Date?
    /// The engine task behind a shell or task row.
    public var task: BackgroundTask?
    /// An engine schedule (OpenCode's own).
    public var scheduleID: String?
    /// One of Ensemble's scheduled tasks (`TaskScheduler`): Pause pauses it, and it has Run now.
    public var scheduledTaskID: UUID?

    public init(id: String, kind: Kind, title: String, detail: String? = nil, openSessionID: String? = nil,
                rootSessionID: String? = nil, started: Date? = nil, nextRun: Date? = nil, task: BackgroundTask? = nil,
                scheduleID: String? = nil, scheduledTaskID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.openSessionID = openSessionID
        self.rootSessionID = rootSessionID
        self.started = started
        self.nextRun = nextRun
        self.task = task
        self.scheduleID = scheduleID
        self.scheduledTaskID = scheduledTaskID
    }

    /// Subagents, shells and tasks run now; a schedule only waits for its next run.
    public var isRunning: Bool { kind != .schedule }

    /// What the row's stop button says.
    public var stopLabel: String { kind == .schedule ? "Pause" : "Stop" }

    /// Tooltip for the row's stop button.
    public var stopHelp: String {
        switch kind {
        case .subagent: "Stop this subagent"
        case .shell: "Stop this command"
        case .task: "Stop this task"
        case .schedule: "Pause this schedule"
        }
    }
}

/// Rows that belong to one top-level session (its subagents and the shells it started), or the scheduled runs.
public struct BackgroundWorkGroup: Identifiable, Hashable, Sendable {
    public static let scheduledID = "scheduled"

    /// The top-level session id, or `scheduledID`.
    public var id: String
    public var title: String
    /// The room the session belongs to, or its folder name.
    public var subtitle: String?
    /// The room agent whose session this is (for its colour dot).
    public var agentID: UUID?
    public var items: [BackgroundWorkItem]

    public init(id: String, title: String, subtitle: String? = nil, agentID: UUID? = nil, items: [BackgroundWorkItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.agentID = agentID
        self.items = items
    }

    public var isScheduled: Bool { id == Self.scheduledID }
}

/// Sorting rules for the background list, kept apart from the store so they can be checked on their own.
public enum BackgroundWork {
    /// Groups rows by top-level session. Groups with the newest work come first; inside a group, subagents come before
    /// shells and tasks, each oldest first (the longest-running at the top). Scheduled runs come last, soonest first.
    /// `group` names each top-level session (title, subtitle, room agent).
    public static func groups(_ items: [BackgroundWorkItem],
                              group: (String) -> (title: String, subtitle: String?, agentID: UUID?)) -> [BackgroundWorkGroup] {
        let running = items.filter { $0.kind != .schedule }
        let byRoot = Dictionary(grouping: running) { $0.rootSessionID ?? "" }
        var result: [BackgroundWorkGroup] = byRoot.map { root, rows in
            let info = group(root)
            return BackgroundWorkGroup(id: root, title: info.title, subtitle: info.subtitle, agentID: info.agentID,
                                       items: rows.sorted(by: rowOrder))
        }
        result.sort { a, b in
            let newestA = a.items.compactMap(\.started).max() ?? .distantPast
            let newestB = b.items.compactMap(\.started).max() ?? .distantPast
            return newestA != newestB ? newestA > newestB : a.id < b.id
        }
        let scheduled = items.filter { $0.kind == .schedule }
            .sorted { ($0.nextRun ?? .distantFuture, $0.title) < ($1.nextRun ?? .distantFuture, $1.title) }
        if !scheduled.isEmpty {
            result.append(BackgroundWorkGroup(id: BackgroundWorkGroup.scheduledID, title: "Scheduled", items: scheduled))
        }
        return result
    }

    static func rowOrder(_ a: BackgroundWorkItem, _ b: BackgroundWorkItem) -> Bool {
        let rankA = a.kind == .subagent ? 0 : 1
        let rankB = b.kind == .subagent ? 0 : 1
        if rankA != rankB { return rankA < rankB }
        let startA = a.started ?? .distantFuture
        let startB = b.started ?? .distantFuture
        return startA != startB ? startA < startB : a.id < b.id
    }
}

/// Background work, plan limit stops and auto-continue state of one store. Held by `SessionStore.background`; the
/// logic lives in `SessionStore+Background.swift` and `AutoContinue+Store.swift`.
@Observable @MainActor
public final class SessionBackgroundState {
    /// Background shells and tasks the engines reported at the last refresh.
    public internal(set) var tasks: [BackgroundTask] = []
    /// Rows whose Stop (or Pause) is in flight, by row id.
    public internal(set) var stopping: Set<String> = []
    /// Schedules paused from the list, hidden until the store reloads its schedules.
    public internal(set) var pausedScheduleIDs: Set<String> = []
    /// Ensemble's scheduled tasks, listed with their next runs (set by the app when the scheduler starts).
    @ObservationIgnored public weak var scheduler: TaskScheduler?
    /// Plan limit stops, by the id of the transcript error row they replace (`AutoContinue.swift`).
    public internal(set) var limitStops: [String: UsageLimitStop] = [:]
    /// Bumped after every turn and every plan limit report, so the plan limit meter refreshes.
    public internal(set) var planLimitsRevision = 0

    /// The clock auto-continue reads. Tests set a fake one.
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }
    /// Auto-continue's own timer. Tests turn it off and call `checkAutoContinue()` themselves.
    @ObservationIgnored public var timerEnabled = true
    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var refreshing = false

    public init() {}
}
