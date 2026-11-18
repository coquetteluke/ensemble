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

        var run = ScheduleRun(taskID: task.id, reason: .manual, started: Date(), status: .succeeded, sessionID: "daily")
        run.restoreMode = .auto
        run.appliedMode = .ask
        store.scheduledRunDidEnd(run, task: task)
        for _ in 0..<50 where store.session("daily")?.permissionMode != .auto { await Task.yield() }
        #expect(store.session("daily")?.permissionMode == .auto)

        task.continueSessionID = "deleted"
        #expect(store.scheduleRefusal(for: task) == "The session it continues was deleted.")
        await #expect(throws: ScheduleRunError.sessionGone) { try await store.startScheduledRun(task, title: "x") }
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
