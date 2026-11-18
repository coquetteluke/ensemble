import Foundation

/// Claude Code's plan and question tools, as they arrive on the control channel (claude 2.1.319, tested 2026-11-18 on
/// haiku with `--permission-prompt-tool stdio`):
/// - `AskUserQuestion` comes as a `can_use_tool` request with `input.questions` (`question`, `header`, `options` with
///   `label` and `description`, `multiSelect`) and `requires_user_interaction`. The answer is an allow whose
///   `updatedInput` is the input plus `answers`, a map from question text to the chosen label (several labels joined
///   with ", ", or the typed text). The agent then reads `"<question>"="<answer>"`. A deny declines.
/// - `ExitPlanMode` comes the same way with `input.plan` (Markdown) and `input.planFilePath` (the CLI's own plan file
///   under `~/.claude/plans`, which plan mode lets it write without asking). Allow means Proceed: the engine first
///   switches the mode with `set_permission_mode`, and the agent carries on in the same turn. A deny with a message
///   means Keep planning: the agent reads the message, revises the plan and calls `ExitPlanMode` again.
enum ClaudeInteractionTools {
    static let askUserQuestion = "AskUserQuestion"
    static let exitPlanMode = "ExitPlanMode"
    static let all: Set<String> = [askUserQuestion, exitPlanMode]

    /// The questions in an `AskUserQuestion` input. The question text is the answer key, so a question without text is
    /// left out, and so is a second question with the same text.
    static func questions(from input: JSONValue) -> [AgentQuestion] {
        var seen = Set<String>()
        return (input["questions"]?.arrayValue ?? []).compactMap { entry in
            guard let text = entry["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  seen.insert(text).inserted else { return nil }
            let options = (entry["options"]?.arrayValue ?? []).compactMap { option -> AgentQuestion.Option? in
                guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
                let detail = option["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                return AgentQuestion.Option(label: label, detail: detail)
            }
            let multi: Bool
            if case .bool(let flag)? = entry["multiSelect"] { multi = flag } else { multi = false }
            let header = entry["header"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            // Claude Code always lets the user type their own answer.
            return AgentQuestion(id: text, header: header, text: text, options: options, multiSelect: multi, allowsOther: true)
        }
    }

    /// The `updatedInput` that answers `AskUserQuestion`: the original input plus `answers`.
    static func answeredInput(_ input: JSONValue, questions: [AgentQuestion], answers: [AgentQuestionAnswer]) -> JSONValue {
        var object = input.objectValue ?? [:]
        var map: [String: JSONValue] = [:]
        for question in questions {
            guard let answer = answers.first(where: { $0.questionID == question.id }).flatMap(question.validated) else { continue }
            map[question.id] = .string(answer.text)
        }
        object["answers"] = .object(map)
        return .object(object)
    }
}

/// Keeps Claude's plan mode read-only. The CLI's plan mode lets the auto-mode classifier approve shell commands
/// (a file write ran without a prompt in testing), so while a session is in plan the engine adds `Bash` to the
/// `permissions.ask` list through `apply_flag_settings` (checked live: the command then came as a prompt, and setting
/// the list back made it run without one again), and denies file edits itself. Any `permissions` the session's
/// `--settings` file already had are sent back unchanged, so whether the CLI merges or replaces the object, nothing
/// else changes.
enum ClaudePlanGuard {
    static let askedTools = ["Bash"]

    /// The `apply_flag_settings` payload for plan on or off.
    static func settings(planOn: Bool, base: JSONValue?) -> JSONValue {
        var permissions = base?.objectValue ?? [:]
        // Off restores exactly what the settings file had (which may list Bash itself).
        var ask = base?["ask"]?.arrayValue ?? []
        if planOn {
            for tool in askedTools where !ask.contains(.string(tool)) { ask.append(.string(tool)) }
        }
        permissions["ask"] = .array(ask)
        return ["permissions": .object(permissions)]
    }

    /// The `permissions` object of the settings handed to the CLI with `--settings`, if it has one.
    static func basePermissions(_ settings: [String: JSONValue]?) -> JSONValue? {
        guard let permissions = settings?["permissions"], permissions.objectValue != nil else { return nil }
        return permissions
    }

    /// What the engine tells the agent when it refuses an edit in plan mode.
    static let editRefusal = "Plan mode is read-only: do not change files. Finish the plan and present it with ExitPlanMode."
}

extension ClaudePermissionPrompt {
    var isQuestion: Bool { toolName == ClaudeInteractionTools.askUserQuestion }
    var isPlan: Bool { toolName == ClaudeInteractionTools.exitPlanMode }
    var isInteraction: Bool { isQuestion || isPlan }

    /// The request Ensemble shows for a plan or question tool, or nil for other tools.
    static func interactionRequest(requestID: String, sessionID: String, toolName: String, input: JSONValue,
                                   created: Date) -> PermissionRequest? {
        switch toolName {
        case ClaudeInteractionTools.askUserQuestion:
            let questions = ClaudeInteractionTools.questions(from: input)
            guard !questions.isEmpty else { return nil }
            return PermissionRequest(id: requestID, sessionID: sessionID, kind: InteractionKind.question,
                                     title: questions[0].text, created: created, questions: questions)
        case ClaudeInteractionTools.exitPlanMode:
            let markdown = input["plan"]?.stringValue ?? ""
            let path = input["planFilePath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let plan = PlanProposal(markdown: markdown, filePath: path)
            return PermissionRequest(id: requestID, sessionID: sessionID, kind: InteractionKind.plan, title: plan.title,
                                     created: created, plan: plan)
        default:
            return nil
        }
    }

    /// The control response that answers this question prompt; empty `answers` declines.
    func questionResponse(answers: [AgentQuestionAnswer]) -> JSONValue {
        let questions = request.questions ?? []
        let usable = answers.compactMap { answer in questions.first { $0.id == answer.questionID }?.validated(answer) }
        guard !usable.isEmpty else {
            return response(behavior: ["behavior": "deny", "message": "The user declined to answer."])
        }
        return response(behavior: ["behavior": "allow",
                                   "updatedInput": ClaudeInteractionTools.answeredInput(input, questions: questions, answers: usable)])
    }

    /// The control response for Proceed (allow; the mode is switched before this is sent) or Keep planning (deny with
    /// the comments).
    func planResponse(_ decision: PlanDecision) -> JSONValue {
        switch decision {
        case .proceed:
            return response(behavior: ["behavior": "allow", "updatedInput": input])
        case .keepPlanning(let comments):
            return response(behavior: ["behavior": "deny", "message": .string(PlanLines.feedback(comments))])
        }
    }

    /// Refuses a file edit while the session is in plan mode.
    func planEditRefusal() -> JSONValue {
        response(behavior: ["behavior": "deny", "message": .string(ClaudePlanGuard.editRefusal)])
    }

    private func response(behavior: JSONValue) -> JSONValue {
        ["type": "control_response",
         "response": ["subtype": "success", "request_id": .string(requestID), "response": behavior]]
    }
}
