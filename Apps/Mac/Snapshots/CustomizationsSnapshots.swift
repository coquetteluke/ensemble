import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the Customizations screen: every section (rules and memory, skills, MCP servers, hooks, trust) for a
/// trusted and an untrusted folder, dark and light, at the requested zoom. Sample data only (a made-up home folder and
/// project); nothing is read from disk. Called from `SnapshotRenderer.run`.
@MainActor
enum CustomizationsSnapshots {
    static let home = "/Users/sam"
    static let folder = "/Users/sam/Projects/widgets"

    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        for trusted in [true, false] {
            let report = sample(trusted: trusted)
            for section in CustomizationsModel.Section.allCases {
                for scheme in [ColorScheme.dark, .light] {
                    let tone = scheme == .dark ? "dark" : "light"
                    let name = "customizations-\(section.rawValue)-\(trusted ? "trusted" : "untrusted")-\(tone)\(suffix)"
                    let model = CustomizationsModel(fixed: report, section: section, home: home)
                    written += save(name, to: directory, width: 960, zoom: zoom, scheme: scheme) {
                        CustomizationsView(model: model)
                    }
                }
            }
        }
        print("Rendered \(written.count) customizations snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Sample data

    static func path(_ relative: String) -> String { folder + "/" + relative }
    static func homePath(_ relative: String) -> String { home + "/" + relative }

    static func sample(trusted: Bool) -> CustomizationsReport {
        let project: CustomizationStatus = trusted ? .loaded : .skippedUntrusted
        let gemini: CustomizationStatus = trusted ? .loaded : .notStarted
        func onDemand(_ reason: String) -> CustomizationStatus { trusted ? .onDemand(reason) : .skippedUntrusted }

        let rules: [CustomizationRule] = [
            .init(engine: .claude, kind: .memory, scope: .user, path: homePath(".claude/CLAUDE.md"), size: 1_840,
                  firstLines: ["# Working with Sam", "Keep answers short and run the tests before saying done."], status: .loaded),
            .init(engine: .claude, kind: .rule, scope: .user, path: homePath(".claude/rules/swift.md"), size: 420,
                  firstLines: ["# Swift", "Swift 6 strict concurrency."], status: .onDemand("Applies to **/*.swift")),
            .init(engine: .claude, kind: .memory, scope: .project, path: path("CLAUDE.md"), size: 2_310,
                  firstLines: ["# Widgets", "Build with make, test with make test.", "api_key: \(CustomizationRedaction.mask)"], status: project),
            .init(engine: .claude, kind: .memory, scope: .local, path: path("CLAUDE.local.md"), size: 96,
                  firstLines: ["My staging server is staging-2."], status: project),
            .init(engine: .claude, kind: .memory, scope: .project, path: path("Sources/Server/CLAUDE.md"), size: 512,
                  firstLines: ["# Server", "Never block the event loop."], status: onDemand("Loads when Claude reads files in Sources/Server/")),
            .init(engine: .openCode, kind: .instructions, scope: .user, path: homePath(".config/opencode/AGENTS.md"), size: 300,
                  firstLines: ["# Global", "Prefer small commits."], status: .loaded),
            .init(engine: .openCode, kind: .instructions, scope: .project, path: "/Users/sam/Projects/AGENTS.md", size: 640,
                  firstLines: ["# All projects", "Use tabs in Makefiles."], status: project),
            .init(engine: .openCode, kind: .instructions, scope: .project, path: path("AGENTS.md"), size: 1_120,
                  firstLines: ["# Widgets agents", "Ask before changing the public API."], status: project),
            .init(engine: .openCode, kind: .instructions, scope: .project, path: "docs/rules/*.md", isFile: false, status: project,
                  note: "From opencode.json instructions, pattern"),
            .init(engine: .gemini, kind: .instructions, scope: .user, path: homePath(".gemini/GEMINI.md"), size: 210,
                  firstLines: ["# Gemini", "Explain changes before making them."], status: gemini),
            .init(engine: .gemini, kind: .instructions, scope: .project, path: path("GEMINI.md"), size: 880,
                  firstLines: ["# Widgets for Gemini", "Run make lint after edits."], status: gemini),
            .init(engine: .gemini, kind: .rule, scope: .project, path: path(".agents/rules/api.md"), size: 350,
                  firstLines: ["# API rules"], status: trusted ? .onDemand("Applies to Sources/API/**") : .notStarted),
        ]

        let entries: [CustomizationEntry] = [
            .init(engine: .claude, kind: .skill, name: "release-notes", summary: "Writes the release notes from merged pull requests.",
                  path: path(".claude/skills/release-notes/SKILL.md"), scope: .project, status: project),
            .init(engine: .claude, kind: .skill, name: "code-review", summary: "Reviews the current diff for bugs.",
                  path: homePath(".claude/skills/code-review/SKILL.md"), scope: .user, status: .loaded),
            .init(engine: .claude, kind: .skill, name: "kit:deploy", summary: "Deploys a preview build.",
                  path: homePath(".claude/plugins/cache/kit/skills/deploy/SKILL.md"), scope: .plugin("kit"), status: .loaded),
            .init(engine: .claude, kind: .command, name: "ship", summary: "Commits, pushes and opens a pull request.",
                  path: homePath(".claude/commands/ship.md"), scope: .user, status: .loaded),
            .init(engine: .claude, kind: .agent, name: "tester", summary: "Writes and runs tests.",
                  path: path(".claude/agents/tester.md"), scope: .project, status: project),
            .init(engine: .openCode, kind: .skill, name: "code-review", summary: "Reviews the current diff for bugs.",
                  path: homePath(".claude/skills/code-review/SKILL.md"), scope: .user, status: .loaded, note: "Shared from ~/.claude/skills"),
            .init(engine: .openCode, kind: .skill, name: "browser", path: "skill://browser/SKILL.md", scope: .builtIn, status: .loaded),
            .init(engine: .openCode, kind: .skill, name: "release-notes", summary: "Writes the release notes from merged pull requests.",
                  path: path(".claude/skills/release-notes/SKILL.md"), scope: .project, status: project),
            .init(engine: .openCode, kind: .command, name: "lint", summary: "Runs the linter.",
                  path: path(".opencode/commands/lint.md"), scope: .project, status: project),
            .init(engine: .gemini, kind: .skill, name: "triage", summary: "Sorts new issues by area.",
                  path: homePath(".gemini/config/skills/triage/SKILL.md"), scope: .user, status: gemini),
            .init(engine: .gemini, kind: .command, name: "standup", summary: "Summarises yesterday's commits.",
                  path: homePath(".gemini/config/global_workflows/standup.md"), scope: .user, status: gemini),
        ]

        let m = CustomizationRedaction.mask
        let mcp: [CustomizationMCPServer] = [
            .init(engine: .claude, scope: .user, name: "github", transport: .stdio, target: "npx -y @example/github-mcp",
                  environmentKeys: ["GITHUB_TOKEN"], sourcePath: homePath(".claude.json"), status: .loaded),
            .init(engine: .claude, scope: .project, name: "docs", transport: .http, target: "https://docs.example.com/mcp?key=\(m)",
                  headerKeys: ["Authorization"], sourcePath: path(".mcp.json"), status: project),
            .init(engine: .claude, scope: .local, name: "staging-db", transport: .stdio, target: "db-mcp --host staging-2",
                  environmentKeys: ["DB_PASSWORD"], sourcePath: homePath(".claude.json"), status: project),
            .init(engine: .openCode, scope: .user, name: "search", transport: .http, target: "https://search.example.com/mcp",
                  headerKeys: ["X-Api-Key"], sourcePath: homePath(".config/opencode/opencode.json"), status: .loaded,
                  live: .init(state: .needsAuth), integrationID: "mcp_sample"),
            .init(engine: .openCode, scope: .user, name: "files", transport: .stdio, target: "files-mcp --root \(m)",
                  sourcePath: homePath(".config/opencode/opencode.json"), status: .loaded, live: .init(state: .connected)),
            .init(engine: .openCode, scope: .project, name: "widgets-db", transport: .stdio, target: "widgets-db-mcp",
                  sourcePath: path("opencode.json"), status: project,
                  live: trusted ? .init(state: .failed, message: "Could not start widgets-db-mcp: not found") : nil),
            .init(engine: .gemini, scope: .user, name: "sqlite", transport: .stdio, target: "sqlite-mcp /data/app.db",
                  environmentKeys: ["DB_READONLY"], sourcePath: homePath(".gemini/config/mcp_config.json"), status: gemini),
        ]

        let hooks: [CustomizationHook] = [
            .init(engine: .claude, scope: .user, event: "PreToolUse", matcher: "Bash", command: "~/.claude/hooks/guard.sh --token \(m)",
                  sourcePath: homePath(".claude/settings.json"), status: .loaded),
            .init(engine: .claude, scope: .project, event: "PostToolUse", matcher: "Edit|Write", command: "make format",
                  sourcePath: path(".claude/settings.json"), status: project),
            .init(engine: .claude, scope: .plugin("kit"), event: "SessionStart", command: "kit status",
                  sourcePath: homePath(".claude/plugins/cache/kit/hooks/hooks.json"), status: .loaded),
            .init(engine: .openCode, kind: .plugin, scope: .user, event: "Plugin", name: "opencode-notify@1.2.0", handler: "package",
                  command: "opencode-notify@1.2.0", sourcePath: homePath(".config/opencode/opencode.json"), status: .loaded),
            .init(engine: .openCode, kind: .plugin, scope: .project, event: "Plugin", name: "guard", handler: "file",
                  command: ".opencode/plugins/guard.ts", sourcePath: path(".opencode/plugins/guard.ts"), status: project),
            .init(engine: .gemini, scope: .project, event: "PostToolUse", matcher: "run_command", name: "lint", command: "./scripts/lint.sh",
                  sourcePath: path(".agents/hooks.json"), status: gemini),
            .init(engine: .gemini, scope: .user, event: "PreToolUse", name: "gate", command: "./gate.sh",
                  sourcePath: homePath(".gemini/config/hooks.json"), status: trusted ? .disabled("enabled is false") : .notStarted),
        ]

        let notes: [CustomizationTrustSummary.EngineNote] = trusted ? [
            .init(engine: .claude, headline: "Loads this folder's settings",
                  detail: "Project memory, rules, settings, hooks, skills and MCP servers load from the next message.", skipped: []),
            .init(engine: .openCode, headline: "Loads this folder's config",
                  detail: "New sessions here run on your OpenCode service with the folder's opencode.json, .opencode/ and AGENTS.md.",
                  skipped: []),
            .init(engine: .gemini, headline: "Starts here with the folder's rules and hooks",
                  detail: "agy loads GEMINI.md, AGENTS.md and .agents/ from this folder up to the repository root.", skipped: []),
        ] : [
            .init(engine: .claude, headline: "Runs with your own settings only",
                  detail: "Claude skips this folder's memory, rules, settings, hooks, skills and MCP servers.",
                  skipped: ["CLAUDE.md", "CLAUDE.local.md", "Sources/Server/CLAUDE.md", ".claude/skills/", ".claude/agents/",
                            ".claude/settings.json", ".mcp.json", "MCP server staging-db (local scope)"]),
            .init(engine: .openCode, headline: "Runs without this folder's config",
                  detail: "New sessions here run on Ensemble's private OpenCode server, which skips project config. "
                      + "Sessions started before you trust the folder keep skipping it.",
                  skipped: ["../AGENTS.md", "AGENTS.md", "docs/rules/*.md", ".claude/skills/", ".opencode/commands/", "opencode.json",
                            ".opencode/plugins/guard.ts"]),
            .init(engine: .gemini, headline: "Does not start here",
                  detail: "agy runs a folder's hooks and rules with no way to turn them off, so Ensemble only starts it in folders you trust.",
                  skipped: ["GEMINI.md", ".agents/rules/api.md", ".agents/hooks.json", ".agents/"]),
        ]

        return CustomizationsReport(folder: folder, trusted: trusted, rules: rules, entries: entries, mcpServers: mcp, hooks: hooks,
                                    trust: CustomizationTrustSummary(folder: folder, trusted: trusted, notes: notes),
                                    openCodeServer: trusted ? "your OpenCode service" : "Ensemble's private OpenCode server")
    }

    // MARK: Rendering

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = view()
            .frame(width: w, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }
}
