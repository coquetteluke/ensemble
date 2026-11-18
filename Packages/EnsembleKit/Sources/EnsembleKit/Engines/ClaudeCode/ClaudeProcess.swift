#if os(macOS)
import Foundation

/// Splits a byte stream into lines (newline separated, UTF-8).
final class ClaudeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    func finish() -> [String] {
        lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
        }
    }
}

/// One running `claude -p` process: stdin for stream-json input, stdout as an ordered stream of lines, and the
/// last part of stderr kept in memory for error messages (never written anywhere).
final class ClaudeProcess: @unchecked Sendable {
    let generation: Int
    let lines: AsyncStream<String>
    let pid: Int32

    private let process: Process
    private let stdinHandle: FileHandle
    private let exitSignal: ClaudeExitSignal
    private let stderrBox: ClaudeOutputBox
    private let lock = NSLock()
    private var stdinClosed = false

    private init(process: Process, stdinHandle: FileHandle, generation: Int, lines: AsyncStream<String>,
                 exitSignal: ClaudeExitSignal, stderrBox: ClaudeOutputBox) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.generation = generation
        self.lines = lines
        self.exitSignal = exitSignal
        self.stderrBox = stderrBox
        pid = process.processIdentifier
    }

    static func launch(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                       generation: Int) throws -> ClaudeProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Writing to a process that already exited must fail with EPIPE, not kill Ensemble with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let buffer = ClaudeLineBuffer()
        let exitSignal = ClaudeExitSignal()
        let stderrBox = ClaudeOutputBox(limit: 16_384)
        output.fileHandleForReading.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty {
                file.readabilityHandler = nil
                for line in buffer.finish() { continuation.yield(line) }
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        errors.fileHandleForReading.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty {
                file.readabilityHandler = nil
                return
            }
            stderrBox.append(data)
        }
        process.terminationHandler = { _ in
            exitSignal.fire()
            // A child the CLI started can keep stdout open after the CLI exits; stop waiting for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw ClaudeCodeError.processFailed("could not start \(executable.path): \(error.localizedDescription)")
        }
        return ClaudeProcess(process: process, stdinHandle: input.fileHandleForWriting, generation: generation,
                             lines: stream, exitSignal: exitSignal, stderrBox: stderrBox)
    }

    /// The end of what the CLI wrote to stderr.
    var stderrText: String { String(decoding: stderrBox.data, as: UTF8.self) }

    var isRunning: Bool { process.isRunning }

    var exitStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !stdinClosed else { throw ClaudeCodeError.processFailed("the session's input is closed") }
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                throw ClaudeCodeError.processFailed("could not write to claude: \(error.localizedDescription)")
            }
        }
    }

    /// Ends input. The CLI finishes what it is doing and exits.
    func closeInput() {
        lock.withLock {
            guard !stdinClosed else { return }
            stdinClosed = true
            try? stdinHandle.close()
        }
    }

    /// Stops the process: SIGTERM first, SIGKILL if it is still running after `grace`.
    func terminate(grace: Duration = .seconds(3)) {
        closeInput()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let signal = exitSignal
        Task.detached {
            if await signal.wait(timeout: grace) == false { kill(pid, SIGKILL) }
        }
    }

    /// Waits until the process has exited.
    func waitForExit() async -> Int32 {
        _ = await exitSignal.wait()
        return process.terminationStatus
    }
}
#endif
