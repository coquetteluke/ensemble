import Foundation

/// Reads what git and gh print. Pure functions, so they are tested without either tool.
public enum GitHubParsing {
    // MARK: Remotes

    /// The repository a remote URL names: https, ssh, git and scp-like (`git@host:owner/name.git`) forms.
    /// Any user name or password in the URL is dropped. Nil for local paths and URLs without owner/name.
    public static func remote(fromURL raw: String) -> GitHubRemote? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var host: String
        var path: String
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let components = URLComponents(string: text), let h = components.host, !h.isEmpty else { return nil }
            host = h
            path = components.path
        } else {
            // scp-like: [user@]host:path, with no slash before the colon.
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let before = text[..<colon]
            guard !before.contains("/"), !before.isEmpty else { return nil }
            host = String(before.split(separator: "@").last ?? "")
            path = String(text[text.index(after: colon)...])
        }
        host = host.lowercased()
        if host == "ssh.github.com" || host == "www.github.com" { host = "github.com" }
        guard !host.isEmpty, host != "localhost" else { return nil }
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return GitHubRemote(host: host, owner: parts[0], name: parts[1])
    }

    /// A remote URL to show: any user name or password removed, and anything shaped like a token replaced.
    public static func displayURL(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://"), var components = URLComponents(string: text) {
            components.user = nil
            components.password = nil
            return redactTokens(components.string ?? text)
        }
        return redactTokens(text)
    }

    /// github.com, GitHub Enterprise Cloud (`*.ghe.com`) and any host gh has a sign-in for.
    public static func isGitHubHost(_ host: String, signedInHosts: Set<String>) -> Bool {
        let host = host.lowercased()
        return host == "github.com" || host.hasSuffix(".ghe.com") || signedInHosts.contains(host)
    }

    // MARK: gh auth status and version

    /// The jq filter given to `gh auth status --json hosts`, so gh itself keeps only the host, account name,
    /// state and whether the account is active. Token fields never leave gh.
    public static let accountsQuery = ".hosts | to_entries[] | .value[] | [.host, .login, .state, (.active | tostring)] | @tsv"

    /// Accounts from the tab-separated lines `accountsQuery` prints.
    public static func accounts(fromTSV text: String) -> [GitHubAccount] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            let state: GitHubAccount.State = switch fields[2] {
            case "success": .valid
            case "timeout": .unverified
            default: .invalid
            }
            return GitHubAccount(host: fields[0].lowercased(), login: fields[1], active: fields[3] == "true", state: state)
        }
    }

    /// "2.103.3" from "gh version 2.103.3 (2026-10-26)".
    public static func version(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(separator: " ")
        guard words.count >= 3, words[0] == "gh", words[1] == "version" else { return nil }
        return String(words[2])
    }

    // MARK: Pull requests

    /// Fields asked of `gh pr list` and `gh pr view`.
    public static let pullRequestFields = "number,title,url,state,isDraft,reviewDecision,autoMergeRequest,headRefName,baseRefName,statusCheckRollup"

    struct PullRequestJSON: Decodable {
        var number: Int
        var title: String
        var url: String
        var state: String
        var isDraft: Bool?
        var reviewDecision: String?
        var autoMergeRequest: AutoMergeJSON?
        var headRefName: String?
        var baseRefName: String?
        var statusCheckRollup: [RollupJSON]?
    }

    struct AutoMergeJSON: Decodable {
        var mergeMethod: String?
    }

    /// One entry of `statusCheckRollup`: a check run (GitHub Actions and apps) or a commit status.
    struct RollupJSON: Decodable {
        var __typename: String?
        var name: String?
        var context: String?
        var status: String?
        var conclusion: String?
        var state: String?
        var detailsUrl: String?
        var targetUrl: String?
        var workflowName: String?
        var startedAt: String?
        var completedAt: String?
    }

    /// Pull requests from `gh pr list --json`.
    public static func pullRequests(_ data: Data) throws -> [GitHubPullRequest] {
        let decoded = try JSONDecoder().decode([PullRequestJSON].self, from: data)
        return decoded.compactMap(pullRequest)
    }

    /// One pull request from `gh pr view --json`.
    public static func pullRequest(_ data: Data) throws -> GitHubPullRequest? {
        pullRequest(try JSONDecoder().decode(PullRequestJSON.self, from: data))
    }

    static func pullRequest(_ json: PullRequestJSON) -> GitHubPullRequest? {
        guard let state = GitHubPullRequest.State(rawValue: json.state.uppercased()) else { return nil }
        let decision = json.reviewDecision.flatMap { GitHubPullRequest.ReviewDecision(rawValue: $0) }
        return GitHubPullRequest(number: json.number, title: json.title, url: json.url, state: state, isDraft: json.isDraft ?? false,
                                 reviewDecision: decision, autoMergeEnabled: json.autoMergeRequest != nil,
                                 headRefName: json.headRefName ?? "", baseRefName: json.baseRefName ?? "",
                                 checks: checks(json.statusCheckRollup ?? []))
    }

    /// The pull request the bar follows for a branch: the newest open one, else the newest of the rest.
    public static func pick(_ pullRequests: [GitHubPullRequest]) -> GitHubPullRequest? {
        let sorted = pullRequests.sorted { $0.number > $1.number }
        return sorted.first { $0.state == .open } ?? sorted.first
    }

    /// Checks in `gh pr checks` buckets. A check that ran more than once counts once, by its latest run.
    static func checks(_ rollup: [RollupJSON]) -> [GitHubCheck] {
        var latest: [String: (check: GitHubCheck, time: String)] = [:]
        var order: [String] = []
        for entry in rollup {
            let isStatus = entry.__typename == "StatusContext" || (entry.name == nil && entry.context != nil)
            guard let name = isStatus ? entry.context : entry.name, !name.isEmpty else { continue }
            let rawState: String
            if isStatus {
                rawState = entry.state ?? "PENDING"
            } else if (entry.status ?? "COMPLETED").uppercased() == "COMPLETED" {
                rawState = entry.conclusion ?? "PENDING"
            } else {
                rawState = entry.status ?? "PENDING"
            }
            let workflow = isStatus ? nil : entry.workflowName
            let check = GitHubCheck(name: name, workflow: workflow, bucket: bucket(rawState),
                                    link: isStatus ? entry.targetUrl : entry.detailsUrl)
            let key = "\(workflow ?? "")\u{1F}\(name)"
            // The newest run started last (an unfinished run's completedAt is gh's zero date).
            let time = [entry.startedAt, entry.completedAt].compactMap { $0 }.first { !$0.hasPrefix("0001-") } ?? ""
            if let existing = latest[key] {
                if time >= existing.time { latest[key] = (check, time) }
            } else {
                latest[key] = (check, time)
                order.append(key)
            }
        }
        return order.compactMap { latest[$0]?.check }
    }

    /// A check run conclusion, check run status or commit status state as a `gh pr checks` bucket.
    public static func bucket(_ state: String) -> GitHubCheck.Bucket {
        switch state.uppercased() {
        case "SUCCESS": .pass
        case "SKIPPED", "NEUTRAL": .skipping
        case "CANCELLED": .cancel
        case "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": .fail
        default: .pending
        }
    }

    // MARK: Repository

    struct RepoJSON: Decodable {
        struct Ref: Decodable { var name: String? }
        var nameWithOwner: String
        var url: String
        var defaultBranchRef: Ref?
        var squashMergeAllowed: Bool?
        var mergeCommitAllowed: Bool?
        var rebaseMergeAllowed: Bool?
    }

    public static let repoFields = "nameWithOwner,url,defaultBranchRef,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed"

    public static func repoInfo(_ data: Data) throws -> GitHubRepoInfo {
        let json = try JSONDecoder().decode(RepoJSON.self, from: data)
        let branch = json.defaultBranchRef?.name.flatMap { $0.isEmpty ? nil : $0 }
        return GitHubRepoInfo(nameWithOwner: json.nameWithOwner, url: json.url, defaultBranch: branch,
                              squashAllowed: json.squashMergeAllowed ?? true, mergeCommitAllowed: json.mergeCommitAllowed ?? true,
                              rebaseAllowed: json.rebaseMergeAllowed ?? true)
    }

    // MARK: Links

    /// The pull request link `gh pr create` prints, and its number.
    public static func createdPullRequest(_ output: String) -> (url: String, number: Int)? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("https://"), let range = trimmed.range(of: "/pull/") else { continue }
            let digits = trimmed[range.upperBound...].prefix { $0.isNumber }
            if let number = Int(digits) { return (trimmed, number) }
        }
        return nil
    }

    /// The run id in a GitHub Actions link (`.../actions/runs/<id>/job/<job>`).
    public static func runID(in link: String?) -> String? {
        number(after: "/actions/runs/", in: link)
    }

    /// The job id in a GitHub Actions link.
    public static func jobID(in link: String?) -> String? {
        number(after: "/job/", in: link)
    }

    private static func number(after marker: String, in link: String?) -> String? {
        guard let link, let range = link.range(of: marker) else { return nil }
        let digits = link[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// True for an https link on `host` (links from gh are opened only when they point at the repository's host).
    public static func isWebLink(_ link: String, on host: String) -> Bool {
        guard let url = URL(string: link), url.scheme == "https", let linkHost = url.host?.lowercased() else { return false }
        return linkHost == host.lowercased() || linkHost == "www.\(host.lowercased())"
    }

    // MARK: Logs

    /// `gh run view --log-failed` output made short enough for one message: colour codes and timestamps
    /// removed, grouped by job and step, and only the end of each failed step kept. Anything shaped like a
    /// GitHub token is replaced.
    public static func trimLog(_ raw: String, limit: Int = 12_000) -> String {
        struct Group { var title: String; var lines: [String] }
        var groups: [Group] = []
        for rawLine in redactTokens(stripANSI(raw)).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            var title = ""
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3 {
                title = "\(fields[0]) / \(fields[1])"
                line = String(fields[2])
            }
            line = stripTimestamp(line)
            if line.hasPrefix("##[group]") || line.hasPrefix("##[endgroup]") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty && (groups.last?.lines.last?.isEmpty ?? true) { continue }
            if groups.last?.title != title { groups.append(Group(title: title, lines: [])) }
            groups[groups.count - 1].lines.append(line)
        }
        groups.removeAll { $0.lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        func render(_ keep: Int) -> String {
            groups.map { group in
                var lines = group.lines
                var head = group.title.isEmpty ? "" : group.title + ":\n"
                if lines.count > keep {
                    head += "[\(lines.count - keep) earlier lines cut]\n"
                    lines = Array(lines.suffix(keep))
                }
                return head + lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        for keep in [80, 50, 30, 15, 8] {
            let text = render(keep)
            if text.count <= limit { return text }
        }
        let text = render(8)
        return "[cut short]\n" + String(text.suffix(limit))
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    static func stripTimestamp(_ line: String) -> String {
        line.replacingOccurrences(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z ?", with: "", options: .regularExpression)
    }

    /// Replaces anything shaped like a GitHub token (`ghp_...`, `gho_...`, `github_pat_...`).
    public static func redactTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})", with: "[token removed]",
                                  options: .regularExpression)
    }

    /// True when `text` holds something shaped like a GitHub token.
    public static func containsToken(_ text: String) -> Bool {
        text.range(of: "(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})", options: .regularExpression) != nil
    }

    /// gh's error output in one line for the bar: the first line that says something, without tokens.
    public static func errorLine(_ stderr: String, fallback: String) -> String {
        let lines = redactTokens(stripANSI(stderr)).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.first else { return fallback }
        if line.count > 240 { line = String(line.prefix(240)) + "\u{2026}" }
        return line
    }

    // MARK: Fix failing checks

    /// The one message Fix failing checks sends: which checks failed and their trimmed logs.
    public static func fixChecksMessage(pullRequest pr: GitHubPullRequest, logs: [GitHubFailedLog]) -> String {
        let names = pr.failingChecks.map(\.label).joined(separator: ", ")
        var parts = [
            "The checks on pull request #\(pr.number) (\u{201C}\(pr.title)\u{201D}) are failing: \(names). "
                + "The failed logs are below, trimmed to the end of each failed step. Find the cause, fix it, and commit the fix.",
        ]
        for log in logs {
            let label = log.checks.map(\.label).joined(separator: ", ")
            if let text = log.text, !text.isEmpty {
                let run = log.runID.map { " (run \($0))" } ?? ""
                parts.append("Failed log for \(label)\(run):\n```text\n\(text)\n```")
            } else {
                let links = log.checks.compactMap(\.link).joined(separator: " ")
                parts.append("No log could be fetched for \(label)." + (links.isEmpty ? "" : " Details: \(links)"))
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
