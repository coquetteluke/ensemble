import Foundation

public struct GitMergeResult: Hashable, Sendable {
    public var merged: Bool
    /// Files with conflicts, when the merge stopped on conflicts.
    public var conflicts: [String]
    /// Git's own output, for the board when something else went wrong.
    public var message: String

    public init(merged: Bool, conflicts: [String] = [], message: String = "") {
        self.merged = merged
        self.conflicts = conflicts
        self.message = message
    }
}

/// Verification result after a merge conflict is reported as resolved.
public struct GitConflictStatus: Hashable, Sendable {
    /// Files still in an unmerged conflict state.
    public var conflicts: [String]
    /// True when git still has a merge in progress (`MERGE_HEAD` exists).
    public var mergeInProgress: Bool
    /// True when the branch tip is now an ancestor of the base branch.
    public var branchMerged: Bool

    public var isResolved: Bool {
        conflicts.isEmpty && !mergeInProgress && branchMerged
    }

    public init(conflicts: [String] = [], mergeInProgress: Bool = false, branchMerged: Bool = true) {
        self.conflicts = conflicts
        self.mergeInProgress = mergeInProgress
        self.branchMerged = branchMerged
    }
}

public struct GitError: Error, LocalizedError, Hashable, Sendable {
    public var command: String
    public var output: String
    public var status: Int32

    public init(command: String, output: String, status: Int32) {
        self.command = command
        self.output = output
        self.status = status
    }

    public var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(command) failed (\(status))" + (detail.isEmpty ? "" : ": \(detail)")
    }
}

/// Git work for Team rooms. The Mac app uses `ProcessGitOps`; tests use a fake.
public protocol GitOps: Sendable {
    /// True when `directory` is inside a git work tree.
    func isRepository(_ directory: String) async -> Bool
    /// The branch checked out in `repo` (the room's base branch).
    func currentBranch(repo: String) async throws -> String
    /// Creates (or reuses) a worktree on `branch`, branched from the current HEAD. Returns its path.
    func createWorktree(repo: String, branch: String) async throws -> String
    /// Files changed in `worktree` since it branched from `base`, committed or not.
    func changedFiles(worktree: String, base: String) async throws -> [String]
    /// Commits everything in `worktree`. Returns false when there was nothing to commit.
    func commitAll(worktree: String, message: String) async throws -> Bool
    /// Merges `branch` into `base` in `repo`. On conflicts the merge is left in progress for someone to resolve.
    func merge(branch: String, into base: String, repo: String) async throws -> GitMergeResult
    /// Checks whether a previously conflicted merge of `branch` into `base` in `repo` has been resolved and committed.
    func conflictStatus(branch: String, into base: String, repo: String) async throws -> GitConflictStatus
}

public extension GitOps {
    func conflictStatus(branch: String, into base: String, repo: String) async throws -> GitConflictStatus {
        GitConflictStatus(conflicts: [], mergeInProgress: false, branchMerged: true)
    }
}

#if os(macOS)
/// `GitOps` with the `git` command line tool.
///
/// Worktrees go in `<room folder>/.ensemble/worktrees/<branch>`, inside the folder the agents' sessions run in (also
/// when the room's folder is below the repository's top), so they need no extra folder permission and
/// `PermissionRules.worktreeEditRules` can scope each agent's edits to its own worktree. A dot folder keeps build
/// tools, test runners and file watchers away from the copies. `.ensemble/` is added to `.git/info/exclude`.
///
/// Git runs through `GitRunner` (no hooks or other repository programs) and only in folders `isTrusted` accepts.
public struct ProcessGitOps: GitOps {
    public var gitPath: String
    /// Whether git may run in a folder. Defaults to the user's workspace trust.
    public var isTrusted: @Sendable (String) -> Bool

    public init(gitPath: String = "/usr/bin/git",
                isTrusted: @escaping @Sendable (String) -> Bool = { WorkspaceTrust.shared.isTrusted($0) }) {
        self.gitPath = gitPath
        self.isTrusted = isTrusted
    }

    public func isRepository(_ directory: String) async -> Bool {
        let r = await run(["-C", directory, "rev-parse", "--is-inside-work-tree"])
        return r.status == 0 && r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func currentBranch(repo: String) async throws -> String {
        let branch = try await checked(["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "HEAD" else {
            throw GitError(command: "rev-parse --abbrev-ref HEAD", output: "Not on a branch.", status: 1)
        }
        return branch
    }

    /// Rejects unsafe or malformed git branch names (empty, leading `-`, `..`, control characters, whitespace, or ref metacharacters).
    public static func validateBranchName(_ branch: String) throws {
        guard !branch.isEmpty,
              !branch.hasPrefix("-"),
              !branch.hasPrefix("/"),
              !branch.hasPrefix("."),
              !branch.hasSuffix("/"),
              !branch.hasSuffix("."),
              !branch.hasSuffix(".lock"),
              !branch.contains(".."),
              !branch.contains("//"),
              !branch.contains("@{"),
              !branch.contains("\\") else {
            throw GitError(command: "validate-branch", output: "Invalid branch name: \(branch)", status: 1)
        }
        for scalar in branch.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || "~^:?*[".unicodeScalars.contains(scalar) {
                throw GitError(command: "validate-branch", output: "Invalid branch name: \(branch)", status: 1)
            }
        }
    }

    public func createWorktree(repo: String, branch: String) async throws -> String {
        try Self.validateBranchName(branch)
        let top = try await checked(["-C", repo, "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await excludeEnsembleFolder(top: top)
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        guard !folder.isEmpty, !folder.hasPrefix("-"), !folder.hasPrefix("."), !folder.contains("..") else {
            throw GitError(command: "worktree add", output: "Invalid worktree folder name: \(folder)", status: 1)
        }
        // The room's folder as git spells it (the top's real path plus the folder's place in the repository).
        let prefix = try await checked(["-C", repo, "rev-parse", "--show-prefix"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let roomFolder = prefix.isEmpty ? top : (top as NSString).appendingPathComponent(prefix)
        let parent = try Self.prepareWorktreeParent(roomFolder: roomFolder)
        let path = (parent as NSString).appendingPathComponent(folder)
        if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            return path
        }
        let exists = await run(["-C", top, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0
        let args = exists
            ? ["-C", top, "worktree", "add", "--", path, branch]
            : ["-C", top, "worktree", "add", "-b", branch, "--", path, "HEAD"]
        _ = try await checked(args)
        return path
    }

    public func changedFiles(worktree: String, base: String) async throws -> [String] {
        try Self.validateBranchName(base)
        var files = Set<String>()
        let committed = await run(["-C", worktree, "diff", "--name-only", "\(base)...HEAD", "--"])
        if committed.status == 0 {
            for line in committed.output.split(separator: "\n") where !line.isEmpty { files.insert(String(line)) }
        }
        let status = try await checked(["-C", worktree, "status", "--porcelain", "--untracked-files=all"])
        for line in status.split(separator: "\n") where line.count > 3 {
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            files.insert(path)
        }
        return files.sorted()
    }

    public func commitAll(worktree: String, message: String) async throws -> Bool {
        _ = try await checked(["-C", worktree, "add", "-A", "--"])
        if await run(["-C", worktree, "diff", "--cached", "--quiet", "--"]).status == 0 { return false }
        let identity = await identityArgs(worktree)
        _ = try await checked(["-C", worktree] + identity + ["commit", "-m", message])
        return true
    }

    public func merge(branch: String, into base: String, repo: String) async throws -> GitMergeResult {
        try Self.validateBranchName(branch)
        try Self.validateBranchName(base)
        let current = try await checked(["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if current != base {
            _ = try await checked(["-C", repo, "checkout", base])
        }
        let identity = await identityArgs(repo)
        let r = await run(["-C", repo] + identity + ["merge", "--no-ff", "--no-edit", "-m", "Merge \(branch)", branch])
        if r.status == 0 { return GitMergeResult(merged: true, message: r.output) }
        let unmerged = await run(["-C", repo, "diff", "--name-only", "--diff-filter=U", "--"])
        let conflicts = unmerged.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if conflicts.isEmpty {
            _ = await run(["-C", repo, "merge", "--abort"])
        }
        return GitMergeResult(merged: false, conflicts: conflicts, message: r.output)
    }

    public func conflictStatus(branch: String, into base: String, repo: String) async throws -> GitConflictStatus {
        try Self.validateBranchName(branch)
        try Self.validateBranchName(base)
        let unmerged = await run(["-C", repo, "diff", "--name-only", "--diff-filter=U", "--"])
        let conflicts = unmerged.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let mergeHead = await run(["-C", repo, "rev-parse", "--verify", "--quiet", "MERGE_HEAD"])
        let mergeInProgress = mergeHead.status == 0
        let ancestor = await run(["-C", repo, "merge-base", "--is-ancestor", branch, base])
        let branchMerged = ancestor.status == 0
        return GitConflictStatus(conflicts: conflicts, mergeInProgress: mergeInProgress, branchMerged: branchMerged)
    }

    // MARK: Helpers

    /// `-c user.name=... -c user.email=...` when the repo has no identity, so commits still work.
    private func identityArgs(_ dir: String) async -> [String] {
        let email = await run(["-C", dir, "config", "user.email"])
        if email.status == 0, !email.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return ["-c", "user.name=Ensemble", "-c", "user.email=ensemble@localhost"]
    }

    private func excludeEnsembleFolder(top: String) async throws {
        var common = try await checked(["-C", top, "rev-parse", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !common.hasPrefix("/") { common = (top as NSString).appendingPathComponent(common) }
        let info = (common as NSString).appendingPathComponent("info")
        let exclude = (info as NSString).appendingPathComponent("exclude")
        try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        if current.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".ensemble/" }) { return }
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".ensemble/\n"
        try (current + line).write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    private func checked(_ args: [String]) async throws -> String {
        let r = await run(args)
        guard r.status == 0 else {
            let command = args.drop { $0 == "-C" || $0.hasPrefix("/") }.joined(separator: " ")
            throw GitError(command: command, output: r.output, status: r.status)
        }
        return r.output
    }

    /// Runs `git -C <dir> <rest>` through `GitRunner`, so the repository's hooks, file system monitor, filters and
    /// other programs never start. Every call passes `-C <dir>` first; a folder that is not trusted runs no git.
    private func run(_ args: [String]) async -> (status: Int32, output: String) {
        guard args.count >= 2, args[0] == "-C" else {
            return (128, "Ensemble runs git only inside a named folder.")
        }
        let directory = args[1]
        guard isTrusted(directory) else {
            return (128, "Ensemble runs no git in a folder you have not trusted.")
        }
        let result = await GitRunner(gitPath: gitPath).run(Array(args.dropFirst(2)), in: directory)
        // Successful runs are parsed, so only their standard output counts; failures show both streams.
        let output = result.succeeded ? result.text : result.text + result.stderr
        return (result.status, output)
    }

    /// Refuses a worktree folder reached through a symbolic link, so a repository that commits `.ensemble` as a link
    /// cannot make `git worktree add` write its files somewhere else on disk.
    static func prepareWorktreeParent(roomFolder: String) throws -> String {
        let fm = FileManager.default
        var current = roomFolder
        for part in PermissionRules.worktreeFolder.split(separator: "/").map(String.init) {
            current = (current as NSString).appendingPathComponent(part)
            if let type = try? fm.attributesOfItem(atPath: current)[.type] as? FileAttributeType {
                guard type == .typeDirectory else {
                    throw GitError(command: "worktree add", output: "\(current) is not a plain folder.", status: 1)
                }
            } else {
                try fm.createDirectory(atPath: current, withIntermediateDirectories: false)
            }
        }
        guard let realRoom = WorkspaceTrust.resolvedPath(roomFolder), let realParent = WorkspaceTrust.resolvedPath(current),
              realParent.hasPrefix(realRoom.hasSuffix("/") ? realRoom : realRoom + "/") else {
            throw GitError(command: "worktree add", output: "The worktree folder is outside the room's folder.", status: 1)
        }
        return current
    }
}
#endif
