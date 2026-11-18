import Foundation
import Testing
@testable import EnsembleKit

@Suite @MainActor struct RoomDebateTests {
    func scriptDebate(_ fake: FakeEngine) {
        fake.on("Alpha", "Round 1 of 2", reply: "Use SQLite. It is simple and local.")
        fake.on("Beta", "Round 1 of 2", reply: "Use Postgres. It scales.")
        fake.on("Alpha", "Round 2 of 2", reply: "Postgres scales, but this is a desktop app. Still SQLite.")
        fake.on("Beta", "Round 2 of 2", reply: "Fair point. SQLite fits a desktop app.")
        fake.on("Alpha", "You are the judge", reply: "**VERDICT:** Use SQLite.\nReasons: local, simple, no server.\nStrongest dissent: Postgres scales better.")
    }

    @Test func createsOneSessionPerAgentAndBriefsThem() async throws {
        let fake = FakeEngine()
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"], permission: .ask, rounds: 2)
        let engine = try await RoomFixtures.engine(spec, fake: fake)

        #expect(fake.created.count == 2)
        #expect(fake.created.allSatisfy { $0.directory == spec.directory && $0.permissionMode == .ask })
        #expect(Set(fake.created.compactMap { $0.model?.description }) == ["mock/alpha", "mock/beta"])
        #expect(engine.state.sessions.count == 2)

        for name in ["Alpha", "Beta"] {
            let first = try #require(fake.sent(to: name).first)
            #expect(first.channel == .synthetic)
            #expect(!first.wake)
            #expect(first.text.hasPrefix("[Room] You are \(name), one of 2 agents"))
            #expect(first.text.contains("Mode: Debate."))
            #expect(first.text.contains("Alpha (mock/alpha), lead: Alpha role"))
            #expect(first.text.contains("Beta (mock/beta): Beta role"))
            #expect(first.text.contains("@Name"))
            #expect(first.text.contains("VERDICT:"))
            #expect(first.text.contains("Keep room messages short"))
            #expect(first.text.contains("Your role: \(name) role."))
        }
        #expect(fake.sent(to: "Alpha").first?.text.contains("You are the lead") == true)
        #expect(fake.sent(to: "Beta").first?.text.contains("The lead is Alpha.") == true)
    }

    @Test func twoAgentsTwoRoundsAndAVerdict() async throws {
        let fake = FakeEngine()
        scriptDebate(fake)
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 2)
        let engine = try await RoomFixtures.engine(spec, fake: fake)

        await engine.start(task: "SQLite or Postgres for the app's local cache?")
        try await engine.waitFor("the verdict", fake: fake) { $0.state.phase == .verdict }

        let debate = try #require(engine.state.debate)
        #expect(debate.verdict?.hasPrefix("Use SQLite.") == true)
        #expect(debate.verdict?.contains("Strongest dissent") == true)
        #expect(debate.arguments.count == 4)
        #expect(debate.arguments(inRound: 1).count == 2)
        #expect(debate.arguments(inRound: 2).count == 2)

        // Round 2 shows each agent the other's latest argument, not its own.
        let alphaRound2 = try #require(fake.wakes(to: "Alpha").first { $0.text.contains("Round 2 of 2") })
        #expect(alphaRound2.text.contains("Beta (mock/beta):\nUse Postgres. It scales."))
        #expect(!alphaRound2.text.contains("Use SQLite. It is simple"))
        let betaRound2 = try #require(fake.wakes(to: "Beta").first { $0.text.contains("Round 2 of 2") })
        #expect(betaRound2.text.contains("Alpha (mock/alpha):\nUse SQLite. It is simple and local."))

        // The judge sees every argument.
        let judge = try #require(fake.wakes(to: "Alpha").first { $0.text.contains("You are the judge") })
        #expect(judge.text.contains("Fair point. SQLite fits a desktop app."))
        #expect(judge.text.contains("Question: SQLite or Postgres"))
        #expect(fake.wakes(to: "Beta").allSatisfy { !$0.text.contains("You are the judge") })

        // Everything is on the board.
        let board = engine.state.board
        #expect(board.first { $0.from == .user }?.text == "SQLite or Postgres for the app's local cache?")
        let arguments = board.filter { $0.kind == .argument }
        #expect(arguments.count == 4)
        #expect(Set(arguments.compactMap(\.round)) == [1, 2])
        #expect(board.filter { $0.kind == .verdict }.count == 1)
        // Debate turns are room messages, never user prompts.
        #expect(fake.sent.allSatisfy { $0.channel == .synthetic })
        #expect(engine.state.usage[engine.id(of: "Alpha")]?.costUSD ?? 0 > 0)
    }

    @Test func buildItTurnsTheVerdictIntoATeamRun() async throws {
        let fake = FakeEngine()
        scriptDebate(fake)
        fake.on("Alpha", "Task for the room", reply: "PLAN: add SQLite\nASSIGN @Alpha: storage layer\nASSIGN @Beta: migrations", times: 1)
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"], permission: .ask, rounds: 2)
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        await engine.start(task: "SQLite or Postgres?")
        try await engine.waitFor("the verdict", fake: fake) { $0.state.phase == .verdict }

        await engine.buildVerdict()
        try await engine.waitFor("plan approval", fake: fake) { $0.state.pendingDecision == .approvePlan }

        #expect(engine.state.runMode == .team)
        #expect(engine.state.assignments.map(\.task) == ["storage layer", "migrations"])
        let planRequest = try #require(fake.wakes(to: "Alpha").first { $0.text.contains("Task for the room") })
        #expect(planRequest.text.contains("Build what the debate decided."))
        #expect(planRequest.text.contains("Use SQLite."))
        // Both agents were told the room switched modes.
        for name in ["Alpha", "Beta"] {
            #expect(fake.sent(to: name).contains { !$0.wake && $0.text.hasPrefix("[Room] The room switched to Team mode.") })
        }
        #expect(engine.state.debate?.verdict != nil)
    }

    @Test func buildItAsSoloUsesTheLead() async throws {
        let fake = FakeEngine()
        scriptDebate(fake)
        fake.on("Alpha", "Build what the debate decided", reply: "Added the SQLite cache.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 2), fake: fake)
        await engine.start(task: "SQLite or Postgres?")
        try await engine.waitFor("the verdict", fake: fake) { $0.state.phase == .verdict }

        await engine.buildVerdict(as: .solo)
        try await engine.waitFor("the solo run to finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.messages(from: "Alpha").last?.text == "Added the SQLite cache.")
        #expect(!fake.wakes(to: "Beta").contains { $0.text.contains("Build what the debate decided") })
    }

    @Test func userJudgesWhenThereIsNoLead() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], lead: nil, rounds: 1), fake: fake)
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("the user to judge", fake: fake) { $0.state.pendingDecision == .judge }
        #expect(engine.state.phase == .judging)

        await engine.submitVerdict("VERDICT: Spaces, because the style guide says so.")
        #expect(engine.state.phase == .verdict)
        #expect(engine.state.debate?.verdict == "Spaces, because the style guide says so.")
        #expect(engine.state.board.last?.from == .user)
        #expect(engine.state.board.last?.kind == .verdict)
    }

    @Test func verdictFormatRetrySucceeds() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "You are the judge", reply: "I think spaces win overall.")
        fake.on("Alpha", "restate your decision", reply: "VERDICT: Spaces.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1), fake: fake)
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("the verdict", fake: fake) { $0.state.phase == .verdict }
        #expect(engine.state.debate?.verdict == "Spaces.")
        let retries = fake.wakes(to: "Alpha").filter { $0.text.contains("restate your decision") }
        #expect(retries.count == 1)
        #expect(!engine.notices.contains { $0.contains("did not write VERDICT") })
    }

    @Test func debateAgainRestartsFromRoundOne() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Spaces.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1), fake: fake)
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("the verdict", fake: fake) { $0.state.phase == .verdict }

        await engine.debateAgain()
        try await engine.waitFor("the second verdict", fake: fake) { $0.state.phase == .verdict && $0.state.run == 2 }
        #expect(fake.wakes(to: "Beta").filter { $0.text.contains("Round 1 of 1") }.count == 2)
        #expect(engine.state.board.filter { $0.kind == .verdict }.count == 2)
    }
}
