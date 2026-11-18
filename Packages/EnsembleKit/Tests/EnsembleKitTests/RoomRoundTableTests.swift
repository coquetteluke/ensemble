import Foundation
import Testing
@testable import EnsembleKit

@Suite @MainActor struct RoomRoundTableTests {
    func scriptDiscussion(_ fake: FakeEngine) {
        fake.on("Alpha", "You speak first", reply: "PLAN: one file hello.txt with a greeting.")
        fake.on("Beta", "Your turn (round 1", reply: "Markdown renders better.\nPLAN: one file hello.md with a greeting.")
        fake.on("Gamma", "Your turn (round 1", reply: "AGREE")
        fake.on("Alpha", "Your turn (round 2", reply: "Agreed.")
        fake.on("Alpha", "You build it", reply: "Wrote the first half of hello.md.")
    }

    @Test func reachesAgreementAndHandsOverOnTakeover() async throws {
        let fake = FakeEngine()
        scriptDiscussion(fake)
        fake.on("Beta", "Review this build step", reply: "TAKEOVER: I proposed markdown, let me finish it.", times: 1)
        fake.on("Gamma", "Review this build step", reply: "APPROVE")
        fake.on("Beta", "You are now the builder", reply: "Finished hello.md.\nDONE")
        fake.on("Alpha", "Review this build step", reply: "**APPROVE**")
        fake.setChangedFiles("Alpha", ["hello.md"])
        let spec = RoomFixtures.spec(.roundTable, ["Alpha", "Beta", "Gamma"], permission: .auto)
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        let alpha = engine.id(of: "Alpha"), beta = engine.id(of: "Beta")

        await engine.start(task: "Add a greeting file.")
        try await engine.waitFor("the build to finish", fake: fake) { $0.state.phase == .finished }

        let rt = try #require(engine.state.roundTable)
        // Discussion: lead first, everyone saw everything, all agreed on Beta's version.
        #expect(rt.order.first == alpha)
        #expect(rt.plan == "one file hello.md with a greeting.")
        #expect(rt.planAuthorID == beta)
        #expect(engine.state.plan == "one file hello.md with a greeting.")
        #expect(engine.notices.contains("Everyone agreed on the plan."))
        #expect(fake.sent(to: "Gamma").contains { !$0.wake && $0.text == "[Room] Alpha (mock/alpha) to you: PLAN: one file hello.txt with a greeting." })
        #expect(fake.sent(to: "Gamma").contains { !$0.wake && $0.text.hasPrefix("[Room] Task for the room:\nAdd a greeting file.") })
        #expect(fake.wakes(to: "Gamma").filter { $0.text.contains("Your turn") }.count == 1)

        // Build: Alpha built a step, Beta took over (automatic in Auto mode) and finished.
        #expect(rt.builderID == beta)
        #expect(rt.builderDone)
        #expect(engine.notices.contains("Beta takes over building from Alpha."))
        #expect(fake.sent(to: "Alpha").contains { !$0.wake && $0.text == "[Room] Beta (mock/beta) takes over building. You are a reviewer now." })
        let handoff = try #require(fake.wakes(to: "Beta").first { $0.text.contains("You are now the builder") })
        #expect(handoff.text.contains("taking over from Alpha"))
        #expect(handoff.text.contains("Plan:\none file hello.md with a greeting."))
        #expect(handoff.text.contains("Progress so far (from Alpha):\nWrote the first half of hello.md."))
        let reviewRequest = try #require(fake.wakes(to: "Gamma").first { $0.text.contains("Review this build step") })
        #expect(reviewRequest.text.contains("by Alpha (mock/alpha)"))
        #expect(reviewRequest.text.contains("Their update:\nWrote the first half of hello.md."))
        #expect(reviewRequest.text.contains("Changed files so far: hello.md"))
        #expect(fake.wakes(to: "Alpha").contains { $0.text.contains("Review this build step by Beta") })
        #expect(engine.notices.contains("Beta finished the build and every reviewer approved."))
        #expect(fake.unmatched.isEmpty, "\(fake.unmatched)")
    }

    @Test func takeoverWaitsForTheUserInAskMode() async throws {
        let fake = FakeEngine()
        scriptDiscussion(fake)
        fake.on("Beta", "Review this build step", reply: "TAKEOVER", times: 1)
        fake.on("Beta", "Review this build step", reply: "APPROVE")
        fake.on("Gamma", "Review this build step", reply: "APPROVE")
        fake.on("Beta", "You are now the builder", reply: "Done building.\nDONE")
        fake.on("Alpha", "Review this build step", reply: "APPROVE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.roundTable, ["Alpha", "Beta", "Gamma"], permission: .ask), fake: fake)
        let beta = engine.id(of: "Beta")
        await engine.start(task: "Add a greeting file.")
        try await engine.waitFor("the takeover offer", fake: fake) { $0.state.pendingDecision == .takeover(agentID: beta) }
        #expect(engine.state.roundTable?.builderID == engine.id(of: "Alpha"))
        #expect(engine.state.needsUser)

        await engine.acceptTakeover()
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.state.roundTable?.builderID == beta)
    }

    @Test func rejectedTakeoverKeepsTheBuilder() async throws {
        let fake = FakeEngine()
        scriptDiscussion(fake)
        fake.on("Beta", "Review this build step", reply: "TAKEOVER", times: 1)
        fake.on("Beta", "Review this build step", reply: "APPROVE")
        fake.on("Gamma", "Review this build step", reply: "APPROVE")
        fake.on("Alpha", "Keep building", reply: "Wrote the second half.\nDONE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.roundTable, ["Alpha", "Beta", "Gamma"], permission: .acceptEdits), fake: fake)
        let beta = engine.id(of: "Beta")
        await engine.start(task: "Add a greeting file.")
        try await engine.waitFor("the takeover offer", fake: fake) { $0.state.pendingDecision == .takeover(agentID: beta) }

        await engine.rejectTakeover()
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }
        #expect(engine.state.roundTable?.builderID == engine.id(of: "Alpha"))
        #expect(engine.notices.contains("Takeover rejected. Alpha keeps building."))
        #expect(fake.wakes(to: "Alpha").contains { $0.text.contains("Every reviewer approved this step. Keep building") })
    }

    @Test func noAgreementAfterFourRoundsTheLeadsVersionWins() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "You speak first", reply: "PLAN: tabs")
        fake.on("Alpha", "Your turn", reply: "PLAN: tabs, final")
        fake.on("Beta", "Your turn", reply: "PLAN: spaces")
        fake.on("Alpha", "You build it", reply: "Built it.\nDONE")
        fake.on("Beta", "Review this build step", reply: "CHANGES: use spaces", times: 1)
        fake.on("Alpha", "Reviewers asked for changes", reply: "Switched to spaces.\nDONE")
        fake.on("Beta", "Review this build step", reply: "APPROVE")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.roundTable, ["Alpha", "Beta"]), fake: fake)
        await engine.start(task: "Pick an indent style.")
        try await engine.waitFor("finish", fake: fake) { $0.state.phase == .finished }

        #expect(engine.notices.contains("No agreement after 4 rounds, so Alpha's last version of the plan wins."))
        #expect(engine.state.plan == "tabs, final")
        #expect(fake.wakes(to: "Beta").filter { $0.text.contains("Your turn") }.count == 4)
        #expect(fake.wakes(to: "Alpha").filter { $0.text.contains("Your turn") || $0.text.contains("You speak first") }.count == 4)
        let changes = try #require(fake.wakes(to: "Alpha").first { $0.text.contains("Reviewers asked for changes") })
        #expect(changes.text.contains("Beta (mock/beta): CHANGES: use spaces"))
        #expect(engine.state.roundTable?.buildTurns == 2)
    }
}
