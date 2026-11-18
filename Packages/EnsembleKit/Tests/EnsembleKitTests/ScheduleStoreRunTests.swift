import Foundation
import Testing
@testable import EnsembleKit

/// Scheduled runs through the real store, on a fake engine.
@MainActor
@Suite("Scheduled runs in the store")
struct ScheduleStoreRunTests {
    static let directory = "/tmp/project"

    func makeStore() -> (SessionStore, RouterFakeEngine) {
        let engine = RouterFakeEngine(name: "fake")
        let store = SessionStore(engine: engine)
        store.seed(StoreSeed(sessions: [
            EngineSession(id: "mine", title: "What I am working on", directory: Self.directory),
            EngineSession(id: "daily", title: "Daily notes", directory: Self.directory,
                          model: ModelRef(providerID: "openai", id: "gpt-5.5")),
        ], modes: ["daily": .auto], selectedSessionID: "mine"))
        store.background.timerEnabled = false
        return (store, engine)
    }

    @Test func aRunStartsANewTitledSessionWithoutTakingTheScreen() async throws {
        let (store, engine) = makeStore()
        let task = ScheduledTask(name: "Nightly", prompt: "Run the tests", directory: Self.directory,
                                 model: ModelRef(providerID: "mock", id: "mock-1"), permissionMode: .ask)
        let start = try await store.startScheduledRun(task, title: "Nightly, Nov 18, 3:00 AM")
        let session = try #require(store.session(start.sessionID))
        #expect(session.title == "Nightly, Nov 18, 3:00 AM")
        #expect(session.permissionMode == .ask)
        #expect(session.info.model == ModelRef(providerID: "mock", id: "mock-1"))
        #expect(store.selectedSessionID == "mine")
        #expect(start.restoreMode == nil)
        let calls = engine.calls
        #expect(calls.contains("create:mock/mock-1:nil"))
        #expect(calls.contains("rename:\(start.sessionID)"))
        #expect(calls.contains("prompt:\(start.sessionID)"))
        if case .user(_, let text, _) = session.items.first { #expect(text == "Run the tests") } else { Issue.record("no prompt shown") }

        // The run is followed through the session's state.
        #expect(store.scheduledRunState(sessionID: start.sessionID) == .working)
        store.apply(.permissionAsked(PermissionRequest(id: "p1", sessionID: start.sessionID, kind: "edit", title: "a.txt")))
        #expect(store.scheduledRunState(sessionID: start.sessionID) == .needsYou)
        store.apply(.permissionReplied(sessionID: start.sessionID, requestID: "p1"))
        store.apply(.executionEnded(sessionID: start.sessionID, outcome: "succeeded", error: nil))
        #expect(store.scheduledRunState(sessionID: start.sessionID) == .idle)
        store.apply(.executionEnded(sessionID: start.sessionID, outcome: "failed", error: "Model unavailable"))
        #expect(store.scheduledRunState(sessionID: start.sessionID) == .failed("Model unavailable"))
        #expect(store.scheduledRunState(sessionID: "gone") == .missing)
    }

    @Test func continuingASessionUsesTheTaskModeAndPutsItsOwnBack() async throws {
        let (store, engine) = makeStore()
        var task = ScheduledTask(name: "Notes", prompt: "Add today's notes", directory: Self.directory, permissionMode: .ask)
        task.continueSessionID = "daily"
        #expect(store.scheduleRefusal(for: task) == nil)
        let start = try await store.startScheduledRun(task, title: "unused")
        #expect(start.sessionID == "daily")
        #expect(start.restoreMode == .auto)
        #expect(store.session("daily")?.permissionMode == .ask)
        #expect(store.session("daily")?.title == "Daily notes")
        #expect(engine.calls.contains("mode:daily"))
        #expect(!engine.calls.contains { $0.hasPrefix("create:") })

        // Busy while its turn runs.
        #expect(store.scheduleRefusal(for: task) == "The session it continues was busy.")
        store.apply(.executionEnded(sessionID: "daily", outcome: "succeeded", error: nil))

        #expect(await store.restoreScheduledMode(.auto, applied: .ask, sessionID: "daily", checkApplied: true) == .restored)
        #expect(store.session("daily")?.permissionMode == .auto)
        #expect(await store.restoreScheduledMode(.auto, applied: .ask, sessionID: "gone", checkApplied: true) == .sessionGone)

        task.continueSessionID = "deleted"
        #expect(store.scheduleRefusal(for: task) == "The session it continues was deleted.")
        await #expect(throws: ScheduleRunError.sessionGone) { try await store.startScheduledRun(task, title: "x") }
    }

    // MARK: Putting the session's own mode back

    /// A scheduler on the store with a hand-moved clock and no timers; runs count as finished at the first idle look.
    func makeScheduler(_ store: SessionStore, storage: InMemoryScheduleStorage = InMemoryScheduleStorage())
        async -> TaskScheduler {
        let scheduler = TaskScheduler(storage: storage, now: { Date() })
        scheduler.timerEnabled = false
        scheduler.settleTime = 0
        await scheduler.start(runner: store)
        return scheduler
    }

    func continuing(_ mode: PermissionMode, name: String = "Notes") -> ScheduledTask {
        var task = ScheduledTask(name: name, prompt: "Add today's notes", directory: Self.directory, permissionMode: mode,
                                 trigger: .daily(hour: 3, minute: 0))
        task.continueSessionID = "daily"
        return task
    }

    /// Ends the session's turn and lets the scheduler see it.
    func endTurn(_ store: SessionStore, _ scheduler: TaskScheduler) {
        store.apply(.executionEnded(sessionID: "daily", outcome: "succeeded", error: nil))
        scheduler.pollActiveRuns()
    }

    @Test func aLooserModeComesBackOnlyOnceTheSessionIsIdle() async throws {
        let (store, _) = makeStore()
        let scheduler = await makeScheduler(store)
        let task = continuing(.ask)
        scheduler.add(task)
        let run = try #require(await scheduler.runNow(task.id))
        #expect(run.restoreMode == .auto)
        #expect(run.appliedMode == .ask)
        #expect(run.modeRestore == .pending)
        endTurn(store, scheduler)
        #expect(scheduler.runs[0].status == .succeeded)
        #expect(scheduler.hasPendingRestores)

        // You send something before the restore: Auto (looser than Ask) waits until that turn ends.
        await store.send("One more thing", to: "daily")
        await scheduler.restorePendingModes()
        #expect(scheduler.runs[0].modeRestore == .pending)
        #expect(store.session("daily")?.permissionMode == .ask)

        store.apply(.executionEnded(sessionID: "daily", outcome: "succeeded", error: nil))
        await scheduler.restorePendingModes()
        #expect(scheduler.runs[0].modeRestore == .restored)
        #expect(store.session("daily")?.permissionMode == .auto)
        #expect(!scheduler.hasPendingRestores)
    }

    @Test func aTighterModeComesBackAtOnceEvenWhileBusy() async throws {
        let (store, engine) = makeStore()
        store.session("daily")?.permissionMode = .ask
        let scheduler = await makeScheduler(store)
        let task = continuing(.bypass, name: "Cleanup")
        scheduler.add(task)
        _ = await scheduler.runNow(task.id)
        #expect(store.session("daily")?.permissionMode == .bypass)
        endTurn(store, scheduler)
        await store.send("Now tidy the README", to: "daily")
        #expect(store.isRunning("daily"))

        // Bypass must not carry over into your turn: Ask comes back while it runs.
        await scheduler.restorePendingModes()
        #expect(scheduler.runs[0].modeRestore == .restored)
        #expect(store.session("daily")?.permissionMode == .ask)
        #expect(engine.calls.filter { $0 == "mode:daily" }.count == 2)
    }

    @Test func aModeYouChangedMeanwhileIsLeftAlone() async throws {
        let (store, _) = makeStore()
        let scheduler = await makeScheduler(store)
        let task = continuing(.ask)
        scheduler.add(task)
        _ = await scheduler.runNow(task.id)
        endTurn(store, scheduler)
        await store.send("Keep going", to: "daily")
        await scheduler.restorePendingModes()
        #expect(scheduler.runs[0].modeRestore == .pending)

        await store.setPermissionMode(.acceptEdits, for: "daily")
        store.apply(.executionEnded(sessionID: "daily", outcome: "succeeded", error: nil))
        await scheduler.restorePendingModes()
        #expect(scheduler.runs[0].modeRestore == .leftAlone)
        #expect(store.session("daily")?.permissionMode == .acceptEdits)
    }

    @Test func aPendingRestoreIsMadeAtTheNextLaunch() async throws {
        let storage = InMemoryScheduleStorage()
        let (store, _) = makeStore()
        let scheduler = await makeScheduler(store, storage: storage)
        let task = continuing(.ask)
        scheduler.add(task)
        _ = await scheduler.runNow(task.id)
        endTurn(store, scheduler)
        await store.send("Keep going", to: "daily")
        await scheduler.restorePendingModes()
        #expect(storage.saved?.runs.first?.modeRestore == .pending)
        scheduler.stop()

        // Next launch: the session's mode in the store is only a guess, and differs from the run's mode.
        let engine = RouterFakeEngine(name: "fake")
        let relaunched = SessionStore(engine: engine)
        relaunched.defaultPermissionMode = .acceptEdits
        relaunched.seed(StoreSeed(sessions: [EngineSession(id: "daily", title: "Daily notes", directory: Self.directory)]))
        relaunched.background.timerEnabled = false
        let reopened = await makeScheduler(relaunched, storage: storage)
        #expect(reopened.runs.first?.modeRestore == .restored)
        #expect(relaunched.session("daily")?.permissionMode == .auto)
        #expect(engine.calls.contains("mode:daily"))
        #expect(storage.saved?.runs.first?.modeRestore == .restored)
    }

    @Test func aSecondRunBeforeTheRestoreKeepsTheOriginalMode() async throws {
        let (store, _) = makeStore()
        let scheduler = await makeScheduler(store)
        let task = continuing(.ask)
        scheduler.add(task)
        _ = await scheduler.runNow(task.id)
        endTurn(store, scheduler)
        let firstID = scheduler.runs[0].id

        // The next run starts before the watcher put Auto back: it takes the restore over.
        let second = try #require(await scheduler.runNow(task.id))
        #expect(scheduler.runs.first { $0.id == firstID }?.modeRestore == .passedOn)
        #expect(second.restoreMode == .auto)
        #expect(second.modeRestore == .pending)
        endTurn(store, scheduler)
        await scheduler.restorePendingModes()
        #expect(store.session("daily")?.permissionMode == .auto)
        #expect(scheduler.runs.first { $0.id == second.id }?.modeRestore == .restored)
    }

    @Test func theSchedulerStartsARealStoreRun() async {
        let (store, _) = makeStore()
        let now = Date()
        let scheduler = TaskScheduler(storage: InMemoryScheduleStorage(), now: { now })
        scheduler.timerEnabled = false
        await scheduler.start(runner: store)
        let task = ScheduledTask(name: "Check", prompt: "Look around", directory: Self.directory)
        scheduler.add(task)
        let run = await scheduler.runNow(task.id)
        #expect(run?.status == .running)
        #expect(run?.sessionID.flatMap { store.session($0) }?.title == run?.sessionTitle)
        #expect(store.selectedSessionID == "mine")
    }
}
