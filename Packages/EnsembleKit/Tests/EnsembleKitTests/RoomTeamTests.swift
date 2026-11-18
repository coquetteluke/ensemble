import Foundation
import Testing
@testable import EnsembleKit

@Suite @MainActor struct RoomTeamTests {
    /// Alpha leads. Beta asks Alpha a question mid-work; Gamma asks Beta for one fix before approving.
    func scriptTeam(_ fake: FakeEngine) {
        fake.on("Alpha", "Task for the room", reply: """
        Here's how we split it.

        **PLAN:** Build a tiny calculator with tests and docs.
        - ASSIGN @Alpha: write Calc.swift
        - ASSIGN @Beta: write CalcTests.swift
        - **ASSIGN @Gamma:** write README.md
        """)
        fake.on("Alpha", "Your assignment: write Calc.swift", reply: "Calc.swift has add, sub, mul and div.\nDONE")
        fake.on("Beta", "Your assignment: write CalcTests.swift", reply: "@Alpha: should add() wrap on overflow?")
        fake.on("Alpha", "should add() wrap on overflow", reply: "@Beta: no, trap on overflow like Swift does.")
        fake.on("Beta", "trap on overflow", reply: "Tests written for all four operations.\nDONE")
        fake.on("Gamma", "Your assignment: write README.md", reply: "README has usage and examples.\n\nDONE")
        // Reviews go round robin: Beta reviews Alpha, Gamma reviews Beta, Alpha reviews Gamma.
        fake.on("Beta", "Please review Alpha", reply: "Clean code.\nAPPROVE")
        fake.on("Gamma", "Please review Beta", reply: "CHANGES: add a test for division by zero", times: 1)
        fake.on("Gamma", "Please review Beta", reply: "Looks good now.\n**APPROVE**")
        fake.on("Beta", "add a test for division by zero", reply: "Added the division by zero test.\nDONE")
        fake.on("Alpha", "Please review Gamma", reply: "Review: APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Built the calculator: Alpha wrote Calc.swift, Beta the tests, Gamma the README. Nothing left.")
    }

    @Test func threeAgentTeamPlansApprovesBuildsReviewsMergesAndSumsUp() async throws {
        let fake = FakeEngine()
        scriptTeam(fake)
        let git = FakeGitOps()
        let store = InMemoryRoomStore()
        let spec = RoomFixtures.spec(.team, ["Alpha", "Beta", "Gamma"], permission: .ask)
        let engine = try await RoomFixtures.engine(spec, fake: fake, store: store, git: git)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta"), gamma = engine.id(of: "Gamma")

        await engine.start(task: "Build a small calculator library.")

        // 1-2. Plan, then wait for approval in Ask mode.
        try await engine.waitFor("plan approval", fake: fake) { $0.state.pendingDecision == .approvePlan }
        #expect(engine.state.phase == .awaitingApproval)
        #expect(engine.state.plan?.hasPrefix("Build a tiny calculator") == true)
        #expect(engine.state.assignments.map(\.agentID) == [alpha, beta, gamma])
        #expect(engine.state.assignments.map(\.task) == ["write Calc.swift", "write CalcTests.swift", "write README.md"])
        #expect(engine.state.assignments.allSatisfy { $0.status == .pending })
        #expect(engine.messages(from: "Alpha").first?.kind == .plan)
        let planRequest = try #require(fake.wakes(to: "Alpha").first)
        #expect(planRequest.text.contains("Task for the room:\nBuild a small calculator library."))
        #expect(planRequest.text.contains("Agents: Alpha, Beta, Gamma."))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!fake.sent.contains { $0.text.contains("Your assignment") }, "work must wait for approval")
        #expect(git.worktrees.isEmpty)

        // 3. Work in parallel, each in its own worktree.
        await engine.approvePlan()
        try await engine.waitFor("the run to finish", timeout: .seconds(10), fake: fake) { $0.state.phase == .finished }

        #expect(git.worktrees == ["ensemble/test-room/alpha", "ensemble/test-room/beta", "ensemble/test-room/gamma"])
        let work = try #require(fake.wakes(to: "Beta").first { $0.text.contains("Your assignment") })
        #expect(work.text.contains("Work only in your own git worktree: /tmp/ensemble-room-test/.ensemble/worktrees/ensemble-test-room-beta (branch ensemble/test-room/beta)"))
        #expect(work.text.contains("questions usually go to Alpha"))
        #expect(work.text.contains("Plan:\nBuild a tiny calculator"))

        // Beta's question was relayed to Alpha in the room format and woke Alpha; the answer came back.
        #expect(fake.wakes(to: "Alpha").contains { $0.text == "[Room] Beta (mock/beta) to you: should add() wrap on overflow?" })
        #expect(fake.wakes(to: "Beta").contains { $0.text == "[Room] Alpha (mock/alpha) to you: no, trap on overflow like Swift does." })
        let question = try #require(engine.state.board.first { $0.text == "should add() wrap on overflow?" })
        #expect(question.from == .agent(beta))
        #expect(question.to == [alpha])
        #expect(question.kind == .question)

        // 4. Review: round robin, one CHANGES round for Beta, then APPROVE.
        let assignments = engine.state.assignments
        #expect(assignments.first { $0.agentID == alpha }?.reviewerID == beta)
        #expect(assignments.first { $0.agentID == beta }?.reviewerID == gamma)
        #expect(assignments.first { $0.agentID == gamma }?.reviewerID == alpha)
        #expect(assignments.first { $0.agentID == beta }?.fixRounds == 1)
        #expect(fake.wakes(to: "Gamma").filter { $0.text.contains("Please review Beta") }.count == 2)
        let fix = try #require(fake.wakes(to: "Beta").first { $0.text.contains("division by zero") })
        #expect(fix.text.hasPrefix("[Room] Gamma (mock/gamma) to you: CHANGES: add a test for division by zero"))
        let review = try #require(fake.wakes(to: "Alpha").first { $0.text.contains("Please review Gamma") })
        #expect(review.text.contains("Changed files: ensemble-test-room-gamma.txt"))
        #expect(review.text.contains("Assignment: write README.md"))

        // 5. Merge in assignment order through GitOps.
        #expect(git.merges == [
            FakeGitOps.Merge(branch: "ensemble/test-room/alpha", base: "main"),
            FakeGitOps.Merge(branch: "ensemble/test-room/beta", base: "main"),
            FakeGitOps.Merge(branch: "ensemble/test-room/gamma", base: "main"),
        ])
        #expect(git.commits.count == 3)
        #expect(engine.state.assignments.allSatisfy { $0.status == .merged })
        #expect(engine.notices.contains("Merged ensemble/test-room/beta into main."))

        // 6. Summary from the lead.
        let summaryRequest = try #require(fake.wakes(to: "Alpha").first { $0.text.contains("Post a short summary") })
        #expect(summaryRequest.text.contains("merged into main"))
        #expect(engine.messages(from: "Alpha").last?.text.hasPrefix("Built the calculator") == true)

        // Board kinds and progress relays to the lead.
        #expect(engine.state.board.filter { $0.kind == .assignment }.count == 3)
        #expect(engine.state.board.contains { $0.kind == .review && $0.from == .agent(gamma) && $0.text.hasPrefix("CHANGES:") })
        #expect(fake.sent(to: "Alpha").contains { !$0.wake && $0.text == "[Room] Gamma (mock/gamma) to you: README has usage and examples.\n\nDONE" })
        #expect(fake.sent(to: "Alpha").contains { !$0.wake && $0.text == "[Room] Beta (mock/beta) to you: APPROVE" })
        #expect(fake.sent(to: "Gamma").contains { !$0.wake && $0.text == "[Room] Alpha (mock/alpha) to you: APPROVE" })
        #expect(engine.state.duties.isEmpty)
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")

        // Saved as it went.
        #expect(try store.load(spec.id) == engine.state)
    }

    @Test func autoModeStartsWorkWithoutApproval() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: split\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment: a", reply: "DONE")
        fake.on("Beta", "Your assignment: b", reply: "DONE")
        fake.on("Alpha", "Please review", reply: "APPROVE")
        fake.on("Beta", "Please review", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "All done.")
        let git = FakeGitOps(isRepository: false)
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"], permission: .auto), fake: fake, git: git)
        await engine.start(task: "Do it")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.notices.contains { $0.contains("not a git repository") })
        #expect(git.worktrees.isEmpty)
        #expect(git.merges.isEmpty)
        let work = try #require(fake.wakes(to: "Beta").first { $0.text.contains("Your assignment") })
        #expect(work.text.contains("Everyone works in /tmp/ensemble-room-test. Edit only the files your assignment gives you."))
        #expect(engine.state.assignments.allSatisfy { $0.status == .approved })
    }

    @Test func editAndRedoThePlan() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: first\nASSIGN @Alpha: everything", times: 1)
        fake.on("Alpha", "wants a different plan", reply: "PLAN: second\nASSIGN @Alpha: api\nASSIGN @Beta: ui")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"], permission: .acceptEdits), fake: fake)
        await engine.start(task: "Build it")
        try await engine.waitFor("first plan", fake: fake) { $0.state.pendingDecision == .approvePlan }
        #expect(engine.state.assignments.count == 1)

        await engine.redoPlan(feedback: "Give Beta real work.")
        try await engine.waitFor("second plan", fake: fake) { $0.state.pendingDecision == .approvePlan && $0.state.plan?.hasPrefix("second") == true }
        #expect(fake.wakes(to: "Alpha").last?.text.contains("Their feedback: Give Beta real work.") == true)
        #expect(engine.state.assignments.map(\.task) == ["api", "ui"])

        await engine.submitPlan("No ASSIGN lines here")
        #expect(engine.lastError?.contains("ASSIGN") == true)
        #expect(engine.state.pendingDecision == .approvePlan)

        await engine.submitPlan("PLAN: mine\nASSIGN @Beta: everything")
        #expect(engine.state.phase == .working)
        #expect(engine.state.assignments.map(\.agentID) == [engine.id(of: "Beta")])
        #expect(engine.state.board.contains { $0.from == .user && $0.kind == .plan })
        try await engine.waitFor("Beta's work request", fake: fake) { _ in fake.wakes(to: "Beta").contains { $0.text.contains("Your assignment: everything") } }
        await engine.stop()
    }

    @Test func mergeConflictGoesToTheLead() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Alpha", "Please review", reply: "APPROVE")
        fake.on("Beta", "Please review", reply: "APPROVE")
        fake.on("Alpha", "conflicts in: Shared.swift", reply: "Resolved and committed.\nDONE")
        fake.on("Alpha", "Post a short summary", reply: "Done, with one conflict fixed.")
        let git = FakeGitOps()
        git.conflictOnce(branch: "ensemble/test-room/alpha", files: ["Shared.swift"])
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake, git: git)
        await engine.start(task: "Do it")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.notices.contains { $0.contains("conflicts in Shared.swift. Alpha resolves it.") })
        #expect(git.merges.map(\.branch) == ["ensemble/test-room/alpha", "ensemble/test-room/beta"])
        #expect(engine.state.assignments.allSatisfy { $0.status == .merged })
    }

    @Test func reviewStalemateGoesToTheUser() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: x\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Alpha", "CHANGES: still wrong", reply: "Fixed.\nDONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Beta", "Please review Alpha", reply: "CHANGES: still wrong")
        fake.on("Alpha", "Please review Beta", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let alpha = engine.id(of: "Alpha")
        await engine.start(task: "Do it")
        try await engine.waitFor("stalemate", fake: fake) { $0.state.pendingDecision == .reviewStalemate(agentID: alpha) }
        #expect(engine.state.assignments.first { $0.agentID == alpha }?.fixRounds == 2)
        #expect(fake.wakes(to: "Beta").filter { $0.text.contains("Please review Alpha") }.count == 3)

        await engine.decideReview(for: alpha, .approve)
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.notices.contains("You approved Alpha's piece."))
    }

    @Test func userAsLeadWritesThePlan() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        engine.takeOver()
        await engine.start(task: "Do it")
        #expect(engine.state.pendingDecision == .writePlan)
        await engine.submitPlan("ASSIGN @Alpha: everything")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.notices.contains { $0.hasPrefix("Run finished. Alpha: everything (approved)") })
        #expect(!fake.sent.contains { $0.text.contains("Post a short summary") })
    }
}
