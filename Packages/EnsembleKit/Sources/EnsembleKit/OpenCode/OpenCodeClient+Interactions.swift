import Foundation
import Synchronization

/// What `OpenCodeClient` keeps for plans: OpenCode's `plan` agent has no tool that hands a plan over (its reminder says
/// to "discuss the plan with the user directly in the conversation"), so when a turn of a session on the plan agent
/// ends, the client turns the agent's last reply into a plan request (`PermissionRequest.plan`) and remembers it until
/// it is answered or a new turn starts.
struct OpenCodeInteractionState {
    /// The open plan of each session.
    var pendingPlans: [String: PermissionRequest] = [:]
    /// Live full event streams; plans the client makes are sent to every one of them.
    var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    /// Sessions whose finished turn is being checked for a plan right now (several streams see the same event).
    var checking: Set<String> = []
    /// Plans answered or withdrawn, so a stream that sees a turn end late cannot bring one back.
    var settledPlans: Set<String> = []
    /// Each session's agent, as the live events report it; sessions on another agent are not checked for plans.
    var agents: [String: String] = [:]
}

extension OpenCodeInteractionState {
    mutating func settle(_ planID: String) {
        settledPlans.insert(planID)
        if settledPlans.count > 500 { settledPlans.removeAll() }
    }
}

extension OpenCodeClient: EngineInteractionControl {
    // MARK: Event streams

    func addInteractionSubscriber(_ continuation: AsyncStream<EngineEvent>.Continuation) -> UUID {
        let id = UUID()
        interactions.withLock { $0.subscribers[id] = continuation }
        return id
    }

    func removeInteractionSubscriber(_ id: UUID) {
        _ = interactions.withLock { $0.subscribers.removeValue(forKey: id) }
    }

    private func broadcast(_ events: [EngineEvent]) {
        let targets = interactions.withLock { Array($0.subscribers.values) }
        for continuation in targets {
            for event in events { continuation.yield(event) }
        }
    }

    /// Plan bookkeeping after each live event: a new turn withdraws the session's open plan, and a turn of the plan
    /// agent that ends well presents its last reply as a plan.
    func afterEvent(_ event: EngineEvent) async {
        switch event {
        case .sessionCreated(let info), .sessionUpdated(let info):
            if let agent = info.agent { interactions.withLock { $0.agents[info.id] = agent } }
        case .activity(let sessionID, .working):
            withdrawPlan(sessionID)
        case .executionEnded(let sessionID, "succeeded", nil):
            let due = interactions.withLock { state -> Bool in
                if let agent = state.agents[sessionID], agent != PermissionRules.agent(for: .plan) { return false }
                return state.checking.insert(sessionID).inserted
            }
            guard due else { return }
            let plan = await planAfterTurn(sessionID)
            let isNew = interactions.withLock { state -> Bool in
                state.checking.remove(sessionID)
                guard let plan, !state.settledPlans.contains(plan.id), state.pendingPlans[sessionID]?.id != plan.id else { return false }
                state.pendingPlans[sessionID] = plan
                return true
            }
            if isNew, let plan { broadcast([.permissionAsked(plan)]) }
        default:
            break
        }
    }

    private func withdrawPlan(_ sessionID: String) {
        guard let plan = interactions.withLock({ state -> PermissionRequest? in
            guard let plan = state.pendingPlans.removeValue(forKey: sessionID) else { return nil }
            state.settle(plan.id)
            return plan
        }) else { return }
        broadcast([.permissionReplied(sessionID: sessionID, requestID: plan.id)])
    }

    /// The plan request for a session's finished turn: only for top-level sessions on the plan agent, from the newest
    /// assistant reply with text since the last user message. Its id comes from that message, so every stream makes the
    /// same request.
    func planAfterTurn(_ sessionID: String) async -> PermissionRequest? {
        guard let info = try? await session(sessionID), info.parentID == nil,
              info.agent == PermissionRules.agent(for: .plan) else { return nil }
        let query = [URLQueryItem(name: "limit", value: "40")]
        guard let page: Wire.Page<Wire.Lossy<Wire.Message>> = try? await get("/api/session/\(sessionID)/message", query: query) else {
            return nil
        }
        // Newest first.
        for message in page.data.compactMap(\.value) {
            switch message.type {
            case "assistant":
                let text = (message.content ?? []).compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let plan = PlanProposal(markdown: text)
                return PermissionRequest(id: "plan-" + message.id, sessionID: sessionID, kind: InteractionKind.plan,
                                         title: plan.title, plan: plan)
            case "user", "synthetic":
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// Open forms in the loaded project folders, as question requests.
    func pendingForms(directories: [String]) async -> [PermissionRequest] {
        var forms: [OpenCodeForms.Form] = []
        await withTaskGroup(of: [OpenCodeForms.Form].self) { group in
            for directory in directories.isEmpty ? [nil] : directories.map(Optional.some) {
                group.addTask {
                    let response: Wire.LocationEnvelope<[Wire.Lossy<OpenCodeForms.Form>]>? =
                        try? await self.get("/api/form", query: Self.location(directory))
                    return response?.data.compactMap(\.value) ?? []
                }
            }
            for await batch in group { forms += batch }
        }
        var seen = Set<String>()
        return forms.filter { seen.insert($0.id).inserted }.compactMap { OpenCodeForms.request($0) }
    }

    // MARK: Modes

    /// Moves the session to OpenCode's `plan` agent for Plan mode and back to `build` when leaving it. Only a session
    /// on one of those two agents is moved, so an agent chosen some other way is left alone.
    func switchAgentForMode(_ sessionID: String, mode: PermissionMode) async throws {
        let wanted = PermissionRules.agent(for: mode)
        let current = try await session(sessionID).agent ?? PermissionRules.agent(for: .ask)
        guard current != wanted, [PermissionRules.agent(for: .plan), PermissionRules.agent(for: .ask)].contains(current) else { return }
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/agent", body: ["agent": .string(wanted)])
    }

    // MARK: EngineInteractionControl

    public func planModeSupport(sessionID: String) async -> PlanModeSupport { .supported }

    /// Fetches the form first: that checks it is still open in this session, and gives each answer its field's type.
    public func answerQuestion(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) async throws {
        let detail: Wire.DataEnvelope<OpenCodeForms.Detail> = try await get("/api/session/\(sessionID)/form/\(requestID)")
        guard detail.data.sessionID == sessionID, detail.data.id == requestID, (detail.data.state?.status ?? "pending") == "pending" else {
            throw OpenCodeError.invalidArgument("This question is no longer open in this session.")
        }
        let questions = detail.data.fields.compactMap(OpenCodeForms.question)
        let answer = OpenCodeForms.answer(fields: detail.data.fields, questions: questions, answers: answers)
        if answer.isEmpty {
            try await sendIgnoringBody("DELETE", "/api/session/\(sessionID)/form/\(requestID)")
        } else {
            try await sendIgnoringBody("POST", "/api/session/\(sessionID)/form/\(requestID)/reply", body: ["answer": .object(answer)])
        }
    }

    /// The plan agent's turn has ended, so both answers continue with a message: Proceed first sets the chosen mode
    /// (rules and the `build` agent), Keep planning sends the comments and stays on the plan agent.
    public func respondToPlan(sessionID: String, requestID: String, decision: PlanDecision) async throws -> String? {
        guard interactions.withLock({ $0.pendingPlans[sessionID]?.id == requestID }) else {
            throw OpenCodeError.invalidArgument("This plan is no longer open in this session.")
        }
        let message: String
        switch decision {
        case .proceed(let mode):
            guard mode != .plan else { throw OpenCodeError.invalidArgument("Proceed needs a mode other than Plan.") }
            try await setPermissionMode(sessionID, mode: mode)
            message = PlanLines.proceedMessage
        case .keepPlanning(let comments):
            message = PlanLines.feedback(comments)
        }
        let removed = interactions.withLock { state -> Bool in
            guard state.pendingPlans[sessionID]?.id == requestID else { return false }
            state.pendingPlans[sessionID] = nil
            state.settle(requestID)
            return true
        }
        if removed { broadcast([.permissionReplied(sessionID: sessionID, requestID: requestID)]) }
        return message
    }
}
