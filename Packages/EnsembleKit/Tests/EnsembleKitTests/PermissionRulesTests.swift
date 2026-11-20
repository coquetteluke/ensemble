import Testing
@testable import EnsembleKit

@Suite struct PermissionRulesTests {
    private func shell(_ command: String, _ mode: PermissionMode) -> String {
        PermissionRules.effect(action: "shell", resource: command, rules: PermissionRules.ruleset(for: mode))
    }

    private func effect(_ action: String, _ resource: String, _ mode: PermissionMode) -> String {
        PermissionRules.effect(action: action, resource: resource, rules: PermissionRules.ruleset(for: mode))
    }

    /// Every permission action OpenCode 2.3 uses (from its docs and binary), plus an MCP tool and a made-up one.
    static let engineActions = [
        "read", "glob", "grep", "edit", "shell", "webfetch", "websearch", "external_directory", "subagent", "skill",
        "question", "execute", "experimental_image_generate", "browser", "opencode_list_mcp_resources",
        "opencode_read_mcp_resource", "opencode_watch_mcp_event", "github_create_issue", "some_future_tool",
    ]

    /// Commands that run code the project defines. Auto must ask before each of them.
    static let projectCodeCommands = [
        "npm test", "npm test -- --watch=false", "npm run build", "npm run test", "pnpm test", "pnpm run build",
        "pnpm build", "yarn test", "yarn run build", "yarn build", "bun test", "bun run build", "bun run dev",
        "make", "make all", "make build", "make test", "make check", "make lint", "make -j8", "just", "just test",
        "task build", "rake", "rake test", "bundle exec rspec", "bundle exec rake",
        "pytest", "pytest -q", "python -m pytest", "python3 -m pytest tests", "tox", "tox -e py312", "nox",
        "cargo build", "cargo build --release", "cargo test", "cargo run", "cargo check",
        "swift build", "swift build -c release", "swift test", "swift run", "xcodebuild -scheme App build",
        "go test ./...", "go build ./...", "go run .", "go vet ./...", "gradle build", "./gradlew test", "gradlew build",
        "mvn test", "./mvnw package",
    ]

    /// Git runs programs named in a repository's config (`core.fsmonitor`, textconv, external diff, filters).
    static let gitCommands = [
        "git status", "git status --short", "git branch", "git branch -a", "git branch --show-current", "git diff",
        "git diff HEAD~1", "git log --oneline -5", "git log -p", "git show HEAD", "git show --stat", "git rev-parse HEAD",
        "git -c core.fsmonitor=false status", "git -c core.fsmonitor=false -c core.hooksPath=/dev/null status",
    ]

    /// Every spelling of OpenCode's config at the top of the folder, nested configs in their usual spellings, and the
    /// project folders OpenCode loads plugins, commands, tools, agents and skills from.
    static let opencodeConfigPaths = [
        "opencode.json", "opencode.jsonc", "OpenCode.json", "OPENCODE.JSON", "OpEnCoDe.jsonc", "OPENCODE.JSONC",
        "opencode.JSON", "opencode.j\u{17F}on", "\u{200C}opencode.json",
        "sub/opencode.json", "sub/OPENCODE.JSON", "sub/Opencode.json", "packages/a/opencode.jsonc", "/Users/me/opencode.json",
        ".opencode/opencode.json", ".OpenCode/opencode.jsonc", ".opencode/plugins/x.ts", ".opencode/plugin/x.js",
        ".opencode/command/deploy.md", ".opencode/commands/x.md", ".opencode/tools/t.ts", ".opencode/agent/a.md",
        ".opencode/skills/x/SKILL.md", ".claude/skills/x/SKILL.md", ".Claude/commands/x.md", ".agents/skills/x/SKILL.md",
        "sub/.opencode/plugins/x.ts",
    ]

    /// Dot paths in many spellings, at the top, nested and absolute.
    static let dotPaths = [
        ".git/hooks/pre-commit", ".GiT/hooks/pre-commit", ".GIT/config", ".git/info/attributes", "sub/.GiT/hooks/post-merge",
        "/Users/me/repo/.GiT/hooks/post-merge", "/Users/me/repo/.git/config",
        ".github/workflows/ci.yml", ".GitHub/Workflows/CI.yml", "sub/.GITHUB/workflows/x.yaml", ".github/dependabot.yml",
        ".husky/pre-commit", ".HUSKY/pre-commit", "apps/web/.husky/pre-push", ".vscode/tasks.json", ".VSCode/settings.json",
        ".devcontainer/devcontainer.json", ".idea/workspace.xml", ".circleci/config.yml", ".buildkite/pipeline.yml",
        ".travis.yml", ".gitlab-ci.yml", ".GitLab-CI.yml", "sub/.gitlab-ci.yml",
        ".envrc", ".EnvRc", "apps/web/.envrc", ".pre-commit-config.yaml", ".Pre-Commit-Config.YAML", ".lefthook.yml",
        ".lefthook-local.yml", ".lintstagedrc", ".lintstagedrc.json", ".LintStagedRC.js", ".gitmodules", ".GitModules",
        ".gitattributes", "sub/dir/.GitAttributes", ".npmrc", ".NPMRC", "web/.npmrc", ".yarnrc", ".yarnrc.yml",
        ".pnpmfile.cjs", ".tool-versions", ".python-version", ".node-version", ".nvmrc", ".mise.toml",
        ".cargo/config", ".cargo/config.toml", ".Cargo/Config.toml", "crates/a/.cargo/config.toml",
        ".gitignore", ".env.example", "a/b/c/.d/e.txt",
    ]

    /// Non-dot build and hook files in their usual spellings.
    static let protectedBuildFiles = [
        "Makefile", "makefile", "MAKEFILE", "GNUmakefile", "rules.mk", "sub/dir/Makefile", "/Users/me/elsewhere/Makefile",
        "CMakeLists.txt", "src/CMakeLists.txt", "cmake/tools.cmake", "meson.build", "BUILD.bazel", "WORKSPACE",
        "MODULE.bazel", "tools/defs.bzl",
        "package.json", "web/package.json", "Package.json", "PACKAGE.JSON", "pnpm-workspace.yaml", "lint-staged.config.js",
        "deno.json", "bunfig.toml",
        "pyproject.toml", "setup.py", "setup.cfg", "tests/conftest.py", "tox.ini", "noxfile.py", "pytest.ini",
        "Cargo.toml", "crates/a/Cargo.toml", "crates/a/build.rs", "rust-toolchain", "rust-toolchain.toml", "go.mod", "go.work",
        "Package.swift", "PACKAGE.SWIFT", "Packages/EnsembleKit/Package.swift", "App.xcodeproj/project.pbxproj",
        "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", "Config/Base.xcconfig", "project.yml",
        "Podfile", "Gemfile", "app.gemspec", "Rakefile", "composer.json", "justfile", "Justfile", "Taskfile.yml",
        "build.gradle", "app/build.gradle.kts", "settings.gradle.kts", "gradle.properties", "gradlew",
        "gradle/wrapper/gradle-wrapper.properties", "pom.xml", "mvnw",
        "lefthook.yml", "Lefthook.yml", "LEFTHOOK.YML", "lefthook-local.yaml", "Jenkinsfile", "azure-pipelines.yml",
        "bitbucket-pipelines.yml",
        "mise.toml", "Brewfile", "flake.nix", "shell.nix", "devbox.json",
    ]

    @Test func onlyBypassStartsFromAllowAll() {
        for mode in [PermissionMode.ask, .acceptEdits, .auto] {
            let rules = PermissionRules.ruleset(for: mode)
            #expect(rules.first == PermissionRule("*", "*", "ask"), "\(mode) must start with a catch-all ask")
            #expect(!rules.contains(PermissionRule("*", "*", "allow")))
            // Nothing falls through to the agent's allow-all default.
            for action in Self.engineActions {
                #expect(effect(action, "anything", mode) != "agent", "\(action) falls through in \(mode)")
            }
        }
        #expect(PermissionRules.ruleset(for: .bypass) == [PermissionRule("*", "*", "allow")])
    }

    @Test func unknownAndMCPToolsAsk() {
        for mode in [PermissionMode.ask, .acceptEdits, .auto] {
            #expect(effect("github_create_issue", "*", mode) == "ask")
            #expect(effect("some_future_tool", "x", mode) == "ask")
            #expect(effect("opencode_read_mcp_resource", "server:file://x", mode) == "ask")
            #expect(effect("websearch", "query", mode) == "ask")
            #expect(effect("webfetch", "https://example.com", mode) == "ask")
            #expect(effect("execute", "*", mode) == "ask")
            #expect(effect("experimental_image_generate", "openai/gpt-image", mode) == "ask")
            #expect(effect("external_directory", "/Users/me/other/*", mode) == "ask")
            #expect(effect("browser", "*", mode) == "deny")
            #expect(effect("skill", "browser", mode) == "deny")
            #expect(effect("skill", "opencode", mode) == "allow")
            #expect(effect("subagent", "general", mode) == "allow")
            #expect(effect("question", "*", mode) == "allow")
            #expect(effect("read", "Sources/App.swift", mode) == "allow")
            #expect(effect("read", ".env", mode) == "ask")
            #expect(effect("read", "config/.env.local", mode) == "ask")
            #expect(effect("read", ".env.example", mode) == "allow")
            #expect(effect("glob", "**/*.swift", mode) == "allow")
            #expect(effect("grep", "TODO", mode) == "allow")
        }
    }

    @Test func ensembleToolsDoNotAskTwice() {
        let readOrPropose = [
            "ensemble_propose_session",
            "ensemble_browser_snapshot",
            "ensemble_browser_screenshot",
            "ensemble_browser_console",
            "ensemble_list_agents",
            "ensemble_ask_agent",
        ]
        let mutating = [
            "ensemble_browser_navigate",
            "ensemble_browser_click",
            "ensemble_browser_type",
            "ensemble_browser_scroll",
            "ensemble_message_agent",
        ]
        #expect(Set(readOrPropose + mutating) == Set(PermissionRules.ensembleToolActions))
        for mode in [PermissionMode.ask, .acceptEdits, .auto, .bypass] {
            for tool in readOrPropose + mutating {
                #expect(effect(tool, "*", mode) == "allow", "\(tool) should not ask OpenCode in \(mode)")
            }
        }
        for tool in readOrPropose {
            #expect(effect(tool, "*", .plan) == "allow", "\(tool) should be allowed in Plan")
        }
        for tool in mutating {
            #expect(effect(tool, "*", .plan) == "deny", "\(tool) should stay denied in Plan")
        }
        // Unrelated MCP tools, including third-party servers with an `ensemble_` prefix, must never auto-allow.
        for unknown in ["github_create_issue", "ensemble_evil_tool", "ensemble_other_future", "ensemble_shell"] {
            for mode in [PermissionMode.ask, .acceptEdits, .auto] {
                #expect(effect(unknown, "*", mode) == "ask", "\(unknown) must ask in \(mode)")
            }
            #expect(effect(unknown, "*", .plan) == "deny", "\(unknown) must be denied in Plan")
        }
        // No mode outside Bypass contains an `ensemble_*` wildcard rule.
        for mode in [PermissionMode.ask, .acceptEdits, .auto, .plan] {
            #expect(!PermissionRules.ruleset(for: mode).contains { $0.action == "ensemble_*" })
        }
    }

    @Test func autoAsksForCommandsOutsideTheSafeList() {
        for command in [
            "rm -r -f x", "rm -rf x", "/bin/rm -rf x", "python3 -c \"import os; os.remove('x')\"", "node -e \"1\"", "perl -e 1",
            "find . -delete", "find . -name '*.tmp' -delete", "find . -exec rm {} ;", "git push origin +main", "git push --force",
            "git reset --hard", "git branch -D main", "sudo ls", "curl https://example.com", "sh", "echo hi > out.txt",
            "ls --output=/tmp/x", "rg --pre ./script foo", "make install", "npm install", "chmod -R 777 .",
            "git -c core.fsmonitor=./x status", "git --git-dir=evil status", "git -C evil show HEAD", "env GIT_DIR=evil git status",
            "sh ./script.sh", "./script.sh", "bash -c 'ls'", "npx vitest", "node scripts/build.js",
        ] {
            #expect(shell(command, .auto) == "ask", "\(command) should ask in Auto")
        }
    }

    /// OpenCode keeps `VAR=value` prefixes in the checked command, so they never match the allow list.
    @Test func autoAsksForCommandsWithEnvironmentPrefixes() {
        for command in ["GIT_EXTERNAL_DIFF=./x git status", "GIT_DIR=evil git status", "FOO=1 ls", "PAGER=./x git branch"] {
            #expect(shell(command, .auto) == "ask", "\(command) should ask in Auto")
        }
    }

    @Test func autoAsksBeforeCommandsThatRunProjectCode() {
        for command in Self.projectCodeCommands {
            #expect(shell(command, .auto) == "ask", "\(command) runs project code and should ask in Auto")
            #expect(shell(command, .acceptEdits) == "ask")
            #expect(shell(command, .ask) == "ask")
        }
        // Nothing on the allow list is a build, test or task runner, or git.
        for pattern in PermissionRules.autoAllowedShell {
            let tool = pattern.split(separator: " ").first.map(String.init) ?? ""
            #expect(["ls", "pwd", "which", "cat", "head", "tail", "wc", "echo", "grep", "rg", "find"].contains(tool), "\(pattern)")
        }
    }

    @Test func autoAsksForEveryGitCommand() {
        for command in Self.gitCommands {
            #expect(shell(command, .auto) == "ask", "\(command) should ask in Auto")
        }
        #expect(!PermissionRules.autoAllowedShell.contains { $0.hasPrefix("git") })
    }

    @Test func autoRunsReadOnlyCommands() {
        for command in [
            "ls", "ls -la", "pwd", "cat README.md", "head -5 a.txt", "tail -n 2 a.txt", "grep -rn foo .", "rg foo", "find . -name '*.swift'",
            "echo hello", "wc -l file.txt", "which swift",
        ] {
            #expect(shell(command, .auto) == "allow", "\(command) should run in Auto")
        }
    }

    @Test func dotPathsAskInEveryCaseWhenEditsAreAllowed() {
        for mode in [PermissionMode.acceptEdits, .auto] {
            for path in Self.dotPaths {
                #expect(effect("edit", path, mode) == "ask", "\(path) should ask in \(mode)")
            }
            // A dot inside a name, or a folder with a dot in the middle, is not a dot path.
            for path in ["Sources/App.swift", "src/v1.2/x.txt", "a.b/c.txt", "file.", "docs/dot.md", "notes/env.txt"] {
                #expect(effect("edit", path, mode) == "allow", "\(path) should be editable in \(mode)")
            }
        }
    }

    @Test func opencodeConfigAsksInEverySpelling() {
        for mode in [PermissionMode.acceptEdits, .auto] {
            for path in Self.opencodeConfigPaths {
                #expect(effect("edit", path, mode) == "ask", "\(path) should ask in \(mode)")
            }
            // Other names of the same shape at the top of the folder ask too; that is the cost of matching any case.
            for path in ["firebase.json", "manifest.json", "renovate.json", "metadata.jsonc"] {
                #expect(effect("edit", path, mode) == "ask", "\(path) should ask in \(mode)")
            }
            // Agent instruction files ask at any depth (W4-C protects them).
            for path in ["AGENTS.md", "sub/AGENTS.md", "CLAUDE.md", "GEMINI.md"] {
                #expect(effect("edit", path, mode) == "ask", "\(path) should ask in \(mode)")
            }
            // Common lookalikes, and the same shape in subfolders, stay editable.
            for path in ["tsconfig.json", "jsconfig.json", "Assets.xcassets/Contents.json",
                         "Sources/App/MainView.swift", "packages/web/tsconfig.json", "docs/opencode.md", "opencode.json.bak",
                         "sub/manifest.json"] {
                #expect(effect("edit", path, mode) == "allow", "\(path) should be editable in \(mode)")
            }
        }
        // Outside the project the edit also needs external_directory, which asks.
        #expect(effect("external_directory", "/Users/me/*", .auto) == "ask")
        // The lookalike exceptions sit after the config shape and before every other ask.
        let rules = PermissionRules.ruleset(for: .auto)
        let shape = rules.lastIndex(of: PermissionRule("edit", "????????.????", "ask"))
        let lookalike = rules.firstIndex(of: PermissionRule("edit", "tsconfig.json", "allow"))
        let dot = rules.firstIndex(of: PermissionRule("edit", ".*", "ask"))
        #expect(shape != nil && lookalike != nil && dot != nil)
        if let shape, let lookalike, let dot { #expect(shape < lookalike && lookalike < dot) }
    }

    /// HFS+ drops these characters from names, so `\u{200C}.git` is `.git` there.
    @Test func pathsWithInvisibleCharactersAsk() {
        #expect(PermissionRules.ignorableCharacterEditPatterns.count == 16)
        for mode in [PermissionMode.acceptEdits, .auto] {
            for path in ["\u{200C}.git/hooks/pre-commit", "sub/\u{200D}.github/workflows/x.yml", "Make\u{200E}file",
                         "\u{FEFF}.envrc", "a/\u{202E}b.txt", "\u{206A}package.json"] {
                #expect(effect("edit", path, mode) == "ask", "\(path.unicodeScalars.map { String($0.value, radix: 16) }) should ask")
            }
        }
    }

    @Test func protectedBuildFilesAskInTheirUsualSpellings() {
        for mode in [PermissionMode.acceptEdits, .auto] {
            for path in Self.protectedBuildFiles {
                #expect(effect("edit", path, mode) == "ask", "\(path) should ask in \(mode)")
            }
            for path in ["Sources/App.swift", "README.md", "notes/Makefile.txt", "mypackage.json.bak", "src/setup.pyc",
                         "docs/github/workflows.md", "Packages/EnsembleKit/Sources/Package.swift.md", "make.swift"] {
                #expect(effect("edit", path, mode) == "allow", "\(path) should be editable in \(mode)")
            }
        }
    }

    /// OpenCode has no character classes and no case folding, so some spellings of build files are editable in
    /// Auto. Each one still needs a command to run it, and those commands ask.
    @Test func mixedCaseBuildFilesCannotRunWithoutAsking() {
        let pairs: [(file: String, command: String)] = [
            ("PaCkAgE.json", "npm test"), ("web/pAcKaGe.json", "npm run build"), ("MaKeFiLe", "make"),
            ("Ma\u{212A}efile", "make test"), ("sub/CaRgO.toml", "cargo test"), ("PyProject.TOML", "pytest -q"),
            ("cOnFtEsT.py", "python3 -m pytest"), ("PaCkAgE.swift", "swift build"), ("JuStFiLe", "just test"),
            ("bUiLd.GrAdLe", "./gradlew test"), ("PoM.xml", "mvn test"), ("gO.mod", "go test ./..."),
        ]
        for (file, command) in pairs {
            #expect(effect("edit", file, .auto) == "allow", "\(file): if this asks now, update this test")
            #expect(shell(command, .auto) == "ask", "\(command) would run \(file) without asking")
        }
        // `[Mm]` is literal text to OpenCode, so a pattern like this never helps.
        #expect(!PermissionRules.engineMatch("[Mm]akefile", "makefile"))
        #expect(!PermissionRules.protectedEditPatterns.contains { $0.contains("[") })
    }

    @Test func askModeAsksForEveryEdit() {
        #expect(effect("edit", "Sources/App.swift", .ask) == "ask")
        #expect(effect("edit", "Makefile", .ask) == "ask")
        #expect(effect("edit", ".GiT/hooks/pre-commit", .ask) == "ask")
        #expect(effect("edit", "PaCkAgE.json", .ask) == "ask")
        #expect(shell("git status", .ask) == "ask")
    }

    @Test func acceptEditsRunsEditsAndAsksForEveryCommand() {
        #expect(effect("edit", "a.txt", .acceptEdits) == "allow")
        #expect(effect("edit", ".GiT/hooks/pre-commit", .acceptEdits) == "ask")
        #expect(shell("git status", .acceptEdits) == "ask")
        #expect(shell("ls", .acceptEdits) == "ask")
    }

    @Test func bypassAllowsEverything() {
        #expect(shell("rm -rf /tmp/x", .bypass) == "allow")
        #expect(shell("make", .bypass) == "allow")
        #expect(effect("edit", "/etc/hosts", .bypass) == "allow")
        #expect(effect("edit", "Makefile", .bypass) == "allow")
        #expect(effect("edit", ".git/hooks/pre-commit", .bypass) == "allow")
        #expect(effect("read", ".env", .bypass) == "allow")
        #expect(effect("github_create_issue", "*", .bypass) == "allow")
    }

    @Test func recognisesItsOwnRulesets() {
        for mode in PermissionMode.allCases {
            #expect(PermissionRules.mode(for: PermissionRules.ruleset(for: mode)) == mode)
            #expect(PermissionRules.outdatedMode(for: PermissionRules.ruleset(for: mode)) == nil)
        }
        #expect(PermissionRules.mode(for: []) == nil)
    }

    /// Rulesets from earlier versions are recognised so the client can reapply them: the first one (build commands
    /// allowed, no dot rule) and the previous one (git status and branch allowed, no OpenCode config rule).
    @Test func recognisesOutdatedRulesets() {
        let configRules = Set(PermissionRules.opencodeConfigEditPatterns.map { PermissionRule("edit", $0, "ask") }
            + PermissionRules.configLookalikesAllowed.map { PermissionRule("edit", $0, "allow") })
        let dotRules = Set((PermissionRules.dotPathEditPatterns + PermissionRules.ignorableCharacterEditPatterns)
            .map { PermissionRule("edit", $0, "ask") })
        let gitAllows = ["git status *", "git branch", "git branch -a", "git branch -r", "git branch -v", "git branch -vv",
                         "git branch --list", "git branch --show-current"].map { PermissionRule("shell", $0, "allow") }
        let previousAcceptEdits = PermissionRules.ruleset(for: .acceptEdits).filter { !configRules.contains($0) }
        let previousAuto = PermissionRules.ruleset(for: .auto).filter { !configRules.contains($0) } + gitAllows
        let firstAcceptEdits = previousAcceptEdits.filter { !dotRules.contains($0) }
        let firstAuto = PermissionRules.ruleset(for: .auto).filter { !configRules.contains($0) && !dotRules.contains($0) }
            + ["make", "npm test *", "swift build *", "git diff *"].map { PermissionRule("shell", $0, "allow") }
        let oldAsk = PermissionRules.ruleset(for: .ask) + [PermissionRule("edit", "Makefile", "ask")]
        let withoutEnsembleAsk = PermissionRules.ruleset(for: .ask).filter { !$0.action.hasPrefix("ensemble_") }
        let legacyWildcardAsk = withoutEnsembleAsk + [PermissionRule("ensemble_*", "*", "allow")]
        let withoutEnsemblePlan = PermissionRules.ruleset(for: .plan).filter { !$0.action.hasPrefix("ensemble_") }
        for (rules, mode) in [(previousAuto, PermissionMode.auto), (firstAuto, .auto), (previousAcceptEdits, .acceptEdits),
                              (firstAcceptEdits, .acceptEdits), (oldAsk, .ask),
                              (withoutEnsembleAsk, .ask), (legacyWildcardAsk, .ask), (withoutEnsemblePlan, .plan)] {
            #expect(PermissionRules.mode(for: rules) == nil)
            #expect(PermissionRules.outdatedMode(for: rules) == mode)
        }
        // Rules Ensemble did not write are left alone.
        #expect(PermissionRules.outdatedMode(for: []) == nil)
        #expect(PermissionRules.outdatedMode(for: [PermissionRule("*", "*", "allow"), PermissionRule("shell", "rm *", "deny")]) == nil)
        #expect(PermissionRules.outdatedMode(for: [PermissionRule("*", "*", "ask"), PermissionRule("edit", "*", "allow")]) == nil)
    }

    @Test func wildcardMatching() {
        #expect(PermissionRules.wildcardMatch("*", ""))
        #expect(PermissionRules.wildcardMatch("git status *", "git status --short"))
        #expect(!PermissionRules.wildcardMatch("git status *", "git status"))
        #expect(PermissionRules.wildcardMatch("*.env", "config/.env"))
        #expect(PermissionRules.wildcardMatch("*/Makefile", "/abs/path/Makefile"))
        #expect(!PermissionRules.wildcardMatch("*/Makefile", "sub/NotMakefile"))
        #expect(PermissionRules.wildcardMatch("a?c", "abc"))
        #expect(!PermissionRules.wildcardMatch("a?c", "ac"))
        // Case matters and brackets are literal, as in OpenCode.
        #expect(!PermissionRules.wildcardMatch("Makefile", "makefile"))
        #expect(PermissionRules.wildcardMatch("[Mm]akefile", "[Mm]akefile"))
        #expect(!PermissionRules.wildcardMatch("[Mm]akefile", "Makefile"))
        // Dot-path patterns.
        #expect(PermissionRules.wildcardMatch(".*", ".GiT/hooks/x"))
        #expect(PermissionRules.wildcardMatch("*/.*", "/Users/me/repo/.GiT/hooks/x"))
        #expect(!PermissionRules.wildcardMatch("*/.*", "src/v1.2/x"))
        // Backslashes count as `/`, and a trailing " *" also matches the bare command.
        #expect(PermissionRules.engineMatch("*/.*", "sub\\.git\\config"))
        #expect(PermissionRules.engineMatch("ls *", "ls"))
        #expect(!PermissionRules.engineMatch("ls *", "lsof"))
        #expect(PermissionRules.effect(action: "shell", resource: "ls", rules: [PermissionRule("shell", "ls *", "allow")]) == "allow")
        #expect(PermissionRules.effect(action: "shell", resource: "lsof", rules: [PermissionRule("shell", "ls *", "allow")]) == "agent")
    }

    // MARK: Room worktrees

    /// A Team agent in Accept edits or Auto edits its own worktree without asking, while every path the mode
    /// protects still asks, inside its worktree and out, and other agents' worktrees keep asking.
    @Test func teamAgentEditsItsOwnWorktree() {
        let own = ".ensemble/worktrees/ensemble-room-ada"
        for mode in [PermissionMode.acceptEdits, .auto] {
            let rules = PermissionRules.ruleset(for: mode, worktree: own)
            func edit(_ path: String) -> String { PermissionRules.effect(action: "edit", resource: path, rules: rules) }
            for path in ["\(own)/ada.txt", "\(own)/Sources/App/Main.swift", "\(own)/docs/notes.md", "\(own)/tsconfig.json",
                         "\(own)/sub/package-lock.json", "\(own)/README"] {
                #expect(edit(path) == "allow", "\(mode) \(path)")
            }
            let protected = [
                // Real dot folders and files, at the top of the project and inside the worktree.
                ".git/config", ".git/hooks/pre-commit", ".GiT/config", ".github/workflows/ci.yml", ".claude/settings.json",
                ".opencode/plugin/x.ts", ".agents/hooks.json", ".mcp.json", ".envrc", "sub/.husky/pre-push",
                "\(own)/.git", "\(own)/.github/workflows/ci.yml", "\(own)/.claude/settings.json", "\(own)/.opencode/agent.md",
                "\(own)/.agents/hooks.json", "\(own)/.envrc", "\(own)/sub/.husky/pre-push", "\(own)/.ensemble/worktrees/x/a",
                // OpenCode's config shape at the worktree's top, any spelling, and nested configs.
                "\(own)/opencode.json", "\(own)/OpenCode.JSONC", "\(own)/oPeNcOdE.json", "\(own)/sub/opencode.json",
                // Build and hook files.
                "\(own)/Makefile", "\(own)/package.json", "\(own)/sub/Package.swift", "\(own)/project.yml", "\(own)/x.mk",
                "\(own)/App.xcodeproj/project.pbxproj", "\(own)/lefthook.yml",
                // Invisible characters.
                "\(own)/\u{200C}.git/config",
                // Other agents' worktrees, lookalike names, the folder itself and the rest of `.ensemble`.
                ".ensemble/worktrees/ensemble-room-byron/b.txt", ".ensemble/worktrees/ensemble-room-ada-2/a.txt",
                ".ensemble/worktrees/ensemble-room-adb/a.txt", ".ensemble/worktrees/ensemble-room-ada", ".ensemble/config",
            ]
            for path in protected {
                #expect(edit(path) == "ask", "\(mode) \(path)")
            }
            // Everything else is the mode's own ruleset.
            #expect(edit("Sources/a.swift") == "allow")
            #expect(Array(rules.prefix(PermissionRules.ruleset(for: mode).count)) == PermissionRules.ruleset(for: mode))
            #expect(PermissionRules.effect(action: "shell", resource: "rm -rf \(own)", rules: rules) == "ask")
            #expect(PermissionRules.effect(action: "external_directory", resource: "/tmp/*", rules: rules) == "ask")
        }
    }

    /// A room below the repository's top: its worktree is a whole checkout, and the branch merges back at the top, so
    /// OpenCode's config shape asks in every folder from the worktree's top down to the room's folder.
    @Test func worktreeConfigAsksAlongTheRoomsPathInTheRepository() {
        let own = ".ensemble/worktrees/ensemble-room-ada"
        let rules = PermissionRules.ruleset(for: .auto, worktree: own, repoPrefix: "apps/web")
        func edit(_ path: String) -> String { PermissionRules.effect(action: "edit", resource: path, rules: rules) }
        // Any spelling of the folders too: the Mac's file system ignores case.
        for path in ["\(own)/OpenCode.JSON", "\(own)/apps/OpEnCoDe.json", "\(own)/apps/web/OPENCODE.JSONC",
                     "\(own)/apps/web/opencode.json", "\(own)/APPS/WEB/OpenCode.json", "\(own)/Apps/opencode.JSONC"] {
            #expect(edit(path) == "ask", "\(path)")
        }
        for path in ["\(own)/apps/web/index.ts", "\(own)/apps/web/tsconfig.json", "\(own)/apps/web/src/MainView.swift",
                     "\(own)/apps/other/notes.md"] {
            #expect(edit(path) == "allow", "\(path)")
        }
        // Read back as the same worktree and mode, so the launch-time check keeps these rules.
        #expect(PermissionRules.worktree(in: rules) == own)
        #expect(PermissionRules.mode(for: rules) == .auto)
        #expect(PermissionRules.outdatedMode(for: rules) == nil)
        // A prefix with wildcard characters gets no worktree allow at all.
        #expect(PermissionRules.worktreeEditRules(own, repoPrefix: "a*/b") == nil)
        #expect(PermissionRules.worktreeEditRules(own, repoPrefix: "../x") == nil)
        #expect(PermissionRules.worktreeEditRules(own, repoPrefix: "caf\u{E9}") == nil, "non-ASCII folders get no worktree allow")
        // Rules from before shapes (folder names spelt out) are not read as current, so they get rewritten.
        var legacy = PermissionRules.ruleset(for: .auto)
        legacy += [PermissionRule("edit", own + "/*", "allow")]
        for level in ["", "apps", "apps/web"] {
            let base = level.isEmpty ? own : own + "/" + level
            legacy += PermissionRules.opencodeConfigEditPatterns.map { PermissionRule("edit", base + "/" + $0, "ask") }
            legacy += PermissionRules.configLookalikesAllowed.map { PermissionRule("edit", base + "/" + $0, "allow") }
        }
        let tail = Array(rules.drop(while: { !($0.resource.hasPrefix(own + "/.")) || $0.effect != "ask" }))
        legacy += tail
        #expect(PermissionRules.worktree(in: legacy) == nil)
        #expect(PermissionRules.mode(for: legacy) == nil)
        #expect(PermissionRules.outdatedMode(for: legacy) == .auto)
    }

    @Test func worktreeRulesOnlyForWorktreeFoldersAndEditModes() {
        let own = ".ensemble/worktrees/ensemble-room-ada"
        #expect(PermissionRules.ruleset(for: .ask, worktree: own) == PermissionRules.ruleset(for: .ask))
        #expect(PermissionRules.ruleset(for: .bypass, worktree: own) == PermissionRules.ruleset(for: .bypass))
        #expect(PermissionRules.ruleset(for: .auto, worktree: nil) == PermissionRules.ruleset(for: .auto))
        for bad in [".git", ".ensemble/worktrees", ".ensemble/worktrees/", ".ensemble/worktrees/.git", ".ensemble/worktrees/a/b",
                    ".ensemble/worktrees/*", ".ensemble/worktrees/a?", "/abs/.ensemble/worktrees/a", "sub/.ensemble/worktrees/a",
                    ".ensemble/worktrees/..", ".ensemble/worktrees/a b", ".ensemble/worktrees/\u{200C}a", ".ensemble/worktrees/é"] {
            #expect(PermissionRules.worktreeEditRules(bad) == nil, "\(bad)")
            #expect(PermissionRules.ruleset(for: .auto, worktree: bad) == PermissionRules.ruleset(for: .auto), "\(bad)")
        }
    }

    /// The store and the client read a Team agent's rules as its mode, and do not rewrite them as outdated.
    @Test func worktreeRulesetsKeepTheirMode() {
        let own = ".ensemble/worktrees/ensemble-room-ada"
        for mode in [PermissionMode.acceptEdits, .auto] {
            let rules = PermissionRules.ruleset(for: mode, worktree: own)
            #expect(PermissionRules.mode(for: rules) == mode)
            #expect(PermissionRules.outdatedMode(for: rules) == nil)
            #expect(PermissionRules.worktree(in: rules) == own)
        }
        #expect(PermissionRules.worktree(in: PermissionRules.ruleset(for: .auto)) == nil)
        // A tampered tail is not recognised.
        var tampered = PermissionRules.ruleset(for: .auto, worktree: own)
        tampered.removeLast()
        #expect(PermissionRules.mode(for: tampered) == nil)
        #expect(PermissionRules.worktree(in: tampered) == nil)
        let wider = PermissionRules.ruleset(for: .auto) + [PermissionRule("edit", ".git/*", "allow")]
        #expect(PermissionRules.mode(for: wider) == nil)
    }
}
