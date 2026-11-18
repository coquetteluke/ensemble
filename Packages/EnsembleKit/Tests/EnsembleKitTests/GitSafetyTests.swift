import Foundation
import Testing
@testable import EnsembleKit

/// What stops a repository's own settings from starting programs when Ensemble runs git (`GitSafety`), checked on
/// config entries and against crafted repositories whose every program setting writes to a marker file.
@Suite struct GitSafetyTests {
    // MARK: Overrides from config

    func entry(_ scope: String, _ key: String, _ value: String? = "x") -> GitConfigEntry {
        GitConfigEntry(scope: scope, key: key, value: value)
    }

    func value(_ pairs: [(key: String, value: String)], _ key: String) -> [String] {
        pairs.filter { $0.key == key }.map(\.value)
    }

    @Test func driversAndHooksAreSwitchedOffFromEveryScope() {
        let entries = [
            entry("local", "filter.evil.clean", "/tmp/evil"),
            entry("global", "filter.lfs.process", "git-lfs filter-process"),
            entry("local", "diff.Evil.textconv", "/tmp/evil"),
            entry("worktree", "diff.tool.command", "/tmp/evil"),
            entry("local", "diff.nice.binary", "true"),
            entry("local", "hook.lint.command", "/tmp/evil"),
            entry("command", "core.fsmonitor", "false"),
        ]
        let off = GitSafety.dynamicOverrides(entries, allowHooks: false)
        for name in ["evil", "lfs"] {
            #expect(value(off, "filter.\(name).clean") == [""] && value(off, "filter.\(name).smudge") == [""])
            #expect(value(off, "filter.\(name).process") == [""] && value(off, "filter.\(name).required") == ["false"])
        }
        #expect(value(off, "diff.Evil.textconv") == [""] && value(off, "diff.tool.command") == [""])
        #expect(value(off, "diff.nice.textconv").isEmpty, "a diff section without a program is left alone")
        #expect(value(off, "hook.lint.enabled") == ["false"])
        let withHooks = GitSafety.dynamicOverrides(entries, allowHooks: true)
        #expect(value(withHooks, "hook.lint.enabled").isEmpty)
    }

    @Test func programKeysFromTheRepositoryFallBackToTheUsersOwn() {
        let entries = [
            entry("global", "core.sshcommand", "ssh -i ~/.ssh/work"),
            entry("local", "core.sshcommand", "/tmp/evil"),
            entry("local", "gpg.program", "/tmp/evil"),
            entry("local", "commit.gpgsign", "true"),
            entry("local", "tag.gpgsign", "false"),
            entry("global", "credential.helper", "osxkeychain"),
            entry("local", "credential.helper", "!/tmp/evil"),
            entry("local", "credential.https://example.com.helper", "/tmp/evil"),
            entry("local", "remote.origin.uploadpack", "/tmp/evil"),
            entry("local", "remote.origin.receivepack", "/tmp/evil"),
            entry("local", "gpg.ssh.defaultkeycommand", "/tmp/evil"),
        ]
        let out = GitSafety.dynamicOverrides(entries, allowHooks: false)
        #expect(value(out, "core.sshcommand") == ["ssh -i ~/.ssh/work"])
        #expect(value(out, "gpg.program") == ["gpg"])
        #expect(value(out, "commit.gpgsign").allSatisfy { $0 == "false" } && !value(out, "commit.gpgsign").isEmpty)
        #expect(value(out, "tag.gpgsign").allSatisfy { $0 == "false" }, "turning signing off is the repository's call")
        #expect(value(out, "credential.helper") == ["", "osxkeychain"], "reset, then the user's own helpers")
        #expect(value(out, "credential.https://example.com.helper") == [""])
        #expect(value(out, "remote.origin.uploadpack") == ["git-upload-pack"])
        #expect(value(out, "remote.origin.receivepack") == ["git-receive-pack"])
        #expect(value(out, "push.gpgsign") == ["false"], "a key command with no default turns signing off")

        // The user's own settings alone are left as they are.
        let mine = GitSafety.dynamicOverrides([entry("global", "core.sshcommand", "ssh -v"), entry("global", "credential.helper", "osxkeychain")],
                                              allowHooks: false)
        #expect(mine.isEmpty)
    }

    @Test func staticOverridesCoverTheAlwaysOnSettings() {
        let off = Dictionary(GitSafety.staticOverrides(allowHooks: false).map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        #expect(off["core.fsmonitor"] == "false" && off["core.hooksPath"] == "/dev/null" && off["core.pager"] == "cat")
        #expect(off["diff.external"] == "" && off["protocol.ext.allow"] == "never")
        let commit = Dictionary(GitSafety.staticOverrides(allowHooks: true).map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        #expect(commit["core.hooksPath"] == nil && commit["core.fsmonitor"] == "false")
        #expect(GitSafety.environment["GIT_CONFIG_NOSYSTEM"] == "1" && GitSafety.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(GitSafety.environment["GIT_ASKPASS"] == "")
    }

    @Test func configListParsing() {
        let raw = "global\u{0}user.name\nAda\u{0}local\u{0}core.bare\nfalse\u{0}local\u{0}filter.x.required\u{0}local\u{0}alias.two\nline one\nline two\u{0}"
        let entries = GitSafety.parseConfigList(Data(raw.utf8))
        #expect(entries.count == 4)
        #expect(entries[0] == GitConfigEntry(scope: "global", key: "user.name", value: "Ada"))
        #expect(entries[2].value == nil && entries[2].parts.subsection == "x")
        #expect(entries[3].value == "line one\nline two")
        #expect(GitConfigEntry(scope: "local", key: "credential.https://a.b/c.helper", value: nil).parts.subsection == "https://a.b/c")
    }
}

#if os(macOS)
/// Crafted repositories: every setting that can start a program points at a script that writes to a marker file.
@Suite struct GitSafetyAttackTests {
    let helper = GitReviewServiceTests()

    struct Attack {
        let repo: URL
        let marker: URL
        let calls: URL
        let fakeGit: String

        /// What the scripts wrote, one line per run.
        var ran: [String] {
            ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// How often git itself was started (through `fakeGit`).
        var gitStarts: Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func clear() { try? FileManager.default.removeItem(at: marker) }
    }

    /// A repository with a committed `a.txt`, `notes.secret` and `b.md`, whose config, attributes and hooks name
    /// marker scripts for everything that can start a program, and a git wrapper that counts how often git runs.
    func makeAttack(trusted: Bool) throws -> Attack {
        let repo = try helper.makeRepo(files: ["a.txt": numbered(30), "notes.secret": "secret\n", "b.md": "# b\n"])
        if !trusted { try helper.trust.revoke(repo.path) }
        let outside = try helper.folder("ensemble-attack-tools")
        let marker = outside.appendingPathComponent("marker")
        let calls = outside.appendingPathComponent("git-calls")
        func script(_ name: String, _ body: String) throws -> String {
            let url = outside.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let evil = try script("evil.sh", "echo \"$1\" >> '\(marker.path)'\ncat")
        let fsmonitor = try script("fsmonitor.sh", "echo fsmonitor >> '\(marker.path)'\nexit 1")
        let hook = try script("hook.sh", "echo \"hook $1\" >> '\(marker.path)'\nexit 0")
        let fakeGit = try script("git", "echo run >> '\(calls.path)'\nexec /usr/bin/git \"$@\"")
        let settings: [(String, String)] = [
            ("core.fsmonitor", fsmonitor),
            ("core.pager", "\(evil) pager"), ("core.editor", "\(evil) editor"), ("sequence.editor", "\(evil) editor"),
            ("core.askPass", "\(evil) askpass"), ("core.sshCommand", "\(evil) ssh"),
            ("diff.external", "\(evil) external"),
            ("filter.evil.clean", "\(evil) clean"), ("filter.evil.smudge", "\(evil) smudge"),
            ("filter.evil2.process", "\(evil) process"),
            ("diff.evil.textconv", "\(evil) textconv"), ("diff.evil.command", "\(evil) diff-command"),
            ("hook.confighook.event", "pre-commit"), ("hook.confighook.command", "\(hook) config-pre-commit"),
            ("credential.helper", "!\(evil) credential"),
            ("gpg.program", "\(evil) gpg"), ("commit.gpgsign", "true"),
            ("core.hooksPath", repo.appendingPathComponent(".git/hooks").path),
        ]
        for (key, value) in settings { try helper.git(["config", "--add", key, value], in: repo) }
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for name in ["pre-commit", "commit-msg", "post-commit"] {
            let url = hooks.appendingPathComponent(name)
            try "#!/bin/sh\n'\(hook)' \(name)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try "*.txt diff=evil\n*.secret filter=evil\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "*.md filter=evil2 diff=evil\n".write(to: repo.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        let attack = Attack(repo: repo, marker: marker, calls: calls, fakeGit: fakeGit)
        attack.clear()
        return attack
    }

    func numbered(_ count: Int, change: [Int: String] = [:]) -> String {
        (1...count).map { change[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func service(_ attack: Attack) -> GitReviewService {
        GitReviewService(runner: GitRunner(gitPath: attack.fakeGit), removeFile: { try FileManager.default.removeItem(at: $0) },
                         trust: helper.trust)
    }

    /// Changes the attack repository the way an agent would: an edit in each kind of file and a new file.
    func edit(_ attack: Attack) throws {
        try helper.write(numbered(30, change: [3: "THREE", 25: "TWENTY-FIVE"]), "a.txt", in: attack.repo)
        try helper.write("secret 2\n", "notes.secret", in: attack.repo)
        try helper.write("# b 2\n", "b.md", in: attack.repo)
        try helper.write("new\n", "new.secret", in: attack.repo)
    }

    @Test func nothingRunsInAnUntrustedFolder() async throws {
        let attack = try makeAttack(trusted: false)
        try edit(attack)
        let service = service(attack)
        let target = ReviewTarget.session(id: "ses_u", title: "Untrusted", directory: attack.repo.path, created: Date())
        let change = FileChange(path: attack.repo.appendingPathComponent("a.txt").path, kind: .modified, additions: 1, deletions: 1,
                                diff: "@@ -3 +3 @@\n-line 3\n+THREE\n")
        let engine = ReviewEngineData(changes: ["ses_u": [change]])

        let result = try await GitReviewLoader(service: service).load(target, scope: .all, marks: [:], engine: engine)
        #expect(!result.isGit && result.untrustedFolder == WorkspaceTrust.resolvedPath(attack.repo.path))
        #expect(result.files.map(\.path) == ["a.txt"] && result.files.allSatisfy { !$0.fromGit })
        _ = try await GitReviewLoader(service: service).load(target, scope: .lastTurn, marks: [:], engine: engine)

        let snapshots = await GitTurnSnapshots(fileURL: nil, service: service)
        #expect(await snapshots.recordTurnStart(sessionID: "ses_u", directory: attack.repo.path) == nil)

        let file = ReviewFileDiff(root: attack.repo.path, path: "a.txt", kind: .modified, stage: .unstaged)
        await #expect(throws: GitUntrustedError.self) { try await service.stage(file) }
        await #expect(throws: GitUntrustedError.self) { try await service.unstage(file) }
        await #expect(throws: GitUntrustedError.self) { try await service.discard(file) }
        await #expect(throws: GitUntrustedError.self) {
            try await service.apply(ReviewHunkAction(kind: .stage, patch: "x"), root: attack.repo.path)
        }
        await #expect(throws: GitUntrustedError.self) { try await service.commit(message: "x", root: attack.repo.path) }

        #expect(attack.gitStarts == 0, "git never started")
        #expect(attack.ran.isEmpty)
        #expect(try helper.git(["status", "--porcelain", "--", "a.txt"], in: attack.repo) == " M a.txt\n", "the folder is as the agent left it")
    }

    @Test func automaticAndStagingRunsStartNoProgramInATrustedFolder() async throws {
        let attack = try makeAttack(trusted: true)
        let service = service(attack)
        let snapshots = await GitTurnSnapshots(fileURL: nil, service: service)
        #expect(await snapshots.recordTurnStart(sessionID: "ses_t", directory: attack.repo.path) != nil)
        try edit(attack)
        let target = ReviewTarget.session(id: "ses_t", title: "Trusted", directory: attack.repo.path, created: Date())
        let marks = await snapshots.marks
        let loader = GitReviewLoader(service: service)
        let whole = try await loader.load(target, scope: .all, marks: marks, engine: ReviewEngineData())
        #expect(whole.isGit && whole.untrustedFolder == nil)
        #expect(Set(whole.files.map(\.path)) == ["a.txt", "notes.secret", "b.md", "new.secret"])
        _ = try await loader.load(target, scope: .lastTurn, marks: marks, engine: ReviewEngineData())
        #expect(attack.gitStarts > 0)

        // Staging works for plain files, single hunks too; files a configured filter handles are refused.
        let text = try #require(whole.files.first { $0.path == "a.txt" })
        let hunk = try #require(text.hunkActions[0])
        try await service.apply(hunk, root: attack.repo.path)
        try await service.stage(text)
        try await service.unstage(text)
        for path in ["notes.secret", "b.md", "new.secret"] {
            let filtered = try #require(whole.files.first { $0.path == path })
            await #expect(throws: GitError.self) { try await service.stage(filtered) }
            await #expect(throws: GitError.self) { try await service.discard(filtered) }
        }
        #expect(await service.filteredPaths(["a.txt", "b.md", "notes.secret"], root: attack.repo.path) == ["b.md": "evil2", "notes.secret": "evil"])

        // A commit with Skip hooks runs nothing at all.
        try await service.stage(text)
        _ = try await service.commit(message: "Without hooks", root: attack.repo.path, skipHooks: true)
        #expect(try helper.git(["log", "-1", "--format=%s"], in: attack.repo) == "Without hooks\n")

        // A diff that forgets --no-ext-diff stops rather than starting the external diff.
        let plainDiff = await service.runner.run(["diff"], in: attack.repo.path)
        #expect(!plainDiff.succeeded)
        _ = await service.runner.run(["log", "-1", "-p"], in: attack.repo.path)

        #expect(attack.ran.isEmpty, "started: \(attack.ran)")
    }

    @Test func aCommitYouAskForRunsOnlyTheRepositorysHooks() async throws {
        let attack = try makeAttack(trusted: true)
        let service = service(attack)
        try edit(attack)
        try await service.stage(paths: ["a.txt"], root: attack.repo.path)
        attack.clear()
        _ = try await service.commit(message: "With hooks", root: attack.repo.path)
        #expect(try helper.git(["log", "-1", "--format=%s"], in: attack.repo) == "With hooks\n")
        let ran = attack.ran
        #expect(Set(ran) == ["hook pre-commit", "hook commit-msg", "hook post-commit", "hook config-pre-commit"], "started: \(ran)")
        #expect(try helper.git(["log", "-1", "--format=%G?"], in: attack.repo) == "N\n", "the repository could not turn signing on")
    }

    /// The control: plain git, without Ensemble's overrides, does start the crafted programs.
    @Test func theCraftedRepositoryRunsProgramsUnderPlainGit() throws {
        let attack = try makeAttack(trusted: true)
        try edit(attack)
        try? helper.git(["status", "--porcelain"], in: attack.repo)
        try? helper.git(["diff"], in: attack.repo)
        try? helper.git(["add", "notes.secret", "b.md"], in: attack.repo)
        try? helper.git(["diff", "--cached", "--stat", "--", "a.txt"], in: attack.repo)
        let ran = Set(attack.ran)
        #expect(ran.contains("fsmonitor"))
        #expect(ran.contains("external"), "diff.external")
        #expect(ran.contains("clean"), "clean filter from .gitattributes")
        #expect(ran.contains("process"), "process filter from .git/info/attributes")
    }

    @Test func aRepositoryThatMovesItsWorkTreeIsNotReviewed() async throws {
        let repo = try helper.makeRepo(files: ["a.txt": "a\n"])
        let elsewhere = try helper.folder("ensemble-elsewhere")
        try helper.write("someone else's file\n", "private.txt", in: elsewhere)
        try helper.git(["config", "core.worktree", elsewhere.path], in: repo)
        let target = ReviewTarget.session(id: "ses_w", title: "Moved", directory: repo.path, created: Date())
        let result = try await GitReviewLoader(service: helper.service).load(target, scope: .all, marks: [:], engine: ReviewEngineData())
        #expect(!result.isGit && result.files.isEmpty)
        let snapshots = await GitTurnSnapshots(fileURL: nil, service: helper.service)
        #expect(await snapshots.recordTurnStart(sessionID: "ses_w", directory: repo.path) == nil)
    }

    @Test func aFolderNeedsItsRepositoryTrustedNotJustItself() async throws {
        let repo = try helper.makeRepo(files: ["sub/a.txt": "a\n"])
        try helper.trust.revoke(repo.path)
        let sub = repo.appendingPathComponent("sub").path
        try helper.trust.trust(sub)
        #expect(throws: GitUntrustedError.self) { try helper.service.trustedRepository(sub) }
        let target = ReviewTarget.session(id: "ses_s", title: "Sub", directory: sub, created: Date())
        let result = try await GitReviewLoader(service: helper.service).load(target, scope: .all, marks: [:], engine: ReviewEngineData())
        #expect(result.untrustedFolder == WorkspaceTrust.resolvedPath(repo.path))
    }
}
#endif
