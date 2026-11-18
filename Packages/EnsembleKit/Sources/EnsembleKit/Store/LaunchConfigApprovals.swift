import Foundation
import Synchronization

/// Dev server commands the user has confirmed, per folder. Ensemble shows the exact command before the first start of
/// a command in a folder; once confirmed it starts without asking. A changed command (a `git pull` that edits
/// `.ensemble/launch.json`, say) is a new command and is asked about again.
///
/// - Folders are stored resolved with `realpath`, like `WorkspaceTrust`.
/// - Saved in `~/Library/Application Support/Ensemble/dev-server-approvals.json`; a nil file URL keeps them in memory.
public final class LaunchApprovals: Sendable {
    public static let shared = LaunchApprovals()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/dev-server-approvals.json")
    }

    struct Approval: Codable, Hashable, Sendable {
        var folder: String
        var arguments: [String]
    }

    private struct FileBody: Codable {
        var version: Int
        var approvals: [Approval]
    }

    public let fileURL: URL?
    private let state: Mutex<Set<Approval>>

    public init(fileURL: URL? = LaunchApprovals.defaultURL) {
        self.fileURL = fileURL
        var loaded: Set<Approval> = []
        if let fileURL, let data = try? Data(contentsOf: fileURL), let body = try? JSONDecoder().decode(FileBody.self, from: data) {
            loaded = Set(body.approvals)
        }
        state = Mutex(loaded)
    }

    /// True when this exact command was confirmed in this folder.
    public func isApproved(_ arguments: [String], folder: String) -> Bool {
        guard let key = Self.key(arguments, folder: folder) else { return false }
        return state.withLock { $0.contains(key) }
    }

    /// Remembers that the user confirmed this command in this folder.
    public func approve(_ arguments: [String], folder: String) throws {
        guard let key = Self.key(arguments, folder: folder) else { throw WorkspaceTrustError.notAFolder(folder) }
        try change { $0.insert(key) }
    }

    /// Forgets every confirmed command in a folder.
    public func revokeAll(folder: String) throws {
        let resolved = WorkspaceTrust.resolvedPath(folder) ?? folder
        try change { approvals in approvals = approvals.filter { $0.folder != resolved } }
    }

    static func key(_ arguments: [String], folder: String) -> Approval? {
        guard !arguments.isEmpty, let resolved = WorkspaceTrust.resolvedPath(folder) else { return nil }
        return Approval(folder: resolved, arguments: arguments)
    }

    private func change(_ edit: (inout Set<Approval>) -> Void) throws {
        let snapshot = state.withLock { approvals -> Set<Approval> in
            edit(&approvals)
            return approvals
        }
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sorted = snapshot.sorted { ($0.folder, $0.arguments.joined(separator: " ")) < ($1.folder, $1.arguments.joined(separator: " ")) }
        let data = try encoder.encode(FileBody(version: 1, approvals: sorted))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
