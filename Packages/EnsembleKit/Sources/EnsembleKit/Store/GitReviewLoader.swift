import Foundation

/// A room agent as the review pane sees it: who it is, which session talks to it, and where it works.
public struct ReviewAgentSource: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var sessionID: String?
    /// The agent's own git worktree, when it has one (`.ensemble/worktrees/...`).
    public var worktree: String?
    /// The branch its worktree branched from (the room's base branch).
    public var baseBranch: String?

    public init(id: UUID, name: String, colorHex: String, sessionID: String? = nil, worktree: String? = nil, baseBranch: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sessionID = sessionID
        self.worktree = worktree
        self.baseBranch = baseBranch
    }
}

/// What the review pane reviews: one session, or a room and its agents.
public struct ReviewTarget: Hashable, Sendable, Identifiable {
    /// The session id, or `room:<uuid>`.
    public var id: String
    public var title: String
    /// The session's or room's project folder.
    public var directory: String
    public var created: Date
    /// Sessions whose turns belong to this review (the session, or every room agent's session).
    public var sessionIDs: [String]
    /// Room agents; empty for a plain session.
    public var agents: [ReviewAgentSource]

    public init(id: String, title: String, directory: String, created: Date, sessionIDs: [String], agents: [ReviewAgentSource] = []) {
        self.id = id
        self.title = title
        self.directory = directory
        self.created = created
        self.sessionIDs = sessionIDs
        self.agents = agents
    }

    public var isRoom: Bool { !agents.isEmpty }

    public static func session(id: String, title: String, directory: String, created: Date) -> ReviewTarget {
        ReviewTarget(id: id, title: title, directory: directory, created: created, sessionIDs: [id])
    }

    public func agent(_ id: UUID) -> ReviewAgentSource? { agents.first { $0.id == id } }
}

/// Which changes the pane shows.
public enum ReviewScope: Hashable, Sendable {
    /// Everything the session (or room) changed.
    case all
    /// What the most recent turn changed.
    case lastTurn
    /// One room agent's work.
    case agent(UUID)
}

/// What the engine knows, for folders that are not git repositories and for turns without a snapshot.
public struct ReviewEngineData: Sendable {
    /// The engine's changed files per session id (`OpenCodeAPI.changedFiles`).
    public var changes: [String: [FileChange]]
    /// Transcripts per session id, for the edits of the last turn.
    public var transcripts: [String: [TranscriptItem]]

    public init(changes: [String: [FileChange]] = [:], transcripts: [String: [TranscriptItem]] = [:]) {
        self.changes = changes
        self.transcripts = transcripts
    }
}

/// The files a review shows and what they are compared with.
public struct ReviewResult: Sendable, Equatable {
    public var files: [ReviewFileDiff]
    /// False when the folder is not a git repository (no staging or commits).
    public var isGit: Bool
    /// What the diff is compared with, in a few words.
    public var comparison: String
    /// The repository folder to trust before git can run, when that is why these diffs come from the engine.
    public var untrustedFolder: String?

    public init(files: [ReviewFileDiff], isGit: Bool, comparison: String, untrustedFolder: String? = nil) {
        self.files = files
        self.isGit = isGit
        self.comparison = comparison
        self.untrustedFolder = untrustedFolder
    }
}

/// Builds edit-based file diffs from what agents report, without git.
public enum ReviewEngineDiffs {
    /// Files from the engine's changed-files list, paths made relative to `directory`.
    public static func files(from changes: [FileChange], directory: String, agentID: UUID? = nil) -> [ReviewFileDiff] {
        changes.map { change in
            let kind: ReviewChangeKind = switch change.kind {
            case .added: .added
            case .deleted: .deleted
            case .modified: .modified
            }
            let patch = change.diff ?? ""
            var additions = change.additions
            var deletions = change.deletions
            if additions == 0, deletions == 0, !patch.isEmpty {
                (additions, deletions) = Format.diffStats(patch)
            }
            return ReviewFileDiff(root: directory, path: Format.relativePath(change.path, base: directory), kind: kind,
                                  additions: additions, deletions: deletions, patch: patch, stage: .notGit,
                                  agentID: agentID, fromGit: false)
        }
    }

    /// The file edits of the transcript's last turn (tool calls after the last message you sent), one entry per
    /// file with the edits' diffs in order.
    public static func lastTurnFiles(_ items: [TranscriptItem], root: String, agentID: UUID? = nil) -> [ReviewFileDiff] {
        let start = items.lastIndex { if case .user = $0 { true } else { false } }.map { items.index(after: $0) } ?? items.startIndex
        var order: [String] = []
        var diffs: [String: [String]] = [:]
        var created: Set<String> = []
        for item in items[start...] {
            guard case .tool(let tool) = item, let diff = tool.diff, !diff.isEmpty, let path = editedPath(tool) else { continue }
            let relative = Format.relativePath(path, base: root)
            if diffs[relative] == nil { order.append(relative) }
            diffs[relative, default: []].append(diff)
            if diff.contains("--- /dev/null") { created.insert(relative) }
        }
        return order.map { path in
            let patch = (diffs[path] ?? []).joined(separator: "\n")
            let stats = Format.diffStats(patch)
            return ReviewFileDiff(root: root, path: path, kind: created.contains(path) && stats.deletions == 0 ? .added : .modified,
                                  additions: stats.additions, deletions: stats.deletions, patch: patch, stage: .notGit,
                                  agentID: agentID, fromGit: false)
        }
    }

    /// The file a tool call edited: `file_path`, `filePath`, `path` or `filename` in its input, else its title.
    static func editedPath(_ tool: ToolCallInfo) -> String? {
        if let data = tool.inputJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["file_path", "filePath", "path", "filename", "file"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        let title = tool.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !title.contains(" "), title.contains("/") || title.contains(".") else { return nil }
        return title
    }
}

#if os(macOS)
/// Loads a review: the git diff of the session's folder against the snapshot from before its first turn
/// (or its last turn), with stage states, falling back to the engine's own record of edits where git cannot
/// answer. Git runs only when the repository is trusted (`service.trust`); otherwise the engine's record is
/// shown with the folder to trust, and no git command runs at all.
public struct GitReviewLoader: Sendable {
    public var service: GitReviewService

    public init(service: GitReviewService = GitReviewService()) {
        self.service = service
    }

    /// `marks` holds each target session's turn snapshots (from `GitTurnSnapshots`).
    public func load(_ target: ReviewTarget, scope: ReviewScope, marks: [String: [GitTurnMark]],
                     engine: ReviewEngineData) async throws -> ReviewResult {
        let folder: String?
        do {
            folder = try service.trustedRepository(target.directory)
        } catch let error as GitUntrustedError {
            var result = nonGit(target, scope: scope, engine: engine)
            result.untrustedFolder = error.folder
            result.comparison = "The agent's record of its edits, because git does not run in folders you have not trusted"
            return result
        }
        // git must agree on the folder: a repository whose config moves its work tree elsewhere is not reviewed.
        guard let folder, let top = await service.topLevel(target.directory), WorkspaceTrust.resolvedPath(top) == folder else {
            return nonGit(target, scope: scope, engine: engine)
        }
        if target.isRoom {
            return try await room(target, top: top, scope: scope, marks: marks, engine: engine)
        }
        return try await session(target, top: top, scope: scope, marks: marks, engine: engine)
    }

    // MARK: One session

    private func session(_ target: ReviewTarget, top: String, scope: ReviewScope, marks: [String: [GitTurnMark]],
                         engine: ReviewEngineData) async throws -> ReviewResult {
        let sessionID = target.sessionIDs.first ?? target.id
        if scope == .lastTurn {
            if let mark = marks[sessionID]?.last(where: { $0.root == top }), let base = await usableBase(mark, root: top) {
                let files = try await service.review(root: top, since: base)
                return ReviewResult(files: files, isGit: true, comparison: "Compared with the folder before the last turn")
            }
            let edits = ReviewEngineDiffs.lastTurnFiles(engine.transcripts[sessionID] ?? [], root: top)
            let files = await service.attachStageInfo(edits, root: top)
            return ReviewResult(files: files, isGit: true, comparison: "The agent's edits in the last turn")
        }
        let (base, comparison) = await sessionBase(sessionIDs: [sessionID], top: top, created: target.created, marks: marks)
        let files = try await service.review(root: top, since: base)
        return ReviewResult(files: files, isGit: true, comparison: comparison)
    }

    /// The tree or commit a whole-session diff starts from, and how to say it.
    func sessionBase(sessionIDs: [String], top: String, created: Date, marks: [String: [GitTurnMark]]) async -> (String, String) {
        let firsts = sessionIDs.compactMap { id in marks[id]?.first { $0.root == top } }.sorted { $0.date < $1.date }
        for mark in firsts {
            if await service.exists(mark.tree, in: top) {
                return (mark.tree, "Compared with the folder before the first turn")
            }
            if let head = mark.head, await service.exists(head, in: top) {
                return (head, "Compared with the commit checked out at the first turn")
            }
        }
        if let commit = await service.head(top, before: created) {
            return (commit, "Compared with the last commit before the session started")
        }
        return (await service.emptyTree(top), "Compared with an empty folder")
    }

    private func usableBase(_ mark: GitTurnMark, root: String) async -> String? {
        if await service.exists(mark.tree, in: root) { return mark.tree }
        if let head = mark.head, await service.exists(head, in: root) { return head }
        return nil
    }

    // MARK: Rooms

    private func room(_ target: ReviewTarget, top: String, scope: ReviewScope, marks: [String: [GitTurnMark]],
                      engine: ReviewEngineData) async throws -> ReviewResult {
        // Agents with their own worktree are diffed there; the others share the project folder.
        var worktreeAgents: [(ReviewAgentSource, String)] = []
        for agent in target.agents {
            if let worktree = agent.worktree, FileManager.default.fileExists(atPath: worktree),
               let folder = try? service.trustedRepository(worktree),
               let root = await service.topLevel(worktree), root != top, WorkspaceTrust.resolvedPath(root) == folder {
                worktreeAgents.append((agent, root))
            }
        }
        let sharedAgents = target.agents.filter { agent in !worktreeAgents.contains { $0.0.id == agent.id } }
        // Which agent touched which shared file, from each agent session's own changed-files list.
        var owner: [String: UUID] = [:]
        for agent in sharedAgents {
            guard let sessionID = agent.sessionID else { continue }
            for change in engine.changes[sessionID] ?? [] {
                owner[Format.relativePath(change.path, base: top)] = agent.id
            }
        }

        if scope == .lastTurn {
            var files: [ReviewFileDiff] = []
            for agent in target.agents {
                let root = worktreeAgents.first { $0.0.id == agent.id }?.1 ?? top
                guard let sessionID = agent.sessionID else { continue }
                if let mark = marks[sessionID]?.last(where: { $0.root == root }), let base = await usableBase(mark, root: root) {
                    files += try await service.review(root: root, since: base).map { tagged($0, agent.id) }
                } else {
                    let edits = ReviewEngineDiffs.lastTurnFiles(engine.transcripts[sessionID] ?? [], root: root, agentID: agent.id)
                    files += await service.attachStageInfo(edits, root: root)
                }
            }
            return ReviewResult(files: dedupe(files), isGit: true, comparison: "Each agent's last turn")
        }

        var files: [ReviewFileDiff] = []
        let wantsShared: Bool = {
            if case .agent(let id) = scope { return sharedAgents.contains { $0.id == id } }
            return true
        }()
        var comparison = "Compared with each agent's base branch"
        if wantsShared {
            let (base, sharedComparison) = await sessionBase(sessionIDs: target.sessionIDs, top: top, created: target.created, marks: marks)
            var shared = try await service.review(root: top, since: base).map { file -> ReviewFileDiff in
                var file = file
                file.agentID = owner[file.path] ?? (sharedAgents.count == 1 ? sharedAgents.first?.id : nil)
                return file
            }
            if case .agent(let id) = scope { shared = shared.filter { $0.agentID == id } }
            files += shared
            comparison = worktreeAgents.isEmpty ? sharedComparison : sharedComparison + ", and each worktree with its base branch"
        }
        for (agent, root) in worktreeAgents {
            if case .agent(let id) = scope, id != agent.id { continue }
            let base: String
            if let branch = agent.baseBranch, let mergeBase = await service.mergeBase(root, base: branch) {
                base = mergeBase
            } else if let head = await service.head(root) {
                base = head
            } else {
                base = await service.emptyTree(root)
            }
            files += try await service.review(root: root, since: base).map { tagged($0, agent.id) }
        }
        if case .agent(let id) = scope, let agent = target.agent(id) {
            comparison = worktreeAgents.contains(where: { $0.0.id == id })
                ? "Compared with \(agent.baseBranch ?? "the base branch")" : comparison
        }
        return ReviewResult(files: files, isGit: true, comparison: comparison)
    }

    private func tagged(_ file: ReviewFileDiff, _ agentID: UUID) -> ReviewFileDiff {
        var file = file
        file.agentID = agentID
        return file
    }

    /// Two agents sharing a folder can both report the same file; it is shown once.
    private func dedupe(_ files: [ReviewFileDiff]) -> [ReviewFileDiff] {
        var seen: Set<String> = []
        return files.filter { seen.insert($0.id).inserted }
    }

    // MARK: Not a repository

    private func nonGit(_ target: ReviewTarget, scope: ReviewScope, engine: ReviewEngineData) -> ReviewResult {
        let directory = target.directory
        var files: [ReviewFileDiff] = []
        if target.isRoom {
            for agent in target.agents {
                if case .agent(let id) = scope, id != agent.id { continue }
                guard let sessionID = agent.sessionID else { continue }
                files += scope == .lastTurn
                    ? ReviewEngineDiffs.lastTurnFiles(engine.transcripts[sessionID] ?? [], root: directory, agentID: agent.id)
                    : ReviewEngineDiffs.files(from: engine.changes[sessionID] ?? [], directory: directory, agentID: agent.id)
            }
        } else {
            let sessionID = target.sessionIDs.first ?? target.id
            files = scope == .lastTurn
                ? ReviewEngineDiffs.lastTurnFiles(engine.transcripts[sessionID] ?? [], root: directory)
                : ReviewEngineDiffs.files(from: engine.changes[sessionID] ?? [], directory: directory)
        }
        let comparison = scope == .lastTurn ? "The agent's edits in the last turn" : "The engine's record of edits (not a git folder)"
        return ReviewResult(files: dedupe(files), isGit: false, comparison: comparison)
    }
}
#endif
