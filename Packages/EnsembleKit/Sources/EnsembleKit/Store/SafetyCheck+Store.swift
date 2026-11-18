import Foundation

/// The safety check in the store (`SafetyCheck.swift`). `apply` hands every permission prompt to `safetyCheckHolds`
/// first. A prompt the check covers (an OpenCode session in Auto, or a shell command in Accept edits when that is on) is
/// not shown while it is checked: the fixed rules decide at once, otherwise the model has `settings.timeout` to answer.
/// ALLOW answers the prompt "once"; anything else shows the prompt as usual. A prompt answered elsewhere meanwhile (the
/// iPhone, a stopped turn) is dropped.
extension SessionStore {
    var safetyCheckSupport: (any EngineSafetyCheckSupport)? { engine as? any EngineSafetyCheckSupport }

    // MARK: Queries

    /// The decisions for a session (a subagent shows its top-level session's), newest first.
    public func safetyCheckDecisions(for sessionID: String) -> [SafetyCheckDecision] {
        guard let session = byID[sessionID] else { return safetyCheck.decisions(forRoot: sessionID) }
        return safetyCheck.decisions(forRoot: topLevelSession(of: session).id)
    }

    /// Classifier usage for a session (its top-level session's), labelled "Safety check" where shown.
    public func safetyCheckUsage(for sessionID: String) -> SafetyCheckUsage {
        guard let session = byID[sessionID] else { return safetyCheck.usage(forRoot: sessionID) }
        return safetyCheck.usage(forRoot: topLevelSession(of: session).id)
    }

    /// True when the safety check can decide this session's prompts (an OpenCode session).
    public func safetyCheckApplies(to sessionID: String) -> Bool {
        safetyCheckSupport?.safetyCheckApplies(to: sessionID) ?? false
    }

    /// Asks the engine for the models the check can use (Settings calls this when it opens).
    public func loadSafetyCheckModels() async {
        guard let support = safetyCheckSupport else {
            safetyCheck.modelsLoaded = true
            return
        }
        let list = (try? await support.safetyCheckModels()) ?? []
        safetyCheck.models = list
        safetyCheck.modelsLoaded = true
        safetyCheck.modelsLoadedAt = Date()
    }

    /// Loads the model list when it was never loaded or is old; waits for a load already running.
    func ensureSafetyCheckModels() async {
        let check = safetyCheck
        if let loadedAt = check.modelsLoadedAt, check.modelsLoaded,
           Date().timeIntervalSince(loadedAt) < SafetyCheckState.modelListLifetime { return }
        if let running = check.modelsTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadSafetyCheckModels()
        }
        check.modelsTask = task
        await task.value
        check.modelsTask = nil
    }

    /// Whether the check covers a prompt of `action` in a session in `mode`.
    static func safetyCheckCovers(mode: PermissionMode, action: String, settings: SafetyCheckSettings) -> Bool {
        switch mode {
        case .auto: true
        case .acceptEdits: settings.checkAcceptEdits && (action == "shell" || action == "bash")
        case .ask, .plan, .bypass: false
        }
    }

    // MARK: Holding prompts

    /// Called from `apply` before a permission prompt is shown. True when the check takes the prompt: it is not shown
    /// now, and is shown later only if the check leaves it for the user. Fixed-rule decisions are made here, so those
    /// prompts show at once.
    func safetyCheckHolds(_ request: PermissionRequest) -> Bool {
        // Agents whose Auto Ensemble decides itself (`SafetyCheck+Agents.swift`) never take the OpenCode path.
        if let held = agentSafetyCheckHolds(request) { return held }
        let check = safetyCheck
        if check.checking.contains(request.id) { return true }
        if check.released.contains(request.id) { return false }
        guard !request.isInteraction, check.settings.enabled != false,
              let support = safetyCheckSupport,
              let session = byID[request.sessionID],
              !session.pendingPermissions.contains(where: { $0.id == request.id }),
              session.resolutions[request.id] == nil else { return false }
        let root = topLevelSession(of: session)
        guard Self.safetyCheckCovers(mode: root.permissionMode, action: request.kind, settings: check.settings),
              support.safetyCheckApplies(to: request.sessionID) else { return false }
        // A guess at the tool call, only to show "Checking" on it. Nothing is decided on the guess: the rules here see
        // only what the prompt itself names, and the whole command comes from the engine (`runSafetyCheck`).
        let tool = matchingTool(for: request, in: session)
        let query = SafetyCheckQuery(action: request.kind, resources: Self.resources(of: request), command: nil,
                                     directory: session.directory, instruction: latestInstruction(in: root))
        // The session's own model decides which provider the check may use.
        let sessionModel = session.info.model ?? root.info.model
        switch check.readiness(forSession: sessionModel) {
        case .off:
            return false
        case .on:
            if let reason = SafetyCheckHardRules.reasonToAsk(query) {
                check.markReleased(request.id)
                check.record(decision(request, query: query, toolCallID: nil, verdict: .ask, basis: .rule, reason: reason),
                             rootSessionID: root.id)
                return false
            }
        case .unknown:
            break
        }
        check.checking.insert(request.id)
        if let toolID = tool?.id { check.badges.setChecking(toolID, true) }
        check.tasks[request.id] = Task { [weak self] in
            await self?.runSafetyCheck(request, query: query, toolCallID: tool?.id, rootSessionID: root.id, sessionModel: sessionModel)
        }
        return true
    }

    /// The check for one held prompt.
    func runSafetyCheck(_ request: PermissionRequest, query initialQuery: SafetyCheckQuery, toolCallID initialToolCallID: String?,
                        rootSessionID: String, sessionModel: ModelRef?) async {
        let check = safetyCheck
        let limit = check.settings.timeout
        // The engine gets the same time limit as the model: a slow answer leaves the prompt for the user.
        _ = await SafetyCheckClassifier.within(limit) { [weak self] in
            await self?.ensureSafetyCheckModels()
            return true
        }
        // Switch not chosen and no cheap model on the session's provider (or no list in time): show the prompt as if the
        // check never ran.
        guard check.readiness(forSession: sessionModel) == .on, let support = safetyCheckSupport else {
            releaseSafetyCheckPrompt(request, toolCallID: initialToolCallID)
            return
        }
        var query = initialQuery
        // The exact tool call, from the engine. Only its whole command is judged; a prompt whose call cannot be found
        // (no answer, no answer in time, or no such call in the transcript) asks, so nothing is approved on a guess.
        let requestID = request.id, sessionID = request.sessionID
        let exact = await SafetyCheckClassifier.within(limit) { await support.toolCallID(forPermission: requestID, sessionID: sessionID) }
        if let guess = initialToolCallID, guess != exact { check.badges.setChecking(guess, false) }
        guard let exact, let session = byID[request.sessionID], let tool = tool(withID: exact, in: session),
              let command = Self.exactCommand(of: tool, action: request.kind) else {
            for id in [initialToolCallID, exact].compactMap({ $0 }) { check.badges.setChecking(id, false) }
            await finishSafetyCheck(request, query: query, toolCallID: nil, rootSessionID: rootSessionID,
                                    verdict: .ask, basis: .failed, reason: Self.unidentified, model: nil)
            return
        }
        let toolCallID: String? = exact
        check.badges.setChecking(exact, true)
        query.command = command
        if let reason = SafetyCheckHardRules.reasonToAsk(query) {
            await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                    verdict: .ask, basis: .rule, reason: reason, model: nil)
            return
        }
        if let cached = check.cachedAnswer(rootSessionID: rootSessionID, key: query.cacheKey) {
            await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                    verdict: cached.verdict, basis: .cache, reason: cached.reason, model: cached.model)
            return
        }
        guard let model = check.classifierModel(forSession: sessionModel) else {
            await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                    verdict: .ask, basis: .failed, reason: "No model is available for the safety check", model: nil)
            return
        }
        let prompt = SafetyCheckClassifier.prompt(for: query, nonce: check.makeNonce())
        let ref = model.ref
        let outcome = await SafetyCheckClassifier.run(timeout: check.settings.timeout) {
            try await support.generateSafetyCheckText(prompt: prompt, model: ref)
        }
        let verdict: SafetyCheckVerdict
        let basis: SafetyCheckBasis
        let reason: String
        switch outcome {
        case .answered(let text):
            check.addUsage(rootSessionID: rootSessionID, prompt: prompt, answer: text, model: model)
            if let answer = SafetyCheckClassifier.parse(text) {
                check.remember(.init(verdict: answer.verdict, reason: answer.reason, model: ref), rootSessionID: rootSessionID,
                               key: query.cacheKey)
                (verdict, basis, reason) = (answer.verdict, .model, answer.reason)
            } else {
                (verdict, basis, reason) = (.ask, .failed, "The model's answer was not ALLOW or ASK")
            }
        case .timedOut:
            check.addUsage(rootSessionID: rootSessionID, prompt: prompt, answer: nil, model: model)
            (verdict, basis, reason) = (.ask, .failed, "The safety check took longer than \(Self.seconds(check.settings.timeout))")
        case .failed(let message):
            (verdict, basis, reason) = (.ask, .failed, "The safety check failed: \(SafetyCheckClassifier.cleanReason(message))")
        }
        await finishSafetyCheck(request, query: query, toolCallID: toolCallID, rootSessionID: rootSessionID,
                                verdict: verdict, basis: basis, reason: reason, model: ref)
    }

    /// Records the decision, then answers the prompt (ALLOW) or shows it. Nothing happens to a prompt answered
    /// elsewhere meanwhile.
    func finishSafetyCheck(_ request: PermissionRequest, query: SafetyCheckQuery, toolCallID: String?, rootSessionID: String,
                           verdict: SafetyCheckVerdict, basis: SafetyCheckBasis, reason: String, model: ModelRef?) async {
        let check = safetyCheck
        guard let session = byID[request.sessionID], session.resolutions[request.id] == nil else {
            dropSafetyCheckPrompt(request, toolCallID: toolCallID)
            return
        }
        let made = decision(request, query: query, toolCallID: toolCallID, verdict: verdict, basis: basis, reason: reason, model: model)
        guard verdict == .allow else {
            check.record(made, rootSessionID: rootSessionID)
            releaseSafetyCheckPrompt(request, toolCallID: toolCallID)
            return
        }
        do {
            try await engine.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: .once, message: nil)
            check.record(made, rootSessionID: rootSessionID)
            dropSafetyCheckPrompt(request, toolCallID: nil)
        } catch {
            // Answered elsewhere first (the engine no longer has it): nothing to show.
            if byID[request.sessionID]?.resolutions[request.id] != nil || Self.isMissingPrompt(error) {
                dropSafetyCheckPrompt(request, toolCallID: toolCallID)
                return
            }
            var failed = made
            failed.verdict = .ask
            failed.basis = .failed
            failed.reason = "Could not answer the prompt: \(SafetyCheckClassifier.cleanReason(error.localizedDescription))"
            check.record(failed, rootSessionID: rootSessionID)
            releaseSafetyCheckPrompt(request, toolCallID: toolCallID)
        }
    }

    /// Ends the hold and shows the prompt the usual way.
    func releaseSafetyCheckPrompt(_ request: PermissionRequest, toolCallID: String?) {
        dropSafetyCheckPrompt(request, toolCallID: toolCallID)
        guard let session = byID[request.sessionID], session.resolutions[request.id] == nil else { return }
        apply(.permissionAsked(request))
    }

    /// Ends the hold without showing anything.
    func dropSafetyCheckPrompt(_ request: PermissionRequest, toolCallID: String?) {
        let check = safetyCheck
        check.checking.remove(request.id)
        check.tasks[request.id] = nil
        check.markReleased(request.id)
        if let toolCallID { check.badges.setChecking(toolCallID, false) }
    }

    // MARK: Helpers

    func decision(_ request: PermissionRequest, query: SafetyCheckQuery, toolCallID: String?, verdict: SafetyCheckVerdict,
                  basis: SafetyCheckBasis, reason: String, model: ModelRef? = nil) -> SafetyCheckDecision {
        SafetyCheckDecision(requestID: request.id, sessionID: request.sessionID, toolCallID: toolCallID, action: query.action,
                            subject: PermissionDisplay.visible(query.subject), verdict: verdict, basis: basis, reason: reason,
                            model: model)
    }

    /// The top-level session (a subagent's parent, through any depth).
    func topLevelSession(of session: SessionModel) -> SessionModel {
        var current = session
        var hops = 0
        while let parentID = current.info.parentID, let parent = byID[parentID], hops < 16 {
            current = parent
            hops += 1
        }
        return current
    }

    /// The user's latest message in the session, cut for the check.
    func latestInstruction(in session: SessionModel) -> String {
        for item in session.items.reversed() {
            if case .user(_, let text, _) = item { return SafetyCheckClassifier.truncatedInstruction(text) }
        }
        return ""
    }

    /// What the engine asks about, one entry per line of the prompt's title (each command of the line).
    static func resources(of request: PermissionRequest) -> [String] {
        request.title.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The tool call the prompt most likely belongs to: the newest unfinished call of the matching tool whose input holds
    /// every resource. The engine's own answer (`toolCallID(forPermission:)`) replaces it when it comes.
    func matchingTool(for request: PermissionRequest, in session: SessionModel) -> ToolCallInfo? {
        let resources = Self.resources(of: request)
        let names: Set<String> = switch request.kind {
        case "shell", "bash": ["shell", "bash"]
        case "edit", "write", "patch": ["edit", "write", "patch", "apply_patch", "multiedit"]
        default: [request.kind]
        }
        for item in session.items.reversed() {
            guard case .tool(let tool) = item, names.contains(tool.name.lowercased()),
                  tool.status == .pending || tool.status == .running else { continue }
            let text = Self.command(of: tool) ?? tool.title
            if resources.allSatisfy({ text.contains($0) }) { return tool }
        }
        return nil
    }

    func tool(withID id: String, in session: SessionModel) -> ToolCallInfo? {
        for item in session.items.reversed() {
            if case .tool(let tool) = item, tool.id == id { return tool }
        }
        return nil
    }

    static let unidentified = "Could not identify the exact command"

    /// What an exactly identified call does: a shell call's command from its input, or the address of a fetch. Nil when
    /// the input does not say (the prompt then asks).
    static func exactCommand(of tool: ToolCallInfo, action: String) -> String? {
        guard let data = tool.inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let key = action == "webfetch" ? "url" : "command"
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// A shell call's whole command line from its input, else its title.
    static func command(of tool: ToolCallInfo) -> String? {
        if let data = tool.inputJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let command = object["command"] as? String, !command.isEmpty {
            return command
        }
        return tool.title.isEmpty || tool.title == tool.name ? nil : tool.title
    }

    static func isMissingPrompt(_ error: Error) -> Bool {
        if case OpenCodeError.http(let status, _, _) = error { return status == 404 }
        return false
    }

    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let rounded = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return rounded == "1" ? "1 second" : "\(rounded) seconds"
    }
}
