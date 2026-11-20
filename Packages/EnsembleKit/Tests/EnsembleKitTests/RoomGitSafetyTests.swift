#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

extension ProcessGitOps {
    /// Git for tests in temporary folders, which the user's workspace trust never lists.
    static var trustingEverything: ProcessGitOps { ProcessGitOps(isTrusted: { _ in true }) }
}

/// Rooms run git like the rest of Ensemble: never the repository's own programs, never in an untrusted folder, and
/// never through a linked `.ensemble` folder.
@Suite struct RoomGitSafetyTests {
    let helper = RoomGitOpsTests()

    @Test func roomGitRunsNoRepositoryHooks() async throws {
        let repo = try helper.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for name in ["post-checkout", "pre-commit", "post-commit", "post-merge"] {
            let hook = hooks.appendingPathComponent(name)
            try "#!/bin/sh\necho \(name) >> '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }

        let ops = ProcessGitOps.trustingEverything
        let path = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/alpha")
        try "new\n".write(toFile: path + "/alpha.txt", atomically: true, encoding: .utf8)
        #expect(try await ops.commitAll(worktree: path, message: "Alpha"))
        let merged = try await ops.merge(branch: "ensemble/room/alpha", into: "main", repo: repo.path)
        #expect(merged.merged)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func anUntrustedFolderRunsNoGit() async throws {
        let repo = try helper.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let ops = ProcessGitOps(isTrusted: { _ in false })
        #expect(await ops.isRepository(repo.path) == false)
        await #expect(throws: GitError.self) {
            _ = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/alpha")
        }
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".ensemble").path))
    }

    @Test func aLinkedEnsembleFolderIsRefused() async throws {
        let repo = try helper.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent(".ensemble"), withDestinationURL: elsewhere)

        let ops = ProcessGitOps.trustingEverything
        await #expect(throws: GitError.self) {
            _ = try await ops.createWorktree(repo: repo.path, branch: "ensemble/room/alpha")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: elsewhere.appendingPathComponent("worktrees").path)
        #expect(written.isEmpty)
    }
}
#endif
