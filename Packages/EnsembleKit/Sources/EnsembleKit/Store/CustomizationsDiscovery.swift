import Foundation

/// Where each engine keeps the user's own config. Built from the home folder and the app's environment, the same way
/// the engines find them.
public struct CustomizationsEnvironment: Hashable, Sendable {
    public var homeDirectory: String
    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public var claudeConfigDirectory: String
    /// The claude CLI's own state file with user and local MCP servers: `$CLAUDE_CONFIG_DIR/.claude.json`, else
    /// `~/.claude.json`. Only `mcpServers` and `projects.<folder>.mcpServers` are read from it.
    public var claudeStateFile: String
    /// `$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`.
    public var openCodeConfigDirectory: String
    /// `~/.gemini`.
    public var geminiDirectory: String

    public init(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = WorkspaceTrust.resolvedPath(homeDirectory) ?? homeDirectory
        func resolved(_ path: String) -> String {
            let expanded = CustomizationFiles.expand(path, home: home)
            return WorkspaceTrust.resolvedPath(expanded) ?? expanded
        }
        self.homeDirectory = home
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            claudeConfigDirectory = resolved(config)
            claudeStateFile = (claudeConfigDirectory as NSString).appendingPathComponent(".claude.json")
        } else {
            claudeConfigDirectory = (home as NSString).appendingPathComponent(".claude")
            claudeStateFile = (home as NSString).appendingPathComponent(".claude.json")
        }
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : resolved($0) }
            ?? (home as NSString).appendingPathComponent(".config")
        openCodeConfigDirectory = (xdg as NSString).appendingPathComponent("opencode")
        geminiDirectory = (home as NSString).appendingPathComponent(".gemini")
    }
}

/// Finds, for one folder, what Claude, OpenCode and Gemini load: rules and memory, skills, commands and agents, MCP
/// servers, hooks and plugins, each with whether the engine uses it now (`CustomizationStatus`).
///
/// Reads files only: it never runs a hook, plugin, MCP server or engine, never opens sign-in stores
/// (`CustomizationFiles.isForbidden`), and passes every value it shows through `CustomizationRedaction`. The rules
/// for each engine, and how trust changes them, are on `claude`, `openCode` and `gemini`; they match what the engines
/// did when checked (2026-11-18: claude 2.1.319, OpenCode 2.3.0, agy 1.5.10).
public enum CustomizationsDiscovery {
    /// Everything for `folder`. `trusted` is the folder's state in `WorkspaceTrust`.
    public static func discover(folder: String, trusted: Bool,
                                environment: CustomizationsEnvironment = CustomizationsEnvironment()) -> CustomizationsReport {
        let context = CustomizationsContext(folder: folder, trusted: trusted, environment: environment)
        var report = CustomizationsReport(folder: context.folder, trusted: trusted)
        claude(context, into: &report)
        openCode(context, into: &report)
        gemini(context, into: &report)
        report.trust = trustSummary(for: report, files: ProjectTrustFiles.scan(context.folder, homeDirectory: environment.homeDirectory),
                                    canBeTrusted: !context.isHomeOrAbove, home: environment.homeDirectory)
        return report
    }

    /// Everything for `folder`, trusted or not as `trust` says.
    public static func discover(folder: String, trust: WorkspaceTrust,
                                environment: CustomizationsEnvironment = CustomizationsEnvironment()) -> CustomizationsReport {
        discover(folder: folder, trusted: trust.isTrusted(folder), environment: environment)
    }

    /// `path` relative to `folder`: `CLAUDE.md`, `sub/CLAUDE.md`, `../AGENTS.md` for a folder above it; otherwise the
    /// path with the home folder as `~`.
    public static func relativePath(_ path: String, to folder: String, home: String = NSHomeDirectory()) -> String {
        if path == folder { return "." }
        if path.hasPrefix(folder + "/") { return String(path.dropFirst(folder.count + 1)) }
        // `../` only for folders below the home folder; the home folder and above read better as `~/...` or absolute.
        let homeResolved = WorkspaceTrust.resolvedPath(home) ?? home
        var base = folder
        var ups = ""
        while true {
            let parent = (base as NSString).deletingLastPathComponent
            guard parent != base, parent.hasPrefix(homeResolved + "/") else { break }
            base = parent
            ups += "../"
            if path.hasPrefix(base + "/") { return ups + path.dropFirst(base.count + 1) }
        }
        return abbreviate(path, home: home)
    }

    static func abbreviate(_ path: String, home: String) -> String {
        let homeResolved = WorkspaceTrust.resolvedPath(home) ?? home
        for base in [homeResolved, home] {
            if path == base { return "~" }
            if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        }
        return path
    }
}

/// The folder and the facts every engine's rules need.
struct CustomizationsContext {
    let folder: String
    let trusted: Bool
    let environment: CustomizationsEnvironment
    /// The folder is the home folder or a folder above it: nothing there counts as a project.
    let isHomeOrAbove: Bool
    /// `CLAUDE.md`, `CLAUDE.local.md`, `GEMINI.md` and `AGENTS.md` files in subfolders (not the folder itself).
    let nestedFiles: [String]

    var home: String { environment.homeDirectory }

    init(folder: String, trusted: Bool, environment: CustomizationsEnvironment, scanNested: Bool = true) {
        let root = WorkspaceTrust.resolvedPath(folder) ?? folder
        self.folder = root
        self.trusted = trusted
        self.environment = environment
        let rootParts = WorkspaceTrust.components(root) ?? []
        let homeParts = WorkspaceTrust.components(environment.homeDirectory) ?? []
        isHomeOrAbove = homeParts.count >= rootParts.count && Array(homeParts.prefix(rootParts.count)) == rootParts
        nestedFiles = isHomeOrAbove || !scanNested ? [] : Self.scanNested(root)
    }

    /// The folder and every folder above it, the folder first, ending with `/`.
    var ancestors: [String] {
        var result = [folder]
        var current = folder
        while current != "/", !current.isEmpty {
            current = (current as NSString).deletingLastPathComponent
            result.append(current.isEmpty ? "/" : current)
        }
        return result
    }

    /// OpenCode's project folders: the folder and each one above it, up to (not including) the home folder, or up to
    /// the top for folders outside it. Same walk as `ProjectTrustFiles.scan`.
    var openCodeLevels: [String] {
        guard !isHomeOrAbove, let rootParts = WorkspaceTrust.components(folder) else { return [] }
        let homeParts = WorkspaceTrust.components(home) ?? []
        let underHome = rootParts.count > homeParts.count && Array(rootParts.prefix(homeParts.count)) == homeParts
        let lowest = underHome ? homeParts.count + 1 : 1
        guard rootParts.count >= lowest else { return [] }
        return stride(from: rootParts.count, through: lowest, by: -1).map { "/" + rootParts.prefix($0).joined(separator: "/") }
    }

    /// agy's project folders: the folder and each one above it up to the repository root (the nearest folder with a
    /// `.git`), never the home folder or above. Without a repository, the folder alone.
    var geminiLevels: [String] {
        guard !isHomeOrAbove else { return [] }
        let levels = openCodeLevels
        if let rootIndex = levels.firstIndex(where: { CustomizationFiles.fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }) {
            return Array(levels[...rootIndex])
        }
        return [folder]
    }

    /// Status of a project item in this folder: loaded (or `trigger`) when trusted, skipped otherwise.
    func projectStatus(_ whenTrusted: CustomizationStatus = .loaded) -> CustomizationStatus {
        trusted ? whenTrusted : .skippedUntrusted
    }

    /// Instruction files in subfolders, at most 4 levels down, skipping hidden folders, dependency and build folders,
    /// and stopping after 2,000 folders.
    static func scanNested(_ root: String) -> [String] {
        let names: Set<String> = ["CLAUDE.md", "CLAUDE.local.md", "GEMINI.md", "AGENTS.md"]
        let skipped: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "vendor", "target", "venv",
                                    "__pycache__", "Carthage", "out", "coverage"]
        var found: [String] = []
        var visited = 0
        func walk(_ folder: String, depth: Int) {
            guard depth <= 4, visited < 2000 else { return }
            visited += 1
            for name in CustomizationFiles.children(folder) {
                let path = (folder as NSString).appendingPathComponent(name)
                if depth > 0, names.contains(name), CustomizationFiles.isFile(path) {
                    found.append(path)
                } else if !name.hasPrefix("."), !skipped.contains(name), !names.contains(name),
                          (try? CustomizationFiles.fm.destinationOfSymbolicLink(atPath: path)) == nil,
                          CustomizationFiles.isDirectory(path) {
                    walk(path, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return found.sorted()
    }
}

// MARK: Shared builders

extension CustomizationsDiscovery {
    /// A rule from a Markdown file, with size and first lines. Nil when the file does not exist.
    static func rule(_ engine: CustomizationEngine, _ kind: CustomizationRule.Kind, scope: CustomizationScope, path: String,
                     status: CustomizationStatus, note: String? = nil) -> CustomizationRule? {
        guard CustomizationFiles.isFile(path), !CustomizationFiles.isForbidden(path) else { return nil }
        let markdown = CustomizationFiles.markdown(path) ?? CustomizationFiles.Markdown()
        return CustomizationRule(engine: engine, kind: kind, scope: scope, path: path, size: CustomizationFiles.size(path),
                                 firstLines: CustomizationFiles.previewLines(markdown), status: status, note: note)
    }

    /// Skills in `<directory>/<name>/SKILL.md`, named by their front matter (`name`), else the folder.
    static func skills(_ engine: CustomizationEngine, in directory: String, scope: CustomizationScope,
                       status: CustomizationStatus, prefix: String = "", note: String? = nil) -> [CustomizationEntry] {
        CustomizationFiles.skillFiles(in: directory).map { file in
            let markdown = CustomizationFiles.markdown(file) ?? CustomizationFiles.Markdown()
            let folderName = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let name = markdown.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? folderName
            return CustomizationEntry(engine: engine, kind: .skill, name: prefix + name,
                                      summary: CustomizationFiles.summary(markdown.string("description")), path: file,
                                      scope: scope, status: status, note: note)
        }
    }

    /// Commands or agents from Markdown files. Commands in subfolders are named `folder:name`, like the CLIs do.
    static func markdownEntries(_ engine: CustomizationEngine, _ kind: CustomizationEntry.Kind, in directory: String,
                                scope: CustomizationScope, status: CustomizationStatus, recursive: Bool = true,
                                prefix: String = "") -> [CustomizationEntry] {
        CustomizationFiles.markdownFiles(in: directory, recursive: recursive).map { file in
            let markdown = CustomizationFiles.markdown(file) ?? CustomizationFiles.Markdown()
            var relative = String(file.dropFirst(directory.count + 1))
            if relative.lowercased().hasSuffix(".md") { relative = String(relative.dropLast(3)) }
            let derived = relative.replacingOccurrences(of: "/", with: ":")
            let name = kind == .agent ? (markdown.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? derived) : derived
            let summary = markdown.string("description") ?? CustomizationFiles.previewLines(markdown, count: 1).first
            return CustomizationEntry(engine: engine, kind: kind, name: prefix + name, summary: CustomizationFiles.summary(summary),
                                      path: file, scope: scope, status: status)
        }
    }

    /// One MCP server entry from any engine's config: `command`/`args`/`env` or OpenCode's `command` list and
    /// `environment`; `url` (or agy's `serverUrl`) with `headers`. Values of `env`, `environment` and `headers` are
    /// never read, only their names.
    static func mcpServer(_ engine: CustomizationEngine, name: String, config: JSONValue, scope: CustomizationScope,
                          source: String?, status: CustomizationStatus) -> CustomizationMCPServer {
        let type = config["type"]?.stringValue?.lowercased()
        var transport: CustomizationMCPServer.Transport = .unknown
        var target = ""
        if let list = config["command"]?.arrayValue {
            let parts = list.compactMap(\.stringValue)
            transport = .stdio
            target = CustomizationRedaction.command(parts)
        } else if let command = config["command"]?.stringValue {
            let args = (config["args"]?.arrayValue ?? []).compactMap(\.stringValue)
            transport = .stdio
            target = CustomizationRedaction.command([command] + args)
        } else if let url = config["url"]?.stringValue ?? config["serverUrl"]?.stringValue ?? config["httpUrl"]?.stringValue {
            transport = type == "sse" ? .sse : .http
            target = CustomizationRedaction.url(url)
        }
        let environmentKeys = Array((config["env"]?.objectValue ?? config["environment"]?.objectValue ?? [:]).keys).sorted()
        let headerKeys = Array((config["headers"]?.objectValue ?? [:]).keys).sorted()
        var finalStatus = status
        if status.isActive {
            if config["enabled"]?.boolValue == false { finalStatus = .disabled("enabled is false in its config") }
            if config["disabled"]?.boolValue == true { finalStatus = .disabled("disabled is true in its config") }
        }
        return CustomizationMCPServer(engine: engine, scope: scope, name: name, transport: transport, target: target,
                                      environmentKeys: environmentKeys, headerKeys: headerKeys, sourcePath: source,
                                      status: finalStatus)
    }

    /// Hooks in the Claude and agy shape: `{"<Event>": [{"matcher": "...", "hooks": [{"type": "command",
    /// "command": "..."}]}]}`, where agy also allows a handler directly in the event's list.
    static func hooks(_ engine: CustomizationEngine, events: [String: JSONValue], scope: CustomizationScope, source: String,
                      status: CustomizationStatus, name: String? = nil) -> [CustomizationHook] {
        var result: [CustomizationHook] = []
        for event in events.keys.sorted() {
            guard let groups = events[event]?.arrayValue else { continue }
            for group in groups {
                let matcher = group["matcher"]?.stringValue.flatMap { $0.isEmpty ? nil : CustomizationRedaction.text($0) }
                let handlers = group["hooks"]?.arrayValue ?? (group["command"] != nil || group["type"] != nil ? [group] : [])
                for handler in handlers {
                    let type = handler["type"]?.stringValue ?? "command"
                    result.append(CustomizationHook(engine: engine, scope: scope, event: event, matcher: matcher, name: name,
                                                    handler: type, command: hookCommand(handler, type: type), sourcePath: source,
                                                    status: status))
                }
            }
        }
        return result
    }

    static func hookCommand(_ handler: JSONValue, type: String) -> String {
        switch type {
        case "http":
            return handler["url"]?.stringValue.map(CustomizationRedaction.url) ?? ""
        case "prompt", "agent":
            let text = CustomizationFiles.summary(handler["prompt"]?.stringValue)
            return text.count > 140 ? String(text.prefix(139)) + "…" : text
        case "mcp_tool":
            let parts = [handler["server"]?.stringValue, handler["tool"]?.stringValue].compactMap { $0 }
            return parts.joined(separator: " ")
        default:
            if let list = handler["command"]?.arrayValue { return CustomizationRedaction.command(list.compactMap(\.stringValue)) }
            return CustomizationRedaction.text(handler["command"]?.stringValue ?? "")
        }
    }
}
