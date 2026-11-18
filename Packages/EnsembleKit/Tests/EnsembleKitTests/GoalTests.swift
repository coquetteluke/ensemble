import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

// MARK: - The agent's answer and the command

@Suite struct GoalParsingTests {
    @Test func verdicts() {
        #expect(GoalVerdictParser.parse("GOAL MET") == .met(""))
        #expect(GoalVerdictParser.parse("Ran swift test.\n**GOAL MET**: 42 tests pass") == .met("42 tests pass"))
        #expect(GoalVerdictParser.parse("GOAL NOT MET: 2 tests fail in RoomTests") == .notMet("2 tests fail in RoomTests"))
        #expect(GoalVerdictParser.parse("goal not met - still failing") == .notMet("still failing"))
        #expect(GoalVerdictParser.parse("> GOAL NOT MET") == .notMet("No reason given."))
        #expect(GoalVerdictParser.parse("- `GOAL MET` (checked with swift test)") == .met("(checked with swift test)"))
        // The last answer line wins.
        #expect(GoalVerdictParser.parse("GOAL NOT MET: first try\nFixed it.\nGOAL MET") == .met(""))
    }

    @Test func malformedAnswers() {
        #expect(GoalVerdictParser.parse("") == .malformed)
        #expect(GoalVerdictParser.parse("I fixed the tests.") == .malformed)
        // Mentioning the words is not answering.
        #expect(GoalVerdictParser.parse("I will answer GOAL MET or GOAL NOT MET when done.") == .malformed)
        // Whole words only.
        #expect(GoalVerdictParser.parse("GOAL METRICS look fine") == .malformed)
        #expect(GoalVerdictParser.parse("GOAL NOTED") == .malformed)
    }

    @Test func commands() {
        #expect(GoalCommand.parse("") == .show)
        #expect(GoalCommand.parse("  stop ") == .stop)
        #expect(GoalCommand.parse("clear") == .stop)
        #expect(GoalCommand.parse("all tests pass") == .set(condition: "all tests pass", budget: GoalBudget()))
        #expect(GoalCommand.parse("all tests pass --turns 3 --cost $2.50")
            == .set(condition: "all tests pass", budget: GoalBudget(maxTurns: 3, maxCostUSD: 2.5)))
        #expect(GoalCommand.parse("--turns 4") == .show)
        // A bad number stays part of the condition.
        #expect(GoalCommand.parse("ship --turns many") == .set(condition: "ship --turns many", budget: GoalBudget()))
    }
}

// MARK: - The rules

@Suite struct GoalDriverTests {
    func start(_ budget: GoalBudget = GoalBudget()) -> GoalRun {
        GoalDriver.start(condition: "all tests pass", budget: budget, costNow: 1.0).0
    }

    @Test func metOnTheSecondTurn() {
        var run = start()
        #expect(run.turns == 1)
        let first = GoalDriver.afterTurn(&run, GoalTurn(reply: "Tried.\nGOAL NOT MET: one test fails", costNow: 1.2))
        guard case .send(let text) = first else { Issue.record("expected a turn, got \(first)"); return }
        #expect(text.hasPrefix("[Goal] Not met yet: one test fails"))
        #expect(text.contains("turn 2 of 10"))
        #expect(run.turns == 2)
        #expect(run.lastReason == "one test fails")
        let second = GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL MET: all 12 pass", costNow: 1.5))
        #expect(second == .finish("Goal met: all 12 pass"))
        #expect(run.status == .met)
        #expect(run.evidence == "all 12 pass")
        #expect(abs(run.costSpent - 0.5) < 0.0001)
        #expect(run.statusLine == "Met after 2 turns")
    }

    @Test func turnBudgetStops() {
        var run = start(GoalBudget(maxTurns: 2))
        #expect(GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL NOT MET: a", costNow: 1)) != .wait)
        let action = GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL NOT MET: b", costNow: 1))
        #expect(action == .finish("Goal stopped. Budget used up after 2 turns. Last check: b"))
        #expect(run.status == .budgetReached)
        #expect(run.turns == 2)
        #expect(!run.isActive)
        // Nothing happens once it ended.
        #expect(GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL NOT MET: c", costNow: 1)) == .wait)
    }

    @Test func costBudgetStops() {
        var run = start(GoalBudget(maxTurns: 10, maxCostUSD: 0.5))
        let action = GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL NOT MET: slow", costNow: 1.6))
        guard case .finish(let line) = action else { Issue.record("expected the goal to stop, got \(action)"); return }
        #expect(line.contains("Cost budget used up: $0.60 of $0.50"))
        #expect(run.status == .budgetReached)
    }

    @Test func missingAnswerAsksForACheck() {
        var run = start()
        let action = GoalDriver.afterTurn(&run, GoalTurn(reply: "I changed three files.", costNow: 1))
        guard case .check(let text) = action else { Issue.record("expected a check, got \(action)"); return }
        #expect(text.hasPrefix("[Goal] Check whether this goal is met: all tests pass"))
        #expect(run.status == .checking)
        #expect(run.turns == 1)
        #expect(run.checks == 1)
        // A check that still does not answer counts as not met, and the next turn goes out.
        let next = GoalDriver.afterTurn(&run, GoalTurn(reply: "Looks fine to me.", costNow: 1, wasCheck: true))
        guard case .send(let more) = next else { Issue.record("expected a turn, got \(next)"); return }
        #expect(more.contains("The agent did not answer GOAL MET or GOAL NOT MET."))
        #expect(run.turns == 2)
    }

    @Test func waitsForTheUser() {
        var run = start()
        // A question to the user.
        #expect(GoalDriver.afterTurn(&run, GoalTurn(reply: "Should I also update the docs?", costNow: 1)) == .wait)
        #expect(run.status == .waiting)
        #expect(run.isActive)
        // The user answers: that turn counts toward the goal.
        GoalDriver.resume(&run)
        #expect(run.status == .working)
        // An open prompt, or a message of the user's waiting to go.
        #expect(GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL NOT MET: needs approval", costNow: 1, userPending: true)) == .wait)
        #expect(run.note == "Waiting on you")
        #expect(run.turns == 1)
        // Met beats a waiting prompt.
        GoalDriver.resume(&run)
        #expect(GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL MET", costNow: 1, userPending: true)) == .finish("Goal met: all tests pass"))
    }

    @Test func stopsAndFailures() {
        var run = start()
        #expect(GoalDriver.afterTurn(&run, GoalTurn(reply: "", ending: .interrupted, costNow: 1))
            == .finish("Goal stopped because the agent was stopped"))
        #expect(run.status == .stopped)

        var limited = start()
        #expect(GoalDriver.afterTurn(&limited, GoalTurn(reply: "", ending: .failed(message: "You've hit your 5-hour limit", planLimit: true),
                                                        costNow: 1)) == .wait)
        #expect(limited.status == .waiting)
        #expect(limited.note == "Waiting for the plan limit to reset")

        var stopped = start()
        #expect(GoalDriver.stop(&stopped) == "Goal stopped by you after 1 turn")
        #expect(GoalDriver.stop(&stopped) == nil)

        var blocked = start()
        #expect(GoalDriver.block(&blocked, reason: "OpenAI reached its daily spending cap") == "Goal stopped. OpenAI reached its daily spending cap.")
        #expect(blocked.status == .blocked)
    }

    @Test func roomsCountRuns() {
        var run = GoalDriver.start(condition: "ship it", budget: GoalBudget(maxTurns: 1), costNow: 0, unit: "run").0
        #expect(run.progressLabel == "Run 1 of 1")
        let action = GoalDriver.afterTurn(&run, GoalTurn(reply: "GOAL NOT MET: no", costNow: 0, wasCheck: true))
        #expect(action == .finish("Goal stopped. Budget used up after 1 run. Last check: no"))
    }
}

// MARK: - Sessions

/// An engine that records what it is asked to send; the test plays the engine's events into the store itself.
final class GoalRecordingEngine: OpenCodeAPI {
    private let prompts = Mutex<[String]>([])
    var sent: [String] { prompts.withLock { $0 } }

    func serverInfo() async throws -> (version: String, url: URL) { ("2.3.0", URL(string: "http://127.0.0.1:1")!) }
    func listSessions() async throws -> [EngineSession] { [] }
    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession {
        EngineSession(id: "ses_goal", title: "Goal", directory: directory)
    }
    func deleteSession(_ sessionID: String) async throws {}
    func renameSession(_ sessionID: String, title: String) async throws {}
    func setArchived(_ sessionID: String, archived: Bool) async throws {}
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws {}
    func switchModel(_ sessionID: String, model: ModelRef) async throws {}
    func transcript(_ sessionID: String) async throws -> [TranscriptItem] { [] }
    func children(_ sessionID: String) async throws -> [EngineSession] { [] }
    func prompt(_ sessionID: String, text: String, files: [URL]) async throws { prompts.withLock { $0.append(text) } }
    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {}
    func interrupt(_ sessionID: String) async throws {}
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {}
    func pendingPermissions() async throws -> [PermissionRequest] { [] }
    func context(_ sessionID: String) async throws -> ContextBreakdown { ContextBreakdown(usedTokens: 0, limitTokens: 200_000, categories: []) }
    func changedFiles(_ sessionID: String) async throws -> [FileChange] { [] }
    func connectors() async throws -> [ConnectorInfo] { [] }
    func models() async throws -> [ModelInfo] { [] }
    func providers() async throws -> [ProviderInfo] { [] }
    func setAPIKey(providerID: String, key: String) async throws {}
    func removeAPIKey(providerID: String) async throws {}
    func schedules() async throws -> [ScheduleInfo] { [] }
    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        throw URLError(.unsupportedURL)
    }
    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {}
    func deleteSchedule(_ scheduleID: String) async throws {}
    func events() -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
}

@Suite @MainActor struct SessionGoalTests {
    let sid = "ses_goal"

    func makeStore() -> (SessionStore, GoalRecordingEngine) {
        let engine = GoalRecordingEngine()
        let store = SessionStore(engine: engine)
        store.seed(StoreSeed(sessions: [EngineSession(id: sid, title: "Goal", directory: "/tmp/goal")]))
        store.goals.settleDelay = .milliseconds(1)
        return (store, engine)
    }

    /// Plays one finished turn of the agent into the store.
    func reply(_ store: SessionStore, _ text: String, cost: Double, outcome: String = "succeeded", error: String? = nil) {
        store.apply(.activity(sessionID: sid, .working))
        let item = "text-\(UUID().uuidString)"
        store.apply(.textEnded(sessionID: sid, itemID: item, text: text))
        store.apply(.usageUpdated(sessionID: sid, Usage(costUSD: cost)))
        store.apply(.executionEnded(sessionID: sid, outcome: outcome, error: error))
    }

    func waitForPrompts(_ engine: GoalRecordingEngine, _ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while engine.sent.count < count {
            guard clock.now < deadline else { throw GoalTestTimeout(description: "Waited for \(count) prompts, got \(engine.sent)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    var notices: (SessionStore) -> [String] {
        { store in
            store.session(sid)?.items.compactMap { item -> String? in
                if case .notice(_, let text) = item { return text }
                return nil
            } ?? []
        }
    }

    @Test func metAfterTwoTurns() async throws {
        let (store, engine) = makeStore()
        #expect(await store.setGoal("all tests pass", for: sid))
        #expect(engine.sent.count == 1)
        #expect(engine.sent[0].hasPrefix("[Goal] Keep working until this goal is met: all tests pass"))
        #expect(store.goal(for: sid)?.status == .working)

        reply(store, "Fixed two tests.\nGOAL NOT MET: RoomTests still fails", cost: 0.10)
        try await waitForPrompts(engine, 2)
        #expect(engine.sent[1].hasPrefix("[Goal] Not met yet: RoomTests still fails"))
        #expect(store.goal(for: sid)?.turns == 2)

        reply(store, "All green.\nGOAL MET: swift test passes", cost: 0.25)
        #expect(store.goal(for: sid)?.status == .met)
        #expect(notices(store).last == "Goal met: swift test passes")
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.sent.count == 2, "nothing more is sent once the goal is met")
        // Each goal turn is a visible message in the transcript.
        let users: [String] = store.session(sid)?.items.compactMap { item -> String? in
            if case .user(_, let text, _) = item { return text }
            return nil
        } ?? []
        #expect(users.count == 2)
        #expect(users.allSatisfy { $0.hasPrefix("[Goal]") })
    }

    @Test func turnBudgetStops() async throws {
        let (store, engine) = makeStore()
        await store.send("/goal all tests pass --turns 2", to: sid)
        try await waitForPrompts(engine, 1)
        #expect(store.goal(for: sid)?.budget.maxTurns == 2)
        reply(store, "GOAL NOT MET: one", cost: 0.1)
        try await waitForPrompts(engine, 2)
        reply(store, "GOAL NOT MET: two", cost: 0.2)
        #expect(store.goal(for: sid)?.status == .budgetReached)
        #expect(notices(store).last == "Goal stopped. Budget used up after 2 turns. Last check: two")
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.sent.count == 2)
    }

    @Test func waitsOnAPromptAndResumesWithTheUser() async throws {
        let (store, engine) = makeStore()
        #expect(await store.setGoal("deploy works", for: sid))
        // The turn ends while a question card is still open: nothing is sent.
        store.apply(.permissionAsked(PermissionRequest(id: "q1", sessionID: sid, kind: "question", title: "Which server?",
                                                       detail: nil, created: Date())))
        reply(store, "Which server should I deploy to?", cost: 0.05)
        #expect(store.goal(for: sid)?.status == .waiting)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.sent.count == 1)

        // The user answers; the next finished turn is checked again.
        store.apply(.permissionReplied(sessionID: sid, requestID: "q1"))
        await store.send("The staging one", to: sid)
        store.apply(.activity(sessionID: sid, .working))
        #expect(store.goal(for: sid)?.status == .working)
        reply(store, "Deployed to staging.\nGOAL MET: staging answers 200", cost: 0.1)
        #expect(store.goal(for: sid)?.status == .met)
        #expect(engine.sent == [engine.sent[0], "The staging one"])
    }

    @Test func noAnswerAsksForACheckTurn() async throws {
        let (store, engine) = makeStore()
        #expect(await store.setGoal("lint is clean", for: sid))
        reply(store, "I fixed the warnings.", cost: 0.05)
        try await waitForPrompts(engine, 2)
        #expect(engine.sent[1].hasPrefix("[Goal] Check whether this goal is met: lint is clean"))
        #expect(store.goal(for: sid)?.status == .checking)
        reply(store, "GOAL MET", cost: 0.06)
        #expect(store.goal(for: sid)?.status == .met)
    }

    @Test func stopping() async throws {
        let (store, engine) = makeStore()
        #expect(await store.setGoal("docs build", for: sid))
        store.stopGoal(for: sid)
        #expect(store.goal(for: sid)?.status == .stopped)
        #expect(notices(store).last == "Goal stopped by you after 1 turn")
        reply(store, "GOAL NOT MET: x", cost: 0.05)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.sent.count == 1)
        store.clearGoal(for: sid)
        #expect(store.goal(for: sid) == nil)

        // Stopping the agent stops the goal.
        #expect(await store.setGoal("docs build", for: sid))
        reply(store, "", cost: 0.06, outcome: "interrupted")
        #expect(store.goal(for: sid)?.status == .stopped)
        #expect(notices(store).last == "Goal stopped because the agent was stopped")

        // Not while the agent works.
        store.apply(.activity(sessionID: sid, .working))
        #expect(await store.setGoal("docs build", for: sid) == false)
        #expect(notices(store).last == "Wait for the agent to finish, or stop it, before setting a goal")
    }

    @Test func showAndStopCommands() async throws {
        let (store, _) = makeStore()
        store.runGoalCommand("", in: sid)
        #expect(notices(store).last == "No goal is set. Type /goal and a condition, for example /goal all tests pass.")
        store.runGoalCommand("stop", in: sid)
        #expect(notices(store).last == "No goal is running")
        #expect(SlashCommands.builtIn.contains { $0.name == "goal" })
    }
}

struct GoalTestTimeout: Error, CustomStringConvertible {
    var description: String
}

// MARK: - Rooms

@Suite @MainActor struct RoomGoalTests {
    @Test func soloRoomMetAfterTwoRuns() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Goal: ship the parser", reply: "Built the parser.")
        fake.on("Alpha", "Goal check after run 1", reply: "Ran the tests.\nGOAL NOT MET: two parser tests fail")
        fake.on("Alpha", "Goal check after run 2", reply: "GOAL MET: all parser tests pass")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        await engine.setGoal("ship the parser")
        try await engine.waitFor("the goal to end", fake: fake) { $0.state.goal?.isActive == false }
        let goal = try #require(engine.state.goal)
        #expect(goal.status == .met, "\(engine.boardDump)")
        #expect(goal.turns == 2)
        #expect(goal.checks == 2)
        #expect(engine.state.run == 2)
        #expect(engine.state.phase == .finished)
        let notices = engine.notices
        #expect(notices.contains("Goal set: ship the parser. Up to 10 runs."))
        #expect(notices.contains("Goal not met yet: two parser tests fail. Run 2 of 10 starts."))
        #expect(notices.last == "Goal met: all parser tests pass")
        // The second run carries the reason.
        #expect(fake.sent(to: "Alpha").contains { $0.text.contains("Not met yet: two parser tests fail") })
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")
    }

    @Test func runBudgetStops() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Goal: never done", reply: "Tried.")
        fake.on("Alpha", "Goal check", reply: "GOAL NOT MET: still broken")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        await engine.setGoal("never done", budget: GoalBudget(maxTurns: 2))
        try await engine.waitFor("the goal to end", fake: fake) { $0.state.goal?.isActive == false }
        #expect(engine.state.goal?.status == .budgetReached)
        #expect(engine.state.run == 2)
        #expect(engine.notices.last == "Goal stopped. Budget used up after 2 runs. Last check: still broken")
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.state.run == 2)
    }

    @Test func teamRoomChecksAfterTheSummary() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Goal: add the API", reply: "PLAN: split it\nASSIGN @Alpha: server\nASSIGN @Beta: client")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Alpha", "Please review", reply: "APPROVE")
        fake.on("Beta", "Please review", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Both pieces are in.")
        fake.on("Alpha", "Goal check", reply: "GOAL MET: the client calls the server")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        await engine.setGoal("add the API")
        try await engine.waitFor("the goal to end", fake: fake) { $0.state.goal?.isActive == false }
        #expect(engine.state.goal?.status == .met, "\(engine.boardDump)")
        #expect(engine.state.run == 1)
        let check = try #require(engine.messages(from: "Alpha").last)
        #expect(check.kind == .review)
        #expect(check.text.contains("GOAL MET"))
    }

    @Test func stoppingTheRoomStopsTheGoal() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Goal: slow work", reply: "Working.", hold: true)
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        await engine.setGoal("slow work")
        try await engine.waitFor("the turn to start", fake: fake) { _ in fake.isHeld("Alpha") }
        await engine.stop()
        #expect(engine.state.goal?.status == .stopped)
        #expect(engine.notices.contains("Goal stopped with the room."))
    }

    @Test func stopGoalWhileChecking() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Goal: check me", reply: "Done.")
        fake.on("Alpha", "Goal check", reply: "GOAL NOT MET: x", hold: true)
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        await engine.setGoal("check me")
        try await engine.waitFor("the check to start", fake: fake) { $0.state.phase == .checkingGoal && fake.isHeld("Alpha") }
        engine.stopGoal()
        #expect(engine.state.phase == .finished)
        #expect(engine.state.goal?.status == .stopped)
        await fake.release("Alpha")
        try await engine.waitForSettled(fake: fake)
        #expect(engine.state.run == 1, "no new run after a stopped goal")
        engine.clearGoal()
        #expect(engine.state.goal == nil)
    }

    @Test func refusedInDebates() async throws {
        let fake = FakeEngine()
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"]), fake: fake)
        await engine.setGoal("decide")
        #expect(engine.state.goal == nil)
        #expect(engine.lastError == "Goal mode needs a room that builds: Team, Round table or Solo.")
    }

    @Test func goalSurvivesSaving() throws {
        var state = RoomState(spec: RoomFixtures.spec(.solo, ["Alpha"]))
        state.goal = GoalDriver.start(condition: "ship", budget: GoalBudget(maxTurns: 3, maxCostUSD: 1), costNow: 0, unit: "run").0
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(RoomState.self, from: data)
        #expect(back.goal == state.goal)
        // A room saved before goal mode still loads.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["goal"] = nil
        let old = try JSONDecoder().decode(RoomState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.goal == nil)
    }
}
