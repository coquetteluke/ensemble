import Foundation
import Observation

/// The user's own marks on sessions: pinned, unread (finished while not looked at) and completed.
///
/// Saved as JSON in `~/Library/Application Support/Ensemble/session-marks.json` after every change.
/// Pass `fileURL: nil` for a store that lives only in memory (previews, snapshots, tests).
@Observable @MainActor
public final class SessionAttentionMarks {
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/session-marks.json")
    }

    public let fileURL: URL?
    /// When each session was pinned.
    public private(set) var pinned: [String: Date] = [:]
    public private(set) var unread: Set<String> = []
    /// When each session was marked completed.
    public private(set) var completed: [String: Date] = [:]
    /// The last save that failed, in a line.
    public private(set) var saveError: String?

    struct FileBody: Codable, Equatable {
        var version = 1
        var pinned: [String: Date] = [:]
        var unread: [String] = []
        var completed: [String: Date] = [:]
    }

    public init(fileURL: URL? = SessionAttentionMarks.defaultURL) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let body = try? decoder.decode(FileBody.self, from: data) else { return }
        pinned = body.pinned
        unread = Set(body.unread)
        completed = body.completed
    }

    // MARK: Queries

    public func isPinned(_ sessionID: String) -> Bool { pinned[sessionID] != nil }
    public func isUnread(_ sessionID: String) -> Bool { unread.contains(sessionID) }
    public func isCompleted(_ sessionID: String) -> Bool { completed[sessionID] != nil }

    // MARK: Changes (each saves when something changed)

    public func setPinned(_ sessionID: String, _ on: Bool, at date: Date = Date()) {
        guard isPinned(sessionID) != on else { return }
        pinned[sessionID] = on ? date : nil
        save()
    }

    public func setUnread(_ sessionID: String, _ on: Bool) {
        guard isUnread(sessionID) != on else { return }
        if on { unread.insert(sessionID) } else { unread.remove(sessionID) }
        save()
    }

    /// Marking completed also clears unread: the user has dealt with it.
    public func setCompleted(_ sessionID: String, _ on: Bool, at date: Date = Date()) {
        let unreadChanged = on && unread.contains(sessionID)
        guard isCompleted(sessionID) != on || unreadChanged else { return }
        completed[sessionID] = on ? date : nil
        if on { unread.remove(sessionID) }
        save()
    }

    /// Drops every mark of a deleted session.
    public func forget(_ sessionID: String) {
        guard isPinned(sessionID) || isUnread(sessionID) || isCompleted(sessionID) else { return }
        pinned[sessionID] = nil
        unread.remove(sessionID)
        completed[sessionID] = nil
        save()
    }

    /// Replaces every mark at once (snapshots and previews).
    public func replace(pinned: [String: Date] = [:], unread: Set<String> = [], completed: [String: Date] = [:]) {
        self.pinned = pinned
        self.unread = unread
        self.completed = completed
        save()
    }

    // MARK: Saving

    private func save() {
        guard let fileURL else { return }
        let body = FileBody(pinned: pinned, unread: unread.sorted(), completed: completed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(body).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save session marks: \(error.localizedDescription)"
        }
    }
}
