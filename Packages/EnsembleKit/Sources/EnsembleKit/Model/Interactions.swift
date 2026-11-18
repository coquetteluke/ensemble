import Foundation

// Plans and questions: agent requests that wait for the user like permission prompts do, so they travel as
// `PermissionRequest`s (with `plan` or `questions` set) and join every session's pending list. The attention system,
// the Session Hub and the iPhone pick them up without a second list.

/// `PermissionRequest.kind` values for plans and questions.
public enum InteractionKind {
    /// The agent presents a plan and waits for Proceed or Keep planning.
    public static let plan = "plan"
    /// The agent asks one or more multiple-choice questions.
    public static let question = "question"
}

public extension PermissionRequest {
    /// A plan waiting for Proceed or Keep planning.
    var isPlan: Bool { kind == InteractionKind.plan && plan != nil }
    /// Questions waiting for answers.
    var isQuestion: Bool { kind == InteractionKind.question && !(questions ?? []).isEmpty }
    /// Plans and questions are answered with their own cards, never with Allow or Reject.
    var isInteraction: Bool { isPlan || isQuestion }
}

// MARK: - Questions

/// A multiple-choice question an agent asks (Claude's AskUserQuestion, OpenCode's question tool, ACP elicitation).
public struct AgentQuestion: Codable, Hashable, Sendable, Identifiable {
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        /// What choosing it means, when the agent says.
        public var detail: String?
        /// The engine's value for the option, when it differs from the label (OpenCode values, ACP constants).
        public var value: String?

        public init(label: String, detail: String? = nil, value: String? = nil) {
            self.label = label
            self.detail = detail
            self.value = value
        }
    }

    /// The engine's key for the question: Claude uses the question text, OpenCode the form field key, ACP the
    /// schema property.
    public var id: String
    /// A very short label ("Color"), when the agent gives one.
    public var header: String?
    public var text: String
    public var options: [Option]
    /// More than one option may be chosen.
    public var multiSelect: Bool
    /// A typed answer is accepted besides the options ("Other").
    public var allowsOther: Bool

    public init(id: String, header: String? = nil, text: String, options: [Option], multiSelect: Bool = false,
                allowsOther: Bool = true) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
        self.allowsOther = allowsOther
    }

    /// `answer` reduced to what this question accepts: known option labels only (one, unless multi-select), and a
    /// typed answer only when "Other" is allowed. A typed answer replaces the choice of a single-choice question.
    /// Nil when nothing usable is left.
    public func validated(_ answer: AgentQuestionAnswer) -> AgentQuestionAnswer? {
        guard answer.questionID == id else { return nil }
        let labels = options.map(\.label)
        var selected = labels.filter { answer.selected.contains($0) }
        var other = allowsOther ? answer.other?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if other?.isEmpty == true { other = nil }
        if !multiSelect {
            if other != nil { selected = [] } else { selected = Array(selected.prefix(1)) }
        }
        let result = AgentQuestionAnswer(questionID: id, selected: selected, other: other)
        return result.isEmpty ? nil : result
    }

    /// The engine value of an option label (the label itself when the option has no separate value).
    public func value(forLabel label: String) -> String? {
        options.first { $0.label == label }.map { $0.value ?? $0.label }
    }
}

/// The user's answer to one question.
public struct AgentQuestionAnswer: Codable, Hashable, Sendable {
    public var questionID: String
    /// Labels of the chosen options.
    public var selected: [String]
    /// The typed answer ("Other"), if any.
    public var other: String?

    public init(questionID: String, selected: [String] = [], other: String? = nil) {
        self.questionID = questionID
        self.selected = selected
        self.other = other
    }

    public var isEmpty: Bool { selected.isEmpty && (other ?? "").isEmpty }

    /// What the agent reads: the chosen labels, then the typed answer, joined with ", ".
    public var text: String {
        (selected + [other].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")
    }
}

// MARK: - Plans

/// A plan the agent presents for approval before it changes anything.
public struct PlanProposal: Codable, Hashable, Sendable {
    /// The plan document, as the agent wrote it (Markdown).
    public var markdown: String
    /// Where the engine keeps the plan file, when it has one (shown for reference, never opened by Ensemble).
    public var filePath: String?
    /// The mode Proceed switches to: the mode before Plan, Accept edits when unknown. Filled in by the store.
    public var proceedMode: PermissionMode?

    public init(markdown: String, filePath: String? = nil, proceedMode: PermissionMode? = nil) {
        self.markdown = markdown
        self.filePath = filePath
        self.proceedMode = proceedMode
    }

    /// The first heading, else the first line, without Markdown marks.
    public var title: String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        let heading = lines.first { $0.hasPrefix("#") }
        var text = heading ?? lines.first ?? ""
        while let first = text.first, "#>-*+ ".contains(first) { text.removeFirst() }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return text.isEmpty ? "Plan" : text
    }

    /// The modes Proceed may switch to from this plan's card: the mode before Plan and Auto.
    public var allowedProceedModes: [PermissionMode] {
        let first = proceedMode ?? .acceptEdits
        return first == .auto ? [.auto] : [first, .auto]
    }
}

/// A comment on one line of a plan.
public struct PlanComment: Codable, Hashable, Sendable, Identifiable {
    /// Index of the commented line in `PlanLines.split(plan.markdown)`.
    public var lineIndex: Int
    /// The line as the agent wrote it.
    public var line: String
    public var text: String

    public var id: Int { lineIndex }

    public init(lineIndex: Int, line: String, text: String) {
        self.lineIndex = lineIndex
        self.line = line
        self.text = text
    }
}

/// What the user decided about a plan.
public enum PlanDecision: Hashable, Sendable {
    /// Leave Plan mode for this mode and carry out the plan.
    case proceed(PermissionMode)
    /// Stay in Plan mode; the comments go back to the agent as one message.
    case keepPlanning(comments: [PlanComment])
}

extension PlanDecision: Codable {
    private enum CodingKeys: String, CodingKey { case action, mode, comments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .action) {
        case "proceed": self = .proceed(try c.decode(PermissionMode.self, forKey: .mode))
        case "keepPlanning": self = .keepPlanning(comments: try c.decodeIfPresent([PlanComment].self, forKey: .comments) ?? [])
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unknown plan decision \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .proceed(let mode):
            try c.encode("proceed", forKey: .action)
            try c.encode(mode, forKey: .mode)
        case .keepPlanning(let comments):
            try c.encode("keepPlanning", forKey: .action)
            try c.encode(comments, forKey: .comments)
        }
    }
}

/// Splitting a plan into the lines comments attach to, and the messages sent back to the agent.
public enum PlanLines {
    /// One entry per commentable line: every non-blank source line, except that a fenced code block and a table
    /// stay whole (a fragment of either does not render on its own).
    public static func split(_ markdown: String) -> [String] {
        var result: [String] = []
        var block: [String] = []
        var inFence = false
        var inTable = false
        func flush() {
            if !block.isEmpty { result.append(block.joined(separator: "\n")) }
            block.removeAll()
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                block.append(line)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inFence = false
                    flush()
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inTable = false
                flush()
                inFence = true
                block.append(line)
                continue
            }
            if trimmed.hasPrefix("|") {
                if !inTable { flush() }
                inTable = true
                block.append(line)
                continue
            }
            if inTable {
                inTable = false
                flush()
            }
            if !trimmed.isEmpty { result.append(line) }
        }
        flush()
        return result
    }

    /// The message Keep planning sends: each commented line quoted, then its comment. It names no files and carries
    /// no attachments.
    public static func feedback(_ comments: [PlanComment]) -> String {
        let useful = comments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.lineIndex < $1.lineIndex }
        guard !useful.isEmpty else { return keepPlanningMessage }
        var parts = ["Comments on the plan:"]
        for comment in useful {
            let quoted = comment.line.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            parts.append(quoted + "\n" + comment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append("Stay in plan mode: revise the plan with these comments and present it again.")
        return parts.joined(separator: "\n\n")
    }

    /// Keep planning without comments.
    public static let keepPlanningMessage = "Keep planning: the plan is not approved yet. Revise it and present it again."

    /// Sent after Proceed by engines whose plan ends the turn (OpenCode, Antigravity).
    public static let proceedMessage = "The plan is approved. Carry it out now."
}

// MARK: - Outcomes

/// How a plan or question was resolved, for the card that stays in the transcript.
public enum InteractionOutcome: Hashable, Sendable {
    case proceeded(PermissionMode)
    case keptPlanning(commentCount: Int)
    case answered([AgentQuestionAnswer])
    case declined

    public var label: String {
        switch self {
        case .proceeded(let mode): "Proceeded in \(mode.shortLabel)"
        case .keptPlanning(let count): count == 0 ? "Kept planning" : "Kept planning, \(count) \(count == 1 ? "comment" : "comments") sent"
        case .answered(let answers): "Answered: " + answers.map(\.text).joined(separator: "; ")
        case .declined: "Declined"
        }
    }
}
