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
/// - Project files OpenCode reads, from the session's folder and every folder above it: `opencode.json` and
///   `opencode.jsonc` (found by a case-insensitive directory listing, so `OpenCode.json` counts), `.opencode/`
///   (config, agents, modes, commands, plugins, tools, skills), `.claude/` and `.agents/` (skills), and `AGENTS.md`
///   (instructions). Config is reloaded as soon as a loaded file changes, and it can run code without any further
///   permission: a `formatter` command runs after the next file edit (checked live), local MCP servers and LSP
///   servers are started, plugins load into the engine, commands can run shell lines, custom tools run. `AGENTS.md`
///   only adds instructions.
/// - The only switch for project config is the engine process's environment: `OPENCODE_DISABLE_PROJECT_CONFIG=1`
///   (alias `OPENCODE_CONFIG_PROJECT_DISABLE`) stops all of the above being read from project folders (checked live
///   with a private `opencode serve`). It is read once at start and applies to every folder that process serves;
///   there is no per-session or per-folder setting. For the background service: `opencode service set env
///   OPENCODE_DISABLE_PROJECT_CONFIG 1`, then `opencode service restart`.
/// - OpenCode's own git calls pass `-c core.fsmonitor=false`, `core.hooksPath=/dev/null` and `--no-ext-diff`;
///   a `git` command the agent runs gets none of that.
/// - Code Mode (`execute`) is only blocked by `deny`; with `ask` it runs, and each tool it calls is checked on its own
///   (its `fetch` asks as `webfetch`).
/// - A subagent's child session copies the parent's ruleset when it is created (no race), but does not follow later
///   changes to the parent, so `OpenCodeClient.setPermissionMode` updates child sessions too.
public enum PermissionRules {
    /// Shell commands Auto mode runs without asking: commands that only read, and never run code that the project
    /// (or an agent's edit) controls. Every other command asks.
    ///
    /// Left out on purpose:
    /// - Every `git` command. A repository's config can make git run programs (`core.fsmonitor` on `git status`,
    ///   textconv, external diff and signature helpers on `git diff`, `git log` and `git show`, filters, pagers),
    ///   and no `-c` list can switch them all off. Ordinary files (`HEAD`, `config`, `refs/`,
    ///   `objects/info/alternates`, `info/attributes`) make any folder a repository, and `cd folder && git show` then
    ///   runs its helpers (reproduced) because OpenCode does not check `cd`.
    /// - Build, test and task runners (`make`, `npm test`, `swift build`, `xcodebuild`, `pytest`, `cargo test`,
    ///   `go test`, `gradle`, ...). They run code the project defines, and an edit to their build file is allowed
    ///   in Auto when the name is spelt in a case `protectedFileNames` does not list (`PaCkAgE.json`), so the
    ///   command is where Ensemble asks.
    ///
    /// A pattern ending in ` *` also matches the bare command.
    public static let autoAllowedShell: [String] = [
        "ls *", "pwd", "which *", "cat *", "head *", "tail *", "wc *", "echo *", "grep *", "rg *", "find *",
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

    /// `edit` patterns for OpenCode's own config in the session's folder, `opencode.json` and `opencode.jsonc`, in
    /// every spelling: any 8-character name with a 4- or 5-character extension. OpenCode finds these names
    /// without regard to case and reloads them at once, and a changed config can run commands (see the type notes),
    /// so the usual spellings are not enough. `?` stands for any one character, so the shape is the only thing a
    /// pattern can pin down. Other names of that shape at the top of the folder ask too (`firebase.json`,
    /// `manifest.json`), except `configLookalikesAllowed`.
    ///
    /// Only the top of the folder: OpenCode reads config from the session's folder and the folders above it (those
    /// are outside the project, so their edits ask anyway). Configs in subfolders only matter to a session started
    /// in that subfolder; they ask in their usual spellings (`protectedFileNames`). The same shape in every subfolder
    /// would also catch `Contents.json` in every asset catalogue and any `MainView.swift`. `.opencode/`, `.claude/`
    /// and `.agents/` ask through the dot rule.
    public static let opencodeConfigEditPatterns: [String] = ["????????.????", "????????.?????"]

    /// Exact names of the `opencodeConfigEditPatterns` shape that are common and cannot be OpenCode's config in any
    /// spelling, so their edits stay allowed.
    public static let configLookalikesAllowed: [String] = ["tsconfig.json", "jsconfig.json"]

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
        // OpenCode config in subfolders (any spelling at the top of the folder: `opencodeConfigEditPatterns`)
        "opencode.json", "opencode.jsonc",
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
    /// - Accept edits: as Ask, but file edits inside the project run, except OpenCode's config (any spelling), paths
    ///   with a segment that starts with a dot, and the protected build files.
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
            // Order matters (the last match wins): the lookalike exceptions only undo the config shape, and every
            // later ask still applies to them.
            rules += opencodeConfigEditPatterns.map { PermissionRule("edit", $0, "ask") }
            rules += configLookalikesAllowed.map { PermissionRule("edit", $0, "allow") }
            rules += (dotPathEditPatterns + ignorableCharacterEditPatterns + protectedEditPatterns)
                .map { PermissionRule("edit", $0, "ask") }
        }
        return rules
    }

    // MARK: Room worktrees

    /// Where Team rooms put each agent's git worktree, relative to the room's folder (see `ProcessGitOps`).
    public static let worktreeFolder = ".ensemble/worktrees"

    /// The ruleset for a permission mode, for a Team agent that works in its own git worktree: in Accept edits and
    /// Auto, `ruleset(for:)` plus `worktreeEditRules(worktree)`. Ask and Bypass, and a path that is not a worktree
    /// folder, get `ruleset(for:)` unchanged.
    /// `repoPrefix` is the room folder's place inside its repository (`git rev-parse --show-prefix`, without the
    /// trailing slash; empty at the top), so config files are protected at every folder the merged branch can reach.
    public static func ruleset(for mode: PermissionMode, worktree: String?, repoPrefix: String = "") -> [PermissionRule] {
        let rules = ruleset(for: mode)
        guard let worktree, mode == .acceptEdits || mode == .auto,
              let extra = worktreeEditRules(worktree, repoPrefix: repoPrefix) else { return rules }
        return rules + extra
    }

    /// `edit` rules that let a Team agent edit its own worktree the way its mode edits the project. Appended after a
    /// mode's ruleset (the last match wins).
    ///
    /// Worktrees live in `.ensemble/worktrees/<branch>` inside the room's folder, so `dotPathEditPatterns` makes every
    /// edit in them ask. These rules allow `<worktree>/*`, then ask again for everything the mode protects, spelt
    /// inside the worktree, because the branch is merged into the project afterwards: OpenCode's config shape at the
    /// worktree's top (except the lookalikes), every path with a dot segment inside it (its `.git` file, `.github`,
    /// `.claude`, `.opencode`, ...), and the ignorable-character and protected-file patterns that can match paths in it
    /// (those starting with `*`; the others match only names at the top of the project). Paths outside this worktree,
    /// other agents' worktrees included, keep the mode's rules. `nil` unless `worktree` is
    /// `.ensemble/worktrees/<name>` with a plain name, so the allow can never cover a real dot folder.
    ///
    /// The worktree is a whole checkout of the repository, and its branch is merged back at the repository's top. So
    /// OpenCode's config shape asks at the worktree's top and at every folder from there down to the room's folder
    /// (`repoPrefix`): after the merge those are the room's folder and its parents, which OpenCode reads config from.
    public static func worktreeEditRules(_ worktree: String, repoPrefix: String = "") -> [PermissionRule]? {
        guard isWorktreeFolder(worktree), let levels = configLevels(repoPrefix) else { return nil }
        var rules = [PermissionRule("edit", worktree + "/*", "allow")]
        for level in levels {
            let base = level.isEmpty ? worktree : worktree + "/" + level
            rules += opencodeConfigEditPatterns.map { PermissionRule("edit", base + "/" + $0, "ask") }
            rules += configLookalikesAllowed.map { PermissionRule("edit", base + "/" + $0, "allow") }
        }
        rules += dotPathEditPatterns.map { PermissionRule("edit", worktree + "/" + $0, "ask") }
        rules += (ignorableCharacterEditPatterns + protectedEditPatterns.filter { $0.hasPrefix("*") })
            .map { PermissionRule("edit", $0, "ask") }
        return rules
    }

    /// `""` and then each folder from the repository's top down to `repoPrefix` (`"a"`, `"a/b"`), or nil when the
    /// prefix is not plain folder names (wildcard characters would change what the rules match).
    static func configLevels(_ repoPrefix: String) -> [String]? {
        let parts = repoPrefix.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("*") && !$0.contains("?") }) else { return nil }
        var levels = [""]
        var current = ""
        for part in parts {
            current = current.isEmpty ? part : current + "/" + part
            levels.append(current)
        }
        return levels
    }

    /// True for `.ensemble/worktrees/<name>` where the name is ASCII letters, digits, `-`, `_` and `.`, and does not
    /// start with a dot.
    public static func isWorktreeFolder(_ path: String) -> Bool {
        let prefix = worktreeFolder + "/"
        guard path.hasPrefix(prefix) else { return false }
        let name = path.dropFirst(prefix.count)
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
    }

    /// The worktree a Team agent's ruleset allows (`ruleset(for:worktree:)`), or nil.
    public static func worktree(in rules: [PermissionRule]) -> String? {
        for mode in [PermissionMode.acceptEdits, .auto] {
            let base = ruleset(for: mode)
            guard rules.count > base.count, Array(rules.prefix(base.count)) == base else { continue }
            let first = rules[base.count]
            guard first.action == "edit", first.effect == "allow", first.resource.hasSuffix("/*") else { continue }
            let worktree = String(first.resource.dropLast(2))
            let extraRules = Array(rules.dropFirst(base.count))
            if let extra = worktreeEditRules(worktree, repoPrefix: repoPrefix(in: extraRules, worktree: worktree)),
               extraRules == extra { return worktree }
        }
        return nil
    }

    /// The deepest folder that has config ask rules inside `worktree`: the room folder's place in its repository.
    static func repoPrefix(in rules: [PermissionRule], worktree: String) -> String {
        let marker = opencodeConfigEditPatterns[0]
        var deepest = ""
        for rule in rules where rule.action == "edit" && rule.effect == "ask" && rule.resource.hasPrefix(worktree + "/") {
            let rest = String(rule.resource.dropFirst(worktree.count + 1))
            guard rest != marker, rest.hasSuffix("/" + marker) else { continue }
            let level = String(rest.dropLast(marker.count + 1))
            if level.count > deepest.count { deepest = level }
        }
        return deepest
    }

    /// Best guess of the mode a ruleset came from (for sessions created elsewhere). `nil` when it does not match.
    /// A Team agent's ruleset with its worktree rules counts as its mode.
    public static func mode(for rules: [PermissionRule]) -> PermissionMode? {
        if rules.isEmpty { return nil }
        if let mode = PermissionMode.allCases.first(where: { ruleset(for: $0) == rules }) { return mode }
        guard let worktree = worktree(in: rules) else { return nil }
        let prefix = repoPrefix(in: rules, worktree: worktree)
        return [PermissionMode.acceptEdits, .auto].first { ruleset(for: $0, worktree: worktree, repoPrefix: prefix) == rules }
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
