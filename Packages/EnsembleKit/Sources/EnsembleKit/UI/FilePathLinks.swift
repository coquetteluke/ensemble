import Foundation
import SwiftUI
import Synchronization

// File paths in agent text (`Sources/App/Foo.swift:42`, `docs/PLAN.md`) that exist inside the session's folder
// become links. Detection is here; `MarkdownView` styles the links, and the app decides what a click does
// through `\.fileLinkActions` (the Mac app opens its file viewer).

/// A file an agent mentioned, inside the session's folder.
public struct FileLink: Hashable, Sendable, Identifiable {
    /// Absolute, standardized path.
    public var path: String
    /// Line to show (1-based), from a `:42` or `#L42` suffix.
    public var line: Int?
    public var column: Int?

    public static let scheme = "ensemble-file"

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    public var id: String { "\(path):\(line ?? 0):\(column ?? 0)" }

    public var fileName: String { (path as NSString).lastPathComponent }

    /// `ensemble-file://open?path=...&line=42`, carried by the text run so a click can be routed.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let column { items.append(URLQueryItem(name: "column", value: String(column))) }
        components.queryItems = items
        return components.url ?? URL(fileURLWithPath: path)
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return nil }
        self.path = path
        line = components.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
        column = components.queryItems?.first(where: { $0.name == "column" })?.value.flatMap(Int.init)
    }

    /// The path relative to `base` when inside it, with `:line` when known.
    public func display(base: String) -> String {
        let relative = Format.relativePath(path, base: base)
        return line.map { "\(relative):\($0)" } ?? relative
    }
}

/// Finds file paths in text that exist inside a folder.
public enum FilePathDetector {
    public struct Match: Hashable, Sendable {
        /// Where the path (with its line suffix) sits in the text.
        public var range: Range<String.Index>
        public var link: FileLink
    }

    /// Answers "is this absolute path a file inside this folder?" (the real one checks the disk, through a cache).
    public typealias FileCheck = @Sendable (_ path: String, _ base: String) -> Bool

    /// Paths in plain text. Words are split at spaces, quotes and brackets; trailing punctuation is ignored; URLs
    /// and anything outside `base` are skipped.
    public static func matches(in text: String, base: String, isFileInside: FileCheck = FileLinkCache.shared.isFileInside) -> [Match] {
        guard !base.isEmpty, text.contains(where: { $0 == "/" || $0 == "." }) else { return [] }
        var matches: [Match] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !isDelimiter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !isDelimiter(text[end]) { end = text.index(after: end) }
            if let match = match(in: text, token: index..<end, base: base, isFileInside: isFileInside) {
                matches.append(match)
            }
            index = end
        }
        return matches
    }

    /// The path in an inline code span (`` `docs/PLAN.md` ``), when the whole span is one.
    public static func link(forCode code: String, base: String, isFileInside: FileCheck = FileLinkCache.shared.isFileInside) -> FileLink? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        return match(in: trimmed, token: trimmed.startIndex..<trimmed.endIndex, base: base, isFileInside: isFileInside)?.link
    }

    static func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || "\"'`()[]{}<>,;|*".contains(character)
    }

    private static func match(in text: String, token: Range<String.Index>, base: String, isFileInside: FileCheck) -> Match? {
        var lower = token.lowerBound
        var upper = token.upperBound
        // Sentence punctuation around a path is not part of it ("See docs/PLAN.md." or "(Foo.swift:12)").
        while upper > lower, ".!?:".contains(text[text.index(before: upper)]) { upper = text.index(before: upper) }
        while lower < upper, ":".contains(text[lower]) { lower = text.index(after: lower) }
        guard lower < upper else { return nil }
        let word = String(text[lower..<upper])
        guard word.count <= 400, !word.contains("://"), !word.hasPrefix("-"), !word.hasPrefix("@") else { return nil }

        let (path, line, column) = splitLine(word)
        guard looksLikePath(path), let absolute = resolve(path, base: base), isFileInside(absolute, base) else { return nil }
        return Match(range: lower..<upper, link: FileLink(path: absolute, line: line, column: column))
    }

    /// `Foo.swift:42:7` -> (Foo.swift, 42, 7); `Foo.swift:42-50` -> line 42; `Foo.swift#L42` -> line 42.
    static func splitLine(_ word: String) -> (path: String, line: Int?, column: Int?) {
        if let hash = word.range(of: "#L", options: .backwards) {
            let digits = word[hash.upperBound...].prefix { $0.isNumber }
            if let line = Int(digits), line > 0 { return (String(word[..<hash.lowerBound]), line, nil) }
        }
        let parts = word.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (word, nil, nil) }
        func number(_ part: Substring) -> Int? {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count == part.count || part.dropFirst(digits.count).first == "-" else { return nil }
            return Int(digits)
        }
        guard let line = number(parts[1]), line > 0 else { return (word, nil, nil) }
        let column = parts.count >= 3 ? number(parts[2]) : nil
        guard parts.count <= 3, parts.count < 3 || column != nil else { return (word, nil, nil) }
        return (String(parts[0]), line, column)
    }

    /// Has a folder part (`docs/PLAN.md`) or a file extension (`Package.swift`); a bare word or a version number
    /// (`2.3.0`) is not a path.
    static func looksLikePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasSuffix("/"), path.contains(where: { $0.isLetter }) else { return false }
        let name = (path as NSString).lastPathComponent
        if path.contains("/") { return !name.isEmpty }
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...]
        guard let first = ext.first, first.isLetter, (1...10).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The absolute path for `path` written in a session in `base`, or nil when it falls outside `base`.
    static func resolve(_ path: String, base: String) -> String? {
        guard base.hasPrefix("/") else { return nil }
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + path.dropFirst()
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            expanded = base + "/" + path
        }
        let standardized = (expanded as NSString).standardizingPath
        let root = (base as NSString).standardizingPath
        guard standardized.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return standardized
    }
}

/// Remembers which paths are files inside which folders for a few seconds, so streaming and redrawing text does
/// not touch the disk for every word.
public final class FileLinkCache: Sendable {
    public static let shared = FileLinkCache()

    private struct Entry {
        var isFile: Bool
        var checked: Date
    }

    private let entries = Mutex<[String: Entry]>([:])
    private let lifetime: TimeInterval = 10

    public init() {}

    /// A regular file that, after following symbolic links, is still inside `base`.
    public var isFileInside: FilePathDetector.FileCheck {
        { [self] path, base in check(path, base: base) }
    }

    func check(_ path: String, base: String) -> Bool {
        let key = base + "\u{0}" + path
        let now = Date()
        if let entry = entries.withLock({ $0[key] }), now.timeIntervalSince(entry.checked) < lifetime { return entry.isFile }
        let isFile = Self.diskCheck(path, base: base)
        entries.withLock { entries in
            if entries.count > 4000 { entries.removeAll(keepingCapacity: true) }
            entries[key] = Entry(isFile: isFile, checked: now)
        }
        return isFile
    }

    public static func diskCheck(_ path: String, base: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        let real = (path as NSString).resolvingSymlinksInPath
        let realBase = (base as NSString).resolvingSymlinksInPath
        return real.hasPrefix(realBase.hasSuffix("/") ? realBase : realBase + "/")
    }
}

// MARK: - What a click does

/// One entry of a file link's right-click menu. Entries with children are submenus ("Open in").
public struct FileLinkMenuItem: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var children: [FileLinkMenuItem]
    public var action: (@MainActor @Sendable () -> Void)?

    public init(id: String, title: String, symbol: String? = nil, children: [FileLinkMenuItem] = [],
                action: (@MainActor @Sendable () -> Void)? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.children = children
        self.action = action
    }
}

/// What the app does with file links. Paths are only detected when this is set (the Mac app sets it; the iPhone
/// remote does not, since the files are on the Mac).
public struct FileLinkActions: Sendable {
    public var open: @MainActor @Sendable (FileLink) -> Void
    public var menu: @MainActor @Sendable (FileLink) -> [FileLinkMenuItem]

    public init(open: @escaping @MainActor @Sendable (FileLink) -> Void,
                menu: @escaping @MainActor @Sendable (FileLink) -> [FileLinkMenuItem] = { _ in [] }) {
        self.open = open
        self.menu = menu
    }
}

public extension EnvironmentValues {
    @Entry var fileLinkActions: FileLinkActions? = nil
    /// Tints each file link's click area, so snapshots of live windows can check where they sit.
    @Entry var showsFileLinkAreas: Bool = false
}
