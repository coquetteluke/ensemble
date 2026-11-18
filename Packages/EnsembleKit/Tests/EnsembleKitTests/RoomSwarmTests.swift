import Foundation
import Testing
@testable import EnsembleKit

@Suite struct RoomSwarmTests {
    let a = UUID(), b = UUID(), c = UUID()

    var agents: [UUID] { [a, b, c] }

    /// User task, A asks B, B answers, A to B again, A posts a plan to the board, a room notice, C argues.
    var board: [BoardMessage] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            BoardMessage(from: .user, kind: .chat, text: "Build the API", date: start),
            BoardMessage(from: .agent(a), to: [b], kind: .question, text: "JSON or protobuf?", date: start + 60),
            BoardMessage(from: .agent(b), to: [a], kind: .chat, text: "JSON.", date: start + 120),
            BoardMessage(from: .agent(a), to: [b], kind: .chat, text: "Thanks.", date: start + 180),
            BoardMessage(from: .agent(a), kind: .plan, text: "PLAN: split it", date: start + 240),
            BoardMessage(from: .room, kind: .notice, text: "The plan is ready.", date: start + 241),
            BoardMessage(from: .agent(c), kind: .argument, round: 1, text: "Protobuf is faster.", date: start + 300),
        ]
    }

    // MARK: Graph

    @Test func edgesFromTheBoard() {
        let list = board
        let graph = RoomGraph.build(board: list, agents: agents)
        // The user's task to the whole room draws no lines.
        #expect(graph.nodes == [.agent(a), .agent(b), .agent(c)])
        #expect(graph.count(from: .user, to: .agent(a)) == 0)
        #expect(graph.count(from: .agent(a), to: .agent(b)) == 2)
        #expect(graph.count(from: .agent(b), to: .agent(a)) == 1)
        // A debate argument reaches every other agent.
        #expect(graph.count(from: .agent(c), to: .agent(a)) == 1)
        #expect(graph.count(from: .agent(c), to: .agent(b)) == 1)
        // Board posts and notices draw nothing.
        #expect(graph.count(from: .agent(a), to: .agent(c)) == 0)
        #expect(graph.edges.count == 4)
        #expect(graph.maxCount == 2)
        #expect(graph.messageCount == 7)
        // The latest message is C's argument.
        #expect(graph.latestMessageID == list[6].id)
        #expect(graph.latestFrom == .agent(c))
        #expect(graph.isLatest(RoomGraph.Edge(from: .agent(c), to: .agent(b), count: 1)))
        #expect(!graph.isLatest(RoomGraph.Edge(from: .agent(a), to: .agent(b), count: 2)))
    }

    @Test func unknownAgentsAndSelfMessagesAreLeftOut() {
        let stranger = UUID()
        let list = [
            BoardMessage(from: .agent(stranger), to: [a], kind: .chat, text: "hi"),
            BoardMessage(from: .agent(a), to: [a, stranger], kind: .chat, text: "note to self"),
            BoardMessage(from: .user, to: [b], kind: .chat, text: "only B"),
        ]
        let graph = RoomGraph.build(board: list, agents: agents)
        #expect(graph.edges.map(\.id) == [RoomGraph.Edge(from: .user, to: .agent(b), count: 1).id])
        #expect(graph.latestTo == [.agent(b)])
        // A user who writes to an agent by name is on the graph.
        #expect(graph.nodes.last == .user)
        #expect(RoomGraph.build(board: [BoardMessage](), agents: agents).nodes == [.agent(a), .agent(b), .agent(c)])
    }

    // MARK: Replay

    @Test func replaySteps() {
        let list = board
        #expect(RoomReplay.stepCount(list) == 7)
        #expect(RoomReplay.messages(list, at: nil).count == 7)
        #expect(RoomReplay.messages(list, at: 3).map(\.id) == list.prefix(3).map(\.id))
        #expect(RoomReplay.clamp(0, board: list) == 1)
        #expect(RoomReplay.clamp(99, board: list) == 7)
        #expect(RoomReplay.clamp(nil, board: list) == nil)
        #expect(RoomReplay.clamp(3, board: []) == nil)

        // The graph follows the step.
        let atTwo = RoomReplay.graph(list, agents: agents, at: 2)
        #expect(atTwo.count(from: .agent(a), to: .agent(b)) == 1)
        #expect(atTwo.count(from: .agent(b), to: .agent(a)) == 0)
        #expect(atTwo.latestMessageID == list[1].id)
        let atFour = RoomReplay.graph(list, agents: agents, at: 4)
        #expect(atFour.count(from: .agent(a), to: .agent(b)) == 2)
        // Steps that end on a post or a notice keep the last message that went somewhere as the latest.
        #expect(RoomReplay.graph(list, agents: agents, at: 6).latestMessageID == list[3].id)
        #expect(RoomReplay.message(list, at: 5)?.kind == .plan)

        // Skipping to the next step that changes the graph passes over the plan and the notice.
        #expect(RoomReplay.nextEdgeStep(list, agents: agents, after: 4) == 7)
        #expect(RoomReplay.nextEdgeStep(list, agents: agents, after: 7) == nil)
        #expect(RoomReplay.nextEdgeStep(list, agents: agents, after: 1) == 2)
    }

    // MARK: Follow

    @Test func followSwitchesOnHandOff() {
        var follow = RoomFollow()
        #expect(follow.update(working: []) == nil)
        #expect(follow.update(working: [a]) == a)
        // B starts while A still works: stay on A.
        #expect(follow.update(working: [a, b]) == a)
        // A hands off to B.
        #expect(follow.update(working: [b]) == b)
        // Nobody works: keep the last one.
        #expect(follow.update(working: []) == b)
        // Two start together: the first in the roster.
        #expect(follow.update(working: [a, c]) == a)
        // A stops while C works: C.
        #expect(follow.update(working: [c]) == c)
        // C keeps working when B starts later; then C stops and B (the newest) is shown.
        #expect(follow.update(working: [b, c]) == c)
        #expect(follow.update(working: [a, b]) == a, "A started after B, so A is the newest")
    }

    @Test func followCountsPermissionWaits() {
        let x = AgentSpec(name: "X", model: ModelRef(providerID: "m", id: "x"), colorHex: "#111111")
        let y = AgentSpec(name: "Y", model: ModelRef(providerID: "m", id: "y"), colorHex: "#222222")
        let activity: [UUID: AgentActivity] = [x.id: .waitingForPermission, y.id: .idle]
        #expect(RoomFollow.working([x, y]) { activity[$0] ?? .idle } == [x.id])
    }

    // MARK: Members

    @Test func teamMembers() {
        let names = RoomFixtures.agents(["Lead", "Builder", "Tester"])
        var state = RoomState(spec: RoomSpec(title: "T", directory: "/tmp", agents: names, mode: .team, leadAgentID: names[0].id))
        state.phase = .working
        state.assignments = [
            Assignment(agentID: names[0].id, task: "server", status: .approved, reviewerID: names[1].id),
            Assignment(agentID: names[1].id, task: "client", status: .inReview, reviewerID: names[2].id),
            Assignment(agentID: names[2].id, task: "tests", status: .working, reviewerID: names[0].id),
        ]
        state.duties = [names[2].id: [Duty(purpose: .review(authorID: names[1].id))]]
        state.usage = [names[1].id: Usage(costUSD: 0.42)]
        let members = RoomSwarm.members(state, activity: [names[2].id: .working])
        #expect(members.map(\.role) == [.lead, .builder, .reviewer])
        #expect(members.map(\.state) == [.finished, .standingBy, .active])
        #expect(members[0].step == "Piece approved")
        #expect(members[1].step == "Piece in review by Tester")
        #expect(members[2].step == "Reviewing Builder's piece")
        #expect(members[1].costUSD == 0.42)
    }

    @Test func membersWaitingAndStopped() {
        let names = RoomFixtures.agents(["Lead", "Two"], caps: ["Two": 1])
        var state = RoomState(spec: RoomSpec(title: "T", directory: "/tmp", agents: names, mode: .team, leadAgentID: names[0].id))
        state.phase = .awaitingApproval
        state.pendingDecision = .approvePlan
        state.cappedAgents = [names[1].id]
        let members = RoomSwarm.members(state)
        #expect(members[0].state == .waitingOnYou)
        #expect(members[0].step == "Waiting for you to approve the plan")
        #expect(members[1].state == .stopped)
        #expect(members[1].step == "Reached its spending cap")

        state.cappedAgents = []
        state.pendingDecision = nil
        state.phase = .working
        let prompted = RoomSwarm.members(state, activity: [names[1].id: .waitingForPermission])
        #expect(prompted[1].state == .waitingOnYou)
        #expect(prompted[1].step == "Waiting for permission")

        state.phase = .stopped
        #expect(RoomSwarm.members(state).allSatisfy { $0.state == .stopped })
    }

    @Test func debateAndRoundTableRoles() {
        let names = RoomFixtures.agents(["Judge", "Pro", "Con"])
        var debate = RoomState(spec: RoomSpec(title: "D", directory: "/tmp", agents: names, mode: .debate, leadAgentID: names[0].id))
        debate.phase = .debating
        debate.debate = DebateState(question: "Q", round: 2, totalRounds: 3, judgeID: names[0].id)
        debate.duties = [names[1].id: [Duty(purpose: .argue(round: 2))]]
        let d = RoomSwarm.members(debate)
        #expect(d.map(\.role) == [.judge, .debater, .debater])
        #expect(d[1].step == "Arguing, round 2")

        var table = RoomState(spec: RoomSpec(title: "R", directory: "/tmp", agents: names, mode: .roundTable, leadAgentID: names[0].id))
        table.phase = .building
        var rt = RoundTableState(order: names.map(\.id))
        rt.builderID = names[1].id
        table.roundTable = rt
        #expect(RoomSwarm.members(table).map(\.role) == [.lead, .builder, .reviewer])

        var finished = table
        finished.phase = .finished
        #expect(RoomSwarm.members(finished).allSatisfy { $0.state == .finished })

        var goal = table
        goal.phase = .checkingGoal
        goal.duties = [names[0].id: [Duty(purpose: .goalCheck)]]
        #expect(RoomSwarm.members(goal, activity: [names[0].id: .working])[0].step == "Checking the goal")
    }
}

@Suite @MainActor struct RoomGoalReloadTests {
    @Test func aGoalBetweenRunsWaitsAfterRelaunch() throws {
        let store = InMemoryRoomStore()
        var state = RoomState(spec: RoomFixtures.spec(.solo, ["Alpha"]))
        state.phase = .finished
        state.goal = GoalDriver.start(condition: "ship", budget: GoalBudget(), costNow: 0, unit: "run").0
        try store.save(state)
        let engine = try #require(try RoomEngine.load(roomID: state.id, api: FakeEngine(), store: store))
        defer { engine.close() }
        #expect(engine.state.goal?.status == .waiting)
        #expect(engine.state.goal?.statusLine == "Ensemble closed. Start a run to carry on.")
        #expect(engine.state.phase == .finished)
    }

    @Test func aRunAfterRelaunchCarriesTheGoalOn() async throws {
        let store = InMemoryRoomStore()
        let fake = FakeEngine()
        let spec = RoomFixtures.spec(.solo, ["Alpha"])
        let first = try await RoomFixtures.engine(spec, fake: fake, store: store)
        first.close()
        var state = first.state
        state.phase = .finished
        state.goal = GoalDriver.start(condition: "ship", budget: GoalBudget(), costNow: 0, unit: "run").0
        try store.save(state)
        fake.on("Alpha", "Carry on", reply: "Done.")
        fake.on("Alpha", "Goal check", reply: "GOAL MET: shipped")
        let engine = try #require(try RoomEngine.load(roomID: state.id, api: fake, store: store))
        defer { engine.close() }
        #expect(engine.state.goal?.status == .waiting)
        await engine.send("Carry on")
        try await engine.waitFor("the goal to end", fake: fake) { $0.state.goal?.isActive == false }
        #expect(engine.state.goal?.status == .met)
    }
}
