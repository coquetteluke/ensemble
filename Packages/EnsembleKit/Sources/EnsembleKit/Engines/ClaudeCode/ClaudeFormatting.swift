import Foundation

// MARK: JSON helpers

extension JSONValue {
    var intValue: Int? {
        if case .number(let value) = self, value.isFinite { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Parses one line of JSON text. Returns nil for blank or broken lines.
    static func parse(line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON for writing to the CLI's stdin (one line, no sorted keys needed).
    var lineData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("null".utf8)
        data.append(0x0A)
        return data
    }
}

enum ClaudeDates {
    /// ISO 8601 with or without fractional seconds (`2026-11-18T04:08:02.325Z`).
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return (try? fractionalStyle.parse(text)) ?? (try? plainStyle.parse(text))
    }
}

// MARK: Tool cards and permission prompts

enum ClaudeFormatting {
    static let previewLimit = 4000
    static let diffLimit = 60_000

    static func trimmed(_ text: String, limit: Int = previewLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n..."
    }

    /// Paths inside the project are shown relative to it.
    static func displayPath(_ path: String, directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        let candidates = [directory, "/private" + directory, directory.hasPrefix("/private/") ? String(directory.dropFirst(8)) : directory]
        for base in candidates {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }

    static let editToolNames: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    static let agentToolNames: Set<String> = ["Agent", "Task"]
    static let shellToolNames: Set<String> = ["Bash", "PowerShell"]

    /// Short card title from a tool's input: the command, file, pattern, URL or task.
    static func title(name: String, input: JSONValue?, directory: String?) -> String {
        guard let input, case .object(let object) = input else { return name }
        func string(_ key: String) -> String? {
            guard let value = object[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        switch name {
        case "Bash", "PowerShell":
            if let command = string("command") { return command }
        case "Read", "Edit", "MultiEdit", "Write":
            if let path = string("file_path") { return displayPath(path, directory: directory) }
        case "NotebookEdit":
            if let path = string("notebook_path") { return displayPath(path, directory: directory) }
        case "Grep", "Glob":
            if let pattern = string("pattern") { return pattern }
        case "WebFetch":
            if let url = string("url") { return url }
        case "WebSearch":
            if let query = string("query") { return query }
        case "Agent", "Task":
            if let description = string("description") ?? string("prompt") { return description }
        case "Skill":
            if let skill = string("skill") ?? string("name") { return skill }
        case "TodoWrite":
            return "Update to-do list"
        default:
            break
        }
        for key in ["description", "command", "file_path", "path", "url", "query", "pattern", "name"] {
            if let value = string(key) {
                return key.hasSuffix("path") ? displayPath(value, directory: directory) : value
            }
        }
        return name
    }

    static func inputJSON(_ input: JSONValue?) -> String {
        guard let input else { return "{}" }
        return input.prettyJSONText
    }

    /// The text of a `tool_result` content field (a string or a list of text blocks).
    static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text)?:
            return text
        case .array(let blocks)?:
            return blocks.compactMap { block -> String? in
                switch block["type"]?.stringValue {
                case "text": return block["text"]?.stringValue
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
        default:
            return ""
        }
    }

    /// Unified diff for an edit, from the CLI's tool result (`structuredPatch`, or the content of a new file).
    static func diff(toolName: String, input: JSONValue?, result: JSONValue?, directory: String?) -> String? {
        guard editToolNames.contains(toolName) else { return nil }
        let path = result?["filePath"]?.stringValue ?? input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue ?? "file"
        let shown = displayPath(path, directory: directory)
        var body: [String] = []
        if let hunks = result?["structuredPatch"]?.arrayValue, !hunks.isEmpty {
            for hunk in hunks {
                let oldStart = hunk["oldStart"]?.intValue ?? 0
                let oldLines = hunk["oldLines"]?.intValue ?? 0
                let newStart = hunk["newStart"]?.intValue ?? 0
                let newLines = hunk["newLines"]?.intValue ?? 0
                body.append("@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@")
                body += (hunk["lines"]?.arrayValue ?? []).compactMap(\.stringValue)
            }
        } else if toolName == "Write", let content = result?["content"]?.stringValue ?? input?["content"]?.stringValue,
                  result?["type"]?.stringValue != "update" {
            var lines = content.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            body.append("@@ -0,0 +1,\(lines.count) @@")
            body += lines.map { "+" + $0 }
        } else {
            return nil
        }
        let header = result?["type"]?.stringValue == "create" ? ["--- /dev/null", "+++ b/\(shown)"] : ["--- a/\(shown)", "+++ b/\(shown)"]
        return trimmed((header + body).joined(separator: "\n"), limit: diffLimit)
    }

    /// A diff from an Edit's old and new strings, for permission prompts (the edit has not run yet).
    static func proposedDiff(toolName: String, input: JSONValue, directory: String?) -> String? {
        let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? "file"
        let shown = displayPath(path, directory: directory)
        func lines(_ text: String?) -> [String] {
            guard let text, !text.isEmpty else { return [] }
            var parts = text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        var body: [String] = []
        switch toolName {
        case "Edit":
            let old = lines(input["old_string"]?.stringValue)
            let new = lines(input["new_string"]?.stringValue)
            body.append("@@ -1,\(old.count) +1,\(new.count) @@")
            body += old.map { "-" + $0 } + new.map { "+" + $0 }
        case "MultiEdit":
            for edit in input["edits"]?.arrayValue ?? [] {
                let old = lines(edit["old_string"]?.stringValue)
                let new = lines(edit["new_string"]?.stringValue)
                body.append("@@ -1,\(old.count) +1,\(new.count) @@")
                body += old.map { "-" + $0 } + new.map { "+" + $0 }
            }
        case "Write":
            let new = lines(input["content"]?.stringValue)
            body.append("@@ -0,0 +1,\(new.count) @@")
            body += new.map { "+" + $0 }
        default:
            return nil
        }
        return trimmed((["--- a/\(shown)", "+++ b/\(shown)"] + body).joined(separator: "\n"), limit: diffLimit)
    }

    /// Ensemble's permission kind for a Claude tool inside the project (`bash`, `edit`, `write`, `webfetch`, `read`, ...).
    /// A prompt for anything outside the project is `external_directory` instead (`ClaudePermissionPrompt`).
    static func permissionKind(toolName: String) -> String {
        switch toolName {
        case "Bash", "PowerShell": return "bash"
        case "Edit", "MultiEdit", "NotebookEdit": return "edit"
        case "Write": return "write"
        case "WebFetch": return "webfetch"
        case "WebSearch": return "websearch"
        case "Read": return "read"
        case "Agent", "Task": return "subagent"
        default:
            if toolName.hasPrefix("mcp__") { return "mcp" }
            return toolName.lowercased()
        }
    }
}
