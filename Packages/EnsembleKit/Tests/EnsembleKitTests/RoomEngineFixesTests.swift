import Foundation
import Testing
@testable import EnsembleKit

/// Fixes found in live room tests: messages held for a busy agent, background subagents, and worktree edits.
@Suite @MainActor struct RoomEngineFixesTests {
    // MARK: Messages to a busy agent

    /// Beta finishes while Alpha (the lead) is still working. Beta's update goes to Alpha only for its information;
    /// before the fix it was injected into Alpha's running turn, which OpenCode answers inside that turn.
    @Test func messagesForABusyAgentWaitUntilItsTurnEnds() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: two parts\nASSIGN @Alpha: part a\nASSIGN @Beta: part b")
        fake.on("Alpha", "Your assignment: part a", reply: "Part a is in.\nDONE", hold: true)
        fake.on("Beta", "Your assignment: part b", reply: "Part b is built.\nDONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Please review Beta", reply: "Looks right.\nAPPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let alpha = engine.id(of: "Alpha")

        await engine.start(task: "Build both parts")
        try await engine.waitFor("Beta's update and review request to wait for Alpha", fake: fake) {
            !($0.state.held[alpha] ?? []).isEmpty && !($0.state.outbox[alpha] ?? []).isEmpty
        }
        #expect(fake.isHeld("Alpha"))
        #expect(engine.state.held[alpha]?.count == 1)
        #expect(engine.state.held[alpha]?.first?.hasPrefix("[Room] Beta (mock/beta) to you: Part b is built.") == true)
        #expect(!fake.sent(to: "Alpha").contains { $0.text.contains("Part b is built") }, "nothing reaches Alpha mid-turn")
        // Beta's review request for Alpha waits in the outbox too.
        #expect(engine.state.outbox[alpha]?.contains { $0.text.contains("Please review Beta") } == true)

        await fake.release("Alpha")
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }

        #expect(fake.sent.filter { !$0.wake && $0.busy }.isEmpty, "\(fake.sent.filter { !$0.wake && $0.busy })")
        let toAlpha = fake.sent(to: "Alpha")
        let note = try #require(toAlpha.firstIndex { !$0.wake && $0.text.contains("Part b is built") })
        let review = try #require(toAlpha.firstIndex { $0.wake && $0.text.contains("Please review Beta") })
        #expect(note < review, "the held update arrives before Alpha's next turn")
        #expect(engine.state.held.isEmpty)
        // Every review reads exactly as the reviewer wrote it.
        #expect(engine.state.board.filter { $0.kind == .review }.map(\.text).sorted() == ["APPROVE", "Looks right.\nAPPROVE"])
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")
    }

    /// An APPROVE relayed to an author that is busy reviewing someone else waits for that review to end.
    @Test func approvalForABusyAuthorWaitsForItsReview() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: p\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE", hold: true)
        fake.on("Alpha", "Please review Beta", reply: "APPROVE", hold: true)
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta")

        await engine.start(task: "Build it")
        try await engine.waitFor("both reviews to run", fake: fake) { _ in fake.isHeld("Alpha") && fake.isHeld("Beta") }
        await fake.release("Beta")
        try await engine.waitFor("Alpha's piece to be approved", fake: fake) {
            $0.state.assignments.first { $0.agentID == alpha }?.status == .approved
        }
        // Alpha leads, so it gets Beta's review as the lead and the APPROVE as the author; both wait.
        #expect(engine.state.held[alpha] == ["[Room] Beta (mock/beta) to you: APPROVE", "[Room] Beta (mock/beta) to you: APPROVE"])
        await fake.release("Alpha")
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }
        #expect(fake.sent.filter { !$0.wake && $0.busy }.isEmpty, "\(fake.sent.filter { !$0.wake && $0.busy })")
        #expect(fake.sent(to: "Alpha").contains { !$0.wake && $0.text == "[Room] Beta (mock/beta) to you: APPROVE" })
        #expect(engine.state.assignments.allSatisfy { $0.status == .approved })
        #expect(engine.state.held[beta] == nil)
    }

    @Test func heldMessagesSurviveARestart() throws {
        var state = RoomState(spec: RoomFixtures.spec(.team, ["Alpha", "Beta"]))
        let alpha = state.spec.agents[0].id
        state.held[alpha] = ["[Room] Beta (mock/beta) to you: done"]
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(RoomState.self, from: data).held == state.held)
        // Rooms saved before `held` existed still load.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["held"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(RoomState.self, from: old).held.isEmpty)
    }

    // MARK: Background subagents

    /// Beta starts a background subagent and its turn ends without DONE. The room waits for the subagent, holds
    /// the review request it would send Beta, and takes the DONE from the turn the subagent's result starts.
    @Test func backgroundSubagentsKeepTheirAgentWorking() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: p\nASSIGN @Alpha: part a\nASSIGN @Beta: part b")
        fake.on("Alpha", "Your assignment: part a", reply: "Part a is in.\nDONE")
        fake.on("Beta", "Your assignment: part b", reply: "I started a helper for part b.", hold: true)
        fake.on("Beta", "<subagent", reply: "The helper finished part b.\nDONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Please review Beta", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let beta = engine.id(of: "Beta")
        engine.subagentSettleDelay = .milliseconds(50)

        await engine.start(task: "Build both parts")
        try await engine.waitFor("Beta to work", fake: fake) { _ in fake.isHeld("Beta") }
        let betaSession = try #require(fake.sessionID(of: "Beta"))
        let child = "ses_child_1"
        fake.emit(.sessionCreated(EngineSession(id: child, parentID: betaSession, title: "Helper", directory: "/tmp")))
        fake.emit(.activity(sessionID: child, .working))
        try await engine.waitFor("the subagent to count", fake: fake) { $0.hasWorkingSubagents(beta) }
        await fake.release("Beta")

        // Beta's turn ended without DONE while its subagent works: no nudge, no fallback, nothing new for Beta.
        try await engine.waitFor("Alpha's piece to wait for Beta's review", fake: fake) {
            $0.state.outbox[beta]?.contains { $0.text.contains("Please review Alpha") } == true
        }
        // Everything the room does about Beta's finished turn has happened. A check on Beta would come from the settle
        // timer, which nothing announces, so give it time to fire as well.
        try await engine.waitForQuiet(fake: fake)
        try await Task.sleep(for: engine.subagentSettleDelay * 3)
        #expect(!fake.sent(to: "Beta").contains { $0.text.hasPrefix("[Room] Reply DONE on its own line") })
        #expect(!engine.notices.contains { $0.contains("did not reply DONE") })
        #expect(engine.state.assignments.first { $0.agentID == beta }?.status == .working)
        #expect(engine.state.phase == .working)
        #expect(!fake.isBusy("Beta"))

        // The subagent finishes and the engine wakes Beta with its result, as OpenCode does.
        fake.emit(.executionEnded(sessionID: child, outcome: "succeeded", error: nil))
        try await fake.injectSynthetic(betaSession, text: "<subagent id=\"\(child)\" state=\"completed\">Part b is done.</subagent>", wake: true)
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }

        let wakes = fake.wakes(to: "Beta").map(\.text)
        let result = try #require(wakes.firstIndex { $0.hasPrefix("<subagent") })
        let review = try #require(wakes.firstIndex { $0.contains("Please review Alpha") })
        #expect(result < review, "the review request waited for the subagent")
        #expect(!wakes.contains { $0.hasPrefix("[Room] Reply DONE on its own line") })
        #expect(engine.messages(from: "Beta").contains { $0.text.hasPrefix("The helper finished part b.") })
        #expect(!engine.notices.contains { $0.contains("did not reply DONE") })
        #expect(engine.state.assignments.allSatisfy { $0.status == .approved })
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")
    }

    /// When the subagent finishes and nothing wakes its agent, the room asks the agent for DONE itself.
    @Test func finishedSubagentWithoutWakeLeadsToANudge() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: p\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "Started a helper.", hold: true)
        fake.on("Beta", "[Room] Reply DONE on its own line", reply: "The helper is done.\nDONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Please review Beta", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let beta = engine.id(of: "Beta")
        engine.subagentSettleDelay = .milliseconds(50)

        await engine.start(task: "Build it")
        try await engine.waitFor("Beta to work", fake: fake) { _ in fake.isHeld("Beta") }
        let betaSession = try #require(fake.sessionID(of: "Beta"))
        // The subagent is learned from the tool card's child session (no sessionCreated event).
        fake.emit(.toolUpdated(sessionID: betaSession, ToolCallInfo(id: "tool_1", name: "subagent", title: "Helper", status: .running,
                                                                     childSessionID: "ses_child_2")))
        fake.emit(.activity(sessionID: "ses_child_2", .working))
        try await engine.waitFor("the subagent to count", fake: fake) { $0.hasWorkingSubagents(beta) }
        await fake.release("Beta")
        // Everything the room does about Beta's finished turn has happened; the subagent still works. A nudge would
        // come from the settle timer, which nothing announces, so give it time to fire as well.
        try await engine.waitForQuiet(fake: fake)
        try await Task.sleep(for: engine.subagentSettleDelay * 3)
        #expect(!fake.sent(to: "Beta").contains { $0.text.hasPrefix("[Room] Reply DONE on its own line") })

        let sentBefore = fake.sent.count
        fake.emit(.activity(sessionID: "ses_child_2", .idle))
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }
        let nudge = try #require(fake.sent.firstIndex { $0.agent == "Beta" && $0.text.hasPrefix("[Room] Reply DONE on its own line") })
        #expect(nudge >= sentBefore, "the nudge came only after the subagent finished")
        #expect(!engine.notices.contains { $0.contains("did not reply DONE") })
    }

    @Test func reconnectForgetsSubagentsItCannotTrack() async throws {
        let fake = FakeEngine()
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake)
        let alpha = engine.id(of: "Alpha")
        let session = try #require(fake.sessionID(of: "Alpha"))
        fake.emit(.sessionCreated(EngineSession(id: "child_a", parentID: session, title: "Helper", directory: "/tmp")))
        fake.emit(.sessionCreated(EngineSession(id: "grandchild_a", parentID: "child_a", title: "Helper's helper", directory: "/tmp")))
        fake.emit(.activity(sessionID: "grandchild_a", .working))
        try await engine.waitFor("the grandchild to count", fake: fake) { $0.hasWorkingSubagents(alpha) }
        fake.emit(.other(type: "server.connected"))
        try await engine.waitFor("the subagents to be forgotten", fake: fake) { !$0.hasWorkingSubagents(alpha) }
        #expect(engine.workingSubagents.isEmpty)
    }

    // MARK: Worktrees

    @Test func worktreeEditsAreAllowedBeforeEveryWorkMessage() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: p\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Please review Beta", reply: "CHANGES: rename the file", times: 1)
        fake.on("Alpha", "Please review Beta", reply: "APPROVE")
        fake.on("Beta", "rename the file", reply: "Renamed.\nDONE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake, git: FakeGitOps())
        await engine.start(task: "Build it")
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }

        let root = "/tmp/ensemble-room-test/.ensemble/worktrees/"
        let grants = fake.worktreeGrants
        #expect(grants.filter { $0.agent == "Alpha" }.map(\.path) == [root + "ensemble-test-room-alpha"])
        // Beta's first piece and its fix round.
        #expect(grants.filter { $0.agent == "Beta" }.map(\.path) == [root + "ensemble-test-room-beta", root + "ensemble-test-room-beta"])
        // Each grant comes before the work message it is for.
        for grant in grants {
            let next = fake.sent.dropFirst(grant.sentCount).first { $0.agent == grant.agent && $0.wake }
            #expect(next.map { $0.text.contains("Your assignment") || $0.text.contains("CHANGES:") } == true, "\(String(describing: next))")
        }
    }

    @Test func noWorktreeNoGrant() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: p\nASSIGN @Alpha: a\nASSIGN @Beta: b")
        fake.on("Alpha", "Your assignment", reply: "DONE")
        fake.on("Beta", "Your assignment", reply: "DONE")
        fake.on("Beta", "Please review Alpha", reply: "APPROVE")
        fake.on("Alpha", "Please review Beta", reply: "APPROVE")
        fake.on("Alpha", "Post a short summary", reply: "Summary.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"]), fake: fake,
                                                   git: FakeGitOps(isRepository: false))
        await engine.start(task: "Build it")
        try await engine.waitFor("the run to finish", fake: fake) { $0.state.phase == .finished }
        #expect(fake.worktreeGrants.isEmpty)
    }

    @Test func worktreePathsRelativeToTheRoomFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-wt-\(UUID().uuidString.prefix(6))")
        let worktree = base.appendingPathComponent(".ensemble/worktrees/ensemble-room-ada")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // `temporaryDirectory` goes through the /var symlink; both spellings work.
        #expect(RoomWorktreePaths.relative(worktree.path, inside: base.path) == ".ensemble/worktrees/ensemble-room-ada")
        #expect(RoomWorktreePaths.relative(worktree.resolvingSymlinksInPath().path, inside: base.path) == ".ensemble/worktrees/ensemble-room-ada")
        // Only a worktree folder directly in `.ensemble/worktrees` of this folder.
        #expect(RoomWorktreePaths.relative(base.appendingPathComponent(".git").path, inside: base.path) == nil)
        #expect(RoomWorktreePaths.relative(worktree.appendingPathComponent("src").path, inside: base.path) == nil)
        #expect(RoomWorktreePaths.relative(worktree.path, inside: worktree.path) == nil)
        #expect(RoomWorktreePaths.relative("/elsewhere/.ensemble/worktrees/x", inside: base.path) == nil)
    }
}
