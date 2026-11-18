import Foundation
import Testing
@testable import EnsembleKit

@Suite @MainActor struct RoomControlTests {
    /// A two- or three-agent Team in Auto mode where every piece is approved at once.
    func scriptEasyTeam(_ fake: FakeEngine, names: [String]) {
        let assigns = names.map { "ASSIGN @\($0): piece for \($0)" }.joined(separator: "\n")
        fake.on(names[0], "Task for the room", reply: "PLAN: split it\n\(assigns)")
        for name in names {
            fake.on(name, "Please review", reply: "APPROVE")
        }
        fake.on(names[0], "Post a short summary", reply: "Summary for the user.")
    }

    // MARK: Relay

    @Test func relayFormattingAndWakeRules() async throws {
        let fake = FakeEngine()
        scriptEasyTeam(fake, names: ["Alpha", "Beta", "Gamma"])
        fake.on("Alpha", "Your assignment: piece for Alpha", reply: """
        Started the API.
        @Beta: please use snake_case for JSON keys.
        @all: heads up, the API skeleton is in.
        @all: anyone need the schema?
        DONE
        """)
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Gamma", "Your assignment", reply: "DONE")
        fake.on("Beta", "snake_case", reply: "Will do.")
        fake.on("Beta", "anyone need the schema", reply: "No.")
        fake.on("Gamma", "anyone need the schema", reply: "No.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta", "Gamma"]), fake: fake)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta")

        #expect(engine.relayLine(from: alpha, text: "hi") == "[Room] Alpha (mock/alpha) to you: hi")

        await engine.start(task: "Build the API")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }

        // A direct @name wakes the receiver; @all without a question is for information only.
        let direct = fake.sent(to: "Beta").filter { $0.text == "[Room] Alpha (mock/alpha) to you: please use snake_case for JSON keys." }
        #expect(direct.count == 1)
        #expect(direct.first?.wake == true)
        #expect(direct.first?.channel == .synthetic)
        for name in ["Beta", "Gamma"] {
            let info = fake.sent(to: name).filter { $0.text == "[Room] Alpha (mock/alpha) to you: heads up, the API skeleton is in." }
            #expect(info.count == 1 && info.first?.wake == false, "\(name)")
            let question = fake.sent(to: name).filter { $0.text == "[Room] Alpha (mock/alpha) to you: anyone need the schema?" }
            #expect(question.count == 1 && question.first?.wake == true, "\(name)")
        }
        #expect(!fake.sent(to: "Alpha").contains { $0.text.hasPrefix("[Room] Alpha (mock/alpha)") })
        #expect(!fake.sent(to: "Gamma").contains { $0.text.contains("snake_case") })

        // Each relayed block and the rest of the turn are on the board.
        let board = engine.state.board
        let snake = try #require(board.first { $0.text == "please use snake_case for JSON keys." })
        #expect(snake.from == .agent(alpha))
        #expect(snake.to == [beta])
        #expect(snake.kind == .chat)
        #expect(board.first { $0.text == "heads up, the API skeleton is in." }?.to == [])
        #expect(board.first { $0.text == "anyone need the schema?" }?.kind == .question)
        let update = try #require(engine.messages(from: "Alpha").first { $0.kind == .update })
        #expect(update.text == "Started the API.\nDONE")
        #expect(engine.messages(from: "Beta").contains { $0.text == "Will do." })
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")
    }

    // MARK: User messages

    @Test func soloChatAndTranscriptFallback() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Write hello", reply: "Wrote hello.swift.")
        fake.on("Alpha", "Now add tests", reply: "Added HelloTests.swift.", textEvents: false)
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        #expect(fake.sent(to: "Alpha").first?.text.hasPrefix("[Room] You are Alpha, the only agent") == true)

        await engine.send("Write hello")
        try await engine.waitFor("first reply", fake: fake) { $0.state.phase == .finished }
        await engine.send("Now add tests")
        try await engine.waitFor("second reply", fake: fake) { $0.state.phase == .finished && $0.state.run == 2 }

        // The second reply had no text events, so the engine read it from the transcript.
        #expect(engine.messages(from: "Alpha").map(\.text) == ["Wrote hello.swift.", "Added HelloTests.swift."])
        #expect(fake.wakes(to: "Alpha").map(\.channel) == [.prompt, .prompt])
        #expect(fake.wakes(to: "Alpha").map(\.text) == ["Write hello", "Now add tests"])
        #expect(engine.state.board.filter { $0.from == .user }.map(\.text) == ["Write hello", "Now add tests"])
    }

    @Test func userTalksToOneAgentOrEveryone() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Spaces.")
        fake.on("Beta", "what about cost", reply: "Spaces cost nothing.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1), fake: fake)
        let beta = engine.id(of: "Beta")
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("verdict", fake: fake) { $0.state.phase == .verdict }

        await engine.send("@Beta what about cost?")
        try await engine.waitFor("Beta's answer", fake: fake) { $0.messages(from: "Beta").contains { $0.text == "Spaces cost nothing." } }
        let toBeta = try #require(fake.wakes(to: "Beta").last)
        #expect(toBeta.channel == .prompt)
        #expect(toBeta.text == "what about cost?")
        #expect(engine.state.board.contains { $0.from == .user && $0.to == [beta] && $0.text == "what about cost?" })
        #expect(!fake.wakes(to: "Alpha").contains { $0.text == "what about cost?" })

        await engine.send("Thanks, both of you.")
        try await engine.waitForSettled(fake: fake)
        #expect(fake.wakes(to: "Alpha").last?.text == "Thanks, both of you.")
        #expect(fake.wakes(to: "Beta").last?.text == "Thanks, both of you.")
        #expect(engine.state.board.contains { $0.from == .user && $0.to.isEmpty && $0.text == "Thanks, both of you." })
        #expect(engine.state.phase == .verdict)
    }

    // MARK: Pause, resume, stop

    @Test func pauseInterruptsAndResumeContinues() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.", hold: true)
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "The room resumed", reply: "Tabs, still.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Tabs.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1), fake: fake)
        let alpha = engine.id(of: "Alpha")
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("Alpha working and Beta's argument", fake: fake) { engine in
            fake.isHeld("Alpha") && engine.state.debate?.arguments.count == 1
        }

        await engine.pause()
        #expect(engine.state.isPaused)
        #expect(engine.state.interruptedAgents == [alpha])
        #expect(fake.interrupts == [fake.sessionID(of: "Alpha")!])
        try await engine.waitFor("Alpha idle", fake: fake) { $0.activity[alpha] == .idle }
        #expect(engine.state.phase == .debating)
        #expect(engine.state.duties[alpha]?.first?.purpose == .argue(round: 1))
        #expect(engine.notices.last == "Paused.")

        // Messages wait while paused.
        await engine.send("@Alpha keep it short")
        #expect(engine.state.outbox[alpha]?.count == 1)
        #expect(!fake.wakes(to: "Alpha").contains { $0.text == "keep it short" })

        await engine.resume()
        try await engine.waitFor("verdict", fake: fake) { $0.state.phase == .verdict }
        try await engine.waitForSettled(fake: fake)
        #expect(engine.state.debate?.verdict == "Tabs.")
        #expect(engine.state.debate?.arguments.map(\.text).sorted() == ["Spaces.", "Tabs, still."])
        #expect(fake.wakes(to: "Alpha").contains { $0.text.hasPrefix("[Room] The room resumed.") })
        #expect(fake.wakes(to: "Alpha").contains { $0.text == "keep it short" })
        #expect(engine.notices.contains("Resumed."))
    }

    @Test func stopEndsTheRunAndKeepsTheBoard() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a", times: 1, hold: true)
        fake.on("Alpha", "Task for the room", reply: "PLAN: y\nASSIGN @Alpha: b")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"], permission: .ask), fake: fake)
        let alpha = engine.id(of: "Alpha")
        await engine.start(task: "First task")
        try await engine.waitFor("Alpha planning", fake: fake) { _ in fake.isHeld("Alpha") }

        await engine.stop()
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.duties.isEmpty)
        #expect(engine.state.outbox.isEmpty)
        #expect(fake.interrupts == [fake.sessionID(of: "Alpha")!])
        #expect(engine.notices.last == "Stopped. The sessions and the board stay.")
        try await engine.waitFor("Alpha idle", fake: fake) { $0.activity[alpha] == .idle }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.board.contains { $0.text == "First task" })

        // A new run can start.
        await engine.start(task: "Second task")
        try await engine.waitFor("second plan", fake: fake) { $0.state.pendingDecision == .approvePlan }
        #expect(engine.state.run == 2)
        #expect(engine.state.assignments.map(\.task) == ["b"])
        #expect(engine.state.sessions.count == 2)
    }

    // MARK: Spending caps

    @Test func cappedDebaterIsStoppedAndTheDebateContinues() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 2", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 2", reply: "Spaces.", cost: 1.0, hold: true)
        fake.on("Alpha", "Round 2 of 2", reply: "Still tabs.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Tabs.")
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 2, caps: ["Beta": 0.5])
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        let beta = engine.id(of: "Beta")
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("verdict", fake: fake) { $0.state.phase == .verdict }

        #expect(engine.state.cappedAgents == [beta])
        #expect(engine.activity[beta] == .capped)
        #expect(engine.state.usage[beta]?.costUSD == 1.0)
        #expect(fake.interrupts.contains(fake.sessionID(of: "Beta")!))
        #expect(engine.notices.contains("Beta reached its spending cap ($1.00 of $0.50) and was stopped. It gets no more turns."))
        #expect(!fake.wakes(to: "Beta").contains { $0.text.contains("Round 2 of 2") })
        #expect(engine.state.debate?.arguments.map(\.text) == ["Tabs.", "Still tabs."])
        #expect(!engine.state.isPaused)
    }

    @Test func cappedSoloAgentPausesTheRoom() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Write it", reply: "Wrote it.", cost: 0.1)
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"], caps: ["Alpha": 0.05]), fake: fake)
        let alpha = engine.id(of: "Alpha")
        await engine.send("Write it")
        try await engine.waitFor("pause", fake: fake) { $0.state.isPaused }
        try await engine.waitForSettled(fake: fake)
        #expect(engine.state.pauseReason == "Paused: Alpha reached its spending cap.")
        #expect(engine.state.needsUser)
        // The reply that pushed it over the cap still reaches the board.
        #expect(engine.messages(from: "Alpha").map(\.text) == ["Wrote it."])

        engine.setSpendingCap(1.0, for: alpha)
        #expect(engine.state.cappedAgents.isEmpty)
        #expect(engine.activity[alpha] == .idle)
        await engine.resume()
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
    }

    @Test func cappedTeamWorkerIsDroppedAndReviewsSkipIt() async throws {
        let fake = FakeEngine()
        scriptEasyTeam(fake, names: ["Alpha", "Beta", "Gamma"])
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Gamma", "Your assignment", reply: "Working...", cost: 2.0, hold: true)
        let spec = RoomFixtures.spec(.team, ["Alpha", "Beta", "Gamma"], caps: ["Gamma": 1.0])
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta"), gamma = engine.id(of: "Gamma")
        await engine.start(task: "Build it")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }

        #expect(engine.state.assignments.first { $0.agentID == gamma }?.status == .dropped)
        #expect(engine.notices.contains("Gamma's piece is dropped."))
        // Beta's reviewer would be Gamma (next in the roster); it skips to Alpha.
        #expect(engine.state.assignments.first { $0.agentID == beta }?.reviewerID == alpha)
        #expect(!fake.wakes(to: "Gamma").contains { $0.text.contains("Please review") })
        #expect(!engine.state.isPaused)
    }

    // MARK: Format retry and fallback

    @Test func formatRetryThenFallback() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "I wrote the code.")
        fake.on("Beta", "[Room] Reply DONE on its own line", reply: "It is written, as I said.")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Please review Beta", reply: "Seems fine to me.")
        fake.on("Alpha", "Please give your review in the room format", reply: "Yes, fine.")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let beta = engine.id(of: "Beta")
        await engine.start(task: "Build it")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }

        #expect(fake.wakes(to: "Beta").filter { $0.text.hasPrefix("[Room] Reply DONE on its own line") }.count == 1)
        #expect(engine.notices.contains("Beta did not reply DONE, so the room treats the end of its turn as DONE."))
        #expect(fake.wakes(to: "Alpha").filter { $0.text.contains("Please give your review in the room format") }.count == 1)
        #expect(engine.notices.contains("Alpha did not give a review in the room format, so the room counts it as APPROVE."))
        #expect(engine.state.assignments.first { $0.agentID == beta }?.status == .approved)
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")
    }

    @Test func planWithoutAssignLinesFallsBackToTheLead() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "I will just do it all myself.")
        fake.on("Alpha", "restate your plan", reply: "Really, I will do it all.")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        await engine.start(task: "Fix the bug")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.state.assignments.map(\.agentID) == [engine.id(of: "Alpha")])
        #expect(engine.state.assignments.first?.task == "Fix the bug")
        #expect(engine.notices.contains("The plan had no usable ASSIGN lines, so Alpha takes the whole task and the others review."))
        #expect(fake.sent(to: "Beta").contains { !$0.wake && $0.text.contains("You have no build piece") })
    }

    @Test func idleRoomNudgesAnAgentWaitingForAnAnswer() async throws {
        let fake = FakeEngine()
        scriptEasyTeam(fake, names: ["Alpha", "Beta"])
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "@Alpha: which file should I use?")
        fake.on("Alpha", "which file should I use", reply: "Not sure yet.")
        fake.on("Beta", "[Room] Reply DONE on its own line", reply: "Picked one myself.\nDONE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        await engine.start(task: "Build it")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(fake.wakes(to: "Beta").filter { $0.text.hasPrefix("[Room] Reply DONE on its own line") }.count == 1)
        #expect(!engine.notices.contains { $0.contains("did not reply DONE") })
    }

    @Test func relayWakeBudgetStopsPingPong() async throws {
        let fake = FakeEngine()
        scriptEasyTeam(fake, names: ["Alpha", "Beta"])
        fake.on("Alpha", "Your assignment", reply: "@Beta: ping")
        fake.on("Beta", "Your assignment", reply: "@Alpha: ping")
        fake.on("Alpha", "to you: ping", reply: "@Beta: ping")
        fake.on("Beta", "to you: ping", reply: "@Alpha: ping")
        fake.on("Alpha", "[Room] Reply DONE", reply: "DONE")
        fake.on("Beta", "[Room] Reply DONE", reply: "DONE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        await engine.start(task: "Build it")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        let pings = fake.sent.filter { $0.wake && $0.text.hasSuffix("to you: ping") }
        #expect(pings.count <= RoomEngine.relayWakeLimit + 2)
        #expect(engine.notices.contains { $0.hasPrefix("Agents have woken each other") })
    }
}
