import Foundation

/// One row of the Files pane's tree: a file or a folder inside the session's folder.
public struct FileTreeEntry: Identifiable, Hashable, Sendable {
    /// Absolute path.
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// A symbolic link. Links are listed but never walked into, so the tree cannot wander out of the folder.
    public var isLink: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, isLink: Bool = false) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
    }
}

/// Lists and searches a folder for the Files pane. Reads names only, never file contents.
public enum FileTree {
    /// Folders and files that are never listed: version control data and build output that would bury the rest.
    public static let skippedNames: Set<String> = [".git", ".DS_Store", "node_modules", ".build", "DerivedData", ".swiftpm"]

    /// What is in one folder: folders first, then files, each in Finder's name order. A link to a folder is listed
    /// as a link and is not a folder to open. Empty when the folder cannot be read.
    public static func list(_ directory: String) -> [FileTreeEntry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        var entries: [FileTreeEntry] = []
        for name in names where !skippedNames.contains(name) {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: path) else { continue }
            let type = attributes[.type] as? FileAttributeType
            let isLink = type == .typeSymbolicLink
            entries.append(FileTreeEntry(path: path, name: name, isDirectory: type == .typeDirectory, isLink: isLink))
        }
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Files under `root` whose path below it contains every word of `query` (case ignored). Folders are walked
    /// breadth first, links are not followed, and the walk stops after `visitLimit` entries so a huge folder cannot
    /// hang the list. Best matches first: a file name that starts with the first word, then shorter paths.
    public static func search(root: String, query: String, limit: Int = 60, visitLimit: Int = 20_000,
                              isCancelled: () -> Bool = { false }) -> [FileTreeEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var found: [(entry: FileTreeEntry, relative: String)] = []
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < visitLimit, !isCancelled() {
            let directory = queue.removeFirst()
            for entry in list(directory) {
                visited += 1
                if entry.isDirectory {
                    if !entry.isLink { queue.append(entry.path) }
                    continue
                }
                let relative = entry.path.hasPrefix(prefix) ? String(entry.path.dropFirst(prefix.count)) : entry.name
                let haystack = relative.lowercased()
                if words.allSatisfy({ haystack.contains($0) }) { found.append((entry, relative)) }
                if visited >= visitLimit { break }
            }
        }
        return found.sorted { a, b in
            let aStarts = a.entry.name.lowercased().hasPrefix(first)
            let bStarts = b.entry.name.lowercased().hasPrefix(first)
            if aStarts != bStarts { return aStarts }
            if a.relative.count != b.relative.count { return a.relative.count < b.relative.count }
            return a.relative < b.relative
        }.prefix(limit).map(\.entry)
    }

    /// A file's folder below `root`, for the second line of a search result ("Sources/App"); empty at the top.
    public static func folder(of path: String, under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        return (relative as NSString).deletingLastPathComponent
    }
}
