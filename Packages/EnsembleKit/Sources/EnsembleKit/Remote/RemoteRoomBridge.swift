import CryptoKit
import Foundation

/// Turns a room (`RoomState`) into what the phone sees, and carries out the phone's answers to the room's decisions
/// through the same `RoomEngine` calls the Mac's cards use. The Mac supplies what only it knows: what each agent is
/// doing, the open permission prompts of the room's agents and whether the room is running.
@MainActor
public enum RemoteRoomBridge {
    /// Ids of the answers a decision offers (`RemoteRoomChoice.id`).
    public enum Choice {
        public static let approve = "approve"
        public static let redo = "redo"
        public static let submitPlan = "submitPlan"
        public static let approvePiece = "approvePiece"
        public static let anotherRound = "anotherRound"
        public static let dropPiece = "dropPiece"
        public static let acceptTakeover = "acceptTakeover"
        public static let rejectTakeover = "rejectTakeover"
        public static let verdict = "verdict"
        public static let continueMerge = "continueMerge"
        public static let buildIt = "buildIt"
        public static let debateAgain = "debateAgain"
    }

    /// Board messages a room transcript carries at most; older ones stay on the Mac.
    public static let transcriptLimit = 400

    /// The id of a room's Session Hub row and combined transcript: the room id, as on the Mac's Session Hub.
    public nonisolated static func sessionID(for roomID: UUID) -> String { roomID.uuidString }

    // MARK: Room

    /// The room as the phone sees it.
    public static func room(_ state: RoomState, activity: [UUID: AgentActivity] = [:], permissions: [PermissionRequest] = [],
                            running: Bool = false) -> RemoteRoom {
        let spec = state.spec
        let agents = spec.agents.map { agent -> RemoteAgent in
            let current = activity[agent.id] ?? (state.cappedAgents.contains(agent.id) ? .capped : .idle)
            return RemoteAgent(agent, activity: sessionActivity(current), sessionID: state.sessions[agent.id],
                               capped: current == .capped ? true : nil)
        }
        let roomState: RemoteRoom.State
        if state.phase == .stopped {
            roomState = .stopped
        } else if state.isPaused {
            roomState = .paused
        } else if running {
            roomState = .running
        } else {
            roomState = .idle
        }
        return RemoteRoom(
            id: spec.id, title: spec.title, directory: spec.directory, mode: state.runMode, agents: agents,
            leadAgentID: leadID(state), state: roomState, permissionMode: spec.permissionMode,
            sessionID: sessionID(for: spec.id), usage: state.totalUsage,
            lastActivity: state.board.last?.date ?? spec.created,
            phaseLabel: state.isPaused ? "Paused" : state.phase.label,
            pauseReason: state.isPaused ? state.pauseReason : nil,
            decision: decision(for: state),
            permissions: permissions.sorted { ($0.created, $0.id) < ($1.created, $1.id) })
    }

    /// The room's Session Hub row. `pausedForUser` marks a pause the room made itself (a spending cap).
    public nonisolated static func hubRow(_ room: RemoteRoom, pausedForUser: Bool = false) -> SessionSummary {
        let decision = room.decision?.needsYou == true ? room.decision : nil
        let ask = decision?.title ?? room.permissions.first.map(askText) ?? (pausedForUser ? room.pauseReason : nil)
        let activity: SessionActivity = room.state == .running ? .working
            : room.permissions.isEmpty ? .idle : .waitingForPermission
        return SessionSummary(
            id: room.sessionID, title: room.title, directory: room.directory, roomID: room.id,
            agentNames: room.agents.map(\.name), activity: activity, lastActivity: room.lastActivity, pendingAsk: ask,
            // A decision blocks the room like a prompt, so it counts as one (the Hub sorts it into Needs you).
            pendingPermissions: room.permissions.count + (decision != nil || pausedForUser ? 1 : 0),
            usage: room.usage)
    }

    /// The Hub row's line for what a session or room waits on.
    public nonisolated static func askText(_ request: PermissionRequest) -> String {
        if request.isPlan { return "Plan ready: \(request.plan?.title ?? request.title)" }
        if request.isQuestion { return "Question: \(request.questions?.first?.text ?? request.title)" }
        return "Approve: \(request.title)"
    }

    /// The room's combined transcript: the board thread, then the open prompts of its agents.
    public static func transcript(_ state: RoomState, room: RemoteRoom) -> RemoteTranscript {
        RemoteTranscript(sessionID: room.sessionID, title: room.title, items: transcriptItems(state, permissions: room.permissions),
                         activity: room.state == .running ? .working : .idle, permissionMode: room.permissionMode,
                         roomID: room.id, agents: room.agents)
    }

    public static func transcriptItems(_ state: RoomState, permissions: [PermissionRequest]) -> [TranscriptItem] {
        let names = Dictionary(state.spec.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var items: [TranscriptItem] = []
        let hidden = state.board.count - transcriptLimit
        if hidden > 0 {
            items.append(.notice(id: "room-earlier-\(state.spec.id.uuidString)",
                                 text: hidden == 1 ? "1 earlier message is on the Mac." : "\(hidden) earlier messages are on the Mac."))
        }
        for message in state.board.suffix(transcriptLimit) {
            let id = message.id.uuidString
            switch message.from {
            case .agent(let agentID):
                items.append(.board(id: id, fromAgentID: agentID, toAgentIDs: message.to, text: message.text, date: message.date))
            case .user:
                let to = message.to.compactMap { names[$0] }.map { "@" + $0 }
                items.append(.user(id: id, text: to.isEmpty ? message.text : to.joined(separator: " ") + " " + message.text,
                                   date: message.date))
            case .room:
                items.append(.notice(id: id, text: message.text))
            }
        }
        items += permissions.map { .permission($0) }
        return items
    }

    /// The room's lead: the chosen lead, else the first agent (a debate without one has none); `nil` when the user leads.
    public static func leadID(_ state: RoomState) -> UUID? {
        if state.userIsLead { return nil }
        let agents = state.spec.agents
        if let lead = state.spec.leadAgentID, agents.contains(where: { $0.id == lead }) { return lead }
        return state.runMode == .debate ? nil : agents.first?.id
    }

    private static func sessionActivity(_ activity: AgentActivity) -> SessionActivity {
        switch activity {
        case .idle, .capped: .idle
        case .working: .working
        case .waitingForPermission: .waitingForPermission
        }
    }

    // MARK: Decisions

    /// What the room waits on the user for, with the answers the Mac's card offers that work from a phone. Editing a plan
    /// line by line stays on the Mac.
    public static func decision(for state: RoomState) -> RemoteRoomDecision? {
        let spec = state.spec
        func name(_ id: UUID?) -> String? { id.flatMap { id in spec.agents.first { $0.id == id }?.name } }
        let active = spec.agents.map(\.id).filter { !state.cappedAgents.contains($0) }

        switch state.pendingDecision {
        case .approvePlan?:
            let lead = leadID(state)
            var choices = [RemoteRoomChoice(id: Choice.approve, label: "Approve", style: .primary)]
            if let lead, active.contains(lead) {
                choices.append(RemoteRoomChoice(id: Choice.redo, label: "Redo", input: .optional,
                                                placeholder: "What should change (optional)"))
            }
            return make(.approvePlan, state, title: "The plan is ready", agentID: lead, text: planText(state),
                        items: state.assignments.map { .init(agentID: $0.agentID, text: $0.task) }, choices: choices)

        case .writePlan?:
            let template = (["PLAN: ", ""] + spec.agents.map { "ASSIGN @\($0.name): " }).joined(separator: "\n")
            return make(.writePlan, state, title: "You lead this room. Write the plan.", note: "One ASSIGN @Name: line per agent.",
                        choices: [RemoteRoomChoice(id: Choice.submitPlan, label: "Start the work", style: .primary, input: .required,
                                                   placeholder: "PLAN: ...", template: template)])

        case .reviewStalemate(let author)?:
            let assignment = state.assignments.first { $0.agentID == author }
            let reviewer = name(assignment?.reviewerID) ?? "The reviewer"
            return make(.reviewStalemate, state,
                        title: "\(reviewer) still asks for changes to \(name(author) ?? "this")'s piece after \(RoomEngine.maxFixRounds) fix rounds",
                        agentID: author, text: assignment?.lastReview,
                        choices: [RemoteRoomChoice(id: Choice.approvePiece, label: "Approve it", style: .primary),
                                  RemoteRoomChoice(id: Choice.anotherRound, label: "Another round"),
                                  RemoteRoomChoice(id: Choice.dropPiece, label: "Drop the piece", style: .destructive)])

        case .takeover(let agentID)?:
            let builder = name(state.roundTable?.builderID) ?? "the builder"
            var reason: String?
            if case .takeover(let text)? = state.roundTable?.reviews[agentID], !text.isEmpty { reason = text }
            return make(.takeover, state, title: "\(name(agentID) ?? "A reviewer") offers to take over building from \(builder)",
                        agentID: agentID, text: reason,
                        choices: [RemoteRoomChoice(id: Choice.acceptTakeover, label: "Accept", style: .primary),
                                  RemoteRoomChoice(id: Choice.rejectTakeover, label: "Keep \(builder)")])

        case .judge?:
            return make(.judge, state, title: "The arguments are in. Write the verdict.", text: state.debate?.question,
                        choices: [RemoteRoomChoice(id: Choice.verdict, label: "Give the verdict", style: .primary, input: .required,
                                                   placeholder: "The decision, the reasons, and the strongest dissent")])

        case .mergeConflict(let agentID, let files)?:
            let branch = state.assignments.first { $0.agentID == agentID }?.branch ?? "the branch"
            let folder = (spec.directory as NSString).lastPathComponent
            return make(.mergeConflict, state, title: "Merging \(branch) into \(state.git?.baseBranch ?? "the base branch") stopped",
                        agentID: agentID, items: files.map { .init(text: $0) },
                        note: "Resolve it on the Mac in \(folder), commit, then continue.",
                        choices: [RemoteRoomChoice(id: Choice.continueMerge, label: "Continue merging", style: .primary)])

        case nil:
            guard state.phase == .verdict, let debate = state.debate, let verdict = debate.verdict else { return nil }
            let mode: RoomMode = active.count > 1 ? .team : .solo
            return make(.verdict, state, title: "Verdict", agentID: debate.judgeID, text: verdict,
                        choices: [RemoteRoomChoice(id: Choice.buildIt, label: "Build it as \(mode.label)", style: .primary),
                                  RemoteRoomChoice(id: Choice.debateAgain, label: "Debate again")],
                        needsYou: false)
        }
    }

    /// Carries out the phone's answer with the engine call the Mac's card makes. Refuses an answer to a decision that
    /// changed since the phone showed it, a choice it does not offer, a missing text, and an answer the room did not take.
    public static func decide(_ reply: RemoteRoomDecisionReply, engine: RoomEngine) async throws {
        guard let open = decision(for: engine.state), open.id == reply.decisionID else {
            throw RemoteError(.notFound, "That decision is no longer open in the room.")
        }
        guard let choice = open.choices.first(where: { $0.id == reply.choice }) else {
            throw RemoteError(.badRequest, "That answer is not offered for this decision.")
        }
        let text = choice.input == .none ? "" : (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if choice.input == .required && text.isEmpty { throw RemoteError(.badRequest, "Write your answer first.") }
        let errorBefore = engine.lastError
        switch choice.id {
        case Choice.approve: await engine.approvePlan()
        case Choice.redo: await engine.redoPlan(feedback: text)
        case Choice.submitPlan: await engine.submitPlan(text)
        case Choice.approvePiece, Choice.anotherRound, Choice.dropPiece:
            guard let author = open.agentID else { throw RemoteError(.badRequest, "That decision has no piece.") }
            let call: ReviewDecision = choice.id == Choice.approvePiece ? .approve : choice.id == Choice.dropPiece ? .drop : .anotherRound
            await engine.decideReview(for: author, call)
        case Choice.acceptTakeover: await engine.acceptTakeover()
        case Choice.rejectTakeover: await engine.rejectTakeover()
        case Choice.verdict: await engine.submitVerdict(text)
        case Choice.continueMerge: await engine.resolveMergeConflict()
        case Choice.buildIt: await engine.buildVerdict(as: nil)
        case Choice.debateAgain: await engine.debateAgain()
        default: throw RemoteError(.badRequest, "That answer is not offered for this decision.")
        }
        if let still = decision(for: engine.state), still.id == open.id {
            let reason = engine.lastError != errorBefore ? engine.lastError : nil
            throw RemoteError(.failed, reason ?? "The room did not take that answer.")
        }
    }

    /// The plan without its ASSIGN lines (they are the decision's items).
    private static func planText(_ state: RoomState) -> String? {
        guard let plan = state.plan else { return nil }
        let text = plan.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("ASSIGN") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func make(_ kind: RemoteRoomDecision.Kind, _ state: RoomState, title: String, agentID: UUID? = nil,
                             text: String? = nil, items: [RemoteRoomDecision.Item] = [], note: String? = nil,
                             choices: [RemoteRoomChoice], needsYou: Bool = true) -> RemoteRoomDecision {
        // Everything the user would be agreeing to goes into the id, so a changed plan or another run is a new decision.
        var parts = [kind.rawValue, agentID?.uuidString ?? "", String(state.run), state.phase.rawValue, title, text ?? ""]
        parts += items.map { ($0.agentID?.uuidString ?? "") + ":" + $0.text }
        parts += choices.map(\.id)
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        let id = kind.rawValue + "-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return RemoteRoomDecision(id: id, kind: kind, title: title, agentID: agentID, text: text, items: items, note: note,
                                  choices: choices, needsYou: needsYou)
    }
}
