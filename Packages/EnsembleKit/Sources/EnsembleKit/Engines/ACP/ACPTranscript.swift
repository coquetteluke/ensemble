import Foundation

// Turning ACP session updates into Ensemble transcript rows and live events. Pure value types, so the same code runs
// for live turns, for `session/load` replays and in tests against captured agent output.

enum ACPFormatting {
    static let previewLimit = 4000
    static let diffLimit = 60_000

    static func trimmed(_ text: String, limit: Int = previewLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n..."
    }

    /// Paths inside the project are shown relative to it (agents report `/private/tmp/...` for `/tmp/...`).
    static func displayPath(_ path: String, directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        var bases = [directory]
        if directory.hasPrefix("/private/") { bases.append(String(directory.dropFirst(8))) } else { bases.append("/private" + directory) }
        for base in bases {
            if path == base { return "." }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }

    /// True when `path` is inside `directory` (after resolving links where the path exists).
    static func isInside(_ path: String, directory: String) -> Bool {
        let resolvedPath = WorkspaceTrust.resolvedPath(path) ?? path
        let resolvedDirectory = WorkspaceTrust.resolvedPath(directory) ?? directory
        if resolvedPath == resolvedDirectory { return true }
        let prefix = resolvedDirectory.hasSuffix("/") ? resolvedDirectory : resolvedDirectory + "/"
        return resolvedPath.hasPrefix(prefix)
    }

    /// The command of a shell tool call, from the raw input fields agents use.
    static func command(_ rawInput: JSONValue?) -> String? {
        for key in ["command", "CommandLine", "commandLine", "cmd"] {
            if let value = rawInput?[key]?.acpText { return value }
            if let parts = rawInput?[key]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty { return parts.map(shellQuoted).joined(separator: " ") }
        }
        return nil
    }

    /// One argument as a shell would need it written: as is when it holds only safe characters, else single-quoted.
    static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func prettyJSON(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if case .object(let object) = value, object.isEmpty { return nil }
        return value.prettyJSONText
    }
}

/// Unified diffs from old and new text.
enum ACPDiff {
    /// A unified diff with three lines of context. `oldText` nil is a new file. Very large inputs fall back to one hunk
    /// that removes all old lines and adds all new ones.
    static func unified(path: String, oldText: String?, newText: String) -> String {
        let old = lines(oldText ?? "")
        let new = lines(newText)
        let header = oldText == nil ? ["--- /dev/null", "+++ b/\(path)"] : ["--- a/\(path)", "+++ b/\(path)"]
        let body = hunks(old: old, new: new)
        return ACPFormatting.trimmed((header + body).joined(separator: "\n"), limit: ACPFormatting.diffLimit)
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private enum Op { case same(String), removed(String), added(String) }

    private static func script(old: [String], new: [String]) -> [Op] {
        // Common prefix and suffix first, so typical edits keep the table small.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var endOld = old.count, endNew = new.count
        while endOld > start, endNew > start, old[endOld - 1] == new[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        let a = Array(old[start..<endOld]), b = Array(new[start..<endNew])
        var middle: [Op] = []
        if a.count * b.count > 2_000_000 {
            middle = a.map { .removed($0) } + b.map { .added($0) }
        } else if !a.isEmpty || !b.isEmpty {
            // Longest common subsequence table, filled from the end.
            let width = b.count + 1
            var table = [Int32](repeating: 0, count: (a.count + 1) * width)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i * width + j] = a[i] == b[j] ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] {
                    middle.append(.same(a[i])); i += 1; j += 1
                } else if i < a.count, j == b.count || table[(i + 1) * width + j] >= table[i * width + j + 1] {
                    // Removals before additions, as unified diffs show them.
                    middle.append(.removed(a[i])); i += 1
                } else {
                    middle.append(.added(b[j])); j += 1
                }
            }
        }
        return old[0..<start].map { .same($0) } + middle + old[endOld...].map { .same($0) }
    }

    private static func hunks(old: [String], new: [String], context: Int = 3) -> [String] {
        let ops = script(old: old, new: new)
        guard ops.contains(where: { if case .same = $0 { false } else { true } }) else { return [] }
        // Indexes of changed ops, grouped into hunks when their context overlaps.
        var changed: [Int] = []
        for (index, op) in ops.enumerated() { if case .same = op {} else { changed.append(index) } }
        var groups: [(Int, Int)] = []
        for index in changed {
            let low = max(0, index - context), high = min(ops.count - 1, index + context)
            if let last = groups.last, low <= last.1 + 1 { groups[groups.count - 1].1 = max(last.1, high) } else { groups.append((low, high)) }
        }
        var output: [String] = []
        for (low, high) in groups {
            var oldLine = 1, newLine = 1
            for op in ops[0..<low] {
                switch op {
                case .same: oldLine += 1; newLine += 1
                case .removed: oldLine += 1
                case .added: newLine += 1
                }
            }
            var body: [String] = []
            var oldCount = 0, newCount = 0
            for op in ops[low...high] {
                switch op {
                case .same(let text): body.append(" " + text); oldCount += 1; newCount += 1
                case .removed(let text): body.append("-" + text); oldCount += 1
                case .added(let text): body.append("+" + text); newCount += 1
                }
            }
            let oldStart = oldCount == 0 ? oldLine - 1 : oldLine
            let newStart = newCount == 0 ? newLine - 1 : newLine
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            output += body
        }
        return output
    }
}

/// A file change seen in a tool call.
struct ACPFileDiff: Equatable, Sendable {
    var path: String
    var oldText: String?
    var newText: String
    var toolID: String
}

/// Everything known about one tool call, merged from `tool_call`, `tool_call_update` and permission requests.
struct ACPToolState: Equatable, Sendable {
    var id: String
    var title = ""
    var name: String?
    var kind = "other"
    var status = "pending"
    var content: [ACPToolContent] = []
    var locations: [ACPLocation] = []
    var rawInput: JSONValue?
    var rawOutput: JSONValue?

    init(id: String) { self.id = id }

    mutating func merge(_ update: ACPToolCallUpdate) {
        if let title = update.title, !title.isEmpty { self.title = title }
        if let name = update.name { self.name = name }
        if let kind = update.kind { self.kind = kind }
        if let status = update.status { self.status = status }
        if let content = update.content, !content.isEmpty {
            // A final update often carries only the output text; keep the diff the agent showed earlier (for example
            // in the permission request).
            let hasDiff = content.contains { if case .diff = $0 { true } else { false } }
            let earlierDiffs = self.content.filter { if case .diff = $0 { true } else { false } }
            self.content = hasDiff ? content : content + earlierDiffs
        }
        if let locations = update.locations, !locations.isEmpty { self.locations = locations }
        if let raw = update.rawInput, raw != .object([:]) || rawInput == nil { rawInput = raw }
        if let raw = update.rawOutput { rawOutput = raw }
    }

    var diffs: [(path: String, oldText: String?, newText: String)] {
        content.compactMap { if case .diff(let path, let old, let new) = $0 { (path, old, new) } else { nil } }
    }

    var isOpen: Bool { status == "pending" || status == "in_progress" }

    var path: String? {
        locations.first?.path ?? diffs.first?.path ?? rawInput?["path"]?.acpText ?? rawInput?["Path"]?.acpText
            ?? rawInput?["file_path"]?.acpText ?? rawInput?["filePath"]?.acpText
    }

    /// Ensemble's tool name, chosen so the transcript shows the right icon and verb.
    var ensembleName: String {
        let lowerName = name?.lowercased() ?? ""
        switch kind {
        case "execute": return "bash"
        case "read": return "read"
        case "edit":
            let created = diffs.first.map { $0.oldText == nil } ?? false
            return created || lowerName.contains("write") || lowerName.contains("create") ? "write" : "edit"
        case "search": return lowerName.contains("glob") || lowerName.contains("find") ? "glob" : "grep"
        case "fetch": return lowerName.contains("search") ? "websearch" : "webfetch"
        case "delete": return "Delete"
        case "move": return "Move"
        case "think": return "Think"
        case "switch_mode": return "Switch mode"
        default:
            if TodoParser.isTodoTool(lowerName) { return "todowrite" }
            return name ?? (title.isEmpty ? "Tool" : title)
        }
    }

    func cardTitle(directory: String?) -> String {
        switch kind {
        case "execute":
            return ACPFormatting.command(rawInput) ?? title
        case "read", "edit", "delete", "move":
            if let path { return ACPFormatting.displayPath(path, directory: directory) }
        default:
            break
        }
        return title.isEmpty ? (name ?? kind) : title
    }

    var ensembleStatus: ToolStatus {
        switch status {
        case "in_progress": .running
        case "completed": .succeeded
        case "failed": .failed
        default: .pending
        }
    }

    var outputPreview: String? {
        let texts = content.compactMap { if case .text(let text) = $0 { text } else { nil } }
        if !texts.isEmpty { return ACPFormatting.trimmed(texts.joined(separator: "\n")) }
        if let output = rawOutput?["output"]?.acpText ?? rawOutput?["error"]?.acpText ?? rawOutput?.acpText {
            return ACPFormatting.trimmed(output)
        }
        return nil
    }

    func unifiedDiff(directory: String?) -> String? {
        let parts = diffs.map { ACPDiff.unified(path: ACPFormatting.displayPath($0.path, directory: directory), oldText: $0.oldText, newText: $0.newText) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func info(directory: String?) -> ToolCallInfo {
        ToolCallInfo(id: id, name: ensembleName, title: cardTitle(directory: directory),
                     inputJSON: ACPFormatting.prettyJSON(rawInput) ?? "{}", status: ensembleStatus,
                     outputPreview: outputPreview, diff: unifiedDiff(directory: directory))
    }

    /// Ensemble's permission kind (`bash`, `edit`, `write`, `read`, `webfetch`, `external_directory`, ...).
    func permissionKind(directory: String?) -> String {
        if let directory, ["read", "edit", "delete", "move", "search"].contains(kind) {
            let paths = touchedPaths(directory: directory)
            if paths == nil || paths?.contains(where: { !ACPFormatting.isInside($0, directory: directory) }) == true {
                return "external_directory"
            }
        }
        switch kind {
        case "execute": return "bash"
        case "edit": return ensembleName
        case "delete", "move": return "edit"
        case "read", "search": return "read"
        case "fetch": return "webfetch"
        default: return name ?? "tool"
        }
    }

    /// Every path the call touches: its locations, its diffs, and its path arguments (source and destination included,
    /// nested arguments too), relative ones taken from the project folder, `~` from the home folder, all with links
    /// resolved and without duplicates. For file tools (read, edit, delete) every string argument that looks like a
    /// path counts, whatever its name, except text in content fields (which counts only when it is a single absolute or
    /// `~` path). nil when a path cannot be resolved (a dangling link, a `..` past a missing folder, `~user`), so the call
    /// cannot be judged.
    func touchedPaths(directory: String) -> [String]? {
        var raw = locations.map(\.path) + diffs.map(\.path)
        if let rawInput {
            if ACPAlwaysRules.fileKinds.contains(kind) {
                ACPAlwaysRules.collectPathLikeValues(rawInput, into: &raw)
            } else {
                ACPAlwaysRules.collectPaths(rawInput, into: &raw)
            }
        }
        var result: [String] = []
        for path in raw where !path.isEmpty {
            var absolute = path
            if path == "~" || path.hasPrefix("~/") {
                absolute = NSHomeDirectory() + path.dropFirst()
            } else if path.hasPrefix("~") {
                return nil
            } else if !path.hasPrefix("/") {
                absolute = (directory as NSString).appendingPathComponent(path)
            }
            guard let resolved = WorkspaceTrust.resolvedPath(absolute) else { return nil }
            if !result.contains(resolved) { result.append(resolved) }
        }
        return result
    }

    /// What an "always" answer remembers for this call, or nil when it has no concrete subject, in which case "always"
    /// only allows this one request. Built only from what the call does, never from the title or other descriptive
    /// text the agent wrote, and nil whenever an argument is one Ensemble does not know for that kind of call:
    /// - every kind: the call touches at most one path, and that path is inside the project folder;
    /// - execute: every argument but descriptive ones, exactly (the command, an argv array as an array, the folder with
    ///   links resolved, environment, shell options, timeouts);
    /// - read, edit, delete: exactly one path, and only path, content and option arguments known for that kind; for
    ///   edits the content may differ next time, the file may not;
    /// - move: never (it touches a source and a destination);
    /// - fetch: the canonical URL plus every other argument but descriptive ones, exactly;
    /// - anything else: the exact arguments.
    func alwaysRule(directory: String) -> ACPAlwaysRule? {
        guard let paths = touchedPaths(directory: directory), paths.count <= 1 else { return nil }
        if let only = paths.first, !ACPFormatting.isInside(only, directory: directory) { return nil }
        let tool = name ?? ""
        let project = WorkspaceTrust.resolvedPath(directory) ?? directory
        switch kind {
        case "execute":
            guard case .object(let input)? = rawInput, let command = ACPFormatting.command(rawInput) else { return nil }
            var kept: [String: JSONValue] = [:]
            var folder: String?
            for (key, value) in input {
                let word = ACPAlwaysRules.normalized(key)
                if ACPAlwaysRules.descriptiveKeys.contains(word) { continue }
                guard ACPAlwaysRules.executeKeys.contains(word) else { return nil }
                if ACPAlwaysRules.folderKeys.contains(word) {
                    guard let text = value.acpText else { return nil }
                    let resolved = WorkspaceTrust.resolvedPath(text.hasPrefix("/") ? text : (directory as NSString).appendingPathComponent(text)) ?? text
                    folder = resolved
                    kept[key] = .string(resolved)
                } else {
                    kept[key] = value
                }
            }
            // Exactly one argument may say what runs, so the card can show all of it. A command next to
            // `args` (or two command fields) is allowed for that request only.
            let commandFields = kept.keys.filter { ACPAlwaysRules.commandKeys.contains(ACPAlwaysRules.normalized($0)) }
            guard commandFields.count == 1 else { return nil }
            var summary = "command: \(command)"
            if let folder, folder != project { summary += " (in \(ACPFormatting.displayPath(folder, directory: project)))" }
            let extras = kept.filter { key, _ in
                let word = ACPAlwaysRules.normalized(key)
                return !ACPAlwaysRules.commandKeys.contains(word) && !ACPAlwaysRules.folderKeys.contains(word)
            }
            if !extras.isEmpty { summary += " with \(JSONValue.object(extras).jsonText)" }
            return ACPAlwaysRule(key: "execute|\(tool)|\(JSONValue.object(kept).jsonText)", summary: summary)
        case "read", "edit", "delete":
            guard let only = paths.first, ACPAlwaysRules.onlyKnownFileArguments(rawInput, kind: kind) else { return nil }
            let shown = ACPFormatting.displayPath(only, directory: project)
            let verb = kind == "read" ? "reading" : kind == "edit" ? "edits to" : "deleting"
            return ACPAlwaysRule(key: "\(kind)|\(tool)|\(only)", summary: "\(verb) \(shown)")
        case "move":
            return nil
        case "fetch":
            guard case .object(let input)? = rawInput else { return nil }
            var extras: [String: JSONValue] = [:]
            var urlKeys = 0
            for (key, value) in input {
                let word = ACPAlwaysRules.normalized(key)
                if ACPAlwaysRules.descriptiveKeys.contains(word) { continue }
                if word == "url" || word == "uri" { urlKeys += 1; continue }
                extras[key] = value
            }
            guard urlKeys <= 1 else { return nil }
            let extra = extras.isEmpty ? nil : JSONValue.object(extras).jsonText
            if urlKeys == 1 {
                guard let url = ACPAlwaysRules.canonicalURL(rawInput) else { return nil }
                return ACPAlwaysRule(key: "fetch|\(tool)|\(url)|\(extra ?? "")",
                                     summary: "web request: \(url)" + (extra.map { " with \($0)" } ?? ""))
            }
            guard let extra else { return nil }
            return ACPAlwaysRule(key: "fetch|\(tool)||\(extra)", summary: "\(ensembleName)(\(extra))")
        default:
            guard let arguments = ACPAlwaysRules.canonicalArguments(rawInput) else { return nil }
            return ACPAlwaysRule(key: "\(kind)|\(tool)|\(arguments)", summary: "\(ensembleName)(\(arguments))")
        }
    }
}

/// One "always" answer Ensemble remembers for a session: an exact key, and the line the permission card shows.
struct ACPAlwaysRule: Hashable, Sendable {
    let key: String
    let summary: String
}

enum ACPAlwaysRules {
    /// What the card says when "always" allows nothing beyond this request.
    static let thisRequestOnly = "nothing more (this request only)"

    /// Kinds whose rule is "this one file".
    static let fileKinds: Set<String> = ["read", "edit", "delete"]

    /// An argument name compared loosely: lowercased, without `_` and `-` (`file_path`, `filePath` and `FilePath` match).
    static func normalized(_ key: String) -> String { key.lowercased().filter { $0 != "_" && $0 != "-" } }

    /// Arguments that only describe the call for people (or the model) and never change what it does.
    static let descriptiveKeys: Set<String> = ["description", "title", "toolsummary", "summary", "explanation", "reason", "rationale",
                                               "thought", "thoughts", "purpose", "intent", "label", "comment", "why", "instruction", "instructions"]

    static let commandKeys: Set<String> = ["command", "commandline", "cmd", "args", "argv", "arguments"]
    static let folderKeys: Set<String> = ["cwd", "workdir", "workingdirectory", "directory", "dir"]
    /// Every argument a shell tool may have that Ensemble knows. Anything else and "always" allows that request only.
    static let executeKeys: Set<String> = commandKeys.union(folderKeys).union([
        "env", "environment", "envvars", "shell", "timeout", "timeoutms", "timeoutseconds", "waitmsbeforeasync", "background",
        "runinbackground", "isbackground", "stdin", "input", "login", "interactive", "sandbox", "usesandbox", "safetoautorun",
    ])

    /// Path arguments of file tools.
    static let filePathKeys: Set<String> = ["path", "filepath", "file", "filename", "absolutepath", "targetfile"]
    /// Content arguments of edits (what is written, or the text it replaces). Agy's `edit_file` calls the old text `Target`.
    static let fileContentKeys: Set<String> = ["content", "contents", "text", "newtext", "oldtext", "newstring", "oldstring", "newstr",
                                               "oldstr", "replacement", "target", "replaceall", "edits"]
    /// Options of reads.
    static let readOptionKeys: Set<String> = ["offset", "limit", "startline", "endline", "line", "linenumber", "encoding"]

    static func allowedFileKeys(kind: String) -> Set<String> {
        switch kind {
        case "read": filePathKeys.union(readOptionKeys).union(descriptiveKeys)
        case "edit": filePathKeys.union(fileContentKeys).union(readOptionKeys).union(descriptiveKeys)
        default: filePathKeys.union(descriptiveKeys)
        }
    }

    /// True when every argument name, at any depth (`edits: [{old_string, new_string}]`), is a path, content, option or
    /// descriptive argument Ensemble knows for this kind of file call.
    static func onlyKnownFileArguments(_ value: JSONValue?, kind: String) -> Bool {
        let allowed = allowedFileKeys(kind: kind)
        func check(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let object):
                return object.allSatisfy { key, item in allowed.contains(normalized(key)) && check(item) }
            case .array(let items):
                return items.allSatisfy(check)
            default:
                return true
            }
        }
        guard let value else { return true }
        return check(value)
    }

    /// True for text that looks like a path: absolute, `~`, or containing `/` (a URL is not a path). Text with spaces only
    /// when it starts like an absolute path, so a sentence such as "fix the read/write bug" is not taken for one.
    static func looksLikePath(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains("\n"), !text.contains("://") else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~") { return true }
        return text.contains("/") && !text.contains(where: \.isWhitespace)
    }

    /// Collects path-like strings from a file tool's arguments, whatever their names: every string in a path argument,
    /// a single absolute or `~` path in a content argument, and anything that looks like a path elsewhere.
    static func collectPathLikeValues(_ value: JSONValue, into paths: inout [String], key: String? = nil) {
        switch value {
        case .string(let text):
            let word = key.map(normalized) ?? ""
            if filePathKeys.contains(word) || isPathKey(key ?? "") {
                paths.append(text)
            } else if fileContentKeys.contains(word) {
                if (text.hasPrefix("/") || text.hasPrefix("~")) && !text.contains(where: \.isWhitespace) { paths.append(text) }
            } else if looksLikePath(text) {
                paths.append(text)
            }
        case .array(let items):
            for item in items { collectPathLikeValues(item, into: &paths, key: key) }
        case .object(let object):
            for itemKey in object.keys.sorted() { collectPathLikeValues(object[itemKey] ?? .null, into: &paths, key: itemKey) }
        default:
            break
        }
    }

    /// Argument names that hold paths: anything with path, file or dir in the name, and the usual source and
    /// destination names.
    static func isPathKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.contains("path") || lower.contains("file") || lower.contains("dir") { return true }
        return ["cwd", "source", "destination", "src", "dst", "dest", "from", "to", "target_file"].contains(lower)
    }

    /// Collects every string under a path-like key, at any depth (including arrays of paths).
    static func collectPaths(_ value: JSONValue, into paths: inout [String], underPathKey: Bool = false) {
        switch value {
        case .string(let text) where underPathKey:
            paths.append(text)
        case .array(let items):
            for item in items { collectPaths(item, into: &paths, underPathKey: underPathKey) }
        case .object(let object):
            // A stable order (sources before destinations), so the card lists paths the same way every time.
            func rank(_ key: String) -> Int {
                let lower = key.lowercased()
                if ["source", "src", "from"].contains(lower) || lower.hasPrefix("old") || lower.hasPrefix("source") { return 0 }
                if ["destination", "dst", "dest", "to"].contains(lower) || lower.hasPrefix("new") || lower.hasPrefix("dest") { return 2 }
                return 1
            }
            for key in object.keys.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
                collectPaths(object[key] ?? .null, into: &paths, underPathKey: isPathKey(key))
            }
        default:
            break
        }
    }

    /// The folder a command runs in, when the arguments say.
    static func workingFolder(_ rawInput: JSONValue?) -> String? {
        for key in ["cwd", "Cwd", "workdir", "workingDirectory", "working_directory", "directory", "Directory"] {
            if let value = rawInput?[key]?.acpText { return value }
        }
        return nil
    }

    /// `https://example.com/a?b=1` from the URL argument: scheme and host lowercased, default port and fragment dropped.
    /// nil without an http or https URL with a host.
    static func canonicalURL(_ rawInput: JSONValue?) -> String? {
        var text: String?
        for key in ["url", "Url", "URL", "uri", "Uri"] {
            if let value = rawInput?[key]?.acpText { text = value; break }
        }
        guard let text, var components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        if components.path.isEmpty { components.path = "/" }
        return components.string
    }

    /// The arguments as compact JSON with sorted keys, or nil when there are none.
    static func canonicalArguments(_ rawInput: JSONValue?) -> String? {
        switch rawInput {
        case .object(let object)? where !object.isEmpty: return rawInput?.jsonText
        case .array(let items)? where !items.isEmpty: return rawInput?.jsonText
        default: return nil
        }
    }
}

/// One session's transcript as Ensemble shows it, built from the agent's updates.
struct ACPTranscriptState: Sendable {
    let sessionID: String
    var directory: String
    /// Texts Ensemble injected (board messages); replayed user messages with exactly this text become notices.
    var syntheticTexts: Set<String>
    private(set) var items: [TranscriptItem] = []
    /// Files sent with a message from Ensemble, by the id of its row.
    private(set) var attachments: [String: [MessageAttachment]] = [:]
    private(set) var tools: [String: ACPToolState] = [:]
    private(set) var turn = 0
    /// Distinguishes rows of this state from rows built by an earlier one (after a restart or a reload), so live
    /// updates never land on an old row with the same number.
    private let generation: String
    private var counter = 0
    private var openText: (id: String, messageID: String?, text: String)?
    private var openReasoning: (id: String, messageID: String?)?
    private var openUser: String?
    private var planID: String?

    init(sessionID: String, directory: String, syntheticTexts: Set<String> = [], generation: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.sessionID = sessionID
        self.directory = directory
        self.syntheticTexts = syntheticTexts
        self.generation = generation
    }

    private mutating func nextID(_ kind: String) -> String {
        counter += 1
        return "\(sessionID):\(generation):\(kind)\(counter)"
    }

    private mutating func index(of id: String) -> Int? { items.lastIndex { $0.id == id } }

    // MARK: Closing open rows

    /// Ends the open agent text row, returning its `textEnded` event.
    private mutating func closeText() -> [EngineEvent] {
        guard let open = openText else { return [] }
        openText = nil
        if let i = index(of: open.id), case .agentText(let id, let text, let agent, _) = items[i] {
            items[i] = .agentText(id: id, text: text, agentID: agent, streaming: false)
        }
        return [.textEnded(sessionID: sessionID, itemID: open.id, text: open.text)]
    }

    private mutating func closeReasoning() {
        guard let open = openReasoning else { return }
        openReasoning = nil
        if let i = index(of: open.id), case .reasoning(let id, let text, _) = items[i] {
            items[i] = .reasoning(id: id, text: text, streaming: false)
        }
    }

    private mutating func closeAll() -> [EngineEvent] {
        closeReasoning()
        openUser = nil
        return closeText()
    }

    // MARK: Input

    /// A message the user (or, when `synthetic`, Ensemble's room relay) sent. Not echoed by agents during live turns.
    mutating func addUser(_ text: String, synthetic: Bool, attachments attached: [MessageAttachment] = [],
                          date: Date = Date()) -> [EngineEvent] {
        let events = closeAll()
        turn += 1
        planID = nil
        if synthetic {
            items.append(.notice(id: nextID("n"), text: text))
        } else {
            let id = nextID("u")
            items.append(.user(id: id, text: text, date: date))
            if !attached.isEmpty { attachments[id] = attached }
        }
        return events
    }

    /// Applies one update. Returns the live events for it (text and reasoning deltas, tool cards). Updates about
    /// commands, modes, options, titles and usage return nothing here; the engine handles them.
    mutating func apply(_ update: ACPSessionUpdate, date: Date = Date()) -> [EngineEvent] {
        switch update {
        case .userMessage(let text, _):
            let events = closeText()
            closeReasoning()
            if syntheticTexts.contains(text) {
                openUser = nil
                items.append(.notice(id: nextID("n"), text: text))
                turn += 1
                return events
            }
            if let open = openUser, let i = index(of: open), case .user(let id, let existing, let when) = items[i] {
                items[i] = .user(id: id, text: existing + text, date: when)
            } else {
                let id = nextID("u")
                items.append(.user(id: id, text: text, date: date))
                openUser = id
                turn += 1
                planID = nil
            }
            return events

        case .agentMessage(let text, let messageID):
            openUser = nil
            closeReasoning()
            var events: [EngineEvent] = []
            if let open = openText, open.messageID != messageID, messageID != nil, open.messageID != nil {
                events += closeText()
            }
            if var open = openText {
                open.text += text
                openText = open
                if let i = index(of: open.id), case .agentText(let id, _, let agent, _) = items[i] {
                    items[i] = .agentText(id: id, text: open.text, agentID: agent, streaming: true)
                }
                events.append(.textDelta(sessionID: sessionID, itemID: open.id, delta: text))
            } else {
                guard !text.isEmpty else { return events }
                let id = nextID("t")
                openText = (id, messageID, text)
                items.append(.agentText(id: id, text: text, agentID: nil, streaming: true))
                events.append(.textDelta(sessionID: sessionID, itemID: id, delta: text))
            }
            return events

        case .agentThought(let text, let messageID):
            openUser = nil
            var events = closeText()
            if let open = openReasoning, open.messageID != messageID, messageID != nil, open.messageID != nil {
                closeReasoning()
            }
            if let open = openReasoning, let i = index(of: open.id), case .reasoning(let id, let existing, _) = items[i] {
                items[i] = .reasoning(id: id, text: existing + text, streaming: true)
                events.append(.reasoningDelta(sessionID: sessionID, itemID: open.id, delta: text))
            } else {
                guard !text.isEmpty else { return events }
                let id = nextID("r")
                openReasoning = (id, messageID)
                items.append(.reasoning(id: id, text: text, streaming: true))
                events.append(.reasoningDelta(sessionID: sessionID, itemID: id, delta: text))
            }
            return events

        case .toolCall(let call), .toolCallUpdate(let call):
            return applyTool(call)

        case .plan(let entries):
            var events = closeAll()
            let todos: [JSONValue] = entries.map {
                ["content": .string($0.content), "status": .string($0.status), "priority": .string($0.priority)]
            }
            let id = planID ?? nextID("plan")
            planID = id
            let info = ToolCallInfo(id: id, name: "todowrite", title: "Plan", inputJSON: JSONValue.object(["todos": .array(todos)]).prettyJSONText,
                                    status: .succeeded)
            upsert(info)
            events.append(.toolUpdated(sessionID: sessionID, info))
            return events

        case .availableCommands, .currentMode, .configOptions, .sessionInfo, .usage, .other:
            return []
        }
    }

    /// Merges a tool call (from an update or a permission request) and returns the card's new state.
    mutating func applyTool(_ call: ACPToolCallUpdate) -> [EngineEvent] {
        var events = closeAll()
        var state = tools[call.id] ?? ACPToolState(id: call.id)
        state.merge(call)
        tools[call.id] = state
        let info = state.info(directory: directory)
        upsert(info)
        events.append(.toolUpdated(sessionID: sessionID, info))
        return events
    }

    private mutating func upsert(_ info: ToolCallInfo) {
        if let i = index(of: info.id), case .tool = items[i] {
            items[i] = .tool(info)
        } else {
            items.append(.tool(info))
        }
    }

    /// Ends the turn: closes streaming rows and fails tool calls the agent left open.
    mutating func endTurn() -> [EngineEvent] {
        var events = closeAll()
        for (id, var state) in tools where state.isOpen {
            state.status = "failed"
            tools[id] = state
            let info = state.info(directory: directory)
            upsert(info)
            events.append(.toolUpdated(sessionID: sessionID, info))
        }
        return events
    }

    /// Ends a replay (`session/load`): like a turn end, without events.
    mutating func finishReplay() {
        _ = endTurn()
    }

    mutating func appendError(_ message: String) {
        _ = closeAll()
        items.append(.error(id: nextID("e"), message: message))
    }

    mutating func appendNotice(_ text: String) {
        _ = closeAll()
        items.append(.notice(id: nextID("n"), text: text))
    }

    /// Files changed by tool calls that finished, merged per path in order.
    func changedFiles() -> [FileChange] {
        var merged: [String: FileChange] = [:]
        var order: [String] = []
        for item in items {
            guard case .tool(let info) = item, info.status == .succeeded, let state = tools[info.id] else { continue }
            for diff in state.diffs {
                let path = ACPFormatting.displayPath(diff.path, directory: directory)
                let unified = ACPDiff.unified(path: path, oldText: diff.oldText, newText: diff.newText)
                let stats = Format.diffStats(unified)
                if var existing = merged[path] {
                    existing.additions += stats.additions
                    existing.deletions += stats.deletions
                    existing.diff = [existing.diff, unified].compactMap { $0 }.joined(separator: "\n")
                    merged[path] = existing
                } else {
                    order.append(path)
                    merged[path] = FileChange(path: path, kind: diff.oldText == nil ? .added : .modified,
                                              additions: stats.additions, deletions: stats.deletions, diff: unified)
                }
            }
        }
        return order.compactMap { merged[$0] }
    }
}

/// Building Ensemble's permission card from an ACP permission request.
enum ACPPermissionMapping {
    /// The permission card for a tool call. Path calls show every path they touch, and `alwaysPatterns` says exactly what
    /// an "always" answer remembers (`ACPToolState.alwaysRule`), or that it allows this request only.
    static func request(id: String, sessionID: String, tool: ACPToolState, directory: String, date: Date = Date()) -> PermissionRequest {
        let base = WorkspaceTrust.resolvedPath(directory) ?? directory
        let title: String
        switch tool.kind {
        case "execute":
            title = ACPFormatting.command(tool.rawInput) ?? tool.title
        case "read", "edit", "delete", "move":
            var raw = tool.locations.map(\.path) + tool.diffs.map(\.path)
            if let input = tool.rawInput { ACPAlwaysRules.collectPaths(input, into: &raw) }
            let paths = tool.touchedPaths(directory: directory) ?? raw
            let shown = paths.map { ACPFormatting.displayPath($0, directory: base) }
            title = shown.isEmpty ? tool.title : shown.joined(separator: ", ")
        default:
            title = tool.title.isEmpty ? (tool.name ?? "Tool call") : tool.title
        }
        let detail = tool.unifiedDiff(directory: directory) ?? ACPFormatting.prettyJSON(tool.rawInput)
        let always = tool.alwaysRule(directory: directory)?.summary ?? ACPAlwaysRules.thisRequestOnly
        return PermissionRequest(id: id, sessionID: sessionID, kind: tool.permissionKind(directory: directory),
                                 title: title.isEmpty ? "Tool call" : title, detail: detail, alwaysPatterns: [always], created: date)
    }
}
