import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// A fake engine that can list and stop background work and report plan limit stops, recording what it was asked.
final class BackgroundFakeEngine: RouterFakeEngine, EngineBackgroundTasks, EngineUsageLimitReporting, @unchecked Sendable {
    let tasks = Mutex<[BackgroundTask]>([])
    let limits = Mutex<[String: UsageLimitInfo]>([:])

    func backgroundTasks() async throws -> [BackgroundTask] {
        log("listTasks")
        return tasks.withLock { $0 }
    }

    func stopBackgroundTask(_ task: BackgroundTask) async throws {
        log("stopTask:\(task.id)")
        tasks.withLock { $0.removeAll { $0.id == task.id } }
    }

    func stopSubagent(_ sessionID: String) async throws { log("stopSubagent:\(sessionID)") }

    func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? { limits.withLock { $0[sessionID] } }
}

@MainActor
@Suite("Background work list")
struct BackgroundWorkTests {
    static let directory = "/tmp/project"

    /// Two top-level sessions with subagents (one nested), a room agent's session, shells, and three schedules.
    static func makeStore(engine: any OpenCodeAPI) -> SessionStore {
        let now = Date()
        let room = UUID()
        let seed = StoreSeed(
            sessions: [
                EngineSession(id: "rootA", title: "Fix the login bug", directory: directory),
                EngineSession(id: "childA1", parentID: "rootA", title: "Find the session code", directory: directory, agent: "Explore"),
                EngineSession(id: "childA2", parentID: "rootA", title: "Finished helper", directory: directory),
                EngineSession(id: "grandA", parentID: "childA1", title: "Read the cookie tests", directory: directory),
                EngineSession(id: "rootB", title: "Write docs", directory: "/tmp/docs"),
                EngineSession(id: "childB", parentID: "rootB", title: "Check links", directory: "/tmp/docs"),
                EngineSession(id: "roomC", title: "Alice in the design room", directory: directory),
                EngineSession(id: "childC", parentID: "roomC", title: "Survey screens", directory: directory),
            ],
            activities: ["childA1": .working, "grandA": .waitingForPermission, "childB": .working, "childC": .working, "rootA": .working],
            schedules: [
                ScheduleInfo(id: "sch_soon", title: "Nightly check", prompt: "p", directory: directory, schedule: "0 3 * * *",
                             nextRun: now.addingTimeInterval(600)),
                ScheduleInfo(id: "sch_later", title: "Weekly refresh", prompt: "p", directory: directory, schedule: "0 9 * * 1",
                             nextRun: now.addingTimeInterval(7200)),
                ScheduleInfo(id: "sch_paused", title: "Paused", prompt: "p", directory: directory, schedule: "0 9 * * 1", paused: true,
                             nextRun: now.addingTimeInterval(60)),
            ],
            agents: [AgentSpec(id: room, name: "Alice", model: ModelRef(providerID: "mock", id: "m"), colorHex: "#A78BFA")],
            sessionAgentIDs: ["roomC": [room]]
        )
        let store = SessionStore(engine: engine)
        store.seed(seed)
        store.background.timerEnabled = false
        // Fixed start times: childC newest, then childB, then the rootA tree.
        store.session("childA1")?.workingSince = now.addingTimeInterval(-300)
        store.session("grandA")?.workingSince = now.addingTimeInterval(-120)
        store.session("childB")?.workingSince = now.addingTimeInterval(-60)
        store.session("childC")?.workingSince = now.addingTimeInterval(-10)
        store.seedBackgroundTasks([
            BackgroundTask(id: "sh1", sessionID: "grandA", kind: .shell, title: "npm run dev", started: now.addingTimeInterval(-500)),
            BackgroundTask(id: "sh2", sessionID: "rootA", kind: .shell, title: "tail -f log", started: now.addingTimeInterval(-30)),
            BackgroundTask(id: "wf", sessionID: "unknown-session", kind: .task, title: "Workflow", started: now.addingTimeInterval(-40)),
        ])
        return store
    }

    @Test func groupsByTopLevelSessionNewestFirst() {
        let store = Self.makeStore(engine: RouterFakeEngine(name: "plain"))
        let groups = store.backgroundWork(roomTitles: ["roomC": "Design review"])
        #expect(groups.map(\.id) == ["roomC", "rootA", "unknown-session", "rootB", BackgroundWorkGroup.scheduledID])

        let room = groups[0]
        #expect(room.title == "Alice in the design room")
        #expect(room.subtitle == "Design review")
        #expect(room.agentID != nil)

        // Subagents (nested ones too) before shells, each oldest first; the finished subagent is left out.
        let a = groups[1]
        #expect(a.items.map(\.id) == ["subagent:childA1", "subagent:grandA", "task:sh1", "task:sh2"])
        #expect(a.subtitle == "project")
        #expect(a.items[0].detail == "Explore")
        #expect(a.items[2].openSessionID == "grandA")
        #expect(a.items[2].kind == .shell)

        // A task of a session the store does not know is still listed, without Open.
        #expect(groups[2].title == "Other sessions")
        #expect(groups[2].items.first?.openSessionID == nil)
        #expect(groups[2].items.first?.kind == .task)

        // Scheduled runs last, soonest first, paused ones left out; they do not count as running.
        #expect(groups[4].items.map(\.scheduleID) == ["sch_soon", "sch_later"])
        #expect(groups[4].items.allSatisfy { !$0.isRunning && $0.stopLabel == "Pause" })
        #expect(store.backgroundRunningCount == 7)
    }

    @Test func sessionSectionShowsItsWholeTree() {
        let store = Self.makeStore(engine: RouterFakeEngine(name: "plain"))
        // From the root or from a subagent, the same tree.
        #expect(store.backgroundWork(forSession: "rootA").map(\.id) == ["subagent:childA1", "subagent:grandA", "task:sh1", "task:sh2"])
        #expect(store.backgroundWork(forSession: "grandA").count == 4)
        #expect(store.backgroundWork(forSession: "rootB").map(\.id) == ["subagent:childB"])
        #expect(store.rootSessionID(of: "grandA") == "rootA")
        // A subagent that stops working leaves the list.
        store.apply(.activity(sessionID: "childB", .idle))
        #expect(store.backgroundWork(forSession: "rootB").isEmpty)
    }

    @Test func stopGoesToTheEngineThatCanStopOnlyTheSubagent() async throws {
        let engine = BackgroundFakeEngine(name: "capable")
        let store = Self.makeStore(engine: engine)
        let items = store.backgroundItems
        let subagent = try #require(items.first { $0.id == "subagent:childA1" })
        let shell = try #require(items.first { $0.id == "task:sh2" })
        let schedule = try #require(items.first { $0.id == "schedule:sch_soon" })

        await store.stopBackground(subagent)
        await store.stopBackground(shell)
        await store.stopBackground(schedule)
        #expect(engine.calls.contains("stopSubagent:childA1"))
        #expect(!engine.calls.contains("interrupt:childA1"))
        #expect(engine.calls.contains("stopTask:sh2"))
        #expect(engine.calls.contains("pause:sch_soon"))
        // The stopped shell and the paused schedule leave the list at once.
        #expect(!store.backgroundItems.contains { $0.id == "task:sh2" || $0.id == "schedule:sch_soon" })
        #expect(store.lastError == nil)
        #expect(!store.isStopping(subagent))
    }

    @Test func stopInterruptsTheSubagentWhenTheEngineCannotStopIt() async throws {
        let engine = RouterFakeEngine(name: "plain")
        let store = Self.makeStore(engine: engine)
        let subagent = try #require(store.backgroundItems.first { $0.id == "subagent:childB" })
        await store.stopBackground(subagent)
        #expect(engine.calls == ["interrupt:childB"])
        // Shells need an engine that can stop them.
        let shell = try #require(store.backgroundItems.first { $0.id == "task:sh1" })
        await store.stopBackground(shell)
        #expect(store.lastError?.contains("npm run dev") == true)
    }

    @Test func routerSendsStopsToTheOwningEngine() async throws {
        let plain = RouterFakeEngine(name: "plain")
        let capable = BackgroundFakeEngine(name: "capable")
        plain.setSessions([EngineSession(id: "oc-root", title: "", directory: "/p"),
                           EngineSession(id: "oc-child", parentID: "oc-root", title: "", directory: "/p")])
        capable.setSessions([EngineSession(id: "cl-root", title: "", directory: "/p")])
        capable.tasks.withLock { $0 = [BackgroundTask(id: "t1", sessionID: "cl-root", kind: .shell, title: "sleep 9")] }
        let router = EngineRouter(fallback: plain)
        router.register(capable, providers: ["claude-code"], id: "claude", name: "Claude")
        _ = try await router.listSessions()

        try await router.stopSubagent("cl-root.toolu_1")
        try await router.stopSubagent("oc-child")
        #expect(capable.calls.contains("stopSubagent:cl-root.toolu_1"))
        #expect(plain.calls.contains("interrupt:oc-child"))

        #expect(try await router.backgroundTasks().map(\.id) == ["t1"])
        try await router.stopBackgroundTask(BackgroundTask(id: "t1", sessionID: "cl-root", kind: .shell, title: "sleep 9"))
        #expect(capable.calls.contains("stopTask:t1"))
        await #expect(throws: (any Error).self) {
            try await router.stopBackgroundTask(BackgroundTask(id: "x", sessionID: "oc-root", kind: .shell, title: "x"))
        }

        capable.limits.withLock { $0["cl-root"] = UsageLimitInfo(window: "five_hour") }
        #expect(await router.usageLimitStop("cl-root")?.window == "five_hour")
        #expect(await router.usageLimitStop("oc-root") == nil)
    }

    @Test func engineEventsRefreshTheTasks() async throws {
        let engine = BackgroundFakeEngine(name: "capable")
        let store = Self.makeStore(engine: engine)
        engine.tasks.withLock { $0 = [BackgroundTask(id: "new", sessionID: "rootB", kind: .shell, title: "make watch")] }
        store.apply(.other(type: ClaudeEventTypes.backgroundTasks))
        store.apply(.other(type: "shell.exited"))
        for _ in 0..<40 where store.background.tasks.map(\.id) != ["new"] { try await Task.sleep(for: .milliseconds(25)) }
        #expect(store.background.tasks.map(\.id) == ["new"])
        // One refresh for the burst.
        #expect(engine.calls.filter { $0 == "listTasks" }.count == 1)
        let revision = store.background.planLimitsRevision
        store.apply(.other(type: ClaudeEventTypes.rateLimit))
        #expect(store.background.planLimitsRevision == revision + 1)
    }
}

@Suite("Plan limit meter")
struct PlanLimitMeterTests {
    @Test(arguments: [
        (0.0, nil as String?, PlanLimitMeter.Level.normal),
        (0.6, nil, .normal),
        (0.58, "allowed_warning", .normal),
        (0.79, nil, .normal),
        (0.8, nil, .nearLimit),
        (0.95, "allowed_warning", .nearLimit),
        (0.999, nil, .nearLimit),
        (1.0, nil, .limited),
        (0.4, "rejected", .limited),
    ])
    func thresholds(utilization: Double, status: String?, level: PlanLimitMeter.Level) {
        #expect(PlanLimitMeter.level(utilization: utilization, status: status) == level)
    }

    @Test func ringFollowsTheWindowClosestToItsLimit() {
        let zero = PlanLimitMeter(windows: [.init(name: "seven_day", utilization: 0), .init(name: "five_hour", utilization: 0)])
        #expect(zero.windows.map(\.name) == ["five_hour", "seven_day"])
        #expect(zero.level == .normal)

        let sixty = PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0.6), .init(name: "seven_day", utilization: 0.31)])
        #expect(sixty.level == .normal)
        #expect(sixty.leading?.name == "five_hour")
        #expect(sixty.leading?.shortLabel == "5-hour")

        let ninetyFive = PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0.42), .init(name: "seven_day", utilization: 0.95)])
        #expect(ninetyFive.level == .nearLimit)
        #expect(ninetyFive.leading?.name == "seven_day")
        #expect(ninetyFive.weekly?.fraction == 0.95)

        // A used-up window wins over a fuller-looking one that is only near.
        let limited = PlanLimitMeter(windows: [.init(name: "five_hour", utilization: 0.5, status: "rejected"),
                                               .init(name: "seven_day", utilization: 0.9)])
        #expect(limited.level == .limited)
        #expect(limited.leading?.name == "five_hour")
        #expect(PlanLimitMeter(windows: []).leading == nil)
    }

    @Test func readsTheEnginesReport() {
        // The recorded fixture's report: weekly at 58% with the CLI's pace warning.
        let recorded = ClaudePlanLimits(status: "allowed_warning", limitType: "seven_day", utilization: 0.58,
                                        resetsAt: Date(timeIntervalSince1970: 1_795_525_200),
                                        windows: [.init(name: "seven_day", utilization: 0.58, resetsAt: Date(timeIntervalSince1970: 1_795_525_200),
                                                        status: "allowed")])
        let meter = PlanLimitMeter(limits: recorded)
        #expect(meter.windows.count == 1)
        #expect(meter.level == .normal)
        #expect(meter.weekly?.resetsAt == Date(timeIntervalSince1970: 1_795_525_200))

        // A rejected headline marks its window used up, even when the windows list omits the status.
        let rejected = ClaudePlanLimits(status: "rejected", limitType: "five_hour", utilization: 1, resetsAt: nil,
                                        windows: [.init(name: "five_hour", utilization: 0.97, resetsAt: nil, status: nil),
                                                  .init(name: "seven_day", utilization: 0.4, resetsAt: nil, status: "allowed")])
        let limited = PlanLimitMeter(limits: rejected)
        #expect(limited.isLimited)
        #expect(limited.level == .limited)
        #expect(limited.fiveHour?.level == .limited)
        #expect(limited.weekly?.level == .normal)

        // Only a headline (no windows): it becomes the one window.
        let headline = PlanLimitMeter(limits: ClaudePlanLimits(status: "allowed", limitType: "five_hour", utilization: 0.83))
        #expect(headline.windows.map(\.name) == ["five_hour"])
        #expect(headline.level == .nearLimit)
    }
}

@MainActor
@Suite("Auto-continue after a plan limit")
struct AutoContinueTests {
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    static let limitText = "Your Claude plan's usage limit is reached. (You've hit your 5-hour limit \u{00B7} resets 4pm)"

    /// An idle session whose turn just failed on a limit that resets an hour from `start`.
    static func limitedStore(reportsReset: Bool = true) async throws -> (SessionStore, BackgroundFakeEngine, Clock, Date) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(3600)
        let engine = BackgroundFakeEngine(name: "claude")
        if reportsReset {
            engine.limits.withLock { $0["s1"] = UsageLimitInfo(resetsAt: reset, window: "five_hour", message: "You've hit your 5-hour limit") }
        }
        let store = SessionStore(engine: engine)
        store.seed(StoreSeed(sessions: [EngineSession(id: "s1", title: "Long job", directory: "/tmp/p")],
                             activities: ["s1": .working]))
        let clock = Clock(start)
        store.background.timerEnabled = false
        store.background.now = { clock.now }
        store.apply(.executionEnded(sessionID: "s1", outcome: "failed", error: limitText))
        store.apply(.activity(sessionID: "s1", .failed))
        if reportsReset {
            for _ in 0..<40 where store.background.limitStops.values.first?.resetsAt == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return (store, engine, clock, reset)
    }

    static func prompts(_ engine: RouterFakeEngine) -> Int { engine.calls.filter { $0 == "prompt:s1" }.count }

    @Test func limitErrorBecomesACardWithTheResetTime() async throws {
        let (store, _, _, reset) = try await Self.limitedStore()
        let session = try #require(store.session("s1"))
        let errorID = try #require(session.items.last?.id)
        let stop = try #require(store.usageLimitStop(forItem: errorID))
        #expect(stop.resetsAt == reset)
        #expect(stop.continueAt == reset.addingTimeInterval(60))
        #expect(stop.window == "five_hour")
        #expect(stop.windowLabel == "5-hour limit")
        #expect(stop.autoContinue)
        #expect(stop.state == .waiting)
    }

    @Test func sendsContinueOnceAMinuteAfterTheReset() async throws {
        let (store, engine, clock, reset) = try await Self.limitedStore()
        clock.now = reset.addingTimeInterval(30)
        #expect(await store.checkAutoContinue().isEmpty)
        #expect(Self.prompts(engine) == 0)

        clock.now = reset.addingTimeInterval(61)
        #expect(await store.checkAutoContinue() == ["s1"])
        #expect(Self.prompts(engine) == 1)
        let session = try #require(store.session("s1"))
        #expect(session.items.contains { if case .user(_, "Continue", _) = $0 { true } else { false } })
        #expect(store.background.limitStops.values.first?.state == .sent)

        // Never twice, even once the session is idle again.
        store.apply(.executionEnded(sessionID: "s1", outcome: "succeeded", error: nil))
        store.apply(.activity(sessionID: "s1", .idle))
        clock.now = reset.addingTimeInterval(600)
        #expect(await store.checkAutoContinue().isEmpty)
        #expect(Self.prompts(engine) == 1)
    }

    @Test func switchedOffSendsNothing() async throws {
        let (store, engine, clock, reset) = try await Self.limitedStore()
        let id = try #require(store.background.limitStops.keys.first)
        store.setAutoContinue(false, forItem: id)
        clock.now = reset.addingTimeInterval(120)
        #expect(await store.checkAutoContinue().isEmpty)
        #expect(Self.prompts(engine) == 0)
        // Switching it back on before anything else happened sends at the next check.
        store.setAutoContinue(true, forItem: id)
        #expect(await store.checkAutoContinue() == ["s1"])
    }

    @Test func busySessionIsLeftAlone() async throws {
        let (store, engine, clock, reset) = try await Self.limitedStore()
        let session = try #require(store.session("s1"))
        session.setActivity(.working)
        clock.now = reset.addingTimeInterval(120)
        #expect(await store.checkAutoContinue().isEmpty)
        #expect(Self.prompts(engine) == 0)
        #expect(store.background.limitStops.values.first?.state == .waiting)

        // A new turn the engine reports (you sent something) replaces the stop: nothing is sent afterwards.
        store.apply(.activity(sessionID: "s1", .working))
        #expect(store.background.limitStops.values.first?.state == .superseded)
        store.apply(.activity(sessionID: "s1", .idle))
        #expect(await store.checkAutoContinue().isEmpty)
        #expect(Self.prompts(engine) == 0)
    }

    @Test func wakeAfterSleepingThroughTheResetContinues() async throws {
        let (store, engine, clock, reset) = try await Self.limitedStore()
        clock.now = reset.addingTimeInterval(-600)
        #expect(await store.checkAutoContinue().isEmpty)
        // The Mac slept through the reset; no timer fired. Waking checks again.
        clock.now = reset.addingTimeInterval(3 * 3600)
        #expect(await store.autoContinueAfterWake() == ["s1"])
        #expect(Self.prompts(engine) == 1)
        #expect(await store.autoContinueAfterWake().isEmpty)
    }

    @Test func timerFiresByItself() async throws {
        let (store, engine, clock, reset) = try await Self.limitedStore()
        clock.now = reset.addingTimeInterval(59.5)
        store.background.timerEnabled = true
        store.rescheduleAutoContinueTimer()
        clock.now = reset.addingTimeInterval(61)
        for _ in 0..<60 where Self.prompts(engine) == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(Self.prompts(engine) == 1)
        #expect(store.background.timer == nil)
    }

    @Test func otherFailuresAndUnknownResets() async throws {
        let engine = RouterFakeEngine(name: "plain")
        let store = SessionStore(engine: engine)
        store.seed(StoreSeed(sessions: [EngineSession(id: "s1", title: "t", directory: "/p"), EngineSession(id: "s2", title: "t", directory: "/p")]))
        store.background.timerEnabled = false
        store.apply(.executionEnded(sessionID: "s1", outcome: "failed", error: "The API key was rejected."))
        #expect(store.background.limitStops.isEmpty)
        // Older CLIs put the reset after a bar; engines without a report still get it from the text.
        store.apply(.executionEnded(sessionID: "s2", outcome: "failed", error: "Claude AI usage limit reached|1800003600"))
        let stop = try #require(store.background.limitStops.values.first)
        #expect(stop.sessionID == "s2")
        #expect(stop.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
    }

    @Test func limitTextIsRecognised() {
        #expect(UsageLimitText.isUsageLimit("You've hit your 5-hour limit \u{00B7} resets 3pm (Europe/London)"))
        #expect(UsageLimitText.isUsageLimit("You've hit your weekly limit \u{00B7} resets Nov 25, 9am \u{00B7} progress saved"))
        #expect(UsageLimitText.isUsageLimit("Claude AI usage limit reached|1795525200"))
        #expect(UsageLimitText.isUsageLimit("5-hour limit reached \u{2219} resets 3pm"))
        #expect(!UsageLimitText.isUsageLimit("You've hit your monthly spend limit \u{00B7} raise it at the console"))
        #expect(!UsageLimitText.isUsageLimit("You're out of usage credits. Switch to another model to continue."))
        #expect(!UsageLimitText.isUsageLimit("Prompt is too long"))
        #expect(UsageLimitText.legacyResetDate("Claude AI usage limit reached|1795525200") == Date(timeIntervalSince1970: 1_795_525_200))
        #expect(UsageLimitText.legacyResetDate("You've hit your limit") == nil)
    }
}
