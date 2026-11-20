import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// Regression tests for the room orchestration fixes: turn cleanup reentrancy, pause across awaits, spending caps during
/// a goal check or a takeover offer, stale interrupted turns, the live debate judge, stacked review stalemates, branch
/// names, merge verification and messages from other agents.
@Suite @MainActor struct RoomHardeningTests {
    // MARK: Turn cleanup (B1)

    @Test func aMessageSentWhileATurnIsFinishingWaitsAndKeepsItsOwnDuty() async throws {
        let fake = FakeEngine()
        // No text events: the room reads the reply from the transcript, and the hook below runs during that read.
        fake.on("Alpha", "first task", reply: "First answer.", textEvents: false)
        fake.on("Alpha", "second message", reply: "Second answer.", hold: true)
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        let alpha = engine.id(of: "Alpha")
        fake.onTranscript(for: "Alpha") {
            await engine.send("@Alpha second message")
        }

        await engine.start(task: "first task")
        try await engine.waitFor("the second turn to run", fake: fake) { engine in
            fake.isHeld("Alpha") && engine.finishing.isEmpty
        }
        // The first reply did not use up the second message's duty, and the second turn shows as working.
        #expect(engine.state.phase == .working)
        #expect(engine.state.duties[alpha]?.map(\.purpose) == [.solo])
        #expect(engine.activity[alpha] == .working)
        #expect(engine.messages(from: "Alpha").map(\.text) == ["First answer."])
        // The second message went out only after the first turn was handled, not into the turn being read.
        let second = try #require(fake.wakes(to: "Alpha").first { $0.text == "second message" })
        #expect(second.channel == .prompt)
        #expect(!second.busy)

        await fake.release("Alpha")
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.messages(from: "Alpha").map(\.text) == ["First answer.", "Second answer."])
    }

    // MARK: Pause across awaits (B2)

    @Test func pausingWhileChangedFilesAreReadSendsNoReviewUntilResume() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Alpha", "Reply DONE", reply: "DONE")
        fake.on("Beta", "Reply DONE", reply: "DONE")
        fake.on("Alpha", "Please review", reply: "APPROVE")
        fake.on("Beta", "Please review", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        // No git: changed files come from the engine, where the hook pauses the room once.
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let once = RoomHardeningOnce()
        fake.onChangedFiles { _ in
            if once.take() { await engine.pause() }
        }

        await engine.start(task: "Build it")
        try await engine.waitFor("the pause", fake: fake) { $0.state.isPaused }
        try await engine.waitForQuiet(fake: fake)
        #expect(engine.state.isPaused)
        #expect(!fake.sent.contains { $0.text.contains("Please review") }, "no review goes out after the pause")
        #expect(!engine.state.assignments.contains { $0.status == .inReview })

        await engine.resume()
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.state.assignments.allSatisfy { $0.status == .approved })
    }

    @Test func stoppingWhileChangedFilesAreReadEndsTheRunCleanly() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "You speak first", reply: "PLAN: one file.")
        fake.on("Beta", "Your turn (round 1", reply: "AGREE")
        fake.on("Alpha", "You build it", reply: "Wrote the file.")
        fake.on("Beta", "Review this build step", reply: "APPROVE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.roundTable, ["Alpha", "Beta"]), fake: fake)
        fake.onChangedFiles { _ in await engine.stop() }

        await engine.start(task: "Add a file.")
        try await engine.waitFor("the stop", fake: fake) { $0.state.phase == .stopped }
        try await engine.waitForQuiet(fake: fake)
        #expect(!fake.sent.contains { $0.text.contains("Review this build step") })
        #expect(engine.state.duties.isEmpty)
        #expect(engine.state.outbox.isEmpty)
    }

    // MARK: Spending caps (B6)

    @Test func aCappedGoalCheckerHandsTheCheckToAnotherAgent() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Goal check", reply: "Checking...", cost: 1.0, hold: true)
        fake.on("Alpha", "Goal: ship it", reply: "Shipped.")
        fake.on("Beta", "Goal check", reply: "Tests pass.\nGOAL MET")
        let spec = RoomFixtures.spec(.solo, ["Alpha", "Beta"], caps: ["Alpha": 0.5])
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        let alpha = engine.id(of: "Alpha")

        await engine.setGoal("ship it")
        try await engine.waitFor("the goal to be met", fake: fake) { engine in
            engine.state.phase == .finished && engine.state.goal?.status == .met
        }
        #expect(engine.state.cappedAgents == [alpha])
        #expect(engine.notices.contains("Beta takes over checking the goal."))
        #expect(fake.wakes(to: "Beta").contains { $0.text.contains("Goal check after run") })
        #expect(!engine.state.isPaused)
    }

    @Test func aCappedReviewersTakeoverOfferIsCancelledAndTheBuilderCarriesOn() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "You speak first", reply: "PLAN: one file hello.txt with a greeting.")
        fake.on("Beta", "Your turn (round 1", reply: "AGREE")
        fake.on("Gamma", "Your turn (round 1", reply: "AGREE")
        fake.on("Alpha", "You build it", reply: "Wrote the first half.")
        fake.on("Beta", "Review this build step", reply: "TAKEOVER")
        fake.on("Gamma", "Review this build step", reply: "APPROVE")
        fake.on("Alpha", "Keep building", reply: "Wrote the second half.\nDONE")
        let spec = RoomFixtures.spec(.roundTable, ["Alpha", "Beta", "Gamma"], permission: .ask, caps: ["Beta": 1.0])
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta")

        await engine.start(task: "Add a greeting file.")
        try await engine.waitFor("the takeover offer", fake: fake) { $0.state.pendingDecision == .takeover(agentID: beta) }

        // Beta goes over its cap while its offer waits for the user.
        let betaSession = try #require(fake.sessionID(of: "Beta"))
        fake.emit(.usageUpdated(sessionID: betaSession, Usage(outputTokens: 10, costUSD: 5.0)))
        try await engine.waitFor("the build to finish", fake: fake) { $0.state.phase == .finished }

        #expect(engine.state.cappedAgents == [beta])
        #expect(engine.state.roundTable?.builderID == alpha)
        #expect(engine.state.pendingDecision == nil)
        #expect(engine.notices.contains("Beta reached its spending cap, so its takeover offer was cancelled."))
        #expect(!fake.wakes(to: "Beta").contains { $0.text.contains("You are now the builder") })
    }

    // MARK: Stale turns and the live judge (B11)

    @Test func aDelayedInterruptedTurnDoesNotCountAsAnArgument() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.", hold: true)
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Tabs.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1), fake: fake)
        let alpha = engine.id(of: "Alpha")
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("Alpha working and Beta's argument", fake: fake) { engine in
            fake.isHeld("Alpha") && engine.state.debate?.arguments.count == 1
        }

        // An interrupted turn ends with some text while the room is running (a late event from an earlier interrupt).
        let alphaSession = try #require(fake.sessionID(of: "Alpha"))
        fake.emit(.textDelta(sessionID: alphaSession, itemID: "late", delta: "Partial tabs."))
        fake.emit(.executionEnded(sessionID: alphaSession, outcome: "interrupted", error: nil))
        try await engine.waitFor("the room to ask Alpha again", fake: fake) { _ in
            fake.wakes(to: "Alpha").contains { $0.text.hasPrefix("[Room] Your last reply was empty") }
        }
        #expect(engine.state.phase == .debating)
        #expect(engine.state.duties[alpha]?.contains { $0.purpose == .argue(round: 1) } == true)
        #expect(!(engine.state.debate?.arguments.contains { $0.text.contains("Partial") } ?? true))

        await fake.release("Alpha")
        try await engine.waitFor("the verdict", fake: fake) { $0.state.phase == .verdict }
        #expect(engine.state.debate?.arguments.map(\.text).sorted() == ["Spaces.", "Tabs."])
    }

    @Test func takingOverMidDebateMakesTheUserTheJudge() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.", hold: true)
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Tabs.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1), fake: fake)
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("Alpha working", fake: fake) { _ in fake.isHeld("Alpha") }
        #expect(engine.state.debate?.judgeID == engine.id(of: "Alpha"))

        engine.takeOver()
        await fake.release("Alpha")
        try await engine.waitFor("the user to judge", fake: fake) { $0.state.pendingDecision == .judge }
        #expect(engine.state.phase == .judging)
        #expect(engine.state.debate?.judgeID == nil)
        #expect(!fake.wakes(to: "Alpha").contains { $0.text.contains("You are the judge") })
    }

    @Test func twoStalematesAreDecidedOneAfterTheOther() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Alpha", "Please review Beta", reply: "CHANGES: beta still wrong")
        fake.on("Beta", "Please review Alpha", reply: "CHANGES: alpha still wrong")
        fake.on("Alpha", "CHANGES: alpha still wrong", reply: "Fixed.\nDONE")
        fake.on("Beta", "CHANGES: beta still wrong", reply: "Fixed.\nDONE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta")

        await engine.start(task: "Do it")
        try await engine.waitFor("both pieces stuck", fake: fake) { engine in
            engine.state.assignments.allSatisfy { $0.status == .changesRequested && $0.fixRounds >= RoomEngine.maxFixRounds }
                && engine.state.pendingDecision != nil
        }
        try await engine.waitForQuiet(fake: fake)
        guard case .reviewStalemate(let first)? = engine.state.pendingDecision else {
            Issue.record("Expected a review stalemate, got \(String(describing: engine.state.pendingDecision))")
            return
        }
        let second = first == alpha ? beta : alpha

        await engine.decideReview(for: first, .approve)
        // The other stalemate comes up next instead of being lost.
        #expect(engine.state.pendingDecision == .reviewStalemate(agentID: second))
        await engine.decideReview(for: second, .approve)
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.state.assignments.allSatisfy { $0.status == .approved })
    }

    // MARK: Branches and merges (B7)

    @Test func roomsWithTheSameTitleAndAgentsWithTheSameSlugGetTheirOwnBranches() async throws {
        let first = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Code Llama", "Code-Llama"]), fake: FakeEngine())
        let second = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Code Llama", "Code-Llama"]), fake: FakeEngine())
        let a = first.branchName(for: first.id(of: "Code Llama"))
        let b = first.branchName(for: first.id(of: "Code-Llama"))
        let c = second.branchName(for: second.id(of: "Code Llama"))
        #expect(Set([a, b, c]).count == 3)
        for branch in [a, b, c] {
            #expect(branch.hasPrefix("ensemble/test-room-"))
            #expect(throws: Never.self) { try ProcessGitOps.validateBranchName(branch) }
        }
    }

    @Test func unsafeBranchNamesAreRejected() {
        for bad in ["", "-x", "--force", "a..b", "a b", "a\u{1}b", "a\u{7F}b", "/a", "a/", "a.lock", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b", "a@{1}", ".a"] {
            #expect(throws: GitError.self, "\(bad.debugDescription)") { try ProcessGitOps.validateBranchName(bad) }
        }
        #expect(throws: Never.self) { try ProcessGitOps.validateBranchName("ensemble/room-1a2b3c/alpha-4d5e6f") }
    }

    @Test func aConflictReportedResolvedIsCheckedBeforeItCountsAsMerged() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Alpha", "Please review", reply: "APPROVE")
        fake.on("Beta", "Please review", reply: "APPROVE")
        fake.on("Alpha", "conflicts in: Shared.swift", reply: "Resolved.\nDONE")
        let git = FakeGitOps()
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake, git: git)
        let alpha = engine.id(of: "Alpha")
        let branch = engine.expectedBranch("Alpha")
        git.conflictOnce(branch: branch, files: ["Shared.swift"])
        // The lead says DONE, but git still has the conflict.
        git.setConflictStatus(GitConflictStatus(conflicts: ["Shared.swift"], mergeInProgress: true, branchMerged: false), for: branch)

        await engine.start(task: "Do it")
        try await engine.waitFor("the conflict to come back to the user", fake: fake) {
            $0.state.pendingDecision == .mergeConflict(agentID: alpha, files: ["Shared.swift"])
        }
        #expect(engine.state.phase == .merging)
        #expect(engine.state.assignments.first { $0.agentID == alpha }?.status == .approved)
        #expect(engine.notices.contains { $0.hasPrefix("Unresolved conflicts remain in Shared.swift.") })
        #expect(!engine.notices.contains { $0.contains("is resolved") })
    }

    // MARK: Messages from other agents (B13) and user turns (B5)

    @Test func anotherAgentsMessageIsNotTheUsersAndDoesNotResetTheRelayBudget() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a", hold: true)
        fake.on("Beta", "status?", reply: "All good.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"], permission: .ask), fake: fake)
        var userTurns = 0
        engine.onUserTurn = { _, _ in userTurns += 1 }

        await engine.start(task: "Build it")
        #expect(userTurns == 1)
        try await engine.waitFor("Alpha planning", fake: fake) { _ in fake.isHeld("Alpha") }
        engine.relayBudget = 2

        await engine.receiveExternalAgentMessage("status?", from: "Session B")
        try await engine.waitFor("Beta's answer", fake: fake) { $0.messages(from: "Beta").contains { $0.text == "All good." } }
        #expect(userTurns == 1)
        #expect(engine.relayBudget == 2)
        #expect(!engine.state.board.contains { $0.from == .user && $0.text.contains("status?") })
        let posted = try #require(engine.state.board.first { $0.text.contains("status?") })
        #expect(posted.from == .room)
        #expect(posted.kind == .notice)
        #expect(posted.text.hasPrefix("Message from Session B:"))
        #expect(fake.wakes(to: "Beta").contains { $0.channel == .synthetic && $0.text == "[Room] status?" })
        #expect(!fake.sent.contains { $0.channel == .prompt && $0.text.contains("status?") })
    }

    @Test func anotherAgentsMessageToAnIdleRoomStartsARunThatIsNotTheUsers() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "hello from elsewhere", reply: "Hi.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        var userTurns = 0
        engine.onUserTurn = { _, _ in userTurns += 1 }

        await engine.receiveExternalAgentMessage("hello from elsewhere")
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }
        #expect(userTurns == 0)
        #expect(!engine.state.board.contains { $0.from == .user })
        #expect(fake.wakes(to: "Alpha").contains { $0.channel == .synthetic && $0.text == "[Room] hello from elsewhere" })
        #expect(!fake.sent.contains { $0.channel == .prompt })
    }

    @Test func theUserTalkingInARoomReportsAUserTurnWithTheRoomsSessions() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "hi", reply: "Hello.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha", "Beta"]), fake: fake)
        var reported: [(UUID, Set<String>)] = []
        engine.onUserTurn = { room, sessions in reported.append((room, Set(sessions))) }

        await engine.send("@Alpha hi")
        #expect(reported.count == 1)
        #expect(reported.first?.0 == engine.state.id)
        #expect(reported.first?.1 == Set(engine.state.sessions.values))
        try await engine.waitForSettled(fake: fake)
    }
}

/// True the first time `take()` is called, false after.
final class RoomHardeningOnce: Sendable {
    private let taken = Mutex(false)

    func take() -> Bool {
        taken.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

/// `CHANGES:` must win over a later review or done word in the same reply (B4).
@Suite struct RoomReplyParserHardeningTests {
    let parser = RoomReplyParser(agentNames: ["Alpha", "Beta"])

    @Test func changesFollowedByApproveStillAskForChanges() {
        let reply = parser.parse("CHANGES: add a test for zero\nAPPROVE")
        #expect(reply.changes == "add a test for zero")
        #expect(reply.reviewVerdict == .changes("add a test for zero"))
    }

    @Test func changesWithBulletsFollowedByDoneKeepEveryBullet() {
        let reply = parser.parse("CHANGES:\n- rename the file\n- add docs\nDONE")
        #expect(reply.done)
        #expect(reply.changes?.contains("rename the file") == true)
        #expect(reply.changes?.contains("add docs") == true)
        #expect(reply.reviewVerdict == .changes(reply.changes ?? ""))
    }

    @Test func twoChangesSectionsAreBothKept() {
        let reply = parser.parse("CHANGES: first thing\nAGREE\nCHANGES: second thing")
        #expect(reply.changes?.contains("first thing") == true)
        #expect(reply.changes?.contains("second thing") == true)
    }

    @Test func changesNoneFollowedByApproveIsAnApproval() {
        let reply = parser.parse("CHANGES: none\nAPPROVE")
        #expect(reply.changes == nil)
        #expect(reply.reviewVerdict == .approve)
    }
}
