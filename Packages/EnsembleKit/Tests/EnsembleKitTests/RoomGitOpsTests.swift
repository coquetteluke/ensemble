#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// `ProcessGitOps` against a real temporary repository.
@Suite struct RoomGitOpsTests {
    @discardableResult
    func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 { throw GitError(command: args.joined(separator: " "), output: out, status: p.terminationStatus) }
        return out
    }

    func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["config", "user.email", "test@example.com"], in: dir)
        try git(["config", "user.name", "Test"], in: dir)
        try "base\n".write(to: dir.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "base"], in: dir)
        return dir
    }

    @Test func worktreeCommitAndMerge() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let ops = ProcessGitOps.trustingEverything
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        #expect(await ops.isRepository(repo.path))
        #expect(await ops.isRepository(plain.path) == false)
        #expect(try await ops.currentBranch(repo: repo.path) == "main")

        let path = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/alpha")
        #expect(path.hasSuffix(".ensemble/worktrees/ensemble-room-alpha"))
        #expect(FileManager.default.fileExists(atPath: path + "/shared.txt"))
        // Asking again reuses it.
        #expect(try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/alpha") == path)
        // The worktrees folder is ignored in the main checkout.
        let exclude = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".ensemble/"))
        #expect(try git(["status", "--porcelain"], in: repo).isEmpty)

        try "new\n".write(toFile: path + "/alpha.txt", atomically: true, encoding: .utf8)
        try "changed\n".write(toFile: path + "/shared.txt", atomically: true, encoding: .utf8)
        #expect(try await ops.changedFiles(worktree: path, base: "main") == ["alpha.txt", "shared.txt"])
        #expect(try await ops.commitAll(worktree: path, message: "Alpha: piece"))
        #expect(try await ops.commitAll(worktree: path, message: "nothing") == false)
        #expect(try await ops.changedFiles(worktree: path, base: "main") == ["alpha.txt", "shared.txt"])

        let result = try await ops.merge(branch: "ensemble/room/alpha", into: "main", repo: repo.path)
        #expect(result.merged)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("alpha.txt").path))
        #expect(try String(contentsOf: repo.appendingPathComponent("shared.txt"), encoding: .utf8) == "changed\n")
    }

    /// A room in a folder below the repository's top keeps its worktrees inside that folder, so they are inside the
    /// folder the agents' sessions run in, and the worktree folder is a room worktree folder relative to it.
    @Test func worktreesLiveInTheRoomFolder() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sub = repo.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "app\n".write(to: sub.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "app"], in: repo)
        let ops = ProcessGitOps.trustingEverything

        let top = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/top")
        #expect(RoomWorktreePaths.relative(top, inside: repo.path) == ".ensemble/worktrees/ensemble-room-top")
        let path = try await ops.createWorktree(repo: sub.path, branch: "ensemble/room/alpha")
        #expect(RoomWorktreePaths.relative(path, inside: sub.path) == ".ensemble/worktrees/ensemble-room-alpha")
        #expect(FileManager.default.fileExists(atPath: path + "/app/main.txt"))
        #expect(try git(["status", "--porcelain"], in: repo).isEmpty)
    }

    @Test func conflictingMergeReportsFiles() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let ops = ProcessGitOps.trustingEverything
        let a = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/a")
        let b = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/b")
        try "from a\n".write(toFile: a + "/shared.txt", atomically: true, encoding: .utf8)
        try "from b\n".write(toFile: b + "/shared.txt", atomically: true, encoding: .utf8)
        _ = try await ops.commitAll(worktree: a, message: "a")
        _ = try await ops.commitAll(worktree: b, message: "b")

        #expect(try await ops.merge(branch: "ensemble/room/a", into: "main", repo: repo.path).merged)
        let second = try await ops.merge(branch: "ensemble/room/b", into: "main", repo: repo.path)
        #expect(second.merged == false)
        #expect(second.conflicts == ["shared.txt"])
    }
}
#endif
