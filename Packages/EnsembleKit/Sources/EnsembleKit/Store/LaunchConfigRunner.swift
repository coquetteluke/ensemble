#if os(macOS)
import Foundation
import Observation

/// Runs the dev servers from folders' `.ensemble/launch.json` files, for the browser pane.
///
/// Starting is gated, in this order:
/// 1. The folder must be trusted (`WorkspaceTrust`), because the file comes from the repository.
/// 2. Nothing may already answer on the port (the pane offers to open what is there instead).
/// 3. The first start of a command in a folder needs the user's confirmation of the exact command (`LaunchApprovals`).
///
/// A started server is a `DevServerProcess` (no shell, its own process group). Ensemble waits for the port, then
/// reports the page through `onReady`. Servers belong to an owner (a session id): `stopAll(owner:)` when the session
/// closes, `stopAllNow()` when the app quits.
@Observable @MainActor
public final class DevServers {
    public struct Key: Hashable, Sendable {
        public var owner: String
        public var folder: String
        public var name: String

        public init(owner: String, folder: String, name: String) {
            self.owner = owner
            self.folder = folder
            self.name = name
        }
    }

    public enum Status: Equatable, Sendable {
        case stopped
        /// Started; waiting for the port to answer.
        case starting
        case running(URL)
        /// Still running, but the port did not answer in time.
        case noAnswer
        /// Ended by itself, or could not start: why, in a line.
        case ended(String)

        /// The process is (still) running.
        public var isActive: Bool {
            switch self {
            case .starting, .running, .noAnswer: true
            case .stopped, .ended: false
            }
        }
    }

    public enum StartResult: Equatable, Sendable {
        /// The folder is not trusted; nothing ran.
        case needsTrust
        /// Something already answers on the port; nothing ran. The page there can be opened instead.
        case portInUse(URL)
        /// The first start of this command in this folder: show `entry.commandLine` and the program, then call again
        /// with `confirmed: true`.
        case needsConfirmation(program: String)
        case started
        /// The server is already running (or starting) for this owner.
        case alreadyRunning
        case failed(String)
    }

    public let trust: WorkspaceTrust
    public let approvals: LaunchApprovals
    /// How long to wait for the port after starting.
    public var portTimeout: Duration = .seconds(90)
    public private(set) var statuses: [Key: Status] = [:]
    /// Each line a server prints.
    @ObservationIgnored public var onOutput: ((Key, DevServerOutput) -> Void)?
    /// The port answered: the page to load.
    @ObservationIgnored public var onReady: ((Key, URL) -> Void)?
    /// A server stopped or ended, with the status it ended in.
    @ObservationIgnored public var onEnded: ((Key, Status) -> Void)?

    @ObservationIgnored private var processes: [Key: DevServerProcess] = [:]
    @ObservationIgnored private var waits: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private let environment: [String: String]

    public init(trust: WorkspaceTrust = .shared, approvals: LaunchApprovals = .shared,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.trust = trust
        self.approvals = approvals
        self.environment = environment
    }

    public func status(_ key: Key) -> Status { statuses[key] ?? .stopped }

    /// The server's process id while it runs.
    public func processID(_ key: Key) -> pid_t? { processes[key]?.pid }

    /// Owners with a server running or starting.
    public var activeOwners: Set<String> {
        Set(statuses.filter { $0.value.isActive }.map(\.key.owner))
    }

    /// The program a command would run, for the confirmation (its full path), or nil when it is not installed.
    public func program(for entry: LaunchEntry, folder: String) -> URL? {
        guard let first = entry.arguments.first else { return nil }
        return LaunchCommand.resolveExecutable(first, folder: folder, searchPath: LaunchCommand.searchPath(environment: environment))
    }

    /// Starts a server, or says what has to happen first. `confirmed` is true once the user has confirmed the
    /// command shown for `.needsConfirmation`; it is remembered for this folder and command.
    @discardableResult
    public func start(_ entry: LaunchEntry, folder: String, owner: String, confirmed: Bool = false) -> StartResult {
        let key = Key(owner: owner, folder: folder, name: entry.name)
        if status(key).isActive { return .alreadyRunning }
        guard trust.isTrusted(folder) else { return .needsTrust }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed("The folder \(folder) is missing.")
        }
        if PortProbe.isListening(entry.port) { return .portInUse(entry.url) }
        guard let program = program(for: entry, folder: folder) else {
            return .failed("\(entry.arguments.first ?? "The program") was not found. Use its full path in \(LaunchConfig.relativePath).")
        }
        if !approvals.isApproved(entry.arguments, folder: folder) {
            guard confirmed else { return .needsConfirmation(program: program.path) }
            do {
                try approvals.approve(entry.arguments, folder: folder)
            } catch {
                return .failed("Could not save the confirmation: \(error.localizedDescription)")
            }
        }

        let process = DevServerProcess(executable: program, arguments: Array(entry.arguments.dropFirst()), folder: folder)
        process.onOutput = { [weak self] line in self?.onOutput?(key, line) }
        process.onExit = { [weak self, weak process] code in
            guard let process else { return }
            self?.exited(key, code: code, process: process)
        }
        do {
            try process.start(environment: LaunchCommand.environment(base: environment))
        } catch {
            let status = Status.ended("Could not start: \(error.localizedDescription)")
            statuses[key] = status
            onEnded?(key, status)
            return .failed("Could not start \(entry.name): \(error.localizedDescription)")
        }
        processes[key] = process
        statuses[key] = .starting
        waits[key] = Task { [weak self] in await self?.waitForPort(key, entry: entry, process: process) }
        return .started
    }

    private func waitForPort(_ key: Key, entry: LaunchEntry, process: DevServerProcess) async {
        let deadline = ContinuousClock.now + portTimeout
        let port = entry.port
        while ContinuousClock.now < deadline {
            guard processes[key] === process, process.isRunning, !Task.isCancelled else { return }
            if await Task.detached(operation: { PortProbe.isListening(port) }).value {
                guard processes[key] === process, process.isRunning else { return }
                statuses[key] = .running(entry.url)
                onReady?(key, entry.url)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if processes[key] === process, process.isRunning { statuses[key] = .noAnswer }
    }

    private func exited(_ key: Key, code: Int32, process: DevServerProcess) {
        guard processes[key] === process else { return }
        processes[key] = nil
        waits.removeValue(forKey: key)?.cancel()
        let status = Status.ended(code == 0 ? "Exited." : "Exited with code \(code).")
        statuses[key] = status
        onEnded?(key, status)
    }

    /// Stops a server and everything it started; returns once they are gone.
    public func stop(_ key: Key) async {
        guard let process = processes.removeValue(forKey: key) else {
            if statuses[key] != nil, !(statuses[key]?.isActive ?? false) { statuses[key] = .stopped }
            return
        }
        waits.removeValue(forKey: key)?.cancel()
        statuses[key] = .stopped
        onEnded?(key, .stopped)
        await process.stop()
    }

    /// Stops every server an owner started (its session closed).
    public func stopAll(owner: String) async {
        for key in processes.keys where key.owner == owner { await stop(key) }
        statuses = statuses.filter { $0.key.owner != owner }
    }

    /// Stops every server, blocking until they are gone or killed (the app is quitting).
    public func stopAllNow(grace: TimeInterval = 1.5) {
        let running = processes
        processes.removeAll()
        for task in waits.values { task.cancel() }
        waits.removeAll()
        for key in running.keys { statuses[key] = .stopped }
        // Signal every tree first so they all get the same grace period.
        let deadline = Date().addingTimeInterval(grace)
        let trees = running.values.compactMap { process -> ([pid_t], pid_t?)? in
            guard let pid = process.pid else { return nil }
            return (ProcessTree.signal(root: process.isRunning ? pid : nil, group: process.group, SIGTERM), process.group)
        }
        for (pids, group) in trees {
            ProcessTree.waitForExit(pids, group: group, grace: max(0.1, deadline.timeIntervalSinceNow))
        }
    }
}
#endif
