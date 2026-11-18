import Foundation

// Swarm views of a room, worked out from the saved room alone so the Mac, the phone and tests agree:
// - Members: each agent's part in the run (lead, builder, reviewer), its state, what it is doing and its spend.
// - The message graph: who messaged whom on the board, weighted by count, with the latest message marked.
// - Replay: the board and the graph as they were after any message.
// - Follow: which agent's transcript to show while agents hand work to each other.

// MARK: - Members

/// An agent's part in the room's current run.
public enum MemberRole: String, Codable, Hashable, Sendable {
    case lead
    case builder
    case reviewer
    /// Debate: decides the verdict.
    case judge
    /// Debate: argues.
    case debater

    public var label: String {
        switch self {
        case .lead: "Lead"
        case .builder: "Builder"
        case .reviewer: "Reviewer"
        case .judge: "Judge"
        case .debater: "Debater"
        }
    }
}

/// Where a member stands.
public enum MemberState: String, Codable, Hashable, Sendable {
    /// In a turn (or its subagents are).
    case active
    /// Free, with nothing it owes right now.
    case standingBy
    /// A permission prompt or a decision about it waits for the user.
    case waitingOnYou
    /// Its part of the run is done.
    case finished
    /// Stopped by its spending cap, or the room was stopped.
    case stopped

    public var label: String {
        switch self {
        case .active: "Active"
        case .standingBy: "Standing by"
        case .waitingOnYou: "Waiting on you"
        case .finished: "Finished"
        case .stopped: "Stopped"
        }
    }
}

/// One agent in the Members list.
public struct RoomMember: Identifiable, Hashable, Sendable {
    public var agent: AgentSpec
    public var role: MemberRole
    public var state: MemberState
    /// What it is doing now ("Reviewing GPT's piece"), when the room knows.
    public var step: String?
    public var costUSD: Double

    public var id: UUID { agent.id }

    public init(agent: AgentSpec, role: MemberRole, state: MemberState, step: String? = nil, costUSD: Double = 0) {
        self.agent = agent
        self.role = role
        self.state = state
        self.step = step
        self.costUSD = costUSD
    }
}

public enum RoomSwarm {
    /// The room's lead: the chosen lead, else the first agent (a debate without a chosen lead has none). `nil` when the
    /// user leads. Same rule as `RoomEngine.leadID`.
    public static func leadID(_ state: RoomState) -> UUID? {
        if state.userIsLead { return nil }
        let agents = state.spec.agents
        if let lead = state.spec.leadAgentID, agents.contains(where: { $0.id == lead }) { return lead }
        return state.runMode == .debate ? nil : agents.first?.id
    }

    /// Every agent of the room with its role, state, step and spend. `activity` is what the Mac sees each agent doing
    /// (working, waiting for permission); agents missing from it count as idle.
    public static func members(_ state: RoomState, activity: [UUID: AgentActivity] = [:]) -> [RoomMember] {
        let lead = leadID(state)
        return state.spec.agents.map { agent in
            let current = activity[agent.id] ?? (state.cappedAgents.contains(agent.id) ? .capped : .idle)
            let memberState = self.state(of: agent.id, in: state, activity: current, lead: lead)
            return RoomMember(agent: agent, role: role(of: agent.id, in: state, lead: lead), state: memberState,
                              step: step(of: agent.id, in: state, activity: current, memberState: memberState, lead: lead),
                              costUSD: state.usage[agent.id]?.costUSD ?? 0)
        }
    }

    static func role(of id: UUID, in state: RoomState, lead: UUID?) -> MemberRole {
        let duties = (state.duties[id] ?? []).map(\.purpose)
        switch state.runMode {
        case .solo:
            return .builder
        case .debate:
            let judge = state.debate?.judgeID ?? lead
            return judge == id ? .judge : .debater
        case .roundTable:
            if let builder = state.roundTable?.builderID { return builder == id ? .builder : (lead == id ? .lead : .reviewer) }
            return lead == id ? .lead : .reviewer
        case .team:
            if lead == id { return .lead }
            if duties.contains(where: { if case .review = $0 { true } else { false } }) { return .reviewer }
            if state.assignments.contains(where: { $0.agentID == id }) { return .builder }
            if state.assignments.contains(where: { $0.reviewerID == id }) { return .reviewer }
            return .builder
        }
    }

    static func state(of id: UUID, in state: RoomState, activity: AgentActivity, lead: UUID?) -> MemberState {
        if activity == .capped || state.cappedAgents.contains(id) || state.phase == .stopped { return .stopped }
        if activity == .waitingForPermission || decisionWaits(on: id, state, lead: lead) { return .waitingOnYou }
        if activity == .working { return .active }
        if !(state.duties[id] ?? []).isEmpty || !(state.outbox[id] ?? []).isEmpty { return .standingBy }
        if state.phase == .finished || state.phase == .verdict { return .finished }
        if state.runMode == .team, let piece = state.assignments.first(where: { $0.agentID == id }),
           [.approved, .merged, .dropped].contains(piece.status), state.phase.isRunActive {
            return .finished
        }
        if state.runMode == .roundTable, let rt = state.roundTable, rt.builderID == id, rt.builderDone { return .finished }
        return .standingBy
    }

    /// A decision about this agent's work waits for the user.
    static func decisionWaits(on id: UUID, _ state: RoomState, lead: UUID?) -> Bool {
        switch state.pendingDecision {
        case .approvePlan?: lead == id
        case .reviewStalemate(let author)?: author == id
        case .takeover(let agent)?: agent == id
        case .mergeConflict(let agent, _)?: agent == id
        case .writePlan?, .judge?, nil: false
        }
    }

    static func step(of id: UUID, in state: RoomState, activity: AgentActivity, memberState: MemberState, lead: UUID?) -> String? {
        if state.cappedAgents.contains(id) || activity == .capped { return "Reached its spending cap" }
        func name(_ other: UUID) -> String { state.spec.agents.first { $0.id == other }?.name ?? "an agent" }
        let piece = state.assignments.first { $0.agentID == id }
        if activity == .waitingForPermission { return "Waiting for permission" }
        switch state.pendingDecision {
        case .approvePlan? where lead == id: return "Waiting for you to approve the plan"
        case .reviewStalemate(let author)? where author == id: return "Waiting for your call on its piece"
        case .takeover(let agent)? where agent == id: return "Offers to take over building"
        case .mergeConflict(let agent, _)? where agent == id: return "Merge stopped on a conflict"
        default: break
        }
        if let duty = state.duties[id]?.first?.purpose {
            switch duty {
            case .chat: return "Answering"
            case .solo: return "Working on your message"
            case .plan: return "Writing the plan"
            case .work: return piece.map { "Building: \($0.task)" } ?? "Building its piece"
            case .review(let author): return "Reviewing \(name(author))'s piece"
            case .resolveConflict: return "Resolving a merge conflict"
            case .summary: return "Writing the summary"
            case .argue(let round): return "Arguing, round \(round)"
            case .verdict: return "Writing the verdict"
            case .propose(let round): return "Proposing, round \(round)"
            case .build: return "Building the next step"
            case .roundTableReview: return "Reviewing the latest step"
            case .goalCheck: return "Checking the goal"
            }
        }
        if let piece, state.runMode == .team {
            switch piece.status {
            case .pending: return state.phase == .awaitingApproval ? "Assigned: \(piece.task)" : nil
            case .working: return "Building: \(piece.task)"
            case .inReview: return piece.reviewerID.map { "Piece in review by \(name($0))" } ?? "Piece in review"
            case .changesRequested: return "Fixing what the review asked for"
            case .approved: return "Piece approved"
            case .merged: return "Piece merged"
            case .dropped: return "Piece dropped"
            }
        }
        if memberState == .active { return "Working" }
        return nil
    }
}

// MARK: - Message graph

/// Who messaged whom on the board.
public struct RoomGraph: Hashable, Sendable {
    public enum Node: Hashable, Sendable {
        case user
        case agent(UUID)
    }

    public struct Edge: Hashable, Sendable, Identifiable {
        public var from: Node
        public var to: Node
        /// Messages from `from` to `to`.
        public var count: Int

        public var id: String { "\(Self.key(from))>\(Self.key(to))" }

        static func key(_ node: Node) -> String {
            switch node {
            case .user: "user"
            case .agent(let id): id.uuidString
            }
        }
    }

    /// The room's agents in roster order, then the user when the user wrote to an agent by name.
    public var nodes: [Node]
    /// Every pair that exchanged messages, in the order they first did.
    public var edges: [Edge]
    /// The newest message that went from someone to someone.
    public var latestMessageID: UUID?
    /// Its sender and receivers.
    public var latestFrom: Node?
    public var latestTo: [Node]
    /// Board messages counted.
    public var messageCount: Int

    public init(nodes: [Node] = [], edges: [Edge] = [], latestMessageID: UUID? = nil, latestFrom: Node? = nil,
                latestTo: [Node] = [], messageCount: Int = 0) {
        self.nodes = nodes
        self.edges = edges
        self.latestMessageID = latestMessageID
        self.latestFrom = latestFrom
        self.latestTo = latestTo
        self.messageCount = messageCount
    }

    /// The highest edge count (for line widths).
    public var maxCount: Int { edges.map(\.count).max() ?? 0 }

    /// True when the edge belongs to the latest message.
    public func isLatest(_ edge: Edge) -> Bool {
        edge.from == latestFrom && latestTo.contains(edge.to)
    }

    public func count(from: Node, to: Node) -> Int {
        edges.first { $0.from == from && $0.to == to }?.count ?? 0
    }

    /// The graph of a board (or the first part of it, for replay).
    public static func build<Messages: Collection>(board: Messages, agents: [UUID]) -> RoomGraph where Messages.Element == BoardMessage {
        var edges: [Edge] = []
        var index: [String: Int] = [:]
        var graph = RoomGraph(messageCount: board.count)
        var userSpoke = false
        for message in board {
            guard let routed = route(message, agents: agents), !routed.to.isEmpty else { continue }
            let from = routed.from, to = routed.to
            if from == .user { userSpoke = true }
            for target in to {
                let edge = Edge(from: from, to: target, count: 1)
                if let i = index[edge.id] {
                    edges[i].count += 1
                } else {
                    index[edge.id] = edges.count
                    edges.append(edge)
                }
            }
            graph.latestMessageID = message.id
            graph.latestFrom = from
            graph.latestTo = to
        }
        graph.edges = edges
        graph.nodes = agents.map { .agent($0) } + (userSpoke ? [.user] : [])
        return graph
    }

    /// Sender and receivers of a board message, or nil for messages that went to no one in particular (room notices,
    /// an agent's post to the board).
    /// - An agent's message with receivers goes to them.
    /// - A debate argument goes to every other agent: the room hands each argument to the others.
    /// - The user's message counts when it names its receivers (`@name`); a message to the whole room draws no lines, as
    ///   it would tie the user to every agent.
    public static func route(_ message: BoardMessage, agents: [UUID]) -> (from: Node, to: [Node])? {
        let known = Set(agents)
        switch message.from {
        case .agent(let id):
            guard known.contains(id) else { return nil }
            if !message.to.isEmpty {
                let to = message.to.filter { known.contains($0) && $0 != id }
                return to.isEmpty ? nil : (.agent(id), to.map { .agent($0) })
            }
            if message.kind == .argument {
                let others = agents.filter { $0 != id }
                return others.isEmpty ? nil : (.agent(id), others.map { .agent($0) })
            }
            return nil
        case .user:
            let to = message.to.filter { known.contains($0) }
            return to.isEmpty ? nil : (.user, to.map { .agent($0) })
        case .room:
            return nil
        }
    }
}

// MARK: - Replay

/// The board and graph as they were after a given number of messages. Step `n` shows the first `n` messages; the last
/// step is the live board.
public enum RoomReplay {
    /// Steps there are: one per board message.
    public static func stepCount(_ board: [BoardMessage]) -> Int { board.count }

    /// `step` kept between 1 and the last step; `nil` (live) stays `nil`.
    public static func clamp(_ step: Int?, board: [BoardMessage]) -> Int? {
        guard let step else { return nil }
        guard !board.isEmpty else { return nil }
        return min(max(step, 1), board.count)
    }

    /// The messages shown at `step` (`nil` is live: all of them).
    public static func messages(_ board: [BoardMessage], at step: Int?) -> [BoardMessage] {
        guard let step = clamp(step, board: board) else { return board }
        return Array(board.prefix(step))
    }

    /// The graph at `step` (`nil` is live).
    public static func graph(_ board: [BoardMessage], agents: [UUID], at step: Int?) -> RoomGraph {
        RoomGraph.build(board: messages(board, at: step), agents: agents)
    }

    /// The message a step ends on.
    public static func message(_ board: [BoardMessage], at step: Int?) -> BoardMessage? {
        messages(board, at: step).last
    }

    /// The next step that changes the graph (a message from someone to someone), after `step`. Live when none is left.
    public static func nextEdgeStep(_ board: [BoardMessage], agents: [UUID], after step: Int?) -> Int? {
        guard let step = clamp(step, board: board) else { return nil }
        for i in step..<board.count where RoomGraph.route(board[i], agents: agents) != nil { return i + 1 }
        return nil
    }
}

// MARK: - Follow

/// Which agent's transcript Follow mode shows. It stays on the agent it shows while that agent works, and moves to the
/// agent that started working most recently when it stops (a hand-off). When nobody works it keeps the last one.
public struct RoomFollow: Hashable, Sendable {
    public private(set) var followed: UUID?
    /// Working agents in the order they started, newest last.
    private var order: [UUID] = []

    public init(followed: UUID? = nil) {
        self.followed = followed
    }

    /// Feeds who works now, in roster order. Returns the agent to show.
    @discardableResult
    public mutating func update(working: [UUID]) -> UUID? {
        let now = Set(working)
        order.removeAll { !now.contains($0) }
        // Agents that start together: the first in the roster counts as the newest.
        for id in working.reversed() where !order.contains(id) { order.append(id) }
        if let followed, now.contains(followed) { return followed }
        if let newest = order.last { followed = newest }
        return followed
    }

    /// The agents that count as working for Follow: in a turn or waiting for permission.
    public static func working(_ agents: [AgentSpec], activity: (UUID) -> AgentActivity) -> [UUID] {
        agents.map(\.id).filter { [.working, .waitingForPermission].contains(activity($0)) }
    }
}
