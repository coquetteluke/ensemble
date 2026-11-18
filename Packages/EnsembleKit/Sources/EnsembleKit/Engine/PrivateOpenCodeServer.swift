import Foundation
import Observation
#if os(macOS)
import Darwin
#endif

/// Why the private OpenCode server for untrusted folders cannot take a session.
public enum PrivateOpenCodeError: Error, LocalizedError, Equatable, Sendable {
    /// The server is starting, stopped, or failed. Carries the reason.
    case notRunning(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning(let reason):
            "OpenCode for folders you have not trusted is not running (\(reason)), so the session was not started. "
                + "Try again in a moment."
        }
    }
}

/// A second OpenCode server, private to Ensemble, for folders the user has not trusted (`WorkspaceTrust`).
///
/// OpenCode loads a project's own config in every folder it serves (`opencode.json`, `.opencode/` plugins, MCP servers,
/// commands, formatters, `AGENTS.md`, from the folder and every folder above it), and the only switch is
/// `OPENCODE_DISABLE_PROJECT_CONFIG=1`, read once when the process starts (see `PermissionRules`). The user's shared
/// background service cannot have it turned on without changing every folder, so Ensemble runs this second server
/// with it, and `EngineRouter` sends new OpenCode sessions in untrusted folders here.
///
/// - Started as `opencode serve --service --hostname 127.0.0.1 --port 0` with its own data and state folders
///   (`XDG_DATA_HOME`, `XDG_STATE_HOME`), so its database, sessions, snapshots and sockets are its own. With `--service`
///   OpenCode makes its own password and writes it, with the address, to `state/opencode/service.json` (0600), the way
///   the shared service does. The password is never in the server's environment, which every command an agent runs
///   inherits (checked live: `OPENCODE_SERVER_PASSWORD` would reach them).
/// - What agent commands do inherit: `XDG_DATA_HOME` and `XDG_STATE_HOME` (paths only; see `dataDirectory` for what the
///   folders hold), `OPENCODE_DISABLE_PROJECT_CONFIG`, and the app's own environment. Those folders are 0700 and the
///   database and service file 0600; an agent command runs as the user, so like the shared service's own files
///   (`~/.local/share/opencode`, `~/.local/state/opencode/service.json`) they are protected from other users, not from
///   commands the user lets an agent run.
/// - The user's config folder and cache stay shared, so user-level config, providers and MCP servers are the same as
///   in the shared service.
/// - Credentials live in each server's database. API keys and external credentials (cloud profiles) are copied from
///   the shared service and kept in step (`credentialSource`). Browser sign-ins (OAuth) are not copied: two servers
///   refreshing one sign-in would log each other out, so those providers only work in trusted folders
///   (`signInOnlyProviders`; `EngineRouter` refuses them there).
/// - A small `/bin/sh` wrapper holds the server: when Ensemble stops it, quits or crashes, the wrapper's input closes
///   and it stops the server, so no server outlives the app.
/// - Never touches the shared service.
@MainActor
@Observable
public final class PrivateOpenCodeServer {
    public struct Configuration: Sendable {
        /// `~/Library/Application Support/Ensemble/OpenCode untrusted` (0700). `data/opencode/` holds the database
        /// (sessions, transcripts, copied API keys), logs and snapshots of project files; `state/opencode/` holds
        /// `service.json` (address, process id, password) and terminal sockets.
        public var dataDirectory: URL
        /// Added to the server's environment last (tests point `OPENCODE_CONFIG` at a user-level config).
        public var extraEnvironment: [String: String]
        public var baseEnvironment: [String: String]
        /// Project folder for location-scoped calls that do not name one.
        public var defaultDirectory: String?

        public init(dataDirectory: URL = PrivateOpenCodeServer.defaultDataDirectory, extraEnvironment: [String: String] = [:],
                    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, defaultDirectory: String? = nil) {
            self.dataDirectory = dataDirectory
            self.extraEnvironment = extraEnvironment
            self.baseEnvironment = baseEnvironment
            self.defaultDirectory = defaultDirectory
        }
    }

    public nonisolated static var defaultDataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/OpenCode untrusted", isDirectory: true)
    }

    public private(set) var status: EngineStatus = .starting
    /// A client for the running server, nil while it is not answering.
    public private(set) var client: OpenCodeClient?
    /// Goes up each time a new server process answers for the first time (start and every restart).
    public private(set) var generation = 0
    /// Providers signed in on the shared service only through a browser sign-in, which is not copied here, so they do
    /// not work in untrusted folders. Updated with the credentials.
    public private(set) var signInOnlyProviders: Set<String> = []

    @ObservationIgnored public let configuration: Configuration
    /// The shared service, whose API keys and external credentials are copied here (nil copies nothing).
    @ObservationIgnored public var credentialSource: OpenCodeClient?
    /// How often a healthy server is checked (and credentials brought in step).
    @ObservationIgnored public var healthInterval: Duration = .seconds(15)
    /// Called with the new client each time a server process answers for the first time.
    @ObservationIgnored public var onReady: (@MainActor (OpenCodeClient) -> Void)?
    /// Called when `signInOnlyProviders` changes.
    @ObservationIgnored public var onSignInOnlyProvidersChanged: (@MainActor (Set<String>) -> Void)?
    @ObservationIgnored private var executable: URL?
    /// Checks in a row that the running server did not answer; it is restarted after three (a busy server gets time).
    @ObservationIgnored private var unhealthyChecks = 0
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    #if os(macOS)
    @ObservationIgnored private var process: PrivateServerProcess?
    #endif

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Starts the server with `executable` (the `opencode` the shared service uses) and keeps it running, restarting
    /// it with backoff when it stops answering. Calling it again restarts the loop.
    public func start(executable: URL) {
        self.executable = executable
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let healthy = await self.checkNow()
                if Task.isCancelled { return }
                if healthy {
                    failures = 0
                    try? await Task.sleep(for: self.healthInterval)
                } else {
                    failures += 1
                    let delay = min(60.0, pow(2.0, Double(min(failures, 6))))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    /// Stops the server and the checks. With `wait` 0 (quitting) the wrapper stops the server on its own.
    public func stop(wait: TimeInterval = 3) {
        monitorTask?.cancel()
        monitorTask = nil
        client = nil
        status = .failed("stopped")
        #if os(macOS)
        let old = process
        process = nil
        old?.stop(wait: wait)
        #endif
    }

    /// One check: starts the server when it is not running, checks it answers, and copies credentials.
    @discardableResult
    public func checkNow() async -> Bool {
        #if os(macOS)
        guard let executable else {
            status = .failed("OpenCode is not installed")
            return false
        }
        if let process, process.isRunning, let client {
            if (try? await client.serverInfo()) != nil {
                unhealthyChecks = 0
                await syncCredentials()
                if case .running = status {} else { status = .running(version: process.version ?? "", url: client.baseURL) }
                return true
            }
            unhealthyChecks += 1
            if unhealthyChecks < 3 { return false }
        }
        unhealthyChecks = 0
        // Not running or not answering: start a fresh one. The old one is stopped off the main thread.
        if let old = process { Task.detached { old.stop(wait: 3) } }
        process = nil
        client = nil
        status = .starting
        do {
            try Self.prepareFolders(configuration.dataDirectory)
            // A service file left by an earlier run must not be mistaken for the new server's.
            try? FileManager.default.removeItem(at: serviceFileURL)
            let environment = Self.environment(base: configuration.baseEnvironment, dataDirectory: configuration.dataDirectory,
                                               executable: executable, extra: configuration.extraEnvironment)
            let launched = try PrivateServerProcess.launch(executable: executable, environment: environment,
                                                           workingDirectory: configuration.dataDirectory)
            process = launched
            guard let url = await launched.waitForURL(timeout: 30),
                  let service = await Self.waitForServiceFile(serviceFileURL, url: url, timeout: 10) else {
                Task.detached { launched.stop(wait: 3) }
                process = nil
                status = .failed("the server did not report its address")
                return false
            }
            Self.lockDown(configuration.dataDirectory)
            let candidate = OpenCodeClient(baseURL: url, password: service.password, defaultDirectory: configuration.defaultDirectory)
            var info: (version: String, url: URL)?
            for _ in 0..<40 {
                if let answer = try? await candidate.serverInfo() { info = answer; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let info else {
                Task.detached { launched.stop(wait: 3) }
                process = nil
                status = .failed("the server did not answer")
                return false
            }
            launched.version = info.version
            client = candidate
            generation += 1
            await syncCredentials()
            status = .running(version: info.version, url: url)
            onReady?(candidate)
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
        #else
        status = .failed("OpenCode runs on the Mac.")
        return false
        #endif
    }

    // MARK: Credentials

    /// Brings this server's API keys and external credentials in step with `credentialSource`, and updates
    /// `signInOnlyProviders`. Errors are dropped (the next check tries again); secret values are never logged or shown.
    public func syncCredentials() async {
        guard let source = credentialSource, let target = client else { return }
        do {
            let wanted: Wire.DataEnvelope<[JSONValue]> = try await source.get("/api/credential")
            let signInOnly = Self.signInOnlyProviders(in: wanted.data)
            if signInOnly != signInOnlyProviders {
                signInOnlyProviders = signInOnly
                onSignInOnlyProvidersChanged?(signInOnly)
            }
            let present: Wire.DataEnvelope<[JSONValue]> = try await target.get("/api/credential")
            let plan = Self.credentialPlan(source: wanted.data, target: present.data)
            for id in plan.remove {
                try? await target.sendIgnoringBody("DELETE", "/api/credential/\(OpenCodeClient.pathComponent(id))")
            }
            for body in plan.create {
                let _: Wire.DataEnvelope<JSONValue>? = try? await target.send("POST", "/api/credential", body: body)
            }
        } catch {
            return
        }
    }

    /// Integrations with a browser sign-in (OAuth) and no copyable credential (API key or external) on the shared service.
    nonisolated static func signInOnlyProviders(in source: [JSONValue]) -> Set<String> {
        var signIn = Set<String>()
        var copyable = Set<String>()
        for entry in source {
            guard let integration = entry["integrationID"]?.stringValue, let type = entry["value"]?["type"]?.stringValue else { continue }
            if type == "oauth" { signIn.insert(integration) } else if type == "key" || type == "external" { copyable.insert(integration) }
        }
        return signIn.subtracting(copyable)
    }

    /// What to change on this server so its copyable credentials match the shared service's: entries to remove (by id)
    /// and bodies for `POST /api/credential`. Only `key` and `external` credentials are copied; inactive ones are
    /// created first so the active one ends up active.
    nonisolated static func credentialPlan(source: [JSONValue], target: [JSONValue]) -> (create: [JSONValue], remove: [String]) {
        func copyable(_ entry: JSONValue) -> Bool {
            guard let type = entry["value"]?["type"]?.stringValue else { return false }
            return type == "key" || type == "external"
        }
        let wanted = source.filter { copyable($0) && $0["id"]?.stringValue != nil && $0["integrationID"]?.stringValue != nil }
        var byID: [String: JSONValue] = [:]
        for entry in target { if let id = entry["id"]?.stringValue { byID[id] = entry } }
        let wantedIDs = Set(wanted.compactMap { $0["id"]?.stringValue })
        var remove = byID.keys.filter { !wantedIDs.contains($0) }.sorted()
        var create: [JSONValue] = []
        for entry in wanted {
            guard let id = entry["id"]?.stringValue else { continue }
            if let existing = byID[id] {
                let same = existing["value"] == entry["value"] && existing["integrationID"] == entry["integrationID"]
                    && existing["label"] == entry["label"] && existing["active"] == entry["active"]
                if same { continue }
                remove.append(id)
            }
            var body: [String: JSONValue] = [
                "id": .string(id),
                "integrationID": entry["integrationID"] ?? .null,
                "value": entry["value"] ?? .null,
                "activate": entry["active"] ?? .bool(false),
            ]
            if let label = entry["label"] { body["label"] = label }
            create.append(.object(body))
        }
        create.sort { ($0["activate"] == .bool(true) ? 1 : 0) < ($1["activate"] == .bool(true) ? 1 : 0) }
        return (create, remove)
    }

    // MARK: Process setup

    /// `state/opencode/service.json`, written by the server.
    var serviceFileURL: URL {
        configuration.dataDirectory.appendingPathComponent("state/opencode/service.json")
    }

    /// The server process's id, once known (tests).
    var serverProcessID: Int32? {
        #if os(macOS)
        return process?.serverProcessID
        #else
        return nil
        #endif
    }

    /// Creates the folder, `data/` and `state/`, all 0700 (existing ones are tightened too).
    nonisolated static func prepareFolders(_ directory: URL) throws {
        let fm = FileManager.default
        for folder in [directory, directory.appendingPathComponent("data"), directory.appendingPathComponent("state")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// Tightens what the server created: its folders 0700, the database and service file 0600.
    nonisolated static func lockDown(_ directory: URL) {
        let fm = FileManager.default
        for folder in ["data/opencode", "state/opencode"] {
            let path = directory.appendingPathComponent(folder).path
            if fm.fileExists(atPath: path) { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        }
        for file in ["data/opencode/opencode.db", "data/opencode/opencode.db-wal", "data/opencode/opencode.db-shm",
                     "state/opencode/service.json"] {
            let path = directory.appendingPathComponent(file).path
            if fm.fileExists(atPath: path) { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        }
    }

    /// Waits for the server's service file to name the address it printed.
    nonisolated static func waitForServiceFile(_ url: URL, url address: URL, timeout: TimeInterval) async -> ServiceFile? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let file = try? ServiceFile.read(from: url), file.url.port == address.port, file.url.host == address.host,
               !file.password.isEmpty {
                return file
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The server's environment: the app's own, without anything that would point it at the shared service's data or
    /// put a password in it, plus the project-config switch and its own data and state folders.
    nonisolated static func environment(base: [String: String], dataDirectory: URL, executable: URL,
                                        extra: [String: String]) -> [String: String] {
        var environment = base
        for key in ["OPENCODE_DB", "OPENCODE_SERVER_PASSWORD", "OPENCODE_PASSWORD", "XDG_DATA_HOME", "XDG_STATE_HOME"] {
            environment[key] = nil
        }
        environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        environment["OPENCODE_CONFIG_PROJECT_DISABLE"] = "1"
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        environment["XDG_DATA_HOME"] = dataDirectory.appendingPathComponent("data", isDirectory: true).path
        environment["XDG_STATE_HOME"] = dataDirectory.appendingPathComponent("state", isDirectory: true).path
        let paths = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        for (key, value) in extra { environment[key] = value }
        // The switch cannot be turned off, and no password can be put in, from outside.
        environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        environment["OPENCODE_CONFIG_PROJECT_DISABLE"] = "1"
        environment["OPENCODE_SERVER_PASSWORD"] = nil
        environment["OPENCODE_PASSWORD"] = nil
        return environment
    }

    /// The address in the server's "Server listening on http://127.0.0.1:PORT" line. Only loopback addresses count.
    nonisolated static func listeningURL(in output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "listening on ") else { continue }
            let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1", url.port != nil else { continue }
            return url
        }
        return nil
    }

}

#if os(macOS)
/// The wrapper process and the server it holds. The wrapper starts `opencode serve` in the background, prints its pid,
/// and waits on its own input; when that closes (Ensemble stops it, quits or crashes) it stops the server.
final class PrivateServerProcess: @unchecked Sendable {
    /// `$0` is the opencode executable. Background jobs of a non-interactive shell read /dev/null, so the server
    /// never shares the wrapper's input.
    static let wrapperScript = """
        "$0" serve --service --hostname 127.0.0.1 --port 0 &
        pid=$!
        echo "ensemble-private-pid $pid"
        read -r _
        kill -TERM "$pid" 2>/dev/null
        wait "$pid"
        """

    let process: Process
    private let input: Pipe
    private let output: Pipe
    private let lock = NSLock()
    private var buffer = ""
    private var serverPID: Int32?
    private var stopped = false
    var version: String? {
        get { lock.withLock { storedVersion } }
        set { lock.withLock { storedVersion = newValue } }
    }
    private var storedVersion: String?

    private init(process: Process, input: Pipe, output: Pipe) {
        self.process = process
        self.input = input
        self.output = output
    }

    static func launch(executable: URL, environment: [String: String], workingDirectory: URL) throws -> PrivateServerProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", wrapperScript, executable.path]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let launched = PrivateServerProcess(process: process, input: input, output: output)
        output.fileHandleForReading.readabilityHandler = { [weak launched] handle in
            let data = handle.availableData
            guard let launched else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            launched.take(data)
        }
        try process.run()
        return launched
    }

    /// Keeps the first few kilobytes of output (the pid and address lines); the rest is read and dropped.
    private func take(_ data: Data) {
        lock.withLock {
            guard buffer.utf8.count < 16_384 else { return }
            buffer += String(decoding: data, as: UTF8.self)
            if serverPID == nil, let range = buffer.range(of: "ensemble-private-pid ") {
                let digits = buffer[range.upperBound...].prefix { $0.isNumber }
                serverPID = Int32(digits)
            }
        }
    }

    var isRunning: Bool { process.isRunning }

    /// The `opencode serve` process (not the wrapper), once it printed its id.
    var serverProcessID: Int32? { lock.withLock { serverPID } }

    func waitForURL(timeout: TimeInterval) async -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = lock.withLock { buffer }
            if let url = PrivateOpenCodeServer.listeningURL(in: text) { return url }
            if !process.isRunning { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Closes the wrapper's input (it stops the server), waits up to `wait` seconds, then kills what is left.
    func stop(wait: TimeInterval) {
        let pid: Int32? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return serverPID ?? -1
        }
        guard let pid else { return }
        try? input.fileHandleForWriting.close()
        guard wait > 0 else { return }
        let deadline = Date().addingTimeInterval(wait)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if pid > 0, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
    }

    deinit {
        if !stopped { try? input.fileHandleForWriting.close() }
    }
}
#endif

/// Stands in for the private OpenCode server while it is not answering: every call fails with
/// `PrivateOpenCodeError.notRunning` and it sends no events. `EngineRouter` keeps the untrusted-folder slot filled
/// with it, so a session in an untrusted folder never falls back to the shared service.
public final class OpenCodeStandIn: OpenCodeAPI, Sendable {
    public let reason: String

    public init(reason: String = "starting") {
        self.reason = reason
    }

    private var error: PrivateOpenCodeError { .notRunning(reason) }

    public func serverInfo() async throws -> (version: String, url: URL) { throw error }
    public func listSessions() async throws -> [EngineSession] { throw error }
    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                              parentID: String?) async throws -> EngineSession { throw error }
    public func deleteSession(_ sessionID: String) async throws { throw error }
    public func renameSession(_ sessionID: String, title: String) async throws { throw error }
    public func setArchived(_ sessionID: String, archived: Bool) async throws { throw error }
    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { throw error }
    public func switchModel(_ sessionID: String, model: ModelRef) async throws { throw error }
    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] { throw error }
    public func children(_ sessionID: String) async throws -> [EngineSession] { throw error }
    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws { throw error }
    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws { throw error }
    public func interrupt(_ sessionID: String) async throws { throw error }
    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        throw error
    }
    public func pendingPermissions() async throws -> [PermissionRequest] { throw error }
    public func context(_ sessionID: String) async throws -> ContextBreakdown { throw error }
    public func changedFiles(_ sessionID: String) async throws -> [FileChange] { throw error }
    public func connectors() async throws -> [ConnectorInfo] { throw error }
    public func models() async throws -> [ModelInfo] { throw error }
    public func providers() async throws -> [ProviderInfo] { throw error }
    public func setAPIKey(providerID: String, key: String) async throws { throw error }
    public func removeAPIKey(providerID: String) async throws { throw error }
    public func schedules() async throws -> [ScheduleInfo] { throw error }
    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        throw error
    }
    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { throw error }
    public func deleteSchedule(_ scheduleID: String) async throws { throw error }

    public func events() -> AsyncStream<EngineEvent> {
        AsyncStream { $0.finish() }
    }
}
