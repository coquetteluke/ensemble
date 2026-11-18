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
    /// `permissions` is checked key by key (`inertPermissionKeys`).
    static let inertTopLevelKeys: Set<String> = [
        "$schema", "permissions", "model", "includeCoAuthoredBy", "attribution", "cleanupPeriodDays", "outputStyle",
        "alwaysThinkingEnabled", "spinnerTipsEnabled", "respectGitignore", "language", "disabledMcpjsonServers",
    ]

    /// `permissions` keys that only take permissions away. Everything else asks for API-key agents as
    /// `permissions.<key>`: `allow` (would run commands without asking, and a command can read the CLI's environment),
    /// `additionalDirectories` (widens what tools reach), `defaultMode` (overridden by `--permission-mode`, which the
    /// engine always passes: a project `defaultMode` of `acceptEdits` or `bypassPermissions` still started in
    /// `default`, checked live 2026-11-18, but it is not worth trusting), and any key added later.
    static let inertPermissionKeys: Set<String> = ["deny", "ask", "disableBypassPermissionsMode"]

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
        case .number(let number):
            // `Int(exactly:)` is nil for fractions, NaN, infinities and anything too large, so no value can trap.
            guard let whole = Int(exactly: number), (0...999_999_999).contains(whole) else { return false }
            text = String(whole)
        case .bool(let flag): text = flag ? "true" : "false"
        default: return false
        }
        if !text.isEmpty, text.count <= 9, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) { return true }
        return ["true", "false", "yes", "no", "on", "off"].contains(text.lowercased())
    }

    /// `env` keys pinned for a trusted folder whose files the CLI reads itself (`ClaudeSettingsPlan.project`): the
    /// engine passes them in a command-line `--settings` file, which outranks project and local settings, so a value a
    /// project adds later (the CLI reloads settings while it runs) has no effect. Checked live 2026-11-18 with one haiku
    /// turn each: a fake `ANTHROPIC_BASE_URL` added mid-session stalled the turn without the pin and did nothing with
    /// it.
    ///
    /// Only keys where an empty value means "unset" are pinned empty (the endpoint, credential and provider switches,
    /// proxies, `NODE_OPTIONS`, `NODE_TLS_REJECT_UNAUTHORIZED`). Left out on purpose: `CLAUDE_CONFIG_DIR` (an empty value
    /// made the CLI use the session folder as its config folder; it is pinned only to the value it already has), and
    /// the CA file variables (an empty value can break TLS for the agent's own tools, and with the proxies and endpoint
    /// pinned a new CA has nothing to intercept). Those still stop the process through the watcher.
    static let pinnedEnvKeys: Set<String> = Set<String>([
        "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_FOUNDRY_RESOURCE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "NODE_OPTIONS", "NODE_TLS_REJECT_UNAUTHORIZED",
    ]).union(pinnedSecretKeys)

    /// Credentials, always pinned empty for a subscription agent and never copied from anywhere.
    static let pinnedSecretKeys: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_FOUNDRY_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]

    /// The pinned values: what the CLI would use without the project, that is the value in the child's environment,
    /// else the one in the user's own `settings.json` (non-secret keys only), else empty. `CLAUDE_CONFIG_DIR` is added
    /// only when the child's environment sets it, with that value.
    static func loginPins(environment: [String: String], userSettings: URL?) -> [String: JSONValue] {
        var userEnv: [String: JSONValue] = [:]
        if let userSettings, let data = try? Data(contentsOf: userSettings), let json = JSONValue.parse(data: data) {
            userEnv = json["env"]?.objectValue ?? [:]
        }
        var pins: [String: JSONValue] = [:]
        for key in pinnedEnvKeys {
            if pinnedSecretKeys.contains(key) {
                pins[key] = ""
            } else if let value = environment[key] {
                pins[key] = .string(value)
            } else if let value = userEnv[key]?.stringValue {
                pins[key] = .string(value)
            } else {
                pins[key] = ""
            }
        }
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty { pins["CLAUDE_CONFIG_DIR"] = .string(config) }
        return pins
    }

    /// The user's own Claude settings file (`$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`).
    static func userSettingsFile(environment: [String: String]) -> URL? {
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath).appendingPathComponent("settings.json")
        }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
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

        /// A hash of everything above, so a confirmation stops counting once any of it changes. Fails closed: a
        /// snapshot that cannot be written as JSON gets a new random value each time, so it can never match.
        var fingerprint: String {
            let body: JSONValue = ["settings": .object(settings), "mcpServers": .object(mcpServers),
                                   "unreadable": .object(unreadable.mapValues(JSONValue.string))]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(body) else { return "unconfirmable-" + UUID().uuidString }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// What can redirect requests or the login and is not neutralised by `ClaudeProjectSettings.loginPins`. For a
        /// process that reads the project's files itself, these stop it at once when they appear.
        var unpinnedRedirects: [String] {
            needsConfirmation(for: .subscription).filter { !ClaudeProjectSettings.pinnedEnvKeys.contains($0) }
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
                        if let object = value.objectValue {
                            keys += object.keys.filter { !ClaudeProjectSettings.inertPermissionKeys.contains($0) }.map { "permissions.\($0)" }
                        } else {
                            keys.append("permissions")
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
    /// usual (so the project's commands, skills and agents work), with the redirect-capable `env` keys pinned by a
    /// command-line `--settings` file (`loginPins`), so a later edit cannot redirect requests or the login. The engine
    /// also watches the files and stops the process at once if something the pins do not cover appears
    /// (`Snapshot.unpinnedRedirects`, for example `apiKeyHelper` or an unreadable file).
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
