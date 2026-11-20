#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// `GitReviewService`, `GitTurnSnapshots` and `GitReviewLoader` against real throwaway repositories.
/// Each test makes its own repository in the temporary folder; nothing outside it is touched (new files
/// that Discard removes are deleted, not sent to the Trash).
@Suite struct GitReviewServiceTests {
    /// A trust list of the tests' own (never the app's); `makeRepo` trusts each repository it makes.
    let trust: WorkspaceTrust
    let service: GitReviewService

    init() {
        let parent = ProcessInfo.processInfo.environment["ENSEMBLE_GIT_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        trust = WorkspaceTrust(fileURL: parent.appendingPathComponent("ensemble-trust-\(UUID().uuidString).json"))
        service = GitReviewService(removeFile: { url in try FileManager.default.removeItem(at: url) }, trust: trust)
    }

    // MARK: Helpers

    @discardableResult
    func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_LITERAL_PATHSPECS"] = "1"
        p.environment = env
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

    /// A new empty folder in the temporary folder (or in `ENSEMBLE_GIT_TEST_DIR` when set).
    func folder(_ name: String = "ensemble-review") throws -> URL {
        let parent = ProcessInfo.processInfo.environment["ENSEMBLE_GIT_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let dir = parent.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    /// A repository with its own identity, no signing and no hooks (so a global setup cannot interfere).
    func makeRepo(files: [String: String] = ["README.md": "hello\n"]) throws -> URL {
        let dir = try folder()
        let hooks = dir.appendingPathComponent(".no-hooks")
        try git(["init", "-q", "-b", "main"], in: dir)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try git(["config", "user.email", "test@example.com"], in: dir)
        try git(["config", "user.name", "Test"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
        try git(["config", "core.hooksPath", hooks.path], in: dir)
        try "/.no-hooks/\n".write(to: dir.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        for (path, content) in files { try write(content, path, in: dir) }
        if !files.isEmpty {
            try git(["add", "-A"], in: dir)
            try git(["commit", "-q", "-m", "base"], in: dir)
        }
        try trust.trust(dir.path)
        return dir
    }

    func write(_ content: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    func numbered(_ count: Int, change: [Int: String] = [:]) -> String {
        (1...count).map { change[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    // MARK: Diffs

    @Test func snapshotDiffCoversEveryKindOfChangeAndLeavesTheIndexAlone() async throws {
        let repo = try makeRepo(files: [
            "README.md": "hello\n",
            "keep.txt": numbered(10),
            "gone.txt": "bye\n",
            "old name.txt": numbered(20),
            "a[1].txt": "bracket\n",
            "a1.txt": "plain\n",
        ])
        let root = try #require(await service.topLevel(repo.path))
        let base = try await service.snapshotTree(root)
        let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))

        try write(numbered(10, change: [3: "line three"]), "keep.txt", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("dossier é"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: repo.appendingPathComponent("old name.txt"),
                                         to: repo.appendingPathComponent("dossier é/new name.txt"))
        try write("new and unicode\n", "dossier é/naïve file.txt", in: repo)
        try write("changed\n", "a[1].txt", in: repo)
        try Data([0, 1, 2, 3, 255, 0, 7]).write(to: repo.appendingPathComponent("blob.bin"))

        let files = try await service.review(root: root, since: base)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["keep.txt"]?.kind == .modified)
        #expect(byPath["keep.txt"]?.additions == 1 && byPath["keep.txt"]?.deletions == 1)
        #expect(byPath["keep.txt"]?.stage == .unstaged)
        #expect(byPath["keep.txt"]?.patch.contains("+line three") == true)
        #expect(byPath["gone.txt"]?.kind == .deleted)
        #expect(byPath["dossier é/new name.txt"]?.kind == .renamed)
        #expect(byPath["dossier é/new name.txt"]?.oldPath == "old name.txt")
        #expect(byPath["dossier é/naïve file.txt"]?.kind == .added)
        #expect(byPath["dossier é/naïve file.txt"]?.stage == .untracked)
        #expect(byPath["a[1].txt"]?.kind == .modified)
        #expect(byPath["a1.txt"] == nil)
        #expect(byPath["blob.bin"]?.isBinary == true)
        #expect(byPath["blob.bin"]?.patch.isEmpty == true)
        // The snapshots never touched the real index.
        #expect(try Data(contentsOf: repo.appendingPathComponent(".git/index")) == indexBefore)
        #expect(try git(["diff", "--cached", "--name-only"], in: repo).isEmpty)
    }

    @Test func notAGitFolderHasNoTopLevel() async throws {
        let plain = try folder("ensemble-plain")
        try write("x\n", "file.txt", in: plain)
        #expect(await service.topLevel(plain.path) == nil)
        #expect(await service.topLevel(plain.appendingPathComponent("missing").path) == nil)
    }

    // MARK: Staging

    @Test func stagingAndUnstagingWholeFiles() async throws {
        let repo = try makeRepo(files: ["README.md": "hello\n", "old.txt": numbered(12)])
        let root = repo.path
        let base = try await service.snapshotTree(root)
        try write("hello world\n", "README.md", in: repo)
        try write("brand new\n", "new file é.txt", in: repo)
        try git(["mv", "old.txt", "renamed.txt"], in: repo)
        try git(["reset", "-q"], in: repo)  // the rename is now unstaged: a deletion plus a new file

        var files = try await service.review(root: root, since: base)
        let readme = try #require(files.first { $0.path == "README.md" })
        let added = try #require(files.first { $0.path == "new file é.txt" })
        let renamed = try #require(files.first { $0.path == "renamed.txt" })
        #expect(renamed.kind == .renamed && renamed.stage == .unstaged)

        try await service.stage(readme)
        try await service.stage(added)
        try await service.stage(renamed)
        files = try await service.review(root: root, since: base)
        #expect(files.allSatisfy { $0.stage == .staged })
        #expect(try git(["diff", "--cached", "--name-status", "-M"], in: repo).contains("R100\told.txt\trenamed.txt"))

        try await service.unstage(try #require(files.first { $0.path == "new file é.txt" }))
        try await service.unstage(try #require(files.first { $0.path == "renamed.txt" }))
        files = try await service.review(root: root, since: base)
        #expect(files.first { $0.path == "new file é.txt" }?.stage == .untracked)
        #expect(files.first { $0.path == "renamed.txt" }?.stage == .unstaged)
        #expect(files.first { $0.path == "README.md" }?.stage == .staged)
    }

    @Test func singleHunksStageAndUnstage() async throws {
        let repo = try makeRepo(files: ["long.txt": numbered(40)])
        let root = repo.path
        let base = try await service.snapshotTree(root)
        try write(numbered(40, change: [3: "THREE", 35: "THIRTY-FIVE"]), "long.txt", in: repo)

        var file = try #require(try await service.review(root: root, since: base).first)
        #expect(file.hunks.count == 2)
        let first = try #require(file.hunkActions[0])
        #expect(first.kind == .stage && file.hunkActions[1]?.kind == .stage)

        try await service.apply(first, root: root)
        let cached = try git(["diff", "--cached"], in: repo)
        #expect(cached.contains("+THREE") && !cached.contains("THIRTY-FIVE"))
        file = try #require(try await service.review(root: root, since: base).first)
        #expect(file.stage == .partial)
        #expect(file.hunkActions[0]?.kind == .unstage)
        #expect(file.hunkActions[1]?.kind == .stage)

        try await service.apply(try #require(file.hunkActions[0]), root: root)
        #expect(try git(["diff", "--cached"], in: repo).isEmpty)
        #expect(read("long.txt", in: repo)?.contains("THIRTY-FIVE") == true)
    }

    // MARK: Commit and discard

    @Test func commitTakesOnlyWhatIsStaged() async throws {
        let repo = try makeRepo(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let root = repo.path
        await #expect(throws: GitError.self) { try await service.commit(message: "Nothing", root: root) }
        try write("a2\n", "a.txt", in: repo)
        try write("b2\n", "b.txt", in: repo)
        try await service.stage(paths: ["a.txt"], root: root)
        await #expect(throws: GitError.self) { try await service.commit(message: "   ", root: root) }
        let short = try await service.commit(message: "Change a only", root: root)
        #expect(!short.isEmpty)
        #expect(try git(["log", "-1", "--format=%s"], in: repo) == "Change a only\n")
        #expect(try git(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], in: repo) == "a.txt\n")
        #expect(try git(["status", "--porcelain"], in: repo) == " M b.txt\n")
        #expect(await service.branch(root) == "main")
    }

    @Test func commitWorksBeforeTheFirstCommit() async throws {
        let repo = try makeRepo(files: [:])
        let root = repo.path
        try write("first\n", "first.txt", in: repo)
        try await service.stage(paths: ["first.txt"], root: root)
        try await service.unstage(paths: ["first.txt"], root: root)
        #expect(try git(["status", "--porcelain"], in: repo) == "?? first.txt\n")
        try await service.stage(paths: ["first.txt"], root: root)
        _ = try await service.commit(message: "First", root: root)
        #expect(await service.head(root) != nil)
    }

    @Test func discardPutsBackTheLastCommit() async throws {
        let repo = try makeRepo(files: ["tracked.txt": "original\n", "moved.txt": numbered(15)])
        let root = repo.path
        let base = try await service.snapshotTree(root)
        try write("edited\n", "tracked.txt", in: repo)
        try git(["add", "tracked.txt"], in: repo)
        try write("edited again\n", "tracked.txt", in: repo)
        try write("scratch\n", "untracked file.txt", in: repo)
        try write("staged new\n", "staged new.txt", in: repo)
        try git(["add", "staged new.txt"], in: repo)
        try git(["mv", "moved.txt", "moved here.txt"], in: repo)

        let files = try await service.review(root: root, since: base)
        for file in files { try await service.discard(file) }

        #expect(read("tracked.txt", in: repo) == "original\n")
        #expect(read("untracked file.txt", in: repo) == nil)
        #expect(read("staged new.txt", in: repo) == nil)
        #expect(read("moved.txt", in: repo) == numbered(15))
        #expect(read("moved here.txt", in: repo) == nil)
        #expect(try git(["status", "--porcelain"], in: repo).isEmpty)
        #expect(try await service.review(root: root, since: base).isEmpty)
    }

    // MARK: Turn snapshots and the loader

    @Test @MainActor func turnSnapshotsSeparateTheLastTurnFromTheSession() async throws {
        let repo = try makeRepo(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let store = try folder("ensemble-turns").appendingPathComponent("turns.json")
        let snapshots = GitTurnSnapshots(fileURL: store, service: service)
        let target = ReviewTarget.session(id: "ses_1", title: "Test", directory: repo.path, created: Date())
        let loader = GitReviewLoader(service: service)

        #expect(await snapshots.recordTurnStart(sessionID: "ses_1", directory: repo.path) != nil)
        try write("a2\n", "a.txt", in: repo)
        #expect(await snapshots.recordTurnStart(sessionID: "ses_1", directory: repo.path) != nil)
        try write("b2\n", "b.txt", in: repo)
        try write("c\n", "sub/c.txt", in: repo)

        let whole = try await loader.load(target, scope: .all, marks: snapshots.marks, engine: ReviewEngineData())
        #expect(whole.isGit)
        #expect(whole.files.map(\.path).sorted() == ["a.txt", "b.txt", "sub/c.txt"])
        #expect(whole.comparison == "Compared with the folder before the first turn")
        let last = try await loader.load(target, scope: .lastTurn, marks: snapshots.marks, engine: ReviewEngineData())
        #expect(last.files.map(\.path).sorted() == ["b.txt", "sub/c.txt"])

        // Saved and read back.
        let reloaded = GitTurnSnapshots(fileURL: store, service: service)
        #expect(reloaded.marks["ses_1"]?.count == 2)
        // A folder that is not a repository records nothing.
        let plain = try folder("ensemble-plain")
        #expect(await snapshots.recordTurnStart(sessionID: "ses_2", directory: plain.path) == nil)
    }

    @Test func withoutSnapshotsTheSessionStartsAtTheCommitBeforeIt() async throws {
        let repo = try makeRepo(files: ["a.txt": "a\n"])
        let created = Date().addingTimeInterval(5)
        try write("a2\n", "a.txt", in: repo)
        // Committed after the session started, so it counts as the session's work.
        try git(["commit", "-q", "-am", "made by the session"], in: repo, env: ["GIT_COMMITTER_DATE": "\(Int(created.timeIntervalSince1970) + 60) +0000"])
        try write("new\n", "new.txt", in: repo)
        let target = ReviewTarget.session(id: "ses_x", title: "Test", directory: repo.path, created: created)
        let result = try await GitReviewLoader(service: service).load(target, scope: .all, marks: [:], engine: ReviewEngineData())
        #expect(result.comparison == "Compared with the last commit before the session started")
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })
        #expect(byPath["a.txt"]?.stage == .committed)
        #expect(byPath["new.txt"]?.stage == .untracked)
    }

    @Test func notAGitFolderUsesTheEngineAndTheTranscript() async throws {
        let plain = try folder("ensemble-plain")
        let target = ReviewTarget.session(id: "ses_p", title: "Plain", directory: plain.path, created: Date())
        let change = FileChange(path: plain.appendingPathComponent("notes.md").path, kind: .modified, additions: 1, deletions: 0,
                                diff: "@@ -1 +1,2 @@\n a\n+b\n")
        let items: [TranscriptItem] = [
            .user(id: "u", text: "go", date: Date()),
            .tool(ToolCallInfo(id: "t", name: "edit", title: "notes.md", inputJSON: "{\"file_path\":\"\(plain.path)/notes.md\"}",
                               status: .succeeded, diff: "@@ -1 +1,2 @@\n a\n+b\n")),
        ]
        let engine = ReviewEngineData(changes: ["ses_p": [change]], transcripts: ["ses_p": items])
        let loader = GitReviewLoader(service: service)
        let all = try await loader.load(target, scope: .all, marks: [:], engine: engine)
        #expect(!all.isGit)
        #expect(all.files.map(\.path) == ["notes.md"])
        #expect(all.files.first?.stage == .notGit)
        let last = try await loader.load(target, scope: .lastTurn, marks: [:], engine: engine)
        #expect(last.files.map(\.path) == ["notes.md"])
    }

    @Test func roomAgentsAreReviewedInTheirOwnWorktrees() async throws {
        let repo = try makeRepo(files: ["shared.txt": "base\n"])
        let gitOps = ProcessGitOps.trustingEverything
        let worktree = try await gitOps.createWorktree(repo: repo.path, branch: "ensemble/room/ada")
        try write("ada's change\n", "shared.txt", in: URL(fileURLWithPath: worktree))
        try write("ada's new file\n", "ada.txt", in: URL(fileURLWithPath: worktree))
        try write("bo edits the shared folder\n", "bo.txt", in: repo)

        let ada = UUID()
        let bo = UUID()
        let target = ReviewTarget(id: "room:1", title: "Room", directory: repo.path, created: Date().addingTimeInterval(60),
                                  sessionIDs: ["s_ada", "s_bo"], agents: [
                                      ReviewAgentSource(id: ada, name: "Ada", colorHex: "#8B7CF6", sessionID: "s_ada", worktree: worktree, baseBranch: "main"),
                                      ReviewAgentSource(id: bo, name: "Bo", colorHex: "#3FB950", sessionID: "s_bo"),
                                  ])
        let engine = ReviewEngineData(changes: ["s_bo": [FileChange(path: repo.appendingPathComponent("bo.txt").path, kind: .added)]])
        let loader = GitReviewLoader(service: service)

        let all = try await loader.load(target, scope: .all, marks: [:], engine: engine)
        #expect(Set(all.files.map(\.path)) == ["shared.txt", "ada.txt", "bo.txt"])
        #expect(all.files.filter { $0.agentID == ada }.map(\.path).sorted() == ["ada.txt", "shared.txt"])
        #expect(all.files.first { $0.path == "bo.txt" }?.agentID == bo)
        // The room's own worktrees folder never shows up as a change of the project folder.
        #expect(!all.files.contains { $0.path.hasPrefix(".ensemble") })

        let onlyAda = try await loader.load(target, scope: .agent(ada), marks: [:], engine: engine)
        #expect(onlyAda.files.allSatisfy { $0.agentID == ada && $0.root == worktree })
        #expect(onlyAda.comparison == "Compared with main")
        let onlyBo = try await loader.load(target, scope: .agent(bo), marks: [:], engine: engine)
        #expect(onlyBo.files.map(\.path) == ["bo.txt"])

        // Staging in Ada's worktree stays in her worktree.
        let adaFile = try #require(onlyAda.files.first { $0.path == "ada.txt" })
        try await service.stage(adaFile)
        #expect(try git(["diff", "--cached", "--name-only"], in: URL(fileURLWithPath: worktree)) == "ada.txt\n")
        #expect(try git(["diff", "--cached", "--name-only"], in: repo).isEmpty)
    }
}

extension GitReviewServiceTests {
    @discardableResult
    func git(_ args: [String], in dir: URL, env extra: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extra { env[key] = value }
        p.environment = env
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
}
#endif
