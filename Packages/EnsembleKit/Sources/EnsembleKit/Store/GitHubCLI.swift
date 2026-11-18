import Foundation

/// The only gh and git push command lines Ensemble runs for GitHub. Checked just before each run, so a
/// mistake elsewhere can never force-push, ask gh for a token, or run gh's sign-in.
public enum GitHubCommandPolicy {
    /// gh subcommands Ensemble may run. Anything else (`auth token`, `auth login`, `api`, ...) is refused.
    public static let allowedCommands: [[String]] = [
        ["--version"], ["auth", "status"], ["repo", "view"], ["pr", "list"], ["pr", "view"], ["pr", "create"],
        ["pr", "merge"], ["run", "view"],
    ]

    /// Arguments refused anywhere in a gh command line.
    static let forbiddenGHArguments: Set<String> = [
        "--show-token", "-t", "--with-token", "--force", "-f", "--admin", "--web", "-w", "--insecure-storage",
    ]

    /// Arguments refused anywhere in a git push.
    static let forbiddenPushArguments: Set<String> = [
        "--force", "-f", "--force-with-lease", "--force-if-includes", "--mirror", "--delete", "-d", "--prune", "--all",
        "--tags", "--follow-tags", "--no-verify",
    ]

    /// Why the gh command line is refused, or nil when it may run.
    public static func ghViolation(_ args: [String]) -> String? {
        guard allowedCommands.contains(where: { args.starts(with: $0) }) else {
            return "Ensemble does not run gh \(args.prefix(2).joined(separator: " "))"
        }
        for arg in args {
            let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if forbiddenGHArguments.contains(flag) { return "Ensemble does not run gh with \(flag)" }
        }
        if args.starts(with: ["auth", "status"]), args.contains("token") { return "Ensemble does not ask gh for a token" }
        return nil
    }

    /// Why the git push is refused, or nil when it may run: one branch, pushed to the same name, never forced.
    /// `-c key=value` settings before `push` are allowed only to switch extra pushing off.
    public static func pushViolation(_ args: [String]) -> String? {
        var args = args[...]
        while args.first == "-c" {
            let setting = args.dropFirst().first ?? ""
            guard ["push.followTags=false", "push.recurseSubmodules=no"].contains(setting) else { return "Unexpected setting \(setting)" }
            args = args.dropFirst(2)
        }
        guard args.first == "push" else { return "Not a push" }
        let rest = args.dropFirst()
        for arg in rest {
            let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if forbiddenPushArguments.contains(flag) { return "Ensemble does not push with \(flag)" }
        }
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard positional.count == 2 else { return "A push names one remote and one branch" }
        let refspec = positional[1]
        guard !refspec.hasPrefix("+"), !refspec.hasPrefix(":") else { return "Ensemble never force-pushes or deletes a branch" }
        let sides = refspec.split(separator: ":", omittingEmptySubsequences: false)
        guard sides.count == 2, sides[0] == sides[1], sides[0].hasPrefix("refs/heads/") else {
            return "A push sends a branch to the same name"
        }
        return nil
    }
}

#if os(macOS)
/// Runs the GitHub CLI (`gh`) with explicit arguments, never through a shell. gh keeps the sign-in: Ensemble
/// never asks it for a token and never reads its files. Every command line is checked by
/// `GitHubCommandPolicy` first.
public struct GitHubCLI: Sendable {
    public var path: String
    /// Seconds before a run is stopped.
    public var timeout: TimeInterval

    public init(path: String, timeout: TimeInterval = 60) {
        self.path = path
        self.timeout = timeout
    }

    /// Where gh is installed: `ENSEMBLE_GH_PATH` when set, then Homebrew's and the usual folders, then `PATH`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let files = FileManager.default
        if let override = environment["ENSEMBLE_GH_PATH"], !override.isEmpty {
            return files.isExecutableFile(atPath: override) ? override : nil
        }
        var candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh",
                          (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/gh")]
        for folder in (environment["PATH"] ?? "").split(separator: ":") where !folder.isEmpty {
            candidates.append((String(folder) as NSString).appendingPathComponent("gh"))
        }
        return candidates.first { files.isExecutableFile(atPath: $0) }
    }

    static let droppedVariables: Set<String> = GitRunner.droppedVariables.union([
        "GH_DEBUG", "DEBUG", "GH_FORCE_TTY", "GH_PAGER", "PAGER", "GH_BROWSER", "BROWSER", "GH_EDITOR", "GIT_EDITOR",
        "VISUAL", "EDITOR",
    ])

    /// The environment gh runs with: no prompts, colours, pager, browser or update checks, and git (which gh
    /// starts) without a file system monitor.
    static func environment(base: [String: String], ghPath: String) -> [String: String] {
        var env = base.filter {
            !droppedVariables.contains($0.key) && !$0.key.hasPrefix("GIT_CONFIG_KEY_") && !$0.key.hasPrefix("GIT_CONFIG_VALUE_")
        }
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_SPINNER_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        env["GH_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_CONFIG_COUNT"] = "2"
        env["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
        env["GIT_CONFIG_VALUE_0"] = "false"
        env["GIT_CONFIG_KEY_1"] = "core.pager"
        env["GIT_CONFIG_VALUE_1"] = "cat"
        let folder = (ghPath as NSString).deletingLastPathComponent
        let path = [folder, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + (base["PATH"].map { [$0] } ?? [])
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// An empty folder gh runs in. Every command names its repository with `--repo`, so gh never needs the
    /// session folder, and any git that gh starts never reads that folder's config.
    static func neutralFolder() -> String {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("ensemble-gh")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs `gh <args>` in `directory`, or in an empty folder of its own when nil. A refused command line never
    /// starts gh and returns status -2 with the reason.
    public func run(_ args: [String], in directory: String? = nil, timeout: TimeInterval? = nil) async -> GitOutput {
        if let violation = GitHubCommandPolicy.ghViolation(args) {
            return GitOutput(status: -2, stdout: Data(), stderr: violation)
        }
        let path = self.path
        let cwd = directory ?? Self.neutralFolder()
        var env = Self.environment(base: ProcessInfo.processInfo.environment, ghPath: path)
        if directory == nil { env["GIT_CEILING_DIRECTORIES"] = (cwd as NSString).deletingLastPathComponent }
        let environment = env
        let limit = timeout ?? self.timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ProcessRun.run(path: path, arguments: args, environment: environment, directory: cwd, timeout: limit))
            }
        }
    }
}

/// One process run with both pipes drained and a time limit.
enum ProcessRun {
    static func run(path: String, arguments: [String], environment: [String: String], directory: String, timeout: TimeInterval) -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return GitOutput(status: -1, stdout: Data(), stderr: error.localizedDescription)
        }
        let box = ProcessBox(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.stopIfRunning() }
        let errData = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        if box.timedOut {
            return GitOutput(status: -3, stdout: outData, stderr: "Took longer than \(Int(timeout)) seconds")
        }
        return GitOutput(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData.get(), as: UTF8.self))
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var stopped = false
    init(_ process: Process) { self.process = process }

    func stopIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning {
            stopped = true
            process.terminate()
        }
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
#endif
