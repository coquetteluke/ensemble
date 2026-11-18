#if os(macOS)
import Foundation

/// A one-shot signal an async caller can wait on with a timeout.
final class ACPSignal: @unchecked Sendable {
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

    /// True if it fired, false on timeout.
    func wait(timeout: Duration) async -> Bool {
        if isFired { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first { self.releaseWaiters() }
            return first
        }
    }

    private func releaseWaiters() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: false) }
    }
}

/// The last part of a byte stream, kept in memory only (for error messages; never written anywhere).
final class ACPTailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int

    init(limit: Int = 16_384) { self.limit = limit }

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        }
    }

    var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
}

/// One running ACP agent process: stdin for JSON-RPC messages, stdout as an ordered stream of lines, and the end of
/// stderr in memory.
final class ACPProcess: @unchecked Sendable {
    let generation: Int
    let lines: AsyncStream<String>
    let pid: Int32

    private let process: Process
    private let stdinHandle: FileHandle
    private let exitSignal: ACPSignal
    private let stderrTail: ACPTailBuffer
    private let lock = NSLock()
    private var stdinClosed = false

    private init(process: Process, stdinHandle: FileHandle, generation: Int, lines: AsyncStream<String>, exitSignal: ACPSignal,
                 stderrTail: ACPTailBuffer) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.generation = generation
        self.lines = lines
        self.exitSignal = exitSignal
        self.stderrTail = stderrTail
        pid = process.processIdentifier
    }

    static func launch(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                       generation: Int) throws -> ACPProcess {
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
        // Writing to an agent that already exited must fail with EPIPE, not kill Ensemble with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let buffer = ACPLineBuffer()
        let exitSignal = ACPSignal()
        let stderrTail = ACPTailBuffer()
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
            stderrTail.append(data)
        }
        process.terminationHandler = { _ in
            exitSignal.fire()
            // A child the agent started can keep stdout open after the agent exits; stop waiting for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw ACPEngineError.processFailed("could not start \(executable.path): \(error.localizedDescription)")
        }
        return ACPProcess(process: process, stdinHandle: input.fileHandleForWriting, generation: generation, lines: stream,
                          exitSignal: exitSignal, stderrTail: stderrTail)
    }

    var stderrText: String { stderrTail.text }

    var isRunning: Bool { process.isRunning }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !stdinClosed else { throw ACPEngineError.processFailed("the agent's input is closed") }
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                throw ACPEngineError.processFailed("could not write to the agent: \(error.localizedDescription)")
            }
        }
    }

    func closeInput() {
        lock.withLock {
            guard !stdinClosed else { return }
            stdinClosed = true
            try? stdinHandle.close()
        }
    }

    /// Stops the process: closes stdin (ACP agents exit on end of input), then SIGTERM, then SIGKILL after `grace`.
    func terminate(grace: Duration = .seconds(3)) {
        closeInput()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let signal = exitSignal
        let process = process
        Task.detached {
            if await signal.wait(timeout: .milliseconds(500)) { return }
            if process.isRunning { process.terminate() }
            if await signal.wait(timeout: grace) == false { kill(pid, SIGKILL) }
        }
    }

    func waitForExit() async -> Int32 {
        _ = await exitSignal.wait()
        return process.terminationStatus
    }
}

/// Runs a short command (`agy --version`) with a timeout and returns stdout.
enum ACPCommandRunner {
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
        let box = ACPTailBuffer(limit: 65_536)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { box.append(data) }
        }
        let exited = ACPSignal()
        process.terminationHandler = { _ in exited.fire() }
        do { try process.run() } catch { return nil }
        guard await exited.wait(timeout: timeout) else {
            process.terminate()
            return nil
        }
        try? await Task.sleep(for: .milliseconds(50))
        out.fileHandleForReading.readabilityHandler = nil
        box.append(out.fileHandleForReading.availableData)
        return box.text
    }
}
#endif
