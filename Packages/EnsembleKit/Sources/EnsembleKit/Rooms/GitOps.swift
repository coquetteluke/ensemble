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
}

#if os(macOS)
/// `GitOps` with the `git` command line tool.
///
/// Worktrees go in `<repo>/.ensemble/worktrees/<branch>` so agents whose sessions run in the project folder
/// can reach them without extra folder permissions; `.ensemble/` is added to `.git/info/exclude`.
public struct ProcessGitOps: GitOps {
    public var gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
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

    public func createWorktree(repo: String, branch: String) async throws -> String {
        let top = try await checked(["-C", repo, "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await excludeEnsembleFolder(top: top)
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        let path = (top as NSString).appendingPathComponent(".ensemble/worktrees/\(folder)")
        if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            return path
        }
        let exists = await run(["-C", top, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0
        let args = exists
            ? ["-C", top, "worktree", "add", path, branch]
            : ["-C", top, "worktree", "add", "-b", branch, path, "HEAD"]
        _ = try await checked(args)
        return path
    }

    public func changedFiles(worktree: String, base: String) async throws -> [String] {
        var files = Set<String>()
        let committed = await run(["-C", worktree, "diff", "--name-only", "\(base)...HEAD"])
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
        _ = try await checked(["-C", worktree, "add", "-A"])
        if await run(["-C", worktree, "diff", "--cached", "--quiet"]).status == 0 { return false }
        let identity = await identityArgs(worktree)
        _ = try await checked(["-C", worktree] + identity + ["commit", "-m", message])
        return true
    }

    public func merge(branch: String, into base: String, repo: String) async throws -> GitMergeResult {
        let current = try await checked(["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if current != base {
            _ = try await checked(["-C", repo, "checkout", base])
        }
        let identity = await identityArgs(repo)
        let r = await run(["-C", repo] + identity + ["merge", "--no-ff", "--no-edit", "-m", "Merge \(branch)", branch])
        if r.status == 0 { return GitMergeResult(merged: true, message: r.output) }
        let unmerged = await run(["-C", repo, "diff", "--name-only", "--diff-filter=U"])
        let conflicts = unmerged.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if conflicts.isEmpty {
            _ = await run(["-C", repo, "merge", "--abort"])
        }
        return GitMergeResult(merged: false, conflicts: conflicts, message: r.output)
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

    private func run(_ args: [String]) async -> (status: Int32, output: String) {
        let path = gitPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
#endif
