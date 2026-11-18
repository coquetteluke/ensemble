import Foundation
import Testing
@testable import EnsembleKit

/// Discovery for the Customizations screen, against a synthetic home and project in a temporary folder.
@Suite("Customizations discovery")
struct CustomizationsTests {
    /// A fake home (`home/`) with Claude, OpenCode and agy config, and a project at `home/code/repo/app` inside a git
    /// repository at `home/code/repo`.
    final class Box: @unchecked Sendable {
        let root: URL
        let home: String
        let repo: String
        let app: String
        static let secret = FakeSecret.make("sk-test-", 27, upper: true)

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("ens-custom-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            root = base
            let resolved = WorkspaceTrust.resolvedPath(base.path) ?? base.path
            home = resolved + "/home"
            repo = home + "/code/repo"
            app = repo + "/app"
            try build()
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func skill(_ folder: String, _ name: String, _ description: String = "Does a thing") throws {
            try write("\(folder)/\(name)/SKILL.md", "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\nSteps.\n")
        }

        var environment: CustomizationsEnvironment { CustomizationsEnvironment(homeDirectory: home, environment: [:]) }

        func discover(trusted: Bool, folder: String? = nil) -> CustomizationsReport {
            CustomizationsDiscovery.discover(folder: folder ?? app, trusted: trusted, environment: environment)
        }

        private func build() throws {
            let s = Self.secret
            try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)

            // Claude, user level.
            try write(home + "/.claude/CLAUDE.md", "# Me\nAlways answer briefly.\napi_key: \(s)\n")
            try write(home + "/.claude/rules/style.md", "# Style\nShort sentences.\n")
            try write(home + "/.claude/rules/swift.md", "---\npaths:\n  - \"**/*.swift\"\n---\n# Swift\n")
            try skill(home + "/.claude/skills", "shared-skill", "Shared with OpenCode")
            try write(home + "/.claude/commands/ship.md", "---\ndescription: Ships it\n---\nShip.\n")
            try write(home + "/.claude/commands/git/sync.md", "Sync the branch.\n")
            try write(home + "/.claude/agents/reviewer.md", "---\nname: reviewer\ndescription: Reviews code\n---\nReview.\n")
            try write(home + "/.claude/.credentials.json", "{\"claudeAiOauth\":{\"accessToken\":\"\(s)\"}}")
            try write(home + "/.claude/settings.json", """
                {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh --token \(s)"}]}],
                           "Stop": [{"hooks": [{"type": "http", "url": "https://user:pass@hooks.example.com/stop?key=\(s)"}]}]},
                 "enabledPlugins": {"helper@market": true, "off@market": false},
                 "env": {"ANTHROPIC_API_KEY": "\(s)"}}
                """)
            try write(home + "/.claude/plugins/installed_plugins.json", """
                {"version": 2, "plugins": {"helper@market": [{"scope": "user", "installPath": "\(home)/.claude/plugins/cache/helper"}],
                                           "off@market": [{"scope": "user", "installPath": "\(home)/.claude/plugins/cache/off"}]}}
                """)
            try skill(home + "/.claude/plugins/cache/helper/skills", "plugged")
            try write(home + "/.claude/plugins/cache/helper/hooks/hooks.json",
                      "{\"hooks\": {\"SessionStart\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo hi\"}]}]}}")
            try skill(home + "/.claude/plugins/cache/off/skills", "never")
            try write(home + "/.claude.json", """
                {"oauthAccount": {"emailAddress": "someone@example.com"},
                 "mcpServers": {"github": {"type": "stdio", "command": "npx", "args": ["-y", "server-github", "--api-key", "\(s)"],
                                           "env": {"GITHUB_TOKEN": "\(s)"}}},
                 "projects": {"\(app)": {"mcpServers": {"localdb": {"command": "db-mcp", "env": {"DB_PASSWORD": "\(s)"}}}}}}
                """)

            // Claude, project level.
            try write(repo + "/CLAUDE.md", "# Repo\nMonorepo notes.\n")
            try write(app + "/CLAUDE.md", "# App\nBuild with make.\n")
            try write(app + "/CLAUDE.local.md", "# Mine\nLocal notes.\n")
            try write(app + "/.claude/CLAUDE.md", "# Dot\n")
            try write(app + "/.claude/rules/tests.md", "# Tests\nRun them.\n")
            try write(app + "/.claude/rules/api.md", "---\npaths: src/api/**\n---\n# API\n")
            try write(app + "/sub/CLAUDE.md", "# Sub\n")
            try write(app + "/node_modules/pkg/CLAUDE.md", "# Ignored\n")
            try skill(app + "/.claude/skills", "app-skill")
            try write(app + "/.claude/commands/deploy.md", "Deploy.\n")
            try write(app + "/.claude/agents/tester.md", "---\nname: tester\n---\nTest.\n")
            try write(app + "/.claude/settings.json", """
                {"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "fmt.sh"}]}]},
                 "disabledMcpjsonServers": ["off-server"]}
                """)
            try write(app + "/.mcp.json", """
                {"mcpServers": {"web": {"type": "http", "url": "https://mcp.example.com/mcp?token=\(s)",
                                        "headers": {"Authorization": "Bearer \(s)"}},
                                "off-server": {"command": "off"}}}
                """)

            // OpenCode.
            try write(home + "/.config/opencode/AGENTS.md", "# Global rules\n")
            try write(home + "/.config/opencode/opencode.jsonc", """
                {
                  // comment
                  "mcp": {"search": {"type": "remote", "url": "https://search.example.com/mcp", "headers": {"X-Api-Key": "\(s)"}},
                          "files": {"type": "local", "command": ["files-mcp", "--root", "/tmp"], "environment": {"SECRET": "\(s)"},
                                    "enabled": false},},
                  "plugin": ["oc-plugin-notify@1.2.0"],
                  "command": {"lint": {"description": "Runs the linter", "template": "lint"}},
                }
                """)
            try skill(home + "/.agents/skills", "agents-skill")
            try skill(home + "/.config/opencode/skills", "oc-skill")
            try write(home + "/.config/opencode/commands/review-all.md", "---\ndescription: Reviews all\n---\nx\n")
            try write(home + "/.config/opencode/agents/helper.md", "---\ndescription: Helps\nmode: subagent\n---\nx\n")
            try write(home + "/.config/opencode/plugins/notify.ts", "export default {}\n")
            try write(repo + "/AGENTS.md", "# Repo agents\nUse tabs.\n")
            try write(app + "/AGENTS.md", "# App agents\n")
            try write(app + "/opencode.json", """
                {"instructions": ["docs/extra.md", "https://example.com/rules.md?sig=\(s)", "rules/*.md"],
                 "mcp": {"projdb": {"type": "local", "command": ["projdb"]}}}
                """)
            try write(app + "/docs/extra.md", "# Extra\nMore rules.\n")
            try skill(app + "/.opencode/skills", "oc-project-skill")
            try skill(app + "/.agents/skills", "agents-project-skill")
            try skill(repo + "/.claude/skills", "parent-skill")
            try write(app + "/.opencode/commands/release.md", "Release.\n")
            try write(app + "/.opencode/agent/planner.md", "---\ndescription: Plans\n---\nx\n")
            try write(app + "/.opencode/plugins/guard.js", "export default {}\n")

            // agy (Gemini).
            try write(home + "/.gemini/GEMINI.md", "# Gemini global\n")
            try write(home + "/.gemini/config/AGENTS.md", "# Gemini config agents\n")
            try skill(home + "/.gemini/config/skills", "gem-skill")
            try write(home + "/.gemini/config/global_workflows/standup.md", "Standup.\n")
            try write(home + "/.gemini/config/mcp_config.json", """
                {"mcpServers": {"sqlite": {"command": "sqlite-mcp", "args": ["/data/db"], "env": {"DB_READONLY": "true"}},
                                "remote": {"serverUrl": "https://\(s)@remote.example.com/mcp"}}}
                """)
            try write(home + "/.gemini/config/hooks.json", """
                {"lint": {"PostToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "./lint.sh"}]}]},
                 "gate": {"enabled": false, "PreToolUse": [{"command": "./gate.sh"}]}}
                """)
            try write(home + "/.gemini/config/plugins/kit/plugin.json", "{\"name\": \"team-kit\"}")
            try skill(home + "/.gemini/config/plugins/kit/skills", "kit-skill")
            try write(home + "/.gemini/config/plugins/kit/mcp_config.json", "{\"mcpServers\": {\"kitmcp\": {\"url\": \"https://kit.example.com/mcp\"}}}")
            try write(repo + "/GEMINI.md", "# Repo gemini\n")
            try write(app + "/GEMINI.md", "# App gemini\n")
            try write(app + "/.agents/rules/always.md", "---\ntrigger: always_on\n---\n# Always\n")
            try write(app + "/.agents/rules/decide.md", "---\ntrigger: model_decision\n---\n# Decide\n")
            try write(app + "/.agents/rules/globbed.md", "---\ntrigger: glob\nglobs: src/**/*.ts\n---\n# Globbed\n")
            try write(app + "/.agents/hooks.json", "{\"check\": {\"PreToolUse\": [{\"matcher\": \"run_command\", \"hooks\": [{\"command\": \"./check.sh\"}]}]}}")
            try write(app + "/sub/GEMINI.md", "# Sub gemini\n")
        }
    }

    // MARK: Claude

    @Test("Claude in a trusted folder: user, project, local, nested and plugin items")
    func claudeTrusted() throws {
        let box = try Box()
        let report = box.discover(trusted: true)
        let rules = Dictionary(report.rules(for: .claude).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        #expect(rules[box.home + "/.claude/CLAUDE.md"]?.scope == .user)
        #expect(rules[box.home + "/.claude/CLAUDE.md"]?.status == .loaded)
        #expect(rules[box.home + "/.claude/rules/style.md"]?.status == .loaded)
        #expect(rules[box.home + "/.claude/rules/swift.md"]?.status == .onDemand("Applies to **/*.swift"))
        #expect(rules[box.repo + "/CLAUDE.md"]?.status == .loaded, "parent folders' CLAUDE.md load too")
        #expect(rules[box.app + "/CLAUDE.md"]?.status == .loaded)
        #expect(rules[box.app + "/.claude/CLAUDE.md"]?.status == .loaded)
        #expect(rules[box.app + "/CLAUDE.local.md"]?.scope == .local)
        #expect(rules[box.app + "/.claude/rules/tests.md"]?.status == .loaded)
        #expect(rules[box.app + "/.claude/rules/api.md"]?.status == .onDemand("Applies to src/api/**"))
        #expect(rules[box.app + "/sub/CLAUDE.md"]?.status == .onDemand("Loads when Claude reads files in sub/"))
        #expect(rules[box.app + "/node_modules/pkg/CLAUDE.md"] == nil)
        #expect(rules[box.app + "/AGENTS.md"] == nil, "the claude CLI does not read AGENTS.md")
        #expect(rules[box.app + "/CLAUDE.md"]?.firstLines == ["# App", "Build with make."])
        #expect(rules[box.app + "/CLAUDE.md"]?.size == 23)

        let entries = report.entries(for: .claude)
        let names = Set(entries.map(\.name))
        #expect(names.isSuperset(of: ["shared-skill", "ship", "git:sync", "reviewer", "app-skill", "deploy", "tester", "helper:plugged"]))
        #expect(!names.contains("never"), "a disabled plugin adds nothing")
        #expect(!names.contains("parent-skill"), "only the session folder's own .claude/skills count")
        #expect(entries.first { $0.name == "ship" }?.summary == "Ships it")
        #expect(entries.first { $0.name == "helper:plugged" }?.scope == .plugin("helper"))
        #expect(entries.allSatisfy { $0.status == .loaded })

        let servers = Dictionary(report.mcpServers(for: .claude).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(servers["github"]?.scope == .user)
        #expect(servers["github"]?.environmentKeys == ["GITHUB_TOKEN"])
        #expect(servers["localdb"]?.scope == .local)
        #expect(servers["localdb"]?.status == .loaded)
        #expect(servers["web"]?.scope == .project)
        #expect(servers["web"]?.transport == .http)
        #expect(servers["web"]?.headerKeys == ["Authorization"])
        #expect(servers["off-server"]?.status == .disabled("Listed in disabledMcpjsonServers"))

        let hooks = report.hooks(for: .claude)
        #expect(hooks.contains { $0.event == "PreToolUse" && $0.matcher == "Bash" && $0.scope == .user })
        #expect(hooks.contains { $0.event == "PostToolUse" && $0.command == "fmt.sh" && $0.status == .loaded })
        #expect(hooks.contains { $0.event == "SessionStart" && $0.scope == .plugin("helper") })
        #expect(hooks.first { $0.event == "Stop" }?.handler == "http")
    }

    @Test("Claude in an untrusted folder skips every project and local item, like --setting-sources user")
    func claudeUntrusted() throws {
        let box = try Box()
        let report = box.discover(trusted: false)
        for rule in report.rules(for: .claude) {
            #expect(rule.scope.isProject ? rule.status == .skippedUntrusted : rule.status.isActive, "\(rule.path)")
        }
        for entry in report.entries(for: .claude) {
            #expect(entry.scope.isProject ? entry.status == .skippedUntrusted : entry.status == .loaded, "\(entry.name)")
        }
        let servers = Dictionary(report.mcpServers(for: .claude).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(servers["github"]?.status == .loaded)
        #expect(servers["localdb"]?.status == .skippedUntrusted, "local-scope servers need project trust too (checked with the CLI)")
        #expect(servers["web"]?.status == .skippedUntrusted)
        #expect(servers["off-server"]?.status == .skippedUntrusted)
        #expect(report.hooks(for: .claude).first { $0.command == "fmt.sh" }?.status == .skippedUntrusted)
        #expect(report.hooks(for: .claude).first { $0.matcher == "Bash" }?.status == .loaded)
        // The engine runs untrusted folders with user settings only.
        #expect(ClaudeSettingSources.all.effective(trusted: false) == .userOnly)
    }

    // MARK: OpenCode

    @Test("OpenCode in a trusted folder: AGENTS.md, instructions, skills from ~/.claude, config MCP and plugins")
    func openCodeTrusted() throws {
        let box = try Box()
        let report = box.discover(trusted: true)
        let rules = report.rules(for: .openCode)
        let paths = rules.map(\.path)
        #expect(paths.contains(box.home + "/.config/opencode/AGENTS.md"))
        #expect(paths.contains(box.repo + "/AGENTS.md"), "AGENTS.md in folders above, up to the home folder")
        #expect(paths.contains(box.app + "/AGENTS.md"))
        #expect(paths.contains(box.app + "/docs/extra.md"))
        #expect(!paths.contains(box.app + "/CLAUDE.md"), "OpenCode 2.3 does not read CLAUDE.md")
        let url = rules.first { $0.path.hasPrefix("https://") }
        #expect(url?.isFile == false)
        #expect(url?.path == "https://example.com/rules.md?sig=•••")
        #expect(rules.contains { $0.path == "rules/*.md" && !$0.isFile })

        let entries = report.entries(for: .openCode)
        let names = Set(entries.map(\.name))
        #expect(names.isSuperset(of: ["shared-skill", "agents-skill", "oc-skill", "oc-project-skill", "agents-project-skill",
                                       "parent-skill", "app-skill", "review-all", "release", "lint", "helper", "planner"]))
        #expect(!names.contains("ship"), "OpenCode does not read ~/.claude/commands")
        #expect(!names.contains("reviewer"), "or ~/.claude/agents")
        #expect(entries.first { $0.name == "shared-skill" }?.note == "Shared from ~/.claude/skills")
        #expect(entries.allSatisfy { $0.status == .loaded })

        let servers = Dictionary(report.mcpServers(for: .openCode).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(servers["search"]?.transport == .http)
        #expect(servers["search"]?.headerKeys == ["X-Api-Key"])
        #expect(servers["files"]?.status == .disabled("enabled is false in its config"))
        #expect(servers["files"]?.environmentKeys == ["SECRET"])
        #expect(servers["files"]?.target == "files-mcp --root /tmp")
        #expect(servers["projdb"]?.scope == .project)

        let plugins = report.hooks(for: .openCode)
        #expect(plugins.contains { $0.kind == .plugin && $0.name == "oc-plugin-notify@1.2.0" && $0.handler == "package" })
        #expect(plugins.contains { $0.name == "notify" && $0.scope == .user })
        #expect(plugins.contains { $0.name == "guard" && $0.scope == .project })
    }

    @Test("OpenCode in an untrusted folder: the private server skips every project item")
    func openCodeUntrusted() throws {
        let box = try Box()
        let report = box.discover(trusted: false)
        for rule in report.rules(for: .openCode) {
            #expect(rule.scope == .project ? rule.status == .skippedUntrusted : rule.status == .loaded, "\(rule.path)")
        }
        let entries = report.entries(for: .openCode)
        #expect(entries.first { $0.name == "shared-skill" }?.status == .loaded)
        #expect(entries.first { $0.name == "oc-project-skill" }?.status == .skippedUntrusted)
        #expect(entries.first { $0.name == "parent-skill" }?.status == .skippedUntrusted)
        #expect(report.mcpServers(for: .openCode).first { $0.name == "projdb" }?.status == .skippedUntrusted)
        #expect(report.hooks(for: .openCode).first { $0.name == "guard" }?.status == .skippedUntrusted)
        #expect(report.hooks(for: .openCode).first { $0.name == "notify" }?.status == .loaded)
    }

    // MARK: Gemini

    @Test("Gemini in a trusted folder: rules up to the repository root, triggers, plugins, named hooks")
    func geminiTrusted() throws {
        let box = try Box()
        let report = box.discover(trusted: true)
        let rules = Dictionary(report.rules(for: .gemini).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(rules[box.home + "/.gemini/GEMINI.md"]?.scope == .user)
        #expect(rules[box.home + "/.gemini/config/AGENTS.md"]?.scope == .user)
        #expect(rules[box.repo + "/GEMINI.md"]?.status == .loaded, "the repository root is the top")
        #expect(rules[box.repo + "/AGENTS.md"]?.status == .loaded)
        #expect(rules[box.app + "/GEMINI.md"]?.status == .loaded)
        #expect(rules[box.app + "/.agents/rules/always.md"]?.status == .loaded)
        #expect(rules[box.app + "/.agents/rules/decide.md"]?.status == .onDemand("Read when the agent decides it applies"))
        #expect(rules[box.app + "/.agents/rules/globbed.md"]?.status == .onDemand("Applies to src/**/*.ts"))
        #expect(rules[box.app + "/sub/GEMINI.md"]?.status == .onDemand("Loads when Gemini works on files in sub/"))

        let entries = report.entries(for: .gemini)
        #expect(entries.contains { $0.name == "gem-skill" && $0.scope == .user })
        #expect(entries.contains { $0.name == "kit-skill" && $0.scope == .plugin("team-kit") })
        #expect(entries.contains { $0.name == "standup" && $0.kind == .command })

        let servers = Dictionary(report.mcpServers(for: .gemini).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(servers["sqlite"]?.environmentKeys == ["DB_READONLY"])
        #expect(servers["remote"]?.target == "https://•••@remote.example.com/mcp")
        #expect(servers["kitmcp"]?.scope == .plugin("team-kit"))

        let hooks = report.hooks(for: .gemini)
        #expect(hooks.first { $0.name == "lint" }?.status == .loaded)
        #expect(hooks.first { $0.name == "gate" }?.status == .disabled("enabled is false"))
        #expect(hooks.first { $0.name == "gate" }?.command == "./gate.sh", "a handler can sit directly in the event list")
        #expect(hooks.first { $0.name == "check" }?.scope == .project)
    }

    @Test("Gemini in an untrusted folder does not start, so nothing loads")
    func geminiUntrusted() throws {
        let box = try Box()
        let report = box.discover(trusted: false)
        let statuses = report.rules(for: .gemini).map(\.status) + report.entries(for: .gemini).map(\.status)
            + report.mcpServers(for: .gemini).map(\.status) + report.hooks(for: .gemini).map(\.status)
        #expect(!statuses.isEmpty)
        #expect(statuses.allSatisfy { $0 == .notStarted })
    }

    // MARK: Trust

    @Test("The trust view lists what each engine skips, including everything the trust card lists")
    func trustSummary() throws {
        let box = try Box()
        let untrusted = box.discover(trusted: false)
        let scanned = ProjectTrustFiles.scan(box.app, homeDirectory: box.home)
        #expect(!scanned.claude.isEmpty && !scanned.openCode.isEmpty && !scanned.gemini.isEmpty)
        func normalized(_ list: [String]) -> Set<String> { Set(list.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) }
        let claude = try #require(untrusted.trust.note(for: .claude))
        let openCode = try #require(untrusted.trust.note(for: .openCode))
        let gemini = try #require(untrusted.trust.note(for: .gemini))
        #expect(normalized(claude.skipped).isSuperset(of: normalized(scanned.claude)))
        #expect(normalized(openCode.skipped).isSuperset(of: normalized(scanned.openCode)))
        #expect(normalized(gemini.skipped).isSuperset(of: normalized(scanned.gemini)))
        #expect(claude.skipped.contains("CLAUDE.md"))
        #expect(claude.skipped.contains("../CLAUDE.md"))
        #expect(claude.skipped.contains("MCP server localdb (local scope)"))
        #expect(claude.skipped.contains(".claude/skills/"))
        #expect(openCode.skipped.contains("../AGENTS.md"))
        #expect(openCode.skipped.contains("../.claude/skills/"))
        #expect(gemini.headline == "Does not start here")
        #expect(untrusted.trust.skipsAnything)
        #expect(untrusted.trust.canBeTrusted)

        let trusted = box.discover(trusted: true)
        #expect(!trusted.trust.skipsAnything)
        #expect(trusted.counts(for: .claude).skipped == 0)
        #expect(untrusted.counts(for: .claude).skipped > 0)
    }

    @Test("Trusting through WorkspaceTrust flips the report, and the home folder cannot be trusted")
    func trustRoundTrip() throws {
        let box = try Box()
        let store = WorkspaceTrust(fileURL: box.root.appendingPathComponent("trusted.json"), homeDirectory: box.home)
        #expect(CustomizationsDiscovery.discover(folder: box.app, trust: store, environment: box.environment).trusted == false)
        try store.trust(box.app)
        let report = CustomizationsDiscovery.discover(folder: box.app, trust: store, environment: box.environment)
        #expect(report.trusted)
        #expect(report.rules(for: .claude).first { $0.path == box.app + "/CLAUDE.md" }?.status == .loaded)

        let homeReport = box.discover(trusted: false, folder: box.home)
        #expect(homeReport.trust.canBeTrusted == false)
        #expect(throws: WorkspaceTrustError.self) { try store.trust(box.home) }
        #expect(homeReport.rules(for: .claude).first { $0.path == box.home + "/.claude/CLAUDE.md" }?.status == .loaded)
        #expect(homeReport.entries(for: .claude).filter { $0.scope == .project }.isEmpty, "the home folder has no project items")
    }

    // MARK: Secrets

    @Test("No secret value from any config, rule or sign-in file reaches the report")
    func noSecretsInReport() throws {
        let box = try Box()
        for trusted in [true, false] {
            let dump = String(describing: box.discover(trusted: trusted))
            #expect(!dump.contains(Box.secret), "trusted: \(trusted)")
            #expect(!dump.contains(String(Box.secret.dropFirst(8))), "trusted: \(trusted)")
            #expect(!dump.contains("someone@example.com"))
            #expect(!dump.contains("user:pass"))
            #expect(!dump.contains(".credentials.json"))
        }
        let report = box.discover(trusted: true)
        let github = try #require(report.mcpServers.first { $0.name == "github" })
        #expect(github.target == "npx -y server-github --api-key •••")
        let web = try #require(report.mcpServers.first { $0.name == "web" })
        #expect(web.target == "https://mcp.example.com/mcp?token=•••")
        #expect(report.hooks.first { $0.matcher == "Bash" }?.command == "guard.sh --token •••")
        #expect(report.hooks.first { $0.event == "Stop" }?.command == "https://•••@hooks.example.com/stop?key=•••")
        #expect(report.rules.first { $0.path == box.home + "/.claude/CLAUDE.md" }?.firstLines.last == "api_key: •••")
    }

    @Test("Sign-in stores are never read")
    func forbiddenFiles() throws {
        let box = try Box()
        #expect(CustomizationFiles.read(box.home + "/.claude/.credentials.json") == nil)
        #expect(CustomizationFiles.isForbidden("/x/.local/share/opencode/auth.json"))
        #expect(CustomizationFiles.isForbidden("/Users/x/Library/Keychains/login.keychain-db"))
        #expect(CustomizationFiles.isForbidden("/Users/x/Library/Cookies/Cookies.binarycookies"))
        #expect(!CustomizationFiles.isForbidden(box.home + "/.claude/settings.json"))
        try box.write(box.app + "/.claude/rules/auth.json", "{\"token\": \"\(Box.secret)\"}")
        #expect(CustomizationFiles.read(box.app + "/.claude/rules/auth.json") == nil)
    }

    // MARK: Files

    @Test("JSONC comments and trailing commas are accepted, strings are left alone")
    func jsonc() {
        let text = "{\n // note\n \"a\": \"http://x//y\", /* block */ \"b\": [1, 2,],\n}"
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(CustomizationFiles.stripJSONC(text).utf8))
        #expect(value?["a"]?.stringValue == "http://x//y")
        #expect(value?["b"]?.arrayValue?.count == 2)
    }

    @Test("Front matter: quoted values, folded blocks and lists")
    func frontMatter() {
        let markdown = CustomizationFiles.parseMarkdown("""
            ---
            name: "my-skill"
            description: >-
              First line
              second line
            paths:
              - src/**
              - "tests/**"
            globs: [a/*, b/*]
            ---
            # Title

            Body text.
            """)
        #expect(markdown.string("name") == "my-skill")
        #expect(markdown.string("description") == "First line second line")
        #expect(markdown.list("paths") == ["src/**", "tests/**"])
        #expect(markdown.list("globs") == ["a/*", "b/*"])
        #expect(CustomizationFiles.previewLines(markdown) == ["# Title", "Body text."])
    }

    @Test("Paths read relative to the folder, with ../ for folders above it")
    func relativePaths() {
        let home = "/Users/sam"
        #expect(CustomizationsDiscovery.relativePath("/Users/sam/code/app/CLAUDE.md", to: "/Users/sam/code/app", home: home) == "CLAUDE.md")
        #expect(CustomizationsDiscovery.relativePath("/Users/sam/code/AGENTS.md", to: "/Users/sam/code/app", home: home) == "../AGENTS.md")
        #expect(CustomizationsDiscovery.relativePath("/Users/sam/.claude/CLAUDE.md", to: "/Users/sam/code/app", home: home) == "~/.claude/CLAUDE.md")
        #expect(CustomizationsDiscovery.relativePath("/CLAUDE.md", to: "/Users/sam/code/app", home: home) == "/CLAUDE.md")
    }

    // MARK: Live

    @Test("OpenCode's answers: MCP status and sign-in, the skills it loaded, plugin failures")
    func liveMerge() throws {
        let box = try Box()
        let report = box.discover(trusted: true)
        let live = CustomizationLiveData(
            mcp: [.init(name: "search", state: .needsAuth, integrationID: "mcp_123"),
                  .init(name: "projdb", state: .failed, message: "spawn failed: token=\(Box.secret)"),
                  .init(name: "files", state: .disabled),
                  .init(name: "from-integration", state: .connected)],
            skills: [.init(id: "browser", path: "skill://browser/SKILL.md"),
                     .init(id: "shared-skill", name: "shared-skill", path: box.home + "/.claude/skills/shared-skill/SKILL.md")],
            plugins: [.init(source: "oc-plugin-notify", isFile: false, failure: "Cannot find module")])
        let merged = CustomizationsLive.merge(report, live: live, serverName: "your OpenCode service", environment: box.environment)
        #expect(merged.openCodeServer == "your OpenCode service")

        let search = try #require(merged.mcpServers.first { $0.engine == .openCode && $0.name == "search" })
        #expect(search.live?.state == .needsAuth)
        #expect(search.canAuthenticate)
        let projdb = try #require(merged.mcpServers.first { $0.name == "projdb" })
        #expect(projdb.canRestart)
        #expect(projdb.live?.message == "spawn failed: token=•••")
        let files = merged.mcpServers.filter { $0.engine == .openCode && $0.name == "files" }
        #expect(files.count == 1, "a server turned off in its config is matched, not listed twice")
        #expect(files.first?.status == .disabled("enabled is false in its config"))
        #expect(files.first?.live?.state == .disabled)
        #expect(files.first?.canRestart == false)
        #expect(merged.mcpServers.first { $0.name == "from-integration" }?.sourcePath == nil)
        #expect(merged.mcpServers.first { $0.engine == .claude && $0.name == "github" }?.canRestart == false)

        let skills = merged.entries(for: .openCode).filter { $0.kind == .skill }
        #expect(Set(skills.map(\.name)) == ["browser", "shared-skill"])
        #expect(skills.first { $0.name == "browser" }?.scope == .builtIn)
        #expect(skills.first { $0.name == "shared-skill" }?.note == "Shared from ~/.claude/skills")
        #expect(merged.entries(for: .openCode).contains { $0.kind == .command }, "commands stay from discovery")

        let plugin = try #require(merged.hooks.first { $0.name == "oc-plugin-notify@1.2.0" })
        #expect(plugin.status == .disabled("Failed to load: Cannot find module"))

        // Untrusted: project skills OpenCode skipped stay listed as skipped.
        let untrusted = CustomizationsLive.merge(box.discover(trusted: false), live: live, serverName: "private", environment: box.environment)
        #expect(untrusted.entries(for: .openCode).first { $0.name == "oc-project-skill" }?.status == .skippedUntrusted)
    }

    @Test("Live answers come from the server the folder routes to, never the shared service for an untrusted folder")
    func liveSource() throws {
        let box = try Box()
        let trust = WorkspaceTrust(fileURL: box.root.appendingPathComponent("trusted.json"), homeDirectory: box.home)
        let shared = OpenCodeClient(baseURL: URL(string: "http://127.0.0.1:9")!, password: "x")
        let router = EngineRouter(fallback: shared, trust: trust)
        #expect(CustomizationsLive.source(for: box.app, router: router) == nil, "untrusted and no private server: no live data")

        let privateServer = OpenCodeClient(baseURL: URL(string: "http://127.0.0.1:10")!, password: "y")
        router.registerForUntrustedFolders(privateServer)
        let untrusted = try #require(CustomizationsLive.source(for: box.app, router: router))
        #expect(untrusted.serverName == "Ensemble's private OpenCode server")
        #expect((untrusted.engine as? OpenCodeClient)?.baseURL.port == 10)

        try trust.trust(box.app)
        let trustedSource = try #require(CustomizationsLive.source(for: box.app, router: router))
        #expect(trustedSource.serverName == "your OpenCode service")
        #expect((trustedSource.engine as? OpenCodeClient)?.baseURL.port == 9)

        router.registerForUntrustedFolders(OpenCodeStandIn(reason: "starting"))
        #expect(CustomizationsLive.source(for: box.repo, router: router) == nil, "the stand-in has no live data")
    }
}
