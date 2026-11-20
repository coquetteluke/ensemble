import Foundation

/// Team: the lead plans with PLAN: and ASSIGN lines, the plan waits for approval in Ask and Accept-edits
/// modes, everyone builds at once (each in its own git worktree when the folder is a repo), another agent
/// reviews each piece (APPROVE or CHANGES:, at most two fix rounds), approved branches are merged in
/// assignment order, and the lead sums up.
extension RoomEngine {
    var planNeedsApproval: Bool {
        state.spec.permissionMode == .ask || state.spec.permissionMode == .acceptEdits
    }

    func assignmentIndex(_ agentID: UUID) -> Int? {
        state.assignments.firstIndex { $0.agentID == agentID }
    }

    // MARK: Plan

    func startTeam(task: String) async {
        guard let lead = activeLeadID else {
            update {
                $0.phase = .awaitingApproval
                $0.pendingDecision = .writePlan
            }
            notice("You lead this room. Write the plan with one ASSIGN @Name: line per agent.")
            return
        }
        update { $0.phase = .planning }
        await deliver(lead, OutgoingMessage(channel: .synthetic, text: planRequestText(task: task), duty: .plan))
    }

    func planReady(lead: UUID, parsed: ParsedReply, text: String) async {
        guard state.phase == .planning else { return }
        await adoptPlan(parsed: parsed, text: text, author: lead)
    }

    /// Turns a parsed plan into assignments. `author` is `nil` when the user wrote or edited the plan.
    func adoptPlan(parsed: ParsedReply, text: String, author: UUID?) async {
        var list: [Assignment] = []
        var unknown: [String] = []
        for item in parsed.assignments {
            guard let id = agentID(named: item.name) else {
                unknown.append(item.name)
                continue
            }
            guard isActive(id), !list.contains(where: { $0.agentID == id }) else { continue }
            list.append(Assignment(agentID: id, task: item.task.isEmpty ? (state.task ?? "") : item.task))
        }
        if !unknown.isEmpty {
            notice("The plan names agents that are not in this room: \(unknown.joined(separator: ", ")).")
        }
        if list.isEmpty {
            guard let owner = author ?? activeLeadID ?? activeAgentIDs.first else { return }
            list = [Assignment(agentID: owner, task: state.task ?? text)]
            notice("The plan had no usable ASSIGN lines, so \(name(owner)) takes the whole task and the others review.")
        }
        let planText = parsed.plan.flatMap { $0.isEmpty ? nil : $0 } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        update {
            $0.plan = planText
            $0.assignments = list
        }
        if author != nil && planNeedsApproval {
            update {
                $0.phase = .awaitingApproval
                $0.pendingDecision = .approvePlan
            }
            notice("The plan is ready. Approve, edit or redo it.")
        } else {
            await startWork()
        }
    }

    /// Approve the lead's plan as it is.
    public func approvePlan() async {
        guard state.pendingDecision == .approvePlan else { return }
        await startWork()
    }

    /// Edit: replaces the plan with the user's text (it needs ASSIGN @Name: lines) and starts the work.
    /// Also how the user submits the plan when they lead.
    public func submitPlan(_ text: String) async {
        guard state.pendingDecision == .approvePlan || state.pendingDecision == .writePlan else { return }
        let parsed = parser.parse(text)
        guard !parsed.assignments.isEmpty else {
            lastError = "The plan needs at least one ASSIGN @Name: line."
            return
        }
        post(BoardMessage(from: .user, kind: .plan, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        update { $0.pendingDecision = nil }
        await adoptPlan(parsed: parsed, text: text, author: nil)
    }

    /// Redo: sends the plan back to the lead with the user's feedback.
    public func redoPlan(feedback: String = "") async {
        guard state.pendingDecision == .approvePlan, let lead = activeLeadID else { return }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { post(BoardMessage(from: .user, to: [lead], kind: .chat, text: note)) }
        update {
            $0.pendingDecision = nil
            $0.phase = .planning
            $0.assignments = []
            $0.plan = nil
        }
        await deliver(lead, OutgoingMessage(channel: .synthetic, text: redoPlanText(feedback: note), duty: .plan))
    }

    // MARK: Work

    func startWork() async {
        let run = state.run
        update {
            $0.pendingDecision = nil
            $0.phase = .working
        }
        await prepareWorktrees()
        guard state.run == run, !state.isPaused, state.phase == .working else { return }
        update {
            for i in $0.assignments.indices { $0.assignments[i].status = .working }
        }
        let from: BoardSender = leadID.map { .agent($0) } ?? .user
        var messages: [(UUID, OutgoingMessage)] = []
        for a in state.assignments {
            post(BoardMessage(from: from, to: [a.agentID], kind: .assignment, text: "\(name(a.agentID)): \(a.task)"))
            messages.append((a.agentID, OutgoingMessage(channel: .synthetic, text: workText(for: a), duty: .work)))
        }
        await deliverAll(messages)
        guard state.run == run, !state.isPaused, state.phase == .working else { return }
        for id in activeAgentIDs where assignmentIndex(id) == nil {
            await inform(id, noPieceText())
        }
    }

    func prepareWorktrees() async {
        let run = state.run
        guard let git else {
            update { $0.git = GitContext(isRepository: false) }
            return
        }
        let dir = state.spec.directory
        guard await git.isRepository(dir) else {
            guard state.run == run, !state.isPaused, state.phase == .working else { return }
            update { $0.git = GitContext(isRepository: false) }
            notice("Git is off for this room (the folder is not a git repository, or you have not trusted it), so the agents share the folder and each owns the files the plan gives it.")
            return
        }
        guard state.run == run, !state.isPaused, state.phase == .working else { return }
        let base: String
        do {
            base = try await git.currentBranch(repo: dir)
        } catch {
            guard state.run == run, !state.isPaused, state.phase == .working else { return }
            update { $0.git = GitContext(isRepository: false) }
            notice("Could not read the current git branch (\(error.localizedDescription)), so the agents share the folder.")
            return
        }
        guard state.run == run, !state.isPaused, state.phase == .working else { return }
        update { $0.git = GitContext(isRepository: true, baseBranch: base) }
        for a in state.assignments {
            guard state.run == run, !state.isPaused, state.phase == .working else { return }
            let branch = branchName(for: a.agentID)
            do {
                let path = try await git.createWorktree(repo: dir, branch: branch)
                guard state.run == run, !state.isPaused, state.phase == .working else { return }
                if let i = assignmentIndex(a.agentID) {
                    update {
                        $0.assignments[i].branch = branch
                        $0.assignments[i].worktreePath = path
                    }
                }
            } catch {
                guard state.run == run, !state.isPaused, state.phase == .working else { return }
                notice("Could not create a worktree for \(name(a.agentID)) (\(error.localizedDescription)), so it works in the shared folder.")
            }
        }
    }

    /// Lets the agent edit its own worktree without asking when the room's mode allows edits in the project (see
    /// `EngineWorktreeAccess`). Runs before every work message, so a mode set from the session view in between does
    /// not leave the worktree asking.
    func allowWorktreeEdits(_ agentID: UUID) async {
        guard let i = assignmentIndex(agentID), let path = state.assignments[i].worktreePath,
              let sid = state.sessions[agentID], let access = api as? any EngineWorktreeAccess else { return }
        do {
            try await access.allowWorktreeEdits(sid, worktreePath: path)
        } catch {
            lastError = "Could not let \(name(agentID)) edit its worktree without asking: \(error.localizedDescription)"
        }
    }

    /// `ensemble/<room>-<roomID>/<agent>-<agentID>`; later runs in the same room add `-<run>` to the room part.
    func branchName(for agentID: UUID) -> String {
        let roomSuffix = String(state.id.uuidString.prefix(6)).lowercased()
        let roomSlug = Self.slug(state.spec.title)
        var room = roomSlug.isEmpty ? roomSuffix : "\(roomSlug)-\(roomSuffix)"
        if state.run > 1 { room += "-\(state.run)" }
        let agentSuffix = String(agentID.uuidString.prefix(6)).lowercased()
        let agentSlug = Self.slug(name(agentID))
        let agentPart = agentSlug.isEmpty ? agentSuffix : "\(agentSlug)-\(agentSuffix)"
        return "ensemble/\(room)/\(agentPart)"
    }

    static func slug(_ text: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: Review

    func pieceDone(_ agentID: UUID) async {
        let run = state.run
        guard state.phase == .working, !state.isPaused, let initialIndex = assignmentIndex(agentID),
              [.working, .changesRequested].contains(state.assignments[initialIndex].status) else { return }
        let files = await changedFiles(for: state.assignments[initialIndex])
        guard state.run == run, state.phase == .working, !state.isPaused,
              let i = assignmentIndex(agentID),
              [.working, .changesRequested].contains(state.assignments[i].status) else { return }
        update {
            $0.assignments[i].status = .inReview
            $0.assignments[i].changedFiles = files
        }
        await requestReview(of: agentID)
    }

    func requestReview(of author: UUID) async {
        guard let i = assignmentIndex(author) else { return }
        let current = state.assignments[i].reviewerID.flatMap { isActive($0) && $0 != author ? $0 : nil }
        guard let reviewer = current ?? pickReviewer(for: author) else {
            update { $0.assignments[i].status = .approved }
            notice("No other agent can review \(name(author))'s piece, so it counts as approved.")
            await checkTeamComplete()
            return
        }
        update { $0.assignments[i].reviewerID = reviewer }
        await deliver(reviewer, OutgoingMessage(channel: .synthetic, text: reviewText(for: state.assignments[i]),
                                                duty: .review(authorID: author)))
    }

    /// Round robin: the next active agent after the author in the roster.
    func pickReviewer(for author: UUID) -> UUID? {
        let ids = agents.map(\.id)
        guard let start = ids.firstIndex(of: author), ids.count > 1 else { return nil }
        for step in 1..<ids.count {
            let candidate = ids[(start + step) % ids.count]
            if isActive(candidate) { return candidate }
        }
        return nil
    }

    func changedFiles(for a: Assignment) async -> [String] {
        if let git, let path = a.worktreePath, let base = state.git?.baseBranch,
           let files = try? await git.changedFiles(worktree: path, base: base) {
            return files
        }
        if let sid = state.sessions[a.agentID], let changes = try? await api.changedFiles(sid) {
            return changes.map(\.path)
        }
        return []
    }

    func reviewDone(reviewer: UUID, author: UUID, parsed: ParsedReply) async {
        guard let i = assignmentIndex(author), state.assignments[i].status == .inReview else { return }
        if case .changes(let what)? = parsed.reviewVerdict {
            if state.assignments[i].fixRounds >= Self.maxFixRounds {
                update {
                    $0.assignments[i].status = .changesRequested
                    $0.assignments[i].lastReview = what
                    if $0.pendingDecision == nil {
                        $0.pendingDecision = .reviewStalemate(agentID: author)
                    }
                }
                notice("\(name(reviewer)) still asks for changes to \(name(author))'s piece after \(Self.maxFixRounds) fix rounds. Approve it, ask for another round, or drop it.")
                return
            }
            update {
                $0.assignments[i].fixRounds += 1
                $0.assignments[i].status = .changesRequested
                $0.assignments[i].lastReview = what
            }
            await deliver(author, OutgoingMessage(channel: .synthetic, text: fixText(from: reviewer, changes: what), duty: .work))
        } else {
            update {
                $0.assignments[i].status = .approved
                $0.assignments[i].lastReview = nil
            }
            await inform(author, relayLine(from: reviewer, text: "APPROVE"))
            await checkTeamComplete()
        }
    }

    /// Surfaces the next assignment stuck in a review stalemate, if no decision is currently pending.
    func surfaceNextReviewStalemate() {
        guard state.phase == .working, state.pendingDecision == nil else { return }
        guard let next = state.assignments.first(where: {
            $0.status == .changesRequested && $0.fixRounds >= Self.maxFixRounds
                && !hasDuty($0.agentID, .work)
                && !(state.outbox[$0.agentID] ?? []).contains(where: { $0.duty == .work })
        }) else { return }
        update { $0.pendingDecision = .reviewStalemate(agentID: next.agentID) }
    }

    /// The user's call on a piece that still has requested changes after the fix rounds.
    public func decideReview(for author: UUID, _ decision: ReviewDecision) async {
        guard case .reviewStalemate(let waiting)? = state.pendingDecision, waiting == author,
              let i = assignmentIndex(author) else { return }
        update { $0.pendingDecision = nil }
        switch decision {
        case .approve:
            update { $0.assignments[i].status = .approved }
            notice("You approved \(name(author))'s piece.")
            surfaceNextReviewStalemate()
            await checkTeamComplete()
        case .drop:
            update { $0.assignments[i].status = .dropped }
            notice("You dropped \(name(author))'s piece.")
            surfaceNextReviewStalemate()
            await checkTeamComplete()
        case .anotherRound:
            let reviewer = state.assignments[i].reviewerID
            let changes = state.assignments[i].lastReview ?? "See the last review."
            update { $0.assignments[i].status = .changesRequested }
            let text = reviewer.map { fixText(from: $0, changes: changes) }
                ?? "[Room] CHANGES: \(changes)\n\nFix these, then reply DONE on its own line when your piece is finished."
            await deliver(author, OutgoingMessage(channel: .synthetic, text: text, duty: .work))
            surfaceNextReviewStalemate()
        }
    }

    func checkTeamComplete() async {
        guard state.phase == .working, !state.isPaused, !state.assignments.isEmpty,
              state.assignments.allSatisfy({ [.approved, .merged, .dropped].contains($0.status) }) else { return }
        update { $0.phase = .merging }
        await continueMerge()
    }

    /// Everyone idle in the work phase with nothing owed: pieces whose agent owes nothing get asked again.
    func teamStalled() async {
        await checkTeamComplete()
        guard state.phase == .working else { return }
        surfaceNextReviewStalemate()
        guard state.pendingDecision == nil else { return }
        for a in state.assignments where isActive(a.agentID) {
            switch a.status {
            case .pending, .working, .changesRequested:
                await deliver(a.agentID, OutgoingMessage(channel: .synthetic, text: retryText(.work), duty: .work))
            case .inReview:
                await requestReview(of: a.agentID)
            default:
                break
            }
        }
    }

    // MARK: Merge

    /// Merges approved branches into the base branch in assignment order. Stops at the first conflict
    /// and hands it to the lead (or the user without a lead agent).
    func continueMerge() async {
        let run = state.run
        guard state.phase == .merging, !state.isPaused else { return }
        if let git, let ctx = state.git, ctx.isRepository, let base = ctx.baseBranch {
            let approvedIDs = state.assignments.filter { $0.status == .approved }.map(\.agentID)
            for agentID in approvedIDs {
                guard state.run == run, state.phase == .merging, !state.isPaused else { return }
                guard let idx = assignmentIndex(agentID), state.assignments[idx].status == .approved else { continue }
                let a = state.assignments[idx]
                guard let branch = a.branch, let path = a.worktreePath else { continue }
                do {
                    _ = try await git.commitAll(worktree: path, message: "\(name(a.agentID)): \(Self.firstLine(a.task))")
                    guard state.run == run, state.phase == .merging, !state.isPaused else { return }
                    let result = try await git.merge(branch: branch, into: base, repo: state.spec.directory)
                    guard state.run == run, state.phase == .merging, !state.isPaused else { return }
                    if result.merged {
                        if let i = assignmentIndex(a.agentID) { update { $0.assignments[i].status = .merged } }
                        notice("Merged \(branch) into \(base).")
                    } else {
                        await mergeBlocked(a.agentID, branch: branch, base: base, files: result.conflicts, message: result.message)
                        return
                    }
                } catch {
                    guard state.run == run, state.phase == .merging, !state.isPaused else { return }
                    await mergeBlocked(a.agentID, branch: branch, base: base, files: [], message: error.localizedDescription)
                    return
                }
            }
        }
        guard state.run == run, state.phase == .merging, !state.isPaused else { return }
        await startSummary()
    }

    func mergeBlocked(_ agentID: UUID, branch: String, base: String, files: [String], message: String) async {
        let what = files.isEmpty
            ? "Merging \(branch) into \(base) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            : "Merging \(branch) into \(base) conflicts in \(files.joined(separator: ", "))"
        if let lead = activeLeadID {
            notice("\(what). \(name(lead)) resolves it.")
            await deliver(lead, OutgoingMessage(channel: .synthetic,
                                                text: conflictText(branch: branch, base: base, files: files, message: message),
                                                duty: .resolveConflict))
        } else {
            update { $0.pendingDecision = .mergeConflict(agentID: agentID, files: files) }
            notice("\(what). Resolve it in \(state.spec.directory), commit, then continue.")
        }
    }

    /// The branch being merged when a conflict stopped the merge.
    var blockedMergeAgentID: UUID? {
        state.assignments.first { $0.status == .approved && $0.branch != nil }?.agentID
    }

    func conflictResolved() async {
        let run = state.run
        guard state.phase == .merging, !state.isPaused, let agentID = blockedMergeAgentID,
              let initialIndex = assignmentIndex(agentID) else { return }
        let branch = state.assignments[initialIndex].branch
        if let git, let ctx = state.git, ctx.isRepository, let base = ctx.baseBranch, let branch {
            do {
                let status = try await git.conflictStatus(branch: branch, into: base, repo: state.spec.directory)
                guard state.run == run, state.phase == .merging, !state.isPaused else { return }
                if !status.isResolved {
                    let detail: String
                    if !status.conflicts.isEmpty {
                        detail = "Unresolved conflicts remain in \(status.conflicts.joined(separator: ", "))."
                    } else if status.mergeInProgress {
                        detail = "A git merge is still in progress and has not been committed."
                    } else {
                        detail = "\(branch) is not merged into \(base) yet."
                    }
                    update { $0.pendingDecision = .mergeConflict(agentID: agentID, files: status.conflicts) }
                    notice("\(detail) Resolve it in \(state.spec.directory), commit, then continue.")
                    return
                }
            } catch {
                guard state.run == run, state.phase == .merging, !state.isPaused else { return }
                update { $0.pendingDecision = .mergeConflict(agentID: agentID, files: []) }
                notice("Could not verify that \(branch) was merged (\(error.localizedDescription)). Check \(state.spec.directory), commit, then continue.")
                return
            }
        }
        guard state.run == run, state.phase == .merging, !state.isPaused, let i = assignmentIndex(agentID) else { return }
        update { $0.assignments[i].status = .merged }
        notice("The merge of \(state.assignments[i].branch ?? "the branch") is resolved.")
        await continueMerge()
    }

    /// The user resolved a merge conflict themselves.
    public func resolveMergeConflict() async {
        guard case .mergeConflict(let agentID, _)? = state.pendingDecision, let i = assignmentIndex(agentID) else { return }
        update {
            $0.pendingDecision = nil
            $0.assignments[i].status = .merged
        }
        await continueMerge()
    }

    // MARK: Finish

    func startSummary() async {
        guard state.phase != .stopped, !state.isPaused else { return }
        update { $0.phase = .summarizing }
        if let lead = activeLeadID {
            await deliver(lead, OutgoingMessage(channel: .synthetic, text: summaryRequestText(), duty: .summary))
        } else {
            notice(engineSummary())
            await teamFinished()
        }
    }

    func teamFinished() async {
        guard state.phase == .summarizing else { return }
        update { $0.phase = .finished }
    }

    func teamContinueWithout(_ id: UUID, openDuties: [TurnPurpose]) async {
        if state.phase == .checkingGoal || openDuties.contains(.goalCheck) {
            await reassignGoalCheck(without: id)
            return
        }
        if openDuties.contains(.plan) || (state.phase == .planning && leadID == id) {
            await pauseRoom(reason: "Paused: the lead, \(name(id)), reached its spending cap before the plan was ready.", interrupt: true)
            return
        }
        if let i = assignmentIndex(id), [.pending, .working, .changesRequested].contains(state.assignments[i].status) {
            update { $0.assignments[i].status = .dropped }
            notice("\(name(id))'s piece is dropped.")
        }
        for purpose in openDuties {
            if case .review(let author) = purpose, let i = assignmentIndex(author), state.assignments[i].status == .inReview {
                update { $0.assignments[i].reviewerID = nil }
                await requestReview(of: author)
            }
        }
        if openDuties.contains(.resolveConflict), let agentID = blockedMergeAgentID {
            update { $0.pendingDecision = .mergeConflict(agentID: agentID, files: []) }
            notice("Resolve the merge in \(state.spec.directory), commit, then continue.")
        }
        if openDuties.contains(.summary) {
            notice(engineSummary())
            await teamFinished()
        }
        await checkTeamComplete()
    }

    func engineSummary() -> String {
        let pieces = state.assignments.map { "\(name($0.agentID)): \(Self.firstLine($0.task)) (\($0.status.label.lowercased()))" }
        return "Run finished. " + (pieces.isEmpty ? "No pieces." : pieces.joined(separator: "; ") + ".")
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }
}
