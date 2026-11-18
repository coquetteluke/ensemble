import Foundation

/// Auto for agents Ensemble decides itself (`SafetyCheckAgents.swift`), in the store. `safetyCheckHolds` hands every
/// prompt to `agentSafetyCheckHolds` first: for a session whose engine decides its Auto prompts through Ensemble, the
/// answer is final and the OpenCode path never runs (so Ask, Accept edits, Plan and Bypass keep working as before).
///
/// In Auto every prompt is held while Ensemble asks the engine what exactly it asks (`autoPromptSubject`). Then:
/// - an edit `SafetyCheckAgentRules.editReason` passes is answered "once";
/// - a command goes past `SafetyCheckHardRules`, is answered "once" when `SafetyCheckAgentRules.isReadOnly`, and
///   otherwise goes to the model chosen in Settings (agents like Antigravity have no provider in OpenCode, so "Same
///   provider as each session" means no model, and the command asks);
/// - everything else, and anything that fails, times out or cannot be read exactly, is shown to the user as usual.
/// Every decision is recorded like the safety check's: the "Checked" badge for allowed tool calls and the session's list.
extension SessionStore {
    var agentPermissionSupport: (any EngineAgentPermissionSupport)? { engine as? any EngineAgentPermissionSupport }

    /// Nil when the session's prompts are not Ensemble's to decide (the OpenCode safety check then looks at them).
    /// Otherwise whether the prompt is held: true while Ensemble decides it, false when it is shown now.
    func agentSafetyCheckHolds(_ request: PermissionRequest) -> Bool? {
        guard let support = agentPermissionSupport, support.decidesAutoPrompts(for: request.sessionID) else { return nil }
        let check = safetyCheck
        if check.checking.contains(request.id) { return true }
        if check.released.contains(request.id) { return false }
        guard !request.isInteraction, let session = byID[request.sessionID],
              !session.pendingPermissions.contains(where: { $0.id == request.id }),
              session.resolutions[request.id] == nil else { return false }
        let root = topLevelSession(of: session)
        guard root.permissionMode == .auto else { return false }
        check.checking.insert(request.id)
        let instruction = latestInstruction(in: root)
        let rootID = root.id
        check.tasks[request.id] = Task { [weak self] in
            await self?.runAgentSafetyCheck(request, support: support, rootSessionID: rootID, instruction: instruction)
        }
        return true
    }

    /// Decides one held prompt of an agent session in Auto.
    func runAgentSafetyCheck(_ request: PermissionRequest, support: any EngineAgentPermissionSupport, rootSessionID: String,
                             instruction: String) async {
        let check = safetyCheck
        let fallback = SafetyCheckQuery(action: request.kind, resources: Self.resources(of: request),
                                        directory: byID[request.sessionID]?.directory ?? "", instruction: instruction)
        let requestID = request.id, sessionID = request.sessionID
        let found = await SafetyCheckClassifier.within(check.settings.timeout) {
            await support.autoPromptSubject(forPermission: requestID, sessionID: sessionID)
        }
        guard let subject = found, let session = byID[request.sessionID] else {
            await finishSafetyCheck(request, query: fallback, toolCallID: nil, rootSessionID: rootSessionID,
                                    verdict: .ask, basis: .failed, reason: "Could not identify exactly what is asked", model: nil)
            return
        }
        let toolCallID = subject.toolCallID
        if let toolCallID { check.badges.setChecking(toolCallID, true) }
        switch subject.action {
        case .edit(let paths):
            let query = SafetyCheckQuery(action: "edit", resources: paths, directory: session.directory, instruction: instruction)
            if let reason = subject.askReason ?? SafetyCheckAgentRules.editReason(paths: paths, directory: session.directory) {
                await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                        verdict: .ask, basis: .rule, reason: reason, model: nil)
            } else {
                await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                        verdict: .allow, basis: .rule, reason: SafetyCheckAgentRules.editAllowed, model: nil)
            }
        case .command(let command, let folder):
            let query = SafetyCheckQuery(action: "shell", resources: [command], command: command, directory: folder,
                                         instruction: instruction)
            if let reason = subject.askReason ?? SafetyCheckHardRules.reasonToAsk(query) {
                await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                        verdict: .ask, basis: .rule, reason: reason, model: nil)
                return
            }
            if SafetyCheckAgentRules.isReadOnly(command) {
                await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                        verdict: .allow, basis: .rule, reason: SafetyCheckAgentRules.readOnly, model: nil)
                return
            }
            let answer = await agentClassifierVerdict(query, rootSessionID: rootSessionID)
            await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                    verdict: answer.verdict, basis: answer.basis, reason: answer.reason, model: answer.model)
        case .other(let reason):
            await finishSafetyCheck(request, query: fallback, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                    verdict: .ask, basis: .rule, reason: subject.askReason ?? reason, model: nil)
        }
    }

    /// The model chosen in Settings, while the engine still lists it. Agent sessions never fall back to their own
    /// provider: it is not one OpenCode has, and the check never calls an agent's provider itself.
    func agentClassifierModel() -> SafetyCheckModel? {
        guard let preferred = safetyCheck.settings.model else { return nil }
        return safetyCheck.models.first { $0.ref.providerID == preferred.providerID && $0.ref.id == preferred.id }
    }

    /// The model's answer for a command the rules left open, with the same switch, time limit, cache and usage as the
    /// OpenCode safety check. Anything but a clear ALLOW asks.
    func agentClassifierVerdict(_ query: SafetyCheckQuery, rootSessionID: String)
        async -> (verdict: SafetyCheckVerdict, basis: SafetyCheckBasis, reason: String, model: ModelRef?) {
        let check = safetyCheck
        let limit = check.settings.timeout
        guard check.settings.enabled != false else { return (.ask, .failed, "The safety check is off", nil) }
        guard check.settings.model != nil else { return (.ask, .failed, "No safety check model is chosen in Settings", nil) }
        guard let support = safetyCheckSupport else { return (.ask, .failed, "No engine can run the safety check", nil) }
        _ = await SafetyCheckClassifier.within(limit) { [weak self] in
            await self?.ensureSafetyCheckModels()
            return true
        }
        guard let model = agentClassifierModel() else {
            return (.ask, .failed, "The safety check model chosen in Settings is not available", nil)
        }
        // Switch not chosen: only a cheap model runs, as for OpenCode sessions.
        if check.settings.enabled == nil, !model.isCheap { return (.ask, .failed, "The safety check is off", nil) }
        if let cached = check.cachedAnswer(rootSessionID: rootSessionID, key: query.cacheKey) {
            return (cached.verdict, .cache, cached.reason, cached.model)
        }
        let prompt = SafetyCheckClassifier.prompt(for: query, nonce: check.makeNonce())
        let ref = model.ref
        let outcome = await SafetyCheckClassifier.run(timeout: limit) {
            try await support.generateSafetyCheckText(prompt: prompt, model: ref)
        }
        switch outcome {
        case .answered(let text):
            check.addUsage(rootSessionID: rootSessionID, prompt: prompt, answer: text, model: model)
            guard let answer = SafetyCheckClassifier.parse(text) else {
                return (.ask, .failed, "The model's answer was not ALLOW or ASK", ref)
            }
            check.remember(.init(verdict: answer.verdict, reason: answer.reason, model: ref), rootSessionID: rootSessionID,
                           key: query.cacheKey)
            return (answer.verdict, .model, answer.reason, ref)
        case .timedOut:
            check.addUsage(rootSessionID: rootSessionID, prompt: prompt, answer: nil, model: model)
            return (.ask, .failed, "The safety check took longer than \(Self.seconds(limit))", ref)
        case .failed(let message):
            return (.ask, .failed, "The safety check failed: \(SafetyCheckClassifier.cleanReason(message))", ref)
        }
    }
}
