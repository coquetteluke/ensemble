#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// A fake `gh` in its own temporary folder: it records every call and prints the canned answers a test sets.
/// Nothing reaches GitHub.
struct FakeGH {
    let dir: URL
    var path: String { dir.appendingPathComponent("gh").path }

    init() throws {
        dir = try GitHubFolders.make("ensemble-fake-gh")
        let script = dir.appendingPathComponent("gh")
        try FileManager.default.copyItem(at: Fixtures.url("github/fake-gh.sh"), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("responses"), withIntermediateDirectories: true)
    }

    /// Sets what `gh <key>` prints (keys: version, auth_status, repo_view, pr_list, pr_create, pr_merge, run_view).
    func respond(_ key: String, out: String = "", err: String = "", code: Int32 = 0) throws {
        let base = dir.appendingPathComponent("responses").appendingPathComponent(key)
        for (ext, text) in [("out", out), ("err", err), ("code", "\(code)")] {
            let url = base.appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: url)
            if !text.isEmpty { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// Sets what `gh <key>` prints to a fixture file's content.
    func respond(_ key: String, fixture: String) throws {
        try respond(key, out: try Fixtures.text("github/\(fixture)"))
    }

    /// The usual signed-in answers: version, sign-in, repository, no pull request.
    func signedIn() throws {
        try respond("version", fixture: "version.txt")
        try respond("auth_status", fixture: "auth-signed-in.tsv")
        try respond("repo_view", fixture: "repo-view.json")
        try respond("pr_list", fixture: "pr-list-empty.json")
    }

    /// Every call so far, oldest first.
    func calls() -> [[String]] {
        GitHubFolders.calls(in: dir.appendingPathComponent("calls"))
    }

    /// The folder each call ran in.
    func folders() -> [String] {
        let folder = dir.appendingPathComponent("calls")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".cwd") }.sorted()
        return names.compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func calls(_ command: String, _ sub: String) -> [[String]] {
        calls().filter { $0.starts(with: [command, sub]) }
    }

    /// A service on this gh whose git refuses every push (see `LoggingGit`); every folder counts as trusted.
    var service: GitHubService {
        let path = self.path
        let git = (try? LoggingGit())?.runner ?? GitRunner(gitPath: "/usr/bin/false")
        return GitHubService(git: git, locateGH: { path }, isTrusted: { _ in true })
    }
}

/// A git that records every call before running `/usr/bin/git`. With `pushingTo` set, ssh remotes go through
/// the stand-in ssh, which never connects anywhere and hands the push to that local bare repository; without
/// it every push is refused.
struct LoggingGit {
    let dir: URL
    var path: String { dir.appendingPathComponent("git").path }

    init(pushingTo bare: URL? = nil) throws {
        dir = try GitHubFolders.make("ensemble-logging-git")
        try Self.install("github/fake-git.sh", as: "git", in: dir)
        if let bare {
            try Self.install("github/fake-ssh.sh", as: "ssh", in: dir)
            try bare.path.write(to: dir.appendingPathComponent("bare"), atomically: true, encoding: .utf8)
            try dir.appendingPathComponent("ssh").path.write(to: dir.appendingPathComponent("ssh-shim"), atomically: true, encoding: .utf8)
        }
    }

    static func install(_ fixture: String, as name: String, in dir: URL) throws {
        let script = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Fixtures.url(fixture), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    var runner: GitRunner { GitRunner(gitPath: path) }

    func calls() -> [[String]] {
        GitHubFolders.calls(in: dir.appendingPathComponent("git-calls"))
    }

    /// "<host> <command>" for each connection the stand-in ssh was asked to make.
    func sshLog() -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("ssh-log"), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The push commands among the calls.
    func pushes() -> [[String]] {
        calls().filter { $0.contains("push") }
    }
}

enum GitHubFolders {
    static func make(_ name: String) throws -> URL {
        let parent = ProcessInfo.processInfo.environment["ENSEMBLE_GIT_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let dir = parent.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    static func calls(in folder: URL) -> [[String]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.contains(".") }.sorted()
        return names.compactMap { name in
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else { return nil }
            var args = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            if args.last == "" { args.removeLast() }
            return args
        }
    }
}

/// A repository whose `origin` is git@github.com:acme/widgets.git. Its pushes go through `loggingGit`, whose
/// stand-in ssh hands them to a local bare repository, so a push never leaves the Mac.
struct GitHubTestRepo {
    let helper = GitReviewServiceTests()
    let work: URL
    let bare: URL
    let loggingGit: LoggingGit
    static let remoteURL = "git@github.com:acme/widgets.git"

    init(files: [String: String] = ["README.md": "hello\n"], remoteURL: String = GitHubTestRepo.remoteURL, pushMain: Bool = true,
         setHead: Bool = true) throws {
        work = try helper.makeRepo(files: files)
        bare = try GitHubFolders.make("ensemble-bare")
        loggingGit = try LoggingGit(pushingTo: bare)
        try helper.git(["init", "-q", "--bare", "-b", "main"], in: bare)
        try helper.git(["remote", "add", "origin", remoteURL], in: work)
        if pushMain {
            // Straight to the bare repository's path, then the remote-tracking branch a fetch would have made.
            try helper.git(["push", "-q", bare.path, "main:main"], in: work)
            try helper.git(["update-ref", "refs/remotes/origin/main", "refs/heads/main"], in: work)
            if setHead { try helper.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: work) }
        }
    }

    /// A service that pushes through the stand-in ssh, with gh at `gh` (or not installed).
    func service(_ gh: FakeGH? = nil, trusted: Bool = true) -> GitHubService {
        let path = gh?.path
        return GitHubService(git: loggingGit.runner, locateGH: { path }, isTrusted: { _ in trusted })
    }

    @discardableResult
    func git(_ args: [String], in dir: URL? = nil) throws -> String {
        try helper.git(args, in: dir ?? work)
    }

    func commit(_ file: String, _ content: String, message: String) throws {
        try helper.write(content, file, in: work)
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", message])
    }

    /// The commit the bare remote has for `branch`, or nil.
    func remoteHead(_ branch: String) -> String? {
        (try? helper.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: bare))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// True when no argument forces, deletes or asks for a token.
func isSafeCommand(_ args: [String]) -> Bool {
    let forbidden: Set<String> = ["--force", "-f", "--force-with-lease", "--force-if-includes", "--mirror", "--delete",
                                  "--show-token", "token", "--with-token", "login", "logout", "setup-git", "--admin"]
    for arg in args {
        let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        if forbidden.contains(flag) { return false }
        if GitHubParsing.containsToken(arg) { return false }
    }
    if args.first == "push", args.contains(where: { $0.hasPrefix("+") || $0.hasPrefix(":") }) { return false }
    return true
}
#endif
