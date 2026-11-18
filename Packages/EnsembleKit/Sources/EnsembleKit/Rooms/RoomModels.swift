import Foundation

// MARK: - Board

/// Who wrote a board message.
public enum BoardSender: Codable, Hashable, Sendable {
    case agent(UUID)
    case user
    /// The room itself: notices about phases, caps, merges.
    case room
}

public enum BoardMessageKind: String, Codable, Hashable, Sendable, CaseIterable {
    case chat
    case plan
    case assignment
    case update
    case question
    case review
    case argument
    case verdict
    case notice
}

/// One message on the room board. Every message the engine moves between agents is also posted here.
public struct BoardMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var from: BoardSender
    /// Receivers. Empty means everyone.
    public var to: [UUID]
    public var kind: BoardMessageKind
    /// Debate or round table round, when it applies.
    public var round: Int?
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), from: BoardSender, to: [UUID] = [], kind: BoardMessageKind,
                round: Int? = nil, text: String, date: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.round = round
        self.text = text
        self.date = date
    }
}

// MARK: - Phases

/// The step a room's current run is on.
public enum RoomPhase: String, Codable, Hashable, Sendable, CaseIterable {
    /// Created, no run yet.
    case idle
    /// Team: the lead is writing the plan.
    case planning
    /// Team: the plan waits for the user (Approve, Edit, Redo), or the user writes it.
    case awaitingApproval
    /// Team: agents build and review. Solo: the agent is answering.
    case working
    /// Team: approved branches are merged into the base branch.
    case merging
    /// Team: the lead writes the final summary.
    case summarizing
    /// Debate: argument rounds.
    case debating
    /// Debate: the judge (or the user) writes the verdict.
    case judging
    /// Debate: the verdict is ready ("Build it" or "Debate again").
    case verdict
    /// Round table: agents take turns on the plan.
    case discussing
    /// Round table: one agent builds, the others review each step.
    case building
    case finished
    case stopped

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .planning: "Planning"
        case .awaitingApproval: "Waiting for plan approval"
        case .working: "Working"
        case .merging: "Merging"
        case .summarizing: "Summing up"
        case .debating: "Debating"
        case .judging: "Judging"
        case .verdict: "Verdict ready"
        case .discussing: "Discussing"
        case .building: "Building"
        case .finished: "Finished"
        case .stopped: "Stopped"
        }
    }

    /// True while the engine is driving agents.
    public var isRunning: Bool {
        switch self {
        case .planning, .working, .merging, .summarizing, .debating, .judging, .discussing, .building: true
        default: false
        }
    }

    /// True while a run exists, including when it waits on the user for the plan.
    public var isRunActive: Bool { isRunning || self == .awaitingApproval }
}

// MARK: - Team

public enum AssignmentStatus: String, Codable, Hashable, Sendable {
    case pending
    case working
    case inReview
    case changesRequested
    case approved
    case merged
    /// Given up: its agent hit a spending cap, or the user dropped it.
    case dropped

    public var label: String {
        switch self {
        case .pending: "Pending"
        case .working: "Working"
        case .inReview: "In review"
        case .changesRequested: "Changes requested"
        case .approved: "Approved"
        case .merged: "Merged"
        case .dropped: "Dropped"
        }
    }
}

/// One piece of a Team plan. One per agent, so its id is the agent's id.
public struct Assignment: Codable, Hashable, Sendable, Identifiable {
    public var agentID: UUID
    public var task: String
    public var status: AssignmentStatus
    public var reviewerID: UUID?
    /// CHANGES rounds sent back to the author so far.
    public var fixRounds: Int
    /// The last CHANGES text from the reviewer.
    public var lastReview: String?
    /// `ensemble/<room>/<agent>` in git projects.
    public var branch: String?
    public var worktreePath: String?
    public var changedFiles: [String]

    public var id: UUID { agentID }

    public init(agentID: UUID, task: String, status: AssignmentStatus = .pending, reviewerID: UUID? = nil, fixRounds: Int = 0,
                lastReview: String? = nil, branch: String? = nil, worktreePath: String? = nil, changedFiles: [String] = []) {
        self.agentID = agentID
        self.task = task
        self.status = status
        self.reviewerID = reviewerID
        self.fixRounds = fixRounds
        self.lastReview = lastReview
        self.branch = branch
        self.worktreePath = worktreePath
        self.changedFiles = changedFiles
    }
}

/// Git facts for a Team run.
public struct GitContext: Codable, Hashable, Sendable {
    public var isRepository: Bool
    public var baseBranch: String?

    public init(isRepository: Bool, baseBranch: String? = nil) {
        self.isRepository = isRepository
        self.baseBranch = baseBranch
    }
}

// MARK: - Debate

public struct DebateArgument: Codable, Hashable, Sendable {
    public var round: Int
    public var agentID: UUID
    public var text: String

    public init(round: Int, agentID: UUID, text: String) {
        self.round = round
        self.agentID = agentID
        self.text = text
    }
}

public struct DebateState: Codable, Hashable, Sendable {
    public var question: String
    public var round: Int
    public var totalRounds: Int
    public var arguments: [DebateArgument]
    /// `nil` means the user judges.
    public var judgeID: UUID?
    public var verdict: String?

    public init(question: String, round: Int = 1, totalRounds: Int = 3, arguments: [DebateArgument] = [],
                judgeID: UUID? = nil, verdict: String? = nil) {
        self.question = question
        self.round = round
        self.totalRounds = totalRounds
        self.arguments = arguments
        self.judgeID = judgeID
        self.verdict = verdict
    }

    public func arguments(inRound round: Int) -> [DebateArgument] {
        arguments.filter { $0.round == round }
    }
}

// MARK: - Round table

public enum RoundTableReview: Codable, Hashable, Sendable {
    case approve
    case changes(String)
    case takeover(String)
}

public struct RoundTableState: Codable, Hashable, Sendable {
    public var round: Int
    public var maxRounds: Int
    /// Speaking order, lead first.
    public var order: [UUID]
    public var speakerIndex: Int
    /// Agents that agree with the current plan.
    public var agreed: [UUID]
    public var plan: String?
    public var planAuthorID: UUID?
    public var lastProposal: [UUID: String]
    public var builderID: UUID?
    public var buildTurns: Int
    public var builderDone: Bool
    public var lastBuildUpdate: String?
    /// Reviews of the latest build step.
    public var reviews: [UUID: RoundTableReview]
    public var pendingTakeoverID: UUID?

    public init(order: [UUID], maxRounds: Int = 4) {
        self.round = 1
        self.maxRounds = maxRounds
        self.order = order
        self.speakerIndex = 0
        self.agreed = []
        self.plan = nil
        self.planAuthorID = nil
        self.lastProposal = [:]
        self.builderID = nil
        self.buildTurns = 0
        self.builderDone = false
        self.lastBuildUpdate = nil
        self.reviews = [:]
        self.pendingTakeoverID = nil
    }

    public var currentSpeaker: UUID? {
        order.indices.contains(speakerIndex) ? order[speakerIndex] : nil
    }
}

// MARK: - Decisions and turns

/// Something the room waits on the user for. The room shows as Needs you while this is set.
public enum RoomDecision: Codable, Hashable, Sendable {
    /// Team in Ask or Accept-edits mode: Approve, Edit or Redo the lead's plan.
    case approvePlan
    /// Team with the user as lead: the user writes the plan.
    case writePlan
    /// A piece still has requested changes after the fix rounds: approve, another round, or drop.
    case reviewStalemate(agentID: UUID)
    /// Round table: a reviewer offers to take over building.
    case takeover(agentID: UUID)
    /// Debate without a judge agent: the user writes the verdict.
    case judge
    /// A merge stopped and no lead agent can resolve it.
    case mergeConflict(agentID: UUID, files: [String])
}

/// Why the engine asked an agent for a turn, and so which reply keyword it waits for.
public enum TurnPurpose: Codable, Hashable, Sendable {
    case chat
    case solo
    case plan
    case work
    case review(authorID: UUID)
    case resolveConflict
    case summary
    case argue(round: Int)
    case verdict
    case propose(round: Int)
    case build
    case roundTableReview

    var round: Int? {
        switch self {
        case .argue(let r), .propose(let r): r
        default: nil
        }
    }
}

/// Something the room is waiting for an agent to deliver.
public struct Duty: Codable, Hashable, Sendable {
    public var purpose: TurnPurpose
    /// The engine already asked once for the room format.
    public var retried: Bool

    public init(purpose: TurnPurpose, retried: Bool = false) {
        self.purpose = purpose
        self.retried = retried
    }
}

/// A message waiting for its agent to be free (or for the room to resume).
public struct OutgoingMessage: Codable, Hashable, Sendable {
    public enum Channel: String, Codable, Hashable, Sendable {
        /// The user speaking (`prompt`).
        case prompt
        /// The room speaking (`injectSynthetic` with `wake: true`).
        case synthetic
    }

    public var channel: Channel
    public var text: String
    /// Duty this message gives the agent.
    public var duty: TurnPurpose?
    /// Duty this message reminds the agent of (format retries, resume nudges).
    public var nudge: TurnPurpose?

    public init(channel: Channel, text: String, duty: TurnPurpose? = nil, nudge: TurnPurpose? = nil) {
        self.channel = channel
        self.text = text
        self.duty = duty
        self.nudge = nudge
    }
}

// MARK: - Room state

/// Everything about a room that survives a restart. Saved as JSON after every change.
public struct RoomState: Codable, Hashable, Sendable, Identifiable {
    public var spec: RoomSpec
    /// Mode of the current run. Starts as `spec.mode`; "Build it" after a debate switches it to Team or Solo.
    public var runMode: RoomMode
    /// Mode the agents were last told about.
    public var briefedMode: RoomMode?
    /// Runs started in this room.
    public var run: Int
    /// agentID -> engine session id.
    public var sessions: [UUID: String]
    public var board: [BoardMessage]
    public var phase: RoomPhase
    public var isPaused: Bool
    public var pauseReason: String?
    public var task: String?
    public var plan: String?
    public var assignments: [Assignment]
    public var debate: DebateState?
    public var roundTable: RoundTableState?
    public var pendingDecision: RoomDecision?
    /// Session usage per agent, from `usageUpdated`.
    public var usage: [UUID: Usage]
    /// Agents stopped by their spending cap.
    public var cappedAgents: [UUID]
    /// "Take over": the user leads instead of an agent.
    public var userIsLead: Bool
    public var git: GitContext?
    /// What the room waits for from each agent.
    public var duties: [UUID: [Duty]]
    /// Messages waiting for their agent to finish its turn (or for the room to resume).
    public var outbox: [UUID: [OutgoingMessage]]
    /// Agents interrupted by the last pause; they get a nudge on resume.
    public var interruptedAgents: [UUID]

    public var id: UUID { spec.id }

    public init(spec: RoomSpec) {
        self.spec = spec
        self.runMode = spec.mode
        self.briefedMode = nil
        self.run = 0
        self.sessions = [:]
        self.board = []
        self.phase = .idle
        self.isPaused = false
        self.pauseReason = nil
        self.task = nil
        self.plan = nil
        self.assignments = []
        self.debate = nil
        self.roundTable = nil
        self.pendingDecision = nil
        self.usage = [:]
        self.cappedAgents = []
        self.userIsLead = false
        self.git = nil
        self.duties = [:]
        self.outbox = [:]
        self.interruptedAgents = []
    }

    /// Total spend across the room's agents.
    public var totalUsage: Usage {
        usage.values.reduce(Usage.zero, +)
    }

    /// True when the room waits on the user: a decision, or a pause the room made itself.
    public var needsUser: Bool {
        pendingDecision != nil || (isPaused && !cappedAgents.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case spec, runMode, briefedMode, run, sessions, board, phase, isPaused, pauseReason, task, plan, assignments
        case debate, roundTable, pendingDecision, usage, cappedAgents, userIsLead, git, duties, outbox, interruptedAgents
    }

    /// Lenient decoding so rooms saved by older builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decode(RoomSpec.self, forKey: .spec)
        runMode = try c.decodeIfPresent(RoomMode.self, forKey: .runMode) ?? spec.mode
        briefedMode = try c.decodeIfPresent(RoomMode.self, forKey: .briefedMode)
        run = try c.decodeIfPresent(Int.self, forKey: .run) ?? 0
        sessions = try c.decodeIfPresent([UUID: String].self, forKey: .sessions) ?? [:]
        board = try c.decodeIfPresent([BoardMessage].self, forKey: .board) ?? []
        phase = try c.decodeIfPresent(RoomPhase.self, forKey: .phase) ?? .idle
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        pauseReason = try c.decodeIfPresent(String.self, forKey: .pauseReason)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        assignments = try c.decodeIfPresent([Assignment].self, forKey: .assignments) ?? []
        debate = try c.decodeIfPresent(DebateState.self, forKey: .debate)
        roundTable = try c.decodeIfPresent(RoundTableState.self, forKey: .roundTable)
        pendingDecision = try c.decodeIfPresent(RoomDecision.self, forKey: .pendingDecision)
        usage = try c.decodeIfPresent([UUID: Usage].self, forKey: .usage) ?? [:]
        cappedAgents = try c.decodeIfPresent([UUID].self, forKey: .cappedAgents) ?? []
        userIsLead = try c.decodeIfPresent(Bool.self, forKey: .userIsLead) ?? false
        git = try c.decodeIfPresent(GitContext.self, forKey: .git)
        duties = try c.decodeIfPresent([UUID: [Duty]].self, forKey: .duties) ?? [:]
        outbox = try c.decodeIfPresent([UUID: [OutgoingMessage]].self, forKey: .outbox) ?? [:]
        interruptedAgents = try c.decodeIfPresent([UUID].self, forKey: .interruptedAgents) ?? []
    }
}
