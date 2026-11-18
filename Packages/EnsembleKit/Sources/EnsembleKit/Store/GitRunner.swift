import Foundation

/// What one `git` run printed.
public struct GitOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    /// Standard output as UTF-8 text (invalid bytes become U+FFFD).
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    /// Standard output, first line, without the newline.
    public var line: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

#if os(macOS)
/// Runs `/usr/bin/git` with explicit arguments (never through a shell), always inside one folder.
///
/// No run lets the folder's own settings start a program (see `GitSafety`): each run first reads the folder's
/// config (reading runs nothing), then runs the command with overrides that switch off the file system monitor,
/// filters, diff converters and tools, hooks, pagers, editors, password prompts and the repository's own SSH,
/// signing, credential and pack programs. System config is never read. Only `allowsHooks` lets hooks run, for a
/// commit the user asked for. A run whose config cannot be read does not run at all.
///
/// Pathspecs are literal (a file named `a[1].txt` never matches other files), and variables that would point git
/// somewhere else (`GIT_DIR`, `GIT_INDEX_FILE`, ...) are dropped from the inherited environment, so a run only ever
/// touches the folder it was given.
public struct GitRunner: Sendable {
    public var gitPath: String
    /// Lets the repository's hooks run (`core.hooksPath` and `hook.<name>` config). Only for a commit the user asked
    /// for in a trusted folder; every other run has hooks off.
    public var allowsHooks = false

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    static let droppedVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES", "GIT_EXTERNAL_DIFF",
        "GIT_DIFF_OPTS", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    ]

    /// Runs `git -C <directory> <args>`. `environment` adds or replaces variables for this run only; it cannot
    /// undo the safety settings.
    public func run(_ args: [String], in directory: String, environment: [String: String] = [:]) async -> GitOutput {
        let path = gitPath
        let allowHooks = allowsHooks
        var env = ProcessInfo.processInfo.environment.filter { !Self.isConfigVariable($0.key) && !Self.droppedVariables.contains($0.key) }
        env["GIT_LITERAL_PATHSPECS"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        for (key, value) in environment where !Self.isConfigVariable(key) { env[key] = value }
        for (key, value) in GitSafety.environment { env[key] = value }
        let base = env
        let overrides = GitSafety.staticOverrides(allowHooks: allowHooks).flatMap { ["-c", "\($0.key)=\($0.value)"] }
        let prefix = ["-C", directory] + overrides
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Read the folder's config first; it decides which drivers and programs to switch off.
                let list = Self.runSync(path: path, arguments: prefix + ["config", "--show-scope", "-z", "--list"], environment: base)
                guard list.succeeded else {
                    continuation.resume(returning: list)
                    return
                }
                var runEnvironment = base
                let dynamic = GitSafety.dynamicOverrides(GitSafety.parseConfigList(list.stdout), allowHooks: allowHooks)
                runEnvironment["GIT_CONFIG_COUNT"] = String(dynamic.count)
                for (index, pair) in dynamic.enumerated() {
                    runEnvironment["GIT_CONFIG_KEY_\(index)"] = pair.key
                    runEnvironment["GIT_CONFIG_VALUE_\(index)"] = pair.value
                }
                continuation.resume(returning: Self.runSync(path: path, arguments: prefix + args, environment: runEnvironment))
            }
        }
    }

    /// Variables that carry config into git; only the runner's own are passed.
    private static func isConfigVariable(_ key: String) -> Bool {
        key == "GIT_CONFIG_COUNT" || key == "GIT_CONFIG_PARAMETERS" || key == "GIT_CONFIG" || key == "GIT_CONFIG_GLOBAL"
            || key == "GIT_CONFIG_SYSTEM" || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_")
    }

    private static func runSync(path: String, arguments: [String], environment: [String: String]) -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
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
        // Read both pipes at once so a full stderr pipe can never stall the process.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return GitOutput(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errBox.get(), as: UTF8.self))
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
#endif
