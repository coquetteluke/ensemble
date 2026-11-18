import Foundation

extension CustomizationsDiscovery {
    /// What OpenCode 2.3 loads, checked 2026-11-18 against two throwaway `opencode serve` processes with a synthetic
    /// home folder (one normal, one with `OPENCODE_DISABLE_PROJECT_CONFIG=1` like Ensemble's private server), through
    /// `GET /api/skill`, `/api/command`, `/api/agent` and `/api/mcp`, and in the 2.3.0 binary for instructions:
    /// - User: `~/.config/opencode/AGENTS.md`; `opencode.json`, `opencode.jsonc` and `config.json` there (`instructions`,
    ///   `mcp`, `plugin`, `command`, `agent`); skills in `~/.claude/skills`, `~/.agents/skills` and
    ///   `~/.config/opencode/skill(s)`; commands in `~/.config/opencode/command(s)`; agents in
    ///   `~/.config/opencode/agent(s)`; plugin files in `~/.config/opencode/plugin(s)`. Not `CLAUDE.md`, not
    ///   `~/.claude/commands` or `~/.claude/agents`.
    /// - Project, in the folder and each folder above it up to the home folder (`openCodeLevels`): `AGENTS.md`,
    ///   `opencode.json(c)` and `.opencode/opencode.json(c)`, skills in `.claude/skills`, `.agents/skills` and
    ///   `.opencode/skill(s)`, commands in `.opencode/command(s)`, agents in `.opencode/agent(s)`, plugin files in
    ///   `.opencode/plugin(s)`.
    /// - Untrusted folder: Ensemble's private server runs with project config off, which drops every project item above
    ///   (checked: only the user's skills, commands, agents and MCP servers were listed).
    static func openCode(_ context: CustomizationsContext, into report: inout CustomizationsReport) {
        let env = context.environment
        let config = env.openCodeConfigDirectory
        let home = env.homeDirectory
        let levels = Array(context.openCodeLevels.reversed())

        // Config files: user first, then the project's from the top folder down.
        var configs: [(path: String, json: JSONValue, scope: CustomizationScope)] = []
        for name in ["config.json", "opencode.json", "opencode.jsonc"] {
            let path = (config as NSString).appendingPathComponent(name)
            if let json = CustomizationFiles.json(path) { configs.append((path, json, .user)) }
        }
        for level in levels {
            for name in CustomizationFiles.children(level) where ["opencode.json", "opencode.jsonc"].contains(name.lowercased()) {
                let path = (level as NSString).appendingPathComponent(name)
                if let json = CustomizationFiles.json(path) { configs.append((path, json, .project)) }
            }
            for name in ["opencode.json", "opencode.jsonc"] {
                let path = ((level as NSString).appendingPathComponent(".opencode") as NSString).appendingPathComponent(name)
                if let json = CustomizationFiles.json(path) { configs.append((path, json, .project)) }
            }
        }
        func status(_ scope: CustomizationScope) -> CustomizationStatus { scope.isProject ? context.projectStatus() : .loaded }

        // Rules: AGENTS.md files, then `instructions` entries.
        if let global = rule(.openCode, .instructions, scope: .user, path: (config as NSString).appendingPathComponent("AGENTS.md"),
                             status: .loaded) {
            report.rules.append(global)
        }
        for level in levels {
            if let local = rule(.openCode, .instructions, scope: .project, path: (level as NSString).appendingPathComponent("AGENTS.md"),
                                status: context.projectStatus()) {
                report.rules.append(local)
            }
        }
        for config in configs {
            let base = (config.path as NSString).deletingLastPathComponent
            let note = "From \((config.path as NSString).lastPathComponent) instructions"
            for entry in (config.json["instructions"]?.arrayValue ?? []).compactMap(\.stringValue) {
                if entry.contains("://") {
                    report.rules.append(CustomizationRule(engine: .openCode, kind: .instructions, scope: config.scope,
                                                          path: CustomizationRedaction.url(entry), isFile: false,
                                                          status: status(config.scope), note: note))
                } else if entry.contains(where: { "*?[{".contains($0) }) {
                    report.rules.append(CustomizationRule(engine: .openCode, kind: .instructions, scope: config.scope,
                                                          path: CustomizationRedaction.text(entry), isFile: false,
                                                          status: status(config.scope), note: note + ", pattern"))
                } else {
                    let expanded = CustomizationFiles.expand(entry, home: home)
                    let path = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
                    let standard = WorkspaceTrust.resolvedPath(path) ?? path
                    if let found = rule(.openCode, .instructions, scope: config.scope, path: standard, status: status(config.scope),
                                        note: note) {
                        report.rules.append(found)
                    }
                }
            }
        }

        // Skills, commands and agents.
        let claudeSkills = (home as NSString).appendingPathComponent(".claude/skills")
        report.entries += skills(.openCode, in: claudeSkills, scope: .user, status: .loaded, note: "Shared from ~/.claude/skills")
        report.entries += skills(.openCode, in: (home as NSString).appendingPathComponent(".agents/skills"), scope: .user, status: .loaded)
        for name in ["skills", "skill"] {
            report.entries += skills(.openCode, in: (config as NSString).appendingPathComponent(name), scope: .user, status: .loaded)
        }
        for name in ["commands", "command"] {
            report.entries += markdownEntries(.openCode, .command, in: (config as NSString).appendingPathComponent(name),
                                              scope: .user, status: .loaded)
        }
        for name in ["agents", "agent"] {
            report.entries += markdownEntries(.openCode, .agent, in: (config as NSString).appendingPathComponent(name),
                                              scope: .user, status: .loaded, recursive: false)
        }
        for level in levels {
            func sub(_ path: String) -> String { (level as NSString).appendingPathComponent(path) }
            for path in [".claude/skills", ".agents/skills", ".opencode/skills", ".opencode/skill"] where sub(path) != claudeSkills {
                report.entries += skills(.openCode, in: sub(path), scope: .project, status: context.projectStatus())
            }
            for path in [".opencode/commands", ".opencode/command"] {
                report.entries += markdownEntries(.openCode, .command, in: sub(path), scope: .project, status: context.projectStatus())
            }
            for path in [".opencode/agents", ".opencode/agent"] {
                report.entries += markdownEntries(.openCode, .agent, in: sub(path), scope: .project, status: context.projectStatus(),
                                                  recursive: false)
            }
        }
        for config in configs {
            for (name, value) in (config.json["command"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                report.entries.append(CustomizationEntry(engine: .openCode, kind: .command, name: name,
                                                         summary: CustomizationFiles.summary(value["description"]?.stringValue),
                                                         path: config.path, scope: config.scope, status: status(config.scope)))
            }
            for (name, value) in (config.json["agent"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                var entryStatus = status(config.scope)
                if entryStatus.isActive, value["disable"]?.boolValue == true { entryStatus = .disabled("disable is true in its config") }
                report.entries.append(CustomizationEntry(engine: .openCode, kind: .agent, name: name,
                                                         summary: CustomizationFiles.summary(value["description"]?.stringValue),
                                                         path: config.path, scope: config.scope, status: entryStatus))
            }
        }

        // MCP servers.
        for config in configs {
            for (name, server) in (config.json["mcp"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) where server.objectValue != nil {
                report.mcpServers.append(mcpServer(.openCode, name: name, config: server, scope: config.scope, source: config.path,
                                                   status: status(config.scope)))
            }
        }

        // Plugins: `plugin` entries in config files, then plugin files.
        for config in configs {
            for spec in (config.json["plugin"]?.arrayValue ?? []).compactMap({ $0.stringValue ?? $0.arrayValue?.first?.stringValue }) {
                let isFile = spec.hasPrefix("file:") || spec.hasPrefix("/") || spec.hasPrefix(".") || spec.hasPrefix("~")
                report.hooks.append(CustomizationHook(engine: .openCode, kind: .plugin, scope: config.scope, event: "Plugin",
                                                      name: spec, handler: isFile ? "file" : "package",
                                                      command: CustomizationRedaction.text(spec), sourcePath: config.path,
                                                      status: status(config.scope)))
            }
        }
        var pluginFolders: [(String, CustomizationScope)] = ["plugins", "plugin"].map {
            ((config as NSString).appendingPathComponent($0), CustomizationScope.user)
        }
        for level in levels {
            pluginFolders += [".opencode/plugins", ".opencode/plugin"].map { ((level as NSString).appendingPathComponent($0), .project) }
        }
        let codeExtensions: Set<String> = ["js", "ts", "mjs", "cjs", "mts", "cts", "jsx", "tsx"]
        for (folder, scope) in pluginFolders where CustomizationFiles.isDirectory(folder) {
            for name in CustomizationFiles.children(folder) where codeExtensions.contains((name as NSString).pathExtension.lowercased()) {
                let path = (folder as NSString).appendingPathComponent(name)
                report.hooks.append(CustomizationHook(engine: .openCode, kind: .plugin, scope: scope, event: "Plugin",
                                                      name: (name as NSString).deletingPathExtension, handler: "file",
                                                      command: relativePath(path, to: context.folder, home: home),
                                                      sourcePath: path, status: status(scope)))
            }
        }
    }
}
