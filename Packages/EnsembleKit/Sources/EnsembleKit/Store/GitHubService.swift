import Foundation

#if os(macOS)
/// The git and gh work behind the pull request bar. Local facts come from `/usr/bin/git` through `GitRunner`
/// (read-only commands, nothing fetched); GitHub facts and actions go through the signed-in `gh`, run outside
/// the session folder with the repository named by `--repo`. The only
/// commands that change anything are `createBranch`, `push`, `createPullRequest`, `enableAutoMerge` and
/// `disableAutoMerge`, and the pull request bar runs the outward ones only after a confirmation.
public struct GitHubService: Sendable {
    public var git: GitRunner
    /// Finds gh; asked again on each sign-in check, so installing gh later is noticed.
    public var locateGH: @Sendable () -> String?
    /// Pushes only leave folders the person trusts (see `WorkspaceTrust`).
    public var isTrusted: @Sendable (String) -> Bool

    public init(git: GitRunner = GitRunner(), locateGH: @escaping @Sendable () -> String? = { GitHubCLI.locate() },
                isTrusted: @escaping @Sendable (String) -> Bool = { WorkspaceTrust.shared.isTrusted($0) }) {
        self.git = git
        self.locateGH = locateGH
        self.isTrusted = isTrusted
    }

    func gh(timeout: TimeInterval = 60) throws -> GitHubCLI {
        guard let path = locateGH() else { throw GitHubError("The GitHub CLI is not installed") }
        return GitHubCLI(path: path, timeout: timeout)
    }

    // MARK: gh and the sign-in

    /// Whether gh is installed, its version, and the host and account name of each sign-in. The sign-in is
    /// read with a jq filter so gh itself drops everything but those fields.
    public func cliStatus() async -> GitHubCLIStatus {
        guard let path = locateGH() else { return .notInstalled }
        let gh = GitHubCLI(path: path, timeout: 30)
        let version = GitHubParsing.version(await gh.run(["--version"]).text)
        let auth = await gh.run(["auth", "status", "--json", "hosts", "--jq", GitHubParsing.accountsQuery])
        guard auth.succeeded else {
            let problem = auth.stderr.contains("unknown flag")
                ? "This version of gh cannot report its sign-in. Update it with brew upgrade gh."
                : GitHubParsing.errorLine(auth.stderr, fallback: "Could not read the GitHub sign-in")
            return .installed(GitHubCLIInfo(path: path, version: version, problem: problem))
        }
        return .installed(GitHubCLIInfo(path: path, version: version, accounts: GitHubParsing.accounts(fromTSV: auth.text)))
    }

    /// Whether git has a credential helper in your own (global) git config. HTTPS pushes need one, because
    /// Ensemble's git never reads the system config where Xcode's git keeps its keychain helper. Reads only
    /// that config and keeps only the answer, never the helper's value.
    public func hasGlobalCredentialHelper(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        var env = environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        let path = git.gitPath
        let folder = GitHubCLI.neutralFolder()
        let finalEnvironment = env
        let r = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ProcessRun.run(path: path, arguments: ["config", "--global", "--get-regexp", "^credential\\..*helper$"],
                                                              environment: finalEnvironment, directory: folder, timeout: 10))
            }
        }
        guard r.succeeded else { return false }
        // "credential.helper value" lines; an empty value only clears earlier helpers.
        return r.text.split(whereSeparator: \.isNewline).contains { line in
            line.split(separator: " ", maxSplits: 1).count == 2
        }
    }

    // MARK: Local facts

    /// The repository folder holding `directory`, found without running git, and whether it is trusted. Git runs
    /// on its own (the bar's refresh) only in trusted folders.
    public func repositoryFolder(_ directory: String) -> (folder: String, trusted: Bool)? {
        guard let folder = GitSafety.repositoryFolder(containing: directory) else { return nil }
        return (folder, isTrusted(folder))
    }

    /// The folder's branch, remote, default branch and how far the branch is ahead. Nil when `directory` is not
    /// in a git work tree, or is in one that is not trusted (no git runs there). `baseHint` is the default branch from GitHub, used when the folder has no
    /// `refs/remotes/<remote>/HEAD`.
    public func localRepository(_ directory: String, baseHint: String? = nil) async -> GitHubLocalRepo? {
        guard FileManager.default.fileExists(atPath: directory), repositoryFolder(directory)?.trusted == true else { return nil }
        let top = await git.run(["rev-parse", "--show-toplevel"], in: directory)
        guard top.succeeded, !top.line.isEmpty else { return nil }
        let root = top.line
        let branchRun = await git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        let branch = branchRun.succeeded && !branchRun.line.isEmpty ? branchRun.line : nil
        let remotes = await git.run(["remote"], in: root).text.split(whereSeparator: \.isNewline).map(String.init)
        var local = GitHubLocalRepo(root: root, branch: branch, remoteName: nil, remote: nil, defaultBranch: nil)
        local.uncommitted = await uncommittedCount(root)
        guard !remotes.isEmpty else { return local }

        var urls: [String: GitHubRemote?] = [:]
        for name in remotes {
            let url = await git.run(["remote", "get-url", "--", name], in: root)
            urls[name] = url.succeeded ? GitHubParsing.remote(fromURL: url.line) : nil
        }
        var upstreamRemote: String?
        if let branch {
            let configured = await git.run(["config", "--get", "branch.\(branch).remote"], in: root).line
            if remotes.contains(configured) { upstreamRemote = configured }
        }
        let githubRemote = remotes.first { urls[$0].flatMap { $0 }.map { GitHubParsing.isGitHubHost($0.host, signedInHosts: []) } ?? false }
        let remoteName = upstreamRemote ?? (remotes.contains("origin") ? "origin" : nil) ?? githubRemote ?? remotes[0]
        local.remoteName = remoteName
        local.remote = urls[remoteName] ?? nil
        let push = await pushRepository(remoteName: remoteName, root: root)
        local.pushRemote = push.remote
        local.pushProblem = push.problem

        let head = await git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remoteName)/HEAD"], in: root)
        if head.succeeded, head.line.hasPrefix(remoteName + "/") {
            local.defaultBranch = String(head.line.dropFirst(remoteName.count + 1))
        } else if let baseHint {
            local.defaultBranch = baseHint
        }
        if let branch, await refExists("refs/remotes/\(remoteName)/\(branch)", root: root) {
            local.published = true
            local.unpushed = await count("refs/remotes/\(remoteName)/\(branch)..HEAD", root: root)
        }
        if let base = local.defaultBranch, await refExists("refs/remotes/\(remoteName)/\(base)", root: root) {
            local.ahead = await count("refs/remotes/\(remoteName)/\(base)..HEAD", root: root)
        }
        return local
    }

    /// The one GitHub repository every push URL of the remote names, or why there is none.
    func pushRepository(remoteName: String, root: String) async -> (remote: GitHubRemote?, problem: String?) {
        guard let urls = await pushDestinations(remoteName: remoteName, root: root) else {
            return (nil, "Could not read where \(remoteName) pushes to")
        }
        var found: GitHubRemote?
        for url in urls {
            guard let target = GitHubParsing.remote(fromURL: url) else {
                return (nil, "\(remoteName) pushes to \(GitHubParsing.displayURL(url)), which is not a GitHub repository")
            }
            if let found, !found.isSameRepository(as: target) {
                return (nil, "\(remoteName) pushes to both \(found.slug) and \(target.slug)")
            }
            found = found ?? target
        }
        return (found, nil)
    }

    func refExists(_ ref: String, root: String) async -> Bool {
        await git.run(["rev-parse", "--verify", "--quiet", ref], in: root).succeeded
    }

    func count(_ range: String, root: String) async -> Int? {
        let r = await git.run(["rev-list", "--count", range, "--"], in: root)
        return r.succeeded ? Int(r.line) : nil
    }

    func uncommittedCount(_ root: String) async -> Int {
        let r = await git.run(["status", "--porcelain", "-z", "--untracked-files=normal", "--no-renames"], in: root)
        guard r.succeeded else { return 0 }
        return r.stdout.split(separator: 0).count
    }

    /// Subjects of the commits on HEAD that `base` does not have (oldest first, at most 50) and the changes,
    /// for Write description.
    public func pullRequestContext(_ local: GitHubLocalRepo, base: String) async -> GitHubPullRequestContext {
        let branch = local.branch ?? "HEAD"
        guard let remoteName = local.remoteName else {
            return GitHubPullRequestContext(branch: branch, base: base, commits: [], files: [])
        }
        let baseRef = "refs/remotes/\(remoteName)/\(base)"
        let log = await git.run(["log", "--no-color", "--reverse", "--max-count=50", "--format=%s", "\(baseRef)..HEAD", "--"], in: local.root)
        let commits = log.succeeded ? log.text.split(whereSeparator: \.isNewline).map(String.init) : []
        let review = GitReviewService(runner: git)
        var files: [ReviewFileDiff] = []
        if let mergeBase = await review.mergeBase(local.root, base: baseRef) {
            files = (try? await review.diff(from: mergeBase, to: "HEAD", root: local.root)) ?? []
        }
        return GitHubPullRequestContext(branch: branch, base: base, commits: commits, files: files)
    }

    // MARK: GitHub facts

    public func repoInfo(_ remote: GitHubRemote) async throws -> GitHubRepoInfo {
        let r = await (try gh()).run(["repo", "view", remote.repoArgument, "--json", GitHubParsing.repoFields])
        guard r.succeeded else { throw GitHubError(GitHubParsing.errorLine(r.stderr, fallback: "Could not read \(remote.slug)")) }
        do {
            return try GitHubParsing.repoInfo(r.stdout, host: remote.host)
        } catch {
            throw GitHubError("gh printed a repository Ensemble could not read")
        }
    }

    /// The pull request of `branch` pushed to `head`, opened in `base` (the newest open one, else the newest), or
    /// nil when it has none. `gh pr list --head` matches the branch name in every fork, so only pull requests whose
    /// head repository is exactly `head` count.
    public func pullRequest(branch: String, head: GitHubRemote, base: GitHubRemote) async throws -> GitHubPullRequest? {
        let args = ["pr", "list", "--repo", base.repoArgument, "--head", branch, "--state", "all", "--limit", "30",
                    "--json", GitHubParsing.pullRequestFields]
        let r = await (try gh()).run(args)
        guard r.succeeded else { throw GitHubError(GitHubParsing.errorLine(r.stderr, fallback: "Could not look up pull requests")) }
        do {
            return GitHubParsing.pick(try GitHubParsing.pullRequests(r.stdout), branch: branch, head: head, base: base)
        } catch {
            throw GitHubError("gh printed pull requests Ensemble could not read")
        }
    }

    /// Trimmed logs of the failed GitHub Actions runs behind `checks`, one per run. Checks from other services
    /// come back without a log.
    public func failedLogs(for checks: [GitHubCheck], remote: GitHubRemote, limit: Int = 12_000) async -> [GitHubFailedLog] {
        var byRun: [String: [GitHubCheck]] = [:]
        var runOrder: [String] = []
        var other: [GitHubCheck] = []
        for check in checks {
            if let run = check.runID {
                if byRun[run] == nil { runOrder.append(run) }
                byRun[run, default: []].append(check)
            } else {
                other.append(check)
            }
        }
        var logs: [GitHubFailedLog] = []
        let share = max(2_000, limit / max(1, runOrder.count))
        for run in runOrder.prefix(5) {
            let checks = byRun[run] ?? []
            guard let gh = try? gh(timeout: 120) else {
                logs.append(GitHubFailedLog(checks: checks, runID: run, text: nil))
                continue
            }
            let r = await gh.run(["run", "view", run, "--repo", remote.repoArgument, "--log-failed"])
            let text = r.succeeded ? GitHubParsing.trimLog(r.text, limit: share) : nil
            logs.append(GitHubFailedLog(checks: checks, runID: run, text: text?.isEmpty == true ? nil : text))
        }
        if !other.isEmpty { logs.append(GitHubFailedLog(checks: other, runID: nil, text: nil)) }
        return logs
    }

    // MARK: Changes

    /// Makes `name` from HEAD and switches the folder to it. Uncommitted changes come along.
    public func createBranch(_ name: String, root: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard await isValidBranchName(trimmed, root: root) else { throw GitHubError("\u{201C}\(trimmed)\u{201D} is not a valid branch name") }
        if await refExists("refs/heads/\(trimmed)", root: root) { throw GitHubError("A branch named \(trimmed) already exists") }
        let r = await git.run(["switch", "--quiet", "--no-guess", "-c", trimmed], in: root)
        guard r.succeeded else { throw GitHubError(GitHubParsing.errorLine(r.stderr, fallback: "Could not create \(trimmed)")) }
    }

    public func isValidBranchName(_ name: String, root: String) async -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("+") else { return false }
        return await git.run(["check-ref-format", "--branch", name], in: root).succeeded
    }

    public static let untrustedPush = "Ensemble pushes only from trusted folders. Trust this folder first."

    /// Config that would make a push send more than the one branch: tags it follows, submodules, mirroring.
    static let pushOverrides = ["-c", "push.followTags=false", "-c", "push.recurseSubmodules=no"]

    /// Every URL `git push <remote>` would send to, after `pushurl`, `pushInsteadOf` and `insteadOf`.
    public func pushDestinations(remoteName: String, root: String) async -> [String]? {
        let r = await git.run(["remote", "get-url", "--push", "--all", "--", remoteName], in: root)
        guard r.succeeded else { return nil }
        let urls = r.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return urls.isEmpty ? nil : urls
    }

    /// Throws unless the folder is trusted and every URL git would push the plan's remote to names the
    /// repository the confirmation shows (a `pushurl` or `pushInsteadOf` pointing elsewhere is refused).
    public func verifyPushDestination(_ plan: GitHubPushPlan) async throws {
        guard isTrusted(plan.root) else { throw GitHubError(Self.untrustedPush) }
        guard let urls = await pushDestinations(remoteName: plan.remoteName, root: plan.root) else {
            throw GitHubError("Could not read where \(plan.remoteName) pushes to")
        }
        for url in urls {
            guard let target = GitHubParsing.remote(fromURL: url), target.isSameRepository(as: plan.remote) else {
                throw GitHubError("\(plan.remoteName) pushes to \(GitHubParsing.displayURL(url)), not \(plan.remote.slug) on "
                    + "\(plan.remote.host). Ensemble only pushes to the repository it shows.")
            }
        }
    }

    /// Pushes the plan's branch to the same name on its remote and sets it as the upstream. Checks first that git
    /// would send it to the plan's repository and nowhere else. Never forced.
    public func push(_ plan: GitHubPushPlan) async throws {
        let args = Self.pushOverrides + plan.arguments
        if let violation = GitHubCommandPolicy.pushViolation(args) { throw GitHubError(violation) }
        guard await isValidBranchName(plan.branch, root: plan.root), !plan.remoteName.hasPrefix("-") else {
            throw GitHubError("Cannot push \(plan.branch) to \(plan.remoteName)")
        }
        try await verifyPushDestination(plan)
        let r = await git.run(args, in: plan.root)
        guard r.succeeded else {
            let line = GitHubParsing.errorLine(r.stderr, fallback: "git push failed")
            if r.stderr.contains("non-fast-forward") || r.stderr.contains("fetch first") || r.stderr.contains("[rejected]") {
                throw GitHubError("\(plan.remoteName) has commits on \(plan.branch) that this folder does not. Pull them first; Ensemble never force-pushes.")
            }
            if r.stderr.contains("could not read Username") || r.stderr.contains("terminal prompts disabled") {
                throw GitHubError("git has no sign-in for \(plan.remote.host). Run gh auth setup-git in Terminal, then push again.")
            }
            throw GitHubError(line)
        }
    }

    /// Opens the pull request. Returns its link and number.
    @discardableResult
    public func createPullRequest(_ request: GitHubPullRequestRequest) async throws -> (url: String, number: Int) {
        let r = await (try gh(timeout: 120)).run(request.arguments)
        guard r.succeeded else { throw GitHubError(GitHubParsing.errorLine(r.stderr, fallback: "Could not open the pull request")) }
        guard let created = GitHubParsing.createdPullRequest(r.text) else {
            throw GitHubError("gh opened the pull request but did not print its link")
        }
        return created
    }

    /// Turns on GitHub's auto-merge for the pull request with `method`.
    public func enableAutoMerge(number: Int, method: GitHubMergeMethod, remote: GitHubRemote) async throws {
        let args = ["pr", "merge", String(number), "--repo", remote.repoArgument, "--auto", method.flag]
        let r = await (try gh(timeout: 90)).run(args)
        guard r.succeeded else { throw GitHubError(GitHubParsing.errorLine(r.stderr, fallback: "Could not turn on auto-merge")) }
    }

    public func disableAutoMerge(number: Int, remote: GitHubRemote) async throws {
        let args = ["pr", "merge", String(number), "--repo", remote.repoArgument, "--disable-auto"]
        let r = await (try gh(timeout: 90)).run(args)
        guard r.succeeded else { throw GitHubError(GitHubParsing.errorLine(r.stderr, fallback: "Could not turn off auto-merge")) }
    }
}
#endif
