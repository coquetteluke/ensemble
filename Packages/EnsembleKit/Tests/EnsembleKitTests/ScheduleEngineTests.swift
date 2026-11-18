import Foundation
import Testing
@testable import EnsembleKit

@Suite("Catch-up rules")
struct ScheduleCatchUpTests {
    let utc = ScheduleTestTime.calendar("UTC")
    let daily = ScheduleTrigger.daily(hour: 9, minute: 0)
    let window = ScheduledTask.defaultCatchUpWindow

    func decide(_ trigger: ScheduleTrigger, checked: Date, now: Date, window: TimeInterval? = nil) -> ScheduleDecision {
        SchedulePlanner.decide(trigger: trigger, checkedThrough: checked, now: now, catchUpWindow: window ?? self.window, calendar: utc)
    }

    @Test func waitsUntilTheTime() {
        let decision = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 18, 8), now: ScheduleTestTime.utc(2026, 11, 18, 8, 30))
        #expect(decision == .wait(next: ScheduleTestTime.utc(2026, 11, 18, 9)))
    }

    @Test func runsOnTimeWhenTheTimerFiresALittleLate() {
        let decision = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 18, 8, 59),
                              now: ScheduleTestTime.utc(2026, 11, 18, 9).addingTimeInterval(40))
        #expect(decision == .run(slot: ScheduleTestTime.utc(2026, 11, 18, 9), caughtUp: false, dropped: 0))
    }

    @Test func missedOnceRunsOnceMarkedCaughtUp() {
        // Asleep from 8:00 to 11:30.
        let decision = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 18, 8), now: ScheduleTestTime.utc(2026, 11, 18, 11, 30))
        #expect(decision == .run(slot: ScheduleTestTime.utc(2026, 11, 18, 9), caughtUp: true, dropped: 0))
    }

    @Test func missedManyRunsOnceForTheNewest() {
        // Hourly at :00, asleep from 1:10 to 5:20: 2:00, 3:00, 4:00 and 5:00 passed.
        let decision = decide(.hourly(minute: 0), checked: ScheduleTestTime.utc(2026, 11, 18, 1, 10),
                              now: ScheduleTestTime.utc(2026, 11, 18, 5, 20))
        #expect(decision == .run(slot: ScheduleTestTime.utc(2026, 11, 18, 5), caughtUp: true, dropped: 3))
        // The newest one is on time, so the run is ordinary even though older ones were dropped.
        let fresh = decide(.hourly(minute: 0), checked: ScheduleTestTime.utc(2026, 11, 18, 1, 10),
                           now: ScheduleTestTime.utc(2026, 11, 18, 5, 1))
        #expect(fresh == .run(slot: ScheduleTestTime.utc(2026, 11, 18, 5), caughtUp: false, dropped: 3))
    }

    @Test func outsideTheWindowNothingRunsAndTheNewestIsMissed() {
        // Closed for two days; the newest 9:00 passed 13 hours ago (window 12 hours).
        let decision = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 16, 8), now: ScheduleTestTime.utc(2026, 11, 18, 22))
        #expect(decision == .missed(slot: ScheduleTestTime.utc(2026, 11, 18, 9)))
        // Within a 24 hour window it runs.
        let wider = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 16, 8), now: ScheduleTestTime.utc(2026, 11, 18, 22),
                           window: 24 * 3600)
        #expect(wider == .run(slot: ScheduleTestTime.utc(2026, 11, 18, 9), caughtUp: true, dropped: 1))
    }

    @Test func withCatchUpOffOnlyOnTimeRunsHappen() {
        let late = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 18, 8), now: ScheduleTestTime.utc(2026, 11, 18, 9, 30), window: 0)
        #expect(late == .missed(slot: ScheduleTestTime.utc(2026, 11, 18, 9)))
        let onTime = decide(daily, checked: ScheduleTestTime.utc(2026, 11, 18, 8), now: ScheduleTestTime.utc(2026, 11, 18, 9, 2), window: 0)
        #expect(onTime == .run(slot: ScheduleTestTime.utc(2026, 11, 18, 9), caughtUp: false, dropped: 0))
    }

    @Test func anInvalidTriggerNeverRuns() {
        #expect(decide(.custom(cron: "bad"), checked: .distantPast, now: Date()) == .wait(next: nil))
    }
}

/// A clock tests move by hand.
@MainActor
final class ScheduleClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A runner that records what it was asked and reports the states the test sets.
@MainActor
final class FakeScheduleRunner: ScheduleRunner {
    var started: [(task: ScheduledTask, title: String)] = []
    var states: [String: ScheduleRunState] = [:]
    var refusal: String?
    var startError: (any Error)?
    var ended: [ScheduleRun] = []
    var restores: [(mode: PermissionMode, sessionID: String, checkApplied: Bool)] = []

    func scheduleRefusal(for task: ScheduledTask) -> String? { refusal }

    func startScheduledRun(_ task: ScheduledTask, title: String) async throws -> ScheduleRunStart {
        if let startError { throw startError }
        started.append((task, title))
        let id = "ses_\(started.count)"
        states[id] = .working
        return ScheduleRunStart(sessionID: id)
    }

    func scheduledRunState(sessionID: String) -> ScheduleRunState { states[sessionID] ?? .missing }

    func restoreScheduledMode(_ mode: PermissionMode, applied: PermissionMode, sessionID: String,
                              checkApplied: Bool) async -> ScheduleModeRestoreResult {
        restores.append((mode, sessionID, checkApplied))
        return .restored
    }
}

struct FakeStartError: Error, LocalizedError {
    var errorDescription: String? { "Gemini only runs in folders you trust." }
}

@MainActor
@Suite("Task scheduler")
struct TaskSchedulerTests {
    let utc = ScheduleTestTime.calendar("UTC")

    func make(at date: Date, storage: InMemoryScheduleStorage = InMemoryScheduleStorage())
        -> (TaskScheduler, ScheduleClock, FakeScheduleRunner) {
        let clock = ScheduleClock(date)
        let scheduler = TaskScheduler(storage: storage, now: { clock.now }, calendar: utc)
        scheduler.timerEnabled = false
        scheduler.settleTime = 3
        let runner = FakeScheduleRunner()
        scheduler.onRunEnded = { _, run in runner.ended.append(run) }
        return (scheduler, clock, runner)
    }

    func task(_ trigger: ScheduleTrigger = .daily(hour: 9, minute: 0), at date: Date, name: String = "Morning triage") -> ScheduledTask {
        ScheduledTask(name: name, prompt: "Look at new issues", directory: "/tmp/project", trigger: trigger, created: date)
    }

    @Test func aTaskFiresWhenItsTimeComes() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 8, 59)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        scheduler.add(task(at: start))
        #expect(await scheduler.check().isEmpty)

        clock.advance(61)
        let runs = await scheduler.check()
        #expect(runs.count == 1)
        #expect(runner.started.count == 1)
        #expect(runner.started.first?.title.hasPrefix("Morning triage, Nov 18") == true)
        let run = scheduler.runs.first
        #expect(run?.reason == .scheduled)
        #expect(run?.scheduledFor == ScheduleTestTime.utc(2026, 11, 18, 9))
        #expect(run?.sessionID == "ses_1")
        #expect(run?.sessionTitle == runner.started.first?.title)
        #expect(run?.status == .running)
        // The same time never runs twice.
        clock.advance(30)
        #expect(await scheduler.check().isEmpty)
        #expect(scheduler.nextRun(for: scheduler.tasks[0]) == ScheduleTestTime.utc(2026, 11, 19, 9))
    }

    @Test func runsAreFollowedToTheirOutcome() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 9)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        let first = task(.hourly(minute: 0), at: start, name: "Hourly")
        scheduler.add(first)
        _ = await scheduler.runNow(first.id)
        let sessionID = scheduler.runs[0].sessionID ?? ""

        runner.states[sessionID] = .needsYou
        #expect(scheduler.pollActiveRuns())
        #expect(scheduler.runs[0].status == .needsYou)

        runner.states[sessionID] = .idle
        scheduler.pollActiveRuns()
        #expect(scheduler.runs[0].status == .needsYou, "idle has to last the settle time first")
        clock.advance(4)
        #expect(!scheduler.pollActiveRuns())
        #expect(scheduler.runs[0].status == .succeeded)
        #expect(scheduler.runs[0].finished == clock.now)
        #expect(runner.ended.map(\.id) == [scheduler.runs[0].id])

        _ = await scheduler.runNow(first.id)
        runner.states[scheduler.runs[0].sessionID ?? ""] = .failed("Model unavailable: openai/gpt-5.1")
        scheduler.pollActiveRuns()
        #expect(scheduler.runs[0].status == .failed)
        #expect(scheduler.runs[0].message == "Model unavailable: openai/gpt-5.1")

        _ = await scheduler.runNow(first.id)
        runner.states[scheduler.runs[0].sessionID ?? ""] = .missing
        scheduler.pollActiveRuns()
        #expect(scheduler.runs[0].status == .unknown)
        #expect(scheduler.runs[0].message == "The session was deleted.")
    }

    @Test func aSleptThroughTimeRunsOnceOnWake() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 1, 10)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        scheduler.add(task(.hourly(minute: 0), at: start, name: "Hourly"))
        // Asleep until 5:20: 2:00, 3:00, 4:00 and 5:00 were missed.
        clock.now = ScheduleTestTime.utc(2026, 11, 18, 5, 20)
        let runs = await scheduler.didWake()
        #expect(runs.count == 1)
        #expect(runner.started.count == 1)
        #expect(scheduler.runs[0].reason == .caughtUp)
        #expect(scheduler.runs[0].scheduledFor == ScheduleTestTime.utc(2026, 11, 18, 5))
        #expect(await scheduler.didWake().isEmpty)
    }

    @Test func aTimeOutsideTheWindowIsRecordedAsMissed() async {
        let start = ScheduleTestTime.utc(2026, 11, 16, 8)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        scheduler.add(task(at: start))
        clock.now = ScheduleTestTime.utc(2026, 11, 18, 22)
        let runs = await scheduler.didWake()
        #expect(runner.started.isEmpty)
        #expect(runs.map(\.status) == [.missed])
        #expect(scheduler.runs[0].scheduledFor == ScheduleTestTime.utc(2026, 11, 18, 9))
        #expect(scheduler.runs[0].message?.contains("12 hours") == true)
        #expect(await scheduler.check().isEmpty, "a missed time is recorded once")
    }

    @Test func pausedTasksDoNotRunAndResumeDoesNotCatchUp() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 8)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        let morning = task(at: start)
        scheduler.add(morning)
        scheduler.setPaused(true, taskID: morning.id)
        #expect(scheduler.nextRun(for: scheduler.tasks[0]) == nil)
        #expect(scheduler.activeTaskCount == 0)

        clock.now = ScheduleTestTime.utc(2026, 11, 18, 10)
        #expect(await scheduler.check().isEmpty)
        scheduler.setPaused(false, taskID: morning.id)
        #expect(await scheduler.check().isEmpty, "9:00 passed while paused")
        #expect(runner.started.isEmpty)
        #expect(scheduler.nextRun(for: scheduler.tasks[0]) == ScheduleTestTime.utc(2026, 11, 19, 9))

        // Run now works while paused.
        scheduler.setPaused(true, taskID: morning.id)
        let run = await scheduler.runNow(morning.id)
        #expect(run?.reason == .manual)
        #expect(run?.scheduledFor == nil)
        #expect(runner.started.count == 1)
    }

    @Test func changingTheTriggerDoesNotCatchUpOldTimes() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 8)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        var morning = task(at: start)
        scheduler.add(morning)
        clock.now = ScheduleTestTime.utc(2026, 11, 18, 8, 30)
        morning.trigger = .daily(hour: 7, minute: 0)
        morning.name = "Earlier"
        scheduler.update(morning)
        #expect(scheduler.tasks[0].checkedThrough == clock.now)
        #expect(scheduler.tasks[0].name == "Earlier")
        clock.now = ScheduleTestTime.utc(2026, 11, 18, 9, 30)
        #expect(await scheduler.check().isEmpty)
        #expect(runner.started.isEmpty)
    }

    @Test func aRunStillGoingSkipsTheNextTime() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 8, 59)
        let (scheduler, clock, runner) = make(at: start)
        await scheduler.start(runner: runner)
        scheduler.add(task(.hourly(minute: 0), at: start, name: "Hourly"))
        clock.advance(61)
        await scheduler.check()
        clock.advance(3600)
        let second = await scheduler.check()
        #expect(runner.started.count == 1)
        #expect(second.map(\.status) == [.skipped])
        #expect(second.first?.message == "The previous run was still going.")
        #expect(scheduler.hasActiveRun(scheduler.tasks[0].id))
    }

    @Test func refusalsAndStartFailuresAreRecorded() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 9)
        let (scheduler, _, runner) = make(at: start)
        await scheduler.start(runner: runner)
        let morning = task(at: start)
        scheduler.add(morning)

        runner.refusal = "OpenAI reached its daily spending cap."
        let skipped = await scheduler.runNow(morning.id)
        #expect(skipped?.status == .skipped)
        #expect(skipped?.message == "OpenAI reached its daily spending cap.")

        runner.refusal = nil
        runner.startError = FakeStartError()
        let failed = await scheduler.runNow(morning.id)
        #expect(failed?.status == .failed)
        #expect(failed?.message == "Gemini only runs in folders you trust.")
        #expect(!scheduler.hasActiveRun(morning.id))
        #expect(runner.started.isEmpty)
    }

    @Test func tasksAndHistorySurviveARestart() async throws {
        let storage = InMemoryScheduleStorage()
        let start = ScheduleTestTime.utc(2026, 11, 18, 9)
        let (scheduler, clock, runner) = make(at: start, storage: storage)
        await scheduler.start(runner: runner)
        let morning = task(.weekly(days: [.monday, .thursday], hour: 9, minute: 0), at: start)
        scheduler.add(morning)
        _ = await scheduler.runNow(morning.id)
        let saved = try #require(storage.saved)
        #expect(saved.tasks == scheduler.tasks)
        #expect(saved.runs.count == 1)

        // Ensemble quits while the run is going; the next launch cannot know how it ended.
        clock.advance(600)
        let (reopened, _, newRunner) = make(at: clock.now, storage: storage)
        newRunner.states["ses_1"] = .idle
        await reopened.start(runner: newRunner)
        #expect(reopened.tasks == scheduler.tasks)
        #expect(reopened.runs.first?.status == .unknown)
        #expect(reopened.runs.first?.message?.contains("Ensemble was closed") == true)

        // A run that is still working after the restart is followed.
        let (again, _, thirdRunner) = make(at: clock.now, storage: InMemoryScheduleStorage(ScheduleFileContents(
            tasks: [morning], runs: [ScheduleRun(taskID: morning.id, reason: .manual, started: start, sessionID: "ses_live")]
        )))
        thirdRunner.states["ses_live"] = .working
        await again.start(runner: thirdRunner)
        #expect(again.runs.first?.status == .running)
    }

    @Test func theFileRoundTripsThroughJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-schedules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = ScheduleFileStorage(url: folder.appendingPathComponent("schedules.json"))
        let created = Date(timeIntervalSince1970: 1_795_000_000.5)
        var morning = ScheduledTask(name: "Nightly", prompt: "Run the tests", directory: "/tmp/p",
                                    model: ModelRef(providerID: "openai", id: "gpt-5.5"), permissionMode: .bypass,
                                    trigger: .custom(cron: "0 3 * * *"), created: created)
        morning.continueSessionID = "ses_x"
        let contents = ScheduleFileContents(tasks: [morning], runs: [
            ScheduleRun(taskID: morning.id, reason: .caughtUp, scheduledFor: created, started: created, finished: created,
                        status: .succeeded, sessionID: "ses_x", message: nil),
        ])
        try storage.save(contents)
        #expect(try storage.load() == contents)
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // A broken file is moved aside, not overwritten later.
        try Data("not json".utf8).write(to: storage.url)
        #expect(throws: (any Error).self) { try storage.load() }
        #expect(!FileManager.default.fileExists(atPath: storage.url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(kept.contains { $0.hasPrefix("schedules.unreadable-") })
    }

    @Test func planModeAndUnknownModesFallBackToAsk() throws {
        let json = #"{"id":"6A1C1E0B-4B4E-4E0C-9C1A-000000000009","name":"x","prompt":"p","directory":"/tmp","permissionMode":"plan"}"#
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        #expect(decoded.permissionMode == .ask)
        #expect(decoded.catchUpWindow == ScheduledTask.defaultCatchUpWindow)
        #expect(decoded.trigger == .default)
    }

    @Test func deletingATaskDropsItsHistoryAndHistoryIsCapped() async {
        let start = ScheduleTestTime.utc(2026, 11, 18, 9)
        let (scheduler, _, runner) = make(at: start)
        await scheduler.start(runner: runner)
        let morning = task(at: start)
        let other = task(at: start, name: "Other")
        scheduler.add(morning)
        scheduler.add(other)
        runner.refusal = "busy"
        for _ in 0..<(TaskScheduler.historyLimit + 5) { _ = await scheduler.runNow(morning.id) }
        _ = await scheduler.runNow(other.id)
        #expect(scheduler.runs(for: morning.id).count == TaskScheduler.historyLimit)
        scheduler.delete(morning.id)
        #expect(scheduler.runs.count == 1)
        #expect(scheduler.tasks.map(\.id) == [other.id])
    }

    @Test func validationNamesWhatIsMissing() {
        var draft = ScheduledTask(name: "", prompt: "", directory: "")
        #expect(draft.validationError() == "Give the task a name.")
        draft.name = "Nightly"
        #expect(draft.validationError() == "Write the prompt to send.")
        draft.prompt = "Run the tests"
        #expect(draft.validationError() == "Choose a folder.")
        draft.continueSessionID = "ses_1"
        #expect(draft.validationError() == nil)
        draft.trigger = .weekly(days: [], hour: 9, minute: 0)
        #expect(draft.validationError() == "Choose at least one day.")
        #expect(ScheduledTask.catchUpLabel(0) == "Never")
        #expect(ScheduledTask.catchUpLabel(12 * 3600) == "Within 12 hours")
        #expect(ScheduledTask.catchUpLabel(7 * 86_400) == "Within 7 days")
    }
}
