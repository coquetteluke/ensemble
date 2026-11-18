#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// `GitHubService` against real throwaway repositories, a local bare repository as the remote (behind a
/// github.com-looking URL) and the fake gh. Nothing reaches GitHub.
@Suite struct GitHubServiceTests {
    // MARK: gh and the sign-in

    @Test func noGHMeansNotInstalled() async {
        let service = GitHubService(locateGH: { nil }, isTrusted: { _ in true })
        #expect(await service.cliStatus() == .notInstalled)
    }

    @Test func signInIsReadThroughTheJQFilterOnly() async throws {
        let gh = try FakeGH()
        try gh.signedIn()
        let status = await gh.service.cliStatus()
        let info = try #require(status.info)
        #expect(info.path == gh.path && info.version == "2.103.3")
        #expect(info.accounts == [GitHubAccount(host: "github.com", login: "octocat", active: true, state: .valid)])
        #expect(status.account(on: "github.com")?.login == "octocat")
        let auth = gh.calls("auth", "status")
        #expect(auth == [["auth", "status", "--json", "hosts", "--jq", GitHubParsing.accountsQuery]])
        #expect(gh.calls().allSatisfy(isSafeCommand))
    }

    @Test func signedOutBrokenAndOldGH() async throws {
        let gh = try FakeGH()
        try gh.respond("auth_status", err: "You are not logged into any GitHub hosts. To log in, run: gh auth login\n")
        var status = await gh.service.cliStatus()
        #expect(status.info?.accounts.isEmpty == true)
        #expect(status.account(on: "github.com") == nil)

        try gh.respond("auth_status", fixture: "auth-invalid.tsv")
        status = await gh.service.cliStatus()
        #expect(status.signInProblem(on: "github.com") == "The sign-in for octocat on github.com no longer works")

        try gh.respond("auth_status", err: "unknown flag: --json\n", code: 1)
        status = await gh.service.cliStatus()
        #expect(status.info?.problem?.contains("brew upgrade gh") == true)
        #expect(gh.calls("auth", "status").count == 3, "never falls back to the text output")
    }

    // MARK: Local facts

    @Test func localFactsForEveryKindOfFolder() async throws {
        let service = GitHubService(locateGH: { nil }, isTrusted: { _ in true })
        let plain = try GitHubFolders.make("ensemble-plain")
        #expect(await service.localRepository(plain.path) == nil)

        let helper = GitReviewServiceTests()
        let noRemote = try helper.makeRepo()
        let bare = try #require(await service.localRepository(noRemote.path))
        #expect(bare.branch == "main" && bare.remoteName == nil && bare.remote == nil)

        let repo = try GitHubTestRepo()
        var local = try #require(await service.localRepository(repo.work.path))
        #expect(URL(fileURLWithPath: local.root).resolvingSymlinksInPath().path == repo.work.resolvingSymlinksInPath().path)
        #expect(local.branch == "main" && local.remoteName == "origin")
        #expect(local.remote == GitHubRemote(host: "github.com", owner: "acme", name: "widgets"))
        #expect(local.defaultBranch == "main" && local.published && local.unpushed == 0 && local.ahead == 0)
        #expect(local.pushRemote == local.remote && local.pushProblem == nil)
        try repo.git(["config", "remote.origin.pushurl", "git@github.com:evil/widgets.git"])
        local = try #require(await service.localRepository(repo.work.path))
        #expect(local.pushRemote?.owner == "evil", "the head is where git pushes, not where it fetches")
        try repo.git(["config", "--add", "remote.origin.pushurl", "git@github.com:acme/widgets.git"])
        local = try #require(await service.localRepository(repo.work.path))
        #expect(local.pushRemote == nil && local.pushProblem?.contains("both") == true)
        try repo.git(["config", "--unset-all", "remote.origin.pushurl"])

        try repo.git(["switch", "-q", "-c", "ensemble/x"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        try repo.commit("b.txt", "b\n", message: "Add b")
        try repo.helper.write("dirty\n", "c.txt", in: repo.work)
        local = try #require(await service.localRepository(repo.work.path))
        #expect(local.branch == "ensemble/x" && !local.published && local.unpushed == nil)
        #expect(local.ahead == 2 && local.uncommitted == 1)

        try repo.git(["checkout", "-q", "--detach"])
        local = try #require(await service.localRepository(repo.work.path))
        #expect(local.branch == nil)
    }

    @Test func defaultBranchFallsBackToTheHintWithoutRemoteHead() async throws {
        let repo = try GitHubTestRepo(setHead: false)
        let service = GitHubService(locateGH: { nil }, isTrusted: { _ in true })
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        var local = try #require(await service.localRepository(repo.work.path))
        #expect(local.defaultBranch == nil && local.ahead == nil)
        local = try #require(await service.localRepository(repo.work.path, baseHint: "main"))
        #expect(local.defaultBranch == "main" && local.ahead == 1)
    }

    @Test func aRemoteOtherThanOriginIsUsedWhenItIsTheUpstream() async throws {
        let repo = try GitHubTestRepo()
        try repo.git(["remote", "add", "fork", "git@github.com:octocat/widgets.git"])
        try repo.git(["config", "branch.main.remote", "fork"])
        let local = try #require(await GitHubService(locateGH: { nil }, isTrusted: { _ in true }).localRepository(repo.work.path))
        #expect(local.remoteName == "fork" && local.remote?.owner == "octocat")
    }

    // MARK: Branch and push

    @Test func createBranchKeepsChangesAndRefusesBadNames() async throws {
        let repo = try GitHubTestRepo()
        let service = GitHubService(locateGH: { nil }, isTrusted: { _ in true })
        try repo.helper.write("changed\n", "README.md", in: repo.work)
        try await service.createBranch("ensemble/fix", root: repo.work.path)
        #expect(try repo.git(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) == "ensemble/fix")
        #expect(repo.helper.read("README.md", in: repo.work) == "changed\n", "uncommitted changes come along")
        await #expect(throws: GitHubError.self) { try await service.createBranch("ensemble/fix", root: repo.work.path) }
        await #expect(throws: GitHubError.self) { try await service.createBranch("bad name..", root: repo.work.path) }
        await #expect(throws: GitHubError.self) { try await service.createBranch("-f", root: repo.work.path) }
    }

    @Test func pushSendsTheBranchToTheConfirmedRepositoryAndNeverForces() async throws {
        let repo = try GitHubTestRepo()
        let service = repo.service()
        try repo.git(["switch", "-q", "-c", "ensemble/fix"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        var local = try #require(await service.localRepository(repo.work.path))
        let remote = try #require(local.remote)
        let plan = GitHubPushPlan(root: local.root, remoteName: "origin", branch: "ensemble/fix", remote: remote, commits: nil)
        try await service.push(plan)
        let head = try repo.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(repo.remoteHead("ensemble/fix") == head)
        #expect(repo.loggingGit.sshLog() == ["git@github.com git-receive-pack 'acme/widgets.git'"], "sent to the repository shown")
        #expect(try repo.git(["config", "branch.ensemble/fix.remote"]).trimmingCharacters(in: .whitespacesAndNewlines) == "origin",
                "the upstream is set")
        local = try #require(await service.localRepository(repo.work.path))
        #expect(local.published && local.unpushed == 0)

        // The remote moves on; a push of a branch that does not contain its commits is refused, not forced.
        let other = try GitHubFolders.make("ensemble-other-clone")
        try repo.git(["clone", "-q", "-b", "ensemble/fix", repo.bare.path, other.path], in: repo.work)
        try repo.git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "Elsewhere"], in: other)
        try repo.git(["push", "-q", "origin", "ensemble/fix"], in: other)
        let remoteAfterOther = repo.remoteHead("ensemble/fix")
        try repo.commit("b.txt", "b\n", message: "Add b")
        await #expect(throws: GitHubError.self) {
            try await service.push(GitHubPushPlan(root: local.root, remoteName: "origin", branch: "ensemble/fix", remote: remote, commits: 1))
        }
        #expect(repo.remoteHead("ensemble/fix") == remoteAfterOther, "the remote's commits are untouched")

        let pushes = repo.loggingGit.pushes()
        #expect(pushes.count == 2)
        #expect(repo.loggingGit.calls().allSatisfy(isSafeCommand))
        for push in pushes {
            #expect(push.suffix(8) == ["-c", "push.followTags=false", "-c", "push.recurseSubmodules=no",
                                       "push", "--set-upstream", "origin", "refs/heads/ensemble/fix:refs/heads/ensemble/fix"])
        }
    }

    /// A remote whose push URL git rewrites to the same repository (a user's https-to-ssh rule) still pushes.
    @Test func aRewriteToTheSameRepositoryIsAllowed() async throws {
        let repo = try GitHubTestRepo(remoteURL: "https://github.com/acme/widgets.git")
        try repo.git(["config", "url.git@github.com:.insteadOf", "https://github.com/"])
        let service = repo.service()
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        try await service.push(GitHubPushPlan(root: repo.work.path, remoteName: "origin", branch: "feature", remote: remote, commits: nil))
        #expect(repo.remoteHead("feature") != nil)
        #expect(repo.loggingGit.sshLog() == ["git@github.com git-receive-pack 'acme/widgets.git'"])
    }

    /// Git config that would send the push somewhere other than the repository the confirmation names is refused
    /// before git push runs.
    @Test func pushesThatGitWouldSendElsewhereAreRefused() async throws {
        let token = "ghp_" + String(repeating: "Q", count: 36)
        let redirects: [(String, [[String]])] = [
            ("pushurl to a local folder", [["config", "remote.origin.pushurl", "/tmp/elsewhere.git"]]),
            ("pushurl to another GitHub repository", [["config", "remote.origin.pushurl", "git@github.com:evil/widgets.git"]]),
            ("a second pushurl elsewhere", [["config", "--add", "remote.origin.pushurl", "git@github.com:acme/widgets.git"],
                                            ["config", "--add", "remote.origin.pushurl", "git@github.com:evil/widgets.git"]]),
            ("pushInsteadOf to another host", [["config", "url.git@evil.example:.pushInsteadOf", "git@github.com:"]]),
            ("pushInsteadOf to a local folder", [["config", "url./tmp/elsewhere/.pushInsteadOf", "git@github.com:acme/"]]),
            ("insteadOf to another owner", [["config", "url.git@github.com:evil/.insteadOf", "git@github.com:acme/"]]),
            ("pushurl with a token in it", [["config", "remote.origin.pushurl", "https://x:\(token)@github.com/evil/widgets.git"]]),
        ]
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        for (name, commands) in redirects {
            let repo = try GitHubTestRepo()
            try repo.git(["switch", "-q", "-c", "feature"])
            try repo.commit("a.txt", "a\n", message: "Add a")
            for command in commands { try repo.git(command) }
            let service = repo.service()
            let plan = GitHubPushPlan(root: repo.work.path, remoteName: "origin", branch: "feature", remote: remote, commits: nil)
            do {
                try await service.push(plan)
                Issue.record("\(name): pushed")
            } catch {
                #expect(error.localizedDescription.contains("Ensemble only pushes to the repository it shows"), "\(name)")
                #expect(!error.localizedDescription.contains(token), "\(name)")
            }
            #expect(repo.loggingGit.pushes().isEmpty, "\(name): git push never ran")
            #expect(repo.loggingGit.sshLog().isEmpty && repo.remoteHead("feature") == nil, "\(name)")
        }
    }

    @Test func pushesOnlyLeaveTrustedFolders() async throws {
        let repo = try GitHubTestRepo()
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let plan = GitHubPushPlan(root: repo.work.path, remoteName: "origin", branch: "feature",
                                  remote: GitHubRemote(host: "github.com", owner: "acme", name: "widgets"), commits: nil)
        await #expect(throws: GitHubError.self) { try await repo.service(trusted: false).push(plan) }
        #expect(repo.loggingGit.pushes().isEmpty && repo.remoteHead("feature") == nil)
    }

    @Test func theGlobalCredentialHelperIsReadFromYourOwnConfigOnly() async throws {
        let service = GitHubService(locateGH: { nil }, isTrusted: { _ in true })
        let home = try GitHubFolders.make("ensemble-home")
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path]
        #expect(await service.hasGlobalCredentialHelper(environment: env) == false, "no global config")
        let config = home.appendingPathComponent(".gitconfig")
        try "[credential]\n\thelper =\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(await service.hasGlobalCredentialHelper(environment: env) == false, "an empty helper only clears others")
        try "[credential \"https://github.com\"]\n\thelper =\n\thelper = !/opt/homebrew/bin/gh auth git-credential\n"
            .write(to: config, atomically: true, encoding: .utf8)
        #expect(await service.hasGlobalCredentialHelper(environment: env))
        // A repository's own helper does not count.
        let repo = try GitHubTestRepo()
        try repo.git(["config", "credential.helper", "store"])
        try "".write(to: config, atomically: true, encoding: .utf8)
        #expect(await service.hasGlobalCredentialHelper(environment: env) == false)
    }

    @Test func displayedURLsDropCredentials() {
        let token = "ghp_" + String(repeating: "Q", count: 36)
        #expect(GitHubParsing.displayURL("https://x:\(token)@github.com/evil/widgets.git") == "https://github.com/evil/widgets.git")
        #expect(GitHubParsing.displayURL("git@github.com:evil/widgets.git") == "git@github.com:evil/widgets.git")
        #expect(GitHubParsing.displayURL("/tmp/elsewhere.git") == "/tmp/elsewhere.git")
        #expect(GitHubRemote(host: "GitHub.com", owner: "Acme", name: "Widgets")
            .isSameRepository(as: GitHubRemote(host: "github.com", owner: "acme", name: "widgets")))
    }

    // MARK: GitHub through gh

    @Test func pullRequestLookupCreateMergeAndLogsUseTheExpectedCommandLines() async throws {
        let gh = try FakeGH()
        try gh.signedIn()
        let service = gh.service
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        let branch = "ensemble/fix-the-readme"
        #expect(try await service.pullRequest(branch: branch, head: remote, base: remote) == nil)
        try gh.respond("pr_list", fixture: "pr-list-failing.json")
        let pr = try #require(try await service.pullRequest(branch: branch, head: remote, base: remote))
        #expect(pr.number == 42)
        #expect(gh.calls("pr", "list").last == ["pr", "list", "--repo", "acme/widgets", "--head", branch, "--state", "all",
                                                 "--limit", "30", "--json", GitHubParsing.pullRequestFields])
        #expect(GitHubParsing.pullRequestFields.contains("headRepositoryOwner,headRepository,isCrossRepository"))
        try gh.respond("pr_list", fixture: "pr-list-fork-same-name.json")
        #expect(try await service.pullRequest(branch: branch, head: remote, base: remote) == nil, "forks' branches of the same name")
        try gh.respond("pr_list", fixture: "pr-list-failing.json")

        let info = try await service.repoInfo(remote)
        #expect(info.defaultBranch == "main")
        #expect(gh.calls("repo", "view").last == ["repo", "view", "acme/widgets", "--json", GitHubParsing.repoFields])

        try gh.respond("pr_create", fixture: "pr-create.txt")
        let request = GitHubPullRequestRequest(remote: remote, base: "main", head: "ensemble/fix", title: "Fix the README",
                                               body: "Line one\n\nLine two", draft: true)
        let created = try await service.createPullRequest(request)
        #expect(created.number == 42)
        #expect(gh.calls("pr", "create").last == ["pr", "create", "--repo", "acme/widgets", "--base", "main", "--head", "ensemble/fix",
                                                   "--title=Fix the README", "--body=Line one\n\nLine two", "--draft"])

        try await service.enableAutoMerge(number: 42, method: .squash, remote: remote)
        try await service.disableAutoMerge(number: 42, remote: remote)
        #expect(gh.calls("pr", "merge") == [
            ["pr", "merge", "42", "--repo", "acme/widgets", "--auto", "--squash"],
            ["pr", "merge", "42", "--repo", "acme/widgets", "--disable-auto"],
        ])

        try gh.respond("run_view_1001", fixture: "run-log-failed.txt")
        let logs = await service.failedLogs(for: pr.failingChecks, remote: remote)
        #expect(logs.count == 2)
        #expect(logs[0].runID == "1001" && logs[0].text?.contains("expected \"Ensemble\"") == true)
        #expect(logs[1].runID == nil && logs[1].text == nil && logs[1].checks.map(\.name) == ["ci/external"])
        #expect(gh.calls("run", "view") == [["run", "view", "1001", "--repo", "acme/widgets", "--log-failed"]])

        #expect(gh.calls().allSatisfy(isSafeCommand))
        #expect(gh.calls().allSatisfy { GitHubCommandPolicy.ghViolation($0) == nil })
        // gh never runs inside a repository: every command names it with --repo.
        let folders = Set(gh.folders())
        #expect(folders.count == 1 && folders.first?.hasSuffix("/ensemble-gh") == true)
    }

    @Test func ghErrorsBecomeOneLineWithoutTokens() async throws {
        let gh = try FakeGH()
        let token = "gho_" + String(repeating: "Z", count: 36)
        try gh.respond("pr_list", err: "HTTP 401: Bad credentials (\(token))\nmore\n", code: 1)
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        do {
            _ = try await gh.service.pullRequest(branch: "x", head: remote, base: remote)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.hasPrefix("HTTP 401: Bad credentials"))
            #expect(!error.localizedDescription.contains(token))
        }
        try gh.respond("pr_create", out: "no link\n")
        await #expect(throws: GitHubError.self) {
            try await gh.service.createPullRequest(GitHubPullRequestRequest(remote: remote, base: "main", head: "x", title: "t", body: ""))
        }
    }

    @Test func refusedCommandLinesNeverStartGH() async throws {
        let gh = try FakeGH()
        let cli = GitHubCLI(path: gh.path)
        for args in [["auth", "token"], ["auth", "status", "--show-token"], ["auth", "login"], ["api", "user"]] {
            let result = await cli.run(args, in: nil)
            #expect(result.status == -2)
        }
        #expect(gh.calls().isEmpty)
    }

    @Test func ghRunsWithoutPromptsColoursOrPagers() {
        let env = GitHubCLI.environment(base: ["PATH": "/usr/bin", "GH_DEBUG": "api", "GIT_DIR": "/elsewhere", "HOME": "/Users/me"],
                                        ghPath: "/opt/homebrew/bin/gh")
        #expect(env["GH_PROMPT_DISABLED"] == "1" && env["NO_COLOR"] == "1" && env["GH_NO_UPDATE_NOTIFIER"] == "1")
        #expect(env["GH_PAGER"] == "cat" && env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GH_DEBUG"] == nil && env["GIT_DIR"] == nil)
        #expect(env["GIT_CONFIG_KEY_0"] == "core.fsmonitor" && env["GIT_CONFIG_VALUE_0"] == "false")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/bin") == true)
        #expect(env["HOME"] == "/Users/me")
    }

    @Test func locateHonoursTheOverrideAndPath() throws {
        let gh = try FakeGH()
        #expect(GitHubCLI.locate(environment: ["ENSEMBLE_GH_PATH": gh.path]) == gh.path)
        #expect(GitHubCLI.locate(environment: ["ENSEMBLE_GH_PATH": "/nowhere/gh"]) == nil)
    }
}
#endif
