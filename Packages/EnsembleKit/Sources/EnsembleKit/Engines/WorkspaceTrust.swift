import Foundation
import Observation
import Synchronization

/// Why a folder could not be trusted.
public enum WorkspaceTrustError: Error, LocalizedError, Equatable, Sendable {
    /// The path does not exist or is not a folder.
    case notAFolder(String)
    /// The root folder, the home folder or a folder above it: trusting it would trust every project the user has.
    case tooBroad(String)
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAFolder(let path): "Not a folder: \(path)"
        case .tooBroad(let path): "Trusting \(path) would trust every project in your home folder. Trust the project folder instead."
        case .saveFailed(let message): "Could not save the trusted folders: \(message)"
        }
    }
}

/// Folders whose own agent settings the user has agreed to run.
///
/// A project can carry settings that run code with the user's rights as soon as an agent starts in it (Claude Code's
/// `.claude/settings.json` hooks, `env` and `apiKeyHelper`, its `.mcp.json` servers). Interactive tools ask before
/// using them ("Do you trust this folder?"), but headless runs skip that question, so Ensemble asks instead and
/// engines only load a project's own settings when its folder is trusted here.
///
/// - Paths are stored resolved with `realpath`, so a symlink to a folder and the folder are the same entry, and a link
///   inside a trusted folder that points elsewhere is not trusted.
/// - A trusted folder trusts everything inside it, except a folder trusted on its own (`trust(_:includingSubfolders:)`
///   with `false`, used for the home folder), which trusts only itself.
/// - Saved in `~/Library/Application Support/Ensemble/trusted-folders.json`.
/// - Observable: SwiftUI views and `withObservationTracking` see `folders` change.
public final class WorkspaceTrust: Observable, Sendable {
    /// The app-wide store.
    public static let shared = WorkspaceTrust()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/trusted-folders.json")
    }

    public let fileURL: URL
    private let homeDirectory: String
    private let registrar = ObservationRegistrar()
    private let state: Mutex<Entries>

    private struct Entries {
        /// Folders trusted with everything inside them.
        var folders: [String] = []
        /// Folders trusted on their own, not the folders inside them.
        var exact: [String] = []
    }

    private struct FileBody: Codable {
        var version: Int
        var folders: [String]
        /// Version 2: folders trusted on their own. Missing in version 1 files.
        var onlyThisFolder: [String]?
    }

    /// - Parameter homeDirectory: the folder that may not be trusted as a whole (nor anything above it).
    public init(fileURL: URL = WorkspaceTrust.defaultURL, homeDirectory: String = NSHomeDirectory()) {
        self.fileURL = fileURL
        self.homeDirectory = Self.resolvedPath(homeDirectory) ?? homeDirectory
        var entries = Entries()
        if let data = try? Data(contentsOf: fileURL), let body = try? JSONDecoder().decode(FileBody.self, from: data) {
            entries.folders = body.folders.filter { Self.components($0) != nil }.sorted()
            entries.exact = (body.onlyThisFolder ?? []).filter { Self.components($0) != nil }.sorted()
        }
        state = Mutex(entries)
    }

    /// The folders trusted with everything inside them, resolved, sorted.
    public var folders: [String] {
        registrar.access(self, keyPath: \.folders)
        return state.withLock { $0.folders }
    }

    /// The folders trusted on their own (not the folders inside them), resolved, sorted.
    public var onlyThisFolder: [String] {
        registrar.access(self, keyPath: \.folders)
        return state.withLock { $0.exact }
    }

    /// The home folder, resolved. It can be trusted only on its own.
    public var homeFolder: String { homeDirectory }

    /// True when the folder, or a folder it is in, is trusted. The folder is resolved with `realpath` first.
    public func isTrusted(_ directory: String) -> Bool {
        registrar.access(self, keyPath: \.folders)
        guard let resolved = Self.resolvedPath(directory), let wanted = Self.components(resolved) else { return false }
        return state.withLock { entries in
            entries.exact.contains { Self.components($0) == wanted } || entries.folders.contains { folder in
                guard let base = Self.components(folder) else { return false }
                return wanted.count >= base.count && Array(wanted.prefix(base.count)) == base
            }
        }
    }

    /// Trusts a folder and everything inside it, or with `includingSubfolders: false` the folder on its own. The home
    /// folder can only be trusted on its own, and a folder above it not at all.
    public func trust(_ directory: String, includingSubfolders: Bool = true) throws {
        guard let resolved = Self.resolvedPath(directory), Self.isDirectory(resolved) else {
            throw WorkspaceTrustError.notAFolder(directory)
        }
        if let wanted = Self.components(resolved), let home = Self.components(homeDirectory),
           wanted.count <= home.count, Array(home.prefix(wanted.count)) == wanted {
            // The home folder itself may be trusted on its own; anything above it never.
            guard !includingSubfolders, wanted == home else { throw WorkspaceTrustError.tooBroad(resolved) }
        }
        try change { entries in
            if includingSubfolders {
                if !entries.folders.contains(resolved) { entries.folders.append(resolved) }
            } else if !entries.exact.contains(resolved) {
                entries.exact.append(resolved)
            }
        }
    }

    /// Stops trusting a folder and every trusted folder inside it. A folder above it that is trusted still trusts it.
    public func revoke(_ directory: String) throws {
        let resolved = Self.resolvedPath(directory) ?? directory
        guard let base = Self.components(resolved) else { return }
        try change { entries in
            let inside: (String) -> Bool = { folder in
                guard let parts = Self.components(folder) else { return true }
                return parts.count >= base.count && Array(parts.prefix(base.count)) == base
            }
            entries.folders.removeAll(where: inside)
            entries.exact.removeAll(where: inside)
        }
    }

    private func change(_ edit: (inout Entries) -> Void) throws {
        var failure: Error?
        registrar.withMutation(of: self, keyPath: \.folders) {
            state.withLock { entries in
                edit(&entries)
                entries.folders.sort()
                entries.exact.sort()
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(FileBody(version: 2, folders: entries.folders,
                                                           onlyThisFolder: entries.exact.isEmpty ? nil : entries.exact))
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    failure = error
                }
            }
        }
        if let failure { throw WorkspaceTrustError.saveFailed(failure.localizedDescription) }
    }

    // MARK: Paths

    /// An absolute path with every symlink resolved (`realpath`). For a path that does not exist yet (a new file), the
    /// deepest existing folder is resolved and the rest appended. Returns nil for a relative path, a missing part
    /// named `..`, or a link that points nowhere (writing through it would create its target, wherever that is).
    public static func resolvedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        var existing = path
        var tail: [String] = []
        while true {
            if let real = realPath(existing) {
                guard !tail.contains("..") else { return nil }
                let rest = tail.reversed().filter { $0 != "." && !$0.isEmpty }
                guard !rest.isEmpty else { return real }
                return (real == "/" ? "" : real) + "/" + rest.joined(separator: "/")
            }
            // Something is there but cannot be resolved: a dangling link, a loop, or no permission.
            if entryExists(existing) { return nil }
            let parent = (existing as NSString).deletingLastPathComponent
            guard parent != existing, !parent.isEmpty else { return nil }
            tail.append((existing as NSString).lastPathComponent)
            existing = parent
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") || parts.contains(".") { return nil }
        return parts
    }
}
