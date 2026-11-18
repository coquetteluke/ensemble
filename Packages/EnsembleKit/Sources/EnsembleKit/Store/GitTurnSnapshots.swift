import Foundation
import Observation

/// A snapshot of a session's git folder taken as one of its turns began.
public struct GitTurnMark: Codable, Hashable, Sendable {
    public var date: Date
    /// Repository top the snapshot covers.
    public var root: String
    /// Tree id of the folder at that moment (tracked and new files, ignored ones left out).
    public var tree: String
    /// The commit checked out then, used when the tree is gone (git can prune it after two weeks).
    public var head: String?

    public init(date: Date, root: String, tree: String, head: String?) {
        self.date = date
        self.root = root
        self.tree = tree
        self.head = head
    }
}

#if os(macOS)
/// Snapshots of each session's folder at the start of its turns, so the review pane can show what the whole
/// session changed (since the first turn) and what the last turn changed. Saved as JSON; the snapshots
/// themselves are git tree objects written without touching the index, the work tree or any branch.
@MainActor
public final class GitTurnSnapshots {
    public static let shared = GitTurnSnapshots(fileURL: GitTurnSnapshots.defaultFileURL)

    /// `~/Library/Application Support/Ensemble/review-turns.json`.
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble", isDirectory: true).appendingPathComponent("review-turns.json")
    }

    /// The first mark is always kept (it is the session's baseline); after it, the newest ones.
    public static let keptRecentMarks = 30

    public private(set) var marks: [String: [GitTurnMark]] = [:]
    let fileURL: URL?
    let service: GitReviewService
    private var inFlight: Set<String> = []
    private var topLevels: [String: String] = [:]

    public init(fileURL: URL?, service: GitReviewService = GitReviewService()) {
        self.fileURL = fileURL
        self.service = service
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.reviewTurns.decode([String: [GitTurnMark]].self, from: data) {
            marks = saved
        }
    }

    /// Snapshots `directory`'s repository as a turn of `sessionID` begins. Does nothing outside git, or while a
    /// snapshot for the same session is still being written.
    @discardableResult
    public func recordTurnStart(sessionID: String, directory: String, date: Date = Date()) async -> GitTurnMark? {
        guard !inFlight.contains(sessionID) else { return nil }
        inFlight.insert(sessionID)
        defer { inFlight.remove(sessionID) }
        guard let root = await topLevel(directory) else { return nil }
        guard let tree = try? await service.snapshotTree(root) else { return nil }
        let mark = GitTurnMark(date: date, root: root, tree: tree, head: await service.head(root))
        var list = marks[sessionID] ?? []
        list.append(mark)
        if list.count > Self.keptRecentMarks + 1 {
            list = [list[0]] + list.suffix(Self.keptRecentMarks)
        }
        marks[sessionID] = list
        save()
        return mark
    }

    /// The first snapshot of a session in `root`.
    public func firstMark(sessionID: String, root: String) -> GitTurnMark? {
        marks[sessionID]?.first { $0.root == root }
    }

    /// The newest snapshot of a session in `root`.
    public func lastMark(sessionID: String, root: String) -> GitTurnMark? {
        marks[sessionID]?.last { $0.root == root }
    }

    /// Adds marks directly (tests and previews).
    public func insert(_ mark: GitTurnMark, sessionID: String) {
        marks[sessionID, default: []].append(mark)
        save()
    }

    public func forget(sessionID: String) {
        marks[sessionID] = nil
        save()
    }

    // MARK: Following a store

    /// Follows a store's sessions and snapshots a session's folder each time one of its turns starts (idle to
    /// working). Subagents and hidden sessions (side questions, commit message copies) are skipped. Following
    /// the same store again does nothing.
    public func follow(_ store: SessionStore) {
        let key = ObjectIdentifier(store)
        guard followed[key] == nil else { return }
        followed[key] = Self.working(store)
        observe(store)
    }

    private var followed: [ObjectIdentifier: Set<String>] = [:]

    private static func working(_ store: SessionStore) -> Set<String> {
        Set(store.sessions.filter(\.isWorking).map(\.id))
    }

    private func observe(_ store: SessionStore) {
        withObservationTracking {
            for session in store.sessions { _ = session.activity }
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                self.sessionsChanged(store)
            }
        }
    }

    private func sessionsChanged(_ store: SessionStore) {
        let key = ObjectIdentifier(store)
        let now = Self.working(store)
        let started = now.subtracting(followed[key] ?? [])
        followed[key] = now
        for id in started {
            guard let session = store.session(id), session.info.parentID == nil, !store.hiddenSessionIDs.contains(id),
                  !session.directory.isEmpty else { continue }
            let directory = session.directory
            Task { await recordTurnStart(sessionID: id, directory: directory) }
        }
        observe(store)
    }

    private func topLevel(_ directory: String) async -> String? {
        if let cached = topLevels[directory] { return cached }
        // Only found folders are remembered, so a folder that becomes a repository later is picked up.
        let top = await service.topLevel(directory)
        if let top { topLevels[directory] = top }
        return top
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.reviewTurns.encode(marks).write(to: fileURL, options: .atomic)
        } catch {
            // The marks still work for this run; the next turn tries to save again.
        }
    }
}

extension JSONEncoder {
    static var reviewTurns: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var reviewTurns: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
