import Foundation

// MARK: - Files in a review

/// How a file changed in a review.
public enum ReviewChangeKind: String, Codable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed

    public var label: String {
        switch self {
        case .added: "New"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}

/// Where a reviewed file stands in git right now.
public enum ReviewStageState: String, Codable, Hashable, Sendable {
    /// Changed in the folder, nothing staged.
    case unstaged
    /// Every change is staged.
    case staged
    /// Some changes are staged, some are not.
    case partial
    /// A new file git does not track yet.
    case untracked
    /// The session changed it, but those changes are already committed.
    case committed
    /// A merge conflict is open in this file.
    case conflicted
    /// The folder is not a git repository (or the file is outside it).
    case notGit

    /// True when the file has changes that are not committed (Stage, Unstage and Discard apply).
    public var hasUncommittedChanges: Bool {
        switch self {
        case .unstaged, .staged, .partial, .untracked: true
        case .committed, .conflicted, .notGit: false
        }
    }
}

/// One hunk of a unified diff (`@@ -a,b +c,d @@` and its lines).
public struct ReviewHunk: Hashable, Sendable {
    /// The `@@` line.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Body lines with their `+`, `-`, space or `\` prefix, without newlines.
    public var lines: [String]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [String]) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    /// The hunk as patch text, ending in a newline.
    public var text: String { ([header] + lines).joined(separator: "\n") + "\n" }

    /// True when the hunk adds or removes lines (not only `\ No newline` changes or context).
    public var hasChanges: Bool { lines.contains { $0.hasPrefix("+") || $0.hasPrefix("-") } }
}

/// A hunk that can go into or out of the index on its own.
public struct ReviewHunkAction: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// The hunk is in the folder but not staged: `git apply --cached`.
        case stage
        /// The hunk is staged: `git apply --cached --reverse`.
        case unstage
    }

    public var kind: Kind
    /// A complete patch (file header plus this one hunk) taken from git's own diff of the index.
    public var patch: String

    public init(kind: Kind, patch: String) {
        self.kind = kind
        self.patch = patch
    }
}

/// One file in the review pane: what changed, its diff and where it stands in git.
public struct ReviewFileDiff: Hashable, Sendable, Identifiable {
    /// The folder git runs in for this file (the repository top, or an agent's worktree). Empty when unknown.
    public var root: String
    /// Path relative to `root` (absolute when the file is outside every known root).
    public var path: String
    /// The path before a rename.
    public var oldPath: String?
    public var kind: ReviewChangeKind
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// Unified diff for this file: header lines then hunks. Empty for binary files.
    public var patch: String
    public var stage: ReviewStageState
    /// The room agent whose work this is, when known.
    public var agentID: UUID?
    /// Hunks that can be staged or unstaged alone, by hunk index in `patch`.
    public var hunkActions: [Int: ReviewHunkAction]
    /// True when the diff came from git (line numbers match the files on disk); false for engine or tool diffs.
    public var fromGit: Bool

    public init(root: String, path: String, oldPath: String? = nil, kind: ReviewChangeKind, additions: Int = 0, deletions: Int = 0,
                isBinary: Bool = false, patch: String = "", stage: ReviewStageState = .notGit, agentID: UUID? = nil,
                hunkActions: [Int: ReviewHunkAction] = [:], fromGit: Bool = true) {
        self.root = root
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.patch = patch
        self.stage = stage
        self.agentID = agentID
        self.hunkActions = hunkActions
        self.fromGit = fromGit
    }

    public var id: String { root + "\u{0}" + path }
    public var fileName: String { (path as NSString).lastPathComponent }
    /// Folder part of `path` ("" at the top).
    public var directoryPart: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    /// Absolute path on disk.
    public var absolutePath: String {
        path.hasPrefix("/") || root.isEmpty ? path : (root as NSString).appendingPathComponent(path)
    }

    /// Every path git must be given to act on this file (both sides of a rename).
    public var gitPaths: [String] { [path] + (oldPath.map { [$0] } ?? []) }

    public var hunks: [ReviewHunk] { GitDiffParsing.hunks(in: patch) }
}

// MARK: - Parsing git output

/// Parsers for the `git` output the review pane reads. Pure functions, so they are tested without git.
public enum GitDiffParsing {
    /// One `--numstat -z` entry.
    public struct NumstatEntry: Hashable, Sendable {
        public var path: String
        public var oldPath: String?
        public var additions: Int
        public var deletions: Int
        public var isBinary: Bool
    }

    /// Parses `git diff --numstat -z` (renames come as `a\td\t\0old\0new\0`, binary files as `-\t-\t`).
    public static func numstat(_ data: Data) -> [NumstatEntry] {
        let tokens = nulTokens(data)
        var entries: [NumstatEntry] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            if token.isEmpty { continue }
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-" && parts[1] == "-"
            let added = Int(parts[0]) ?? 0
            let deleted = Int(parts[1]) ?? 0
            if parts[2].isEmpty {
                guard i + 1 < tokens.count else { break }
                entries.append(NumstatEntry(path: tokens[i + 1], oldPath: tokens[i], additions: added, deletions: deleted, isBinary: binary))
                i += 2
            } else {
                entries.append(NumstatEntry(path: String(parts[2]), oldPath: nil, additions: added, deletions: deleted, isBinary: binary))
            }
        }
        return entries
    }

    /// Splits a whole `git diff` patch into one chunk per file (each starts with `diff --git`).
    public static func fileChunks(_ patch: String) -> [String] {
        var chunks: [String] = []
        var current: [Substring] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") {
                if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty {
            while current.last?.isEmpty == true { current.removeLast() }
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }
    }

    /// Header lines of a file chunk: everything before the first `@@`.
    public static func fileHeader(_ chunk: String) -> String {
        var header: [Substring] = []
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { break }
            header.append(line)
        }
        while header.last?.isEmpty == true { header.removeLast() }
        return header.isEmpty ? "" : header.joined(separator: "\n") + "\n"
    }

    /// How a file chunk says the file changed.
    public static func changeKind(_ chunk: String) -> ReviewChangeKind {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("new file mode") { return .added }
            if line.hasPrefix("deleted file mode") { return .deleted }
            if line.hasPrefix("rename from ") || line.hasPrefix("rename to ") || line.hasPrefix("copy from ") { return .renamed }
        }
        return .modified
    }

    /// Hunks of a unified diff, with their raw body lines.
    public static func hunks(in patch: String) -> [ReviewHunk] {
        var hunks: [ReviewHunk] = []
        var current: ReviewHunk?
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let current { hunks.append(current) }
                let r = hunkRanges(line)
                current = ReviewHunk(header: line, oldStart: r.oldStart, oldCount: r.oldCount, newStart: r.newStart, newCount: r.newCount, lines: [])
            } else if current != nil {
                if line.hasPrefix("diff --git ") {
                    hunks.append(current!)
                    current = nil
                } else if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\\") {
                    current?.lines.append(line)
                } else if line.isEmpty {
                    // A trailing newline at the end of the patch, or an empty context line some tools write without the space.
                    continue
                }
            }
        }
        if let current { hunks.append(current) }
        return hunks
    }

    /// Ranges from `@@ -12,7 +12,9 @@ ...`. A missing count means 1.
    public static func hunkRanges(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        let parts = header.split(separator: " ")
        func range(_ prefix: Character) -> (Int, Int) {
            guard let part = parts.dropFirst().first(where: { $0.first == prefix }) else { return (1, 0) }
            let numbers = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            let start = Int(numbers.first ?? "1") ?? 1
            let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
            return (start, count)
        }
        let (os, oc) = range("-")
        let (ns, nc) = range("+")
        return (os, oc, ns, nc)
    }

    /// One path from `git status --porcelain=v2 -z`.
    public struct StatusEntry: Hashable, Sendable {
        /// Index status letter (`.` when unchanged).
        public var index: Character
        /// Work tree status letter (`.` when unchanged).
        public var worktree: Character
        public var untracked: Bool
        public var conflicted: Bool

        public var state: ReviewStageState {
            if conflicted { return .conflicted }
            if untracked { return .untracked }
            switch (index != ".", worktree != ".") {
            case (true, false): return .staged
            case (true, true): return .partial
            case (false, true): return .unstaged
            case (false, false): return .committed
            }
        }
    }

    /// Parses `git status --porcelain=v2 -z --no-renames`: path -> entry.
    public static func status(_ data: Data) -> [String: StatusEntry] {
        var result: [String: StatusEntry] = [:]
        let tokens = nulTokens(data)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            guard let kind = token.first else { continue }
            switch kind {
            case "1", "2", "u":
                // Fields before the path: 8 for "1", 9 for "2", 10 for "u".
                let before = kind == "1" ? 8 : (kind == "2" ? 9 : 10)
                let fields = token.split(separator: " ", maxSplits: before, omittingEmptySubsequences: false)
                guard fields.count == before + 1 else { continue }
                let xy = Array(fields[1])
                guard xy.count == 2 else { continue }
                result[String(fields[before])] = StatusEntry(index: xy[0], worktree: xy[1], untracked: false, conflicted: kind == "u")
                // A rename entry is followed by its original path.
                if kind == "2" { i += 1 }
            case "?":
                result[String(token.dropFirst(2))] = StatusEntry(index: ".", worktree: "?", untracked: true, conflicted: false)
            default:
                continue
            }
        }
        return result
    }

    static func nulTokens(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The path a file chunk names on its `+++ b/` line (or `rename to`), to match chunks to numstat entries.
    static func chunkPath(_ chunk: String) -> String? {
        var fallback: String?
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("+++ b/") { return unquote(String(line.dropFirst(6))) }
            if line.hasPrefix("rename to ") { fallback = unquote(String(line.dropFirst(10))) }
            if line.hasPrefix("--- a/"), fallback == nil { fallback = unquote(String(line.dropFirst(6))) }
        }
        return fallback
    }

    /// Undoes git's C-style quoting of a path (`"a\tb"`), which it still uses for control characters.
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        var bytes: [UInt8] = []
        var chars = Array(value.dropFirst().dropLast().utf8)[...]
        while let c = chars.popFirst() {
            guard c == UInt8(ascii: "\\"), let next = chars.popFirst() else {
                bytes.append(c)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let d = chars.first, d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") else { break }
                    chars.removeFirst()
                    octal = octal * 8 + Int(d - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: octal))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Pairs numstat entries with file chunks. Both come from the same diff in the same order; when the
    /// counts differ, chunks are matched by the path they name.
    static func pair(_ entries: [NumstatEntry], _ chunks: [String]) -> [(NumstatEntry, String)] {
        if entries.count == chunks.count { return Array(zip(entries, chunks)) }
        var byPath: [String: String] = [:]
        for chunk in chunks { if let path = chunkPath(chunk) { byPath[path] = chunk } }
        return entries.map { ($0, byPath[$0.path] ?? "") }
    }

    // MARK: Hunk matching

    /// Hunks of the session diff that match a hunk of the index diffs exactly, so they can be staged or
    /// unstaged alone. A hunk matches an unstaged hunk with the same lines and the same new-side range (both
    /// diffs end at the work tree), or a staged hunk with the same lines and the same old-side range (both
    /// start at the last commit). Text git could not read as UTF-8 never matches.
    public static func hunkActions(session: String, unstaged: String?, staged: String?) -> [Int: ReviewHunkAction] {
        guard !session.contains("\u{FFFD}") else { return [:] }
        let sessionHunks = hunks(in: session)
        var actions: [Int: ReviewHunkAction] = [:]
        let unstagedHunks = unstaged.flatMap { $0.contains("\u{FFFD}") ? nil : $0 }.map { (fileHeader($0), hunks(in: $0)) }
        let stagedHunks = staged.flatMap { $0.contains("\u{FFFD}") ? nil : $0 }.map { (fileHeader($0), hunks(in: $0)) }
        for (index, hunk) in sessionHunks.enumerated() where hunk.hasChanges {
            if let (header, candidates) = unstagedHunks, isPatchableHeader(header),
               let match = candidates.first(where: { $0.lines == hunk.lines && $0.newStart == hunk.newStart && $0.newCount == hunk.newCount }) {
                actions[index] = ReviewHunkAction(kind: .stage, patch: header + match.text)
            } else if let (header, candidates) = stagedHunks, isPatchableHeader(header),
                      let match = candidates.first(where: { $0.lines == hunk.lines && $0.oldStart == hunk.oldStart && $0.oldCount == hunk.oldCount }) {
                actions[index] = ReviewHunkAction(kind: .unstage, patch: header + match.text)
            }
        }
        return actions
    }

    /// Hunks are applied one at a time only to plain modifications: not to new, deleted, renamed or binary files,
    /// and not when the file mode changes.
    static func isPatchableHeader(_ header: String) -> Bool {
        for line in header.split(separator: "\n") {
            if line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") || line.hasPrefix("rename ")
                || line.hasPrefix("copy ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") || line.hasPrefix("Binary files")
                || line.hasPrefix("GIT binary patch") {
                return false
            }
        }
        return header.contains("--- ") && header.contains("+++ ")
    }
}
