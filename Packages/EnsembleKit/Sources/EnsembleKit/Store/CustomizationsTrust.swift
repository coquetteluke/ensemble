import Foundation

extension CustomizationsDiscovery {
    /// Per engine, what trusting the folder changes and which project files are skipped now. The skipped list joins
    /// the items discovery marked skipped with `ProjectTrustFiles` (what the trust card lists), so the screen and the
    /// card never disagree.
    static func trustSummary(for report: CustomizationsReport, files: ProjectTrustFiles,
                             canBeTrusted: Bool = true, home: String = NSHomeDirectory()) -> CustomizationTrustSummary {
        let folder = report.folder
        let trusted = report.trusted

        func display(_ path: String) -> String {
            let relative = relativePath(path, to: folder, home: home)
            // Skills, commands and agents are listed by their folder, not file by file.
            for marker in ["skills/", "skill/", "commands/", "command/", "agents/", "agent/", "workflows/"] {
                if let range = relative.range(of: "/" + marker) ?? (relative.hasPrefix(marker) ? relative.range(of: marker) : nil) {
                    return String(relative[..<range.upperBound])
                }
            }
            return relative
        }

        func skipped(_ engine: CustomizationEngine, projectOnly: Bool) -> [String] {
            var result: [String] = []
            func take(_ status: CustomizationStatus, _ scope: CustomizationScope) -> Bool {
                projectOnly ? scope.isProject && !status.isActive : status == .skippedUntrusted
            }
            for rule in report.rules(for: engine) where take(rule.status, rule.scope) {
                result.append(rule.isFile ? display(rule.path) : rule.path)
            }
            for entry in report.entries(for: engine) where take(entry.status, entry.scope) && entry.isFile {
                result.append(display(entry.path))
            }
            for server in report.mcpServers(for: engine) where take(server.status, server.scope) {
                if server.scope == .local {
                    result.append("MCP server \(server.name) (local scope)")
                } else if let source = server.sourcePath {
                    result.append(display(source))
                }
            }
            for hook in report.hooks(for: engine) where take(hook.status, hook.scope) {
                if let source = hook.sourcePath { result.append(display(source)) }
            }
            var seen = Set<String>()
            return result.filter { seen.insert($0).inserted }
        }

        func merged(_ found: [String], _ scanned: [String]) -> [String] {
            var seen = Set<String>()
            return (found + scanned).filter { seen.insert($0.hasSuffix("/") ? String($0.dropLast()) : $0).inserted }
        }

        var notes: [CustomizationTrustSummary.EngineNote] = []
        if trusted {
            notes.append(.init(engine: .claude, headline: "Loads this folder's settings",
                               detail: "Project memory, rules, settings, hooks, skills and MCP servers load from the next message.",
                               skipped: []))
            notes.append(.init(engine: .openCode, headline: "Loads this folder's config",
                               detail: "New sessions here run on your OpenCode service with the folder's opencode.json, .opencode/ and AGENTS.md.",
                               skipped: []))
            notes.append(.init(engine: .gemini, headline: "Starts here with the folder's rules and hooks",
                               detail: "agy loads GEMINI.md, AGENTS.md and .agents/ from this folder up to the repository root.",
                               skipped: []))
        } else {
            notes.append(.init(engine: .claude, headline: "Runs with your own settings only",
                               detail: "Claude skips this folder's memory, rules, settings, hooks, skills and MCP servers.",
                               skipped: merged(skipped(.claude, projectOnly: false), files.claude)))
            notes.append(.init(engine: .openCode, headline: "Runs without this folder's config",
                               detail: "New sessions here run on Ensemble's private OpenCode server, which skips project config. "
                                   + "Sessions started before you trust the folder keep skipping it.",
                               skipped: merged(skipped(.openCode, projectOnly: false), files.openCode)))
            notes.append(.init(engine: .gemini, headline: "Does not start here",
                               detail: "agy runs a folder's hooks and rules with no way to turn them off, so Ensemble only starts it "
                                   + "in folders you trust.",
                               skipped: merged(skipped(.gemini, projectOnly: true), files.gemini)))
        }
        return CustomizationTrustSummary(folder: folder, trusted: trusted, canBeTrusted: canBeTrusted, notes: notes)
    }
}
