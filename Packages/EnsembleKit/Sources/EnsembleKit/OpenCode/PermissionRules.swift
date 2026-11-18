import Foundation

/// One OpenCode permission rule (`Permission.Rule`): `action` is the tool permission (`edit`, `shell`, `read`,
/// `webfetch`, `external_directory`, ...), `resource` a wildcard pattern for what it touches (a path, the
/// scanned shell command, a URL), `effect` is `allow`, `ask` or `deny`. Within a ruleset the last matching rule wins,
/// and session rules are checked after the agent's own rules, so they override them.
public struct PermissionRule: Codable, Hashable, Sendable {
    public var action: String
    public var resource: String
    public var effect: String

    public init(_ action: String, _ resource: String = "*", _ effect: String) {
        self.action = action
        self.resource = resource
        self.effect = effect
    }
}

/// The session rulesets behind Ensemble's permission modes.
///
/// OpenCode 2.3 facts these rely on (checked against the running engine):
/// - The built-in agents start from `{"*", "*", allow}`, so any tool a session ruleset does not mention runs
///   without asking. Every ruleset except Bypass therefore starts with `{"*", "*", ask}` and then names each
///   tool, so unknown tools and MCP tools (action `<server>_<tool>`) ask.
/// - Permission actions: `read`, `glob`, `grep`, `edit` (also used by the `write` and `patch` tools), `shell`,
///   `webfetch`, `websearch`, `external_directory`, `subagent`, `skill`, `question`, `execute` (Code Mode),
///   `experimental_image_generate`, `browser`, `opencode_list_mcp_resources`, `opencode_read_mcp_resource`,
///   `opencode_watch_mcp_event`, and `<server>_<tool>` for MCP tools.
/// - `edit` resources are paths relative to the session's folder (`Makefile`, `sub/Makefile`, `.git/hooks/x`), even
///   when the model passes an absolute path inside the folder. Paths outside the folder are absolute and also trigger
///   `external_directory`.
/// - `*` matches any run of characters including `/`. Matching is case-sensitive on macOS.
/// - Code Mode (`execute`) is only blocked by `deny`; with `ask` it runs, and each tool it calls is checked on its own
///   (its `fetch` asks as `webfetch`).
/// - A subagent's child session copies the parent's ruleset when it is created (no race), but does not follow later
///   changes to the parent, so `OpenCodeClient.setPermissionMode` updates child sessions too.
public enum PermissionRules {
    /// Shell commands Auto mode runs without asking: read-only commands plus common build and test commands.
    /// Every other command asks. This is a convenience list, not a security boundary: build and test commands
    /// run project code.
    ///
    /// OpenCode checks each command of a compound line (`a && b`, `a | b`) on its own, against the scanned
    /// command text. `*` matches anything, and a pattern ending in ` *` also matches the bare command.
    public static let autoAllowedShell: [String] = [
        // Read-only
        "ls *", "pwd", "which *", "cat *", "head *", "tail *", "wc *", "echo *", "grep *", "rg *", "find *",
        "git status *", "git diff *", "git log *", "git show *",
        "git branch", "git branch -a", "git branch -r", "git branch -v", "git branch -vv", "git branch --list",
        "git branch --show-current",
        // Build and test
        "swift build *", "swift test *", "xcodebuild *",
        "npm test *", "npm run *", "pnpm test *", "pnpm run *", "pnpm build *", "yarn test *", "yarn run *", "yarn build *",
        "cargo build *", "cargo test *", "cargo check *", "go build *", "go test *", "go vet *",
        "pytest *", "python -m pytest *", "python3 -m pytest *",
        "make", "make all", "make build", "make test", "make check", "make lint",
    ]

    /// Forms of the allowed commands that can still change things; these ask again (checked after the allow list).
    public static let autoAskAgainShell: [String] = [
        "find * -delete*", "find * -exec*", "find * -execdir*", "find * -ok*", "find * -okdir*",
        "find * -fprint*", "find * -fls*",
        "rg *--pre*",
        "*--output*",
        "*>*",
        "*$(*", "*`*",
    ]

    /// Files whose edits ask even when edits are allowed: they change what the allowed build and test commands run,
    /// or run code later outside the agent (git hooks, CI, direnv, toolchain pins).
    public static let protectedFileNames: [String] = [
        // make
        "Makefile", "makefile", "GNUmakefile", "*.mk",
        // JavaScript
        "package.json", ".npmrc", ".yarnrc*", "pnpm-workspace.yaml", ".pnpmfile.cjs",
        // Python
        "pyproject.toml", "setup.py", "setup.cfg", "conftest.py", "tox.ini", "noxfile.py", "pytest.ini",
        // Rust and Go
        "Cargo.toml", "build.rs", "rust-toolchain", "rust-toolchain.toml", "go.mod", "go.work",
        // Swift and Xcode
        "Package.swift", "*.pbxproj", "*.xcscheme", "*.xcconfig", "project.yml",
        // Ruby, JVM, task runners
        "Podfile", "Gemfile", "Rakefile", "justfile", "Justfile", "Taskfile*", "build.gradle*", "settings.gradle*",
        "gradle.properties", "pom.xml",
        // Environment and toolchain managers
        ".envrc", ".tool-versions", ".python-version", ".node-version", "mise.toml", ".mise.toml", "Brewfile",
    ]

    /// Folders whose contents are protected the same way.
    public static let protectedFolders: [String] = [
        ".git", ".github/workflows", ".husky", ".cargo/config", ".cargo/config.toml",
    ]

    /// `edit` patterns for the protected files: each name at the top of the folder and in any subfolder (the
    /// `*/` form also covers absolute paths), plus capitalised and all-caps spellings, because macOS file systems
    /// usually ignore case while OpenCode's matching does not.
    public static var protectedEditPatterns: [String] {
        var patterns: [String] = []
        func add(_ pattern: String) {
            if !patterns.contains(pattern) { patterns.append(pattern) }
        }
        func spellings(_ name: String) -> [String] {
            guard !name.hasPrefix("*") else { return [name, name.uppercased()] }
            return [name, name.lowercased(), name.uppercased(), name.prefix(1).uppercased() + name.dropFirst().lowercased()]
        }
        for name in protectedFileNames {
            for spelling in spellings(name) {
                if spelling.hasPrefix("*") {
                    add(spelling)
                } else {
                    add(spelling)
                    add("*/" + spelling)
                }
            }
        }
        for folder in protectedFolders {
            for spelling in spellings(folder) {
                if folder.hasPrefix(".cargo/config") {
                    // A file, not a folder: `.cargo/config` and `.cargo/config.toml`.
                    add(spelling)
                    add("*/" + spelling)
                } else {
                    add(spelling + "/*")
                    add("*/" + spelling + "/*")
                }
            }
        }
        return patterns
    }

    /// The session ruleset for a permission mode.
    ///
    /// - Ask: reads and searches run; edits, commands, web access, Code Mode, image generation, work outside the
    ///   project folder and any other tool (MCP included) ask.
    /// - Accept edits: as Ask, but file edits inside the project run, except the protected build files.
    /// - Auto: safe commands run, everything else asks. As Accept edits, plus the commands in `autoAllowedShell`
    ///   run (minus the forms in `autoAskAgainShell`).
    /// - Bypass: everything runs.
    ///
    /// All modes except Bypass allow `subagent`; the child session copies the ruleset, so children follow the same mode.
    public static func ruleset(for mode: PermissionMode) -> [PermissionRule] {
        switch mode {
        case .ask:
            return base(editsAllowed: false)
        case .acceptEdits:
            return base(editsAllowed: true)
        case .auto:
            var rules = base(editsAllowed: true)
            rules += autoAllowedShell.map { PermissionRule("shell", $0, "allow") }
            rules += autoAskAgainShell.map { PermissionRule("shell", $0, "ask") }
            return rules
        case .bypass:
            return [PermissionRule("*", "*", "allow")]
        }
    }

    private static func base(editsAllowed: Bool) -> [PermissionRule] {
        var rules = [
            // Anything not named below, including MCP tools, asks.
            PermissionRule("*", "*", "ask"),
            // Reading and searching inside the project.
            PermissionRule("read", "*", "allow"),
            PermissionRule("read", "*.env", "ask"),
            PermissionRule("read", "*.env.*", "ask"),
            PermissionRule("read", "*.env.example", "allow"),
            PermissionRule("glob", "*", "allow"),
            PermissionRule("grep", "*", "allow"),
            // Asking the user a question, loading a skill's instructions, starting a subagent (which copies these rules).
            PermissionRule("question", "*", "allow"),
            PermissionRule("skill", "*", "allow"),
            PermissionRule("subagent", "*", "allow"),
            // The engine's own defaults deny the desktop browser; keep that.
            PermissionRule("browser", "*", "deny"),
            PermissionRule("skill", "browser", "deny"),
            // Edits and commands.
            PermissionRule("edit", "*", editsAllowed ? "allow" : "ask"),
            PermissionRule("shell", "*", "ask"),
            // Network, Code Mode, images, outside the project.
            PermissionRule("webfetch", "*", "ask"),
            PermissionRule("websearch", "*", "ask"),
            PermissionRule("execute", "*", "ask"),
            PermissionRule("experimental_image_generate", "*", "ask"),
            PermissionRule("external_directory", "*", "ask"),
        ]
        if editsAllowed {
            rules += protectedEditPatterns.map { PermissionRule("edit", $0, "ask") }
        }
        return rules
    }

    /// Best guess of the mode a ruleset came from (for sessions created elsewhere). `nil` when it does not match.
    public static func mode(for rules: [PermissionRule]) -> PermissionMode? {
        if rules.isEmpty { return nil }
        return PermissionMode.allCases.first { ruleset(for: $0) == rules }
    }

    /// What a ruleset decides for one action and resource, using OpenCode's matching: the last matching rule wins,
    /// `*` matches any run of characters (including `/` and spaces), `?` matches one character, and for `shell`
    /// a pattern ending in ` *` also matches the bare command. With no match the engine falls back to the agent's
    /// rules, which allow everything for the built-in agents; this returns `"agent"` then.
    /// Used to preview and test rulesets; the engine makes the real decision.
    public static func effect(action: String, resource: String, rules: [PermissionRule]) -> String {
        var result = "agent"
        for rule in rules where wildcardMatch(rule.action, action) {
            if wildcardMatch(rule.resource, resource)
                || (action == "shell" && rule.resource.hasSuffix(" *") && resource == String(rule.resource.dropLast(2))) {
                result = rule.effect
            }
        }
        return result
    }

    static func wildcardMatch(_ pattern: String, _ value: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let v = Array(value.unicodeScalars)
        var pi = 0, vi = 0
        var starP = -1, starV = 0
        while vi < v.count {
            if pi < p.count, p[pi] == "?" || (p[pi] != "*" && p[pi] == v[vi]) {
                pi += 1
                vi += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi
                starV = vi
                pi += 1
            } else if starP >= 0 {
                pi = starP + 1
                starV += 1
                vi = starV
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
