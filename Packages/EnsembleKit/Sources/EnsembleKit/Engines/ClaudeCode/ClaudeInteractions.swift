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

/// Keeps Claude's plan mode read-only, in two layers.
///
/// 1. The CLI asks. Its plan mode only holds a call the permission system would not allow anyway: the auto-mode
///    classifier approved `echo hi > shell.txt` without a prompt (tested 2026-11-18), and the user's own allow rules
///    would approve edits or MCP tools the same way. So while a session is in plan the engine adds every tool that can
///    run commands, change files or reach outside the conversation to `permissions.ask` through `apply_flag_settings`;
///    ask rules outrank allow rules and the classifier (checked live: `Bash` and `mcp__*` then came as prompts, and
///    removing them made the calls run without one again). Any `permissions` the session's `--settings` file already
///    had are sent back unchanged, so whether the CLI merges or replaces the object, nothing else changes. The engine
///    waits for the CLI to accept this before it sends a turn, and fails closed when it does not (`ClaudeEngineCore`).
/// 2. Ensemble decides. Every prompt that reaches the engine in plan is checked by `decision(for:)`: tools that change
///    files are refused, everything else waits for the user, and remembered "Always" rules approve nothing.
enum ClaudePlanGuard {
    /// Tools that run commands: `ClaudeFormatting.shellToolNames`, plus `Monitor` (runs a command and watches it).
    static let commandTools: Set<String> = ClaudeFormatting.shellToolNames.union(["Monitor"])

    /// Tools that change files: `ClaudeFormatting.editToolNames`, plus the worktree tools (they create or remove a git
    /// worktree).
    static let fileTools: Set<String> = ClaudeFormatting.editToolNames.union(["EnterWorktree", "ExitWorktree"])

    /// Other tools in claude 2.1.319's list that act outside the conversation: schedules and triggers, messages to
    /// other sessions and projects, notifications, design sync, workflows (which script subagents).
    static let sideEffectTools: Set<String> = [
        "CronCreate", "CronDelete", "RemoteTrigger", "ScheduleWakeup", "SendMessage", "SendToProject",
        "SendToProjectContext", "PushNotification", "DesignSync", "Workflow",
    ]

    /// Every MCP tool (the CLI matches `mcp__*` against all servers' tools).
    static let mcpPattern = "mcp__*"

    /// What plan adds to `permissions.ask`, in a stable order.
    static let askedTools: [String] = commandTools.union(fileTools).union(sideEffectTools).sorted() + [mcpPattern]

    enum Decision: Equatable {
        /// Answer no at once: the tool would change files.
        case refuse
        /// Show the prompt to the user, never approve it on Ensemble's own.
        case ask
        /// The CLI's own plan file (`~/.claude/plans/<name>.md`), which plan mode writes as part of planning.
        case allowPlanFile
    }

    /// Ensemble's own decision for a prompt in plan mode (layer 2), whatever the CLI suggests with it.
    static func decision(toolName: String, input: JSONValue, plansFolder: String?) -> Decision {
        guard fileTools.contains(toolName) else { return .ask }
        if ["Write", "Edit"].contains(toolName), let plansFolder, isPlanFile(input["file_path"]?.stringValue, plansFolder: plansFolder) {
            return .allowPlanFile
        }
        return .refuse
    }

    /// True for a Markdown file directly inside the CLI's plans folder, after resolving links on both sides.
    static func isPlanFile(_ path: String?, plansFolder: String) -> Bool {
        guard let path, path.hasPrefix("/"), path.hasSuffix(".md"), !path.split(separator: "/").contains(".."),
              let resolved = WorkspaceTrust.resolvedPath(path), let folder = WorkspaceTrust.resolvedPath(plansFolder) else { return false }
        return (resolved as NSString).deletingLastPathComponent == folder
    }

    /// The CLI's plans folder for a child environment: `$CLAUDE_CONFIG_DIR/plans`, else `~/.claude/plans`.
    static func plansFolder(environment: [String: String]) -> String? {
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty { return (config as NSString).appendingPathComponent("plans") }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return (home as NSString).appendingPathComponent(".claude/plans")
    }

    /// The `apply_flag_settings` payload for plan on or off.
    static func settings(planOn: Bool, base: JSONValue?) -> JSONValue {
        var permissions = base?.objectValue ?? [:]
        // Off restores exactly what the settings file had (which may list some of these tools itself).
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
