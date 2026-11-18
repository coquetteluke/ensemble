import Foundation
import Testing
@testable import EnsembleKit

/// What git and gh print, read without either tool: remotes, sign-ins, pull requests and checks, logs, the
/// description reply, the command policy, the confirmations and the bar's states.
@Suite struct GitHubParsingTests {
    // MARK: Remotes

    @Test func remoteURLsInEveryFormNameTheRepositoryAndDropCredentials() throws {
        let cases: [(String, GitHubRemote?)] = [
            ("https://github.com/acme/widgets.git", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("https://github.com/acme/widgets", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("https://github.com/acme/widgets/", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("git@github.com:acme/widgets.git", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("ssh://git@github.com/acme/widgets.git", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("ssh://git@ssh.github.com:443/acme/widgets.git", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("https://GitHub.com/acme/widgets.git", GitHubRemote(host: "github.com", owner: "acme", name: "widgets")),
            ("git@work.ghe.com:team/app.git", GitHubRemote(host: "work.ghe.com", owner: "team", name: "app")),
            ("https://gitlab.com/acme/widgets.git", GitHubRemote(host: "gitlab.com", owner: "acme", name: "widgets")),
            ("/Users/someone/repos/widgets.git", nil),
            ("../widgets", nil),
            ("file:///tmp/widgets.git", nil),
            ("https://github.com/acme", nil),
            ("https://github.com/acme/widgets/tree/main", nil),
            ("", nil),
        ]
        for (url, expected) in cases {
            #expect(GitHubParsing.remote(fromURL: url) == expected, "\(url)")
        }
        // A token in the URL never reaches any field.
        let secret = "ghp_" + String(repeating: "A", count: 36)
        let remote = try #require(GitHubParsing.remote(fromURL: "https://x-access-token:\(secret)@github.com/acme/widgets.git"))
        #expect(remote == GitHubRemote(host: "github.com", owner: "acme", name: "widgets"))
        #expect(!"\(remote)".contains(secret))
    }

    /// A remote URL is written by the repository; anything that could turn the sign-in hint into another command
    /// makes the remote not GitHub.
    @Test func hostileRemotesAreNotGitHub() {
        let hostile = [
            "git@github.com;touch x:acme/widgets.git",
            "git@$(touch x):acme/widgets.git",
            "git@`touch x`:acme/widgets.git",
            "git@github .com:acme/widgets.git",
            "git@-oProxyCommand=x:acme/widgets.git",
            "git@github.com\n:acme/widgets.git",
            "ssh://git@evil.com;rm%20-rf/acme/widgets.git",
            "https://github.com/acme;touch x/widgets.git",
            "https://github.com/acme/$(touch x).git",
            "https://github.com/-acme/widgets.git",
            "https://github.com/acme/-widgets.git",
            "https://github.com/acme/wid gets.git",
            "https://github.com/ac`me`/widgets.git",
            "git@github.com:acme/widgets.git\nrm -rf ~",
            "https://-github.com/acme/widgets.git",
            "https://github-.com/acme/widgets.git",
            "https://github..com/acme/widgets.git",
            "https://github.com//acme/widgets.git",
        ]
        for url in hostile {
            #expect(GitHubParsing.remote(fromURL: url) == nil, "\(url)")
        }
        #expect(GitHubParsing.isSafeHost("github.com") && GitHubParsing.isSafeHost("git.example-corp.co.uk"))
        for host in ["github.com;x", "$(x)", "`x`", "a b", "-x", "x-", "x\ny", "", "a..b"] {
            #expect(!GitHubParsing.isSafeHost(host), "\(host)")
        }
        #expect(GitHubParsing.isSafeName("my.repo_name-2") && !GitHubParsing.isSafeName("-x") && !GitHubParsing.isSafeName("a;b"))
    }

    @Test func githubHostsAreGitHubComEnterpriseCloudAndSignedInHosts() {
        #expect(GitHubParsing.isGitHubHost("github.com", signedInHosts: []))
        #expect(GitHubParsing.isGitHubHost("work.ghe.com", signedInHosts: []))
        #expect(!GitHubParsing.isGitHubHost("git.example.com", signedInHosts: []))
        #expect(GitHubParsing.isGitHubHost("git.example.com", signedInHosts: ["git.example.com"]))
        #expect(!GitHubParsing.isGitHubHost("gitlab.com", signedInHosts: ["github.com"]))
        let remote = GitHubRemote(host: "git.example.com", owner: "a", name: "b")
        #expect(remote.repoArgument == "git.example.com/a/b")
        #expect(GitHubRemote(host: "github.com", owner: "a", name: "b").repoArgument == "a/b")
    }

    // MARK: Sign-in and version

    @Test func signInLinesKeepOnlyHostAccountStateAndActive() {
        let text = "github.com\toctocat\tsuccess\ttrue\ngithub.com\tother\terror\tfalse\nwork.ghe.com\tme\ttimeout\ttrue\n\nbad line\n"
        let accounts = GitHubParsing.accounts(fromTSV: text)
        #expect(accounts == [
            GitHubAccount(host: "github.com", login: "octocat", active: true, state: .valid),
            GitHubAccount(host: "github.com", login: "other", active: false, state: .invalid),
            GitHubAccount(host: "work.ghe.com", login: "me", active: true, state: .unverified),
        ])
        let status = GitHubCLIStatus.installed(GitHubCLIInfo(path: "/opt/homebrew/bin/gh", accounts: accounts))
        #expect(status.account(on: "github.com")?.login == "octocat")
        #expect(status.account(on: "work.ghe.com")?.login == "me", "a sign-in gh could not check still counts")
        #expect(status.signInProblem(on: "github.com") == nil)
        #expect(status.signedInHosts == ["github.com", "work.ghe.com"])

        let broken = GitHubCLIStatus.installed(GitHubCLIInfo(path: "gh", accounts: GitHubParsing.accounts(fromTSV: "github.com\toctocat\terror\ttrue")))
        #expect(broken.account(on: "github.com") == nil)
        #expect(broken.signInProblem(on: "github.com") == "The sign-in for octocat on github.com no longer works")
        #expect(GitHubCLIStatus.notInstalled.signInProblem(on: "github.com") != nil)
        #expect(GitHubCLIStatus.installed(GitHubCLIInfo(path: "gh")).account(on: "github.com") == nil)
    }

    @Test func theSignInQueryAsksGHForFourFieldsOnly() {
        let query = GitHubParsing.accountsQuery
        #expect(query.contains(".host") && query.contains(".login") && query.contains(".state") && query.contains(".active"))
        #expect(!query.contains("token"))
    }

    @Test func versionLine() {
        #expect(GitHubParsing.version("gh version 2.103.3 (2026-10-26)\nhttps://github.com/cli/cli/releases/tag/v2.103.3\n") == "2.103.3")
        #expect(GitHubParsing.version("something else") == nil)
    }

    // MARK: Pull requests and checks

    @Test func pendingChecksIncludeRunningRunsAndCommitStatuses() throws {
        let prs = try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-pending.json"))
        let pr = try #require(prs.first)
        #expect(pr.number == 42 && pr.title == "Fix the README" && pr.state == .open && !pr.isDraft)
        #expect(pr.reviewDecision == .reviewRequired && !pr.autoMergeEnabled)
        #expect(pr.headRefName == "ensemble/fix-the-readme" && pr.baseRefName == "main")
        #expect(pr.checks.map(\.bucket) == [.pass, .pending, .pending])
        #expect(pr.checks.map(\.label) == ["CI / lint", "CI / test", "ci/external"])
        #expect(pr.checks[1].runID == "1001")
        #expect(pr.checks[2].runID == nil && pr.checks[2].link == "https://ci.example.com/build/7")
        #expect(pr.checkSummary.overall == .pending)
        #expect(pr.checkSummary.label == "2 checks pending")
    }

    @Test func failingChecksCountEachCheckOnceByItsNewestRun() throws {
        let pr = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-failing.json")).first)
        #expect(pr.reviewDecision == .changesRequested)
        #expect(pr.checks.count == 3, "the older passing run of test is dropped")
        #expect(pr.failingChecks.map(\.label) == ["CI / test", "ci/external"])
        #expect(pr.checkSummary.overall == .failing)
        #expect(pr.checkSummary.label == "2 checks failing")
    }

    @Test func passingChecksAndTheOpenPullRequestIsPicked() throws {
        let prs = try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-passing.json"))
        #expect(prs.count == 2)
        let pr = try #require(GitHubParsing.pick(prs))
        #expect(pr.number == 42, "the open one wins over the older closed one")
        #expect(pr.reviewDecision == .approved)
        #expect(pr.checkSummary.overall == .passing)
        #expect(pr.checkSummary.label == "3 checks passing")
        #expect(prs[1].reviewDecision == nil, "an empty review decision is none")
    }

    @Test func onlyPullRequestsFromTheBranchesOwnRepositoryArePicked() throws {
        let acme = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        let octocat = GitHubRemote(host: "github.com", owner: "octocat", name: "widgets")
        let branch = "ensemble/fix-the-readme"
        let forks = try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-fork-same-name.json"))
        #expect(forks.count == 2 && forks.allSatisfy { $0.headRepositoryOwner == "mallory" && $0.isCrossRepository })
        #expect(GitHubParsing.pick(forks, branch: branch, head: acme, base: acme) == nil, "a fork's branch of the same name never counts")
        let mixed = try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-mixed.json"))
        #expect(GitHubParsing.pick(mixed, branch: branch, head: acme, base: acme)?.number == 42, "even when the fork's is newer")
        #expect(GitHubParsing.pick(mixed, branch: "other", head: acme, base: acme) == nil)

        let fromFork = try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-from-fork.json"))
        #expect(GitHubParsing.pick(fromFork, branch: "feature", head: octocat, base: acme)?.number == 51)
        #expect(GitHubParsing.pick(fromFork, branch: "feature", head: acme, base: acme) == nil)
        // A pull request whose head is the right repository but claims the wrong cross-repository flag does not count.
        var odd = try #require(mixed.last)
        odd.isCrossRepository = true
        #expect(!odd.isFrom(branch: branch, head: acme, base: acme))
        var noHead = try #require(mixed.last)
        noHead.headRepositoryName = nil
        #expect(!noHead.isFrom(branch: branch, head: acme, base: acme), "a deleted head repository never matches")
    }

    @Test func aForkKnowsItsParent() throws {
        let fork = try GitHubParsing.repoInfo(Fixtures.data("github/repo-view-fork.json"))
        #expect(fork.parent == GitHubRemote(host: "github.com", owner: "acme", name: "widgets"))
        #expect(fork.ownerLogin == "octocat" && GitHubParsing.repoFields.hasSuffix("isFork,parent,owner"))
        #expect(try GitHubParsing.repoInfo(Fixtures.data("github/repo-view.json")).parent == nil)
        let enterprise = try GitHubParsing.repoInfo(Fixtures.data("github/repo-view-fork.json"), host: "work.ghe.com")
        #expect(enterprise.parent?.host == "work.ghe.com")
    }

    /// Deny by default: the fetch repository, or your own fork of it, and nothing else.
    @Test func pushesGoOnlyToTheFetchRepositoryOrYourOwnForkOfIt() {
        let acme = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        let octocat = GitHubRemote(host: "github.com", owner: "octocat", name: "widgets")
        let mallory = GitHubRemote(host: "github.com", owner: "mallory", name: "widgets")
        let signedIn = GitHubCLIStatus.installed(GitHubCLIInfo(path: "gh", accounts: [
            GitHubAccount(host: "github.com", login: "OctoCat", active: true, state: .valid),
            GitHubAccount(host: "github.com", login: "work-me", active: false, state: .valid),
            GitHubAccount(host: "github.com", login: "old-me", active: false, state: .invalid),
        ]))
        func fork(_ remote: GitHubRemote, of parent: GitHubRemote?, owner: String? = nil) -> GitHubRepoInfo {
            GitHubRepoInfo(nameWithOwner: remote.slug, url: "", defaultBranch: "main", parent: parent, ownerLogin: owner ?? remote.owner)
        }
        func refusal(_ push: GitHubRemote, _ info: GitHubRepoInfo?, fetch: GitHubRemote? = acme, cli: GitHubCLIStatus? = signedIn) -> String? {
            GitHubPushPolicy.refusal(remoteName: "origin", fetch: fetch, push: push, pushInfo: info, cli: cli)
        }
        #expect(refusal(acme, nil) == nil, "the repository it fetches from")
        #expect(refusal(GitHubRemote(host: "github.com", owner: "ACME", name: "Widgets"), nil) == nil)
        #expect(refusal(octocat, fork(octocat, of: acme)) == nil, "your own fork of it")
        let work = GitHubRemote(host: "github.com", owner: "work-me", name: "widgets")
        #expect(refusal(work, fork(work, of: acme)) == nil, "a fork owned by another signed-in account")

        let unrelated = refusal(GitHubRemote(host: "github.com", owner: "evil", name: "widgets"),
                                GitHubRepoInfo(nameWithOwner: "evil/widgets", url: "", defaultBranch: "main", ownerLogin: "evil"))
        #expect(unrelated == "origin fetches from acme/widgets but pushes to evil/widgets. Ensemble pushes only to the repository "
            + "a branch comes from, or to your own fork of it.")
        #expect(refusal(mallory, fork(mallory, of: acme)) != nil, "someone else's fork")
        let old = GitHubRemote(host: "github.com", owner: "old-me", name: "widgets")
        #expect(refusal(old, fork(old, of: acme)) != nil, "an account whose sign-in no longer works")
        #expect(refusal(octocat, fork(octocat, of: GitHubRemote(host: "github.com", owner: "other", name: "widgets"))) != nil,
                "your fork of another repository")
        #expect(refusal(octocat, fork(octocat, of: acme, owner: "mallory")) != nil, "GitHub says someone else owns it")
        #expect(refusal(octocat, nil) != nil, "nothing known about the push repository")
        #expect(refusal(octocat, fork(mallory, of: acme)) != nil, "facts about another repository")
        #expect(refusal(octocat, fork(octocat, of: acme), cli: nil) != nil)
        #expect(refusal(octocat, fork(octocat, of: acme), fetch: nil) != nil)
        let enterprise = GitHubRemote(host: "work.ghe.com", owner: "octocat", name: "widgets")
        #expect(refusal(enterprise, fork(enterprise, of: acme)) != nil, "another host")
    }

    @Test func aPullRequestFromAForkNamesItsHeadByOwner() {
        let acme = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        let octocat = GitHubRemote(host: "github.com", owner: "octocat", name: "widgets")
        let request = GitHubPullRequestRequest(remote: acme, base: "main", head: "feature", headRemote: octocat, title: "Fix", body: "")
        #expect(request.isCrossRepository && request.headLabel == "octocat:feature")
        #expect(request.arguments == ["pr", "create", "--repo", "acme/widgets", "--base", "main", "--head", "octocat:feature",
                                      "--title=Fix", "--body="])
        let same = GitHubPullRequestRequest(remote: acme, base: "main", head: "feature", headRemote: acme, title: "Fix", body: "")
        #expect(!same.isCrossRepository && same.headLabel == "feature")
        let plan = GitHubPushPlan(root: "/r", remoteName: "origin", branch: "feature", remote: octocat, commits: nil)
        let confirmation = GitHubConfirmation(action: .createPullRequest(push: plan, request: request))
        #expect(confirmation.message.contains("Pushes feature to origin (octocat/widgets on github.com)"))
        #expect(confirmation.message.contains("in acme/widgets from octocat:feature into main"))
    }

    @Test func autoMergeAndMergedStates() throws {
        let auto = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-auto-merge.json")).first)
        #expect(auto.autoMergeEnabled)
        #expect(auto.checks.first?.bucket == .pending, "a queued run is pending")
        let merged = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-merged.json")).first)
        #expect(merged.state == .merged && merged.stateLabel == "Merged" && !merged.isOpen)
        #expect(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-empty.json")).isEmpty)
        #expect(GitHubParsing.pick([]) == nil)
    }

    @Test func bucketsMatchGHPRChecks() {
        #expect(GitHubParsing.bucket("SUCCESS") == .pass)
        #expect(GitHubParsing.bucket("NEUTRAL") == .skipping)
        #expect(GitHubParsing.bucket("SKIPPED") == .skipping)
        #expect(GitHubParsing.bucket("CANCELLED") == .cancel)
        for failure in ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"] {
            #expect(GitHubParsing.bucket(failure) == .fail)
        }
        for pending in ["PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", ""] {
            #expect(GitHubParsing.bucket(pending) == .pending)
        }
        #expect(GitHubCheckSummary([]).label == "No checks")
        #expect(GitHubCheckSummary([GitHubCheck(name: "a", bucket: .pass)]).label == "1 check passing")
        #expect(GitHubCheckSummary([GitHubCheck(name: "a", bucket: .cancel)]).overall == .failing)
    }

    @Test func repositorySettingsAndTheMergeMethod() throws {
        let info = try GitHubParsing.repoInfo(Fixtures.data("github/repo-view.json"))
        #expect(info.nameWithOwner == "acme/widgets" && info.defaultBranch == "main")
        #expect(info.mergeMethod == .squash)
        let mergeOnly = try GitHubParsing.repoInfo(Fixtures.data("github/repo-view-merge-only.json"))
        #expect(mergeOnly.defaultBranch == "trunk" && mergeOnly.mergeMethod == .merge)
        #expect(GitHubRepoInfo(nameWithOwner: "a/b", url: "", defaultBranch: nil, squashAllowed: false, mergeCommitAllowed: false,
                               rebaseAllowed: true).mergeMethod == .rebase)
        #expect(GitHubRepoInfo(nameWithOwner: "a/b", url: "", defaultBranch: nil, squashAllowed: false, mergeCommitAllowed: false,
                               rebaseAllowed: false).mergeMethod == nil)
    }

    @Test func linksFromGH() {
        let created = GitHubParsing.createdPullRequest("Warning: 1 uncommitted change\nhttps://github.com/acme/widgets/pull/42\n")
        #expect(created?.number == 42 && created?.url == "https://github.com/acme/widgets/pull/42")
        #expect(GitHubParsing.createdPullRequest("nothing here") == nil)
        #expect(GitHubParsing.runID(in: "https://github.com/acme/widgets/actions/runs/1001/job/2002") == "1001")
        #expect(GitHubParsing.jobID(in: "https://github.com/acme/widgets/actions/runs/1001/job/2002") == "2002")
        #expect(GitHubParsing.runID(in: "https://ci.example.com/build/7") == nil)
        #expect(GitHubParsing.isWebLink("https://github.com/acme/widgets/pull/42", on: "github.com"))
        #expect(!GitHubParsing.isWebLink("http://github.com/acme/widgets/pull/42", on: "github.com"))
        #expect(!GitHubParsing.isWebLink("https://evil.example/acme/widgets/pull/42", on: "github.com"))
        #expect(!GitHubParsing.isWebLink("file:///etc/passwd", on: "github.com"))
    }

    // MARK: Logs

    @Test func failedLogsLoseColoursTimestampsAndGroupMarkers() throws {
        let trimmed = GitHubParsing.trimLog(try Fixtures.text("github/run-log-failed.txt"))
        #expect(trimmed.hasPrefix("test / Run swift test:\n"))
        #expect(trimmed.contains("Test Suite started\n"))
        #expect(trimmed.contains("error: README.md:3: expected \"Ensemble\""))
        #expect(trimmed.contains("##[error]Process completed with exit code 1."))
        #expect(!trimmed.contains("\u{1B}"))
        #expect(!trimmed.contains("2026-11-18T"))
        #expect(!trimmed.contains("##[group]") && !trimmed.contains("##[endgroup]"))
    }

    @Test func longLogsKeepTheEndOfEachStepAndFitTheLimit() {
        var lines: [String] = []
        for i in 1...500 { lines.append("build\tCompile\t2026-11-18T10:00:00.0000000Z line \(i)") }
        for i in 1...300 { lines.append("test\tRun tests\t2026-11-18T10:01:00.0000000Z failure \(i)") }
        let trimmed = GitHubParsing.trimLog(lines.joined(separator: "\n"), limit: 3_000)
        #expect(trimmed.count <= 3_000 + 20)
        #expect(trimmed.contains("line 500") && trimmed.contains("failure 300"), "the end of each step stays")
        #expect(!trimmed.contains("line 1\n"))
        #expect(trimmed.contains("earlier lines cut"))
    }

    @Test func tokensInLogsAndErrorsAreRemoved() {
        let token = "ghp_" + String(repeating: "x", count: 36)
        let pat = "github_pat_" + String(repeating: "Y", count: 40)
        let log = "job\tstep\t2026-11-18T10:00:00Z using \(token) and \(pat)"
        let trimmed = GitHubParsing.trimLog(log)
        #expect(!trimmed.contains(token) && !trimmed.contains(pat))
        #expect(trimmed.contains("[token removed]"))
        #expect(!GitHubParsing.errorLine("HTTP 401: Bad credentials \(token)", fallback: "x").contains(token))
        #expect(GitHubParsing.errorLine("\n\n  ", fallback: "fallback") == "fallback")
    }

    @Test func fixMessageNamesTheChecksAndCarriesEachRunLog() throws {
        let pr = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-failing.json")).first)
        let failing = pr.failingChecks
        let logs = [
            GitHubFailedLog(checks: [failing[0]], runID: "1001", text: "error: README.md:3"),
            GitHubFailedLog(checks: [failing[1]], runID: nil, text: nil),
        ]
        let message = GitHubParsing.fixChecksMessage(pullRequest: pr, logs: logs)
        #expect(message.contains("#42"))
        #expect(message.contains("failing: CI / test, ci/external"))
        #expect(message.contains("Failed log for CI / test (run 1001):\n```text\nerror: README.md:3\n```"))
        #expect(message.contains("No log could be fetched for ci/external. Details: https://ci.example.com/build/7"))
        #expect(!message.contains("\u{2014}"))
    }

    // MARK: Write description

    @Test func descriptionRepliesBecomeATitleAndABody() throws {
        let plain = try #require(GitHubPullRequestDraft.clean("Title: Fix the README.\n\nThe README named the wrong app.\n\n- Rename it\n- Add a check"))
        #expect(plain.title == "Fix the README")
        #expect(plain.body == "The README named the wrong app.\n\n- Rename it\n- Add a check")

        let fenced = try #require(GitHubPullRequestDraft.clean("```\nTitle: \"Add the pull request bar\"\n\nDescription:\nShows checks \u{2014} and more.\n```"))
        #expect(fenced.title == "Add the pull request bar")
        #expect(fenced.body == "Shows checks, and more.")

        let heading = try #require(GitHubPullRequestDraft.clean("# Speed up the sidebar\nBody: Caches rows."))
        #expect(heading.title == "Speed up the sidebar" && heading.body == "Caches rows.")

        let titleOnly = try #require(GitHubPullRequestDraft.clean("Tidy the settings"))
        #expect(titleOnly.title == "Tidy the settings" && titleOnly.body.isEmpty)
        #expect(GitHubPullRequestDraft.clean("  \n\n") == nil)
        #expect(GitHubPullRequestDraft.clean("Title:   ") == nil)
    }

    @Test func descriptionPromptCarriesCommitsFilesAndACutDiff() {
        let files = [ReviewFileDiff(root: "/r", path: "README.md", kind: .modified, additions: 1, deletions: 1,
                                    patch: "@@ -1 +1 @@\n-a\n+" + String(repeating: "b", count: 200) + "\n")]
        let context = GitHubPullRequestContext(branch: "ensemble/x", base: "main", commits: ["Fix one", "Fix two"], files: files)
        let prompt = GitHubPullRequestDraft.prompt(context, diffLimit: 50)
        #expect(prompt.contains("branch ensemble/x, to be merged into main"))
        #expect(prompt.contains("- Fix one\n- Fix two"))
        #expect(prompt.contains("M README.md (+1 -1)"))
        #expect(prompt.contains("[diff cut short]"))
        #expect(prompt.contains("Title:"))
    }

    // MARK: Command policy

    @Test func ghPolicyAllowsOnlyTheCommandsEnsembleUses() {
        let allowed: [[String]] = [
            ["--version"],
            ["auth", "status", "--json", "hosts", "--jq", GitHubParsing.accountsQuery],
            ["repo", "view", "acme/widgets", "--json", GitHubParsing.repoFields],
            ["pr", "list", "--repo", "acme/widgets", "--head", "x", "--state", "all", "--json", "number"],
            ["pr", "create", "--repo", "acme/widgets", "--base", "main", "--head", "x", "--title=--force it", "--body=-t"],
            ["pr", "merge", "42", "--repo", "acme/widgets", "--auto", "--squash"],
            ["run", "view", "1001", "--repo", "acme/widgets", "--log-failed"],
        ]
        for args in allowed { #expect(GitHubCommandPolicy.ghViolation(args) == nil, "\(args)") }
        let refused: [[String]] = [
            ["auth", "token"], ["auth", "login"], ["auth", "logout"], ["auth", "setup-git"], ["auth", "refresh"],
            ["auth", "status", "--show-token"], ["auth", "status", "-t"], ["auth", "status", "token"],
            ["api", "user"], ["repo", "delete", "acme/widgets"], ["pr", "close", "42"],
            ["pr", "merge", "42", "--admin"], ["pr", "merge", "42", "--squash", "--force"], ["pr", "view", "--web"],
            ["pr", "create", "-f"], [],
        ]
        for args in refused { #expect(GitHubCommandPolicy.ghViolation(args) != nil, "\(args)") }
    }

    @Test func pushPolicyAllowsOneBranchToTheSameNameAndNeverForces() {
        let plan = GitHubPushPlan(root: "/r", remoteName: "origin", branch: "ensemble/x",
                                  remote: GitHubRemote(host: "github.com", owner: "acme", name: "widgets"), commits: 2)
        #expect(plan.arguments == ["push", "--set-upstream", "origin", "refs/heads/ensemble/x:refs/heads/ensemble/x"])
        #expect(GitHubCommandPolicy.pushViolation(plan.arguments) == nil)
        let refused: [[String]] = [
            ["push", "--force", "origin", "refs/heads/x:refs/heads/x"],
            ["push", "-f", "origin", "refs/heads/x:refs/heads/x"],
            ["push", "--force-with-lease=x", "origin", "refs/heads/x:refs/heads/x"],
            ["push", "origin", "+refs/heads/x:refs/heads/x"],
            ["push", "origin", ":refs/heads/x"],
            ["push", "origin", "refs/heads/x:refs/heads/main"],
            ["push", "--delete", "origin", "x"],
            ["push", "--mirror", "origin"],
            ["push", "--all", "origin"],
            ["push", "origin"],
            ["fetch", "origin"],
            ["-c", "core.sshCommand=/tmp/x", "push", "origin", "refs/heads/x:refs/heads/x"],
            ["-c", "remote.origin.pushurl=/tmp/x", "push", "origin", "refs/heads/x:refs/heads/x"],
        ]
        for args in refused { #expect(GitHubCommandPolicy.pushViolation(args) != nil, "\(args)") }
        #expect(GitHubCommandPolicy.pushViolation(["-c", "push.followTags=false", "-c", "push.recurseSubmodules=no"] + plan.arguments) == nil)
    }

    // MARK: Confirmations

    @Test func confirmationsNameTheRemoteBranchAndRepository() {
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        let plan = GitHubPushPlan(root: "/r", remoteName: "origin", branch: "ensemble/fix", remote: remote, commits: 3)
        let push = GitHubConfirmation(action: .push(plan))
        #expect(push.title == "Push ensemble/fix to origin?")
        #expect(push.message.contains("3 commits") && push.message.contains("origin") && push.message.contains("acme/widgets"))
        #expect(push.message.contains("force-pushed"))

        let request = GitHubPullRequestRequest(remote: remote, base: "main", head: "ensemble/fix", title: "Fix it", body: "")
        let create = GitHubConfirmation(action: .createPullRequest(push: GitHubPushPlan(root: "/r", remoteName: "origin",
                                                                                         branch: "ensemble/fix", remote: remote, commits: nil),
                                                                   request: request))
        #expect(create.message.contains("Pushes ensemble/fix to origin (acme/widgets on github.com)"))
        #expect(create.message.contains("into main") && create.message.contains("Fix it"))
        #expect(create.confirmTitle == "Push and open")

        let openOnly = GitHubConfirmation(action: .createPullRequest(push: nil, request: request))
        #expect(openOnly.message.contains("acme/widgets") && openOnly.message.contains("ensemble/fix") && !openOnly.message.contains("Push"))

        let merge = GitHubConfirmation(action: .merge(number: 42, method: .squash, remote: remote, base: "main"))
        #expect(merge.title == "Merge #42 when ready?")
        #expect(merge.message.contains("acme/widgets") && merge.message.contains("squash and merge into main"))
        for text in [push.title, push.message, create.message, openOnly.message, merge.message] {
            #expect(!text.contains("\u{2014}"))
        }
        #expect(request.arguments == ["pr", "create", "--repo", "acme/widgets", "--base", "main", "--head", "ensemble/fix",
                                      "--title=Fix it", "--body="])
    }

    // MARK: Bar states

    @Test func everyBarState() throws {
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")
        let signedIn = GitHubCLIStatus.installed(GitHubCLIInfo(path: "gh", accounts: [
            GitHubAccount(host: "github.com", login: "octocat", active: true, state: .valid),
        ]))
        let signedOut = GitHubCLIStatus.installed(GitHubCLIInfo(path: "gh"))
        func local(branch: String? = "ensemble/x", remoteName: String? = "origin", remote: GitHubRemote? = remote) -> GitHubLocalRepo {
            GitHubLocalRepo(root: "/r", branch: branch, remoteName: remoteName, remote: remote, defaultBranch: "main")
        }
        let pr = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-pending.json")).first)

        #expect(GitHubBarState.derive(local: nil, cli: signedIn, defaultBranch: nil, pullRequest: nil, lookupError: nil) == .hidden(.notRepository))
        #expect(GitHubBarState.derive(local: local(remoteName: nil, remote: nil), cli: signedIn, defaultBranch: "main", pullRequest: nil,
                                      lookupError: nil) == .hidden(.noRemote))
        let gitlab = GitHubRemote(host: "gitlab.com", owner: "a", name: "b")
        #expect(GitHubBarState.derive(local: local(remote: gitlab), cli: signedIn, defaultBranch: "main", pullRequest: nil,
                                      lookupError: nil) == .hidden(.notGitHub))
        #expect(GitHubBarState.derive(local: local(remote: nil), cli: signedIn, defaultBranch: "main", pullRequest: nil,
                                      lookupError: nil) == .hidden(.notGitHub), "a remote that is a local path")
        #expect(GitHubBarState.derive(local: local(), cli: nil, defaultBranch: "main", pullRequest: nil, lookupError: nil) == .loading)
        #expect(GitHubBarState.derive(local: local(), cli: .notInstalled, defaultBranch: "main", pullRequest: nil, lookupError: nil) == .needsCLI)
        #expect(GitHubBarState.derive(local: local(), cli: signedOut, defaultBranch: "main", pullRequest: nil, lookupError: nil)
            == .signedOut(host: "github.com", problem: nil))
        #expect(GitHubBarState.derive(local: local(branch: nil), cli: signedIn, defaultBranch: "main", pullRequest: nil,
                                      lookupError: nil) == .hidden(.detached))
        #expect(GitHubBarState.derive(local: local(branch: "main"), cli: signedIn, defaultBranch: "main", pullRequest: nil,
                                      lookupError: nil) == .defaultBranch(branch: "main"))
        #expect(GitHubBarState.derive(local: local(), cli: signedIn, defaultBranch: "main", pullRequest: nil, lookupError: nil)
            == .noPullRequest(branch: "ensemble/x", base: "main"))
        #expect(GitHubBarState.derive(local: local(), cli: signedIn, defaultBranch: "main", pullRequest: pr, lookupError: nil)
            == .pullRequest(pr))
        #expect(GitHubBarState.derive(local: local(), cli: signedIn, defaultBranch: "main", pullRequest: nil, lookupError: "HTTP 502")
            == .failed("HTTP 502"))

        #expect(!GitHubBarState.loading.isVisible && !GitHubBarState.hidden(.noRemote).isVisible)
        #expect(GitHubBarState.needsCLI.isVisible && GitHubBarState.needsCLI.isDismissible)
        #expect(!GitHubBarState.pullRequest(pr).isDismissible)
    }

    @Test func refreshEveryMinuteWhileChecksArePendingAndLessOftenOtherwise() throws {
        let pending = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-pending.json")).first)
        let passing = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-passing.json")).first)
        let merged = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-merged.json")).first)
        #expect(GitHubRefreshPolicy.interval(for: .pullRequest(pending)) == .seconds(60))
        #expect(GitHubRefreshPolicy.interval(for: .pullRequest(passing)) == .seconds(300))
        #expect(GitHubRefreshPolicy.interval(for: .pullRequest(merged)) == .seconds(900))
        #expect(GitHubRefreshPolicy.interval(for: .noPullRequest(branch: "x", base: "main")) == .seconds(300))
        #expect(GitHubRefreshPolicy.interval(for: .needsCLI) == .seconds(600))
    }

    @Test func autoArchiveOnlyAfterAMergeWhileTheAgentIsIdle() throws {
        let merged = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-merged.json")).first)
        let open = try #require(try GitHubParsing.pullRequests(Fixtures.data("github/pr-list-passing.json")).first)
        var closed = open
        closed.state = .closed
        #if os(macOS)
        typealias C = GitHubPullRequestController
        #expect(C.shouldArchive(enabled: true, pullRequest: merged, agentWorking: false, alreadyArchived: false))
        #expect(!C.shouldArchive(enabled: false, pullRequest: merged, agentWorking: false, alreadyArchived: false), "off by default")
        #expect(!C.shouldArchive(enabled: true, pullRequest: merged, agentWorking: true, alreadyArchived: false))
        #expect(!C.shouldArchive(enabled: true, pullRequest: merged, agentWorking: false, alreadyArchived: true))
        #expect(!C.shouldArchive(enabled: true, pullRequest: open, agentWorking: false, alreadyArchived: false))
        #expect(!C.shouldArchive(enabled: true, pullRequest: closed, agentWorking: false, alreadyArchived: false))
        #expect(!C.shouldArchive(enabled: true, pullRequest: nil, agentWorking: false, alreadyArchived: false))
        #endif
    }

    @Test func branchNamesFromSessionTitles() {
        #if os(macOS)
        #expect(GitHubPullRequestController.suggestedBranchName(title: "Fix the README!") == "ensemble/fix-the-readme")
        #expect(GitHubPullRequestController.suggestedBranchName(title: "  ") == "ensemble/changes")
        #expect(GitHubPullRequestController.suggestedBranchName(title: "Café: über cool") == "ensemble/caf-ber-cool")
        let long = GitHubPullRequestController.suggestedBranchName(title: String(repeating: "word ", count: 20))
        #expect(long.count <= "ensemble/".count + 40 && !long.hasSuffix("-"))
        #endif
    }
}
