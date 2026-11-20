import Foundation

/// Plans and questions (`Model/Interactions.swift`). They wait in the session's `pendingPermissions` like permission
/// prompts, so the sidebar marks, alerts, the Session Hub and the iPhone see them, but they are answered with their
/// own calls through `EngineInteractionControl`, never with Allow or Reject.
extension SessionStore {
    public var interactionControl: (any EngineInteractionControl)? { engine as? any EngineInteractionControl }

    // MARK: Queries

    /// The oldest open question in a session, for the card docked above the composer.
    public func openQuestion(in sessionID: String) -> PermissionRequest? {
        byID[sessionID]?.pendingPermissions.first(where: \.isQuestion)
    }

    /// The mode Proceed returns to: the mode before Plan, else the session's mode when the agent planned on its own
    /// initiative, else Accept edits.
    public func proceedMode(for sessionID: String) -> PermissionMode {
        let primaryID = primarySessionID(for: sessionID)
        if let mode = modeBeforePlan[primaryID] ?? modeBeforePlan[sessionID], mode != .plan { return mode }
        if let mode = byID[primaryID]?.permissionMode, mode != .plan { return mode }
        return .acceptEdits
    }

    /// Plan support for the composer's menu, once loaded; nil until then.
    public func planModeSupport(for sessionID: String) -> PlanModeSupport? {
        planSupport[primarySessionID(for: sessionID)]
    }

    /// Asks the engine whether the session can use Plan mode, and remembers the answer.
    @discardableResult
    public func loadPlanModeSupport(for sessionID: String) async -> PlanModeSupport {
        let primaryID = primarySessionID(for: sessionID)
        if let known = planSupport[primaryID] { return known }
        let targetID = backingSessionID(for: primaryID)
        let support = await interactionControl?.planModeSupport(sessionID: targetID)
            ?? .unsupported(reason: "This engine has no plan mode")
        planSupport[primaryID] = support
        return support
    }

    /// The next mode for Shift-Tab, skipping Plan where the session has no plan mode.
    public func nextPermissionMode(for sessionID: String) -> PermissionMode {
        let primaryID = primarySessionID(for: sessionID)
        guard let session = byID[primaryID] else { return .ask }
        var next = session.permissionMode.next
        if next == .plan, planSupport[primaryID]?.isSupported != true { next = next.next }
        return next
    }

    /// Previews and snapshots: shows these requests as resolved this way.
    public func recordOutcomesForSnapshots(_ outcomes: [String: InteractionOutcome]) {
        interactionOutcomes.merge(outcomes) { _, new in new }
    }

    /// Fills in what the store adds to a plan before showing it: the mode Proceed switches to.
    func prepared(_ request: PermissionRequest) -> PermissionRequest {
        guard request.isPlan, request.plan?.proceedMode == nil else { return request }
        var copy = request
        copy.plan?.proceedMode = proceedMode(for: request.sessionID)
        return copy
    }

    // MARK: Answers

    /// Sends answers to a session's open question. Every question needs an answer; the answers reach only the session
    /// that asked (the engine checks the request belongs to it).
    @discardableResult
    public func answerQuestion(_ request: PermissionRequest, answers: [AgentQuestionAnswer]) async -> Bool {
        guard let questions = request.questions, !questions.isEmpty else { return false }
        let usable = questions.compactMap { question in
            answers.first { $0.questionID == question.id }.flatMap(question.validated)
        }
        guard usable.count == questions.count else {
            lastError = "Answer every question first."
            return false
        }
        return await resolve(request, outcome: .answered(usable)) { control in
            try await control.answerQuestion(sessionID: request.sessionID, requestID: request.id, answers: usable)
            return nil
        }
    }

    /// Declines a question: the agent is told the user chose not to answer.
    @discardableResult
    public func declineQuestion(_ request: PermissionRequest) async -> Bool {
        guard request.isQuestion else { return false }
        return await resolve(request, outcome: .declined) { control in
            try await control.answerQuestion(sessionID: request.sessionID, requestID: request.id, answers: [])
            return nil
        }
    }

    /// Proceed (only to a mode the plan card offers) or keep planning with line comments.
    @discardableResult
    public func respondToPlan(_ request: PermissionRequest, decision: PlanDecision) async -> Bool {
        guard let plan = request.isPlan ? (pendingCopy(of: request)?.plan ?? request.plan) : nil else { return false }
        let outcome: InteractionOutcome
        switch decision {
        case .proceed(let mode):
            guard plan.allowedProceedModes.contains(mode) else {
                lastError = "That plan can only proceed in \(plan.allowedProceedModes.map(\.shortLabel).joined(separator: " or "))."
                return false
            }
            outcome = .proceeded(mode)
        case .keepPlanning(let comments):
            outcome = .keptPlanning(commentCount: comments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
        }
        let session = byID[request.sessionID]
        let previousMode = session?.permissionMode
        if case .proceed(let mode) = decision, let session {
            session.permissionMode = mode
            permissionRulesChecked.insert(session.id)
        }
        let delivered = await resolve(request, outcome: outcome) { control in
            try await control.respondToPlan(sessionID: request.sessionID, requestID: request.id, decision: decision)
        }
        if !delivered, let session, let previousMode { session.permissionMode = previousMode }
        if delivered, case .proceed(let mode) = decision {
            let primaryID = primarySessionID(for: request.sessionID)
            modeBeforePlan[primaryID] = nil
            modeBeforePlan[request.sessionID] = nil
            threadLinks.updatePermissionMode(mode, forBackingID: request.sessionID, primaryID: primaryID)
        }
        return delivered
    }

    /// Reject from an Allow/Reject surface (palette, older iPhone apps): keeps planning or declines. Allow is refused,
    /// since it would approve a plan without a visible mode or answer a question with nothing.
    func replyToInteraction(_ request: PermissionRequest, decision: PermissionDecision) async {
        guard decision == .reject else {
            lastError = request.isPlan ? "Choose Proceed on the plan card." : "Answer the question in its card."
            return
        }
        if request.isPlan {
            await respondToPlan(request, decision: .keepPlanning(comments: []))
        } else {
            await declineQuestion(request)
        }
    }

    /// The request as the session holds it (with the store's additions), if it is still open.
    private func pendingCopy(of request: PermissionRequest) -> PermissionRequest? {
        byID[request.sessionID]?.pendingPermissions.first { $0.id == request.id }
    }

    /// Marks the request answered at once, calls the engine, and sends the engine's follow-up message as the user.
    /// Restores the request when the engine refuses. Returns whether the engine took the answer.
    @discardableResult
    private func resolve(_ request: PermissionRequest, outcome: InteractionOutcome,
                         call: (any EngineInteractionControl) async throws -> String?) async -> Bool {
        guard let session = byID[request.sessionID], let open = pendingCopy(of: request) else { return false }
        guard let control = interactionControl else {
            lastError = "This engine cannot answer plans or questions."
            return false
        }
        session.resolutions[request.id] = outcome.resolution
        interactionOutcomes[request.id] = outcome
        session.pendingPermissions.removeAll { $0.id == request.id }
        if session.activity == .waitingForPermission, session.pendingPermissions.isEmpty {
            session.setActivity(.working)
        }
        session.touch()
        do {
            if let followUp = try await call(control) {
                await deliver(followUp, to: session.id)
            }
            return true
        } catch {
            session.resolutions[request.id] = nil
            interactionOutcomes[request.id] = nil
            if !session.pendingPermissions.contains(where: { $0.id == request.id }) {
                session.pendingPermissions.append(open)
            }
            lastError = "Could not answer: \(error.localizedDescription)"
            session.touch()
            return false
        }
    }
}

extension InteractionOutcome {
    /// The plain resolution the transcript's grouping and older views read.
    var resolution: PermissionResolution {
        switch self {
        case .proceeded, .answered: .allowedOnce
        case .keptPlanning, .declined: .rejected
        }
    }
}
