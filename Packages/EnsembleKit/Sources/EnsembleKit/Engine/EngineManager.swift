import Foundation
import Observation
#if os(macOS)
import Darwin
#endif

/// Finds the `opencode` binary, checks its version, starts the shared background service when it is not running,
/// and keeps checking it, restarting it with backoff when it breaks. Publishes `status` (observable) and a
/// ready-to-use `client`.
///
/// The service is shared with the user's other tools: the manager never stops it. It only runs
/// `opencode service start` when the service is missing or its process is gone, and `opencode service restart`
/// when the process is alive but stops answering.
///
/// On iOS there is no local engine; `start()` reports `.failed`.
@MainActor
@Observable
public final class EngineManager {
    public private(set) var status: EngineStatus = .starting
    public private(set) var client: OpenCodeClient?
    /// The `opencode` binary in use, once found.
    public private(set) var executableURL: URL?
    /// Version reported by `opencode --version`.
    public private(set) var installedVersion: EngineVersion?

    @ObservationIgnored public let serviceFileURL: URL
    @ObservationIgnored public let defaultDirectory: String?
    @ObservationIgnored private let searchPaths: [String]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<EngineStatus>.Continuation] = [:]
    @ObservationIgnored private var unhealthyChecks = 0
    @ObservationIgnored private var clientKey: String?
    /// The check that is running now. A second caller waits for it instead of starting the service a second time.
    @ObservationIgnored private var checkInFlight: Task<Bool, Never>?
    /// How many times, half a second apart, a freshly started service is asked whether it is up.
    @ObservationIgnored var startupAttempts = 40

    /// How often a healthy service is checked.
    @ObservationIgnored public var healthInterval: Duration = .seconds(15)

    public init(serviceFileURL: URL = ServiceFile.defaultURL, searchPaths: [String]? = nil, defaultDirectory: String? = nil) {
        self.serviceFileURL = serviceFileURL
        self.defaultDirectory = defaultDirectory
        self.searchPaths = searchPaths ?? EngineManager.defaultSearchPaths()
    }

    /// Directories searched for `opencode`: `PATH`, then Homebrew and the usual install places.
    public nonisolated static func defaultSearchPaths() -> [String] {
        EngineSetup.engineSearchPaths()
    }

    /// Status now and every change after it.
    public func statusUpdates() -> AsyncStream<EngineStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineStatus.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    /// Starts checking (and starting) the engine in the background. Calling it again restarts the loop.
    public func start() {
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

    /// Stops checking. The service keeps running.
    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func publish(_ newStatus: EngineStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for continuation in continuations.values { continuation.yield(newStatus) }
    }

    /// One check: find, version-check, connect or start. Returns true when the engine is running and answering.
    /// Calls that overlap (the background loop and a Check again button) share one check.
    @discardableResult
    public func checkNow() async -> Bool {
        #if os(macOS)
        if let checkInFlight { return await checkInFlight.value }
        let check = Task { await self.checkMac() }
        checkInFlight = check
        let healthy = await check.value
        checkInFlight = nil
        return healthy
        #else
        publish(.failed("The OpenCode engine runs on the Mac."))
        return false
        #endif
    }

    #if os(macOS)
    private func checkMac() async -> Bool {
        if executableURL == nil {
            executableURL = Self.locate(in: searchPaths)
            installedVersion = nil
        }
        guard let executable = executableURL else {
            client = nil
            publish(.notInstalled)
            return false
        }
        if installedVersion == nil {
            guard let result = await Self.run(executable, ["--version"], timeout: 20), result.status == 0,
                  let version = EngineVersion(result.output) else {
                executableURL = nil
                publish(.failed("Could not run \(executable.path) --version"))
                return false
            }
            installedVersion = version
        }
        if let installed = installedVersion, installed < .minimum {
            publish(.tooOld(found: installed.description, required: EnsembleKit.minimumEngineVersion))
            return false
        }

        // Already running?
        if let running = await connectToRunningService() {
            unhealthyChecks = 0
            publish(running)
            return true
        }

        if case .running = status { publish(.starting) }
        let file = try? ServiceFile.read(from: serviceFileURL)
        let processAlive = file?.pid.map(Self.processIsAlive) ?? false
        let arguments: [String]
        if processAlive {
            unhealthyChecks += 1
            // Give a busy but alive service a few chances before restarting it.
            guard unhealthyChecks >= 3 else {
                publish(.starting)
                return false
            }
            arguments = ["service", "restart"]
        } else {
            arguments = ["service", "start"]
        }
        publish(.starting)
        _ = await Self.run(executable, arguments, timeout: 60)
        unhealthyChecks = 0

        for _ in 0..<startupAttempts {
            if let running = await connectToRunningService() {
                publish(running)
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        client = nil
        publish(.failed("The OpenCode service did not start. Try `opencode service status` in Terminal."))
        return false
    }

    /// Reads service.json and checks `GET /api/info` with its password.
    private func connectToRunningService() async -> EngineStatus? {
        guard let file = try? ServiceFile.read(from: serviceFileURL) else { return nil }
        if let pid = file.pid, !Self.processIsAlive(pid) { return nil }
        let key = "\(file.url.absoluteString)|\(file.password.hashValue)"
        let candidate = (key == clientKey ? client : nil) ?? OpenCodeClient(serviceFile: file, defaultDirectory: defaultDirectory)
        guard let info = try? await candidate.serverInfo() else { return nil }
        if let version = EngineVersion(info.version), version < .minimum {
            return .tooOld(found: version.description, required: EnsembleKit.minimumEngineVersion)
        }
        client = candidate
        clientKey = key
        return .running(version: info.version, url: info.url)
    }

    nonisolated static func locate(in paths: [String]) -> URL? {
        let fileManager = FileManager.default
        for directory in paths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("opencode")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
        }
        return nil
    }

    nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Runs a command and returns its exit status and combined output. Output goes to a temporary file, not a pipe,
    /// because `opencode service start` leaves a background process that would hold a pipe open.
    nonisolated static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, output: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-engine-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: outputURL) }
                guard let handle = try? FileHandle(forWritingTo: outputURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = handle
                process.standardError = handle
                process.standardInput = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                environment["PATH"] = (extra + [environment["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
                process.environment = environment
                do {
                    try process.run()
                } catch {
                    try? handle.close()
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    let killDeadline = Date().addingTimeInterval(3)
                    while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    while process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
                }
                try? handle.close()
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            }
        }
    }
    #endif
}
