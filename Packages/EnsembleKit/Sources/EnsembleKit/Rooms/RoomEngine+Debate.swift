import Foundation

/// Debate: every agent answers in parallel rounds, each round seeing the others' latest arguments,
/// then the judge (the lead, or the user when there is no lead) writes VERDICT:.
extension RoomEngine {
    /// The chosen lead judges. With no lead chosen (or the user leading), the user judges.
    var debateJudgeID: UUID? {
        guard !state.userIsLead, let lead = state.spec.leadAgentID, agent(lead) != nil else { return nil }
        return lead
    }

    func startDebate(question: String) async {
        let rounds = max(1, state.spec.debateRounds)
        let judge = debateJudgeID
        update {
            $0.phase = .debating
            $0.debate = DebateState(question: question, round: 1, totalRounds: rounds, judgeID: judge)
        }
        let text = debateOpeningText(question: question, rounds: rounds)
        await deliverAll(activeAgentIDs.map { ($0, OutgoingMessage(channel: .synthetic, text: text, duty: .argue(round: 1))) })
    }

    func argued(_ id: UUID, round: Int, text: String) async {
        guard state.phase == .debating, let debate = state.debate, debate.round == round else { return }
        let argument = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !argument.isEmpty {
            update { $0.debate?.arguments.append(DebateArgument(round: round, agentID: id, text: argument)) }
        }
        await advanceDebateIfRoundComplete()
    }

    func advanceDebateIfRoundComplete() async {
        guard state.phase == .debating, let debate = state.debate else { return }
        let round = debate.round
        let waiting = isPending {
            if case .argue(let r) = $0 { return r == round }
            return false
        }
        guard !waiting else { return }
        if round < debate.totalRounds {
            let next = round + 1
            update { $0.debate?.round = next }
            await deliverAll(activeAgentIDs.map {
                ($0, OutgoingMessage(channel: .synthetic, text: debateRoundText(for: $0, round: next), duty: .argue(round: next)))
            })
        } else {
            await startJudging()
        }
    }

    func startJudging() async {
        update { $0.phase = .judging }
        if let judge = state.debate?.judgeID, isActive(judge) {
            await deliver(judge, OutgoingMessage(channel: .synthetic, text: judgeText(), duty: .verdict))
        } else {
            update { $0.pendingDecision = .judge }
            notice("The arguments are in. Write the verdict.")
        }
    }

    func verdictReady(text: String) async {
        guard state.phase == .judging else { return }
        update {
            $0.debate?.verdict = text.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.phase = .verdict
            $0.pendingDecision = nil
        }
    }

    /// The user writes the verdict (debates without a judge agent).
    public func submitVerdict(_ text: String) async {
        guard state.phase == .judging, state.pendingDecision == .judge else { return }
        let verdict = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !verdict.isEmpty else { return }
        post(BoardMessage(from: .user, kind: .verdict, text: verdict))
        await verdictReady(text: parser.parse(verdict).verdict ?? verdict)
    }

    /// "Build it": starts a Team run (or Solo with one agent) with the verdict as the task.
    public func buildVerdict(as mode: RoomMode? = nil) async {
        guard state.phase == .verdict, let debate = state.debate, let verdict = debate.verdict else { return }
        var runMode = mode ?? (activeAgentIDs.count > 1 ? .team : .solo)
        if runMode == .debate { runMode = .team }
        notice("Building the verdict as a \(runMode.label) run.")
        await startRun(task: buildTaskText(question: debate.question, verdict: verdict), mode: runMode, fromUser: false)
    }

    /// "Debate again": the same question, from round one.
    public func debateAgain() async {
        guard let debate = state.debate, !state.phase.isRunActive else { return }
        notice("Debating again.")
        await startRun(task: debate.question, mode: .debate, fromUser: false)
    }

    func debateContinueWithout(_ id: UUID, openDuties: [TurnPurpose]) async {
        if openDuties.contains(.verdict) {
            update { $0.pendingDecision = .judge }
            notice("The judge reached its spending cap. Write the verdict.")
            return
        }
        if state.phase == .debating { await advanceDebateIfRoundComplete() }
    }
}
