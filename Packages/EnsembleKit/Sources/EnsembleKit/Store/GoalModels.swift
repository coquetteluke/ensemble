import Foundation

// Goal mode: keep a session or a room working until a stated condition is met ("all tests pass").
//
// Each turn toward the goal asks the agent to finish by checking the goal with evidence and ending its reply with one
// line, `GOAL MET` or `GOAL NOT MET: <why>`. When a reply has no such line, Ensemble asks for it in a short check turn
// on the same engine. Not met: Ensemble sends the next turn itself, with the reason, so every continuation is a visible
// message. It stops when the goal is met, when the turn or cost budget is used up, when the user stops it, and it waits
// (sends nothing) while a question or permission prompt is open or after a failed turn.
// `GoalDriver` holds the rules; sessions (`GoalStore.swift`) and rooms (`RoomEngine+Goal.swift`) feed it turns.

/// How far a goal may go before it stops on its own.
public struct GoalBudget: Codable, Hashable, Sendable {
    /// Work turns, the first one included. For a room, one turn is one run.
    public var maxTurns: Int
    /// Spend since the goal was set, in US dollars. `nil` means no cost budget.
    public var maxCostUSD: Double?

    public static let defaultTurns = 10
    public static let standard = GoalBudget()

    public init(maxTurns: Int = GoalBudget.defaultTurns, maxCostUSD: Double? = nil) {
        self.maxTurns = max(1, maxTurns)
        self.maxCostUSD = maxCostUSD.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Where a goal stands.
public enum GoalStatus: String, Codable, Hashable, Sendable {
    /// A turn toward the goal is running.
    case working
    /// The agent is checking the goal (a check turn).
    case checking
    /// Nothing is sent until the user acts: a question or prompt is open, a turn failed, or a plan limit is waiting to reset.
    case waiting
    case met
    /// The turn or cost budget is used up.
    case budgetReached
    /// The user stopped it (Stop, or stopping the agent or the room).
    case stopped
    /// Something outside the goal refused the next turn (a spending cap, no agent left to check).
    case blocked

    public var isActive: Bool { self == .working || self == .checking || self == .waiting }

    public var label: String {
        switch self {
        case .working: "Working"
        case .checking: "Checking"
        case .waiting: "Waiting"
        case .met: "Goal met"
        case .budgetReached: "Budget used up"
        case .stopped: "Stopped"
        case .blocked: "Stopped"
        }
    }
}

/// One goal: the condition, its budget and how far it got.
public struct GoalRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var condition: String
    public var budget: GoalBudget
    public var startedAt: Date
    /// Work turns sent so far, the first one included.
    public var turns: Int
    /// Check turns sent so far.
    public var checks: Int
    /// The session's or room's spend when the goal was set.
    public var costAtStart: Double
    /// Spend since the goal was set, as of the last turn.
    public var costSpent: Double
    public var status: GoalStatus
    /// The last reason the goal was not met.
    public var lastReason: String?
    /// What the agent gave as evidence when the goal was met.
    public var evidence: String?
    /// Why nothing is sent while `status` is `waiting`, or why the goal ended.
    public var note: String?
    public var endedAt: Date?
    /// What one turn is called: "turn" in a session, "run" in a room.
    public var unit: String

    public init(id: UUID = UUID(), condition: String, budget: GoalBudget = .standard, startedAt: Date = Date(),
                costAtStart: Double = 0, unit: String = "turn") {
        self.id = id
        self.unit = unit
        self.condition = condition
        self.budget = budget
        self.startedAt = startedAt
        self.turns = 0
        self.checks = 0
        self.costAtStart = costAtStart
        self.costSpent = 0
        self.status = .working
        self.lastReason = nil
        self.evidence = nil
        self.note = nil
        self.endedAt = nil
    }

    public var isActive: Bool { status.isActive }

    /// "Turn 3 of 10" ("Run 3 of 10" in a room).
    public var progressLabel: String { "\(unit.prefix(1).uppercased() + unit.dropFirst()) \(max(turns, 1)) of \(budget.maxTurns)" }

    /// "1 turn", "3 turns".
    public func count(_ n: Int) -> String { n == 1 ? "1 \(unit)" : "\(n) \(unit)s" }

    /// Turns used, 0...1.
    public var turnFraction: Double { min(1, Double(turns) / Double(max(1, budget.maxTurns))) }

    /// One line for the indicator and the phone: what the goal is doing or how it ended.
    public var statusLine: String {
        switch status {
        case .working: progressLabel
        case .checking: "Checking the goal"
        case .waiting: note ?? "Waiting on you"
        case .met: "Met after \(count(turns))"
        case .budgetReached: note ?? "Budget used up after \(count(turns))"
        case .stopped: note ?? "Stopped"
        case .blocked: note ?? "Stopped"
        }
    }
}

// MARK: - The agent's answer

/// What an agent answered about the goal.
public enum GoalVerdict: Hashable, Sendable {
    /// `GOAL MET`, with whatever followed it on the line.
    case met(String)
    /// `GOAL NOT MET: <why>`.
    case notMet(String)
    /// No answer line.
    case malformed
}

public enum GoalVerdictParser {
    /// The last line that starts with `GOAL MET` or `GOAL NOT MET` (any case, Markdown emphasis, quotes and list marks
    /// ignored). A line that only mentions the words further in ("answer GOAL MET or ...") does not count.
    public static func parse(_ text: String) -> GoalVerdict {
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let line = cleaned(String(raw))
            let upper = line.uppercased()
            if let rest = after(prefix: "GOAL NOT MET", in: line, upper: upper) {
                let why = reason(rest)
                return .notMet(why.isEmpty ? "No reason given." : why)
            }
            if let rest = after(prefix: "GOAL MET", in: line, upper: upper) {
                return .met(reason(rest))
            }
        }
        return .malformed
    }

    /// The line without list marks, quote marks, emphasis and code ticks around it.
    private static func cleaned(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for mark in ["> ", "- ", "* ", "+ "] where s.hasPrefix(mark) { s = String(s.dropFirst(mark.count)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "*_`# ").union(.whitespaces))
        return s
    }

    /// The text after `prefix` when the line starts with it as whole words.
    private static func after(prefix: String, in line: String, upper: String) -> String? {
        guard upper.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        if let next = rest.first, next.isLetter || next.isNumber { return nil }
        return String(rest)
    }

    /// The reason after the keyword: separators and stray emphasis removed.
    private static func reason(_ rest: String) -> String {
        var s = rest.trimmingCharacters(in: .whitespaces)
        while let first = s.first, ":-.,;\u{2013}\u{2014}*_`".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "*_`").union(.whitespaces))
    }
}

// MARK: - The /goal command

/// What `/goal <arguments>` asks for.
public enum GoalCommand: Hashable, Sendable {
    /// `/goal` alone: say what the goal is doing.
    case show
    /// `/goal stop`, `/goal clear` or `/goal off`.
    case stop
    /// `/goal <condition> [--turns N] [--cost N]`.
    case set(condition: String, budget: GoalBudget)

    public static func parse(_ arguments: String) -> GoalCommand {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .show }
        if ["stop", "clear", "off", "cancel"].contains(trimmed.lowercased()) { return .stop }
        var words: [String] = []
        var turns = GoalBudget.defaultTurns
        var cost: Double?
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < parts.count {
            let word = parts[i].lowercased()
            if ["--turns", "--max-turns"].contains(word), i + 1 < parts.count, let n = Int(parts[i + 1]), n > 0 {
                turns = n
                i += 2
                continue
            }
            if ["--cost", "--budget"].contains(word), i + 1 < parts.count,
               let usd = Double(parts[i + 1].replacingOccurrences(of: "$", with: "")), usd > 0 {
                cost = usd
                i += 2
                continue
            }
            words.append(parts[i])
            i += 1
        }
        let condition = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if condition.isEmpty { return .show }
        return .set(condition: condition, budget: GoalBudget(maxTurns: turns, maxCostUSD: cost))
    }
}

// MARK: - Messages

/// The words Ensemble sends for a goal. Every one starts with `[Goal]` so it reads as Ensemble's, not the user's.
public enum GoalPrompts {
    static let answerLine = "End your reply with one line: GOAL MET, or GOAL NOT MET: followed by why."

    /// The first turn.
    public static func start(_ run: GoalRun) -> String {
        "[Goal] Keep working until this goal is met: \(run.condition)\n\n"
            + "When you finish this turn, check the goal with evidence (run the tests, read the files, try it). " + answerLine
    }

    /// A turn after a "not met".
    public static func next(_ run: GoalRun, reason: String) -> String {
        "[Goal] Not met yet: \(reason)\n\nKeep working toward the goal: \(run.condition)\n"
            + "This is turn \(run.turns + 1) of \(run.budget.maxTurns). When you finish, check the goal with evidence. " + answerLine
    }

    /// A check turn, when a reply had no answer line.
    public static func check(_ run: GoalRun) -> String {
        "[Goal] Check whether this goal is met: \(run.condition)\n\n"
            + "Check it with evidence (run the tests, read the files) and change nothing. " + answerLine
    }
}

// MARK: - The rules

/// What to do after a turn.
public enum GoalAction: Hashable, Sendable {
    /// Send this work turn now.
    case send(String)
    /// Send this check turn now.
    case check(String)
    /// Send nothing until the user acts.
    case wait
    /// The goal ended; post this line.
    case finish(String)
}

/// How a turn ended, as the session or room saw it.
public struct GoalTurn: Hashable, Sendable {
    public enum Ending: Hashable, Sendable {
        case completed
        /// The user stopped the agent.
        case interrupted
        /// The turn failed; `planLimit` when the plan's usage limit stopped it (auto-continue picks it up after the reset).
        case failed(message: String, planLimit: Bool)
    }

    /// The agent's text for the turn.
    public var reply: String
    public var ending: Ending
    /// Total spend of the session or room now.
    public var costNow: Double
    /// A question or permission prompt is still open, or the user has a message waiting to go.
    public var userPending: Bool
    /// The turn was a check turn.
    public var wasCheck: Bool

    public init(reply: String, ending: Ending = .completed, costNow: Double, userPending: Bool = false, wasCheck: Bool = false) {
        self.reply = reply
        self.ending = ending
        self.costNow = costNow
        self.userPending = userPending
        self.wasCheck = wasCheck
    }
}

public enum GoalDriver {
    /// A new goal and its first message. The first turn counts toward the budget.
    public static func start(condition: String, budget: GoalBudget, costNow: Double, unit: String = "turn",
                             now: Date = Date()) -> (GoalRun, String) {
        var run = GoalRun(condition: condition.trimmingCharacters(in: .whitespacesAndNewlines), budget: budget, startedAt: now,
                          costAtStart: costNow, unit: unit)
        let text = GoalPrompts.start(run)
        run.turns = 1
        return (run, text)
    }

    /// Decides what follows a turn and updates the goal. Call only while the goal is active.
    public static func afterTurn(_ run: inout GoalRun, _ turn: GoalTurn, now: Date = Date()) -> GoalAction {
        guard run.isActive else { return .wait }
        run.costSpent = max(0, turn.costNow - run.costAtStart)
        switch turn.ending {
        case .interrupted:
            return end(&run, .stopped, note: "Stopped with the agent", line: "Goal stopped because the agent was stopped", now: now)
        case .failed(let message, let planLimit):
            run.status = .waiting
            run.note = planLimit ? "Waiting for the plan limit to reset" : "The last turn failed. Send a message to carry on."
            if !planLimit, !message.isEmpty { run.lastReason = message }
            return .wait
        case .completed:
            break
        }
        let verdict = GoalVerdictParser.parse(turn.reply)
        if case .met(let evidence) = verdict {
            run.evidence = evidence.isEmpty ? nil : evidence
            let line = evidence.isEmpty ? "Goal met: \(run.condition)" : "Goal met: \(evidence)"
            return end(&run, .met, note: nil, line: line, now: now)
        }
        if turn.userPending {
            run.status = .waiting
            run.note = "Waiting on you"
            return .wait
        }
        var reason: String
        switch verdict {
        case .notMet(let why):
            reason = why
        case .malformed where turn.wasCheck:
            reason = "The agent did not answer GOAL MET or GOAL NOT MET."
        case .malformed:
            if endsWithQuestion(turn.reply) {
                run.status = .waiting
                run.note = "Waiting on you"
                return .wait
            }
            if let stop = budgetStop(&run, now: now) { return stop }
            run.checks += 1
            run.status = .checking
            run.note = nil
            return .check(GoalPrompts.check(run))
        case .met:
            reason = ""
        }
        reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        run.lastReason = reason
        if let stop = budgetStop(&run, now: now) { return stop }
        let text = GoalPrompts.next(run, reason: reason)
        run.turns += 1
        run.status = .working
        run.note = nil
        return .send(text)
    }

    /// The user stopped the goal.
    public static func stop(_ run: inout GoalRun, note: String = "Stopped by you", now: Date = Date()) -> String? {
        // "Goal stopped: stopped by you" reads badly; the user's own stop gets its own line.
        if note == "Stopped by you", run.isActive {
            _ = end(&run, .stopped, note: note, now: now)
            return "Goal stopped by you after \(run.count(run.turns))"
        }
        guard run.isActive else { return nil }
        return lineFor(end(&run, .stopped, note: note, now: now))
    }

    /// Something refused the next turn (a spending cap, no agent to check).
    public static func block(_ run: inout GoalRun, reason: String, now: Date = Date()) -> String? {
        guard run.isActive else { return nil }
        return lineFor(end(&run, .blocked, note: reason, now: now))
    }

    /// The user (or auto-continue) started a turn while the goal waited: it counts as a work turn.
    public static func resume(_ run: inout GoalRun) {
        guard run.status == .waiting else { return }
        run.status = .working
        run.note = nil
    }

    /// Stops when the next turn would go over the turn or cost budget.
    static func budgetStop(_ run: inout GoalRun, now: Date) -> GoalAction? {
        if run.turns >= run.budget.maxTurns {
            let note = "Budget used up after \(run.count(run.turns))"
            return end(&run, .budgetReached, note: note, now: now)
        }
        if let cap = run.budget.maxCostUSD, run.costSpent >= cap {
            let note = "Cost budget used up: \(Format.usd(run.costSpent)) of \(Format.usd(cap))"
            return end(&run, .budgetReached, note: note, now: now)
        }
        return nil
    }

    private static func end(_ run: inout GoalRun, _ status: GoalStatus, note: String?, line: String? = nil, now: Date) -> GoalAction {
        run.status = status
        run.note = note
        run.endedAt = now
        if let line { return .finish(line) }
        var text = "Goal stopped. " + (note ?? "No reason given")
        if !text.hasSuffix(".") { text += "." }
        if status == .budgetReached, let reason = run.lastReason, !reason.isEmpty { text += " Last check: \(reason)" }
        return .finish(text)
    }

    private static func lineFor(_ action: GoalAction) -> String? {
        if case .finish(let line) = action { return line }
        return nil
    }

    /// True when the reply's last line asks something (the agent waits for the user).
    static func endsWithQuestion(_ text: String) -> Bool {
        let last = text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return last.hasSuffix("?")
    }
}
