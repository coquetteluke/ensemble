import Foundation

/// What one `claude` process is started with.
struct ClaudeLaunchOptions: Equatable, Sendable {
    enum Start: Equatable, Sendable {
        /// A new conversation with this id (`--session-id`).
        case new
        /// Continue the conversation (`--resume`).
        case resume
        /// Copy another conversation into this new id (`--resume <from> --fork-session --session-id <id>`).
        case fork(from: String)
    }

    /// The CLI session id.
    var sessionID: String
    var start: Start
    /// Resume only up to and including this chain entry (`--resume-session-at`, for rewinds and forks at a message).
    var resumeAt: String?
    /// Model id or alias (`sonnet`, `claude-opus-5-5`, `opus[1m]`); nil keeps the user's default.
    var model: String?
    /// `--effort` level.
    var effort: String?
    var permissionMode: PermissionMode
    var settingSources: ClaudeSettingSources
    /// `--thinking-display` (`summarized`, `omitted`); nil keeps the CLI default (token counts only).
    var thinkingDisplay: String?
    /// `--fast-mode on|off`; nil keeps the user's setting.
    var fastMode: Bool?
    var extraArguments: [String] = []
}

/// Building the `claude` command line and environment. Ensemble only ever runs the unmodified CLI as itself: no
/// `--bare`, no changed identity, no proxy, and it never reads or passes the CLI's own login.
enum ClaudeCLI {
    /// The argv after the executable. Prompts never go in argv (other users can read argv with `ps`); they are
    /// written to stdin as stream-json.
    static func arguments(_ options: ClaudeLaunchOptions) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Subagent text and thinking arrive with parent_tool_use_id, so subagents get their own live transcripts.
            "--forward-subagent-text",
            "--permission-mode", ClaudePermissionModes.cliMode(options.permissionMode),
            // Permission prompts go to the host over stdio as `can_use_tool` control requests (what the Agent SDK
            // uses). An MCP permission tool was tested too and timed out after about 60 s of waiting for a person.
            "--permission-prompts", "host",
            "--permission-prompt-tool", "stdio",
        ]
        if options.permissionMode == .bypass { args.append("--allow-dangerously-skip-permissions") }
        if let model = options.model, !model.isEmpty { args += ["--model", model] }
        if let effort = options.effort, ClaudeModels.effortLevels.contains(effort) { args += ["--effort", effort] }
        if let display = options.thinkingDisplay, !display.isEmpty { args += ["--thinking-display", display] }
        if let fast = options.fastMode { args += ["--fast-mode", fast ? "on" : "off"] }
        if let sources = options.settingSources.argument { args += ["--setting-sources", sources] }
        switch options.start {
        case .new:
            args += ["--session-id", options.sessionID]
        case .resume:
            args += ["--resume", options.sessionID]
            if let at = options.resumeAt { args += ["--resume-session-at", at] }
        case .fork(let from):
            args += ["--resume", from, "--fork-session", "--session-id", options.sessionID]
            if let at = options.resumeAt { args += ["--resume-session-at", at] }
        }
        args += options.extraArguments.filter { !forbiddenArguments.contains($0) }
        return args
    }

    /// Never passed, even as an extra argument: `--bare` ignores the subscription login (and skips its refresh), and
    /// the skip-permissions switches would bypass the permission mode the user picked in Ensemble.
    static let forbiddenArguments: Set<String> = ["--bare", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"]

    /// Variables passed through from Ensemble's own environment. Everything else is dropped, in particular every
    /// `ANTHROPIC_*` and `CLAUDE_*` variable (a shell started inside another Claude Code session carries an API base
    /// URL and session tokens, and in `-p` mode a present `ANTHROPIC_API_KEY` would bill the API instead of the plan).
    static let passThrough: Set<String> = [
        "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TMPDIR", "SHELL", "SSH_AUTH_SOCK",
        "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
        "__CF_USER_TEXT_ENCODING",
    ]

    /// The child environment: an allowlist of the parent's variables, a usable PATH, and, only for API billing,
    /// the agent's API key.
    static func environment(base: [String: String], billing: ClaudeBilling, apiKey: String?, fileCheckpointing: Bool = false) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in base where passThrough.contains(key) { env[key] = value }
        let home = env["HOME"] ?? NSHomeDirectory()
        env["HOME"] = home
        var path = (base["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // File snapshots before each edit, so a rewind can restore files (the Agent SDK's enableFileCheckpointing).
        if fileCheckpointing { env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1" }
        if billing == .apiKey, let apiKey, !apiKey.isEmpty {
            env["ANTHROPIC_API_KEY"] = apiKey
            // Keeps the key out of the agent's Bash commands and hooks.
            env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        }
        return env
    }

    /// Where `claude` is installed, if anywhere.
    static func locate(override: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The user message line for stdin. `priority` is the CLI's queue priority for a message that arrives while a turn
    /// runs: `next` folds it into that turn after the tool calls in flight, `later` waits for the turn to end.
    static func userMessage(blocks: [JSONValue], priority: String? = nil) -> JSONValue {
        var line: [String: JSONValue] = [
            "type": "user",
            "session_id": "",
            "message": ["role": "user", "content": .array(blocks)],
            "parent_tool_use_id": nil,
        ]
        if let priority { line["priority"] = .string(priority) }
        return .object(line)
    }

    /// Content blocks for a prompt: queued synthetic texts, the text, then attachments. Images go inline (base64);
    /// other files are listed by path so the agent reads them with its own tools.
    static func contentBlocks(synthetic: [String], text: String, files: [URL]) throws -> [JSONValue] {
        var blocks: [JSONValue] = synthetic.map { ["type": "text", "text": .string($0)] }
        if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        var listed: [String] = []
        for url in files {
            guard url.isFileURL else { throw ClaudeCodeError.invalidArgument("Attachments must be local files: \(url)") }
            let ext = url.pathExtension.lowercased()
            let mediaTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
            if let media = mediaTypes[ext], let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024 {
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": .string(media), "data": .string(data.base64EncodedString())]])
            } else {
                listed.append(url.path)
            }
        }
        if !listed.isEmpty {
            blocks.append(["type": "text", "text": .string(ClaudeTranscriptBuilder.attachedFilesPrefix + "\n" + listed.joined(separator: "\n"))])
        }
        if blocks.isEmpty { throw ClaudeCodeError.invalidArgument("The message is empty.") }
        return blocks
    }
}

/// Sign-in state from `claude auth status` (the CLI's own command). Only these fields are kept; the account email
/// and organisation the command also prints are dropped at once.
public struct ClaudeAuthState: Equatable, Sendable {
    public var installed: Bool
    public var version: String?
    public var loggedIn: Bool
    /// `claude.ai` for a subscription login, or the API key source.
    public var authMethod: String?
    /// `pro`, `max`, ... when signed in with a subscription.
    public var subscriptionType: String?

    public init(installed: Bool, version: String? = nil, loggedIn: Bool = false, authMethod: String? = nil, subscriptionType: String? = nil) {
        self.installed = installed
        self.version = version
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.subscriptionType = subscriptionType
    }

    static func parse(_ text: String, installed: Bool, version: String?) -> ClaudeAuthState {
        guard let json = JSONValue.parse(line: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ClaudeAuthState(installed: installed, version: version)
        }
        return ClaudeAuthState(installed: installed, version: version, loggedIn: json["loggedIn"]?.boolValue ?? false,
                               authMethod: json["authMethod"]?.stringValue, subscriptionType: json["subscriptionType"]?.stringValue)
    }
}

#if os(macOS)
enum ClaudeCommand {
    /// Runs a short `claude` command (version, auth status) with a timeout and returns stdout.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration = .seconds(15)) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let box = ClaudeOutputBox()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { box.append(data) }
        }
        let exited = ClaudeExitSignal()
        process.terminationHandler = { _ in exited.fire() }
        do { try process.run() } catch { return nil }
        let finished = await exited.wait(timeout: timeout)
        if !finished {
            process.terminate()
            return nil
        }
        // Let the reader drain what is left in the pipe.
        try? await Task.sleep(for: .milliseconds(50))
        out.fileHandleForReading.readabilityHandler = nil
        box.append(out.fileHandleForReading.availableData)
        return String(decoding: box.data, as: UTF8.self)
    }
}

final class ClaudeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int?

    init(limit: Int? = nil) { self.limit = limit }

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if let limit, buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        }
    }

    var data: Data { lock.withLock { buffer } }
}

/// A one-shot signal that an async caller can wait on with a timeout.
final class ClaudeExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func fire() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            fired = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: true) }
    }

    var isFired: Bool { lock.withLock { fired } }

    /// True if it fired, false on timeout.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first { self.fireTimeout() }
            return first
        }
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume(returning: true) }
        }
    }

    /// Releases waiters after a timeout without marking the signal as fired.
    private func fireTimeout() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: false) }
    }
}
#endif
