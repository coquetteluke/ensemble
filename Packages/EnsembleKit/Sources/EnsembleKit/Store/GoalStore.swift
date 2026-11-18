import Foundation
import Observation

/// Goals of sessions (`GoalModels.swift`). Kept in memory like auto-continue: a goal does not survive quitting the app.
@Observable @MainActor
public final class SessionGoals {
    /// The current or last goal of each session. An ended goal stays until a new one replaces it or it is cleared.
    public internal(set) var runs: [String: GoalRun] = [:]
    /// How long a finished turn stays finished before the next goal turn goes out, like the message queue's wait: an
    /// engine can end one turn and start a queued one in the same breath.
    @ObservationIgnored public var settleDelay: Duration = .milliseconds(300)
    @ObservationIgnored var pending: [String: Task<Void, Never>] = [:]

    public init() {}
}

extension SessionStore {
    /// The session's current or last goal.
    public func goal(for sessionID: String) -> GoalRun? { goals.runs[sessionID] }

    /// Why a goal cannot be set in this session now, or nil.
    public func goalUnavailableReason(_ sessionID: String) -> String? {
        guard let session = byID[sessionID] else { return "This session is gone" }
        if session.isSubagent { return "Goals run in top-level sessions, not subagents" }
        if session.isWorking { return "Wait for the agent to finish, or stop it, before setting a goal" }
        return nil
    }

    /// Sets a goal and sends its first turn. Replaces an active goal. Returns false (with a notice in the transcript)
    /// when the goal could not be set.
    @discardableResult
    public func setGoal(_ condition: String, budget: GoalBudget = .standard, for sessionID: String) async -> Bool {
        let condition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condition.isEmpty, let session = byID[sessionID] else { return false }
        if let reason = goalUnavailableReason(sessionID) {
            addNotice(reason, to: sessionID)
            return false
        }
        if let refusal = spendingCapRefusal(for: sessionID) {
            addNotice("Goal not set. " + refusal.message, to: sessionID)
            return false
        }
        goals.pending.removeValue(forKey: sessionID)?.cancel()
        if var old = goals.runs[sessionID], old.isActive {
            _ = GoalDriver.stop(&old, note: "Replaced by a new goal")
            goals.runs[sessionID] = old
        }
        let (run, text) = GoalDriver.start(condition: condition, budget: budget, costNow: session.usage.costUSD)
        goals.runs[sessionID] = run
        addNotice("Goal set: \(condition). " + Self.goalBudgetText(budget), to: sessionID)
        await send(text, to: sessionID)
        return true
    }

    /// Stops the session's goal. The agent's current turn carries on; nothing more is sent for the goal.
    public func stopGoal(for sessionID: String) {
        goals.pending.removeValue(forKey: sessionID)?.cancel()
        guard var run = goals.runs[sessionID], run.isActive else { return }
        let line = GoalDriver.stop(&run)
        goals.runs[sessionID] = run
        if let line { addNotice(line, to: sessionID) }
    }

    /// Takes an ended goal off the indicator.
    public func clearGoal(for sessionID: String) {
        guard let run = goals.runs[sessionID], !run.isActive else { return }
        goals.runs[sessionID] = nil
    }

    /// `/goal <arguments>`: sets, stops or describes the session's goal.
    public func runGoalCommand(_ arguments: String, in sessionID: String) {
        switch GoalCommand.parse(arguments) {
        case .show:
            if let run = goals.runs[sessionID], run.isActive {
                addNotice("Goal: \(run.condition). \(run.statusLine). Type /goal stop to stop it.", to: sessionID)
            } else {
                addNotice("No goal is set. Type /goal and a condition, for example /goal all tests pass.", to: sessionID)
            }
        case .stop:
            if goals.runs[sessionID]?.isActive == true {
                stopGoal(for: sessionID)
            } else {
                addNotice("No goal is running", to: sessionID)
            }
        case .set(let condition, let budget):
            Task { await setGoal(condition, budget: budget, for: sessionID) }
        }
    }

    /// "Up to 10 turns." or "Up to 10 turns or $2.00."
    static func goalBudgetText(_ budget: GoalBudget) -> String {
        let turns = "Up to \(budget.maxTurns) \(budget.maxTurns == 1 ? "turn" : "turns")"
        if let cost = budget.maxCostUSD { return turns + " or \(Format.usd(cost))." }
        return turns + "."
    }

    // MARK: Following turns

    func goalDidApply(_ event: EngineEvent) {
        switch event {
        case .executionEnded(let sessionID, let outcome, let error):
            guard var run = goals.runs[sessionID], run.isActive, let session = byID[sessionID], !session.isSubagent else { return }
            let ending: GoalTurn.Ending
            if outcome == "interrupted" {
                ending = .interrupted
            } else if outcome == "failed" || error?.isEmpty == false {
                let message = error ?? ""
                ending = .failed(message: message, planLimit: UsageLimitText.isUsageLimit(message))
            } else {
                ending = .completed
            }
            let turn = GoalTurn(reply: Self.lastReply(session.items), ending: ending, costNow: session.usage.costUSD,
                                userPending: !session.pendingPermissions.isEmpty || !(queues[sessionID] ?? []).isEmpty,
                                wasCheck: run.status == .checking)
            let action = GoalDriver.afterTurn(&run, turn)
            goals.runs[sessionID] = run
            switch action {
            case .send(let text), .check(let text):
                scheduleGoalTurn(text, to: sessionID, goalID: run.id)
            case .wait:
                break
            case .finish(let line):
                addNotice(line, to: sessionID)
            }
        case .activity(let sessionID, let activity) where activity == .working:
            // The user answered (or auto-continue sent "Continue" after a plan limit): that turn counts toward the goal.
            if var run = goals.runs[sessionID], run.status == .waiting {
                GoalDriver.resume(&run)
                goals.runs[sessionID] = run
            }
        case .sessionDeleted(let sessionID):
            goals.pending.removeValue(forKey: sessionID)?.cancel()
            goals.runs[sessionID] = nil
        default:
            break
        }
    }

    /// Sends the next goal turn once the finished turn has settled, unless the user started one meanwhile, the goal
    /// ended, or the provider's spending cap refuses it.
    func scheduleGoalTurn(_ text: String, to sessionID: String, goalID: UUID) {
        goals.pending.removeValue(forKey: sessionID)?.cancel()
        let delay = goals.settleDelay
        goals.pending[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.goals.pending[sessionID] = nil
            guard var run = self.goals.runs[sessionID], run.id == goalID, run.isActive, let session = self.byID[sessionID] else { return }
            if session.isWorking || !(self.queues[sessionID] ?? []).isEmpty {
                // Something else started a turn; its end is checked like any goal turn.
                if run.status == .checking {
                    run.status = .working
                    self.goals.runs[sessionID] = run
                }
                return
            }
            if let refusal = self.spendingCapRefusal(for: sessionID) {
                let line = GoalDriver.block(&run, reason: refusal.message)
                self.goals.runs[sessionID] = run
                if let line { self.addNotice(line, to: sessionID) }
                return
            }
            await self.send(text, to: sessionID)
        }
    }

    /// The agent's text since the last user message.
    static func lastReply(_ items: [TranscriptItem]) -> String {
        var parts: [String] = []
        for item in items.reversed() {
            switch item {
            case .agentText(_, let text, _, _): parts.insert(text, at: 0)
            case .user: return join(parts)
            default: continue
            }
        }
        return join(parts)
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
