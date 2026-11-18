import Foundation

/// What the CLI's `initialize` control response says about models, commands and fast mode. Built straight from the
/// response; the account part of that response (email, organisation) is never read or kept.
struct ClaudeInitializeInfo: Equatable, Sendable {
    struct Model: Equatable, Sendable {
        /// What `--model` takes (`opus`, `claude-opus-4-8`, `default`).
        var value: String
        var resolvedModel: String?
        var displayName: String
        var summary: String?
        var effortLevels: [String]
        var supportsFastMode: Bool
    }

    struct Command: Equatable, Sendable {
        var name: String
        var summary: String
        var argumentHint: String?
        var builtin: Bool
        var aliases: [String]
    }

    var models: [Model] = []
    var commands: [Command] = []
    var fastModeState: String?
    var fastModeDisabledReason: String?
    var version: String?

    init(models: [Model] = [], commands: [Command] = [], fastModeState: String? = nil, fastModeDisabledReason: String? = nil,
         version: String? = nil) {
        self.models = models
        self.commands = commands
        self.fastModeState = fastModeState
        self.fastModeDisabledReason = fastModeDisabledReason
        self.version = version
    }

    init(response: JSONValue) {
        models = (response["models"]?.arrayValue ?? []).compactMap { entry in
            guard let value = entry["value"]?.stringValue else { return nil }
            let levels = (entry["supportsEffort"]?.boolValue ?? false)
                ? (entry["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.stringValue) : []
            return Model(value: value, resolvedModel: entry["resolvedModel"]?.stringValue,
                         displayName: entry["displayName"]?.stringValue ?? value, summary: entry["description"]?.stringValue,
                         effortLevels: levels, supportsFastMode: entry["supportsFastMode"]?.boolValue ?? false)
        }
        commands = (response["commands"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { return nil }
            let hint = entry["argumentHint"]?.stringValue
            return Command(name: name, summary: Self.cleanSummary(entry["description"]?.stringValue ?? ""),
                           argumentHint: (hint?.isEmpty ?? true) ? nil : hint, builtin: entry["builtin"]?.boolValue ?? false,
                           aliases: (entry["aliases"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        fastModeState = response["fast_mode_state"]?.stringValue
        fastModeDisabledReason = response["fast_mode_disabled_reason"]?.stringValue
        version = response["claude_code_version"]?.stringValue
    }

    /// Drops the source tag the CLI appends ("(user)", "(project)", "(plugin:name)").
    static func cleanSummary(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix(")"), let open = result.range(of: " (", options: .backwards) {
            let tag = result[open.upperBound..<result.index(before: result.endIndex)]
            if ["user", "project", "bundled", "managed", "local"].contains(tag) || tag.hasPrefix("plugin") {
                result = String(result[..<open.lowerBound])
            }
        }
        return result
    }

    /// Commands that would break Ensemble's view of the session, that Ensemble already offers as controls, or that
    /// only work in the terminal.
    static let hiddenCommands: Set<String> = [
        "clear", "reset", "new", "resume", "continue", "exit", "quit", "login", "logout", "rewind", "teleport",
        "remote-control", "rc", "ide", "terminal-setup", "vim", "theme", "statusline", "keybindings", "upgrade",
        "install-github-app", "install-slack-app", "bug", "feedback", "model", "effort", "fast", "permissions",
        "doctor", "color", "focus", "reload-plugins", "config", "output-style", "heapdump", "export", "tasks",
    ]

    /// The `/` menu: skills and commands that work in a headless session.
    func engineCommands(skills: Set<String>, terminalOnly: Set<String>) -> [EngineCommand] {
        var seen = Set<String>()
        return commands.compactMap { command in
            guard !Self.hiddenCommands.contains(command.name), !terminalOnly.contains(command.name),
                  seen.insert(command.name).inserted else { return nil }
            let kind: EngineCommand.Kind = command.builtin ? .command : (skills.isEmpty || skills.contains(command.name) ? .skill : .command)
            return EngineCommand(name: command.name, summary: command.summary, kind: kind, argumentHint: command.argumentHint)
        }
    }
}
