import Foundation
import Observation

// Per-session git worktrees ("Work in a copy"). A session in a git repository can run in its own checkout on its own
// branch, so two sessions in the same project never edit the same files. The copy lives in
// `<project folder>/.ensemble/worktrees/session-<id>` (the folder Team rooms use for their agents' copies, kept out of
// git status by `.git/info/exclude`), on a new branch `ensemble/session-<id>` made from the current HEAD, and the session
// runs in it: its folder is the copy (plus the project folder's place in the repository, when the project folder is
// below the repository's top).
//
// Permissions: the session's folder is the copy itself, so each mode's own rules (`PermissionRules.ruleset(for:)`, and
// the Claude engine's rules, both relative to the session's folder) already let it edit there the way a Team agent's
// worktree rules do, and protect the same things inside it (dot paths such as the copy's `.git` file, OpenCode's config
// shape at its top, build and hook files). Anything outside the copy, the project's own checkout included, is outside
// the session's folder and asks.
//
// Copies are only made in trusted folders (`WorkspaceTrust`); a copy inside a trusted folder is trusted with it.

/// A git worktree Ensemble made for one session.
public struct SessionWorktreeRecord: Codable, Hashable, Sendable, Identifiable {
    /// Short random id: the copy's folder is `session-<id>`, its branch `ensemble/session-<id>`.
    public var id: String
    /// The session running in it, once created.
    public var sessionID: String?
    /// The project folder the copy was made for.
    public var home: String
    /// The copy's top folder.
    public var path: String
    /// Where the session runs: `path`, plus the project folder's place in the repository.
    public var sessionDirectory: String
    /// The branch Ensemble made for the copy.
    public var branch: String
    /// The branch the project folder was on when the copy was made (nil when HEAD was detached).
    public var baseBranch: String?
    public var created: Date
    public var lastUsed: Date
    /// Set for a Team room agent's copy (listed in Settings, never saved in the session list).
    public var room: RoomCopyInfo?

    public init(id: String, sessionID: String? = nil, home: String, path: String, sessionDirectory: String, branch: String,
                baseBranch: String?, created: Date = Date(), lastUsed: Date = Date(), room: RoomCopyInfo? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.home = home
        self.path = path
        self.sessionDirectory = sessionDirectory
        self.branch = branch
        self.baseBranch = baseBranch
        self.created = created
        self.lastUsed = lastUsed
        self.room = room
    }

    /// A Team room agent's copy, from a saved room: `<room folder>/.ensemble/worktrees/<branch>` (see `ProcessGitOps`).
    /// Nil when the assignment has no copy.
    public static func roomCopy(_ assignment: Assignment, in room: RoomState) -> SessionWorktreeRecord? {
        guard let path = assignment.worktreePath, !path.isEmpty else { return nil }
        let agent = room.spec.agents.first { $0.id == assignment.agentID }
        let info = RoomCopyInfo(roomID: room.id, roomTitle: room.spec.title, agentName: agent?.name,
                                finished: room.phase == .finished || room.phase == .stopped)
        return SessionWorktreeRecord(id: "room-\(room.id.uuidString.lowercased())-\(assignment.agentID.uuidString.lowercased())",
                                     sessionID: room.sessions[assignment.agentID], home: room.spec.directory, path: path,
                                     sessionDirectory: room.spec.directory, branch: assignment.branch ?? "",
                                     baseBranch: room.git?.baseBranch, created: room.spec.created, lastUsed: room.spec.created,
                                     room: info)
    }
}

/// The Team room a copy belongs to.
public struct RoomCopyInfo: Codable, Hashable, Sendable {
    public var roomID: UUID
    public var roomTitle: String
    public var agentName: String?
    /// The room's run is finished (or stopped), so its copies can go.
    public var finished: Bool

    public init(roomID: UUID, roomTitle: String, agentName: String?, finished: Bool) {
        self.roomID = roomID
        self.roomTitle = roomTitle
        self.agentName = agentName
        self.finished = finished
    }
}

/// Paths of session copies.
public enum SessionWorktreePaths {
    /// Copies are `<project folder>/.ensemble/worktrees/session-<id>`.
    public static let folderPrefix = "session-"
    public static let branchPrefix = "ensemble/session-"

    /// The copy's folder for an id.
    public static func path(home: String, id: String) -> String {
        (home as NSString).appendingPathComponent(PermissionRules.worktreeFolder + "/" + folderPrefix + id)
    }

    /// The project folder a session folder belongs to: the folder above `.ensemble/worktrees/session-<id>` for a
    /// session in a copy, the folder itself otherwise. The sidebar groups sessions by it.
    public static func projectFolder(for directory: String) -> String {
        let marker = "/" + PermissionRules.worktreeFolder + "/" + folderPrefix
        guard let range = directory.range(of: marker) else { return directory }
        let rest = directory[range.upperBound...]
        let id = rest.prefix { $0 != "/" }
        guard isValidID(String(id)) else { return directory }
        let home = String(directory[..<range.lowerBound])
        return home.isEmpty ? "/" : home
    }

    /// True for a session folder inside a session copy.
    public static func isInCopy(_ directory: String) -> Bool { projectFolder(for: directory) != directory }

    /// Ids are lower-case letters and digits (what `newID` makes), 4 to 32 of them.
    public static func isValidID(_ id: String) -> Bool {
        (4...32).contains(id.count) && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// 8 random lower-case hex digits.
    public static func newID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }
}

/// A local branch for the branch picker.
public struct SessionBranch: Hashable, Sendable, Identifiable {
    public var name: String
    /// The other checkout that has it, when one does: git allows a branch in one checkout at a time.
    public var checkedOutAt: String?
    public var isCurrent: Bool
    public var id: String { name }

    public init(name: String, checkedOutAt: String? = nil, isCurrent: Bool = false) {
        self.name = name
        self.checkedOutAt = checkedOutAt
        self.isCurrent = isCurrent
    }
}

/// A copy as Settings lists it.
public struct SessionWorktreeStatus: Hashable, Sendable, Identifiable {
    public var record: SessionWorktreeRecord
    /// False when the folder is gone (removed outside Ensemble).
    public var exists: Bool
    /// The branch checked out now (it can differ from `record.branch` after a switch).
    public var branch: String?
    /// Files with uncommitted changes, untracked files included.
    public var changedFiles: [String]
    public var sizeBytes: Int64?
    public var id: String { record.id }

    public init(record: SessionWorktreeRecord, exists: Bool, branch: String?, changedFiles: [String], sizeBytes: Int64?) {
        self.record = record
        self.exists = exists
        self.branch = branch
        self.changedFiles = changedFiles
        self.sizeBytes = sizeBytes
    }
}

public enum SessionWorktreeError: Error, LocalizedError, Equatable, Sendable {
    case untrusted(String)
    case notARepository(String)
    case noCommits
    case unknownBranch(String)
    /// The branch is checked out in another checkout.
    case branchInUse(String, at: String)
    case notACopy(String)
    case uncommittedChanges([String])
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .untrusted: "Copies are made only in trusted folders. Trust this folder first."
        case .notARepository: "This folder is not in a git repository."
        case .noCommits: "The repository has no commits yet, so there is nothing to copy."
        case .unknownBranch(let name): "There is no local branch named \(name)."
        case .branchInUse(let name, let path): "\(name) is checked out in \(Format.abbreviatedPath(path)). Git allows a branch in one checkout at a time."
        case .notACopy(let path): "\(Format.abbreviatedPath(path)) is not a session copy Ensemble made."
        case .uncommittedChanges(let files): "The copy has uncommitted changes in \(files.count == 1 ? "1 file" : "\(files.count) files")."
        case .git(let message): message
        }
    }
}

/// Per-session copies of one store: the saved list, the branch picker's data and what is in flight. Held by
/// `SessionStore.worktrees`; the logic lives in `SessionWorktree+Store.swift`.
@Observable @MainActor
public final class SessionWorktrees {
    /// Every copy Ensemble made that is not removed yet, by id.
    public internal(set) var records: [String: SessionWorktreeRecord] = [:]
    /// Settings' list, from the last `refreshWorktreeList`.
    public internal(set) var statuses: [SessionWorktreeStatus] = []
    public internal(set) var listLoaded = false
    /// Branches for the picker, by session id.
    public internal(set) var branches: [String: [SessionBranch]] = [:]
    /// The branch each session's folder is on, by session id (nil entry: not on a branch, or not a repository).
    public internal(set) var currentBranch: [String: String] = [:]
    /// Why a folder cannot get a copy, by folder; an empty string means it can.
    public internal(set) var availability: [String: String] = [:]
    /// Sessions and copies with a change in flight (by session id or record id).
    public internal(set) var busy: Set<String> = []
    /// The last failure, by session id or record id.
    public internal(set) var errors: [String: String] = [:]

    /// Where `records` is saved; nil keeps them in memory (previews, tests, snapshots).
    @ObservationIgnored public private(set) var fileURL: URL?
    /// Saved rooms, for their Team agents' copies in Settings' list. The app's own room folder when the list is saved
    /// to disk; nil lists session copies only.
    @ObservationIgnored public var roomStore: (any RoomStore)?
    @ObservationIgnored public var git = SessionWorktreeGit()
    @ObservationIgnored var loaded = false

    nonisolated public init() {}

    /// `~/Library/Application Support/Ensemble/session-worktrees.json` for the app; nil for previews and test runners.
    nonisolated public static func defaultURL(isPreview: Bool, bundle: Bundle = .main) -> URL? {
        guard !isPreview, bundle.bundleURL.pathExtension == "app" else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/session-worktrees.json")
    }

    /// Sets where the list is saved and reads it.
    public func configure(fileURL: URL?) {
        self.fileURL = fileURL
        if fileURL != nil, roomStore == nil { roomStore = FileRoomStore.standard }
        loaded = false
        loadIfNeeded()
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([SessionWorktreeRecord].self, from: data) {
            records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let list = records.values.sorted { $0.created < $1.created }
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The copy a session runs in.
    public func record(forSession sessionID: String) -> SessionWorktreeRecord? {
        records.values.first { $0.sessionID == sessionID }
    }

    /// Fills the state without git or disk (previews and snapshots).
    public func seedPreview(records: [SessionWorktreeRecord] = [], statuses: [SessionWorktreeStatus] = [],
                            availability: [String: String] = [:], currentBranch: [String: String] = [:],
                            branches: [String: [SessionBranch]] = [:]) {
        loaded = true
        fileURL = nil
        self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.statuses = statuses
        listLoaded = true
        self.availability = availability
        self.currentBranch = currentBranch
        self.branches = branches
    }

    func upsert(_ record: SessionWorktreeRecord) {
        records[record.id] = record
        save()
    }

    func remove(_ id: String) {
        records[id] = nil
        statuses.removeAll { $0.id == id }
        save()
    }
}
