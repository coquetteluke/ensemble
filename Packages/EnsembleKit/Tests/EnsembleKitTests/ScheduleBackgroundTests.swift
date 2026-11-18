import Foundation
import Testing
@testable import EnsembleKit

/// Ensemble's scheduled tasks in the background list: next runs, Run now and Pause.
@MainActor
@Suite("Scheduled tasks in the background list")
struct ScheduleBackgroundTests {
    @Test func activeTasksAreListedWithTheirNextRunAndRunNowAndPauseWork() async throws {
        let engine = RouterFakeEngine(name: "fake")
        let store = SessionStore(engine: engine)
        store.seed(StoreSeed(sessions: [EngineSession(id: "mine", title: "Mine", directory: "/tmp/project")], selectedSessionID: "mine"))
        store.background.timerEnabled = false
        let scheduler = TaskScheduler(storage: InMemoryScheduleStorage(), now: { Date() })
        scheduler.timerEnabled = false
        await scheduler.start(runner: store)
        store.background.scheduler = scheduler

        let nightly = ScheduledTask(name: "Nightly", prompt: "Run the tests", directory: "/tmp/project", trigger: .daily(hour: 3, minute: 0))
        let hourly = ScheduledTask(name: "Hourly", prompt: "Check the inbox", directory: "/tmp/project", trigger: .hourly(minute: 0))
        var paused = ScheduledTask(name: "Paused", prompt: "p", directory: "/tmp/project", trigger: .hourly(minute: 30))
        paused.paused = true
        for task in [nightly, hourly, paused] { scheduler.add(task) }

        let rows = store.backgroundItems.filter { $0.scheduledTaskID != nil }
        #expect(Set(rows.map(\.title)) == ["Nightly", "Hourly"])
        #expect(rows.allSatisfy { $0.kind == .schedule && !$0.isRunning && $0.nextRun != nil && $0.detail == "project" })
        #expect(store.backgroundRunningCount == 0, "scheduled rows are not counted as running")
        let group = try #require(store.backgroundWork().first { $0.isScheduled })
        #expect(group.items.first?.title == "Hourly", "soonest first")

        // Run now starts a run; the row then opens its session and Run now is off.
        let row = try #require(rows.first { $0.scheduledTaskID == hourly.id })
        await store.runScheduledTaskNow(row)
        let run = try #require(scheduler.lastRun(for: hourly.id))
        #expect(run.status == .running)
        let updated = try #require(store.backgroundItems.first { $0.scheduledTaskID == hourly.id })
        #expect(updated.openSessionID == run.sessionID)
        #expect(updated.detail == "Running")
        #expect(store.scheduledTaskIsRunning(updated))
        #expect(store.selectedSessionID == "mine")

        // Pause from the list pauses the task, and it leaves the list.
        await store.stopBackground(updated)
        #expect(scheduler.task(hourly.id)?.paused == true)
        #expect(!store.backgroundItems.contains { $0.scheduledTaskID == hourly.id })
        #expect(!engine.calls.contains { $0.hasPrefix("schedulePaused") })
    }
}
