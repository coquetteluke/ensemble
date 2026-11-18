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

    @Test func autoAsksForCommandsOutsideTheSafeList() {
        for command in [
            "rm -r -f x", "rm -rf x", "/bin/rm -rf x", "python3 -c \"import os; os.remove('x')\"", "node -e \"1\"", "perl -e 1",
            "find . -delete", "find . -name '*.tmp' -delete", "find . -exec rm {} ;", "git push origin +main", "git push --force",
            "git reset --hard", "git branch -D main", "sudo ls", "curl https://example.com", "sh", "echo hi > out.txt",
            "git log --output=/tmp/x", "rg --pre ./script foo", "make install", "npm install", "chmod -R 777 .",
        ] {
            #expect(shell(command, .auto) == "ask", "\(command) should ask in Auto")
        }
    }

    @Test func autoRunsSafeCommands() {
        for command in [
            "git status", "git status --short", "git diff", "git log --oneline -5", "git show HEAD", "git branch",
            "swift test", "swift build -c release", "xcodebuild -scheme App build", "ls", "ls -la", "pwd", "cat README.md",
            "grep -rn foo .", "rg foo", "find . -name '*.swift'", "npm test", "npm run build", "cargo test", "go test ./...",
            "pytest -q", "make", "make test", "echo hello", "wc -l file.txt", "which swift",
        ] {
            #expect(shell(command, .auto) == "allow", "\(command) should run in Auto")
        }
    }

    /// Edit resources are relative to the session folder (`sub/Makefile`); outside it they are absolute.
    @Test func protectedBuildFilesAskWhenEditsAreAllowed() {
        let protected = [
            "Makefile", "makefile", "GNUmakefile", "rules.mk", "sub/dir/Makefile", "/Users/me/elsewhere/Makefile", "MAKEFILE",
            "package.json", "web/package.json", ".npmrc", ".yarnrc", ".yarnrc.yml", "pyproject.toml", "setup.py", "setup.cfg",
            "tests/conftest.py", "tox.ini", "noxfile.py", "pytest.ini", "Cargo.toml", "crates/a/build.rs", ".cargo/config",
            ".cargo/config.toml", "Package.swift", "Packages/EnsembleKit/Package.swift", "App.xcodeproj/project.pbxproj",
            "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", "Config/Base.xcconfig", "project.yml", "Podfile", "Gemfile",
            "Rakefile", "justfile", "Taskfile.yml", "build.gradle", "app/build.gradle.kts", "settings.gradle.kts",
            "gradle.properties", "pom.xml", ".git/hooks/pre-commit", ".git/config", "/Users/me/repo/.git/hooks/post-merge",
            ".github/workflows/ci.yml", "sub/.github/workflows/x.yaml", ".husky/pre-commit", ".envrc", ".tool-versions",
            "Brewfile", "go.mod", "rust-toolchain.toml", ".python-version", "mise.toml", "PACKAGE.SWIFT", "Package.swift",
        ]
        for mode in [PermissionMode.acceptEdits, .auto] {
            for path in protected {
                #expect(effect("edit", path, mode) == "ask", "\(path) should ask in \(mode)")
            }
            for path in ["Sources/App.swift", "README.md", "notes/Makefile.txt", "mypackage.json.bak", "src/setup.pyc",
                         "docs/github/workflows.md", "Packages/EnsembleKit/Sources/Package.swift.md", "make.swift"] {
                #expect(effect("edit", path, mode) == "allow", "\(path) should be editable in \(mode)")
            }
        }
    }

    @Test func askModeAsksForEveryEdit() {
        #expect(effect("edit", "Sources/App.swift", .ask) == "ask")
        #expect(effect("edit", "Makefile", .ask) == "ask")
        #expect(shell("git status", .ask) == "ask")
    }

    @Test func acceptEditsRunsEditsAndAsksForEveryCommand() {
        #expect(effect("edit", "a.txt", .acceptEdits) == "allow")
        #expect(shell("git status", .acceptEdits) == "ask")
        #expect(shell("ls", .acceptEdits) == "ask")
    }

    @Test func bypassAllowsEverything() {
        #expect(shell("rm -rf /tmp/x", .bypass) == "allow")
        #expect(effect("edit", "/etc/hosts", .bypass) == "allow")
        #expect(effect("edit", "Makefile", .bypass) == "allow")
        #expect(effect("read", ".env", .bypass) == "allow")
        #expect(effect("github_create_issue", "*", .bypass) == "allow")
    }

    @Test func recognisesItsOwnRulesets() {
        for mode in PermissionMode.allCases {
            #expect(PermissionRules.mode(for: PermissionRules.ruleset(for: mode)) == mode)
        }
        #expect(PermissionRules.mode(for: []) == nil)
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
        // A trailing " *" also matches the bare command for shell rules.
        #expect(PermissionRules.effect(action: "shell", resource: "ls", rules: [PermissionRule("shell", "ls *", "allow")]) == "allow")
        #expect(PermissionRules.effect(action: "shell", resource: "lsof", rules: [PermissionRule("shell", "ls *", "allow")]) == "agent")
    }
}
