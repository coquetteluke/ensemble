#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// A shell (or any program) running on a pseudo-terminal: opened with `openpty`, started with `posix_spawn` as the
/// leader of its own session with the terminal as its controlling terminal, so job control, Control-C and
/// window-size changes work as in Terminal. The child gets only the file descriptors of the terminal (no
/// descriptor of Ensemble's leaks into it) and default signal handling.
///
/// Output arrives on a background queue through `onOutput`; `onExit` runs once when the process has ended and
/// has been reaped (no zombies are left behind). The object stays alive until then, even when nothing else holds it.
public final class PseudoTerminal: Sendable {
    public struct Configuration: Sendable {
        public var executable: String
        /// The full argument list, the program name first (`["zsh", "-l"]`). The program sees its full path as
        /// its name (see `init`).
        public var arguments: [String]
        public var environment: [String: String]
        public var directory: String
        public var columns: Int
        public var rows: Int

        public init(executable: String, arguments: [String], environment: [String: String], directory: String,
                    columns: Int, rows: Int) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
            self.columns = columns
            self.rows = rows
        }
    }

    public enum StartError: Error, LocalizedError {
        case terminalUnavailable(Int32)
        case spawnFailed(path: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .terminalUnavailable(let code): "Could not open a terminal: \(String(cString: strerror(code)))"
            case .spawnFailed(let path, let code): "Could not start \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// The shell's process ID (also its process group and session).
    public let processID: pid_t
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "ensemble.terminal.read")
    private let writeQueue = DispatchQueue(label: "ensemble.terminal.write")
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private nonisolated(unsafe) let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 1)

    private struct State {
        var closed = false
        var exitStatus: Int32?
        var readSource: DispatchSourceRead?
        var processSource: DispatchSourceProcess?
        var readingPaused = false
    }
    private let state = Mutex(State())

    /// `TIOCSWINSZ` (`_IOW('t', 103, struct winsize)`).
    private static let setWindowSize: UInt = 0x8008_7467

    public init(configuration: Configuration, onOutput: @escaping @Sendable ([UInt8]) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        self.onOutput = onOutput
        self.onExit = onExit
        guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            readBuffer.deallocate()
            throw StartError.spawnFailed(path: configuration.executable, code: ENOENT)
        }
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: UInt16(clamping: configuration.rows), ws_col: UInt16(clamping: configuration.columns),
                           ws_xpixel: 0, ws_ypixel: 0)
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, &size) == 0 else {
            readBuffer.deallocate()
            throw StartError.terminalUnavailable(errno)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        // UTF-8 aware line editing (backspace removes a whole character in programs that read lines).
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_iflag |= tcflag_t(IUTF8)
            _ = tcsetattr(slave, TCSANOW, &settings)
        }
        let slavePath = Self.string(fromCString: name)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int32(POSIX_SPAWN_SETSID) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGDEF)
            | Int32(POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir(&actions, configuration.directory)

        // A terminal becomes the controlling terminal when a session leader opens it, but posix_spawn starts the
        // new session only after the file actions above. So `/bin/sh`, as the session leader, opens the terminal
        // again by name and then replaces itself with the program (same process, same session). Without this,
        // shells that do not reopen the terminal themselves (zsh) get no job control, Control-C and Control-Z do
        // nothing, and the program in front cannot be told apart from the shell.
        let launcher = ["sh", "-c", "tty=$1; shift; unset SHLVL; exec \"$@\" <>\"$tty\" >&0 2>&0", "sh", slavePath,
                        configuration.executable] + configuration.arguments.dropFirst()
        let argv: [UnsafeMutablePointer<CChar>?] = launcher.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = configuration.environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes,
                            UnsafeMutablePointer(mutating: argvBuffer.baseAddress), UnsafeMutablePointer(mutating: envpBuffer.baseAddress))
            }
        }
        close(slave)
        guard result == 0 else {
            close(master)
            readBuffer.deallocate()
            throw StartError.spawnFailed(path: configuration.executable, code: result)
        }
        processID = pid
        fd = master
        startReading()
        startWatchingExit()
    }

    deinit {
        readBuffer.deallocate()
    }

    // MARK: Output and exit

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [self] in
            let count = read(fd, readBuffer.baseAddress, readBuffer.count)
            if count > 0 {
                onOutput(Array(UnsafeRawBufferPointer(rebasing: readBuffer[0..<count])))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // End of output: every program on the terminal has closed it.
                stopReading()
                reapIfExited()
            }
        }
        source.setCancelHandler { [self] in
            writeQueue.async { [self] in
                state.withLock { state in
                    if !state.closed {
                        state.closed = true
                        close(fd)
                    }
                }
            }
        }
        state.withLock { $0.readSource = source }
        source.resume()
    }

    private func startWatchingExit() {
        let source = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: readQueue)
        source.setEventHandler { [self] in reapIfExited() }
        state.withLock { $0.processSource = source }
        source.resume()
        // It may have ended before the watch started.
        readQueue.async { [self] in reapIfExited() }
    }

    /// Collects the exit status once the process has ended. Returns true when it has (now or before).
    @discardableResult
    private func reapIfExited() -> Bool {
        let status: Int32? = state.withLock { state in
            if state.exitStatus != nil { return nil }
            var status: Int32 = 0
            let result = waitpid(processID, &status, WNOHANG)
            guard result == processID || (result == -1 && errno == ECHILD) else { return nil }
            state.exitStatus = status
            state.processSource?.cancel()
            state.processSource = nil
            return status
        }
        guard let status else { return state.withLock { $0.exitStatus != nil } }
        onExit(status)
        return true
    }

    /// Stops reading and closes the terminal (on the write queue, after any writes already queued).
    private func stopReading() {
        state.withLock { state in
            guard let source = state.readSource else { return }
            state.readSource = nil
            source.cancel()
            if state.readingPaused {
                state.readingPaused = false
                source.resume()
            }
        }
    }

    /// Pauses reading while the app catches up with a flood of output; the program blocks on writing meanwhile.
    public func setReadingPaused(_ paused: Bool) {
        state.withLock { state in
            guard let source = state.readSource, state.readingPaused != paused else { return }
            state.readingPaused = paused
            if paused { source.suspend() } else { source.resume() }
        }
    }

    // MARK: Input

    /// Sends bytes to the program, in order.
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count {
                if state.withLock({ $0.closed }) { return }
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR || errno == EAGAIN {
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    /// Tells the program the new size (`TIOCSWINSZ`; the kernel sends it SIGWINCH).
    public func resize(columns: Int, rows: Int) {
        writeQueue.async { [self] in
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
            state.withLock { state in
                guard !state.closed else { return }
                _ = ioctl(fd, Self.setWindowSize, &size)
            }
        }
    }

    // MARK: What is running

    public var hasExited: Bool { state.withLock { $0.exitStatus != nil } }

    /// The process group in front on the terminal: the shell's at the prompt, a program's while it runs.
    public var foregroundProcessGroup: pid_t? {
        state.withLock { state in
            guard !state.closed, state.exitStatus == nil else { return nil }
            let group = tcgetpgrp(fd)
            return group > 0 ? group : nil
        }
    }

    /// True while a program other than the shell runs in front (for example `top` or a build).
    public var isRunningProgram: Bool {
        guard let group = foregroundProcessGroup else { return false }
        return group != processID
    }

    /// The name of the program in front, when it is not the shell.
    public var foregroundProgramName: String? {
        guard let group = foregroundProcessGroup, group != processID else { return nil }
        return Self.processName(group)
    }

    /// The shell's current folder.
    public var currentDirectory: String? {
        guard !hasExited else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// A process's name. Programs that run as another user (`top` is set-user-ID root) refuse `proc_name`, so the
    /// name then comes from the program's path.
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = string(fromCString: buffer)
            if !name.isEmpty { return name }
        }
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = (string(fromCString: buffer) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func string(fromCString buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Ending

    /// Hangs up like closing a Terminal window: SIGHUP to the program in front and to the shell, then closes the
    /// terminal. Whatever has not ended after `grace` seconds is killed.
    public func terminate(grace: TimeInterval = 2) {
        hangUp()
        guard !hasExited else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            guard !reapIfExited() else { return }
            kill(-processID, SIGKILL)
            kill(processID, SIGKILL)
        }
    }

    private func hangUp() {
        if !hasExited {
            if let group = foregroundProcessGroup, group != processID { kill(-group, SIGHUP) }
            kill(processID, SIGHUP)
        }
        stopReading()
    }

    /// Ends every terminal before the app quits: hangs them all up, waits up to `timeout` seconds, then kills and
    /// reaps whatever is left, so quitting never leaves shells or zombies behind.
    public static func terminateAll(_ terminals: [PseudoTerminal], timeout: TimeInterval = 0.5) {
        terminals.forEach { $0.hangUp() }
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = terminals.filter { !$0.reapIfExited() }
        while !remaining.isEmpty, Date() < deadline {
            usleep(10_000)
            remaining = remaining.filter { !$0.reapIfExited() }
        }
        for terminal in remaining {
            kill(-terminal.processID, SIGKILL)
            kill(terminal.processID, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(1)
        while !remaining.isEmpty, Date() < killDeadline {
            remaining = remaining.filter { !$0.reapIfExited() }
            if !remaining.isEmpty { usleep(5_000) }
        }
    }

    /// The shell's exit code from a `waitpid` status (128 plus the signal number when a signal ended it).
    public static func exitCode(fromStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
#endif
