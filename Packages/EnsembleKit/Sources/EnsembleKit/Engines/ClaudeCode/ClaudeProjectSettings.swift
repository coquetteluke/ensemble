import CryptoKit
import Foundation

/// A project's own Claude Code settings: `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json`.
///
/// Facts this relies on (claude 2.1.319, checked 2026-11-18 without prompts unless noted):
/// - Headless `claude -p` skips Claude Code's "Do you trust this folder?" question. With `--setting-sources
///   user,project,local` a project's SessionStart hook and its `.mcp.json` server both ran with no prompt; with
///   `--setting-sources user` neither did, and the project's commands, skills and agents were left out too.
/// - Only the session folder's own `.claude/settings*.json` count, not those of folders above it (not even a git
///   root above it).
/// - The CLI reloads project settings while it runs: a hook and an `env` value added to `.claude/settings.json` after
///   start were used on the next prompt (one haiku turn). A check before launch is therefore not enough.
/// - `--settings <file>` and `--mcp-config <file>` still apply with `--setting-sources user`: hooks, `env` and MCP
///   servers from them ran.
///
/// So the engine never lets the CLI read these files when what they contain matters (`ClaudeSettingsPlan`): it hands
/// the CLI a private copy of exactly the values the user confirmed.
enum ClaudeProjectSettings {
    /// `env` keys a project may set without asking, with plain numeric or yes/no values only. They switch features off
    /// or bound how long things run; they name no host, file, program or credential, and a Bash command that inherits
    /// them gains nothing. Every other key asks for API-key agents, since any variable can change what the CLI or the
    /// programs it starts do while the key is in its environment (`NODE_OPTIONS`, `PATH`, proxies, CA files,
    /// `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, ...).
    static let safeEnvKeys: Set<String> = [
        "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "DISABLE_BUG_COMMAND", "DISABLE_COST_WARNINGS",
        "DISABLE_NON_ESSENTIAL_MODEL_CALLS", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "BASH_DEFAULT_TIMEOUT_MS", "BASH_MAX_TIMEOUT_MS", "BASH_MAX_OUTPUT_LENGTH", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT",
    ]

    /// Top-level settings that do not run programs, reach the network or loosen permissions. Anything else (hooks,
    /// `statusLine`, `apiKeyHelper`, plugins, MCP switches, keys added in later CLI versions) asks for API-key agents.
    /// `permissions` counts only without `allow` rules: a project allow rule would run commands without asking, and a
    /// command can read the CLI's environment.
    static let inertTopLevelKeys: Set<String> = [
        "$schema", "permissions", "model", "includeCoAuthoredBy", "attribution", "cleanupPeriodDays", "outputStyle",
        "alwaysThinkingEnabled", "spinnerTipsEnabled", "respectGitignore", "language", "disabledMcpjsonServers",
    ]

    /// Top-level settings that produce credentials by running a program.
    static let credentialHelperKeys: Set<String> = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper"]

    /// `env` keys that can send the CLI's requests, and with them the user's Claude login, somewhere else, or change
    /// how it finds or checks credentials: Anthropic and Claude Code settings, Node options, cloud provider switches,
    /// proxies (any spelling), CA and TLS settings, and where programs and config are looked up.
    static func redirectsLogin(_ key: String) -> Bool {
        let upper = key.uppercased()
        let prefixes = ["ANTHROPIC_", "CLAUDE_", "NODE_", "SSL_", "AWS_", "GOOGLE_", "CLOUD_ML_", "VERTEX_", "BEDROCK_", "DYLD_", "LD_"]
        if prefixes.contains(where: upper.hasPrefix) || upper.contains("PROXY") { return true }
        return ["HOME", "PATH", "XDG_CONFIG_HOME", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "TMPDIR"].contains(upper)
    }

    static func isSafeEnv(_ key: String, _ value: JSONValue) -> Bool {
        guard safeEnvKeys.contains(key) else { return false }
        let text: String
        switch value {
        case .string(let string): text = string
        case .number(let number): text = number.rounded() == number ? String(Int(number)) : "x"
        case .bool(let flag): text = flag ? "true" : "false"
        default: return false
        }
        if !text.isEmpty, text.count <= 9, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) { return true }
        return ["true", "false", "yes", "no", "on", "off"].contains(text.lowercased())
    }

    /// Permission rules whose `/path` form means "relative to the settings file's project", rewritten to the absolute
    /// `//path` form so they keep meaning the same once the settings live in a private copy.
    static let pathRuleTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "NotebookRead", "Glob", "Grep", "LS"]

    /// What the CLI would load from a session folder, merged, plus a fingerprint of it.
    struct Snapshot: Equatable, Sendable {
        /// The resolved project folder.
        var directory: String
        /// Project then local settings, merged like the CLI merges them (objects key by key, lists joined, local wins),
        /// with `/path` permission rules made absolute.
        var settings: [String: JSONValue]
        /// `.mcp.json` servers, minus those the settings disable.
        var mcpServers: [String: JSONValue]
        /// Files that exist but are not JSON objects, with a hash of their bytes.
        var unreadable: [String: String]

        var isEmpty: Bool { settings.isEmpty && mcpServers.isEmpty && unreadable.isEmpty }

        /// A hash of everything above, so a confirmation stops counting once any of it changes.
        var fingerprint: String {
            let body: JSONValue = ["settings": .object(settings), "mcpServers": .object(mcpServers),
                                   "unreadable": .object(unreadable.mapValues(JSONValue.string))]
            return SHA256.hash(data: Data(body.jsonText.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// What needs the user's confirmation before an agent with this billing may load these settings. Values are
        /// never included.
        func needsConfirmation(for billing: ClaudeBilling) -> [String] {
            var keys = unreadable.keys.map { "unreadable \($0)" }
            for (key, value) in settings["env"]?.objectValue ?? [:] where !ClaudeProjectSettings.isSafeEnv(key, value) {
                if billing == .apiKey || ClaudeProjectSettings.redirectsLogin(key) { keys.append(key) }
            }
            if settings["env"] != nil, settings["env"]?.objectValue == nil { keys.append("env") }
            for (key, value) in settings where key != "env" {
                switch billing {
                case .apiKey:
                    if key == "permissions" {
                        if !(value["allow"]?.arrayValue ?? []).isEmpty || (value["allow"] != nil && value["allow"]?.arrayValue == nil) {
                            keys.append("permissions.allow")
                        }
                    } else if !ClaudeProjectSettings.inertTopLevelKeys.contains(key) {
                        keys.append(key)
                    }
                case .subscription:
                    if ClaudeProjectSettings.credentialHelperKeys.contains(key) { keys.append(key) }
                }
            }
            if billing == .apiKey { keys += mcpServers.keys.map { "MCP server \($0)" } }
            return Array(Set(keys)).sorted()
        }

        /// The private `--settings` file's contents.
        var settingsData: Data { JSONValue.object(settings).lineData }

        /// The private `--mcp-config` file's contents, or nil without servers.
        var mcpData: Data? {
            mcpServers.isEmpty ? nil : JSONValue.object(["mcpServers": .object(mcpServers)]).lineData
        }
    }

    /// Reads a session folder's own settings. Nil when the folder cannot be resolved.
    static func snapshot(directory: String) -> Snapshot? {
        guard let root = WorkspaceTrust.resolvedPath(directory) else { return nil }
        let base = URL(fileURLWithPath: root)
        var settings: [String: JSONValue] = [:]
        var unreadable: [String: String] = [:]
        for name in ["settings.json", "settings.local.json"] {
            let file = base.appendingPathComponent(".claude").appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            guard let json = JSONValue.parse(data: data), case .object(let object) = json else {
                unreadable[".claude/" + name] = digest(data)
                continue
            }
            settings = merge(.object(settings), .object(absolutePermissionPaths(object, root: root))).objectValue ?? settings
        }
        var servers: [String: JSONValue] = [:]
        let mcpFile = base.appendingPathComponent(".mcp.json")
        if let data = try? Data(contentsOf: mcpFile) {
            if let json = JSONValue.parse(data: data), case .object = json, let list = json["mcpServers"]?.objectValue {
                let disabled = Set((settings["disabledMcpjsonServers"]?.arrayValue ?? []).compactMap(\.stringValue))
                servers = list.filter { !disabled.contains($0.key) }
            } else if JSONValue.parse(data: data)?.objectValue == nil {
                unreadable[".mcp.json"] = digest(data)
            }
        }
        return Snapshot(directory: root, settings: settings, mcpServers: servers, unreadable: unreadable)
    }

    /// True when the folder has settings, MCP servers, commands, skills or agents of its own, which an untrusted
    /// session leaves out.
    static func hasOwnSettings(directory: String) -> Bool {
        guard let root = WorkspaceTrust.resolvedPath(directory) else { return false }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: root)
        let paths = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/commands", ".claude/skills", ".claude/agents"]
        return paths.contains { fm.fileExists(atPath: base.appendingPathComponent($0).path) }
    }

    static func merge(_ base: JSONValue, _ over: JSONValue) -> JSONValue {
        switch (base, over) {
        case (.object(var left), .object(let right)):
            for (key, value) in right { left[key] = left[key].map { merge($0, value) } ?? value }
            return .object(left)
        case (.array(let left), .array(let right)):
            return .array(left + right.filter { !left.contains($0) })
        default:
            return over
        }
    }

    static func absolutePermissionPaths(_ settings: [String: JSONValue], root: String) -> [String: JSONValue] {
        guard case .object(var permissions)? = settings["permissions"] else { return settings }
        for list in ["allow", "deny", "ask"] {
            guard let rules = permissions[list]?.arrayValue else { continue }
            permissions[list] = .array(rules.map { rule in
                guard let text = rule.stringValue, let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return rule }
                let tool = String(text[..<open])
                let spec = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                guard pathRuleTools.contains(tool), spec.hasPrefix("/"), !spec.hasPrefix("//") else { return rule }
                return .string("\(tool)(/\(root)\(spec))")
            })
        }
        var result = settings
        result["permissions"] = .object(permissions)
        return result
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// How a session's process gets its folder's own settings.
enum ClaudeSettingsPlan: Equatable, Sendable {
    /// Untrusted folder: the project's settings, MCP servers, commands, skills and agents are left out
    /// (`--setting-sources user`).
    case userOnly
    /// Trusted folder with nothing that needs confirming for a subscription agent: the CLI reads the project's files as
    /// usual, and the engine watches them and stops the process if something that needs confirming appears.
    case project
    /// The confirmed values, passed as private `--settings` and `--mcp-config` files with `--setting-sources user`, so
    /// the CLI never reads the project's files and nothing added to them later can take effect. Used for every
    /// API-key agent in a trusted folder and for subscription agents whose folder needed confirming. The project's own
    /// commands, skills and agents are left out, since they can carry hooks and MCP servers of their own.
    case snapshot(ClaudeProjectSettings.Snapshot)

    /// Decides the plan, or throws the error the UI turns into a question.
    /// - Parameter confirmed: the fingerprint the user confirmed for this folder, if any.
    static func decide(billing: ClaudeBilling, trusted: Bool, directory: String, snapshot: ClaudeProjectSettings.Snapshot?,
                       confirmed: String?) throws -> ClaudeSettingsPlan {
        guard trusted else {
            // The CLI will not load these files, but an API-key agent in a folder that tries to redirect requests or
            // credentials is always shown, so such a project never goes unnoticed.
            if billing == .apiKey, let snapshot, !snapshot.needsConfirmation(for: .subscription).isEmpty {
                throw ClaudeCodeError.folderNotTrusted(directory)
            }
            return .userOnly
        }
        let found = snapshot ?? ClaudeProjectSettings.Snapshot(directory: directory, settings: [:], mcpServers: [:], unreadable: [:])
        let keys = found.needsConfirmation(for: billing)
        if !keys.isEmpty, confirmed != found.fingerprint {
            throw ClaudeCodeError.projectOverridesAPISettings(directory: directory, keys: keys)
        }
        if billing == .apiKey || !keys.isEmpty { return .snapshot(found) }
        return .project
    }
}
