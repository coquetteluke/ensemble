import Foundation
import Observation

/// The per-session "Archive after merge" switch (default off), kept in user defaults.
@MainActor
public final class GitHubAutoArchiveSetting {
    public static let shared = GitHubAutoArchiveSetting()
    public static let key = "githubAutoArchiveSessions"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isOn(_ sessionID: String) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(sessionID)
    }

    public func set(_ on: Bool, for sessionID: String) {
        var ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
        if on { ids.insert(sessionID) } else { ids.remove(sessionID) }
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}

/// What the pull request bar needs from the rest of the app for one session.
public struct GitHubSessionHooks {
    /// The session's folder.
    public var directory: @MainActor () -> String
    /// The session's title (the first guess for a branch name and a pull request title).
    public var sessionTitle: @MainActor () -> String
    /// Sends a message to the session's agent; held in the session's queue while the agent works.
    public var send: @MainActor (String) async -> Void
    public var isAgentWorking: @MainActor () -> Bool
    /// Archives the session.
    public var archive: @MainActor () async -> Void
    /// Asks a hidden copy of the session for a pull request title and description.
    public var draftDescription: @MainActor (GitHubPullRequestContext) async throws -> GitHubPullRequestText

    public init(directory: @escaping @MainActor () -> String, sessionTitle: @escaping @MainActor () -> String,
                send: @escaping @MainActor (String) async -> Void, isAgentWorking: @escaping @MainActor () -> Bool,
                archive: @escaping @MainActor () async -> Void,
                draftDescription: @escaping @MainActor (GitHubPullRequestContext) async throws -> GitHubPullRequestText) {
        self.directory = directory
        self.sessionTitle = sessionTitle
        self.send = send
        self.isAgentWorking = isAgentWorking
        self.archive = archive
        self.draftDescription = draftDescription
    }

    /// Does nothing; for snapshots.
    public static func inert(directory: String = "", title: String = "") -> GitHubSessionHooks {
        GitHubSessionHooks(directory: { directory }, sessionTitle: { title }, send: { _ in }, isAgentWorking: { false },
                           archive: {}, draftDescription: { _ in GitHubPullRequestText(title: title, body: "") })
    }
}

/// Work the bar is doing, for spinners and disabled buttons.
public enum GitHubBusy: Hashable, Sendable {
    case pushing, creatingPullRequest, creatingBranch, writingDescription, merging, fixing
}

/// The Create pull request form.
public struct GitHubPullRequestForm: Hashable, Sendable {
    public var title: String
    public var body: String
    public var draft: Bool
    public var base: String
    public var head: String
    public var remote: GitHubRemote

    public init(title: String, body: String = "", draft: Bool = false, base: String, head: String, remote: GitHubRemote) {
        self.title = title
        self.body = body
        self.draft = draft
        self.base = base
        self.head = head
        self.remote = remote
    }

    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
}

#if os(macOS)
/// State and actions of one session's pull request bar: the gh sign-in, the folder's branch, the branch's
/// pull request and its checks, Create branch, Create pull request (with Write description), Push, Fix failing
/// checks, Merge when ready, and archiving the session once its pull request is merged.
///
/// Every outward step (push, open a pull request, turn on auto-merge) first sets `confirmation`, whose text
/// names the remote, branch and repository; nothing leaves the Mac until `confirm()` runs.
@Observable @MainActor
public final class GitHubPullRequestController {
    public let sessionID: String
    public private(set) var state: GitHubBarState = .loading
    public private(set) var local: GitHubLocalRepo?
    public private(set) var cli: GitHubCLIStatus?
    public private(set) var repoInfo: GitHubRepoInfo?
    public private(set) var busy: Set<GitHubBusy> = []
    public private(set) var isRefreshing = false
    /// The last action that failed, in a line.
    public var actionError: String?
    /// A line after an action worked ("Opened #12").
    public var notice: String?
    /// An outward step waiting for the person's yes.
    public var confirmation: GitHubConfirmation?
    /// The Create pull request form, while it is open.
    public var form: GitHubPullRequestForm?
    /// Why Write description or opening the pull request failed, shown in the form.
    public var formError: String?
    /// The Create branch name, while that field is open.
    public var branchName: String?
    /// The person closed the note (gh missing, signed out, an error) for this session.
    public var isDismissed = false
    /// Archive the session once its pull request is merged.
    public var autoArchive: Bool {
        didSet { if autoArchive != oldValue { setting.set(autoArchive, for: sessionID) } }
    }
    /// Set once the session was archived after its merge.
    public private(set) var archivedAfterMerge = false

    @ObservationIgnored public let hooks: GitHubSessionHooks
    /// Nil in snapshots and previews: nothing runs.
    @ObservationIgnored public let service: GitHubService?
    @ObservationIgnored let setting: GitHubAutoArchiveSetting
    @ObservationIgnored private var cliCheckedAt: Date?
    @ObservationIgnored private var repoInfoCheckedAt: Date?
    @ObservationIgnored private var lastPullRequest: GitHubPullRequest?
    @ObservationIgnored private var generation = 0

    public init(sessionID: String, hooks: GitHubSessionHooks, service: GitHubService? = GitHubService(),
                setting: GitHubAutoArchiveSetting = .shared) {
        self.sessionID = sessionID
        self.hooks = hooks
        self.service = service
        self.setting = setting
        self.autoArchive = setting.isOn(sessionID)
    }

    /// A controller showing a ready-made state; nothing runs. For snapshots and previews.
    public static func preview(state: GitHubBarState, local: GitHubLocalRepo? = nil, cli: GitHubCLIStatus? = nil,
                               repoInfo: GitHubRepoInfo? = nil, autoArchive: Bool = false, busy: Set<GitHubBusy> = [],
                               notice: String? = nil, actionError: String? = nil, form: GitHubPullRequestForm? = nil,
                               branchName: String? = nil, hooks: GitHubSessionHooks = .inert()) -> GitHubPullRequestController {
        let setting = GitHubAutoArchiveSetting(defaults: UserDefaults(suiteName: "ensemble-github-preview") ?? .standard)
        let controller = GitHubPullRequestController(sessionID: "preview", hooks: hooks, service: nil, setting: setting)
        controller.state = state
        controller.local = local
        controller.cli = cli
        controller.repoInfo = repoInfo
        controller.autoArchive = autoArchive
        controller.busy = busy
        controller.notice = notice
        controller.actionError = actionError
        controller.form = form
        controller.branchName = branchName
        return controller
    }

    // MARK: Derived

    public var isVisible: Bool { state.isVisible && !(isDismissed && state.isDismissible) }

    /// Pushing the branch as it is now, or nil when the remote already has every commit.
    public var pushPlan: GitHubPushPlan? {
        guard let local, let branch = local.branch, let remoteName = local.remoteName, let remote = local.remote else { return nil }
        if local.published, (local.unpushed ?? 0) == 0 { return nil }
        return GitHubPushPlan(root: local.root, remoteName: remoteName, branch: branch, remote: remote,
                              commits: local.published ? local.unpushed : nil)
    }

    /// Why Create pull request cannot run now, or nil when it can.
    public var createUnavailableReason: String? {
        guard case .noPullRequest(_, let base) = state else { return "Not available" }
        if let ahead = local?.ahead, ahead == 0 { return "No commits ahead of \(base ?? "the default branch") yet" }
        return nil
    }

    public var pullRequestURL: URL? {
        guard let pr = state.pullRequest, let host = local?.remote?.host, GitHubParsing.isWebLink(pr.url, on: host) else { return nil }
        return URL(string: pr.url)
    }

    // MARK: Refresh

    /// Re-reads everything while the bar is on screen, then waits as long as `GitHubRefreshPolicy` says.
    /// Ends when the task is cancelled (the bar left the screen).
    public func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: GitHubRefreshPolicy.interval(for: state))
        }
    }

    /// Reads the folder's git facts and, with `network`, gh's sign-in, the repository and the branch's pull
    /// request. Without `network` the last pull request is kept (used when the agent's turn ends). `force`
    /// asks gh again even when its last answers are recent.
    public func refresh(network: Bool = true, force: Bool = false) async {
        guard let service else { return }
        generation += 1
        let current = generation
        isRefreshing = true
        defer { if current == generation { isRefreshing = false } }
        if force {
            cliCheckedAt = nil
            repoInfoCheckedAt = nil
        }
        let directory = hooks.directory()
        var local = await service.localRepository(directory, baseHint: repoInfo?.defaultBranch)
        guard current == generation else { return }
        guard let found = local, found.remoteName != nil, let remote = found.remote else {
            apply(local: local, pullRequest: nil, error: nil)
            return
        }
        let now = Date()
        if cli == nil || cliCheckedAt.map({ now.timeIntervalSince($0) > GitHubRefreshPolicy.signInLifetime }) ?? true {
            let status = await service.cliStatus()
            guard current == generation else { return }
            cli = status
            cliCheckedAt = now
        }
        guard GitHubParsing.isGitHubHost(remote.host, signedInHosts: cli?.signedInHosts ?? []),
              cli?.account(on: remote.host) != nil else {
            apply(local: local, pullRequest: nil, error: nil)
            return
        }

        var lookupError: String?
        let repoStale = repoInfoCheckedAt.map { now.timeIntervalSince($0) > GitHubRefreshPolicy.repoInfoLifetime } ?? true
        let repoMoved = repoInfo.map { $0.nameWithOwner.lowercased() != remote.slug.lowercased() } ?? false
        if network, repoInfo == nil || repoStale || repoMoved {
            do {
                let info = try await service.repoInfo(remote)
                guard current == generation else { return }
                repoInfo = info
                repoInfoCheckedAt = now
                if found.defaultBranch == nil, let base = info.defaultBranch {
                    local = await service.localRepository(directory, baseHint: base)
                    guard current == generation else { return }
                }
            } catch {
                lookupError = error.localizedDescription
            }
        }

        var pullRequest: GitHubPullRequest?
        if let branch = local?.branch, branch != local?.defaultBranch {
            if network {
                do {
                    pullRequest = try await service.pullRequest(branch: branch, remote: remote)
                    lookupError = nil
                } catch {
                    lookupError = error.localizedDescription
                }
                guard current == generation else { return }
            } else if let last = lastPullRequest, last.headRefName == branch {
                pullRequest = last
                lookupError = nil
            }
        }
        apply(local: local, pullRequest: pullRequest, error: lookupError)
        await archiveIfMerged()
    }

    private func apply(local: GitHubLocalRepo?, pullRequest: GitHubPullRequest?, error: String?) {
        self.local = local
        lastPullRequest = pullRequest
        let next = GitHubBarState.derive(local: local, cli: cli, defaultBranch: local?.defaultBranch, pullRequest: pullRequest,
                                         lookupError: error)
        if !next.isDismissible { isDismissed = false }
        state = next
    }

    /// Archives the session when the switch is on, its pull request is merged and its agent is not working.
    func archiveIfMerged() async {
        guard Self.shouldArchive(enabled: autoArchive, pullRequest: state.pullRequest, agentWorking: hooks.isAgentWorking(),
                                 alreadyArchived: archivedAfterMerge) else { return }
        archivedAfterMerge = true
        await hooks.archive()
    }

    nonisolated public static func shouldArchive(enabled: Bool, pullRequest: GitHubPullRequest?, agentWorking: Bool, alreadyArchived: Bool) -> Bool {
        enabled && !alreadyArchived && !agentWorking && pullRequest?.state == .merged
    }

    // MARK: Create branch

    /// Opens the branch name field with a name made from the session title.
    public func beginCreateBranch() {
        branchName = Self.suggestedBranchName(title: hooks.sessionTitle())
    }

    /// Creates the branch from HEAD and switches the folder to it (changes come along). Local only.
    public func createBranch() async {
        guard let name = branchName?.trimmingCharacters(in: .whitespaces), !name.isEmpty, let root = local?.root,
              let service, !busy.contains(.creatingBranch) else { return }
        busy.insert(.creatingBranch)
        defer { busy.remove(.creatingBranch) }
        do {
            try await service.createBranch(name, root: root)
            branchName = nil
            actionError = nil
            notice = "Switched to \(name)"
        } catch {
            actionError = error.localizedDescription
        }
        await refresh()
    }

    /// "ensemble/fix-the-login-form" from a session title.
    nonisolated public static func suggestedBranchName(title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-"), !slug.isEmpty {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 40 {
            slug = String(slug.prefix(40))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return "ensemble/" + (slug.isEmpty ? "changes" : slug)
    }

    // MARK: Create pull request

    /// Opens the form with the session title (or the only commit's subject) as the title.
    public func beginPullRequest() async {
        guard case .noPullRequest(let branch, let base) = state, let local, let remote = local.remote else { return }
        let target = base ?? repoInfo?.defaultBranch ?? "main"
        let title = hooks.sessionTitle()
        form = GitHubPullRequestForm(title: title, base: target, head: branch, remote: remote)
        formError = nil
        guard let service else { return }
        let context = await service.pullRequestContext(local, base: target)
        if context.commits.count == 1, form?.title == title { form?.title = context.commits[0] }
    }

    public func cancelPullRequest() {
        form = nil
        formError = nil
    }

    /// Asks a hidden copy of the session for the title and description and puts them in the form.
    public func writeDescription() async {
        guard let form, let local, !busy.contains(.writingDescription) else { return }
        busy.insert(.writingDescription)
        defer { busy.remove(.writingDescription) }
        let context = await service?.pullRequestContext(local, base: form.base)
            ?? GitHubPullRequestContext(branch: form.head, base: form.base, commits: [], files: [])
        do {
            let text = try await hooks.draftDescription(context)
            self.form?.title = text.title
            self.form?.body = text.body
            formError = nil
        } catch {
            formError = "Could not write a description: \(error.localizedDescription)"
        }
    }

    /// Asks to push (when needed) and open the pull request in the form. A push that git would send anywhere but
    /// the repository shown is refused here, before any confirmation, and checked again when it runs.
    public func requestCreatePullRequest() async {
        guard let form, !form.trimmedTitle.isEmpty else { return }
        let request = GitHubPullRequestRequest(remote: form.remote, base: form.base, head: form.head, title: form.trimmedTitle,
                                               body: form.body.trimmingCharacters(in: .whitespacesAndNewlines), draft: form.draft)
        let push = pushPlan
        if let push, let service {
            do {
                try await service.verifyPushDestination(push)
            } catch {
                formError = error.localizedDescription
                return
            }
        }
        formError = nil
        confirmation = GitHubConfirmation(action: .createPullRequest(push: push, request: request))
    }

    // MARK: Push, merge, fix

    /// Asks to push the branch's new commits, after checking where git would send them.
    public func requestPush() async {
        guard let plan = pushPlan else { return }
        if let service {
            do {
                try await service.verifyPushDestination(plan)
            } catch {
                actionError = error.localizedDescription
                return
            }
        }
        confirmation = GitHubConfirmation(action: .push(plan))
    }

    /// Asks to turn on auto-merge with the repository's allowed method.
    public func requestMerge() async {
        guard let pr = state.pullRequest, pr.isOpen, let local, let remote = local.remote else { return }
        if repoInfo == nil, let service {
            repoInfo = try? await service.repoInfo(remote)
        }
        guard let method = repoInfo?.mergeMethod else {
            actionError = "Could not read which merge methods \(remote.slug) allows"
            return
        }
        confirmation = GitHubConfirmation(action: .merge(number: pr.number, method: method, remote: remote, base: pr.baseRefName))
    }

    public func cancelConfirmation() {
        confirmation = nil
    }

    /// Runs the confirmed step.
    public func confirm() async {
        guard let confirmation, let service else { return }
        self.confirmation = nil
        switch confirmation.action {
        case .push(let plan):
            busy.insert(.pushing)
            defer { busy.remove(.pushing) }
            do {
                try await service.push(plan)
                actionError = nil
                notice = "Pushed \(plan.branch) to \(plan.remoteName)"
            } catch {
                actionError = error.localizedDescription
            }
        case .createPullRequest(let push, let request):
            busy.insert(.creatingPullRequest)
            defer { busy.remove(.creatingPullRequest) }
            do {
                if let push { try await service.push(push) }
                let created = try await service.createPullRequest(request)
                form = nil
                formError = nil
                actionError = nil
                notice = "Opened #\(created.number)"
            } catch {
                formError = error.localizedDescription
                if form == nil { actionError = error.localizedDescription }
            }
        case .merge(let number, let method, let remote, _):
            busy.insert(.merging)
            defer { busy.remove(.merging) }
            do {
                try await service.enableAutoMerge(number: number, method: method, remote: remote)
                actionError = nil
                notice = "Auto-merge is on for #\(number)"
            } catch {
                actionError = error.localizedDescription
            }
        }
        await refresh()
    }

    /// Turns auto-merge off again (no confirmation: it only stops a merge).
    public func disableAutoMerge() async {
        guard let pr = state.pullRequest, pr.autoMergeEnabled, let local, let remote = local.remote, let service,
              !busy.contains(.merging) else { return }
        busy.insert(.merging)
        defer { busy.remove(.merging) }
        do {
            try await service.disableAutoMerge(number: pr.number, remote: remote)
            actionError = nil
            notice = "Auto-merge is off for #\(pr.number)"
        } catch {
            actionError = error.localizedDescription
        }
        await refresh()
    }

    /// Fetches the failed runs' logs and sends them to the agent as one message (queued while it works).
    public func fixFailingChecks() async {
        guard let pr = state.pullRequest, !pr.failingChecks.isEmpty, let local, let remote = local.remote,
              let service, !busy.contains(.fixing) else { return }
        busy.insert(.fixing)
        defer { busy.remove(.fixing) }
        let logs = await service.failedLogs(for: pr.failingChecks, remote: remote)
        let message = GitHubParsing.fixChecksMessage(pullRequest: pr, logs: logs)
        let waiting = hooks.isAgentWorking()
        await hooks.send(message)
        actionError = nil
        notice = waiting ? "Queued the failed logs until the agent's turn ends" : "Sent the failed logs to the agent"
    }
}
#endif
