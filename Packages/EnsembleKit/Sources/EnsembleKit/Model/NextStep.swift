import Foundation

/// The card under a finished turn: what the turn changed, what the agent asked last, and one to three things to do
/// next. Worked out from the transcript alone, so it costs no model request and works with every engine.
public struct NextStep: Equatable, Sendable {
    /// What the turn did to files and how many commands it ran.
    public struct Work: Equatable, Sendable {
        public var filesChanged = 0
        public var additions = 0
        public var deletions = 0
        public var commands = 0
        public var failedSteps = 0
        /// One of the changed files, by name, for the recap.
        public var firstFile: String?

        public init(filesChanged: Int = 0, additions: Int = 0, deletions: Int = 0, commands: Int = 0, failedSteps: Int = 0,
                    firstFile: String? = nil) {
            self.filesChanged = filesChanged
            self.additions = additions
            self.deletions = deletions
            self.commands = commands
            self.failedSteps = failedSteps
            self.firstFile = firstFile
        }

        public var isEmpty: Bool { filesChanged == 0 && commands == 0 }
    }

    /// The user message the turn answers; the card belongs to this turn, and dismissing it is remembered by this id.
    public var turnID: String
    public var work: Work
    /// One line on what the turn did; empty when it only talked.
    public var recap: String
    /// The agent's closing question on one line; nil when it asked nothing.
    public var question: String?
    /// Replies first, then the app's own actions. The first is the suggested one.
    public var actions: [NextStepAction]

    public init(turnID: String, work: Work, recap: String, question: String?, actions: [NextStepAction]) {
        self.turnID = turnID
        self.work = work
        self.recap = recap
        self.question = question
        self.actions = actions
    }
}

public enum NextStepAction: String, CaseIterable, Sendable, Identifiable {
    case replyYes
    case replyNo
    case reviewChanges

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .replyYes: "Yes"
        case .replyNo: "No"
        case .reviewChanges: "Review changes"
        }
    }

    /// The message a reply sends; nil for the app's own actions.
    public var reply: String? {
        switch self {
        case .replyYes: "Yes"
        case .replyNo: "No"
        case .reviewChanges: nil
        }
    }
}

public enum NextStepBuilder {
    /// The card for the newest turn, or nil when there is nothing worth a card: the agent is still working, a
    /// prompt is already waiting for an answer, the turn failed (the error row offers Retry), or the turn changed
    /// no file and ended without a yes-or-no question.
    public static func build(items: [TranscriptItem], isWorking: Bool, hasOpenPrompt: Bool) -> NextStep? {
        guard !isWorking, !hasOpenPrompt else { return nil }
        guard let start = items.lastIndex(where: { if case .user = $0 { true } else { false } }) else { return nil }
        let turn = items[(start + 1)...]
        guard !turn.isEmpty else { return nil }
        if case .error = turn.last { return nil }

        let work = Self.work(in: turn)
        let question = lastAgentText(in: turn).flatMap(closingQuestion)
        let yesNo = question.map(isYesOrNo) ?? false

        var actions: [NextStepAction] = []
        if yesNo { actions += [.replyYes, .replyNo] }
        if work.filesChanged > 0 { actions.append(.reviewChanges) }
        guard !actions.isEmpty else { return nil }

        return NextStep(turnID: items[start].id, work: work, recap: recap(work), question: question, actions: actions)
    }

    // MARK: Work

    static func work(in turn: ArraySlice<TranscriptItem>) -> NextStep.Work {
        var work = NextStep.Work()
        var paths: [String] = []
        for item in turn {
            guard case .tool(let tool) = item else { continue }
            if tool.status == .failed { work.failedSteps += 1 }
            switch ToolCategory(tool.name) {
            case .command:
                work.commands += 1
            case .edit, .create:
                guard tool.status != .failed else { continue }
                if !paths.contains(tool.title) { paths.append(tool.title) }
                let counts = diffCounts(tool.diff)
                work.additions += counts.additions
                work.deletions += counts.deletions
            default:
                break
            }
        }
        work.filesChanged = paths.count
        work.firstFile = paths.first.map { ($0 as NSString).lastPathComponent }
        return work
    }

    /// Added and removed lines in a unified diff (the `+++` and `---` file lines do not count).
    static func diffCounts(_ diff: String?) -> (additions: Int, deletions: Int) {
        guard let diff else { return (0, 0) }
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    /// "Changed ContextBar.swift and 2 more files (+48, -12). Ran 3 commands, 1 step failed."
    static func recap(_ work: NextStep.Work) -> String {
        var sentences: [String] = []
        if work.filesChanged > 0 {
            var text = "Changed " + (work.firstFile ?? "a file")
            if work.filesChanged == 2 { text += " and 1 more file" }
            if work.filesChanged > 2 { text += " and \(work.filesChanged - 1) more files" }
            var counts: [String] = []
            if work.additions > 0 { counts.append("+\(work.additions)") }
            if work.deletions > 0 { counts.append("-\(work.deletions)") }
            if !counts.isEmpty { text += " (" + counts.joined(separator: ", ") + ")" }
            sentences.append(text)
        }
        if work.commands > 0 {
            sentences.append(work.commands == 1 ? "Ran a command" : "Ran \(work.commands) commands")
        }
        guard !sentences.isEmpty else { return "" }
        var text = sentences.joined(separator: ". ")
        if work.failedSteps > 0 {
            text += work.failedSteps == 1 ? ", 1 step failed" : ", \(work.failedSteps) steps failed"
        }
        return text + "."
    }

    // MARK: Question

    static func lastAgentText(in turn: ArraySlice<TranscriptItem>) -> String? {
        for item in turn.reversed() {
            if case .agentText(_, let text, _, _) = item,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// The question the text ends with, as one plain sentence; nil when its last line asks nothing.
    static func closingQuestion(_ text: String) -> String? {
        guard HubSorter.asksSomething(text) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.last else { return nil }
        // Markdown marks, list bullets and quote marks around the question.
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        while let first = line.first, "-*>#\u{2022} ".contains(first) { line.removeFirst() }
        while let last = line.last, "*_)\"\u{201D} ".contains(last) { line.removeLast() }
        // Keep the last sentence only: what follows the last full stop, exclamation mark or earlier question mark
        // that ends a sentence (one followed by a space, so "README.md" and "v2.3" stay whole).
        for mark in [". ", "! ", "? "] {
            if let range = line.range(of: mark, options: .backwards) {
                let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.count > 1, rest.count < line.count { line = rest }
            }
        }
        guard line.hasSuffix("?"), line.count > 1 else { return nil }
        return line
    }

    /// True for a question that Yes or No answers ("Should I go ahead?"), false for a choice ("A or B?") or an
    /// open question ("Which file?").
    static func isYesOrNo(_ question: String) -> Bool {
        let text = question.lowercased()
        if text.contains("yes or no") { return true }
        // A choice between named things is not a yes or no.
        if text.contains(" or "), !text.contains("or not") { return false }
        let openers = ["which ", "what ", "who ", "where ", "when ", "why ", "how "]
        // The question may follow a clause: "The tests pass. Should I commit?" was already cut to its last line.
        let lastClause = text.split(whereSeparator: { ".!;:".contains($0) }).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? text
        if openers.contains(where: { lastClause.hasPrefix($0) }) { return false }
        let starts = ["should i", "shall i", "should we", "shall we", "want me to", "do you want", "would you like",
                      "can i", "may i", "could i", "is it ok", "is that ok", "is this ok", "ok to", "okay to", "ready to",
                      "does that", "does this", "is that", "is this", "are you", "do you", "did you", "have you", "will you",
                      "go ahead", "proceed", "sound good", "sounds good", "continue"]
        return starts.contains { lastClause.hasPrefix($0) || lastClause.contains(", " + $0) || lastClause.contains(" " + $0 + " ") }
    }
}
