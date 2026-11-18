import Foundation

// Goal mode for rooms (`GoalModels.swift`). One turn toward a room's goal is one run. When a run finishes, the lead (or
// the only agent left) gets a check turn: check the goal with evidence and answer GOAL MET or GOAL NOT MET: <why>. Not
// met: the room posts why and starts the next run in the same mode with the reason, until the goal is met, the run or
// cost budget is used up, or the user stops the goal or the room. Decisions and permission prompts hold a run until the
// user answers, so the goal waits with it; spending caps pause the room as usual, and the goal carries on after Resume.

extension RoomEngine {
    /// Why a goal cannot be set in this room now, or nil.
    public var goalUnavailableReason: String? {
        if state.runMode == .debate && state.spec.mode == .debate {
            return "Goal mode needs a room that builds: Team, Round table or Solo."
        }
        if activeAgentIDs.isEmpty { return "Every agent has reached its spending cap." }
        return nil
    }

    /// Sets the room's goal. With no run going, it starts one with the goal as the task; otherwise the current run is
    /// the first turn and the goal is checked when it finishes. Replaces an active goal.
    public func setGoal(_ condition: String, budget: GoalBudget = .standard) async {
        let condition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condition.isEmpty else { return }
        if let reason = goalUnavailableReason {
            lastError = reason
            return
        }
        if var old = state.goal, old.isActive {
            _ = GoalDriver.stop(&old, note: "Replaced by a new goal")
            update { $0.goal = old }
        }
        let (run, _) = GoalDriver.start(condition: condition, budget: budget, costNow: state.totalUsage.costUSD, unit: "run")
        update { $0.goal = run }
        notice("Goal set: \(condition). " + Self.goalBudgetText(budget))
        if !state.phase.isRunActive && !state.isPaused {
            await startRun(task: goalTask(run, reason: nil), mode: goalMode, fromUser: true)
        }
    }

    /// Stops the goal. A run that is going carries on; nothing more starts for the goal.
    public func stopGoal() {
        guard var goal = state.goal, goal.isActive else { return }
        let line = GoalDriver.stop(&goal)
        update {
            $0.goal = goal
            if $0.phase == .checkingGoal {
                for (id, duties) in $0.duties {
                    let left = duties.filter { $0.purpose != .goalCheck }
                    $0.duties[id] = left.isEmpty ? nil : left
                }
                $0.phase = .finished
            }
        }
        if let line { notice(line) }
    }

    /// Takes an ended goal off the header.
    public func clearGoal() {
        guard let goal = state.goal, !goal.isActive else { return }
        update { $0.goal = nil }
    }

    /// `/goal <arguments>` typed in the room's composer.
    public func runGoalCommand(_ arguments: String) async {
        switch GoalCommand.parse(arguments) {
        case .show:
            if let goal = state.goal, goal.isActive {
                notice("Goal: \(goal.condition). \(goal.statusLine). Type /goal stop to stop it.")
            } else {
                notice("No goal is set. Type /goal and a condition, for example /goal all tests pass.")
            }
        case .stop:
            if state.goal?.isActive == true { stopGoal() } else { notice("No goal is running.") }
        case .set(let condition, let budget):
            await setGoal(condition, budget: budget)
        }
    }

    static func goalBudgetText(_ budget: GoalBudget) -> String {
        let runs = "Up to \(budget.maxTurns) \(budget.maxTurns == 1 ? "run" : "runs")"
        if let cost = budget.maxCostUSD { return runs + " or \(Format.usd(cost))." }
        return runs + "."
    }

    /// The mode goal runs use: the room's current run mode.
    var goalMode: RoomMode { state.runMode == .debate ? (state.spec.mode == .debate ? .team : state.spec.mode) : state.runMode }

    /// The agent that checks the goal: the lead, else the first agent that can still take turns.
    var goalCheckerID: UUID? { activeLeadID ?? activeAgentIDs.first }

    /// The task of a goal run.
    func goalTask(_ goal: GoalRun, reason: String?) -> String {
        guard let reason else { return "Goal: \(goal.condition)" }
        return "Goal: \(goal.condition)\nNot met yet: \(reason)\nKeep working until the goal is met."
    }

    func goalCheckText(_ goal: GoalRun) -> String {
        "[Room] Goal check after run \(goal.turns) of \(goal.budget.maxTurns). Is this goal met: \(goal.condition)\n\n"
            + "Check it with evidence (run the tests, read the files) and change nothing. "
            + "End your reply with one line: GOAL MET, or GOAL NOT MET: followed by why."
    }

    // MARK: Following runs

    /// Called on every phase change (`update`).
    func phaseChanged(from old: RoomPhase) {
        guard var goal = state.goal, goal.isActive else { return }
        switch state.phase {
        case .finished where old != .checkingGoal:
            Task { [weak self] in await self?.goalRunFinished() }
        case .stopped:
            let line = GoalDriver.stop(&goal, note: "Stopped with the room")
            update { $0.goal = goal }
            if line != nil { notice("Goal stopped with the room.") }
        case let phase where phase.isRunning && phase != .checkingGoal && goal.status == .waiting:
            // A run started after the goal waited (after a relaunch): it counts toward the goal.
            GoalDriver.resume(&goal)
            update { $0.goal = goal }
        default:
            break
        }
    }

    /// A run finished while the goal is active: ask for the check.
    func goalRunFinished() async {
        guard var goal = state.goal, goal.isActive, state.phase == .finished, !state.isPaused else { return }
        goal.costSpent = max(0, state.totalUsage.costUSD - goal.costAtStart)
        if let cap = goal.budget.maxCostUSD, goal.costSpent >= cap {
            // No check turn once the money is spent.
            let action = GoalDriver.afterTurn(&goal, GoalTurn(reply: "GOAL NOT MET: the cost budget is used up.",
                                                              costNow: state.totalUsage.costUSD, wasCheck: true))
            update { $0.goal = goal }
            if case .finish(let line) = action { notice(line) }
            return
        }
        guard let checker = goalCheckerID else {
            let line = GoalDriver.block(&goal, reason: "No agent is left to check the goal")
            update { $0.goal = goal }
            if let line { notice(line) }
            return
        }
        goal.checks += 1
        goal.status = .checking
        goal.note = nil
        update {
            $0.goal = goal
            $0.phase = .checkingGoal
        }
        notice("\(name(checker)) checks the goal.")
        await deliver(checker, OutgoingMessage(channel: .synthetic, text: goalCheckText(goal), duty: .goalCheck))
    }

    /// The check turn's answer.
    func goalChecked(_ id: UUID, text: String) async {
        guard var goal = state.goal, goal.isActive else {
            if state.phase == .checkingGoal { update { $0.phase = .finished } }
            return
        }
        let action = GoalDriver.afterTurn(&goal, GoalTurn(reply: text, costNow: state.totalUsage.costUSD, wasCheck: true))
        switch action {
        case .finish(let line):
            update {
                $0.goal = goal
                $0.phase = .finished
            }
            notice(line)
        case .send, .check:
            update { $0.goal = goal }
            let reason = goal.lastReason ?? "no reason given"
            notice("Goal not met yet: \(reason). Run \(goal.turns) of \(goal.budget.maxTurns) starts.")
            await startRun(task: goalTask(goal, reason: reason), mode: goalMode, fromUser: false)
        case .wait:
            update {
                $0.goal = goal
                $0.phase = .finished
            }
        }
    }
}
