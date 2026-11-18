import Foundation

/// Round table: agents take turns (lead first) on one plan until everyone says AGREE or four rounds pass
/// (then the lead's last version wins). The builder builds; after each build step the others review in
/// parallel with APPROVE, CHANGES: or TAKEOVER. It ends when the builder says DONE and every reviewer approves.
extension RoomEngine {
    var takeoverIsAutomatic: Bool {
        state.spec.permissionMode == .auto || state.spec.permissionMode == .bypass
    }

    // MARK: Discussion

    func startRoundTable(task: String) async {
        var order = activeAgentIDs
        if let lead = activeLeadID, let i = order.firstIndex(of: lead) {
            order.remove(at: i)
            order.insert(lead, at: 0)
        }
        guard let first = order.first else { return }
        update {
            $0.phase = .discussing
            $0.roundTable = RoundTableState(order: order)
        }
        for id in order.dropFirst() {
            await inform(id, roundTableTaskText(task: task, first: first))
        }
        await nextSpeaker()
    }

    func advanceSpeaker(_ rt: inout RoundTableState) {
        rt.speakerIndex += 1
        if rt.speakerIndex >= rt.order.count {
            rt.speakerIndex = 0
            rt.round += 1
        }
    }

    func nextSpeaker() async {
        guard state.phase == .discussing, var rt = state.roundTable, !rt.order.isEmpty else { return }
        var skipped = 0
        while let speaker = rt.currentSpeaker, !isActive(speaker), skipped < rt.order.count {
            advanceSpeaker(&rt)
            skipped += 1
        }
        update { $0.roundTable = rt }
        guard rt.round <= rt.maxRounds, let speaker = rt.currentSpeaker, isActive(speaker) else {
            await discussionEnded(consensus: false)
            return
        }
        let opening = rt.round == 1 && rt.speakerIndex == 0
        let text = opening
            ? roundTableOpenText(task: state.task ?? "", maxRounds: rt.maxRounds)
            : roundTableTurnText(round: rt.round, maxRounds: rt.maxRounds)
        await deliver(speaker, OutgoingMessage(channel: .synthetic, text: text, duty: .propose(round: rt.round)))
    }

    func proposed(_ id: UUID, round: Int, parsed: ParsedReply, text: String) async {
        guard state.phase == .discussing, var rt = state.roundTable, rt.currentSpeaker == id else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsed.agree {
            if !rt.agreed.contains(id) { rt.agreed.append(id) }
        } else if !words.isEmpty {
            let plan = parsed.plan.flatMap { $0.isEmpty ? nil : $0 } ?? words
            rt.plan = plan
            rt.planAuthorID = id
            rt.agreed = [id]
            rt.lastProposal[id] = plan
        }
        let active = rt.order.filter { isActive($0) }
        if rt.plan != nil, !active.isEmpty, active.allSatisfy({ rt.agreed.contains($0) }) {
            update { $0.roundTable = rt }
            await discussionEnded(consensus: true)
            return
        }
        advanceSpeaker(&rt)
        update { $0.roundTable = rt }
        if rt.round > rt.maxRounds {
            await discussionEnded(consensus: false)
        } else {
            await nextSpeaker()
        }
    }

    func discussionEnded(consensus: Bool) async {
        guard state.phase == .discussing, var rt = state.roundTable else { return }
        if consensus {
            notice("Everyone agreed on the plan.")
        } else {
            let lead = rt.order.first
            if let lead, let last = rt.lastProposal[lead] {
                rt.plan = last
                rt.planAuthorID = lead
            }
            notice("No agreement after \(rt.maxRounds) rounds, so \(lead.map { name($0) } ?? "the lead")'s last version of the plan wins.")
        }
        update {
            $0.roundTable = rt
            $0.plan = rt.plan
        }
        await startBuilding()
    }

    // MARK: Building

    func startBuilding() async {
        guard var rt = state.roundTable else { return }
        let candidates = [rt.builderID, activeLeadID, rt.order.first].compactMap { $0 }
        guard let builder = candidates.first(where: { isActive($0) }) ?? activeAgentIDs.first else {
            await pauseRoom(reason: "Paused: no agent can build.", interrupt: false)
            return
        }
        rt.builderID = builder
        rt.buildTurns = 0
        rt.builderDone = false
        rt.reviews = [:]
        update {
            $0.phase = .building
            $0.roundTable = rt
        }
        notice("\(name(builder)) builds; the others review each step.")
        await deliver(builder, OutgoingMessage(channel: .synthetic, text: buildText(plan: rt.plan ?? state.task ?? ""), duty: .build))
    }

    var roundTableReviewers: [UUID] {
        activeAgentIDs.filter { $0 != state.roundTable?.builderID }
    }

    func built(_ builder: UUID, parsed: ParsedReply, text: String) async {
        guard state.phase == .building, var rt = state.roundTable, rt.builderID == builder else { return }
        rt.buildTurns += 1
        rt.builderDone = parsed.done
        rt.lastBuildUpdate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rt.reviews = [:]
        update { $0.roundTable = rt }
        let reviewers = roundTableReviewers
        guard !reviewers.isEmpty else {
            await concludeReviewRound()
            return
        }
        var files: [String] = []
        if let sid = state.sessions[builder], let changes = try? await api.changedFiles(sid) {
            files = changes.map(\.path)
        }
        let request = roundTableReviewText(builder: builder, update: parsed.boardText, files: files)
        await deliverAll(reviewers.map { ($0, OutgoingMessage(channel: .synthetic, text: request, duty: .roundTableReview)) })
    }

    func roundTableReviewed(_ reviewer: UUID, parsed: ParsedReply) async {
        guard state.phase == .building, state.roundTable != nil else { return }
        let review: RoundTableReview
        if parsed.takeover {
            review = .takeover(parsed.boardText)
        } else if case .changes(let what)? = parsed.reviewVerdict {
            review = .changes(what)
        } else {
            review = .approve
        }
        update { $0.roundTable?.reviews[reviewer] = review }
        guard !isPending({ $0 == .roundTableReview }) else { return }
        await concludeReviewRound()
    }

    func concludeReviewRound() async {
        guard state.phase == .building, state.pendingDecision == nil, let rt = state.roundTable, let builder = rt.builderID else { return }
        guard !isPending({ $0 == .roundTableReview || $0 == .build }) else { return }
        let reviews = agents.map(\.id).compactMap { id in rt.reviews[id].map { (id, $0) } }
        if let offer = reviews.first(where: { if case .takeover = $0.1 { true } else { false } }) {
            if takeoverIsAutomatic {
                await performTakeover(to: offer.0)
            } else {
                update {
                    $0.roundTable?.pendingTakeoverID = offer.0
                    $0.pendingDecision = .takeover(agentID: offer.0)
                }
                notice("\(name(offer.0)) offers to take over building from \(name(builder)). Accept or reject.")
            }
            return
        }
        let changes = reviews.compactMap { item -> String? in
            if case .changes(let what) = item.1 { return "\(label(item.0)): CHANGES: \(what)" }
            return nil
        }
        if !changes.isEmpty {
            await deliver(builder, OutgoingMessage(channel: .synthetic, text: roundTableChangesText(changes), duty: .build))
            return
        }
        if rt.builderDone {
            update { $0.phase = .finished }
            notice("\(name(builder)) finished the build and every reviewer approved.")
            return
        }
        if rt.buildTurns >= Self.maxBuildTurns {
            update { $0.phase = .finished }
            notice("Stopped after \(Self.maxBuildTurns) build steps. Message \(name(builder)) to continue.")
            return
        }
        await deliver(builder, OutgoingMessage(channel: .synthetic, text: roundTableContinueText(), duty: .build))
    }

    func performTakeover(to newBuilder: UUID) async {
        guard var rt = state.roundTable else { return }
        let old = rt.builderID
        rt.builderID = newBuilder
        rt.pendingTakeoverID = nil
        rt.builderDone = false
        rt.reviews = [:]
        update {
            $0.roundTable = rt
            $0.pendingDecision = nil
        }
        notice("\(name(newBuilder)) takes over building from \(old.map { name($0) } ?? "the builder").")
        if let old, old != newBuilder {
            await inform(old, "[Room] \(label(newBuilder)) takes over building. You are a reviewer now.")
        }
        await deliver(newBuilder, OutgoingMessage(channel: .synthetic,
                                                  text: handoffText(from: old, plan: rt.plan, progress: rt.lastBuildUpdate),
                                                  duty: .build))
    }

    /// Accepts a reviewer's TAKEOVER offer (Ask and Accept-edits modes).
    public func acceptTakeover() async {
        guard case .takeover(let id)? = state.pendingDecision else { return }
        await performTakeover(to: id)
    }

    /// Rejects a reviewer's TAKEOVER offer; the builder carries on.
    public func rejectTakeover() async {
        guard case .takeover(let id)? = state.pendingDecision else { return }
        update {
            $0.pendingDecision = nil
            $0.roundTable?.pendingTakeoverID = nil
            $0.roundTable?.reviews[id] = .approve
        }
        let builder = state.roundTable?.builderID.map { name($0) } ?? "The builder"
        notice("Takeover rejected. \(builder) keeps building.")
        await inform(id, "[Room] The user kept \(builder) as the builder.")
        await concludeReviewRound()
    }

    func roundTableContinueWithout(_ id: UUID, openDuties: [TurnPurpose]) async {
        guard var rt = state.roundTable else { return }
        switch state.phase {
        case .discussing:
            if rt.currentSpeaker == id {
                advanceSpeaker(&rt)
                update { $0.roundTable = rt }
                if rt.round > rt.maxRounds { await discussionEnded(consensus: false) } else { await nextSpeaker() }
            } else {
                let active = rt.order.filter { isActive($0) }
                if rt.plan != nil, !active.isEmpty, active.allSatisfy({ rt.agreed.contains($0) }) {
                    await discussionEnded(consensus: true)
                }
            }
        case .building:
            if rt.builderID == id {
                if let next = roundTableReviewersAfterCap(excluding: id).first {
                    await performTakeover(to: next)
                } else {
                    await pauseRoom(reason: "Paused: no agent is left to build.", interrupt: true)
                }
            } else if openDuties.contains(.roundTableReview) {
                rt.reviews[id] = nil
                update { $0.roundTable = rt }
                if !isPending({ $0 == .roundTableReview }) { await concludeReviewRound() }
            }
        default:
            break
        }
    }

    private func roundTableReviewersAfterCap(excluding id: UUID) -> [UUID] {
        let order = state.roundTable?.order ?? agents.map(\.id)
        return order.filter { $0 != id && isActive($0) }
    }
}
