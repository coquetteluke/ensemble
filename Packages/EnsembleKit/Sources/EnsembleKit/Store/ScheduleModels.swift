import Foundation

// Scheduled tasks run inside Ensemble (not through OpenCode's experimental schedules), so they work on every engine:
// Claude, Gemini and OpenCode. They run only while Ensemble is open. Saved in
// `~/Library/Application Support/Ensemble/schedules.json` (`ScheduleFileStorage`).

/// A prompt Ensemble sends on a schedule.
public struct ScheduledTask: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// The project folder new sessions open in.
    public var directory: String
    /// Nil uses the default model at run time.
    public var model: ModelRef?
    /// Ask by default; Bypass only after the editor's warning.
    public var permissionMode: PermissionMode
    public var trigger: ScheduleTrigger
    /// Nil starts a new session for every run; otherwise every run continues this session.
    public var continueSessionID: String?
    public var paused: Bool
    /// A run missed by less than this (the Mac slept, or Ensemble was closed) runs once when Ensemble is back.
    /// 0 never catches up.
    public var catchUpWindow: TimeInterval
    /// Keeps the Mac awake while a run works (Ensemble's own keep-awake, released when the run ends).
    public var keepAwake: Bool
    public var created: Date
    /// Every scheduled time up to here has been handled (run, skipped or missed). Moves on with every check, and to
    /// the present on resume or when the trigger changes, so those never catch up on old times.
    public var checkedThrough: Date

    public static let defaultCatchUpWindow: TimeInterval = 12 * 3600
    /// The catch-up choices the editor offers.
    public static let catchUpChoices: [TimeInterval] = [0, 3600, 4 * 3600, 12 * 3600, 24 * 3600, 7 * 24 * 3600]
    /// Modes a scheduled task may use (Plan mode needs someone to approve the plan).
    public static let permissionModes: [PermissionMode] = [.ask, .acceptEdits, .auto, .bypass]

    public init(id: UUID = UUID(), name: String, prompt: String, directory: String, model: ModelRef? = nil,
                permissionMode: PermissionMode = .ask, trigger: ScheduleTrigger = .default, continueSessionID: String? = nil,
                paused: Bool = false, catchUpWindow: TimeInterval = ScheduledTask.defaultCatchUpWindow, keepAwake: Bool = true,
                created: Date = Date(), checkedThrough: Date? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.directory = directory
        self.model = model
        self.permissionMode = permissionMode
        self.trigger = trigger
        self.continueSessionID = continueSessionID
        self.paused = paused
        self.catchUpWindow = catchUpWindow
        self.keepAwake = keepAwake
        self.created = created
        self.checkedThrough = checkedThrough ?? created
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, directory, model, permissionMode, trigger, continueSessionID, paused, catchUpWindow, keepAwake
        case created, checkedThrough
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Scheduled task"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
        model = try c.decodeIfPresent(ModelRef.self, forKey: .model)
        // An unknown mode in the file falls back to Ask, never to something more permissive.
        let mode = (try? c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)) ?? .ask
        permissionMode = Self.permissionModes.contains(mode) ? mode : .ask
        trigger = try c.decodeIfPresent(ScheduleTrigger.self, forKey: .trigger) ?? .default
        continueSessionID = try c.decodeIfPresent(String.self, forKey: .continueSessionID)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        catchUpWindow = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .catchUpWindow) ?? Self.defaultCatchUpWindow)
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        checkedThrough = try c.decodeIfPresent(Date.self, forKey: .checkedThrough) ?? created
    }

    /// Why the task cannot be saved, or nil.
    public func validationError(calendar: Calendar = .current, now: Date = Date()) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the task a name." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write the prompt to send." }
        if continueSessionID == nil, directory.isEmpty { return "Choose a folder." }
        if !Self.permissionModes.contains(permissionMode) { return "Plan mode cannot be used for scheduled tasks." }
        return trigger.validationError(calendar: calendar, now: now)
    }

    /// "Within 12 hours", "Never" for the catch-up choice.
    public static func catchUpLabel(_ window: TimeInterval) -> String {
        switch window {
        case ..<1: "Never"
        case ..<7200: "Within 1 hour"
        case ..<(48 * 3600): "Within \(Int((window / 3600).rounded())) hours"
        default: "Within \(Int((window / 86_400).rounded())) days"
        }
    }
}

/// Why a run started.
public enum ScheduleRunReason: String, Codable, Hashable, Sendable {
    /// At its time.
    case scheduled
    /// Once, after the Mac slept through its time or Ensemble was closed.
    case caughtUp
    /// Run now.
    case manual
}

public enum ScheduleRunStatus: String, Codable, Hashable, Sendable {
    /// The agent is working.
    case running
    /// The agent waits on a permission prompt, a plan or a question.
    case needsYou
    case succeeded
    case failed
    /// Not started: the previous run was still going, a spending cap was reached, or the session it continues was
    /// busy or deleted.
    case skipped
    /// Its time passed longer ago than the catch-up window, so it did not run.
    case missed
    /// Ensemble was closed while it ran, so how it ended is not known.
    case unknown

    /// Still going (running or waiting on you).
    public var isActive: Bool { self == .running || self == .needsYou }

    public var label: String {
        switch self {
        case .running: "Running"
        case .needsYou: "Needs you"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .missed: "Missed"
        case .unknown: "Result unknown"
        }
    }
}

/// One run of a scheduled task, for its history.
public struct ScheduleRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var reason: ScheduleRunReason
    /// The scheduled time it ran for (nil for Run now).
    public var scheduledFor: Date?
    public var started: Date
    public var finished: Date?
    public var status: ScheduleRunStatus
    /// The session it ran in.
    public var sessionID: String?
    /// The session's title when the run started.
    public var sessionTitle: String?
    /// Why it failed, was skipped or missed.
    public var message: String?
    /// A continued session's own mode, put back after the run if the session is still in `appliedMode`.
    public var restoreMode: PermissionMode?
    /// The task's mode the run switched the continued session to.
    public var appliedMode: PermissionMode?
    /// Where putting `restoreMode` back stands; nil when the run did not switch a mode.
    public var modeRestore: ScheduleModeRestore?

    public init(id: UUID = UUID(), taskID: UUID, reason: ScheduleRunReason, scheduledFor: Date? = nil, started: Date,
                finished: Date? = nil, status: ScheduleRunStatus = .running, sessionID: String? = nil, sessionTitle: String? = nil,
                message: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.reason = reason
        self.scheduledFor = scheduledFor
        self.started = started
        self.finished = finished
        self.status = status
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.message = message
    }

    /// How long it ran, once finished.
    public var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
}

/// Putting a continued session's own permission mode back after a run switched it to the task's mode. Saved with the
/// run, so a restore still waiting when Ensemble quits happens at the next launch.
public enum ScheduleModeRestore: String, Codable, Hashable, Sendable {
    /// Still to do: the run is going, the session was busy (and the restore would loosen its mode), or the engine
    /// refused and it is retried.
    case pending
    case restored
    /// The session's mode was changed by you (or another run) meanwhile, so it was left as it is.
    case leftAlone
    /// A later run of a task on the same session took the restore over (its own restore puts this mode back).
    case passedOn
    /// The session was deleted.
    case sessionGone
}

/// What one attempt to put a mode back did (`ScheduleRunner.restoreScheduledMode`).
public enum ScheduleModeRestoreResult: Equatable, Sendable {
    case restored
    case leftAlone
    case sessionGone
    /// The session works and the restore would loosen its mode; tried again once it is idle.
    case busy
    /// The engine did not take the change; tried again later.
    case failed
}

extension PermissionMode {
    /// How much a mode allows without asking, for comparing modes: Plan, Ask, Accept edits, Auto, Bypass.
    public var looseness: Int {
        switch self {
        case .plan: 0
        case .ask: 1
        case .acceptEdits: 2
        case .auto: 3
        case .bypass: 4
        }
    }
}

/// What a run's session is doing (`ScheduleRunner.scheduledRunState`).
public enum ScheduleRunState: Equatable, Sendable {
    case working
    case needsYou
    case idle
    /// The last turn failed, with the error shown in the transcript.
    case failed(String?)
    /// The session is gone.
    case missing
}

/// The schedules file.
public struct ScheduleFileContents: Codable, Equatable, Sendable {
    public var version: Int
    public var tasks: [ScheduledTask]
    /// Newest first.
    public var runs: [ScheduleRun]

    public init(version: Int = 1, tasks: [ScheduledTask] = [], runs: [ScheduleRun] = []) {
        self.version = version
        self.tasks = tasks
        self.runs = runs
    }
}

/// Session titles for runs: "Morning triage, Nov 18, 9:00 AM".
public enum ScheduleTitle {
    public static func sessionTitle(taskName: String, date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Scheduled task" : name) + ", " + formatter.string(from: date)
    }
}
