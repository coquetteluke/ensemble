import Foundation

extension CustomizationsDiscovery {
    /// Customization roots agy looks for in a project folder.
    static let geminiRoots = [".agents", ".agent", "_agents", "_agent"]

    /// What agy loads, from its bundled customization guide (`~/.gemini/antigravity/builtin/skills/agy-customizations`)
    /// and the paths in the agy 1.5.10 binary:
    /// - User: `~/.gemini/GEMINI.md`, `~/.gemini/AGENTS.md` and the same two in `~/.gemini/config/`; `config/rules/*.md`;
    ///   `config/skills/*/SKILL.md` and folders listed in `config/skills.json`; `config/global_workflows/*.md`;
    ///   `config/mcp_config.json`; `config/hooks.json`; plugins in `config/plugins/<name>/` (their `skills/`, `rules/`,
    ///   `hooks.json` and `mcp_config.json`).
    /// - Project, from the folder up to the repository root (`geminiLevels`): `GEMINI.md` and `AGENTS.md`, and in each
    ///   customization root (`.agents/`, `.agent/`, `_agents/`, `_agent/`) `rules/*.md` (front matter `trigger`:
    ///   `always_on`, `model_decision`, `glob` with `globs`, or `manual`), `skills/`, `skills.json`, `workflows/`,
    ///   `hooks.json` and `plugins/`. `GEMINI.md` and `AGENTS.md` in subfolders load when agy works on files there.
    /// - Untrusted folder: Ensemble does not start agy at all (it runs a folder's hooks and rules with no way to turn
    ///   them off), so nothing loads, user items included.
    static func gemini(_ context: CustomizationsContext, into report: inout CustomizationsReport) {
        let home = context.environment.homeDirectory
        let base = context.environment.geminiDirectory
        let config = (base as NSString).appendingPathComponent("config")
        let levels = Array(context.geminiLevels.reversed())
        let repoRoot = context.geminiLevels.last ?? context.folder
        func status(_ scope: CustomizationScope, _ trigger: CustomizationStatus = .loaded) -> CustomizationStatus {
            guard context.trusted else { return .notStarted }
            return trigger
        }
        var seen = Set<String>()
        func add(_ rule: CustomizationRule?) {
            guard let rule else { return }
            let key = WorkspaceTrust.resolvedPath(rule.path) ?? rule.path
            guard seen.insert(key).inserted else { return }
            report.rules.append(rule)
        }
        func triggered(_ file: String) -> CustomizationStatus {
            let markdown = CustomizationFiles.markdown(file)
            switch markdown?.string("trigger")?.lowercased() {
            case "model_decision": return .onDemand("Read when the agent decides it applies")
            case "glob":
                let globs = markdown?.list("globs") ?? []
                return .onDemand(globs.isEmpty ? "Applies to matching files" : "Applies to \(globs.joined(separator: ", "))")
            case "manual": return .onDemand("Only when you mention it")
            default: return .loaded
            }
        }
        func ruleFiles(_ folder: String, scope: CustomizationScope) {
            for file in CustomizationFiles.markdownFiles(in: folder, recursive: false) {
                add(rule(.gemini, .rule, scope: scope, path: file, status: status(scope, triggered(file))))
            }
        }

        // Rules.
        for path in ["GEMINI.md", "AGENTS.md", "config/GEMINI.md", "config/AGENTS.md"] {
            add(rule(.gemini, .instructions, scope: .user, path: (base as NSString).appendingPathComponent(path), status: status(.user)))
        }
        ruleFiles((config as NSString).appendingPathComponent("rules"), scope: .user)
        var projectRoots: [String] = []
        for level in levels {
            for name in ["GEMINI.md", "AGENTS.md"] {
                add(rule(.gemini, .instructions, scope: .project, path: (level as NSString).appendingPathComponent(name),
                         status: status(.project)))
            }
            for root in geminiRoots {
                let path = (level as NSString).appendingPathComponent(root)
                if CustomizationFiles.isDirectory(path) { projectRoots.append(path) }
            }
        }
        for root in projectRoots { ruleFiles((root as NSString).appendingPathComponent("rules"), scope: .project) }
        for file in context.nestedFiles where ["GEMINI.md", "AGENTS.md"].contains((file as NSString).lastPathComponent) {
            let sub = relativePath((file as NSString).deletingLastPathComponent, to: context.folder, home: home)
            add(rule(.gemini, .instructions, scope: .project, path: file,
                     status: status(.project, .onDemand("Loads when Gemini works on files in \(sub)/"))))
        }

        // Skills and workflows.
        func skillsJSON(_ root: String, scope: CustomizationScope) {
            guard let json = CustomizationFiles.json((root as NSString).appendingPathComponent("skills.json")) else { return }
            for entry in json["entries"]?.arrayValue ?? [] {
                guard let raw = entry["path"]?.stringValue else { continue }
                let expanded = CustomizationFiles.expand(raw, home: home)
                let path = expanded.hasPrefix("/") ? expanded : (repoRoot as NSString).appendingPathComponent(expanded)
                report.entries += skills(.gemini, in: WorkspaceTrust.resolvedPath(path) ?? path, scope: scope, status: status(scope))
            }
        }
        report.entries += skills(.gemini, in: (config as NSString).appendingPathComponent("skills"), scope: .user, status: status(.user))
        skillsJSON(config, scope: .user)
        for name in ["global_workflows", "workflows"] {
            report.entries += markdownEntries(.gemini, .command, in: (config as NSString).appendingPathComponent(name), scope: .user,
                                              status: status(.user), recursive: false)
        }
        for root in projectRoots {
            report.entries += skills(.gemini, in: (root as NSString).appendingPathComponent("skills"), scope: .project,
                                     status: status(.project))
            skillsJSON(root, scope: .project)
            report.entries += markdownEntries(.gemini, .command, in: (root as NSString).appendingPathComponent("workflows"),
                                              scope: .project, status: status(.project), recursive: false)
        }

        // MCP servers and hooks.
        let mcpPath = (config as NSString).appendingPathComponent("mcp_config.json")
        for (name, server) in (CustomizationFiles.json(mcpPath)?["mcpServers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            report.mcpServers.append(mcpServer(.gemini, name: name, config: server, scope: .user, source: mcpPath, status: status(.user)))
        }
        report.hooks += geminiHooks(at: (config as NSString).appendingPathComponent("hooks.json"), scope: .user, status: status(.user))
        for root in projectRoots {
            report.hooks += geminiHooks(at: (root as NSString).appendingPathComponent("hooks.json"), scope: .project,
                                        status: status(.project))
        }

        // Plugins.
        var pluginFolders = [((config as NSString).appendingPathComponent("plugins"), CustomizationScope.user)]
        pluginFolders += projectRoots.map { (($0 as NSString).appendingPathComponent("plugins"), CustomizationScope.project) }
        for (folder, ownerScope) in pluginFolders {
            for name in CustomizationFiles.children(folder) {
                let root = (folder as NSString).appendingPathComponent(name)
                let manifest = (root as NSString).appendingPathComponent("plugin.json")
                guard CustomizationFiles.isFile(manifest) else { continue }
                let pluginName = CustomizationFiles.json(manifest)?["name"]?.stringValue ?? name
                let scope = CustomizationScope.plugin(pluginName)
                let pluginStatus = status(ownerScope)
                report.entries += skills(.gemini, in: (root as NSString).appendingPathComponent("skills"), scope: scope, status: pluginStatus)
                for file in CustomizationFiles.markdownFiles(in: (root as NSString).appendingPathComponent("rules"), recursive: false) {
                    add(rule(.gemini, .rule, scope: scope, path: file, status: pluginStatus))
                }
                let pluginMCP = (root as NSString).appendingPathComponent("mcp_config.json")
                for (server, value) in (CustomizationFiles.json(pluginMCP)?["mcpServers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                    report.mcpServers.append(mcpServer(.gemini, name: server, config: value, scope: scope, source: pluginMCP,
                                                       status: pluginStatus))
                }
                for hooksFile in ["hooks.json", "hooks/hooks.json"] {
                    report.hooks += geminiHooks(at: (root as NSString).appendingPathComponent(hooksFile), scope: scope, status: pluginStatus)
                }
            }
        }
    }

    /// agy's `hooks.json`: named hooks, each with `enabled` and event lists in the Claude shape.
    static func geminiHooks(at path: String, scope: CustomizationScope, status: CustomizationStatus) -> [CustomizationHook] {
        guard let named = CustomizationFiles.json(path)?.objectValue else { return [] }
        var result: [CustomizationHook] = []
        for name in named.keys.sorted() {
            guard let spec = named[name]?.objectValue else { continue }
            let off = spec["enabled"]?.boolValue == false
            let events = spec.filter { $0.key != "enabled" && $0.value.arrayValue != nil }
            result += hooks(.gemini, events: events, scope: scope, source: path,
                            status: off && status.isActive ? .disabled("enabled is false") : status, name: name)
        }
        return result
    }
}
