import SwiftUI
import EnsembleKit

/// What the review pane needs from the rest of the app, so the same model serves a session and a room.
struct ReviewEnvironment {
    /// The target as it is now (a room's worktrees appear once its agents start).
    var currentTarget: @MainActor () -> ReviewTarget
    /// The engine's changed files and transcripts, for folders without git and turns without a snapshot.
    var engineData: @MainActor (ReviewTarget) async -> ReviewEngineData
    /// Sends a message to the agent: `nil` is the session (or the room's lead). Held while the agent works.
    var send: @MainActor (String, UUID?) async -> Void
    /// Asks the agent (`nil` as above) for a one-line commit message.
    var draftMessage: @MainActor ([ReviewFileDiff], UUID?) async throws -> String
    /// True while the agent that would get `send` is working.
    var isAgentWorking: @MainActor (UUID?) -> Bool

    /// Does nothing; for snapshots.
    static func inert(_ target: ReviewTarget) -> ReviewEnvironment {
        ReviewEnvironment(currentTarget: { target }, engineData: { _ in ReviewEngineData() }, send: { _, _ in },
                          draftMessage: { _, _ in "" }, isAgentWorking: { _ in false })
    }
}

/// A comment being written or edited under a diff line.
struct ReviewCommentDraft: Equatable {
    var key: ReviewLineKey
    var path: String
    var quoted: String
    var agentID: UUID?
    var text: String
    /// The comment being edited, or nil for a new one.
    var editing: UUID?
}

/// State of the review pane for one session or room: the files, the comments waiting to be sent, and the
/// commit message. Kept by `ReviewCenter` so closing the pane keeps your comments.
@Observable @MainActor
final class ReviewModel {
    private(set) var target: ReviewTarget
    var scope: ReviewScope = .all {
        didSet { if scope != oldValue { Task { await reload() } } }
    }
    private(set) var result: ReviewResult?
    private(set) var parsed: [String: ParsedDiff] = [:]
    private(set) var lineCounts: [String: Int] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    var collapsed: Set<String> = []
    var showAllFiles = false

    private(set) var comments: [ReviewComment] = []
    var draft: ReviewCommentDraft?
    private(set) var isSending = false
    /// A line under the comments bar after sending, until the next change.
    private(set) var sentNote: String?

    var commitMessage = ""
    private(set) var isWritingMessage = false
    private(set) var isCommitting = false
    private(set) var lastCommit: String?
    private(set) var busyFiles: Set<String> = []
    /// The last git or agent action that failed, in a line.
    var actionError: String?
    /// The file waiting for the Discard confirmation.
    var discardCandidate: ReviewFileDiff?
    private(set) var branches: [String: String] = [:]

    @ObservationIgnored let environment: ReviewEnvironment
    @ObservationIgnored let service: GitReviewService
    @ObservationIgnored let snapshots: GitTurnSnapshots?
    @ObservationIgnored private var loadGeneration = 0

    init(target: ReviewTarget, environment: ReviewEnvironment, service: GitReviewService = GitReviewService(),
         snapshots: GitTurnSnapshots? = .shared) {
        self.target = target
        self.environment = environment
        self.service = service
        self.snapshots = snapshots
    }

    /// A model filled with ready-made files (snapshots and previews); nothing runs.
    static func preview(target: ReviewTarget, result: ReviewResult, comments: [ReviewComment] = [], draft: ReviewCommentDraft? = nil,
                        commitMessage: String = "", lineCounts: [String: Int] = [:], branch: String? = "main",
                        environment: ReviewEnvironment? = nil) -> ReviewModel {
        let model = ReviewModel(target: target, environment: environment ?? .inert(target), snapshots: nil)
        model.result = result
        model.parsed = Dictionary(uniqueKeysWithValues: result.files.map { ($0.id, ParsedDiff($0.patch)) })
        model.comments = comments
        model.draft = draft
        model.commitMessage = commitMessage
        model.lineCounts = lineCounts
        if let branch { model.branches = Dictionary(uniqueKeysWithValues: Set(result.files.map(\.root)).map { ($0, branch) }) }
        return model
    }

    // MARK: Derived

    var files: [ReviewFileDiff] { result?.files ?? [] }
    var isGit: Bool { result?.isGit ?? false }
    var totals: (additions: Int, deletions: Int) {
        files.reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
    }
    var stagedFiles: [ReviewFileDiff] { files.filter { $0.stage == .staged || $0.stage == .partial } }
    var uncommittedFiles: [ReviewFileDiff] { files.filter { $0.stage.hasUncommittedChanges && !$0.root.isEmpty } }

    /// The branch each commit lands on, for the commit box ("main", or "main, ensemble/room/ada").
    var commitBranches: String {
        let roots = Set((stagedFiles.isEmpty ? uncommittedFiles : stagedFiles).map(\.root))
        return roots.compactMap { branches[$0] }.sorted().joined(separator: ", ")
    }

    var commitTitle: String { stagedFiles.isEmpty ? "Stage all and commit" : "Commit" }
    var canCommit: Bool {
        isGit && !isCommitting && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !uncommittedFiles.isEmpty
    }

    /// The agent that gets comments and writes the commit message when only one is in view.
    var focusedAgentID: UUID? {
        if case .agent(let id) = scope { return id }
        return nil
    }

    func comments(at key: ReviewLineKey) -> [ReviewComment] {
        comments.filter { $0.lineKey == key }
    }

    func agent(_ id: UUID?) -> ReviewAgentSource? { id.flatMap { target.agent($0) } }

    // MARK: Loading

    /// Loads the first time the pane opens.
    func loadIfNeeded() async {
        guard result == nil, !isLoading else { return }
        await reload()
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        target = environment.currentTarget()
        if case .agent(let id) = scope, target.agent(id) == nil { scope = .all }
        isLoading = true
        loadError = nil
        let target = self.target
        let scope = self.scope
        let marks = snapshots.map { store in
            Dictionary(uniqueKeysWithValues: target.sessionIDs.map { ($0, store.marks[$0] ?? []) })
        } ?? [:]
        let engine = await environment.engineData(target)
        let loader = GitReviewLoader(service: service)
        do {
            let loaded = try await loader.load(target, scope: scope, marks: marks, engine: engine)
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepare(loaded.files) }.value
            var branches: [String: String] = [:]
            if loaded.isGit {
                for root in Set(loaded.files.map(\.root)).union([target.directory]) where !root.isEmpty {
                    if let branch = await service.branch(root) { branches[root] = branch }
                }
            }
            guard generation == loadGeneration else { return }
            result = loaded
            parsed = prepared.parsed
            lineCounts = prepared.lineCounts
            self.branches = branches
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Parses each diff once and counts the lines of the files on disk (for the region after the last hunk).
    nonisolated private static func prepare(_ files: [ReviewFileDiff]) -> (parsed: [String: ParsedDiff], lineCounts: [String: Int]) {
        var parsed: [String: ParsedDiff] = [:]
        var counts: [String: Int] = [:]
        for file in files {
            parsed[file.id] = ParsedDiff(file.patch)
            guard file.fromGit, !file.isBinary, file.kind != .deleted, let lines = readLines(file.absolutePath) else { continue }
            counts[file.id] = lines.count
        }
        return (parsed, counts)
    }

    /// A text file's lines, or nil for missing, large or non-text files.
    nonisolated static func readLines(_ path: String) -> [String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size <= 2_000_000,
              let data = FileManager.default.contents(atPath: path), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: Staging

    func toggleStage(_ file: ReviewFileDiff) async {
        if file.stage == .staged {
            await run(file) { try await $0.unstage(file) }
        } else {
            await run(file) { try await $0.stage(file) }
        }
    }

    func stageAll() async {
        await runAll { service in
            for (root, files) in Dictionary(grouping: self.uncommittedFiles, by: \.root) {
                try await service.stage(paths: files.flatMap(\.gitPaths), root: root)
            }
        }
    }

    func unstageAll() async {
        await runAll { service in
            for (root, files) in Dictionary(grouping: self.stagedFiles, by: \.root) {
                try await service.unstage(paths: files.flatMap(\.gitPaths), root: root)
            }
        }
    }

    func applyHunk(_ action: ReviewHunkAction, in file: ReviewFileDiff) async {
        await run(file) { try await $0.apply(action, root: file.root) }
    }

    func confirmDiscard(_ file: ReviewFileDiff) {
        discardCandidate = file
    }

    func discard(_ file: ReviewFileDiff) async {
        discardCandidate = nil
        await run(file) { try await $0.discard(file) }
    }

    private func run(_ file: ReviewFileDiff, _ work: (GitReviewService) async throws -> Void) async {
        guard !busyFiles.contains(file.id) else { return }
        busyFiles.insert(file.id)
        defer { busyFiles.remove(file.id) }
        do {
            try await work(service)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    private func runAll(_ work: (GitReviewService) async throws -> Void) async {
        let ids = Set(files.map(\.id))
        busyFiles.formUnion(ids)
        defer { busyFiles.subtract(ids) }
        do {
            try await work(service)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    // MARK: Commit

    /// Commits what is staged on each folder's own branch. With nothing staged, stages every change shown
    /// here first.
    func commit() async {
        guard canCommit else { return }
        isCommitting = true
        defer { isCommitting = false }
        let message = commitMessage
        do {
            if stagedFiles.isEmpty {
                for (root, files) in Dictionary(grouping: uncommittedFiles, by: \.root) {
                    try await service.stage(paths: files.flatMap(\.gitPaths), root: root)
                }
            }
            var made: [String] = []
            for root in Set(files.map(\.root)) where !root.isEmpty {
                guard await service.hasStagedChanges(root) else { continue }
                made.append(try await service.commit(message: message, root: root))
            }
            lastCommit = made.isEmpty ? nil : made.joined(separator: ", ")
            if !made.isEmpty { commitMessage = "" }
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    /// Asks the agent for a one-line message about what will be committed, and puts it in the message box.
    func writeMessage() async {
        guard !isWritingMessage else { return }
        let described = stagedFiles.isEmpty ? uncommittedFiles : stagedFiles
        guard !described.isEmpty else { return }
        isWritingMessage = true
        defer { isWritingMessage = false }
        do {
            commitMessage = try await environment.draftMessage(described, focusedAgentID)
            actionError = nil
        } catch {
            actionError = "Could not write a message: \(error.localizedDescription)"
        }
    }

    // MARK: Comments

    func beginComment(file: ReviewFileDiff, line: DiffLine) {
        guard line.kind != .hunk else { return }
        let side: ReviewComment.Side = line.kind == .deletion ? .old : .new
        guard let number = side == .old ? line.oldNumber : line.newNumber else { return }
        draft = ReviewCommentDraft(key: ReviewLineKey(fileID: file.id, side: side, line: number), path: file.path,
                                   quoted: line.text, agentID: file.agentID, text: "", editing: nil)
    }

    func edit(_ comment: ReviewComment) {
        draft = ReviewCommentDraft(key: comment.lineKey, path: comment.path, quoted: comment.quoted, agentID: comment.agentID,
                                   text: comment.text, editing: comment.id)
    }

    func saveDraft() {
        guard let draft else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.draft = nil
            return
        }
        if let id = draft.editing, let index = comments.firstIndex(where: { $0.id == id }) {
            comments[index].text = text
        } else {
            comments.append(ReviewComment(fileID: draft.key.fileID, path: draft.path, line: draft.key.line, side: draft.key.side,
                                          quoted: draft.quoted, text: text, agentID: draft.agentID))
        }
        sentNote = nil
        self.draft = nil
    }

    func cancelDraft() { draft = nil }

    func delete(_ comment: ReviewComment) {
        comments.removeAll { $0.id == comment.id }
        if draft?.editing == comment.id { draft = nil }
    }

    func clearComments() {
        comments = []
        draft = nil
    }

    /// Sends every comment as one message (in a room, one message to each agent about its own files).
    func sendComments() async {
        if draft != nil { saveDraft() }
        guard !comments.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        let pending = comments
        let messages: [(agentID: UUID?, text: String)] = target.isRoom
            ? ReviewCommentFormatter.messagesByAgent(pending)
            : [(nil, ReviewCommentFormatter.message(pending))]
        let waiting = messages.contains { environment.isAgentWorking($0.agentID) }
        for message in messages {
            await environment.send(message.text, message.agentID)
        }
        let sentIDs = Set(pending.map(\.id))
        comments.removeAll { sentIDs.contains($0.id) }
        let count = pending.count == 1 ? "1 comment" : "\(pending.count) comments"
        sentNote = waiting ? "Queued \(count) until the agent's turn ends" : "Sent \(count) to the agent"
    }
}
