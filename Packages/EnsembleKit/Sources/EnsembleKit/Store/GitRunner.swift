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
/// Every run reads no repository-defined programs it can avoid: no file system monitor, no pager, no
/// prompts, and pathspecs are literal (a file named `a[1].txt` never matches other files). Variables that
/// would point git somewhere else (`GIT_DIR`, `GIT_INDEX_FILE`, ...) are dropped from the inherited
/// environment, so a run only ever touches the folder it was given.
public struct GitRunner: Sendable {
    public var gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    static let droppedVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES", "GIT_EXTERNAL_DIFF",
        "GIT_DIFF_OPTS", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    ]

    /// Runs `git -C <directory> <args>`. `environment` adds or replaces variables for this run only.
    public func run(_ args: [String], in directory: String, environment: [String: String] = [:]) async -> GitOutput {
        let path = gitPath
        var env = ProcessInfo.processInfo.environment.filter { !Self.droppedVariables.contains($0.key) && !$0.key.hasPrefix("GIT_CONFIG_KEY_") && !$0.key.hasPrefix("GIT_CONFIG_VALUE_") }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_LITERAL_PATHSPECS"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        for (key, value) in environment { env[key] = value }
        let arguments = ["-C", directory, "-c", "core.quotePath=false", "-c", "core.fsmonitor=false", "-c", "color.ui=false"] + args
        let finalEnvironment = env
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runSync(path: path, arguments: arguments, environment: finalEnvironment))
            }
        }
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
