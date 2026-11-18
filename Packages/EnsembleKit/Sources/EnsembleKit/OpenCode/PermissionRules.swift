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
/// OpenCode 2.3 facts these rely on (checked against the running engine and its binary):
/// - The built-in agents start from `{"*", "*", allow}`, so any tool a session ruleset does not mention runs
///   without asking. Every ruleset except Bypass therefore starts with `{"*", "*", ask}` and then names each
///   tool, so unknown tools and MCP tools (action `<server>_<tool>`) ask.
/// - Permission actions: `read`, `glob`, `grep`, `edit` (also used by the `write` and `patch` tools), `shell`,
///   `webfetch`, `websearch`, `external_directory`, `subagent`, `skill`, `question`, `execute` (Code Mode),
///   `experimental_image_generate`, `browser`, `opencode_list_mcp_resources`, `opencode_read_mcp_resource`,
///   `opencode_watch_mcp_event`, and `<server>_<tool>` for MCP tools.
/// - `edit` resources are paths relative to the session's folder (`Makefile`, `sub/Makefile`, `.git/hooks/x`), even
///   when the model passes an absolute path inside the folder. They are normalised (`./a` is `a`, `sub/../Makefile`
///   is `Makefile`) but keep the model's spelling (`.GiT/hooks/x` stays `.GiT/hooks/x`). Paths outside the folder
///   are absolute and also trigger `external_directory`.
/// - Matching turns the pattern into a regular expression: `*` is any run of characters including `/`, `?` is one
///   character, and everything else is literal, `[` and `]` included, so there are no character classes. It is
///   case-sensitive on every platform. macOS disks usually ignore case (and fold a few other letters, such as the
///   Kelvin sign, into ASCII ones), so no list of spellings covers a file name. Only rules that do not depend on
///   letters hold: a path segment that starts with a dot, for example.
/// - The shell tool checks each command of a line on its own (`a && b`, `a | b`, and commands inside `$(...)` and
///   `<(...)`), against the command text with any `VAR=value` prefix kept. It never checks `cd` (only whether the
///   folder is outside the project) or the tool's `workdir` argument, so a command can run in any project subfolder.
/// - Code Mode (`execute`) is only blocked by `deny`; with `ask` it runs, and each tool it calls is checked on its own
///   (its `fetch` asks as `webfetch`).
/// - A subagent's child session copies the parent's ruleset when it is created (no race), but does not follow later
///   changes to the parent, so `OpenCodeClient.setPermissionMode` updates child sessions too.
public enum PermissionRules {
    /// Shell commands Auto mode runs without asking: commands that only read, and never run code that the project
    /// (or an agent's edit) controls. Every other command asks.
    ///
    /// Left out on purpose:
    /// - Build, test and task runners (`make`, `npm test`, `swift build`, `xcodebuild`, `pytest`, `cargo test`,
    ///   `go test`, `gradle`, ...). They run code the project defines, and an edit to their build file is allowed
    ///   in Auto when the name is spelt in a case `protectedFileNames` does not list (`PaCkAgE.json`), so the
    ///   command is where Ensemble asks.
    /// - `git diff`, `git log` and `git show`. They run helpers named in the repository config (textconv, external
    ///   diff, signature checks). Ordinary files (`HEAD`, `config`, `refs/`, `objects/info/alternates`,
    ///   `info/attributes`) make any folder a bare repository, and `cd folder && git show` then runs its helpers.
    ///   `git status` stays: in such a folder it stops for lack of a work tree before running anything (checked with
    ///   git 2.54 and 2.56). Neither it nor the listed `git branch` forms run diff or signature helpers.
    ///
    /// A pattern ending in ` *` also matches the bare command.
    public static let autoAllowedShell: [String] = [
        "ls *", "pwd", "which *", "cat *", "head *", "tail *", "wc *", "echo *", "grep *", "rg *", "find *",
        "git status *",
        "git branch", "git branch -a", "git branch -r", "git branch -v", "git branch -vv", "git branch --list",
        "git branch --show-current",
    ]

    /// Forms of the allowed commands that can still change things or run other programs; these ask again (checked
    /// after the allow list).
    public static let autoAskAgainShell: [String] = [
        "find * -delete*", "find * -exec*", "find * -execdir*", "find * -ok*", "find * -okdir*",
        "find * -fprint*", "find * -fls*",
        "rg *--pre*",
        "*--output*",
        "*>*",
        "*$(*", "*`*",
    ]

    /// `edit` patterns for any path with a segment that starts with a dot: `.git`, `.github`, `.husky`, `.vscode`,
    /// `.devcontainer`, `.idea`, `.circleci`, `.cargo`, `.envrc`, `.gitlab-ci.yml`, `.pre-commit-config.yaml`,
    /// `.lefthook.yml`, `.lintstagedrc*`, `.gitmodules`, `.gitattributes`, `.npmrc`, `.yarnrc*`, `.tool-versions`
    /// and every dot-config yet to come. A dot has no case, so a mixed-case spelling (`.GiT/hooks/pre-commit`) is
    /// still caught. `.*` covers the top of the folder, `*/.*` any subfolder and absolute paths.
    public static let dotPathEditPatterns: [String] = [".*", "*/.*"]

    /// `edit` patterns for paths containing a character that HFS+ disks drop from file names (zero-width and
    /// direction marks, the byte order mark), so `\u{200C}.git` is `.git` there. Nobody names files this way.
    public static let ignorableCharacterEditPatterns: [String] = (
        Array(0x200C...0x200F) + Array(0x202A...0x202E) + Array(0x206A...0x206F) + [0xFEFF]
    ).compactMap { code in Unicode.Scalar(code).map { scalar in "*\(Character(scalar))*" } }

    /// Build and hook files without a leading dot whose edits ask even when edits are allowed: they change what build
    /// and test commands run, or run code later outside the agent (git hook managers, CI, toolchain pins).
    ///
    /// This is a heads-up for the usual spellings, not a boundary. OpenCode cannot match a name in any case, so
    /// `PaCkAgE.json` is not caught; Auto asks before every command that runs project code instead.
    public static let protectedFileNames: [String] = [
        // make, CMake, Meson, Bazel
        "Makefile", "makefile", "GNUmakefile", "*.mk", "CMakeLists.txt", "*.cmake", "meson.build",
        "BUILD.bazel", "WORKSPACE", "MODULE.bazel", "*.bzl",
        // JavaScript
        "package.json", "pnpm-workspace.yaml", "lint-staged.config.*", "deno.json", "deno.jsonc", "bunfig.toml",
        // Python
        "pyproject.toml", "setup.py", "setup.cfg", "conftest.py", "tox.ini", "noxfile.py", "pytest.ini",
        // Rust and Go
        "Cargo.toml", "build.rs", "rust-toolchain", "rust-toolchain.toml", "go.mod", "go.work",
        // Swift and Xcode
        "Package.swift", "*.pbxproj", "*.xcscheme", "*.xcconfig", "project.yml",
        // Ruby, PHP, JVM, task runners
        "Podfile", "Gemfile", "*.gemspec", "Rakefile", "composer.json", "justfile", "Justfile", "Taskfile*",
        "build.gradle*", "settings.gradle*", "gradle.properties", "gradlew", "gradle-wrapper.properties",
        "pom.xml", "mvnw",
        // Git hook managers and CI without a dot
        "lefthook.yml", "lefthook.yaml", "lefthook-local.yml", "lefthook-local.yaml", "Jenkinsfile",
        "azure-pipelines.yml", "bitbucket-pipelines.yml",
        // Environment and toolchain managers
        "mise.toml", "Brewfile", "flake.nix", "shell.nix", "devbox.json",
    ]

    /// `edit` patterns for the protected files: each name at the top of the folder and in any subfolder (the
    /// `*/` form also covers absolute paths), in its usual, lower-case, upper-case and capitalised spellings.
    public static let protectedEditPatterns: [String] = {
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
                add(spelling)
                if !spelling.hasPrefix("*") { add("*/" + spelling) }
            }
        }
        return patterns
    }()

    /// The session ruleset for a permission mode.
    ///
    /// - Ask: reads and searches run; edits, commands, web access, Code Mode, image generation, work outside the
    ///   project folder and any other tool (MCP included) ask.
    /// - Accept edits: as Ask, but file edits inside the project run, except paths with a segment that starts with a
    ///   dot and the protected build files.
    /// - Auto: safe commands run, everything else asks. As Accept edits, plus the read-only commands in
    ///   `autoAllowedShell` run (minus the forms in `autoAskAgainShell`).
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
            rules += (dotPathEditPatterns + ignorableCharacterEditPatterns + protectedEditPatterns)
                .map { PermissionRule("edit", $0, "ask") }
        }
        return rules
    }

    /// Best guess of the mode a ruleset came from (for sessions created elsewhere). `nil` when it does not match.
    public static func mode(for rules: [PermissionRule]) -> PermissionMode? {
        if rules.isEmpty { return nil }
        return PermissionMode.allCases.first { ruleset(for: $0) == rules }
    }

    /// The mode of a ruleset that an earlier Ensemble version wrote for Ask, Accept edits or Auto (it starts with a
    /// catch-all ask and allows subagents) but that differs from today's ruleset for that mode. Such a session keeps
    /// its old rules until its mode is set again, so the caller should reapply `ruleset(for:)` with this mode.
    /// `nil` for current rulesets and for rules Ensemble did not write.
    public static func outdatedMode(for rules: [PermissionRule]) -> PermissionMode? {
        guard mode(for: rules) == nil, rules.first == PermissionRule("*", "*", "ask"),
              rules.contains(PermissionRule("subagent", "*", "allow")),
              let edit = rules.last(where: { $0.action == "edit" && $0.resource == "*" }) else { return nil }
        if edit.effect == "ask" { return .ask }
        guard edit.effect == "allow" else { return nil }
        return rules.contains { $0.action == "shell" && $0.effect == "allow" } ? .auto : .acceptEdits
    }

    /// What a ruleset decides for one action and resource, using OpenCode's matching: the last matching rule wins,
    /// `*` matches any run of characters (including `/` and spaces), `?` matches one character, every other
    /// character is literal and case matters, backslashes count as `/`, and a pattern ending in ` *` also matches
    /// without the tail. With no match the engine falls back to the agent's rules, which allow everything for the
    /// built-in agents; this returns `"agent"` then.
    /// Used to preview and test rulesets; the engine makes the real decision.
    public static func effect(action: String, resource: String, rules: [PermissionRule]) -> String {
        var result = "agent"
        for rule in rules where engineMatch(rule.action, action) && engineMatch(rule.resource, resource) {
            result = rule.effect
        }
        return result
    }

    /// OpenCode's `Wildcard.match`: backslashes become `/` on both sides, then `wildcardMatch`, where a pattern ending
    /// in ` *` also matches the value without that tail (`ls *` matches `ls`).
    static func engineMatch(_ pattern: String, _ value: String) -> Bool {
        let pattern = pattern.replacingOccurrences(of: "\\", with: "/")
        let value = value.replacingOccurrences(of: "\\", with: "/")
        if wildcardMatch(pattern, value) { return true }
        return pattern.hasSuffix(" *") && wildcardMatch(String(pattern.dropLast(2)), value)
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
