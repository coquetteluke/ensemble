import Foundation

/// File access for `CustomizationsDiscovery`: reads only, with size limits, and never the files that hold sign-ins.
enum CustomizationFiles {
    /// File names discovery never opens, wherever they are: Claude's and other tools' stored sign-ins, OpenCode's old
    /// credential file, cookie jars and browser storage.
    static let forbiddenNames: Set<String> = [
        ".credentials.json", "credentials.json", "auth.json", "oauth_creds.json", "google_accounts.json", "cookies",
        "cookies.sqlite", "cookies.binarycookies", "login data", "local storage", "session storage", "keychain-2.db",
    ]

    /// True for paths discovery must never read.
    static func isForbidden(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if forbiddenNames.contains(name) || name.hasSuffix(".keychain") || name.hasSuffix(".keychain-db") { return true }
        let lower = path.lowercased()
        return lower.contains("/library/keychains/") || lower.contains("/library/cookies/")
    }

    static var fm: FileManager { FileManager.default }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    static func size(_ path: String) -> Int? {
        (try? fm.attributesOfItem(atPath: path))?[.size].flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// Entry names in a folder, sorted, without `.DS_Store`.
    static func children(_ directory: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    /// At most `limit` bytes of a regular file (links are followed). Nil for forbidden, missing or unreadable files.
    static func read(_ path: String, limit: Int = 1 << 20) -> Data? {
        guard !isForbidden(path), isFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit) ?? Data()
    }

    static func text(_ path: String, limit: Int = 1 << 20) -> String? {
        read(path, limit: limit).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A JSON or JSONC file (comments and trailing commas allowed), at most 8 MB.
    static func json(_ path: String) -> JSONValue? {
        guard let data = read(path, limit: 8 << 20) else { return nil }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { return value }
        let cleaned = stripJSONC(String(decoding: data, as: UTF8.self))
        return try? JSONDecoder().decode(JSONValue.self, from: Data(cleaned.utf8))
    }

    /// Removes `//` and `/* */` comments outside strings, and commas before `}` or `]`.
    static func stripJSONC(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1
                } else {
                    out.append(c)
                    i += 1
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: Markdown

    /// A Markdown file's front matter (`---` block at the top) and body.
    struct Markdown {
        var frontMatter: [String: FrontValue] = [:]
        var body: String = ""

        func string(_ key: String) -> String? { frontMatter[key]?.text }
        func list(_ key: String) -> [String] { frontMatter[key]?.items ?? [] }
    }

    enum FrontValue: Equatable {
        case text(String)
        case list([String])

        var text: String? {
            switch self {
            case .text(let value): value
            case .list(let items): items.joined(separator: ", ")
            }
        }

        var items: [String] {
            switch self {
            case .text(let value):
                value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .list(let items): items
            }
        }
    }

    /// Reads a Markdown file's first 64 KB.
    static func markdown(_ path: String) -> Markdown? {
        text(path, limit: 64 << 10).map(parseMarkdown)
    }

    /// A small front matter reader: top-level `key: value` lines, quoted values, `>` and `|` blocks, `[a, b]` and
    /// `- item` lists. Anything else is ignored.
    static func parseMarkdown(_ text: String) -> Markdown {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Markdown(body: normalized)
        }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return Markdown(body: normalized)
        }
        let header = Array(lines[..<end])
        let body = lines[(end + 1)...].joined(separator: "\n")
        var values: [String: FrontValue] = [:]
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }
            if value.isEmpty || value.hasPrefix(">") || value.hasPrefix("|") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                var items: [String] = []
                while index < header.count, header[index].hasPrefix(" ") || header[index].hasPrefix("\t") || header[index].isEmpty {
                    let inner = header[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if inner.hasPrefix("- ") {
                        items.append(unquote(String(inner.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    } else if !inner.isEmpty {
                        block.append(inner)
                    }
                }
                if !items.isEmpty {
                    values[key] = .list(items)
                } else if !block.isEmpty || !value.isEmpty {
                    values[key] = .text(block.joined(separator: folded || value.isEmpty ? " " : "\n"))
                }
                continue
            }
            if value.hasPrefix("["), value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
                values[key] = .list(value.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty })
                continue
            }
            values[key] = .text(unquote(value))
        }
        return Markdown(frontMatter: values, body: body)
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// The first `count` non-empty lines of the body (after front matter), redacted, each cut to 160 characters.
    static func previewLines(_ markdown: Markdown, count: Int = 4) -> [String] {
        var lines: [String] = []
        for raw in markdown.body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---" else { continue }
            let redacted = CustomizationRedaction.text(line)
            lines.append(redacted.count > 160 ? String(redacted.prefix(159)) + "…" : redacted)
            if lines.count == count { break }
        }
        return lines
    }

    /// A description for display: one line, redacted, at most 300 characters.
    static func summary(_ text: String?) -> String {
        guard let text else { return "" }
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let redacted = CustomizationRedaction.text(flat)
        return redacted.count > 300 ? String(redacted.prefix(299)) + "…" : redacted
    }

    /// `.md` files in a folder, sorted by path. `recursive` descends into subfolders (not hidden ones), up to 4 levels
    /// and 500 files.
    static func markdownFiles(in directory: String, recursive: Bool) -> [String] {
        guard isDirectory(directory) else { return [] }
        var found: [String] = []
        func walk(_ folder: String, depth: Int) {
            for name in children(folder) where found.count < 500 {
                let path = (folder as NSString).appendingPathComponent(name)
                if name.lowercased().hasSuffix(".md"), isFile(path) {
                    found.append(path)
                } else if recursive, depth < 4, !name.hasPrefix("."), isDirectory(path) {
                    walk(path, depth: depth + 1)
                }
            }
        }
        walk(directory, depth: 0)
        return found.sorted()
    }

    /// `<name>/SKILL.md` files one level inside a skills folder, sorted by folder name.
    static func skillFiles(in directory: String) -> [String] {
        guard isDirectory(directory) else { return [] }
        return children(directory).compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let file = ((directory as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("SKILL.md")
            return isFile(file) ? file : nil
        }
    }

    /// Paths with `~` expanded against `home`.
    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }
}
