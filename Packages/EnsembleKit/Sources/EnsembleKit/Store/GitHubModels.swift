import Foundation

// MARK: Repository

/// A GitHub repository named by a remote URL. Never holds credentials: a user name or password in the URL
/// is dropped when it is parsed (see `GitHubParsing.remote(fromURL:)`).
public struct GitHubRemote: Hashable, Sendable, Codable {
    public var host: String
    public var owner: String
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// "owner/name".
    public var slug: String { "\(owner)/\(name)" }
    /// The `--repo` value for gh: OWNER/REPO on github.com, HOST/OWNER/REPO on other hosts.
    public var repoArgument: String { host == "github.com" ? slug : "\(host)/\(slug)" }
    public var webURL: URL? { URL(string: "https://\(host)/\(owner)/\(name)") }

    /// The same repository (GitHub ignores case in host, owner and name).
    public func isSameRepository(as other: GitHubRemote) -> Bool {
        host.lowercased() == other.host.lowercased() && owner.lowercased() == other.owner.lowercased()
            && name.lowercased() == other.name.lowercased()
    }
}

/// What `gh repo view` says about the repository.
public struct GitHubRepoInfo: Hashable, Sendable {
    public var nameWithOwner: String
    public var url: String
    public var defaultBranch: String?
    public var squashAllowed: Bool
    public var mergeCommitAllowed: Bool
    public var rebaseAllowed: Bool
    /// The repository this one was forked from, when it is a fork. Pull requests from a fork go there.
    public var parent: GitHubRemote?
    /// The account or organisation that owns the repository.
    public var ownerLogin: String?

    public init(nameWithOwner: String, url: String, defaultBranch: String?, squashAllowed: Bool = true,
                mergeCommitAllowed: Bool = true, rebaseAllowed: Bool = true, parent: GitHubRemote? = nil, ownerLogin: String? = nil) {
        self.nameWithOwner = nameWithOwner
        self.url = url
        self.defaultBranch = defaultBranch
        self.squashAllowed = squashAllowed
        self.mergeCommitAllowed = mergeCommitAllowed
        self.rebaseAllowed = rebaseAllowed
        self.parent = parent
        self.ownerLogin = ownerLogin
    }

    /// The method Merge when ready uses: squash when the repository allows it, then a merge commit, then rebase.
    public var mergeMethod: GitHubMergeMethod? {
        if squashAllowed { return .squash }
        if mergeCommitAllowed { return .merge }
        if rebaseAllowed { return .rebase }
        return nil
    }
}

public enum GitHubMergeMethod: String, Hashable, Sendable, CaseIterable {
    case squash, merge, rebase

    public var flag: String { "--\(rawValue)" }
    /// "squash and merge", for the confirmation.
    public var label: String {
        switch self {
        case .squash: "squash and merge"
        case .merge: "merge with a merge commit"
        case .rebase: "rebase and merge"
        }
    }
}

// MARK: The gh command line tool

public struct GitHubAccount: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// gh checked the sign-in with GitHub and it works.
        case valid
        /// gh checked it and GitHub refused it.
        case invalid
        /// gh could not reach the host to check it.
        case unverified
    }

    public var host: String
    public var login: String
    public var active: Bool
    public var state: State

    public init(host: String, login: String, active: Bool, state: State) {
        self.host = host
        self.login = login
        self.active = active
        self.state = state
    }
}

public struct GitHubCLIInfo: Hashable, Sendable {
    public var path: String
    public var version: String?
    /// Host and account name of each sign-in. Nothing else from `gh auth status` is kept.
    public var accounts: [GitHubAccount]
    /// Set when the sign-in could not be read.
    public var problem: String?

    public init(path: String, version: String? = nil, accounts: [GitHubAccount] = [], problem: String? = nil) {
        self.path = path
        self.version = version
        self.accounts = accounts
        self.problem = problem
    }
}

public enum GitHubCLIStatus: Hashable, Sendable {
    case notInstalled
    case installed(GitHubCLIInfo)

    public var info: GitHubCLIInfo? {
        if case .installed(let info) = self { return info }
        return nil
    }

    /// The account gh uses on `host`, when that sign-in works (or could not be checked).
    public func account(on host: String) -> GitHubAccount? {
        guard let info else { return nil }
        let active = info.accounts.first { $0.host.lowercased() == host.lowercased() && $0.active }
        guard let active, active.state != .invalid else { return nil }
        return active
    }

    /// Why gh cannot act on `host`, in a line, or nil when it can.
    public func signInProblem(on host: String) -> String? {
        guard let info else { return "The GitHub CLI is not installed" }
        if account(on: host) != nil { return nil }
        if let broken = info.accounts.first(where: { $0.host.lowercased() == host.lowercased() && $0.active }) {
            return "The sign-in for \(broken.login) on \(broken.host) no longer works"
        }
        return info.problem
    }

    /// Hosts gh has a sign-in for (GitHub Enterprise hosts count as GitHub once you sign in there).
    public var signedInHosts: Set<String> {
        Set(info?.accounts.map { $0.host.lowercased() } ?? [])
    }
}

// MARK: The session folder

/// Git facts about the session's folder that the pull request bar needs. Read locally; nothing is fetched.
public struct GitHubLocalRepo: Hashable, Sendable {
    public var root: String
    /// The branch checked out, or nil when HEAD is detached.
    public var branch: String?
    /// The remote the bar works with: the branch's upstream remote, else `origin`, else the first GitHub one.
    public var remoteName: String?
    /// That remote as a repository, when its URL names one (where it fetches from).
    public var remote: GitHubRemote?
    /// The one repository every push URL of that remote names (after `pushurl`, `pushInsteadOf` and `insteadOf`):
    /// where this branch is pushed, and so the head of its pull request. Nil when they disagree or name no
    /// GitHub repository; `pushProblem` says why.
    public var pushRemote: GitHubRemote?
    public var pushProblem: String?
    /// The remote's default branch as last fetched (`refs/remotes/<remote>/HEAD`), or the hint given.
    public var defaultBranch: String?
    /// True when the remote has a branch of this name (as last fetched or pushed).
    public var published: Bool
    /// Commits on HEAD that the remote's copy of the branch does not have; nil when it is not published.
    public var unpushed: Int?
    /// Commits on HEAD that the remote's default branch does not have; nil when that branch is unknown.
    public var ahead: Int?
    /// Files with uncommitted changes.
    public var uncommitted: Int

    public init(root: String, branch: String?, remoteName: String?, remote: GitHubRemote?, defaultBranch: String?,
                published: Bool = false, unpushed: Int? = nil, ahead: Int? = nil, uncommitted: Int = 0,
                pushRemote: GitHubRemote? = nil, pushProblem: String? = nil) {
        self.root = root
        self.branch = branch
        self.remoteName = remoteName
        self.remote = remote
        self.defaultBranch = defaultBranch
        self.published = published
        self.unpushed = unpushed
        self.ahead = ahead
        self.uncommitted = uncommitted
        // Without a push remote or a problem, the branch is pushed where it is fetched from.
        self.pushRemote = pushRemote ?? (pushProblem == nil ? remote : nil)
        self.pushProblem = pushProblem
    }
}

// MARK: Pull requests and checks

public struct GitHubCheck: Hashable, Sendable, Identifiable {
    /// The same buckets as `gh pr checks`.
    public enum Bucket: String, Hashable, Sendable {
        case pass, fail, pending, skipping, cancel
    }

    public var name: String
    public var workflow: String?
    public var bucket: Bucket
    public var link: String?

    public init(name: String, workflow: String? = nil, bucket: Bucket, link: String? = nil) {
        self.name = name
        self.workflow = workflow
        self.bucket = bucket
        self.link = link
    }

    public var id: String { "\(workflow ?? "")/\(name)/\(link ?? "")" }
    /// "CI / build", or the name alone.
    public var label: String { workflow.map { $0.isEmpty ? name : "\($0) / \(name)" } ?? name }
    /// The GitHub Actions run behind the check, when its link points at one.
    public var runID: String? { GitHubParsing.runID(in: link) }
    public var isFailure: Bool { bucket == .fail || bucket == .cancel }
}

public struct GitHubCheckSummary: Hashable, Sendable {
    public enum Overall: Hashable, Sendable { case none, passing, failing, pending }

    public var passing = 0
    public var failing = 0
    public var pending = 0
    public var skipped = 0

    public init(_ checks: [GitHubCheck]) {
        for check in checks {
            switch check.bucket {
            case .pass: passing += 1
            case .fail, .cancel: failing += 1
            case .pending: pending += 1
            case .skipping: skipped += 1
            }
        }
    }

    public var total: Int { passing + failing + pending + skipped }

    /// Failing wins over pending, so the bar always shows the check that needs a fix.
    public var overall: Overall {
        if failing > 0 { return .failing }
        if pending > 0 { return .pending }
        if passing + skipped > 0 { return .passing }
        return .none
    }

    /// "2 checks failing", "3 checks pending", "Checks passing", "No checks".
    public var label: String {
        func count(_ n: Int) -> String { n == 1 ? "1 check" : "\(n) checks" }
        switch overall {
        case .failing: return "\(count(failing)) failing"
        case .pending: return "\(count(pending)) pending"
        case .passing: return passing + skipped == 1 ? "1 check passing" : "\(passing + skipped) checks passing"
        case .none: return "No checks"
        }
    }
}

public struct GitHubPullRequest: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case open = "OPEN", closed = "CLOSED", merged = "MERGED"
    }

    public enum ReviewDecision: String, Hashable, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"

        public var label: String {
            switch self {
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .reviewRequired: "Review required"
            }
        }
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var isDraft: Bool
    public var reviewDecision: ReviewDecision?
    public var autoMergeEnabled: Bool
    public var headRefName: String
    public var baseRefName: String
    public var checks: [GitHubCheck]
    /// The repository the pull request's commits come from (owner login and name), and whether that is another
    /// repository than the one it merges into.
    public var headRepositoryOwner: String?
    public var headRepositoryName: String?
    public var isCrossRepository: Bool

    public init(number: Int, title: String, url: String, state: State, isDraft: Bool = false,
                reviewDecision: ReviewDecision? = nil, autoMergeEnabled: Bool = false, headRefName: String,
                baseRefName: String, checks: [GitHubCheck] = [], headRepositoryOwner: String? = nil,
                headRepositoryName: String? = nil, isCrossRepository: Bool = false) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.autoMergeEnabled = autoMergeEnabled
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.checks = checks
        self.headRepositoryOwner = headRepositoryOwner
        self.headRepositoryName = headRepositoryName
        self.isCrossRepository = isCrossRepository
    }

    /// True when this is the pull request of `branch` pushed to `head` and merging into `base`: the same branch
    /// name in exactly that repository. A fork's branch of the same name never matches.
    public func isFrom(branch: String, head: GitHubRemote, base: GitHubRemote) -> Bool {
        guard headRefName == branch, let owner = headRepositoryOwner, let name = headRepositoryName else { return false }
        guard owner.lowercased() == head.owner.lowercased(), name.lowercased() == head.name.lowercased() else { return false }
        return isCrossRepository == !head.isSameRepository(as: base)
    }

    public var checkSummary: GitHubCheckSummary { GitHubCheckSummary(checks) }
    public var failingChecks: [GitHubCheck] { checks.filter(\.isFailure) }
    public var isOpen: Bool { state == .open }

    /// "Open", "Draft", "Merged", "Closed".
    public var stateLabel: String {
        switch state {
        case .open: isDraft ? "Draft" : "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

// MARK: The bar

/// Why the bar is not shown for a session.
public enum GitHubHiddenReason: Hashable, Sendable {
    case notRepository, noRemote, notGitHub, detached
    /// The folder is not trusted, so no git or gh runs for it.
    case untrusted
}

/// What the pull request bar shows. Worked out by `derive` from the folder's git facts, gh's sign-in and the
/// branch's pull request.
public enum GitHubBarState: Hashable, Sendable {
    /// Nothing known yet; the bar stays hidden rather than flashing.
    case loading
    case hidden(GitHubHiddenReason)
    /// The folder is a GitHub repository but gh is not installed.
    case needsCLI
    /// gh is installed but cannot act on the repository's host.
    case signedOut(host: String, problem: String?)
    /// On the default branch: a pull request needs its own branch first.
    case defaultBranch(branch: String)
    /// A branch without a pull request.
    case noPullRequest(branch: String, base: String?)
    case pullRequest(GitHubPullRequest)
    /// gh failed; the line says why.
    case failed(String)

    public var isVisible: Bool {
        switch self {
        case .loading, .hidden: false
        default: true
        }
    }

    public var pullRequest: GitHubPullRequest? {
        if case .pullRequest(let pr) = self { return pr }
        return nil
    }

    /// Whether the bar can be closed for the session (only the notes that need something done outside Ensemble).
    public var isDismissible: Bool {
        switch self {
        case .needsCLI, .signedOut, .failed: true
        default: false
        }
    }

    /// The bar's state from what is known. `defaultBranch` is the remote's default branch from the folder or
    /// from GitHub; `pullRequest` is the branch's pull request (nil when it has none or it was not looked up);
    /// `lookupError` is set when looking it up failed.
    public static func derive(local: GitHubLocalRepo?, cli: GitHubCLIStatus?, defaultBranch: String?,
                              pullRequest: GitHubPullRequest?, lookupError: String?) -> GitHubBarState {
        guard let local else { return .hidden(.notRepository) }
        guard local.remoteName != nil else { return .hidden(.noRemote) }
        guard let remote = local.remote,
              GitHubParsing.isGitHubHost(remote.host, signedInHosts: cli?.signedInHosts ?? []) else {
            return .hidden(.notGitHub)
        }
        guard let cli else { return .loading }
        if cli == .notInstalled { return .needsCLI }
        if cli.account(on: remote.host) == nil { return .signedOut(host: remote.host, problem: cli.signInProblem(on: remote.host)) }
        guard let branch = local.branch else { return .hidden(.detached) }
        if let defaultBranch, branch == defaultBranch {
            if let pullRequest, pullRequest.headRefName == branch { return .pullRequest(pullRequest) }
            return .defaultBranch(branch: branch)
        }
        if let pullRequest { return .pullRequest(pullRequest) }
        if let lookupError { return .failed(lookupError) }
        return .noPullRequest(branch: branch, base: defaultBranch)
    }
}

/// Where a branch may be pushed, deny by default: to the repository its remote fetches from, or to your own fork
/// of that repository (a fork whose parent is the fetch repository and whose owner is an account gh is signed in
/// to on that host). Anything else, such as a lookalike repository in `pushurl`, is refused before any confirmation.
public enum GitHubPushPolicy {
    /// Why pushing to `push` is refused, or nil when it is allowed. `pushInfo` is `gh repo view` of `push`.
    public static func refusal(remoteName: String, fetch: GitHubRemote?, push: GitHubRemote, pushInfo: GitHubRepoInfo?,
                               cli: GitHubCLIStatus?) -> String? {
        guard let fetch else {
            return "\(remoteName) fetches from no GitHub repository, so Ensemble does not push to \(push.slug)"
        }
        if push.isSameRepository(as: fetch) { return nil }
        let refused = "\(remoteName) fetches from \(fetch.slug) but pushes to \(push.slug). Ensemble pushes only to the repository "
            + "a branch comes from, or to your own fork of it."
        guard let info = pushInfo, info.nameWithOwner.lowercased() == push.slug.lowercased(),
              let parent = info.parent, parent.isSameRepository(as: fetch),
              let owner = info.ownerLogin?.lowercased(), owner == push.owner.lowercased() else { return refused }
        let accounts = cli?.info?.accounts.filter { $0.host.lowercased() == push.host.lowercased() && $0.state != .invalid } ?? []
        guard accounts.contains(where: { $0.login.lowercased() == owner }) else { return refused }
        return nil
    }
}

/// How often the bar checks GitHub while it is on screen.
public enum GitHubRefreshPolicy {
    public static func interval(for state: GitHubBarState) -> Duration {
        switch state {
        case .pullRequest(let pr):
            guard pr.isOpen else { return .seconds(900) }
            return pr.checkSummary.pending > 0 ? .seconds(60) : .seconds(300)
        case .noPullRequest, .defaultBranch: return .seconds(300)
        case .failed: return .seconds(120)
        case .loading: return .seconds(30)
        case .needsCLI, .signedOut, .hidden: return .seconds(600)
        }
    }

    /// How long gh's sign-in answer is reused before asking again.
    public static let signInLifetime: TimeInterval = 600
    /// How long the repository's settings (default branch, merge methods) are reused.
    public static let repoInfoLifetime: TimeInterval = 1800
}

// MARK: Outward actions

/// Pushing one branch to its remote. Never forced: the arguments are fixed here and checked again by
/// `GitHubCommandPolicy` before git runs.
public struct GitHubPushPlan: Hashable, Sendable {
    public var root: String
    public var remoteName: String
    public var branch: String
    public var remote: GitHubRemote
    /// Commits the remote does not have yet; nil when the branch is new there.
    public var commits: Int?

    public init(root: String, remoteName: String, branch: String, remote: GitHubRemote, commits: Int?) {
        self.root = root
        self.remoteName = remoteName
        self.branch = branch
        self.remote = remote
        self.commits = commits
    }

    public var arguments: [String] {
        ["push", "--set-upstream", remoteName, "refs/heads/\(branch):refs/heads/\(branch)"]
    }
}

/// Opening a pull request with gh. The branch is pushed first, so gh never pushes on its own.
public struct GitHubPullRequestRequest: Hashable, Sendable {
    /// The repository the pull request is opened in (it merges into `base` there).
    public var remote: GitHubRemote
    public var base: String
    /// The branch, in `headRemote` (the repository it is pushed to; nil is `remote` itself).
    public var head: String
    public var headRemote: GitHubRemote?
    public var title: String
    public var body: String
    public var draft: Bool

    public init(remote: GitHubRemote, base: String, head: String, headRemote: GitHubRemote? = nil, title: String, body: String,
                draft: Bool = false) {
        self.remote = remote
        self.base = base
        self.head = head
        self.headRemote = headRemote
        self.title = title
        self.body = body
        self.draft = draft
    }

    /// True when the branch lives in a fork rather than in the repository the pull request goes to.
    public var isCrossRepository: Bool { headRemote.map { !$0.isSameRepository(as: remote) } ?? false }

    /// "feature", or "octocat:feature" from a fork.
    public var headLabel: String { isCrossRepository ? "\(headRemote?.owner ?? ""):\(head)" : head }

    public var arguments: [String] {
        var args = ["pr", "create", "--repo", remote.repoArgument, "--base", base, "--head", headLabel,
                    "--title=\(title)", "--body=\(body)"]
        if draft { args.append("--draft") }
        return args
    }
}

/// An outward-facing step waiting for the person to confirm it. The texts name what is sent where.
public struct GitHubConfirmation: Hashable, Sendable, Identifiable {
    public enum Action: Hashable, Sendable {
        case push(GitHubPushPlan)
        case createPullRequest(push: GitHubPushPlan?, request: GitHubPullRequestRequest)
        case merge(number: Int, method: GitHubMergeMethod, remote: GitHubRemote, base: String)
    }

    public var action: Action
    public var title: String
    public var message: String
    public var confirmTitle: String

    public var id: String { title + message }

    public init(action: Action) {
        self.action = action
        switch action {
        case .push(let plan):
            title = "Push \(plan.branch) to \(plan.remoteName)?"
            message = "Sends \(Self.commits(plan.commits)) on \(plan.branch) to \(plan.remoteName) (\(plan.remote.slug) on \(plan.remote.host)). "
                + "Nothing is force-pushed."
            confirmTitle = "Push"
        case .createPullRequest(let push, let request):
            if let push {
                title = "Push and open a pull request?"
                message = "Pushes \(push.branch) to \(push.remoteName) (\(push.remote.slug) on \(push.remote.host)), then opens a pull request "
                    + "in \(request.remote.slug) from \(request.headLabel) into \(request.base) titled \u{201C}\(request.title)\u{201D}. "
                    + "Nothing is force-pushed."
                confirmTitle = request.draft ? "Push and open draft" : "Push and open"
            } else {
                title = "Open a pull request?"
                message = "Opens a pull request in \(request.remote.slug) from \(request.headLabel) into \(request.base) titled "
                    + "\u{201C}\(request.title)\u{201D}."
                confirmTitle = request.draft ? "Open draft" : "Open pull request"
            }
        case .merge(let number, let method, let remote, let base):
            title = "Merge #\(number) when ready?"
            message = "Turns on auto-merge for #\(number) in \(remote.slug). GitHub will \(method.label) into \(base) as soon as "
                + "its required checks and reviews pass, which can be right away."
            confirmTitle = "Turn on auto-merge"
        }
    }

    static func commits(_ count: Int?) -> String {
        guard let count else { return "the branch" }
        return count == 1 ? "1 commit" : "\(count) commits"
    }
}

/// What "Write description" sends: the branch's commits and changes against the base.
public struct GitHubPullRequestContext: Hashable, Sendable {
    public var branch: String
    public var base: String
    /// Commit subjects, oldest first.
    public var commits: [String]
    public var files: [ReviewFileDiff]

    public init(branch: String, base: String, commits: [String], files: [ReviewFileDiff]) {
        self.branch = branch
        self.base = base
        self.commits = commits
        self.files = files
    }
}

/// A title and description for a pull request.
public struct GitHubPullRequestText: Hashable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// One failed run's trimmed log, or a failing check without a log Ensemble can fetch.
public struct GitHubFailedLog: Hashable, Sendable {
    public var checks: [GitHubCheck]
    public var runID: String?
    public var text: String?

    public init(checks: [GitHubCheck], runID: String?, text: String?) {
        self.checks = checks
        self.runID = runID
        self.text = text
    }
}

public struct GitHubError: Error, LocalizedError, Hashable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
