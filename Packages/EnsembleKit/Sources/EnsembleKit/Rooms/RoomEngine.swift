import Foundation
import Observation

/// What an agent in a room is doing right now (for the status chips). Not saved.
public enum AgentActivity: String, Hashable, Sendable {
    case idle
    case working
    case waitingForPermission
    /// Stopped by its spending cap.
    case capped
}

/// The user's call when a piece still has requested changes after the fix rounds.
public enum ReviewDecision: String, Hashable, Sendable {
    case approve
    case anotherRound
    case drop
}

/// Runs one room: Solo, Team, Debate or Round table.
///
/// The engine is the only thing that moves messages between agents, and only through `OpenCodeAPI`.
/// It listens to `api.events()` for its sessions. When an agent's execution ends it takes the agent's
/// final text for that turn, posts it to the board, relays `@name` lines to those agents with
/// `injectSynthetic` (`[Room] <Name> (<model>) to you: <text>`), and moves the run forward.
///
/// Final text of a turn: the engine accumulates `textDelta` / `textEnded` events for the agent's session
/// from the start of the turn to `executionEnded` (using `textEnded`'s full text when it arrives). Only when
/// that comes out empty (for example after an event stream reconnect) does it read `transcript(sessionID)`
/// and take the agent text items after the last non-agent item (the message that started the turn).
///
/// The engine never sends a turn to a busy agent: messages wait in the agent's outbox until its current
/// turn ends, so every `executionEnded` belongs to exactly one request. Everything that changes is saved
/// through the `RoomStore` right away.
@MainActor
@Observable
public final class RoomEngine {
    /// The saved room. Bind the room view to this.
    public internal(set) var state: RoomState
    /// What each agent is doing right now.
    public internal(set) var activity: [UUID: AgentActivity] = [:]
    /// Text of each agent's current turn while it streams.
    public internal(set) var liveText: [UUID: String] = [:]
    /// The last thing that went wrong (engine call failed, save failed, bad plan text).
    public internal(set) var lastError: String?

    /// Fix rounds before a review stalemate goes to the user.
    public static let maxFixRounds = 2
    /// Agent-to-agent wake-ups in a row before the room stops waking agents for each other's replies.
    public static let relayWakeLimit = 8
    /// Round table build steps before the room stops on its own.
    public static let maxBuildTurns = 12

    let api: any OpenCodeAPI
    let store: any RoomStore
    let git: (any GitOps)?

    @ObservationIgnored var listener: Task<Void, Never>?
    @ObservationIgnored var busy: Set<UUID> = []
    @ObservationIgnored var buffers: [UUID: TextBuffer] = [:]
    @ObservationIgnored var turnDuty: [UUID: TurnPurpose] = [:]
    @ObservationIgnored var lastText: [UUID: String] = [:]
    @ObservationIgnored var relayBudget = RoomEngine.relayWakeLimit
    @ObservationIgnored var relayBudgetNoticePosted = false

    public init(state: RoomState, api: any OpenCodeAPI, store: any RoomStore, git: (any GitOps)? = nil) {
        self.state = state
        self.api = api
        self.store = store
        self.git = git
        for agent in state.spec.agents {
            activity[agent.id] = state.cappedAgents.contains(agent.id) ? .capped : .idle
        }
    }

    // MARK: - Creating and loading

    /// Creates the room: one engine session per agent (room folder, the agent's model, the room's
    /// permission mode), then the room briefing to each agent (`injectSynthetic`, `wake: false`).
    public static func create(spec: RoomSpec, api: any OpenCodeAPI, store: any RoomStore,
                              git: (any GitOps)? = nil) async throws -> RoomEngine {
        let engine = RoomEngine(state: RoomState(spec: spec), api: api, store: store, git: git)
        engine.persist()
        engine.startListening()
        try await engine.openSessions()
        return engine
    }

    /// Loads a saved room. A room that was running when Ensemble closed comes back paused.
    public static func load(roomID: UUID, api: any OpenCodeAPI, store: any RoomStore,
                            git: (any GitOps)? = nil) throws -> RoomEngine? {
        guard let saved = try store.load(roomID) else { return nil }
        let engine = RoomEngine(state: saved, api: api, store: store, git: git)
        engine.startListening()
        if saved.phase.isRunning && !saved.isPaused {
            let waiting = saved.duties.filter { !$0.value.isEmpty }.map(\.key)
            engine.update {
                $0.isPaused = true
                $0.pauseReason = "Ensemble closed while the room was running."
                $0.interruptedAgents = waiting
            }
            engine.notice("Paused because Ensemble closed during the run. Resume to continue.")
        }
        return engine
    }

    func openSessions() async throws {
        let spec = state.spec
        for agent in spec.agents where state.sessions[agent.id] == nil {
            let session = try await api.createSession(directory: spec.directory, model: agent.model, agent: nil,
                                                      permissionMode: spec.permissionMode, parentID: nil)
            update { $0.sessions[agent.id] = session.id }
            try? await api.renameSession(session.id, title: "\(spec.title): \(agent.name)")
        }
        for agent in spec.agents {
            guard let sid = state.sessions[agent.id] else { continue }
            try await api.injectSynthetic(sid, text: briefingText(for: agent), wake: false)
        }
        update {
            $0.briefedMode = spec.mode
            $0.runMode = spec.mode
        }
    }

    /// Starts listening to engine events. `create` and `load` call this.
    public func startListening() {
        guard listener == nil else { return }
        let stream = api.events()
        listener = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// Stops listening. Sessions and the board stay.
    public func close() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Roster

    public var agents: [AgentSpec] { state.spec.agents }

    public func agent(_ id: UUID) -> AgentSpec? {
        state.spec.agents.first { $0.id == id }
    }

    public func sessionID(for agentID: UUID) -> String? {
        state.sessions[agentID]
    }

    /// The lead agent: the chosen lead, else the first agent (a debate without a chosen lead has none, so the
    /// user judges). `nil` when the user took over as lead.
    public var leadID: UUID? {
        if state.userIsLead { return nil }
        if let lead = state.spec.leadAgentID, agent(lead) != nil { return lead }
        return state.runMode == .debate ? nil : agents.first?.id
    }

    var activeLeadID: UUID? {
        guard let lead = leadID, isActive(lead) else { return nil }
        return lead
    }

    func isActive(_ id: UUID) -> Bool {
        !state.cappedAgents.contains(id) && agent(id) != nil
    }

    var activeAgentIDs: [UUID] {
        agents.map(\.id).filter { isActive($0) }
    }

    func name(_ id: UUID) -> String {
        agent(id)?.name ?? "An agent"
    }

    /// `Name (provider/model)`.
    func label(_ id: UUID) -> String {
        guard let a = agent(id) else { return "Unknown agent" }
        return "\(a.name) (\(a.model.description))"
    }

    func agentID(named written: String) -> UUID? {
        let canonical = parser.rosterName(for: written) ?? written
        return agents.first { $0.name.compare(canonical, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.id
    }

    func agentID(forSession sessionID: String) -> UUID? {
        state.sessions.first { $0.value == sessionID }?.key
    }

    var parser: RoomReplyParser {
        RoomReplyParser(agentNames: agents.map(\.name))
    }

    // MARK: - Saving and the board

    func update(_ body: (inout RoomState) -> Void) {
        body(&state)
        persist()
    }

    func persist() {
        do {
            try store.save(state)
        } catch {
            lastError = "Could not save the room: \(error.localizedDescription)"
        }
    }

    func post(_ message: BoardMessage) {
        update { $0.board.append(message) }
    }

    func notice(_ text: String) {
        post(BoardMessage(from: .room, kind: .notice, text: text))
    }

    // MARK: - User controls

    /// Starts a run with the user's message as the task, in the room's mode.
    public func start(task: String) async {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        guard !state.phase.isRunActive else {
            lastError = "A run is already going. Stop it before starting another."
            return
        }
        await startRun(task: task, mode: state.spec.mode, fromUser: true)
    }

    /// The user talks to the room. `@name` or `@all` at the start (or `agentIDs`) picks the receivers;
    /// otherwise it goes to everyone. With no run going and no receivers named, it starts a run.
    /// The user's words go to agents with `prompt`. While the room is paused they wait for resume.
    public func send(_ text: String, to agentIDs: [UUID] = []) async {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var targets = agentIDs.filter { agent($0) != nil }
        if targets.isEmpty, let address = parser.leadingAddress(body) {
            targets = address.toAll ? agents.map(\.id) : address.names.compactMap { agentID(named: $0) }
            body = address.text
            guard !body.isEmpty else { return }
        }
        let named = !targets.isEmpty
        if !named && [.idle, .finished, .stopped].contains(state.phase) {
            await startRun(task: body, mode: state.spec.mode, fromUser: true)
            return
        }
        if !named { targets = agents.map(\.id) }
        let everyone = Set(targets) == Set(agents.map(\.id))
        post(BoardMessage(from: .user, to: everyone ? [] : targets, kind: .chat, text: body))
        resetRelayBudget()
        for target in targets {
            guard isActive(target) else {
                notice("\(name(target)) has reached its spending cap, so your message was not delivered.")
                continue
            }
            var duty: TurnPurpose?
            if state.runMode == .solo {
                duty = .solo
                if state.phase != .working { update { $0.phase = .working } }
            }
            await deliver(target, OutgoingMessage(channel: .prompt, text: body, duty: duty))
        }
    }

    /// Interrupts every session and stops scheduling. `resume()` continues from the saved phase.
    public func pause() async {
        await pauseRoom(reason: "Paused.", interrupt: true)
    }

    public func resume() async {
        guard state.isPaused else { return }
        if activeAgentIDs.isEmpty {
            lastError = "Every agent has reached its spending cap. Raise a cap to continue."
            return
        }
        let toNudge = state.interruptedAgents.filter { isActive($0) && !(state.duties[$0] ?? []).isEmpty }
        update {
            $0.isPaused = false
            $0.pauseReason = nil
            $0.interruptedAgents = []
        }
        notice("Resumed.")
        resetRelayBudget()
        for id in toNudge where !busy.contains(id) {
            let duty = state.duties[id]?.first?.purpose
            await deliver(id, OutgoingMessage(channel: .synthetic, text: resumeText(), nudge: duty))
        }
        for id in agents.map(\.id) where !busy.contains(id) && !state.isPaused {
            if let next = dequeue(id) { await deliver(id, next) }
        }
        await checkQuiescence()
    }

    /// Ends the run. Sessions and the board stay; a new run can start.
    public func stop() async {
        guard state.phase != .stopped else { return }
        let running = agents.map(\.id).filter { busy.contains($0) }
        update {
            $0.phase = .stopped
            $0.isPaused = false
            $0.pauseReason = nil
            $0.duties = [:]
            $0.outbox = [:]
            $0.pendingDecision = nil
            $0.interruptedAgents = []
        }
        notice("Stopped. The sessions and the board stay.")
        for id in running {
            if let sid = state.sessions[id] { try? await api.interrupt(sid) }
        }
    }

    /// The user becomes the lead: plans, conflicts and verdicts come to the user.
    public func takeOver() {
        guard !state.userIsLead else { return }
        update { $0.userIsLead = true }
        notice("You are the lead now.")
    }

    /// Gives the lead back to an agent.
    public func setLead(_ agentID: UUID) {
        guard agent(agentID) != nil else { return }
        update {
            $0.userIsLead = false
            $0.spec.leadAgentID = agentID
        }
        notice("\(name(agentID)) leads now.")
    }

    /// Changes an agent's spending cap. Raising it above the agent's spend lets a capped agent take turns again.
    public func setSpendingCap(_ usd: Double?, for agentID: UUID) {
        guard let i = state.spec.agents.firstIndex(where: { $0.id == agentID }) else { return }
        update { $0.spec.agents[i].spendingCapUSD = usd }
        let spent = state.usage[agentID]?.costUSD ?? 0
        if state.cappedAgents.contains(agentID), usd == nil || spent < usd! {
            update { $0.cappedAgents.removeAll { $0 == agentID } }
            activity[agentID] = .idle
            notice("\(name(agentID)) can take turns again.")
        }
    }

    // MARK: - Runs

    func startRun(task: String, mode: RoomMode, fromUser: Bool) async {
        update {
            $0.run += 1
            $0.runMode = mode
            $0.phase = .idle
            $0.task = task
            $0.plan = nil
            $0.assignments = []
            $0.roundTable = nil
            $0.pendingDecision = nil
            $0.duties = [:]
            $0.outbox = [:]
            $0.isPaused = false
            $0.pauseReason = nil
            $0.interruptedAgents = []
            if mode == .debate { $0.debate = nil }
        }
        resetRelayBudget()
        if fromUser { post(BoardMessage(from: .user, kind: .chat, text: task)) }
        guard !activeAgentIDs.isEmpty else {
            await pauseRoom(reason: "Every agent has reached its spending cap.", interrupt: false)
            return
        }
        if state.briefedMode != mode {
            for id in activeAgentIDs { await inform(id, modeSwitchText(mode)) }
            update { $0.briefedMode = mode }
        }
        switch mode {
        case .solo: await startSolo(task: task, fromUser: fromUser)
        case .team: await startTeam(task: task)
        case .debate: await startDebate(question: task)
        case .roundTable: await startRoundTable(task: task)
        }
    }

    var soloAgentID: UUID? {
        activeLeadID ?? activeAgentIDs.first
    }

    func startSolo(task: String, fromUser: Bool) async {
        guard let id = soloAgentID else { return }
        update { $0.phase = .working }
        let message = fromUser
            ? OutgoingMessage(channel: .prompt, text: task, duty: .solo)
            : OutgoingMessage(channel: .synthetic, text: "[Room] \(task)", duty: .solo)
        await deliver(id, message)
    }

    func soloReplied(_ agent: UUID) async {
        guard state.runMode == .solo, state.phase == .working else { return }
        if !isPending({ $0 == .solo }) { update { $0.phase = .finished } }
    }

    // MARK: - Events

    func handle(_ event: EngineEvent) async {
        switch event {
        case .activity(let sid, let act):
            guard let id = agentID(forSession: sid) else { return }
            switch act {
            case .working:
                busy.insert(id)
                if activity[id] != .capped { activity[id] = .working }
            case .waitingForPermission:
                if activity[id] != .capped { activity[id] = .waitingForPermission }
            case .idle, .failed:
                break
            }
        case .textDelta(let sid, let item, let delta):
            guard let id = agentID(forSession: sid) else { return }
            buffers[id, default: TextBuffer()].add(item, delta: delta)
            liveText[id] = buffers[id]?.text
        case .textEnded(let sid, let item, let text):
            guard let id = agentID(forSession: sid) else { return }
            buffers[id, default: TextBuffer()].end(item, text: text)
            liveText[id] = buffers[id]?.text
        case .usageUpdated(let sid, let usage):
            guard let id = agentID(forSession: sid) else { return }
            await usageChanged(id, usage)
        case .executionEnded(let sid, let outcome, let error):
            guard let id = agentID(forSession: sid) else { return }
            await turnEnded(id, outcome: outcome, error: error)
        case .permissionAsked(let request):
            guard let id = agentID(forSession: request.sessionID), activity[id] != .capped else { return }
            activity[id] = .waitingForPermission
        case .permissionReplied(let sid, _):
            guard let id = agentID(forSession: sid), activity[id] == .waitingForPermission else { return }
            activity[id] = busy.contains(id) ? .working : .idle
        default:
            break
        }
    }

    func turnEnded(_ id: UUID, outcome: String, error: String?) async {
        busy.remove(id)
        let duty = turnDuty.removeValue(forKey: id)
        let text = await collectText(id)
        liveText[id] = nil
        if state.cappedAgents.contains(id) {
            activity[id] = .capped
            // A turn that finished as the cap was hit is paid for: show it, but move nothing.
            if outcome != "interrupted" {
                let body = parser.parse(text).boardText
                if !body.isEmpty { post(BoardMessage(from: .agent(id), kind: .chat, text: body)) }
            }
            return
        }
        activity[id] = .idle
        let interrupted = outcome == "interrupted"
        if interrupted && (state.isPaused || state.phase == .stopped) { return }
        if !interrupted, state.interruptedAgents.contains(id) {
            update { $0.interruptedAgents.removeAll { $0 == id } }
        }
        if outcome == "failed" {
            notice("\(name(id))'s turn failed" + (error.map { ": \($0)" } ?? "."))
        }
        lastText[id] = text
        let parsed = parser.parse(text)
        let purpose = duty ?? state.duties[id]?.first?.purpose ?? .chat
        await postAndRelay(id, parsed: parsed, text: text, purpose: purpose)
        guard state.phase != .stopped else { return }
        await applyDuties(id, parsed: parsed, text: text)
        await afterTurn(id, turnDuty: duty, addressed: !parsed.addressed.isEmpty)
    }

    func collectText(_ id: UUID) async -> String {
        let buffer = buffers.removeValue(forKey: id) ?? TextBuffer()
        let streamed = buffer.text
        if !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return streamed }
        guard let sid = state.sessions[id], let items = try? await api.transcript(sid) else { return "" }
        var collected: [String] = []
        scan: for item in items.reversed() {
            switch item {
            case .agentText(_, let text, _, _): collected.insert(text, at: 0)
            case .reasoning, .tool, .permission, .error: continue
            case .user, .board, .notice: break scan
            }
        }
        return collected.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Board and relay

    func boardKind(_ purpose: TurnPurpose, _ parsed: ParsedReply) -> BoardMessageKind {
        switch purpose {
        case .plan: .plan
        case .work, .resolveConflict, .build, .summary: .update
        case .review, .roundTableReview: .review
        case .argue: .argument
        case .verdict: .verdict
        case .propose, .chat, .solo: parsed.boardText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? .question : .chat
        }
    }

    /// Posts the turn to the board and delivers its `@name` blocks.
    func postAndRelay(_ id: UUID, parsed: ParsedReply, text: String, purpose: TurnPurpose) async {
        let round = purpose.round
        let body = parsed.boardText
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            post(BoardMessage(from: .agent(id), kind: boardKind(purpose, parsed), round: round, text: body))
        }
        let phase = state.phase
        let discussing = phase == .discussing
        let relays = !(phase == .debating || phase == .judging || phase == .stopped || discussing)
        let canWake = phase == .working || phase == .building
        for message in parsed.addressed {
            let targets = message.toAll
                ? agents.map(\.id).filter { $0 != id }
                : message.names.compactMap { agentID(named: $0) }.filter { $0 != id }
            guard !targets.isEmpty else { continue }
            post(BoardMessage(from: .agent(id), to: message.toAll ? [] : targets,
                              kind: message.text.hasSuffix("?") ? .question : .chat, round: round, text: message.text))
            guard relays else { continue }
            let wantsWake = canWake && (!message.toAll || message.text.contains("?"))
            for target in targets {
                guard isActive(target) else {
                    if !message.toAll {
                        notice("\(name(target)) has reached its spending cap, so \(name(id))'s message was not delivered.")
                    }
                    continue
                }
                let line = relayLine(from: id, text: message.text)
                if wantsWake && relayBudget > 0 {
                    relayBudget -= 1
                    await deliver(target, OutgoingMessage(channel: .synthetic, text: line))
                } else {
                    if wantsWake && !relayBudgetNoticePosted {
                        relayBudgetNoticePosted = true
                        notice("Agents have woken each other \(Self.relayWakeLimit) times in a row, so further replies are delivered without waking anyone. Message an agent to continue.")
                    }
                    await inform(target, line)
                }
            }
        }
        if discussing {
            let all = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !all.isEmpty else { return }
            for other in activeAgentIDs where other != id {
                await inform(other, relayLine(from: id, text: all))
            }
        } else if state.runMode == .team, phase == .working || phase == .merging,
                  let lead = activeLeadID, lead != id, !body.isEmpty {
            // Everything that is not addressed goes to the board for the user and the lead.
            await inform(lead, relayLine(from: id, text: body))
        }
    }

    func resetRelayBudget() {
        relayBudget = Self.relayWakeLimit
        relayBudgetNoticePosted = false
    }

    // MARK: - Delivery

    /// Sends a message that asks the agent to act (`prompt` or `injectSynthetic` with `wake: true`).
    /// If the agent is busy or the room is paused, the message waits in the agent's outbox.
    func deliver(_ id: UUID, _ message: OutgoingMessage) async {
        guard let sid = reserve(id, message) else { return }
        await transmit(id, sid, message)
    }

    /// Delivers several messages so that every duty is on record before the first one is sent.
    func deliverAll(_ items: [(UUID, OutgoingMessage)]) async {
        var ready: [(UUID, String, OutgoingMessage)] = []
        for (id, message) in items {
            if let sid = reserve(id, message) { ready.append((id, sid, message)) }
        }
        for (id, sid, message) in ready {
            await transmit(id, sid, message)
        }
    }

    /// Records the message's duty and marks the agent busy. Returns the session to send to now, or
    /// `nil` when the message was queued or dropped.
    private func reserve(_ id: UUID, _ message: OutgoingMessage) -> String? {
        guard isActive(id), let sid = state.sessions[id] else { return nil }
        if state.isPaused || busy.contains(id) {
            update { $0.outbox[id, default: []].append(message) }
            return nil
        }
        busy.insert(id)
        activity[id] = .working
        if let duty = message.duty {
            update { $0.duties[id, default: []].append(Duty(purpose: duty)) }
            resetRelayBudget()
        }
        turnDuty[id] = message.duty ?? message.nudge
        return sid
    }

    private func transmit(_ id: UUID, _ sid: String, _ message: OutgoingMessage) async {
        do {
            switch message.channel {
            case .prompt: try await api.prompt(sid, text: message.text, files: [])
            case .synthetic: try await api.injectSynthetic(sid, text: message.text, wake: true)
            }
        } catch {
            busy.remove(id)
            turnDuty[id] = nil
            activity[id] = .idle
            let reason = "Could not reach \(name(id)): \(error.localizedDescription)"
            lastError = reason
            if let duty = message.duty {
                // Keep the request so resume sends it again.
                update {
                    if let i = $0.duties[id]?.lastIndex(where: { $0.purpose == duty }) { $0.duties[id]?.remove(at: i) }
                    if $0.duties[id]?.isEmpty == true { $0.duties[id] = nil }
                    $0.outbox[id, default: []].insert(message, at: 0)
                }
            }
            await pauseRoom(reason: "Paused. \(reason)", interrupt: false)
        }
    }

    /// Text the agent reads on its next turn (`injectSynthetic` with `wake: false`).
    func inform(_ id: UUID, _ text: String) async {
        guard isActive(id), let sid = state.sessions[id] else { return }
        do {
            try await api.injectSynthetic(sid, text: text, wake: false)
        } catch {
            lastError = "Could not reach \(name(id)): \(error.localizedDescription)"
        }
    }

    func dequeue(_ id: UUID) -> OutgoingMessage? {
        guard var queue = state.outbox[id], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        update { $0.outbox[id] = queue.isEmpty ? nil : queue }
        return next
    }

    /// True when some agent owes (or has waiting in its outbox) a turn matching `match`.
    func isPending(_ match: (TurnPurpose) -> Bool) -> Bool {
        state.duties.values.contains { $0.contains { match($0.purpose) } }
            || state.outbox.values.contains { $0.contains { $0.duty.map(match) ?? false } }
    }

    func hasDuty(_ id: UUID, _ purpose: TurnPurpose) -> Bool {
        state.duties[id]?.contains { $0.purpose == purpose } ?? false
    }

    func pauseRoom(reason: String, interrupt: Bool) async {
        guard !state.isPaused else { return }
        let running = agents.map(\.id).filter { busy.contains($0) }
        update {
            $0.isPaused = true
            $0.pauseReason = reason
            $0.interruptedAgents = running
        }
        notice(reason)
        guard interrupt else { return }
        for id in running {
            if let sid = state.sessions[id] { try? await api.interrupt(sid) }
        }
    }

    // MARK: - Duties

    func satisfies(_ purpose: TurnPurpose, _ reply: ParsedReply, _ text: String) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch purpose {
        case .chat, .solo: return true
        case .plan: return !reply.assignments.isEmpty
        case .work, .resolveConflict: return reply.done
        case .review: return reply.reviewVerdict != nil
        case .roundTableReview: return reply.takeover || reply.reviewVerdict != nil
        case .verdict: return !(reply.verdict ?? "").isEmpty
        case .summary, .argue, .propose, .build: return hasText
        }
    }

    func applyDuties(_ id: UUID, parsed: ParsedReply, text: String) async {
        let current = state.duties[id] ?? []
        guard !current.isEmpty else { return }
        var remaining: [Duty] = []
        var met: [TurnPurpose] = []
        var reviewUsed = false
        for duty in current {
            var ok = satisfies(duty.purpose, parsed, text)
            if ok, case .review = duty.purpose {
                if reviewUsed { ok = false } else { reviewUsed = true }
            }
            if ok { met.append(duty.purpose) } else { remaining.append(duty) }
        }
        guard !met.isEmpty else { return }
        update { $0.duties[id] = remaining.isEmpty ? nil : remaining }
        for purpose in met {
            await fulfilled(id, purpose, parsed: parsed, text: text)
        }
    }

    func fulfilled(_ id: UUID, _ purpose: TurnPurpose, parsed: ParsedReply, text: String) async {
        switch purpose {
        case .chat: break
        case .solo: await soloReplied(id)
        case .plan: await planReady(lead: id, parsed: parsed, text: text)
        case .work: await pieceDone(id)
        case .review(let author): await reviewDone(reviewer: id, author: author, parsed: parsed)
        case .resolveConflict: await conflictResolved()
        case .summary: await teamFinished()
        case .argue(let round): await argued(id, round: round, text: text)
        case .verdict: await verdictReady(text: parsed.verdict ?? text)
        case .propose(let round): await proposed(id, round: round, parsed: parsed, text: text)
        case .build: await built(id, parsed: parsed, text: text)
        case .roundTableReview: await roundTableReviewed(id, parsed: parsed)
        }
    }

    func afterTurn(_ id: UUID, turnDuty duty: TurnPurpose?, addressed: Bool) async {
        guard !state.isPaused, state.phase != .stopped, isActive(id) else { return }
        if !busy.contains(id), let duty, hasDuty(id, duty), !addressed {
            await nudgeOrFallback(id, duty)
        }
        if !busy.contains(id), !state.isPaused, let next = dequeue(id) {
            await deliver(id, next)
        }
        await checkQuiescence()
    }

    /// Asks once for the room format; the second time, falls back and posts a notice.
    func nudgeOrFallback(_ id: UUID, _ purpose: TurnPurpose) async {
        guard let i = state.duties[id]?.firstIndex(where: { $0.purpose == purpose }) else { return }
        if state.duties[id]?[i].retried == false {
            update { $0.duties[id]?[i].retried = true }
            await deliver(id, OutgoingMessage(channel: .synthetic, text: retryText(purpose), nudge: purpose))
            return
        }
        update {
            $0.duties[id]?.remove(at: i)
            if $0.duties[id]?.isEmpty == true { $0.duties[id] = nil }
        }
        let text = lastText[id] ?? ""
        var reply = parser.parse(text)
        switch purpose {
        case .work, .resolveConflict: reply.done = true
        case .review, .roundTableReview:
            reply.approve = true
            reply.changes = nil
            reply.takeover = false
        case .verdict:
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            reply.verdict = whole.isEmpty ? "No verdict was given." : whole
        default: break
        }
        if let note = fallbackNotice(purpose, agent: id) { notice(note) }
        await fulfilled(id, purpose, parsed: reply, text: text)
    }

    /// Called when nobody is busy and nothing is queued. Agents that still owe something get a nudge or
    /// a fallback, so a run never stalls silently.
    func checkQuiescence() async {
        guard !state.isPaused, state.pendingDecision == nil, state.phase.isRunning, busy.isEmpty,
              state.outbox.values.allSatisfy(\.isEmpty) else { return }
        let waiting = agents.map(\.id).filter { isActive($0) && !(state.duties[$0] ?? []).isEmpty }
        if waiting.isEmpty {
            await roomStalled()
            return
        }
        for id in waiting where !busy.contains(id) {
            guard let duty = state.duties[id]?.first else { continue }
            await nudgeOrFallback(id, duty.purpose)
        }
    }

    /// A running phase with nobody owing anything: re-check what should happen next.
    func roomStalled() async {
        switch state.phase {
        case .working where state.runMode == .solo:
            update { $0.phase = .finished }
        case .working:
            await teamStalled()
        case .merging:
            await continueMerge()
        case .summarizing:
            await teamFinished()
        case .debating:
            await advanceDebateIfRoundComplete()
        case .discussing:
            await nextSpeaker()
        case .building:
            await concludeReviewRound()
        case .planning, .judging:
            await pauseRoom(reason: "Paused: nobody is left to finish this step.", interrupt: false)
        default:
            break
        }
    }

    // MARK: - Spending caps

    func usageChanged(_ id: UUID, _ usage: Usage) async {
        update { $0.usage[id] = usage }
        guard let cap = agent(id)?.spendingCapUSD, usage.costUSD >= cap, !state.cappedAgents.contains(id) else { return }
        await capAgent(id, cap: cap, spent: usage.costUSD)
    }

    func capAgent(_ id: UUID, cap: Double, spent: Double) async {
        let wasBusy = busy.contains(id)
        let open = (state.duties[id] ?? []).map(\.purpose) + (state.outbox[id] ?? []).compactMap(\.duty)
        update {
            $0.cappedAgents.append(id)
            $0.duties[id] = nil
            $0.outbox[id] = nil
            $0.interruptedAgents.removeAll { $0 == id }
        }
        activity[id] = .capped
        turnDuty[id] = nil
        notice("\(name(id)) reached its spending cap (\(Self.dollars(spent)) of \(Self.dollars(cap))) and was stopped. It gets no more turns.")
        if wasBusy, let sid = state.sessions[id] { try? await api.interrupt(sid) }
        await continueWithout(id, openDuties: open)
    }

    /// The room continues without a capped agent if it can, otherwise pauses.
    func continueWithout(_ id: UUID, openDuties: [TurnPurpose]) async {
        guard state.phase.isRunActive else { return }
        if activeAgentIDs.isEmpty {
            let reason = agents.count == 1 ? "Paused: \(name(id)) reached its spending cap." : "Paused: every agent has reached its spending cap."
            await pauseRoom(reason: reason, interrupt: true)
            return
        }
        switch state.runMode {
        case .solo:
            await pauseRoom(reason: "Paused: \(name(id)) reached its spending cap.", interrupt: true)
        case .team:
            await teamContinueWithout(id, openDuties: openDuties)
        case .debate:
            await debateContinueWithout(id, openDuties: openDuties)
        case .roundTable:
            await roundTableContinueWithout(id, openDuties: openDuties)
        }
    }

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

/// Text of one agent turn, assembled from streaming events.
struct TextBuffer {
    private var order: [String] = []
    private var parts: [String: String] = [:]
    private var ended: Set<String> = []

    mutating func add(_ item: String, delta: String) {
        if parts[item] == nil {
            order.append(item)
            parts[item] = ""
        }
        if !ended.contains(item) { parts[item, default: ""] += delta }
    }

    mutating func end(_ item: String, text: String) {
        if parts[item] == nil { order.append(item) }
        parts[item] = text
        ended.insert(item)
    }

    var text: String {
        order.compactMap { parts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
