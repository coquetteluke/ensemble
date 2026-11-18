import Foundation

// Auto for agents that Ensemble decides itself (`SafetyCheck+Agents.swift`).
//
// Some agents have no auto mode Ensemble can trust: Antigravity's own `auto` sends no permission prompts at all (it ran
// `rm -rf`, a `curl` to the internet and a retry with `BypassSandbox: true` without asking). For those, Ensemble's Auto
// runs the agent in its ask-everything mode, so every edit and command reaches Ensemble as a prompt, and Ensemble
// answers each one the way OpenCode's Auto rules and the safety check would:
// - an edit of files inside the session's folder runs, except hidden paths, protected build, config and agent
//   instruction files, and anything a link takes outside the folder (`PermissionRules`, `SafetyCheckHardRules`);
// - a command first goes past the fixed rules (`SafetyCheckHardRules`), then runs when it is one of the read-only
//   commands OpenCode's Auto allows (`PermissionRules.autoAllowedShell`), and otherwise goes to the safety check's model
//   chosen in Settings, or asks when there is none;
// - a request to leave the agent's sandbox, an argument Ensemble does not know, and every other kind of request asks.

/// Exactly what one agent permission prompt asks, read by the engine from the request itself (never from the transcript
/// or from text the agent wrote to describe it).
public struct AgentPermissionSubject: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// A shell command: the whole command line, and the folder it runs in (links resolved).
        case command(String, folder: String)
        /// A file edit: the files it writes, relative to the session's folder (every one inside it).
        case edit(paths: [String])
        /// Anything else: reads, fetches, deletes, moves and other tools. Always asks, for this reason.
        case other(reason: String)
    }

    public var action: Action
    /// The tool call the prompt belongs to (the same id as the tool card).
    public var toolCallID: String?
    /// Set when the prompt must ask whatever else it holds: an argument Ensemble does not know, a request to run outside
    /// the agent's sandbox, a folder outside the project.
    public var askReason: String?

    public init(action: Action, toolCallID: String? = nil, askReason: String? = nil) {
        self.action = action
        self.toolCallID = toolCallID
        self.askReason = askReason
    }
}

/// Engines whose agents, in Auto, ask before every edit and command, so that Ensemble decides each prompt itself (ACP
/// agents whose definition sets `ensembleDecidesAuto`). The router forwards both calls to the session's engine. Sessions
/// of other engines never take this path: OpenCode prompts go through the safety check as before, Claude prompts are
/// shown as they come.
public protocol EngineAgentPermissionSupport: Sendable {
    /// True when Ensemble decides this session's prompts while it is in Auto.
    func decidesAutoPrompts(for sessionID: String) -> Bool
    /// What an open prompt asks, or nil when the engine cannot say exactly (the prompt then asks).
    func autoPromptSubject(forPermission requestID: String, sessionID: String) async -> AgentPermissionSubject?
}

/// The rules for agent prompts that need no model. They only combine the lists in `PermissionRules` and the readers in
/// `SafetyCheckHardRules`; nothing here has a list of its own.
public enum SafetyCheckAgentRules {
    static let editAllowed = "Edit inside the project folder"
    static let readOnly = "Read-only command"

    /// Why an edit of these files (relative to `directory`) asks, or nil when it may run. Each path must be plain text
    /// inside the folder, allowed by OpenCode's Auto edit rules (`PermissionRules.ruleset(for: .auto)`: no hidden
    /// segment, no protected file in its usual spellings, not OpenCode's config shape at the top), not a protected or
    /// key file name in any case (`SafetyCheckHardRules.nameReason`), and not taken outside the folder by a link.
    public static func editReason(paths: [String], directory: String) -> String? {
        guard !paths.isEmpty else { return "No file to check" }
        let rules = PermissionRules.ruleset(for: .auto)
        for path in paths {
            if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") { return SafetyCheckHardRules.outside }
            if PermissionDisplay.visible(path) != path { return "Contains hidden characters" }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return SafetyCheckHardRules.outside }
            if parts.contains(where: { $0.hasPrefix(".") }) { return SafetyCheckHardRules.hidden }
            if PermissionRules.effect(action: "edit", resource: path, rules: rules) != "allow" { return SafetyCheckHardRules.protected }
            if let reason = SafetyCheckHardRules.nameReason(path) { return reason }
            if SafetyCheckHardRules.leavesFolderOnDisk(directory + "/" + path, root: directory) { return SafetyCheckHardRules.outside }
        }
        return nil
    }

    /// True when every command of the line is one of the read-only commands OpenCode's Auto runs without asking
    /// (`PermissionRules.autoAllowedShell`, minus the forms in `autoAskAgainShell`), matched the way OpenCode matches
    /// them, one command at a time. Call it only for lines the fixed rules passed. Lines with a variable (`echo $TOKEN`)
    /// or a redirection never count: the model decides those.
    public static func isReadOnly(_ command: String) -> Bool {
        guard !command.contains("$"), !command.contains(">"), !command.contains("<") else { return false }
        let reading = ShellText.read(command)
        guard reading.problem == nil, !reading.segments.isEmpty else { return false }
        let askAgain = PermissionRules.autoAskAgainShell.map { PermissionRule("shell", $0, "ask") }
        if PermissionRules.effect(action: "shell", resource: command, rules: askAgain) == "ask" { return false }
        let rules = [PermissionRule("shell", "*", "ask")]
            + PermissionRules.autoAllowedShell.map { PermissionRule("shell", $0, "allow") }
            + askAgain
        for segment in reading.segments {
            let text = segment.raw.joined(separator: " ")
            guard PermissionRules.effect(action: "shell", resource: text, rules: rules) == "allow" else { return false }
        }
        return true
    }
}
