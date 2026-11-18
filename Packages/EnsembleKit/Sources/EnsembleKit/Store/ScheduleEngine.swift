import Foundation
import Observation

/// What starts and follows scheduled runs. `SessionStore` is the real one (`ScheduleSessionRuns.swift`); tests use a
/// fake.
@MainActor
public protocol ScheduleRunner: AnyObject {
    /// Why a run of `task` must not start now (a spending cap, the continued session busy or gone), or nil.
    func scheduleRefusal(for task: ScheduledTask) -> String?
    /// Starts a run: a new session titled `title` (or the continued session), then sends the prompt.
    func startScheduledRun(_ task: ScheduledTask, title: String) async throws -> ScheduleRunStart
    /// What the run's session is doing now.
    func scheduledRunState(sessionID: String) -> ScheduleRunState
    /// Puts a continued session's own mode back after a run switched it to `applied`. Leaves it alone when its mode is
    /// no longer `applied` (someone changed it), unless `checkApplied` is false: after a relaunch the store may not
    /// know the engine's mode yet, and nobody can have changed it while Ensemble was closed. While the session works,
    /// only a restore that tightens the mode is made; one that would loosen it waits until the session is idle.
    func restoreScheduledMode(_ mode: PermissionMode, applied: PermissionMode, sessionID: String,
                              checkApplied: Bool) async -> ScheduleModeRestoreResult
}

/// The session a run started in.
public struct ScheduleRunStart: Equatable, Sendable {
    public var sessionID: String
    /// The continued session's mode before the run switched it to the task's mode, to put back afterwards.
    public var restoreMode: PermissionMode?

    public init(sessionID: String, restoreMode: PermissionMode? = nil) {
        self.sessionID = sessionID
        self.restoreMode = restoreMode
    }
}

/// Runs scheduled tasks inside Ensemble, on every engine, while the app is open.
///
/// - `check()` decides every active task with `SchedulePlanner` and starts what is due. It runs from a timer that
///   sleeps until the next scheduled time but never longer than a minute (so a sleep or a changed clock is noticed
///   within a minute), when the Mac wakes (`didWake()`), and once at start (runs missed while Ensemble was closed).
///   Ensemble never wakes the Mac to run a task.
/// - A task whose previous run is still going skips its next time (recorded as skipped).
/// - Runs are followed through the runner until they finish, fail or wait on you. A run counts as finished after its
///   session has been idle for `settleTime`, so a parent waiting for its subagents is not finished too early.
/// - A run that continues a session in another permission mode switches the session to the task's mode (engines keep
///   one mode per session, so there is no mode for a single turn) and puts the session's own mode back afterwards:
///   at once when that tightens the mode, else as soon as the session is idle, unless its mode was changed meanwhile.
///   The pending restore is saved with the run and finished at the next launch if Ensemble quits first. A run that
///   continues the same session before the restore keeps the original mode to put back.
@MainActor @Observable
public final class TaskScheduler {
    public private(set) var tasks: [ScheduledTask] = []
    /// Newest first, at most `historyLimit` per task.
    public private(set) var runs: [ScheduleRun] = []
    public private(set) var isLoaded = false
    /// The last problem reading or saving the file, in a line.
    public var lastError: String?

    @ObservationIgnored public let storage: any ScheduleStorage
    @ObservationIgnored public private(set) var runner: (any ScheduleRunner)?
    @ObservationIgnored public var now: () -> Date
    @ObservationIgnored public var calendar: Calendar
    /// False in tests and snapshots: nothing is scheduled or followed; checks and polls run only when called.
    @ObservationIgnored public var timerEnabled = true
    @ObservationIgnored public var watchInterval: Duration = .seconds(1)
    @ObservationIgnored public var settleTime: TimeInterval = 3
    /// Called when a run's session exists and the prompt was sent (the app keeps the Mac awake for it).
    @ObservationIgnored public var onRunStarted: ((ScheduledTask, ScheduleRun) -> Void)?
    /// Called when a followed run ends, whatever the outcome.
    @ObservationIgnored public var onRunEnded: ((ScheduledTask?, ScheduleRun) -> Void)?

    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored var watcher: Task<Void, Never>?
    @ObservationIgnored var idleSince: [UUID: Date] = [:]
    /// Tasks whose run is being started (between the decision and the session existing).
    @ObservationIgnored var starting: Set<UUID> = []
    /// Runs started by this launch. Active runs left from an earlier launch are resolved once at start.
    @ObservationIgnored var followed: Set<UUID> = []
    /// Restores being made right now, by run id.
    @ObservationIgnored var restoring: Set<UUID> = []
    /// When a failed restore is tried again, by run id.
    @ObservationIgnored var restoreRetryAt: [UUID: Date] = [:]
    /// Pending restores saved by an earlier launch (made without the "still in the applied mode" check).
    @ObservationIgnored var restoresFromEarlierLaunch: Set<UUID> = []
    /// How long after a failed restore it is tried again.
    @ObservationIgnored public var restoreRetryDelay: TimeInterval = 30

    public static let historyLimit = 50

    public init(storage: any ScheduleStorage, now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.storage = storage
        self.now = now
        self.calendar = calendar
    }

    // MARK: Lifecycle

    /// Reads the saved tasks and history.
    public func load() {
        do {
            let contents = try storage.load() ?? ScheduleFileContents()
            tasks = contents.tasks
            runs = contents.runs
        } catch {
            lastError = "Could not read the scheduled tasks: \(error.localizedDescription)"
        }
        isLoaded = true
    }

    /// Loads (once), resolves runs left from an earlier launch, starts what is due and keeps checking.
    public func start(runner: any ScheduleRunner) async {
        self.runner = runner
        if !isLoaded { load() }
        resolveLeftoverRuns()
        restoresFromEarlierLaunch = Set(runs.filter { $0.modeRestore == .pending && !followed.contains($0.id) }.map(\.id))
        await restorePendingModes()
        startWatching()
        await check()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Call when the Mac wakes: a time it slept through runs now (once), if it is within the task's catch-up window.
    @discardableResult
    public func didWake() async -> [ScheduleRun] {
        await check()
    }

    /// Fills the scheduler without saving or scheduling anything (previews and snapshots).
    public func seed(tasks: [ScheduledTask], runs: [ScheduleRun]) {
        self.tasks = tasks
        self.runs = runs.sorted { $0.started > $1.started }
        timerEnabled = false
        isLoaded = true
    }

    // MARK: Editing

    public func add(_ task: ScheduledTask) {
        var new = task
        new.checkedThrough = max(new.checkedThrough, now())
        tasks.append(new)
        persist()
        rescheduleTimer()
    }

    /// Saves an edited task. A new trigger, or resuming, starts counting from now, so old times never catch up.
    public func update(_ task: ScheduledTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let old = tasks[index]
        var updated = task
        updated.created = old.created
        if old.trigger != task.trigger || (old.paused && !task.paused) {
            updated.checkedThrough = now()
        } else {
            updated.checkedThrough = old.checkedThrough
        }
        tasks[index] = updated
        persist()
        rescheduleTimer()
    }

    /// Deletes the task and its history.
    public func delete(_ taskID: UUID) {
        tasks.removeAll { $0.id == taskID }
        runs.removeAll { $0.taskID == taskID }
        persist()
        rescheduleTimer()
    }

    /// Pause keeps the task and stops its runs. Resume starts from now: times that passed while paused do not run.
    public func setPaused(_ paused: Bool, taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].paused != paused else { return }
        tasks[index].paused = paused
        if !paused { tasks[index].checkedThrough = now() }
        persist()
        rescheduleTimer()
    }

    /// Runs the task now, whatever its schedule (paused tasks too). Nothing starts while its previous run is going.
    @discardableResult
    public func runNow(_ taskID: UUID) async -> ScheduleRun? {
        guard let task = task(taskID) else { return nil }
        let run = await startRun(task, reason: .manual, slot: nil)
        rescheduleTimer()
        return run
    }

    // MARK: Queries

    public func task(_ id: UUID) -> ScheduledTask? { tasks.first { $0.id == id } }

    public func runs(for taskID: UUID) -> [ScheduleRun] { runs.filter { $0.taskID == taskID } }

    /// The newest run of the task, whatever its outcome.
    public func lastRun(for taskID: UUID) -> ScheduleRun? { runs.first { $0.taskID == taskID } }

    /// The next time the task runs; nil when paused or when it never runs.
    public func nextRun(for task: ScheduledTask) -> Date? {
        guard !task.paused else { return nil }
        return task.trigger.nextFire(after: max(task.checkedThrough, now()), calendar: calendar)
    }

    /// True while a run of the task is starting, working or waiting on you.
    public func hasActiveRun(_ taskID: UUID) -> Bool {
        starting.contains(taskID) || runs.contains { $0.taskID == taskID && $0.status.isActive }
    }

    /// Tasks that are not paused (the sidebar count).
    public var activeTaskCount: Int { tasks.filter { !$0.paused }.count }

    // MARK: Checking

    /// Decides every active task and starts the runs that are due. Returns the runs it recorded (started or skipped).
    @discardableResult
    public func check() async -> [ScheduleRun] {
        guard isLoaded, runner != nil else { return [] }
        let current = now()
        var due: [(task: ScheduledTask, reason: ScheduleRunReason, slot: Date)] = []
        var recorded: [ScheduleRun] = []
        var changed = false
        for index in tasks.indices where !tasks[index].paused {
            let task = tasks[index]
            let decision = SchedulePlanner.decide(trigger: task.trigger, checkedThrough: task.checkedThrough, now: current,
                                                  catchUpWindow: task.catchUpWindow, calendar: calendar)
            switch decision {
            case .wait:
                continue
            case .run(let slot, let caughtUp, _):
                // Marked handled before anything awaits, so an overlapping check cannot start it twice.
                tasks[index].checkedThrough = current
                changed = true
                due.append((tasks[index], caughtUp ? .caughtUp : .scheduled, slot))
            case .missed(let slot):
                tasks[index].checkedThrough = current
                changed = true
                let run = ScheduleRun(taskID: task.id, reason: .scheduled, scheduledFor: slot, started: current, finished: current,
                                      status: .missed, message: Self.missedMessage(window: task.catchUpWindow))
                insert(run)
                recorded.append(run)
            }
        }
        if changed { persist() }
        for item in due {
            if let run = await startRun(item.task, reason: item.reason, slot: item.slot) { recorded.append(run) }
        }
        rescheduleTimer()
        return recorded
    }

    static func missedMessage(window: TimeInterval) -> String {
        if window < 1 { return "The Mac was asleep or Ensemble was closed at that time, and this task does not catch up." }
        return "The Mac was asleep or Ensemble was closed for longer than the catch-up window "
            + "(\(ScheduledTask.catchUpLabel(window).lowercased()))."
    }

    /// Records a run and starts it, unless its previous run is still going or the runner refuses.
    func startRun(_ task: ScheduledTask, reason: ScheduleRunReason, slot: Date?) async -> ScheduleRun? {
        guard let runner else { return nil }
        let started = now()
        var run = ScheduleRun(taskID: task.id, reason: reason, scheduledFor: slot, started: started)
        if hasActiveRun(task.id) {
            run.status = .skipped
            run.finished = started
            run.message = "The previous run was still going."
            insert(run)
            persist()
            return run
        }
        var refusal = runner.scheduleRefusal(for: task)
        if refusal == nil, let sessionID = task.continueSessionID,
           runs.contains(where: { $0.sessionID == sessionID && restoring.contains($0.id) }) {
            refusal = "The session it continues was busy."
        }
        if let refusal {
            run.status = .skipped
            run.finished = started
            run.message = refusal
            insert(run)
            persist()
            return run
        }
        // An earlier run's restore on the same session that has not happened yet: this run takes it over, so the
        // session's own mode is what goes back in the end. Marked first, so it is not made while this run starts.
        let earlier = task.continueSessionID.flatMap { id in runs.first { $0.sessionID == id && $0.modeRestore == .pending } }
        if let earlier { updateRun(earlier.id) { $0.modeRestore = .passedOn } }
        starting.insert(task.id)
        insert(run)
        followed.insert(run.id)
        persist()
        let title = ScheduleTitle.sessionTitle(taskName: task.name, date: started, calendar: calendar)
        do {
            let start = try await runner.startScheduledRun(task, title: title)
            starting.remove(task.id)
            var restoreMode = start.restoreMode
            if let earlier, let original = earlier.restoreMode {
                // The session was still in the earlier run's mode: its own mode is the earlier one's to put back.
                // Otherwise it was changed meanwhile and the earlier restore is dropped.
                if (start.restoreMode ?? task.permissionMode) == earlier.appliedMode {
                    restoreMode = original == task.permissionMode ? nil : original
                } else {
                    updateRun(earlier.id) { $0.modeRestore = .leftAlone }
                }
            }
            updateRun(run.id) { stored in
                stored.sessionID = start.sessionID
                stored.sessionTitle = task.continueSessionID == nil ? title : nil
                stored.restoreMode = restoreMode
                stored.appliedMode = restoreMode == nil ? nil : task.permissionMode
                stored.modeRestore = restoreMode == nil ? nil : .pending
            }
            if let stored = runs.first(where: { $0.id == run.id }) {
                run = stored
                onRunStarted?(task, stored)
            }
            startWatching()
        } catch {
            starting.remove(task.id)
            if let earlier { updateRun(earlier.id) { $0.modeRestore = .pending } }
            updateRun(run.id) { stored in
                stored.status = .failed
                stored.finished = self.now()
                stored.message = error.localizedDescription
            }
            run = runs.first(where: { $0.id == run.id }) ?? run
        }
        persist()
        return run
    }

    // MARK: Following runs

    func startWatching() {
        guard timerEnabled, watcher == nil, runs.contains(where: { $0.status.isActive }) || hasPendingRestores else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.pollActiveRuns()
                await self.restorePendingModes()
                guard active || self.hasPendingRestores else {
                    self.watcher = nil
                    return
                }
                try? await Task.sleep(for: self.watchInterval)
            }
        }
    }

    /// True while a finished run still has to put a session's mode back.
    public var hasPendingRestores: Bool {
        runs.contains { $0.modeRestore == .pending && !$0.status.isActive }
    }

    /// Tries every pending mode restore of a finished run once (skipping ones in flight or waiting to retry).
    public func restorePendingModes() async {
        guard let runner else { return }
        for run in runs where run.modeRestore == .pending && !run.status.isActive && !restoring.contains(run.id) {
            if let retry = restoreRetryAt[run.id], retry > now() { continue }
            guard let sessionID = run.sessionID, let mode = run.restoreMode, let applied = run.appliedMode else {
                updateRun(run.id) { $0.modeRestore = nil }
                continue
            }
            restoring.insert(run.id)
            let result = await runner.restoreScheduledMode(mode, applied: applied, sessionID: sessionID,
                                                           checkApplied: !restoresFromEarlierLaunch.contains(run.id))
            restoring.remove(run.id)
            // Another run may have taken the restore over while this one was in flight.
            guard runs.first(where: { $0.id == run.id })?.modeRestore == .pending else { continue }
            switch result {
            case .restored: updateRun(run.id) { $0.modeRestore = .restored }
            case .leftAlone: updateRun(run.id) { $0.modeRestore = .leftAlone }
            case .sessionGone: updateRun(run.id) { $0.modeRestore = .sessionGone }
            case .busy: continue
            case .failed:
                restoreRetryAt[run.id] = now().addingTimeInterval(restoreRetryDelay)
                continue
            }
            restoreRetryAt[run.id] = nil
            restoresFromEarlierLaunch.remove(run.id)
            persist()
        }
    }

    /// Updates every active run from its session. Returns true while any run is still active.
    @discardableResult
    public func pollActiveRuns() -> Bool {
        guard let runner else { return runs.contains { $0.status.isActive } }
        let current = now()
        var changed = false
        for index in runs.indices where runs[index].status.isActive {
            let run = runs[index]
            guard let sessionID = run.sessionID else { continue }
            switch runner.scheduledRunState(sessionID: sessionID) {
            case .working:
                idleSince[run.id] = nil
                if run.status != .running {
                    runs[index].status = .running
                    changed = true
                }
            case .needsYou:
                idleSince[run.id] = nil
                if run.status != .needsYou {
                    runs[index].status = .needsYou
                    changed = true
                }
            case .idle:
                let since = idleSince[run.id] ?? current
                idleSince[run.id] = since
                if current.timeIntervalSince(since) >= settleTime {
                    finish(index, status: .succeeded, message: nil)
                    changed = true
                }
            case .failed(let message):
                finish(index, status: .failed, message: message ?? "The run failed.")
                changed = true
            case .missing:
                finish(index, status: .unknown, message: "The session was deleted.")
                changed = true
            }
        }
        if changed { persist() }
        return runs.contains { $0.status.isActive }
    }

    private func finish(_ index: Int, status: ScheduleRunStatus, message: String?) {
        runs[index].status = status
        runs[index].finished = now()
        runs[index].message = message
        idleSince[runs[index].id] = nil
        let run = runs[index]
        onRunEnded?(task(run.taskID), run)
        // Its mode restore (if any) is made by the watcher, or by `restorePendingModes()`.
        if run.modeRestore == .pending { startWatching() }
    }

    /// Active runs saved by an earlier launch: still working ones are followed; the rest are marked unknown, because
    /// Ensemble was closed while they ran.
    func resolveLeftoverRuns() {
        guard let runner else { return }
        var changed = false
        for index in runs.indices where runs[index].status.isActive && !followed.contains(runs[index].id) {
            let run = runs[index]
            if let sessionID = run.sessionID {
                let state = runner.scheduledRunState(sessionID: sessionID)
                if state == .working || state == .needsYou {
                    followed.insert(run.id)
                    continue
                }
            }
            runs[index].status = .unknown
            runs[index].finished = runs[index].finished ?? now()
            runs[index].message = run.sessionID == nil
                ? "Ensemble was closed before the run started."
                : "Ensemble was closed while this run was going. Open the session to see how it ended."
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Timer

    /// Sleeps until the next scheduled time, never longer than a minute.
    func rescheduleTimer() {
        timer?.cancel()
        timer = nil
        guard timerEnabled, isLoaded else { return }
        let next = tasks.filter { !$0.paused }.compactMap { $0.trigger.nextFire(after: $0.checkedThrough, calendar: calendar) }.min()
        guard let next else { return }
        let delay = min(max(next.timeIntervalSince(now()), 0.5), 60)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            await self.check()
        }
    }

    // MARK: Storage

    private func insert(_ run: ScheduleRun) {
        runs.insert(run, at: 0)
        let ofTask = runs.indices.filter { runs[$0].taskID == run.taskID }
        if ofTask.count > Self.historyLimit {
            let drop = Set(ofTask.dropFirst(Self.historyLimit).map { runs[$0].id })
            runs.removeAll { drop.contains($0.id) && !$0.status.isActive }
        }
    }

    private func updateRun(_ id: UUID, _ change: (inout ScheduleRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
    }

    func persist() {
        do {
            try storage.save(ScheduleFileContents(tasks: tasks, runs: runs))
        } catch {
            lastError = "Could not save the scheduled tasks: \(error.localizedDescription)"
        }
    }
}
