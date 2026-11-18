import Foundation

/// Every text the room sends to agents. Room messages start with `[Room]`; relays use
/// `[Room] <Name> (<model>) to you: <text>`.
extension RoomEngine {
    func relayLine(from id: UUID, text: String) -> String {
        "[Room] \(label(id)) to you: \(text)"
    }

    // MARK: Briefing

    func modeDescription(_ mode: RoomMode) -> String {
        switch mode {
        case .solo:
            "You work with the user like a normal chat."
        case .team:
            "The lead writes a plan and gives every agent a piece. Everyone builds at the same time, another agent reviews each piece, then the lead merges and sums up."
        case .debate:
            "Everyone answers the user's question in rounds, reads the others' arguments, and agrees or pushes back. Then the judge writes the verdict. Do not edit files."
        case .roundTable:
            "Agents take turns refining one plan until everyone agrees. Then one agent builds while the others review each step and can take over."
        }
    }

    func keywordLines(_ mode: RoomMode) -> [String] {
        switch mode {
        case .solo:
            []
        case .team:
            [
                "- PLAN: the plan (lead only)",
                "- ASSIGN @Name: what that agent builds (lead only, one line per agent, the lead too)",
                "- DONE when your piece is finished",
                "- APPROVE when a piece you review is good",
                "- CHANGES: what to change, when it is not",
            ]
        case .debate:
            ["- VERDICT: the decision (judge only)"]
        case .roundTable:
            [
                "- AGREE when you agree with the plan as it stands",
                "- DONE when you are the builder and the whole plan is built",
                "- APPROVE, CHANGES: what to change, or TAKEOVER when you review a build step",
            ]
        }
    }

    func briefingText(for me: AgentSpec) -> String {
        let spec = state.spec
        let count = spec.agents.count
        var lines: [String] = []
        lines.append("[Room] You are \(me.name), \(count == 1 ? "the only agent" : "one of \(count) agents") in an Ensemble room working in \(spec.directory).")
        lines.append("Mode: \(spec.mode.label). \(modeDescription(spec.mode))")
        lines.append("Your role: \(me.role.isEmpty ? "teammate" : me.role).")
        if count > 1 {
            if let lead = leadID {
                lines.append(lead == me.id ? "You are the lead: you coordinate, and you also do real work." : "The lead is \(name(lead)).")
            } else {
                lines.append("The user leads this room.")
            }
            lines.append("")
            lines.append("Agents in the room:")
            for a in spec.agents {
                let lead = a.id == leadID ? ", lead" : ""
                let role = a.role.isEmpty ? "" : ": \(a.role)"
                lines.append("- \(a.name) (\(a.model.description))\(lead)\(role)")
            }
            lines.append("")
            let audience = leadID == me.id || leadID == nil ? "the user" : "the user and the lead"
            lines.append("To message another agent, start a line with @Name, or @all for everyone. The room delivers it. Everything else goes to the room board for \(audience).")
        }
        let keywords = keywordLines(spec.mode)
        if !keywords.isEmpty {
            lines.append("")
            lines.append("Room keywords, each at the start of its own line:")
            lines.append(contentsOf: keywords)
        }
        if count > 1 {
            lines.append("")
            if spec.mode == .debate {
                lines.append("Do not edit files during the debate.")
            } else {
                lines.append("File ownership: edit only the files your assignment gives you. Ask the owner with an @Name line before touching anyone else's files.")
            }
            lines.append("Keep room messages short; do the real work in your own session.")
        }
        lines.append("Wait for the room to give you a task.")
        return lines.joined(separator: "\n")
    }

    func modeSwitchText(_ mode: RoomMode) -> String {
        var lines = ["[Room] The room switched to \(mode.label) mode. \(modeDescription(mode))"]
        let keywords = keywordLines(mode)
        if !keywords.isEmpty {
            lines.append("Room keywords, each at the start of its own line:")
            lines.append(contentsOf: keywords)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Team

    func planRequestText(task: String) -> String {
        let names = activeAgentIDs.map { name($0) }.joined(separator: ", ")
        return """
        [Room] Task for the room:
        \(task)

        You are the lead. Do not edit files yet. Reply with a line starting PLAN: and a short plan, then one line per agent, yourself included:
        ASSIGN @Name: what that agent builds, and which files it owns.
        Every agent needs real work or a review duty. Agents: \(names).
        """
    }

    func redoPlanText(feedback: String) -> String {
        let note = feedback.isEmpty ? "" : " Their feedback: \(feedback)"
        return "[Room] The user wants a different plan.\(note)\nReply with PLAN: and one ASSIGN @Name: line per agent again."
    }

    func workText(for a: Assignment) -> String {
        var lines = ["[Room] The plan is approved. Start your piece now.", "", "Plan:", state.plan ?? "", "", "Your assignment: \(a.task)"]
        if let path = a.worktreePath, let branch = a.branch {
            lines.append("Work only in your own git worktree: \(path) (branch \(branch)). Do not edit files outside it.")
        } else if activeAgentIDs.count > 1 {
            lines.append("Everyone works in \(state.spec.directory). Edit only the files your assignment gives you.")
        }
        if let lead = leadID, lead != a.agentID {
            lines.append("Message others with @Name lines; questions usually go to \(name(lead)).")
        } else if leadID == nil {
            lines.append("Message others with @Name lines. The user leads; questions for the user go on the board.")
        } else if activeAgentIDs.count > 1 {
            lines.append("You are the lead: answer the others' questions with @Name lines.")
        }
        lines.append("Reply DONE on its own line when your piece is finished.")
        return lines.joined(separator: "\n")
    }

    func noPieceText() -> String {
        "[Room] The plan is approved. You have no build piece this time; the room will ask you to review the others' pieces.\n\nPlan:\n\(state.plan ?? "")"
    }

    func reviewText(for a: Assignment) -> String {
        var lines = ["[Room] Please review \(label(a.agentID))'s piece.", "Assignment: \(a.task)"]
        lines.append("Changed files: \(a.changedFiles.isEmpty ? "none reported" : a.changedFiles.joined(separator: ", "))")
        if let path = a.worktreePath { lines.append("Their worktree: \(path)") }
        lines.append("Read the changes, then reply APPROVE on its own line, or CHANGES: followed by what to change.")
        return lines.joined(separator: "\n")
    }

    func fixText(from reviewer: UUID, changes: String) -> String {
        relayLine(from: reviewer, text: "CHANGES: \(changes)") + "\n\nFix these, then reply DONE on its own line when your piece is finished."
    }

    func conflictText(branch: String, base: String, files: [String], message: String) -> String {
        let what = files.isEmpty
            ? "failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            : "stopped with conflicts in: \(files.joined(separator: ", "))"
        return "[Room] Merging \(branch) into \(base) \(what).\nResolve it in \(state.spec.directory) (the base worktree, on \(base)), commit the merge, and reply DONE on its own line."
    }

    func summaryRequestText() -> String {
        let merged = state.git?.isRepository == true && state.assignments.contains { $0.status == .merged }
        let base = state.git?.baseBranch ?? "the base branch"
        var lines = ["[Room] Every piece is reviewed\(merged ? " and merged into \(base)" : ""). Post a short summary for the user: what was built, who did what, and anything left.", "Pieces:"]
        for a in state.assignments {
            lines.append("- \(name(a.agentID)): \(Self.firstLine(a.task)) (\(a.status.label.lowercased()))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Debate

    func debateOpeningText(question: String, rounds: Int) -> String {
        """
        [Room] Debate question from the user:
        \(question)

        Round 1 of \(rounds). Give your position and your reasons. Do not edit files. Keep it short.
        """
    }

    func debateRoundText(for id: UUID, round: Int) -> String {
        let debate = state.debate
        var lines = ["[Room] Round \(round) of \(debate?.totalRounds ?? round). The others' latest arguments:", ""]
        for other in agents.map(\.id) where other != id {
            guard let latest = debate?.arguments.last(where: { $0.agentID == other }) else { continue }
            lines.append("\(label(other)):")
            lines.append(latest.text)
            lines.append("")
        }
        lines.append("Answer them: agree where they are right, push back where they are wrong, and update or defend your position. Keep it short.")
        return lines.joined(separator: "\n")
    }

    func judgeText() -> String {
        guard let debate = state.debate else { return "[Room] Write the verdict." }
        var lines = ["[Room] The debate is over. You are the judge.", "", "Question: \(debate.question)", ""]
        for round in 1...max(1, debate.totalRounds) {
            let args = debate.arguments(inRound: round)
            guard !args.isEmpty else { continue }
            lines.append("Round \(round)")
            for arg in args {
                lines.append("\(label(arg.agentID)): \(arg.text)")
            }
            lines.append("")
        }
        lines.append("Reply with a line starting VERDICT: and the decision, then the reasons, then the strongest dissent.")
        return lines.joined(separator: "\n")
    }

    func buildTaskText(question: String, verdict: String) -> String {
        "Build what the debate decided.\n\nQuestion: \(question)\n\nVerdict:\n\(verdict)"
    }

    // MARK: Round table

    func roundTableTaskText(task: String, first: UUID) -> String {
        "[Room] Task for the room:\n\(task)\n\nRound table: agents take turns refining one plan, \(name(first)) first. Wait for your turn."
    }

    func roundTableOpenText(task: String, maxRounds: Int) -> String {
        "[Room] Task for the room:\n\(task)\n\nRound table, round 1 of \(maxRounds). You speak first: propose a plan. The others refine it in turn. When you agree with the plan as it stands, reply AGREE on its own line."
    }

    func roundTableTurnText(round: Int, maxRounds: Int) -> String {
        "[Room] Your turn (round \(round) of \(maxRounds)). Everything said so far is above. Refine the plan, or reply AGREE on its own line if you agree with it as it stands."
    }

    func buildText(plan: String) -> String {
        "[Room] The plan is agreed. You build it; the others review each step.\n\nPlan:\n\(plan)\n\nBuild a step, then report what you changed. Reply DONE on its own line when the whole plan is built."
    }

    func roundTableReviewText(builder: UUID, update: String, files: [String]) -> String {
        var lines = ["[Room] Review this build step by \(label(builder)).", "Their update:", update.isEmpty ? "(no update text)" : update]
        lines.append("Changed files so far: \(files.isEmpty ? "none reported" : files.joined(separator: ", "))")
        lines.append("Reply APPROVE, CHANGES: followed by what to change, or TAKEOVER if you should take over building.")
        return lines.joined(separator: "\n")
    }

    func roundTableChangesText(_ changes: [String]) -> String {
        "[Room] Reviewers asked for changes:\n" + changes.joined(separator: "\n")
            + "\n\nMake them, report what you changed, and reply DONE on its own line when the whole plan is built."
    }

    func roundTableContinueText() -> String {
        "[Room] Every reviewer approved this step. Keep building, report what you changed, and reply DONE on its own line when the whole plan is built."
    }

    func handoffText(from old: UUID?, plan: String?, progress: String?) -> String {
        let from = old.map { name($0) } ?? "the last builder"
        return """
        [Room] You are now the builder, taking over from \(from).

        Plan:
        \(plan ?? state.task ?? "")

        Progress so far (from \(from)):
        \(progress?.isEmpty == false ? progress! : "(no progress reported)")

        Continue building, report what you changed, and reply DONE on its own line when the whole plan is built.
        """
    }

    // MARK: Format retries and fallbacks

    func retryText(_ purpose: TurnPurpose) -> String {
        switch purpose {
        case .plan:
            "[Room] Please restate your plan in the room format: a line starting PLAN: with the plan, then one line per agent, yourself included: ASSIGN @Name: task."
        case .work:
            "[Room] Reply DONE on its own line when your piece is finished. If you are blocked, say what you need in an @Name line."
        case .review:
            "[Room] Please give your review in the room format: APPROVE on its own line, or CHANGES: followed by what to change."
        case .resolveConflict:
            "[Room] Reply DONE on its own line once the merge is resolved and committed."
        case .verdict:
            "[Room] Please restate your decision in the room format: a line starting VERDICT: with the decision, then the reasons and the strongest dissent."
        case .roundTableReview:
            "[Room] Please reply APPROVE, CHANGES: followed by what to change, or TAKEOVER."
        case .goalCheck:
            "[Room] Please answer the goal check with one line: GOAL MET, or GOAL NOT MET: followed by why."
        case .chat, .solo, .summary, .argue, .propose, .build:
            "[Room] Your last reply was empty. Please answer again."
        }
    }

    func resumeText() -> String {
        "[Room] The room resumed. Carry on with what you were doing, and reply in the room format when you are done."
    }

    func fallbackNotice(_ purpose: TurnPurpose, agent id: UUID) -> String? {
        let who = name(id)
        switch purpose {
        case .work: return "\(who) did not reply DONE, so the room treats the end of its turn as DONE."
        case .review, .roundTableReview: return "\(who) did not give a review in the room format, so the room counts it as APPROVE."
        case .resolveConflict: return "\(who) did not reply DONE, so the room treats the merge as resolved."
        case .verdict: return "\(who) did not write VERDICT:, so its whole reply is the verdict."
        case .argue(let round): return "\(who) gave no argument in round \(round)."
        case .propose: return "\(who) passed its turn."
        case .build: return "\(who) sent an empty build update."
        case .summary: return "\(who) sent no summary."
        case .goalCheck: return "\(who) did not answer the goal check, so the room counts the goal as not met."
        case .plan, .chat, .solo: return nil
        }
    }
}
