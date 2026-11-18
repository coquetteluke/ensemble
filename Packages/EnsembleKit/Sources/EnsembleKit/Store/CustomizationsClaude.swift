import Foundation

extension CustomizationsDiscovery {
    /// What the claude CLI loads, checked against the CLI itself (claude 2.1.319, 2026-11-18, with its
    /// `get_context_usage` and `mcp_status` answers in a synthetic folder and config folder):
    /// - User (`~/.claude` or `$CLAUDE_CONFIG_DIR`): `CLAUDE.md`, `rules/**/*.md`, `skills/*/SKILL.md`,
    ///   `commands/**/*.md`, `agents/*.md`, hooks in `settings.json`, MCP servers in `~/.claude.json` `mcpServers`, and
    ///   the plugins `settings.json` enables (their skills, commands, agents, `hooks/hooks.json` and `.mcp.json`).
    /// - Project, from the session folder up to `/`: `CLAUDE.md`, `.claude/CLAUDE.md` and `.claude/rules/*.md` in every
    ///   folder; `CLAUDE.local.md` in every folder (local). Rules with `paths` front matter and `CLAUDE.md` files in
    ///   subfolders load only when Claude reads matching files.
    /// - Project, session folder only: `.claude/settings.json` and `.claude/settings.local.json` (hooks), `.mcp.json`
    ///   (minus `disabledMcpjsonServers`), `.claude/skills`, `.claude/commands`, `.claude/agents`; local-scope MCP
    ///   servers in `~/.claude.json` `projects.<folder>.mcpServers`.
    /// - Untrusted folder: the engine runs the CLI with `--setting-sources user` (`ClaudeSettingSources.effective`), and
    ///   then every project and local item above is left out (checked: no project or local memory, rules, skills,
    ///   commands, project MCP or local MCP), while user items still load.
    static func claude(_ context: CustomizationsContext, into report: inout CustomizationsReport) {
        let env = context.environment
        let config = env.claudeConfigDirectory
        let folder = context.folder
        var seen = Set<String>()
        func add(_ rule: CustomizationRule?) {
            guard let rule, seen.insert(rule.path).inserted else { return }
            report.rules.append(rule)
        }
        func scopedRules(_ directory: String, scope: CustomizationScope, base: (CustomizationStatus) -> CustomizationStatus) {
            for file in CustomizationFiles.markdownFiles(in: directory, recursive: true) {
                let markdown = CustomizationFiles.markdown(file)
                let paths = markdown?.list("paths") ?? []
                let status = paths.isEmpty ? base(.loaded) : base(.onDemand("Applies to \(paths.joined(separator: ", "))"))
                add(rule(.claude, .rule, scope: scope, path: file, status: status))
            }
        }

        // Rules and memory: user first, then the folders from the top down to the session folder, then subfolders.
        add(rule(.claude, .memory, scope: .user, path: (config as NSString).appendingPathComponent("CLAUDE.md"), status: .loaded))
        scopedRules((config as NSString).appendingPathComponent("rules"), scope: .user) { $0 }
        for level in context.ancestors.reversed() {
            let dotClaude = (level as NSString).appendingPathComponent(".claude")
            add(rule(.claude, .memory, scope: .project, path: (level as NSString).appendingPathComponent("CLAUDE.md"),
                     status: context.projectStatus()))
            if dotClaude != config {
                add(rule(.claude, .memory, scope: .project, path: (dotClaude as NSString).appendingPathComponent("CLAUDE.md"),
                         status: context.projectStatus()))
                scopedRules((dotClaude as NSString).appendingPathComponent("rules"), scope: .project) { context.projectStatus($0) }
            }
            add(rule(.claude, .memory, scope: .local, path: (level as NSString).appendingPathComponent("CLAUDE.local.md"),
                     status: context.projectStatus()))
        }
        for file in context.nestedFiles where ["CLAUDE.md", "CLAUDE.local.md"].contains((file as NSString).lastPathComponent) {
            let sub = relativePath((file as NSString).deletingLastPathComponent, to: folder, home: env.homeDirectory)
            add(rule(.claude, .memory, scope: file.hasSuffix(".local.md") ? .local : .project, path: file,
                     status: context.projectStatus(.onDemand("Loads when Claude reads files in \(sub)/"))))
        }

        // Skills, commands and agents.
        let projectClaude = (folder as NSString).appendingPathComponent(".claude")
        let ownProject = projectClaude != config && !context.isHomeOrAbove
        report.entries += skills(.claude, in: (config as NSString).appendingPathComponent("skills"), scope: .user, status: .loaded)
        report.entries += markdownEntries(.claude, .command, in: (config as NSString).appendingPathComponent("commands"),
                                          scope: .user, status: .loaded)
        report.entries += markdownEntries(.claude, .agent, in: (config as NSString).appendingPathComponent("agents"),
                                          scope: .user, status: .loaded)
        if ownProject {
            report.entries += skills(.claude, in: (projectClaude as NSString).appendingPathComponent("skills"), scope: .project,
                                     status: context.projectStatus())
            report.entries += markdownEntries(.claude, .command, in: (projectClaude as NSString).appendingPathComponent("commands"),
                                              scope: .project, status: context.projectStatus())
            report.entries += markdownEntries(.claude, .agent, in: (projectClaude as NSString).appendingPathComponent("agents"),
                                              scope: .project, status: context.projectStatus())
        }

        // Settings: hooks and enabled plugins.
        let userSettingsPath = (config as NSString).appendingPathComponent("settings.json")
        let userSettings = CustomizationFiles.json(userSettingsPath)
        let userHooksOff = userSettings?["disableAllHooks"]?.boolValue == true
        if let events = userSettings?["hooks"]?.objectValue {
            report.hooks += hooks(.claude, events: events, scope: .user, source: userSettingsPath,
                                  status: userHooksOff ? .disabled("disableAllHooks is on") : .loaded)
        }
        var projectSettings: [(path: String, json: JSONValue, scope: CustomizationScope)] = []
        if ownProject {
            for (name, scope) in [("settings.json", CustomizationScope.project), ("settings.local.json", .local)] {
                let path = (projectClaude as NSString).appendingPathComponent(name)
                if let json = CustomizationFiles.json(path) { projectSettings.append((path, json, scope)) }
            }
        }
        let projectHooksOff = projectSettings.contains { $0.json["disableAllHooks"]?.boolValue == true }
        for settings in projectSettings {
            guard let events = settings.json["hooks"]?.objectValue else { continue }
            let status = (userHooksOff || projectHooksOff) && context.trusted ? .disabled("disableAllHooks is on") : context.projectStatus()
            report.hooks += hooks(.claude, events: events, scope: settings.scope, source: settings.path, status: status)
        }

        // MCP servers: user and local scope from the CLI's state file, project scope from `.mcp.json`.
        let state = CustomizationFiles.json(env.claudeStateFile)
        for (name, server) in (state?["mcpServers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            report.mcpServers.append(mcpServer(.claude, name: name, config: server, scope: .user, source: env.claudeStateFile,
                                               status: .loaded))
        }
        if !context.isHomeOrAbove, let projects = state?["projects"]?.objectValue {
            let entry = projects[folder] ?? projects.first { WorkspaceTrust.resolvedPath($0.key) == folder }?.value
            for (name, server) in (entry?["mcpServers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                report.mcpServers.append(mcpServer(.claude, name: name, config: server, scope: .local, source: env.claudeStateFile,
                                                   status: context.projectStatus()))
            }
        }
        if !context.isHomeOrAbove {
            let mcpPath = (folder as NSString).appendingPathComponent(".mcp.json")
            let disabled = Set(projectSettings.flatMap { ($0.json["disabledMcpjsonServers"]?.arrayValue ?? []).compactMap(\.stringValue) })
            for (name, server) in (CustomizationFiles.json(mcpPath)?["mcpServers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                let status: CustomizationStatus = context.trusted && disabled.contains(name)
                    ? .disabled("Listed in disabledMcpjsonServers") : context.projectStatus()
                report.mcpServers.append(mcpServer(.claude, name: name, config: server, scope: .project, source: mcpPath, status: status))
            }
        }

        // Plugins the user (and a trusted project) enabled.
        var enabled: [String] = []
        for settings in [userSettings] + (context.trusted ? projectSettings.map(\.json) : []) {
            for (id, value) in settings?["enabledPlugins"]?.objectValue ?? [:] where value.boolValue == true {
                if !enabled.contains(id) { enabled.append(id) }
            }
        }
        let installed = CustomizationFiles.json((config as NSString).appendingPathComponent("plugins/installed_plugins.json"))
        for id in enabled.sorted() {
            guard let installPath = pluginInstallPath(installed?["plugins"]?[id], folder: folder),
                  CustomizationFiles.isDirectory(installPath) else { continue }
            claudePlugin(name: String(id.split(separator: "@").first ?? Substring(id)), at: installPath, hooksOff: userHooksOff,
                         into: &report)
        }
    }

    /// The install folder of one plugin entry in `installed_plugins.json` (a list of installs, or one install).
    static func pluginInstallPath(_ entry: JSONValue?, folder: String) -> String? {
        let installs = entry?.arrayValue ?? (entry.map { [$0] } ?? [])
        let usable = installs.first { install in
            guard let project = install["projectPath"]?.stringValue else { return true }
            return (WorkspaceTrust.resolvedPath(project) ?? project) == folder
        }
        return usable?["installPath"]?.stringValue
    }

    static func claudePlugin(name: String, at root: String, hooksOff: Bool, into report: inout CustomizationsReport) {
        let scope = CustomizationScope.plugin(name)
        let prefix = name + ":"
        report.entries += skills(.claude, in: (root as NSString).appendingPathComponent("skills"), scope: scope, status: .loaded,
                                 prefix: prefix)
        report.entries += markdownEntries(.claude, .command, in: (root as NSString).appendingPathComponent("commands"),
                                          scope: scope, status: .loaded, prefix: prefix)
        report.entries += markdownEntries(.claude, .agent, in: (root as NSString).appendingPathComponent("agents"),
                                          scope: scope, status: .loaded, recursive: false, prefix: prefix)
        let hooksPath = (root as NSString).appendingPathComponent("hooks/hooks.json")
        if let json = CustomizationFiles.json(hooksPath), let events = json["hooks"]?.objectValue ?? json.objectValue {
            report.hooks += hooks(.claude, events: events, scope: scope, source: hooksPath,
                                  status: hooksOff ? .disabled("disableAllHooks is on") : .loaded)
        }
        let mcpPath = (root as NSString).appendingPathComponent(".mcp.json")
        if let json = CustomizationFiles.json(mcpPath) {
            let servers = json["mcpServers"]?.objectValue ?? json.objectValue ?? [:]
            for (server, config) in servers.sorted(by: { $0.key < $1.key }) where config.objectValue != nil {
                report.mcpServers.append(mcpServer(.claude, name: server, config: config, scope: scope, source: mcpPath, status: .loaded))
            }
        }
    }
}
