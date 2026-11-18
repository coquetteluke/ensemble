import Foundation

/// The git work behind session copies, with the hardened `GitRunner` (no hooks, filters, helpers or pagers a
/// repository could plant run, so a checkout of an untrusted branch starts nothing).
public struct SessionWorktreeGit: Sendable {
    public var trust: WorkspaceTrust
    #if os(macOS)
    public var runner: GitRunner

    public init(trust: WorkspaceTrust = .shared, runner: GitRunner = GitRunner()) {
        self.trust = trust
        self.runner = runner
    }
    #else
    public init(trust: WorkspaceTrust = .shared) {
        self.trust = trust
    }
    #endif

    #if os(macOS)

    // MARK: Checks

    /// Why `directory` cannot get a copy, or nil when it can.
    public func unavailableReason(_ directory: String) async -> String? {
        guard !directory.isEmpty else { return "Choose a folder first" }
        guard await isRepository(directory) else { return "Not a git repository" }
        guard trust.isTrusted(directory) else { return "Trust this folder to work in a copy" }
        guard await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory).succeeded else {
            return "The repository has no commits yet"
        }
        return nil
    }

    public func isRepository(_ directory: String) async -> Bool {
        let result = await runner.run(["rev-parse", "--is-inside-work-tree"], in: directory)
        return result.succeeded && result.line == "true"
    }

    /// The branch checked out in `directory`, or nil (detached HEAD, not a repository).
    public func currentBranch(_ directory: String) async -> String? {
        let result = await runner.run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory)
        return result.succeeded && !result.line.isEmpty ? result.line : nil
    }

    // MARK: Create

    /// Makes `<home>/.ensemble/worktrees/session-<id>` on a new branch `ensemble/session-<id>` from the current HEAD.
    /// Only in a trusted folder.
    public func create(home: String, id: String = SessionWorktreePaths.newID()) async throws -> SessionWorktreeRecord {
        guard SessionWorktreePaths.isValidID(id) else { throw SessionWorktreeError.git("Not a valid copy id: \(id)") }
        guard trust.isTrusted(home) else { throw SessionWorktreeError.untrusted(home) }
        guard await isRepository(home) else { throw SessionWorktreeError.notARepository(home) }
        guard await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: home).succeeded else {
            throw SessionWorktreeError.noCommits
        }
        let top = try await checked(["rev-parse", "--show-toplevel"], in: home).line
        let prefix = try await checked(["rev-parse", "--show-prefix"], in: home).line
        try await excludeEnsembleFolder(top: top)
        let path = SessionWorktreePaths.path(home: home, id: id)
        let branch = SessionWorktreePaths.branchPrefix + id
        if FileManager.default.fileExists(atPath: path) {
            throw SessionWorktreeError.git("\(Format.abbreviatedPath(path)) already exists.")
        }
        if await runner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: top).succeeded {
            throw SessionWorktreeError.git("The branch \(branch) already exists.")
        }
        let base = await currentBranch(home)
        _ = try await checked(["worktree", "add", "-b", branch, "--", path, "HEAD"], in: top)
        let trimmedPrefix = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let sessionDirectory = trimmedPrefix.isEmpty ? path : (path as NSString).appendingPathComponent(trimmedPrefix)
        return SessionWorktreeRecord(id: id, home: home, path: path, sessionDirectory: sessionDirectory, branch: branch,
                                     baseBranch: base)
    }

    // MARK: Branches

    /// Local branches, with the other checkout that has each one (if any) and the one `directory` is on.
    public func branches(_ directory: String) async throws -> [SessionBranch] {
        let current = await currentBranch(directory)
        let top = (try? await checked(["rev-parse", "--show-toplevel"], in: directory).line) ?? directory
        let output = try await checked(["for-each-ref", "--format=%(refname:short)%00%(worktreepath)", "refs/heads"], in: directory)
        return output.text.split(separator: "\n").compactMap { line -> SessionBranch? in
            let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let at = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            let elsewhere = at.flatMap { Self.samePath($0, top) ? nil : $0 }
            return SessionBranch(name: name, checkedOutAt: elsewhere, isCurrent: name == current)
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Files with uncommitted changes in `directory`'s checkout (staged, unstaged and untracked).
    public func uncommittedChanges(_ directory: String) async throws -> [String] {
        let output = try await checked(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory)
        var files: [String] = []
        var entries = output.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            files.append(String(entry.dropFirst(3)))
            // A rename or copy is followed by its old path.
            if status.contains("R") || status.contains("C") { _ = entries.popFirst() }
        }
        return files
    }

    /// Checks out another existing local branch in a session's copy. Uncommitted changes come along; git stops
    /// without changing anything when they conflict with the branch.
    public func switchBranch(_ directory: String, to branch: String) async throws {
        guard !branch.hasPrefix("-"),
              await runner.run(["check-ref-format", "--branch", branch], in: directory).succeeded,
              await runner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: directory).succeeded else {
            throw SessionWorktreeError.unknownBranch(branch)
        }
        let list = try await branches(directory)
        if let match = list.first(where: { $0.name == branch }), let elsewhere = match.checkedOutAt {
            throw SessionWorktreeError.branchInUse(branch, at: elsewhere)
        }
        _ = try await checked(["switch", "--no-guess", branch], in: directory)
    }

    // MARK: Remove

    /// Removes a copy Ensemble made. Without `force` it refuses a copy with uncommitted changes. Its branch is
    /// deleted only when fully merged (`git branch -d`), so commits made in the copy are never lost.
    public func remove(_ record: SessionWorktreeRecord, force: Bool) async throws {
        let isCopy = record.room == nil ? Self.isCopyPath(record.path, home: record.home, id: record.id)
            : Self.isRoomCopyPath(record.path, home: record.home)
        guard isCopy else { throw SessionWorktreeError.notACopy(record.path) }
        let exists = FileManager.default.fileExists(atPath: record.path)
        if exists, !force {
            let changes = (try? await uncommittedChanges(record.path)) ?? []
            if !changes.isEmpty { throw SessionWorktreeError.uncommittedChanges(changes) }
        }
        let gitFolder = FileManager.default.fileExists(atPath: record.home) ? record.home : nil
        if exists {
            guard let gitFolder else { throw SessionWorktreeError.git("The project folder is gone.") }
            var args = ["worktree", "remove"]
            if force { args.append("--force") }
            args += ["--", record.path]
            _ = try await checked(args, in: gitFolder)
        }
        if let gitFolder {
            _ = await runner.run(["worktree", "prune"], in: gitFolder)
            _ = await runner.run(["branch", "-d", "--", record.branch], in: gitFolder)
        }
    }

    // MARK: Size

    /// Disk space the copy takes (allocated size of its files, its `.git` link file included).
    public static func size(of path: String) -> Int64? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Helpers

    /// True when `path` is exactly `<home>/.ensemble/worktrees/session-<id>` with a valid id.
    static func isCopyPath(_ path: String, home: String, id: String) -> Bool {
        SessionWorktreePaths.isValidID(id) && path == SessionWorktreePaths.path(home: home, id: id)
    }

    /// True when `path` is `<home>/.ensemble/worktrees/<name>` with a plain name (where Team rooms put their copies).
    /// Git itself refuses to remove a folder that is not one of its worktrees.
    static func isRoomCopyPath(_ path: String, home: String) -> Bool {
        // Rooms save git's spelling of the folder (`/private/var/...` for `/var/...`), so both are resolved first.
        let path = WorkspaceTrust.resolvedPath(path) ?? path
        let home = WorkspaceTrust.resolvedPath(home) ?? home
        let prefix = (home as NSString).appendingPathComponent(PermissionRules.worktreeFolder) + "/"
        guard path.hasPrefix(prefix) else { return false }
        return PermissionRules.isWorktreeFolder(PermissionRules.worktreeFolder + "/" + String(path.dropFirst(prefix.count)))
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        let left = WorkspaceTrust.resolvedPath(a) ?? a
        let right = WorkspaceTrust.resolvedPath(b) ?? b
        return left == right
    }

    /// `.ensemble/` in the repository's `info/exclude`, so copies never show in git status (as Team rooms do).
    private func excludeEnsembleFolder(top: String) async throws {
        var common = try await checked(["rev-parse", "--git-common-dir"], in: top).line
        if !common.hasPrefix("/") { common = (top as NSString).appendingPathComponent(common) }
        let info = (common as NSString).appendingPathComponent("info")
        let exclude = (info as NSString).appendingPathComponent("exclude")
        try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        if current.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".ensemble/" }) { return }
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".ensemble/\n"
        try (current + line).write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func checked(_ args: [String], in directory: String) async throws -> GitOutput {
        let result = await runner.run(args, in: directory)
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SessionWorktreeError.git(detail.isEmpty ? "git \(args.first ?? "") failed (\(result.status))" : detail)
        }
        return result
    }

    #else

    public func unavailableReason(_ directory: String) async -> String? { "Copies are made on the Mac" }
    public func currentBranch(_ directory: String) async -> String? { nil }
    public func create(home: String, id: String = SessionWorktreePaths.newID()) async throws -> SessionWorktreeRecord {
        throw SessionWorktreeError.git("Copies are made on the Mac")
    }

    #endif
}
