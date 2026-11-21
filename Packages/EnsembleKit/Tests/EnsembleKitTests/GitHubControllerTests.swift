#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The pull request bar's controller end to end: a real repository whose origin pushes to a local bare
/// repository, the fake gh, and hooks that record what would go to the session. Nothing reaches GitHub.
@Suite @MainActor struct GitHubControllerTests {
    /// What the hooks saw.
    final class Recorder {
        var sent: [String] = []
        var archived = 0
        var working = false
        var drafted: [GitHubPullRequestContext] = []
    }

    func hooks(_ repo: URL, _ recorder: Recorder, title: String = "Fix the README") -> GitHubSessionHooks {
        GitHubSessionHooks(
            directory: { repo.path }, sessionTitle: { title },
            send: { recorder.sent.append($0) }, isAgentWorking: { recorder.working },
            archive: { recorder.archived += 1 },
            draftDescription: { context in
                recorder.drafted.append(context)
                return GitHubPullRequestText(title: "Fix the README name", body: "Renames the app in the README.")
            })
    }

    func setting() -> GitHubAutoArchiveSetting {
        GitHubAutoArchiveSetting(defaults: InMemoryDefaults())
    }

    // MARK: The whole flow

    @Test func defaultBranchToMergedWithEveryOutwardStepConfirmedFirst() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        let git = repo.loggingGit
        let recorder = Recorder()
        let service = repo.service(gh)
        let controller = GitHubPullRequestController(sessionID: "ses_1", hooks: hooks(repo.work, recorder), service: service,
                                                     setting: setting())
        #expect(controller.state == .loading && !controller.isVisible)
        #expect(!controller.autoArchive, "auto-archive is off by default")

        // On main: Create branch first.
        await controller.refresh()
        #expect(controller.state == .defaultBranch(branch: "main"))
        #expect(gh.calls("pr", "list").isEmpty, "no pull request lookup on the default branch")
        controller.beginCreateBranch()
        #expect(controller.branchName == "ensemble/fix-the-readme")
        await controller.createBranch()
        #expect(controller.state == .noPullRequest(branch: "ensemble/fix-the-readme", base: "main"))
        #expect(controller.createUnavailableReason == "No commits ahead of main yet")

        // The agent commits; the turn ends.
        try repo.commit("README.md", "Ensemble\n", message: "Name the app in the README")
        await controller.refresh(network: false)
        #expect(controller.local?.ahead == 1 && controller.createUnavailableReason == nil)

        // Create pull request: the form, Write description, then a confirmation before anything is pushed.
        await controller.beginPullRequest()
        #expect(controller.form?.title == "Name the app in the README", "one commit: its subject is the title")
        #expect(controller.form?.base == "main" && controller.form?.head == "ensemble/fix-the-readme")
        await controller.writeDescription()
        #expect(controller.form?.title == "Fix the README name" && controller.form?.body == "Renames the app in the README.")
        #expect(recorder.drafted.first?.commits == ["Name the app in the README"])
        #expect(recorder.drafted.first?.files.map(\.path) == ["README.md"])
        await controller.requestCreatePullRequest()
        let confirmation = try #require(controller.confirmation)
        #expect(confirmation.message.contains("ensemble/fix-the-readme") && confirmation.message.contains("origin")
            && confirmation.message.contains("acme/widgets"))
        #expect(repo.remoteHead("ensemble/fix-the-readme") == nil, "nothing is pushed before the confirmation")
        #expect(gh.calls("pr", "create").isEmpty)

        controller.cancelConfirmation()
        #expect(controller.confirmation == nil && repo.remoteHead("ensemble/fix-the-readme") == nil)

        try gh.respond("pr_create", fixture: "pr-create.txt")
        try gh.respond("pr_list", fixture: "pr-list-pending.json")
        await controller.requestCreatePullRequest()
        await controller.confirm()
        #expect(repo.remoteHead("ensemble/fix-the-readme") != nil, "pushed (through the stand-in ssh) to the bare remote")
        #expect(git.sshLog() == ["git@github.com git-receive-pack 'acme/widgets.git'"])
        #expect(gh.calls("pr", "create").count == 1)
        #expect(controller.form == nil && controller.notice == "Opened #42")

        // Pending checks: refreshed every minute.
        guard case .pullRequest(let pending) = controller.state else {
            Issue.record("expected a pull request, got \(controller.state)")
            return
        }
        #expect(pending.checkSummary.overall == .pending)
        #expect(GitHubRefreshPolicy.interval(for: controller.state) == .seconds(60))
        #expect(controller.pushPlan == nil, "everything is pushed")

        // Failing checks: Fix sends one message with the trimmed log.
        try gh.respond("pr_list", fixture: "pr-list-failing.json")
        try gh.respond("run_view_1001", fixture: "run-log-failed.txt")
        await controller.refresh()
        #expect(controller.state.pullRequest?.checkSummary.overall == .failing)
        await controller.fixFailingChecks()
        #expect(recorder.sent.count == 1)
        #expect(recorder.sent[0].contains("CI / test") && recorder.sent[0].contains("expected \"Ensemble\""))
        #expect(controller.notice == "Sent the failed logs to the agent")
        recorder.working = true
        await controller.fixFailingChecks()
        #expect(recorder.sent.count == 2 && controller.notice == "Queued the failed logs until the agent's turn ends")
        recorder.working = false

        // The agent's fix is committed: Push asks first.
        try repo.commit("README.md", "Ensemble app\n", message: "Fix the test")
        await controller.refresh(network: false)
        #expect(controller.state.pullRequest != nil, "the last pull request is kept without a network refresh")
        let plan = try #require(controller.pushPlan)
        #expect(plan.commits == 1)
        await controller.requestPush()
        #expect(controller.confirmation?.title == "Push ensemble/fix-the-readme to origin?")
        let before = repo.remoteHead("ensemble/fix-the-readme")
        await controller.confirm()
        #expect(repo.remoteHead("ensemble/fix-the-readme") != before)

        // Passing: Merge when ready asks first, with the repository's method.
        try gh.respond("pr_list", fixture: "pr-list-passing.json")
        await controller.refresh()
        await controller.requestMerge()
        #expect(controller.confirmation?.title == "Merge #42 when ready?")
        #expect(gh.calls("pr", "merge").isEmpty, "nothing merged before the confirmation")
        try gh.respond("pr_list", fixture: "pr-list-auto-merge.json")
        await controller.confirm()
        #expect(gh.calls("pr", "merge") == [["pr", "merge", "42", "--repo", "acme/widgets", "--auto", "--squash"]])
        #expect(controller.state.pullRequest?.autoMergeEnabled == true)

        // Merged with auto-archive on: archived once the agent is idle, and only once.
        controller.autoArchive = true
        try gh.respond("pr_list", fixture: "pr-list-merged.json")
        recorder.working = true
        await controller.refresh()
        #expect(recorder.archived == 0, "not while the agent works")
        recorder.working = false
        await controller.refresh(network: false)
        #expect(recorder.archived == 1)
        await controller.refresh()
        #expect(recorder.archived == 1)

        // Safety: every gh and git command line Ensemble ran.
        #expect(gh.calls().allSatisfy(isSafeCommand))
        #expect(gh.calls().allSatisfy { GitHubCommandPolicy.ghViolation($0) == nil })
        #expect(git.calls().allSatisfy(isSafeCommand))
        let pushes = git.pushes()
        #expect(pushes.count == 2)
        #expect(pushes.allSatisfy { $0.suffix(4) == ["push", "--set-upstream", "origin",
                                                      "refs/heads/ensemble/fix-the-readme:refs/heads/ensemble/fix-the-readme"] })
        #expect(git.sshLog().allSatisfy { $0 == "git@github.com git-receive-pack 'acme/widgets.git'" })
        #expect(!gh.calls().contains { $0.starts(with: ["auth", "token"]) })
    }

    // MARK: Pull requests from forks

    /// `gh pr list --head` also returns forks' branches of the same name; none of them is shown, merged, fixed
    /// or archived on.
    @Test func aSameNamedBranchFromAnotherForkIsNeverPickedMergedOrArchived() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try gh.respond("run_view_1001", fixture: "run-log-failed.txt")
        try gh.respond("pr_list", fixture: "pr-list-fork-same-name.json")
        try repo.git(["switch", "-q", "-c", "ensemble/fix-the-readme"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let recorder = Recorder()
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, recorder), service: repo.service(gh),
                                                     setting: setting())
        controller.autoArchive = true
        await controller.refresh()
        #expect(controller.state == .noPullRequest(branch: "ensemble/fix-the-readme", base: "main"))
        await controller.fixFailingChecks()
        await controller.requestMerge()
        await controller.refresh(network: false)
        #expect(controller.confirmation == nil && recorder.sent.isEmpty && recorder.archived == 0)
        #expect(gh.calls("pr", "merge").isEmpty && gh.calls("run", "view").isEmpty)

        try gh.respond("pr_list", fixture: "pr-list-mixed.json")
        await controller.refresh()
        #expect(controller.state.pullRequest?.number == 42, "the branch's own pull request, not the newer one from the fork")
    }

    /// The match is checked again right before each action, so a pull request that stopped matching is left alone.
    @Test func everyActionRechecksThatThePullRequestStillMatches() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try gh.respond("run_view_1001", fixture: "run-log-failed.txt")
        try repo.git(["switch", "-q", "-c", "ensemble/fix-the-readme"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let recorder = Recorder()
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, recorder), service: repo.service(gh),
                                                     setting: setting())

        // Fix failing checks.
        try gh.respond("pr_list", fixture: "pr-list-failing.json")
        await controller.refresh()
        #expect(controller.state.pullRequest?.number == 42)
        try gh.respond("pr_list", fixture: "pr-list-fork-same-name.json")
        await controller.fixFailingChecks()
        #expect(recorder.sent.isEmpty && gh.calls("run", "view").isEmpty)
        #expect(controller.actionError == GitHubPullRequestController.mismatch)

        // Merge when ready: refused at the request, and again at the confirmation.
        try gh.respond("pr_list", fixture: "pr-list-passing.json")
        await controller.refresh()
        try gh.respond("pr_list", fixture: "pr-list-fork-same-name.json")
        await controller.requestMerge()
        #expect(controller.confirmation == nil)
        try gh.respond("pr_list", fixture: "pr-list-passing.json")
        await controller.refresh()
        await controller.requestMerge()
        #expect(controller.confirmation != nil)
        try gh.respond("pr_list", fixture: "pr-list-fork-same-name.json")
        await controller.confirm()
        #expect(gh.calls("pr", "merge").isEmpty && controller.actionError == GitHubPullRequestController.mismatch)

        // The push destination changes after the bar showed the pull request.
        try gh.respond("pr_list", fixture: "pr-list-failing.json")
        await controller.refresh()
        try repo.git(["config", "remote.origin.pushurl", "git@github.com:evil/widgets.git"])
        await controller.fixFailingChecks()
        #expect(recorder.sent.isEmpty && controller.actionError == GitHubPullRequestController.mismatch)
        try repo.git(["config", "--unset-all", "remote.origin.pushurl"])

        // Auto-archive.
        try gh.respond("pr_list", fixture: "pr-list-merged.json")
        await controller.refresh()
        #expect(controller.state.pullRequest?.state == .merged)
        controller.autoArchive = true
        try gh.respond("pr_list", fixture: "pr-list-fork-same-name.json")
        await controller.refresh(network: false)
        #expect(recorder.archived == 0, "not archived on a pull request that no longer matches")
        try gh.respond("pr_list", fixture: "pr-list-merged.json")
        await controller.refresh(network: false)
        #expect(recorder.archived == 1)
        #expect(gh.calls().allSatisfy(isSafeCommand))
    }

    /// Pushed to your fork: the fork is the head and its parent the base.
    @Test func aBranchInAForkOpensItsPullRequestInTheParent() async throws {
        let repo = try GitHubTestRepo(remoteURL: "git@github.com:octocat/widgets.git")
        let gh = try FakeGH()
        try gh.signedIn()
        try gh.respond("repo_view_octocat_widgets", fixture: "repo-view-fork.json")
        try gh.respond("repo_view_acme_widgets", fixture: "repo-view.json")
        try gh.respond("pr_create", out: "https://github.com/acme/widgets/pull/51\n")
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: repo.service(gh),
                                                     setting: setting())
        await controller.refresh()
        #expect(controller.headRepository?.slug == "octocat/widgets" && controller.baseRepository?.slug == "acme/widgets")
        #expect(controller.state == .noPullRequest(branch: "feature", base: "main"))
        #expect(gh.calls("pr", "list").last?.starts(with: ["pr", "list", "--repo", "acme/widgets", "--head", "feature"]) == true)

        await controller.beginPullRequest()
        #expect(controller.form?.remote.slug == "acme/widgets" && controller.form?.headRemote?.slug == "octocat/widgets")
        await controller.requestCreatePullRequest()
        let message = try #require(controller.confirmation?.message)
        #expect(message.contains("Pushes feature to origin (octocat/widgets on github.com)"))
        #expect(message.contains("in acme/widgets from octocat:feature into main"))
        try gh.respond("pr_list", fixture: "pr-list-from-fork.json")
        await controller.confirm()
        #expect(repo.loggingGit.sshLog() == ["git@github.com git-receive-pack 'octocat/widgets.git'"], "pushed to the fork")
        #expect(gh.calls("pr", "create").last?.prefix(8) == ["pr", "create", "--repo", "acme/widgets", "--base", "main",
                                                             "--head", "octocat:feature"])
        #expect(controller.state.pullRequest?.number == 51, "the fork's own pull request, not another fork's same-named branch")
    }

    @Test func autoArchiveIsRememberedPerSession() {
        let setting = setting()
        let hooks = GitHubSessionHooks.inert()
        let a = GitHubPullRequestController(sessionID: "a", hooks: hooks, service: nil, setting: setting)
        a.autoArchive = true
        #expect(GitHubPullRequestController(sessionID: "a", hooks: hooks, service: nil, setting: setting).autoArchive)
        #expect(!GitHubPullRequestController(sessionID: "b", hooks: hooks, service: nil, setting: setting).autoArchive)
        a.autoArchive = false
        #expect(!GitHubPullRequestController(sessionID: "a", hooks: hooks, service: nil, setting: setting).autoArchive)
    }

    // MARK: States without a pull request

    @Test func noGHSignedOutNoRemoteAndOtherHosts() async throws {
        let repo = try GitHubTestRepo()
        try repo.git(["switch", "-q", "-c", "feature"])
        let recorder = Recorder()

        let noGH = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, recorder),
                                               service: GitHubService(locateGH: { nil }, isTrusted: { _ in true }), setting: setting())
        await noGH.refresh()
        #expect(noGH.state == .needsCLI && noGH.isVisible)
        noGH.isDismissed = true
        #expect(!noGH.isVisible, "the note can be closed")

        let gh = try FakeGH()
        try gh.respond("auth_status", err: "You are not logged into any GitHub hosts.\n")
        let signedOut = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, recorder), service: gh.service,
                                                    setting: setting())
        await signedOut.refresh()
        #expect(signedOut.state == .signedOut(host: "github.com", problem: nil))
        #expect(gh.calls("pr", "list").isEmpty && gh.calls("repo", "view").isEmpty)

        let local = try GitReviewServiceTests().makeRepo()
        let noRemote = GitHubPullRequestController(sessionID: "s", hooks: hooks(local, recorder), service: gh.service, setting: setting())
        await noRemote.refresh()
        #expect(noRemote.state == .hidden(.noRemote) && !noRemote.isVisible)

        let plain = try GitHubFolders.make("ensemble-plain")
        let notRepo = GitHubPullRequestController(sessionID: "s", hooks: hooks(plain, recorder), service: gh.service, setting: setting())
        await notRepo.refresh()
        #expect(notRepo.state == .hidden(.notRepository))

        let gitlab = try GitReviewServiceTests().makeRepo()
        try GitReviewServiceTests().git(["remote", "add", "origin", "git@gitlab.com:acme/widgets.git"], in: gitlab)
        let other = GitHubPullRequestController(sessionID: "s", hooks: hooks(gitlab, recorder), service: gh.service, setting: setting())
        await other.refresh()
        #expect(other.state == .hidden(.notGitHub))
        #expect(gh.calls().allSatisfy(isSafeCommand))
    }

    @Test func lookupFailuresShowAsAFailedBar() async throws {
        let repo = try GitHubTestRepo()
        try repo.git(["switch", "-q", "-c", "feature"])
        let gh = try FakeGH()
        try gh.signedIn()
        try gh.respond("pr_list", err: "HTTP 502: Server Error\n", code: 1)
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: gh.service,
                                                     setting: setting())
        await controller.refresh()
        #expect(controller.state == .failed("HTTP 502: Server Error"))
        try gh.respond("pr_list", fixture: "pr-list-empty.json")
        await controller.refresh()
        #expect(controller.state == .noPullRequest(branch: "feature", base: "main"))
    }

    @Test func theDefaultBranchComesFromGitHubWhenTheFolderDoesNotKnowIt() async throws {
        let repo = try GitHubTestRepo(setHead: false)
        let gh = try FakeGH()
        try gh.signedIn()
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: gh.service,
                                                     setting: setting())
        await controller.refresh()
        #expect(controller.state == .defaultBranch(branch: "main"))
        #expect(gh.calls("repo", "view").count == 1)
        await controller.refresh()
        #expect(gh.calls("repo", "view").count == 1, "the repository's settings are reused")
        await controller.refresh(force: true)
        #expect(gh.calls("repo", "view").count == 2)
    }

    /// A push URL naming another repository than the fetch URL is refused before any confirmation, unless it is
    /// your own fork of the fetch repository.
    @Test func aPushURLToAnUnrelatedRepositoryOrSomeoneElsesForkIsRefused() async throws {
        let cases: [(pushURL: String, slug: String, fixture: String)] = [
            ("git@github.com:evil/widgets.git", "evil/widgets", "repo-view-evil.json"),
            ("git@github.com:mallory/widgets.git", "mallory/widgets", "repo-view-fork-mallory.json"),
        ]
        for item in cases {
            let repo = try GitHubTestRepo()
            let gh = try FakeGH()
            try gh.signedIn()
            try gh.respond("repo_view_" + item.slug.replacingOccurrences(of: "/", with: "_"), fixture: item.fixture)
            try repo.git(["config", "remote.origin.pushurl", item.pushURL])
            try repo.git(["switch", "-q", "-c", "feature"])
            try repo.commit("a.txt", "a\n", message: "Add a")
            let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: repo.service(gh),
                                                         setting: setting())
            await controller.refresh()
            let expected = "origin fetches from acme/widgets but pushes to \(item.slug). Ensemble pushes only to the repository "
                + "a branch comes from, or to your own fork of it."
            #expect(controller.state == .failed(expected), "\(item.slug)")
            #expect(gh.calls("pr", "list").isEmpty, "\(item.slug): nothing is looked up for a refused push repository")
            await controller.requestPush()
            #expect(controller.confirmation == nil && controller.actionError == expected, "\(item.slug)")
            #expect(repo.loggingGit.pushes().isEmpty && repo.loggingGit.sshLog().isEmpty && gh.calls("pr", "create").isEmpty)
        }
    }

    @Test func aPushURLToYourOwnForkOfTheRepositoryIsAllowed() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try gh.respond("repo_view_octocat_widgets", fixture: "repo-view-fork.json")
        try gh.respond("repo_view_acme_widgets", fixture: "repo-view.json")
        try gh.respond("pr_create", out: "https://github.com/acme/widgets/pull/51\n")
        try repo.git(["config", "remote.origin.pushurl", "git@github.com:octocat/widgets.git"])
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: repo.service(gh),
                                                     setting: setting())
        await controller.refresh()
        #expect(controller.state == .noPullRequest(branch: "feature", base: "main"))
        #expect(controller.headRepository?.slug == "octocat/widgets" && controller.baseRepository?.slug == "acme/widgets")
        await controller.beginPullRequest()
        await controller.requestCreatePullRequest()
        #expect(controller.confirmation?.message.contains("to origin (octocat/widgets on github.com)") == true)
        await controller.confirm()
        #expect(repo.loggingGit.sshLog() == ["git@github.com git-receive-pack 'octocat/widgets.git'"])
        #expect(gh.calls("pr", "create").last?.prefix(8) == ["pr", "create", "--repo", "acme/widgets", "--base", "main",
                                                             "--head", "octocat:feature"])
    }

    @Test func pushURLsThatDisagreeOfferNoPush() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try repo.git(["config", "--add", "remote.origin.pushurl", "git@github.com:acme/widgets.git"])
        try repo.git(["config", "--add", "remote.origin.pushurl", "git@github.com:evil/widgets.git"])
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: repo.service(gh),
                                                     setting: setting())
        await controller.refresh()
        #expect(controller.state == .failed("origin pushes to both acme/widgets and evil/widgets"))
        #expect(controller.pushPlan == nil)
        #expect(repo.loggingGit.pushes().isEmpty && gh.calls("pr", "create").isEmpty)
    }

    @Test func configChangedAfterTheConfirmationIsCheckedAgain() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: repo.service(gh),
                                                     setting: setting())
        await controller.refresh()
        await controller.beginPullRequest()
        await controller.requestCreatePullRequest()
        #expect(controller.confirmation != nil)
        // Something rewrites the push URL while the confirmation is on screen.
        try repo.git(["config", "url./tmp/elsewhere/.pushInsteadOf", "git@github.com:acme/"])
        await controller.confirm()
        #expect(controller.form != nil && controller.formError?.contains("/tmp/elsewhere/widgets.git") == true)
        #expect(repo.loggingGit.pushes().isEmpty && repo.remoteHead("feature") == nil)
        #expect(gh.calls("pr", "create").isEmpty, "no pull request without the push")
    }

    @Test func untrustedFoldersRunNoGitOrGHAtAll() async throws {
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try repo.git(["switch", "-q", "-c", "feature"])
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()),
                                                     service: repo.service(gh, trusted: false), setting: setting())
        await controller.refresh()
        #expect(controller.state == .hidden(.untrusted) && !controller.isVisible)
        #expect(repo.loggingGit.calls().isEmpty && gh.calls().isEmpty)
    }

    /// Trust taken away while the bar is on screen: the push is refused before any confirmation.
    @Test func aFolderNoLongerTrustedDoesNotPush() async throws {
        final class Trust: @unchecked Sendable { var trusted = true }
        let trust = Trust()
        let repo = try GitHubTestRepo()
        let gh = try FakeGH()
        try gh.signedIn()
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.commit("a.txt", "a\n", message: "Add a")
        let ghPath = gh.path
        let service = GitHubService(git: repo.loggingGit.runner, locateGH: { ghPath }, isTrusted: { _ in trust.trusted })
        let controller = GitHubPullRequestController(sessionID: "s", hooks: hooks(repo.work, Recorder()), service: service,
                                                     setting: setting())
        await controller.refresh()
        await controller.beginPullRequest()
        trust.trusted = false
        await controller.requestCreatePullRequest()
        #expect(controller.confirmation == nil && controller.formError?.contains("trusted") == true)
        #expect(repo.loggingGit.pushes().isEmpty)
    }

    // MARK: Fix failing checks goes through the session's queue

    @Test func fixFailingChecksQueuesWhileTheAgentWorks() async throws {
        let engine = PreviewEngine(delayScale: TestWait.longTurnScale)  // still working when the hook sends
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/github-demo", model: nil, permissionMode: .bypass)
        await store.send("Start a long turn", to: session.id)
        #expect(session.isWorking)
        let hooks = GitHubSessionHooks(directory: { session.directory }, sessionTitle: { session.title },
                                       send: { await store.send($0, to: session.id) }, isAgentWorking: { session.isWorking },
                                       archive: { await store.archive(session.id) }, draftDescription: { _ in
                                           GitHubPullRequestText(title: "", body: "")
                                       })
        await hooks.send("The checks failed")
        #expect(store.queue(for: session.id).map(\.text) == ["The checks failed"])
        await hooks.archive()
        #expect(session.info.archived)
        store.stopListening()
    }

    @Test func descriptionComesFromAHiddenCopyThatIsDeletedAfter() async throws {
        let engine = PreviewEngine(delayScale: 0.02)
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/github-demo", model: nil, permissionMode: .bypass)
        await store.send("Build the bar", to: session.id)
        try await waitUntil("the turn to end") { !session.isWorking }
        let itemsBefore = session.items
        let sidebarBefore = store.sidebarOrder.map(\.id)
        let context = GitHubPullRequestContext(branch: "ensemble/x", base: "main", commits: ["Add the bar"], files: [])
        let text = try await store.draftPullRequest(sessionID: session.id, directory: session.directory, context: context)
        #expect(!text.title.isEmpty && !text.title.contains("\n"))
        #expect(session.items == itemsBefore, "nothing was added to the session")
        #expect(store.sidebarOrder.map(\.id) == sidebarBefore, "the copy never showed in the sidebar")
        try await waitUntil("the copy to be deleted") { store.hiddenSessionIDs.isEmpty }
        store.stopListening()
    }
}
#endif
