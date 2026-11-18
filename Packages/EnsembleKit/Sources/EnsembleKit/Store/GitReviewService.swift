import Foundation

#if os(macOS)
/// The git work behind the review pane: diffs between snapshots, stage and unstage (whole files or single
/// hunks), discard and commit. Every command runs through `GitRunner` with explicit arguments in the folder it
/// is given. It never pushes, never forces anything, never switches or edits branches, and never touches
/// the real index except through `stage`, `unstage`, `discard` and `commit`.
public struct GitReviewService: Sendable {
    public var runner: GitRunner
    /// Removes a new file on Discard. The app moves it to the Trash; tests delete it.
    public var removeFile: @Sendable (URL) throws -> Void

    public init(runner: GitRunner = GitRunner(), removeFile: @escaping @Sendable (URL) throws -> Void = GitReviewService.moveToTrash) {
        self.runner = runner
        self.removeFile = removeFile
    }

    public static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Diff flags used everywhere: no external diff programs or text conversion, fixed prefixes and context,
    /// paths relative to the repository top.
    static let diffFlags = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-relative", "-U3", "--src-prefix=a/", "--dst-prefix=b/"]

    // MARK: Repository facts

    /// The repository's top folder, or nil when `directory` is not inside a git work tree.
    public func topLevel(_ directory: String) async -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let r = await runner.run(["rev-parse", "--show-toplevel"], in: directory)
        guard r.succeeded, !r.line.isEmpty else { return nil }
        return r.line
    }

    /// The commit checked out, or nil before the first commit.
    public func head(_ root: String) async -> String? {
        let r = await runner.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)
        return r.succeeded && !r.line.isEmpty ? r.line : nil
    }

    /// The newest commit on HEAD made before `date`, or nil when there is none.
    public func head(_ root: String, before date: Date) async -> String? {
        let r = await runner.run(["rev-list", "-1", "--before=\(Int(date.timeIntervalSince1970))", "HEAD", "--"], in: root)
        return r.succeeded && !r.line.isEmpty ? r.line : nil
    }

    /// The commit where HEAD branched from `base`, or nil.
    public func mergeBase(_ root: String, base: String) async -> String? {
        let r = await runner.run(["merge-base", base, "HEAD"], in: root)
        return r.succeeded && !r.line.isEmpty ? r.line : nil
    }

    /// The empty tree's id in this repository's hash format.
    public func emptyTree(_ root: String) async -> String {
        let r = await runner.run(["hash-object", "-t", "tree", "/dev/null"], in: root)
        return r.succeeded && !r.line.isEmpty ? r.line : "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    }

    /// True when `object` (a tree or commit id) is still in the repository.
    public func exists(_ object: String, in root: String) async -> Bool {
        await runner.run(["cat-file", "-e", object], in: root).succeeded
    }

    /// The folder's current content as a tree: tracked and new files, without ignored ones. Written with a
    /// temporary copy of the index, so the real index and the work tree are left exactly as they were.
    public func snapshotTree(_ root: String) async throws -> String {
        let indexPath = await runner.run(["rev-parse", "--git-path", "index"], in: root).line
        let realIndex = indexPath.hasPrefix("/") ? indexPath : (root as NSString).appendingPathComponent(indexPath)
        let temp = (NSTemporaryDirectory() as NSString).appendingPathComponent("ensemble-review-\(UUID().uuidString).index")
        defer {
            try? FileManager.default.removeItem(atPath: temp)
            try? FileManager.default.removeItem(atPath: temp + ".lock")
        }
        if FileManager.default.fileExists(atPath: realIndex) {
            try? FileManager.default.copyItem(atPath: realIndex, toPath: temp)
        }
        let env = ["GIT_INDEX_FILE": temp]
        let add = await runner.run(["add", "-A", "--", "."], in: root, environment: env)
        guard add.succeeded else { throw GitError(command: "add -A (snapshot)", output: add.stderr, status: add.status) }
        let tree = await runner.run(["write-tree"], in: root, environment: env)
        guard tree.succeeded, !tree.line.isEmpty else { throw GitError(command: "write-tree", output: tree.stderr, status: tree.status) }
        return tree.line
    }

    // MARK: Diffs

    /// Files that differ between two trees or commits, with their diffs, renames detected.
    public func diff(from base: String, to target: String, root: String) async throws -> [ReviewFileDiff] {
        let numstat = await runner.run(["diff"] + Self.diffFlags + ["-M", "--numstat", "-z", base, target, "--"], in: root)
        guard numstat.succeeded else { throw GitError(command: "diff --numstat", output: numstat.stderr, status: numstat.status) }
        let patch = await runner.run(["diff"] + Self.diffFlags + ["-M", base, target, "--"], in: root)
        guard patch.succeeded else { throw GitError(command: "diff", output: patch.stderr, status: patch.status) }
        let pairs = GitDiffParsing.pair(GitDiffParsing.numstat(numstat.stdout), GitDiffParsing.fileChunks(patch.text))
        return pairs.map { entry, chunk in
            ReviewFileDiff(root: root, path: entry.path, oldPath: entry.oldPath,
                           kind: entry.oldPath != nil ? .renamed : GitDiffParsing.changeKind(chunk),
                           additions: entry.additions, deletions: entry.deletions, isBinary: entry.isBinary,
                           patch: entry.isBinary ? "" : chunk, stage: .committed)
        }
    }

    /// Path -> state for every path with uncommitted changes.
    public func stageStates(_ root: String) async -> [String: GitDiffParsing.StatusEntry] {
        let r = await runner.run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"], in: root)
        return r.succeeded ? GitDiffParsing.status(r.stdout) : [:]
    }

    /// Per-file patches of the index against the work tree (`staged: false`) or of HEAD against the index.
    func indexPatches(_ root: String, staged: Bool) async -> [String: String] {
        let args = ["diff"] + Self.diffFlags + (staged ? ["--cached"] : []) + ["--no-renames"]
        let numstat = await runner.run(args + ["--numstat", "-z", "--"], in: root)
        let patch = await runner.run(args + ["--"], in: root)
        guard numstat.succeeded, patch.succeeded else { return [:] }
        var result: [String: String] = [:]
        for (entry, chunk) in GitDiffParsing.pair(GitDiffParsing.numstat(numstat.stdout), GitDiffParsing.fileChunks(patch.text)) where !chunk.isEmpty {
            result[entry.path] = chunk
        }
        return result
    }

    /// Fills in each file's stage state and the hunks that can be staged or unstaged alone.
    public func attachStageInfo(_ files: [ReviewFileDiff], root: String) async -> [ReviewFileDiff] {
        let states = await stageStates(root)
        let unstaged = await indexPatches(root, staged: false)
        let staged = await indexPatches(root, staged: true)
        return files.map { file in
            var file = file
            file.stage = Self.combinedState(file.gitPaths.compactMap { states[$0]?.state })
            if file.fromGit, !file.isBinary, file.kind == .modified {
                file.hunkActions = GitDiffParsing.hunkActions(session: file.patch, unstaged: unstaged[file.path], staged: staged[file.path])
            } else {
                file.hunkActions = [:]
            }
            return file
        }
    }

    /// One state for a file whose paths (both sides of a rename) may stand differently.
    static func combinedState(_ states: [ReviewStageState]) -> ReviewStageState {
        if states.isEmpty { return .committed }
        if states.contains(.conflicted) { return .conflicted }
        let set = Set(states)
        if set.count == 1, let only = set.first { return only }
        if set.isSubset(of: [.staged, .committed]) { return .staged }
        if set.contains(.staged) || set.contains(.partial) { return .partial }
        if set.contains(.untracked) { return set == [.untracked] ? .untracked : .unstaged }
        return .unstaged
    }

    /// Everything the folder changed since `base` (a tree or commit): a snapshot of the folder now, diffed
    /// against `base`, with stage states.
    public func review(root: String, since base: String) async throws -> [ReviewFileDiff] {
        let now = try await snapshotTree(root)
        let files = try await diff(from: base, to: now, root: root)
        return await attachStageInfo(files, root: root)
    }

    // MARK: Changing the index and the work tree

    /// Stages every change to the file (new, changed, deleted or renamed).
    public func stage(_ file: ReviewFileDiff) async throws {
        try await stage(paths: file.gitPaths, root: file.root)
    }

    public func stage(paths: [String], root: String) async throws {
        let states = await stageStates(root)
        let present = paths.filter { states[$0] != nil }
        guard !present.isEmpty else { return }
        try await checked(["add", "-A", "--"] + present, in: root, label: "add")
    }

    /// Takes the file out of the index again, leaving the work tree as it is.
    public func unstage(_ file: ReviewFileDiff) async throws {
        try await unstage(paths: file.gitPaths, root: file.root)
    }

    public func unstage(paths: [String], root: String) async throws {
        let states = await stageStates(root)
        let staged = paths.filter { states[$0].map { $0.index != "." } ?? false }
        guard !staged.isEmpty else { return }
        if await head(root) != nil {
            try await checked(["restore", "--staged", "--"] + staged, in: root, label: "restore --staged")
        } else {
            try await checked(["rm", "--cached", "-q", "--"] + staged, in: root, label: "rm --cached")
        }
    }

    /// Applies one hunk to the index (stage) or takes it out (unstage).
    public func apply(_ action: ReviewHunkAction, root: String) async throws {
        let temp = (NSTemporaryDirectory() as NSString).appendingPathComponent("ensemble-hunk-\(UUID().uuidString).patch")
        try action.patch.write(toFile: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: temp) }
        var args = ["apply", "--cached", "--whitespace=nowarn", "--recount"]
        if action.kind == .unstage { args.append("--reverse") }
        try await checked(args + [temp], in: root, label: "apply --cached")
    }

    /// Puts the file back to the last commit, staged and unstaged changes alike. A file the last commit does
    /// not have is taken out of the index and removed with `removeFile` (the Trash in the app).
    public func discard(_ file: ReviewFileDiff) async throws {
        let root = file.root
        let hasHead = await head(root) != nil
        let states = await stageStates(root)
        for path in file.gitPaths {
            guard let state = states[path] else { continue }
            if state.conflicted { throw GitError(command: "discard", output: "\(path) has a merge conflict.", status: 1) }
            let inHead = hasHead ? await runner.run(["cat-file", "-e", "HEAD:\(path)"], in: root).succeeded : false
            if inHead {
                try await checked(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + [path], in: root, label: "restore")
            } else {
                if !state.untracked {
                    try await checked(["rm", "--cached", "-q", "--"] + [path], in: root, label: "rm --cached")
                }
                let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(path))
                if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
            }
        }
    }

    /// True when something is staged.
    public func hasStagedChanges(_ root: String) async -> Bool {
        let r = await runner.run(["diff", "--cached", "--quiet", "--no-ext-diff"], in: root)
        return r.status == 1
    }

    /// The branch checked out, or nil when HEAD is detached.
    public func branch(_ root: String) async -> String? {
        let r = await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        return r.succeeded && !r.line.isEmpty ? r.line : nil
    }

    /// Commits what is staged on the branch checked out, with the repository's own identity and hooks.
    /// Returns the new commit's short id.
    @discardableResult
    public func commit(message: String, root: String) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError(command: "commit", output: "The commit message is empty.", status: 1) }
        guard await hasStagedChanges(root) else { throw GitError(command: "commit", output: "Nothing is staged.", status: 1) }
        try await checked(["commit", "--quiet", "-m", trimmed], in: root, label: "commit")
        return await runner.run(["rev-parse", "--short", "HEAD"], in: root).line
    }

    @discardableResult
    private func checked(_ args: [String], in root: String, label: String) async throws -> GitOutput {
        let r = await runner.run(args, in: root)
        guard r.succeeded else {
            let detail = r.stderr.isEmpty ? r.text : r.stderr
            throw GitError(command: label, output: detail, status: r.status)
        }
        return r
    }
}
#endif
