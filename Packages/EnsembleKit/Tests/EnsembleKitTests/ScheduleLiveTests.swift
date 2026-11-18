#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// A scheduled task against the real OpenCode service and the mock model (`ENSEMBLE_LIVE_TESTS=1`, see
/// `scripts/test-live.sh`): its time comes, the scheduler starts a new titled session through the store, the mock
/// replies, and the run is recorded as finished. Then an Ask-mode run stops on a permission prompt and shows as
/// needing you.
@MainActor
@Suite("Scheduled tasks, live", .enabled(if: LiveConfig.enabled), .serialized)
struct ScheduleLiveTests {
    static let mock = ModelRef(providerID: "mock", id: "mock-1")

    @Test func aDueTaskStartsASessionThatFinishes() async throws {
        let harness = try await LiveHarness.start()
        let store = SessionStore(engine: harness.client)
        store.sideQuestionRecordURL = nil
        do {
            await store.start()
            let selectedBefore = store.selectedSessionID
            let clock = ScheduleClock(Date())
            let scheduler = TaskScheduler(storage: InMemoryScheduleStorage(), now: { clock.now })
            scheduler.timerEnabled = false
            scheduler.settleTime = 1
            await scheduler.start(runner: store)

            let task = ScheduledTask(name: "Live check", prompt: "hello", directory: harness.path, model: Self.mock,
                                     permissionMode: .ask, trigger: .custom(cron: "* * * * *"))
            scheduler.add(task)
            #expect(await scheduler.check().isEmpty)

            // The next minute comes.
            clock.advance(61)
            let started = await scheduler.check()
            #expect(started.count == 1)
            let sessionID = try #require(scheduler.runs.first?.sessionID)
            harness.track(sessionID)
            #expect(scheduler.runs.first?.reason == .scheduled)
            #expect(store.selectedSessionID == selectedBefore, "a scheduled run does not take the screen")

            scheduler.now = Date.init
            let finished = try await Self.waitUntilDone(scheduler, timeout: 45)
            #expect(finished.status == .succeeded, "run ended as \(finished.status) \(finished.message ?? "")")
            let session = try #require(store.session(sessionID))
            #expect(session.title.hasPrefix("Live check, "), "title was \(session.title)")
            #expect(session.info.model == Self.mock)
            let replied = session.items.contains { item in
                if case .agentText(_, let text, _, _) = item { return text.contains("Hello from the mock model") }
                return false
            }
            #expect(replied)
            // The engine has the title too.
            let listed = try await harness.client.listSessions().first { $0.id == sessionID }
            #expect(listed?.title.hasPrefix("Live check, ") == true, "engine title was \(listed?.title ?? "nil")")

            // Ask mode, unattended: the shell command waits for you.
            let asking = ScheduledTask(name: "Live ask", prompt: "run the echo", directory: harness.path, model: Self.mock,
                                       permissionMode: .ask, trigger: .daily(hour: 3, minute: 0))
            scheduler.add(asking)
            let run = try #require(await scheduler.runNow(asking.id))
            let askingSession = try #require(run.sessionID)
            harness.track(askingSession)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, scheduler.runs.first(where: { $0.id == run.id })?.status != .needsYou {
                scheduler.pollActiveRuns()
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(scheduler.runs.first { $0.id == run.id }?.status == .needsYou)
            if let request = store.session(askingSession)?.pendingPermissions.first {
                await store.reply(to: request, decision: .reject)
            }
            let ended = try await Self.waitUntilDone(scheduler, timeout: 30)
            #expect(ended.id == run.id)
            #expect(!ended.status.isActive)
        } catch {
            store.stopListening()
            await harness.cleanup()
            throw error
        }
        store.stopListening()
        await harness.cleanup()
    }

    /// Polls the scheduler until no run is active; returns the newest run.
    static func waitUntilDone(_ scheduler: TaskScheduler, timeout: TimeInterval) async throws -> ScheduleRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !scheduler.pollActiveRuns(), let run = scheduler.runs.first { return run }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LiveTimeout(what: "the scheduled run to finish")
    }
}
#endif
