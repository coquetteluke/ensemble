import Foundation

// What the phone shows of a room's goal and Members list, read only. Added after protocol 3 shipped: older Macs leave
// them out and older phones ignore them. The Mac writes the labels, so a phone shows a new state without an update.

/// A room's goal as the phone sees it.
public struct RemoteGoal: Codable, Hashable, Sendable {
    public var condition: String
    /// True while the goal still drives the room.
    public var active: Bool
    /// The goal's state in the Mac's words ("Run 3 of 10", "Checking the goal", "Met after 2 runs").
    public var statusLabel: String
    public var turns: Int
    public var maxTurns: Int
    public var costSpentUSD: Double
    public var maxCostUSD: Double?
    /// Why the last check said not met.
    public var lastReason: String?

    public init(condition: String, active: Bool, statusLabel: String, turns: Int, maxTurns: Int, costSpentUSD: Double = 0,
                maxCostUSD: Double? = nil, lastReason: String? = nil) {
        self.condition = condition
        self.active = active
        self.statusLabel = statusLabel
        self.turns = turns
        self.maxTurns = maxTurns
        self.costSpentUSD = costSpentUSD
        self.maxCostUSD = maxCostUSD
        self.lastReason = lastReason
    }

    public init(_ run: GoalRun) {
        self.init(condition: run.condition, active: run.isActive, statusLabel: run.statusLine, turns: run.turns,
                  maxTurns: run.budget.maxTurns, costSpentUSD: run.costSpent, maxCostUSD: run.budget.maxCostUSD,
                  lastReason: run.lastReason)
    }
}

/// One agent in a room's Members list as the phone sees it.
public struct RemoteMember: Codable, Hashable, Sendable, Identifiable {
    public var agentID: UUID
    /// "Lead", "Builder", "Reviewer", "Judge", "Debater".
    public var role: String
    /// `MemberState` raw value (`active`, `standingBy`, `waitingOnYou`, `finished`, `stopped`); a phone colours the ones it
    /// knows and shows `stateLabel` for all.
    public var state: String
    public var stateLabel: String
    /// What the agent is doing now.
    public var step: String?
    public var costUSD: Double

    public var id: UUID { agentID }

    public init(agentID: UUID, role: String, state: String, stateLabel: String, step: String? = nil, costUSD: Double = 0) {
        self.agentID = agentID
        self.role = role
        self.state = state
        self.stateLabel = stateLabel
        self.step = step
        self.costUSD = costUSD
    }

    public init(_ member: RoomMember) {
        self.init(agentID: member.agent.id, role: member.role.label, state: member.state.rawValue,
                  stateLabel: member.state.label, step: member.step, costUSD: member.costUSD)
    }
}
