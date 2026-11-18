import Foundation
import Testing
@testable import EnsembleKit

/// The room's goal and Members list on the phone: additive fields that old frames and old phones live without.
@Suite @MainActor struct RemoteSwarmTests {
    func room(goal: RemoteGoal? = nil, members: [RemoteMember] = []) -> RemoteRoom {
        let agent = RemoteAgent(id: UUID(), name: "Opus", model: "anthropic/claude-opus-5-5", colorHex: "#A78BFA")
        return RemoteRoom(id: UUID(), title: "Settings", directory: "/tmp/app", mode: .team, agents: [agent], state: .running,
                          permissionMode: .auto, sessionID: "room", lastActivity: Date(timeIntervalSince1970: 1_800_000_000),
                          goal: goal, members: members)
    }

    @Test func roundTrip() throws {
        let id = UUID()
        let original = room(goal: RemoteGoal(condition: "all tests pass", active: true, statusLabel: "Run 2 of 10", turns: 2,
                                             maxTurns: 10, costSpentUSD: 0.4, maxCostUSD: 5, lastReason: "one test fails"),
                            members: [RemoteMember(agentID: id, role: "Lead", state: "active", stateLabel: "Active",
                                                   step: "Writing the plan", costUSD: 0.4)])
        let back = try JSONDecoder().decode(RemoteRoom.self, from: JSONEncoder().encode(original))
        #expect(back == original)
        #expect(back.members.first?.id == id)
    }

    @Test func oldFramesStillDecode() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(room())) as? [String: Any])
        object["goal"] = nil
        object["members"] = nil
        let back = try JSONDecoder().decode(RemoteRoom.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(back.goal == nil)
        #expect(back.members.isEmpty)
    }

    @Test func unreadableGoalKeepsTheRoom() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(room())) as? [String: Any])
        object["goal"] = ["condition": 12]
        object["members"] = [["agentID": "not a uuid"]]
        let back = try JSONDecoder().decode(RemoteRoom.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(back.title == "Settings")
        #expect(back.goal == nil)
        #expect(back.members.isEmpty)
    }

    @Test func bridgeFillsGoalAndMembers() {
        let agents = RoomFixtures.agents(["Lead", "Two"])
        var state = RoomState(spec: RoomSpec(title: "T", directory: "/tmp", agents: agents, mode: .team, leadAgentID: agents[0].id))
        state.phase = .working
        state.duties = [agents[1].id: [Duty(purpose: .work)]]
        state.assignments = [Assignment(agentID: agents[1].id, task: "client")]
        state.usage = [agents[1].id: Usage(costUSD: 0.2)]
        var goal = GoalDriver.start(condition: "ship", budget: GoalBudget(maxTurns: 4), costNow: 0, unit: "run").0
        goal.costSpent = 0.2
        state.goal = goal
        let remote = RemoteRoomBridge.room(state, activity: [agents[1].id: .working], running: true)
        #expect(remote.goal == RemoteGoal(condition: "ship", active: true, statusLabel: "Run 1 of 4", turns: 1, maxTurns: 4,
                                          costSpentUSD: 0.2))
        #expect(remote.members.map(\.role) == ["Lead", "Builder"])
        #expect(remote.members[1].state == "active")
        #expect(remote.members[1].stateLabel == "Active")
        #expect(remote.members[1].step == "Building: client")
        #expect(remote.members[1].costUSD == 0.2)
    }
}
