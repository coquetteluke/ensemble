#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// "Work in a copy" in throwaway repositories: create, run, switch branch, remove, remove unused, an untrusted folder
/// refused, and uncommitted changes guarded. Every repository lives in a temporary folder and is deleted afterwards.
@Suite("Session worktrees")
struct SessionWorktreeTests {
    /// A temporary repository with one commit on `main`, and a trust store of its own.
    final class Repo: @unchecked Sendable {
        let folder: URL
        let root: String
        let trust: WorkspaceTrust

        init(commit: Bool = true) throws {
            let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            folder = base.appendingPathComponent("ens-worktree-\(UUID().uuidString.prefix(8))")
            let repo = folder.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
            root = repo.path
            trust = WorkspaceTrust(fileURL: folder.appendingPathComponent("trusted.json"), homeDirectory: "/nonexistent-home")
            try git("init", "-q", "-b", "main")
            try git("config", "user.email", "test@example.com")
            try git("config", "user.name", "Test")
            try git("config", "commit.gpgsign", "false")
            if commit {
                try write("README.md", "hello\n")
                try write("apps/web/index.js", "console.log(1)\n")
                try git("add", "-A")
                try git("commit", "-q", "-m", "first")
            }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        var gitOps: SessionWorktreeGit { SessionWorktreeGit(trust: trust) }

        func write(_ path: String, _ text: String, in base: String? = nil) throws {
            let url = URL(fileURLWithPath: base ?? root).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ path: String, in base: String) -> String? {
            try? String(contentsOfFile: (base as NSString).appendingPathComponent(path), encoding: .utf8)
        }

        @discardableResult
        func git(_ args: String..., in directory: String? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory ?? root] + args
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw SessionWorktreeError.git("git \(args.joined(separator: " ")): \(text)")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Git

    @Test func createsACopyOnANewBranchFromHead() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let record = try await repo.gitOps.create(home: repo.root, id: "abc12345")
        #expect(record.path == repo.root + "/.ensemble/worktrees/session-abc12345")
        #expect(record.sessionDirectory == record.path)
        #expect(record.branch == "ensemble/session-abc12345")
        #expect(record.baseBranch == "main")
        #expect(repo.read("README.md", in: record.path) == "hello\n")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "HEAD", in: record.path) == "ensemble/session-abc12345")
        #expect(try repo.git("rev-parse", "HEAD", in: record.path) == (try repo.git("rev-parse", "HEAD")))
        // The copy never shows in the project's own status.
        #expect(try repo.git("status", "--porcelain") == "")
        #expect(repo.read(".git/info/exclude", in: repo.root)?.contains(".ensemble/") == true)
        // A trusted folder trusts the copy inside it.
        #expect(repo.trust.isTrusted(record.sessionDirectory))
        await #expect(throws: SessionWorktreeError.self) { _ = try await repo.gitOps.create(home: repo.root, id: "abc12345") }
    }

    @Test func aSubfolderSessionRunsInTheSameSubfolderOfTheCopy() async throws {
        let repo = try Repo()
        let web = repo.root + "/apps/web"
        try repo.trust.trust(web)
        let record = try await repo.gitOps.create(home: web, id: "web00001")
        #expect(record.path == web + "/.ensemble/worktrees/session-web00001")
        #expect(record.sessionDirectory == record.path + "/apps/web")
        #expect(repo.read("index.js", in: record.sessionDirectory) == "console.log(1)\n")
        #expect(SessionWorktreePaths.projectFolder(for: record.sessionDirectory) == web)
    }

    @Test func untrustedAndUnsuitableFoldersAreRefused() async throws {
        let repo = try Repo()
        #expect(await repo.gitOps.unavailableReason(repo.root) == "Trust this folder to work in a copy")
        await #expect(throws: SessionWorktreeError.untrusted(repo.root)) { _ = try await repo.gitOps.create(home: repo.root) }
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/.ensemble"))

        let plain = repo.folder.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try repo.trust.trust(plain.path)
        #expect(await repo.gitOps.unavailableReason(plain.path) == "Not a git repository")

        let empty = try Repo(commit: false)
        try empty.trust.trust(empty.root)
        #expect(await empty.gitOps.unavailableReason(empty.root) == "The repository has no commits yet")
        await #expect(throws: SessionWorktreeError.noCommits) { _ = try await empty.gitOps.create(home: empty.root) }

        try repo.trust.trust(repo.root)
        #expect(await repo.gitOps.unavailableReason(repo.root) == nil)
    }

    @Test func switchesToAnotherLocalBranchButNotOneCheckedOutElsewhere() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        try repo.git("branch", "feature")
        let record = try await repo.gitOps.create(home: repo.root, id: "sw000001")
        let branches = try await repo.gitOps.branches(record.path)
        #expect(branches.first?.name == record.branch && branches.first?.isCurrent == true)
        let main = try #require(branches.first { $0.name == "main" })
        #expect(main.checkedOutAt.map { SessionWorktreeGit.samePath($0, repo.root) } == true)
        #expect(branches.first { $0.name == "feature" }?.checkedOutAt == nil)

        await #expect(throws: SessionWorktreeError.self) { try await repo.gitOps.switchBranch(record.path, to: "main") }
        await #expect(throws: SessionWorktreeError.unknownBranch("nope")) { try await repo.gitOps.switchBranch(record.path, to: "nope") }
        await #expect(throws: SessionWorktreeError.unknownBranch("--orphan")) { try await repo.gitOps.switchBranch(record.path, to: "--orphan") }

        // Uncommitted work comes along when it does not conflict.
        try repo.write("notes.txt", "draft\n", in: record.path)
        #expect(try await repo.gitOps.uncommittedChanges(record.path) == ["notes.txt"])
        try await repo.gitOps.switchBranch(record.path, to: "feature")
        #expect(await repo.gitOps.currentBranch(record.path) == "feature")
        #expect(repo.read("notes.txt", in: record.path) == "draft\n")
        // The project's own checkout did not move.
        #expect(await repo.gitOps.currentBranch(repo.root) == "main")
    }

    @Test func removeGuardsUncommittedChangesAndKeepsBranchesWithCommits() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let dirty = try await repo.gitOps.create(home: repo.root, id: "rm000001")
        try repo.write("README.md", "changed\n", in: dirty.path)
        await #expect(throws: SessionWorktreeError.uncommittedChanges(["README.md"])) { try await repo.gitOps.remove(dirty, force: false) }
        #expect(FileManager.default.fileExists(atPath: dirty.path))
        try await repo.gitOps.remove(dirty, force: true)
        #expect(!FileManager.default.fileExists(atPath: dirty.path))
        // No commits of its own: the branch goes too.
        #expect((try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(dirty.branch)")) == nil)

        let worked = try await repo.gitOps.create(home: repo.root, id: "rm000002")
        try repo.write("feature.txt", "x\n", in: worked.path)
        try repo.git("add", "-A", in: worked.path)
        try repo.git("commit", "-q", "-m", "work", in: worked.path)
        try await repo.gitOps.remove(worked, force: false)
        #expect(!FileManager.default.fileExists(atPath: worked.path))
        // Its commit is not merged anywhere: the branch stays.
        #expect(try repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(worked.branch)").isEmpty == false)

        // Only copies Ensemble made, at their own path, are removed.
        var forged = worked
        forged.path = repo.root
        await #expect(throws: SessionWorktreeError.notACopy(repo.root)) { try await repo.gitOps.remove(forged, force: true) }
        #expect(FileManager.default.fileExists(atPath: repo.root + "/README.md"))
    }

    @Test func pathsOfCopies() {
        #expect(SessionWorktreePaths.projectFolder(for: "/p/.ensemble/worktrees/session-ab12cd34") == "/p")
        #expect(SessionWorktreePaths.projectFolder(for: "/p/web/.ensemble/worktrees/session-ab12cd34/web") == "/p/web")
        #expect(SessionWorktreePaths.projectFolder(for: "/p/.ensemble/worktrees/agent-a") == "/p/.ensemble/worktrees/agent-a")
        #expect(SessionWorktreePaths.projectFolder(for: "/p/.ensemble/worktrees/session-../x") == "/p/.ensemble/worktrees/session-../x")
        #expect(SessionWorktreePaths.projectFolder(for: "/p") == "/p")
        #expect(SessionWorktreePaths.isValidID(SessionWorktreePaths.newID()))
        #expect(!SessionWorktreePaths.isValidID("AB12"))
    }

    /// The session's folder is the copy, so the mode's own rules decide, relative to it: edits inside run in Auto,
    /// the copy's `.git` file and dot folders ask, and the project's own checkout is outside and asks.
    @Test func aSessionInACopyKeepsTheModesProtections() {
        let rules = PermissionRules.ruleset(for: .auto)
        #expect(PermissionRules.effect(action: "edit", resource: "Sources/App.swift", rules: rules) == "allow")
        #expect(PermissionRules.effect(action: "edit", resource: ".git", rules: rules) == "ask")
        #expect(PermissionRules.effect(action: "edit", resource: ".github/workflows/ci.yml", rules: rules) == "ask")
        #expect(PermissionRules.effect(action: "edit", resource: "opencode.json", rules: rules) == "ask")
        #expect(PermissionRules.effect(action: "edit", resource: "Package.swift", rules: rules) == "ask")
        #expect(PermissionRules.effect(action: "external_directory", resource: "/p/Sources/*", rules: rules) == "ask")
        #expect(PermissionRules.ruleset(for: .plan).contains(PermissionRule("edit", "*", "deny")))
    }

    // MARK: Store

    @MainActor
    private func makeStore(_ repo: Repo) -> SessionStore {
        let store = SessionStore(engine: PreviewEngine(seed: StoreSeed(), delayScale: 0))
        store.worktrees.git = repo.gitOps
        return store
    }

    @Test @MainActor func storeStartsASessionInACopyAndGroupsItUnderTheProject() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let store = makeStore(repo)
        let session = try await store.newSession(directory: repo.root, model: nil, permissionMode: .auto, inWorktree: true)
        let record = try #require(store.worktree(for: session.id))
        #expect(session.directory == record.sessionDirectory)
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(store.isInWorktree(session.id))
        #expect(store.projects.map(\.directory) == [repo.root])

        await store.loadBranches(for: session.id)
        #expect(store.worktrees.currentBranch[session.id] == record.branch)
        #expect(store.branchSwitchUnavailableReason(session.id) == nil)
        try repo.git("branch", "other")
        await store.loadBranches(for: session.id)
        #expect(await store.switchBranch("other", for: session.id))
        #expect(store.worktrees.currentBranch[session.id] == "other")

        // Untrusted folders get no copy, and no session.
        let untrusted = try Repo()
        let other = makeStore(untrusted)
        await #expect(throws: SessionWorktreeError.self) {
            _ = try await other.newSession(directory: untrusted.root, model: nil, permissionMode: .auto, inWorktree: true)
        }
        #expect(other.sessions.isEmpty)
    }

    @Test @MainActor func theSwitchMovesAnEmptySessionIntoACopyAndBack() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let store = makeStore(repo)
        let plain = try await store.newSession(directory: repo.root, model: nil, permissionMode: .acceptEdits)
        await store.checkWorktreeAvailability(repo.root)
        #expect(store.worktreeSwitchUnavailableReason(plain.id) == nil)

        let copied = try #require(await store.setWorkInCopy(true, for: plain.id))
        #expect(store.session(plain.id) == nil)
        #expect(store.selectedSessionID == copied.id)
        #expect(copied.permissionMode == .acceptEdits)
        let record = try #require(store.worktree(for: copied.id))
        #expect(copied.directory == record.sessionDirectory)

        let back = try #require(await store.setWorkInCopy(false, for: copied.id))
        #expect(back.directory == repo.root)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(store.worktrees.records.isEmpty)

        // After the first message the copy is fixed.
        await store.send("hello", to: back.id)
        #expect(store.worktreeSwitchUnavailableReason(back.id)?.contains("before the first message") == true)
        #expect(await store.setWorkInCopy(true, for: back.id) == nil)
    }

    @Test @MainActor func removeUnusedKeepsCopiesWithUncommittedChanges() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let store = makeStore(repo)
        let clean = try await store.newSession(directory: repo.root, model: nil, permissionMode: .auto, inWorktree: true)
        let dirty = try await store.newSession(directory: repo.root, model: nil, permissionMode: .auto, inWorktree: true)
        let active = try await store.newSession(directory: repo.root, model: nil, permissionMode: .auto, inWorktree: true)
        let dirtyRecord = try #require(store.worktree(for: dirty.id))
        try repo.write("wip.txt", "unsaved\n", in: dirtyRecord.path)
        await store.archive(clean.id)
        await store.delete(dirty.id)

        await store.refreshWorktreeList()
        #expect(store.worktrees.statuses.count == 3)
        let dirtyStatus = try #require(store.worktrees.statuses.first { $0.id == dirtyRecord.id })
        #expect(dirtyStatus.changedFiles == ["wip.txt"])
        #expect((dirtyStatus.sizeBytes ?? 0) > 0)
        #expect(store.isUnused(dirtyRecord))
        #expect(!store.isUnused(try #require(store.worktree(for: active.id))))

        let outcome = await store.removeUnusedWorktrees()
        #expect(outcome.removed == 1 && outcome.kept == 1)
        #expect(store.worktree(for: active.id) != nil)
        #expect(store.worktrees.records[dirtyRecord.id] != nil)
        #expect(FileManager.default.fileExists(atPath: dirtyRecord.path))

        // Remove with the confirmation's force: the uncommitted file goes with it.
        #expect(await store.removeWorktree(dirtyRecord.id, force: false) == false)
        #expect(await store.removeWorktree(dirtyRecord.id, force: true))
        #expect(!FileManager.default.fileExists(atPath: dirtyRecord.path))
    }

    @Test @MainActor func copiesAreRememberedBetweenLaunches() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let file = repo.folder.appendingPathComponent("session-worktrees.json")
        let store = makeStore(repo)
        store.worktrees.configure(fileURL: file)
        let session = try await store.newSession(directory: repo.root, model: nil, permissionMode: .auto, inWorktree: true)
        let again = SessionWorktrees()
        again.configure(fileURL: file)
        #expect(again.record(forSession: session.id)?.path == store.worktree(for: session.id)?.path)
    }
    /// Team room agents' copies are listed too, as room copies, and can go only once the room is finished.
    @Test @MainActor func roomCopiesAreListedAndRemovedOnlyWhenTheRoomIsFinished() async throws {
        let repo = try Repo()
        try repo.trust.trust(repo.root)
        let roomPath = try await ProcessGitOps.trustingEverything.createWorktree(repo: repo.root, branch: "ensemble/room1/ada")
        #expect(roomPath.hasSuffix("/repo/.ensemble/worktrees/ensemble-room1-ada"))
        let ada = AgentSpec(name: "Ada", model: ModelRef(providerID: "mock", id: "mock-1"), colorHex: "#ff0000")
        var room = RoomState(spec: RoomSpec(title: "Parser split", directory: repo.root, agents: [ada], mode: .team))
        room.phase = .working
        room.assignments = [Assignment(agentID: ada.id, task: "Tokenizer", branch: "ensemble/room1/ada", worktreePath: roomPath)]
        let rooms = InMemoryRoomStore()
        try rooms.save(room)

        let store = makeStore(repo)
        store.worktrees.roomStore = rooms
        await store.refreshWorktreeList()
        let status = try #require(store.worktrees.statuses.first { $0.record.room != nil })
        #expect(status.record.path == roomPath)
        #expect(status.record.room?.roomTitle == "Parser split")
        #expect(status.record.room?.agentName == "Ada")
        #expect(status.branch == "ensemble/room1/ada")
        #expect(!store.isUnused(status.record))
        #expect(store.removeWorktreeUnavailableReason(status.record) == "Remove it once the room is finished")
        #expect(await store.removeWorktree(status.id, force: true) == false)
        #expect((await store.removeUnusedWorktrees()).removed == 0)
        #expect(FileManager.default.fileExists(atPath: roomPath))

        room.phase = .finished
        try rooms.save(room)
        await store.refreshWorktreeList()
        let finished = try #require(store.worktrees.statuses.first { $0.record.room != nil })
        #expect(store.isUnused(finished.record))
        #expect(store.removeWorktreeUnavailableReason(finished.record) == nil)
        let outcome = await store.removeUnusedWorktrees()
        #expect(outcome.removed == 1)
        #expect(!FileManager.default.fileExists(atPath: roomPath))
        #expect(!store.worktrees.statuses.contains { $0.record.room != nil })

        // A room record pointing anywhere but a copy folder is refused before git runs.
        var forged = finished.record
        forged.path = repo.root
        await #expect(throws: SessionWorktreeError.notACopy(repo.root)) { try await repo.gitOps.remove(forged, force: true) }
    }
}
#endif
