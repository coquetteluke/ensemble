import Testing
@testable import EnsembleKit

@Suite struct PermissionRulesTests {
    private func shell(_ command: String, _ mode: PermissionMode) -> String {
        PermissionRules.effect(action: "shell", resource: command, rules: PermissionRules.ruleset(for: mode))
    }

    private func effect(_ action: String, _ resource: String, _ mode: PermissionMode) -> String {
        PermissionRules.effect(action: action, resource: resource, rules: PermissionRules.ruleset(for: mode))
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

    @Test func autoEditsInsideTheProjectAndAsksOutside() {
        #expect(effect("edit", "Sources/App.swift", .auto) == "allow")
        #expect(effect("external_directory", "/Users/me/other/*", .auto) == "ask")
        #expect(effect("webfetch", "https://example.com", .auto) == "ask")
        #expect(effect("read", "Sources/App.swift", .auto) == "allow")
        #expect(effect("read", ".env", .auto) == "ask")
        #expect(effect("read", ".env.example", .auto) == "allow")
        #expect(effect("grep", "TODO", .auto) == "allow")
        #expect(effect("subagent", "general", .auto) == "allow")
    }

    @Test func askModeAsksForEditsAndCommands() {
        #expect(effect("edit", "a.txt", .ask) == "ask")
        #expect(shell("git status", .ask) == "ask")
        #expect(effect("webfetch", "https://example.com", .ask) == "ask")
        #expect(effect("external_directory", "/tmp/*", .ask) == "ask")
        // Not covered by the session rules: the engine's agent rules decide (reads are allowed there).
        #expect(PermissionRules.ruleset(for: .ask).contains { $0.action == "read" } == false)
    }

    @Test func acceptEditsRunsEditsAndAsksForEveryCommand() {
        #expect(effect("edit", "a.txt", .acceptEdits) == "allow")
        #expect(shell("git status", .acceptEdits) == "ask")
        #expect(shell("ls", .acceptEdits) == "ask")
    }

    @Test func bypassAllowsEverything() {
        #expect(shell("rm -rf /tmp/x", .bypass) == "allow")
        #expect(effect("edit", "/etc/hosts", .bypass) == "allow")
        #expect(effect("read", ".env", .bypass) == "allow")
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
        #expect(PermissionRules.wildcardMatch("a?c", "abc"))
        #expect(!PermissionRules.wildcardMatch("a?c", "ac"))
        // A trailing " *" also matches the bare command for shell rules.
        #expect(PermissionRules.effect(action: "shell", resource: "ls", rules: [PermissionRule("shell", "ls *", "allow")]) == "allow")
        #expect(PermissionRules.effect(action: "shell", resource: "lsof", rules: [PermissionRule("shell", "ls *", "allow")]) == "ask")
    }
}
