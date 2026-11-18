#if os(macOS)
import Foundation
import Darwin

/// A line a dev server printed.
public struct DevServerOutput: Equatable, Sendable {
    public var text: String
    /// Printed on standard error.
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

/// One running dev server: the program started with `Process` (never through a shell), in its own process group, its
/// output read line by line. Stopping signals the whole tree: the process group and every process below it.
@MainActor
public final class DevServerProcess {
    public let executable: URL
    public let arguments: [String]
    public let folder: String
    /// Each line of output, without colour codes.
    public var onOutput: ((DevServerOutput) -> Void)?
    /// The exit status (or the signal number for a process that was killed), once it has ended.
    public var onExit: ((Int32) -> Void)?

    public private(set) var pid: pid_t?
    /// The process group the server leads, so processes it starts are stopped with it.
    public private(set) var group: pid_t?
    public private(set) var exitStatus: Int32?
    private var process: Process?
    private var partial: [Bool: Data] = [:]

    public static let maxLineLength = 4000

    /// - Parameters:
    ///   - executable: the program, already resolved (`LaunchCommand.resolveExecutable`).
    ///   - arguments: the words after the program.
    public init(executable: URL, arguments: [String], folder: String) {
        self.executable = executable
        self.arguments = arguments
        self.folder = folder
    }

    public var isRunning: Bool { pid != nil && exitStatus == nil }

    public func start(environment: [String: String]) throws {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        for (pipe, isError) in [(out, false), (err, true)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                // FIFO onto the main queue keeps lines in order.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data, isError: isError) } }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(status) } }
        }
        try process.run()
        self.process = process
        pid = process.processIdentifier
        group = ProcessTree.ownGroup(of: process.processIdentifier)
    }

    private func receive(_ data: Data, isError: Bool) {
        var buffer = (partial[isError] ?? Data()) + data
        if data.isEmpty {
            // End of the stream: what is left is the last line.
            if !buffer.isEmpty { emit(buffer, isError: isError) }
            partial[isError] = nil
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            emit(buffer[buffer.startIndex..<newline], isError: isError)
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > Self.maxLineLength * 4 {
            emit(buffer, isError: isError)
            buffer = Data()
        }
        partial[isError] = buffer
    }

    private func emit(_ bytes: Data, isError: Bool) {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        // Progress bars redraw with carriage returns; keep the newest state of the line.
        if let last = text.split(separator: "\r", omittingEmptySubsequences: true).last { text = String(last) }
        text = ConsoleText.strippingEscapes(text)
        if text.count > Self.maxLineLength { text = String(text.prefix(Self.maxLineLength)) + "\u{2026}" }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onOutput?(DevServerOutput(text: text, isError: isError))
    }

    /// The program ended. Anything it left running in its group is stopped too, so no server outlives its entry.
    private func finished(_ status: Int32) {
        guard exitStatus == nil else { return }
        exitStatus = status
        if let group, !ProcessTree.members(ofGroup: group).isEmpty {
            let targets = ProcessTree.signal(root: nil, group: group, SIGTERM)
            Task.detached(priority: .utility) { ProcessTree.waitForExit(targets, group: group, grace: 3) }
        }
        onExit?(status)
    }

    /// Signals the tree to stop and waits (off the main actor) until it is gone, killing what is left after `grace`.
    public func stop(grace: TimeInterval = 3) async {
        guard let pid else { return }
        let group = self.group
        let targets = ProcessTree.signal(root: isRunning ? pid : nil, group: group, SIGTERM)
        await Task.detached(priority: .userInitiated) {
            ProcessTree.waitForExit(targets, group: group, grace: grace)
        }.value
    }

    /// The same, blocking the calling thread (for quitting the app).
    public func stopNow(grace: TimeInterval = 1.5) {
        guard let pid else { return }
        let targets = ProcessTree.signal(root: isRunning ? pid : nil, group: group, SIGTERM)
        ProcessTree.waitForExit(targets, group: group, grace: grace)
    }
}

/// Signals a process and everything it started.
public enum ProcessTree {
    /// Every process below `pid`, breadth first.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [pid]
        var seen: Set<pid_t> = [pid]
        while !queue.isEmpty, found.count < 4096 {
            let parent = queue.removeFirst()
            var buffer = [pid_t](repeating: 0, count: 512)
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
            }
            guard count > 0 else { continue }
            for child in buffer.prefix(Int(count)) where child > 1 && seen.insert(child).inserted {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /// The live processes in a process group.
    public static func members(ofGroup group: pid_t) -> [pid_t] {
        guard group > 1 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 1024)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        return buffer.prefix(count).filter { $0 > 1 && isAlive($0) }
    }

    /// The group a freshly started child leads (`Process` puts each child in a group of its own), or nil when it shares
    /// Ensemble's group, which must never be signalled as a whole.
    public static func ownGroup(of pid: pid_t) -> pid_t? {
        let group = getpgid(pid)
        guard group == pid, group > 1, group != getpgrp() else { return nil }
        return group
    }

    /// Sends `signal` to the group, to every live process in it, and to the root and every process below the root.
    /// Returns the processes signalled.
    @discardableResult
    public static func signal(root: pid_t?, group: pid_t?, _ signal: Int32) -> [pid_t] {
        var targets: [pid_t] = []
        if let root, root > 1 { targets = [root] + descendants(of: root) }
        if let group, group > 1, group != getpgrp() {
            let inGroup = members(ofGroup: group)
            // Only a group that still has members (so its id cannot belong to anyone else yet).
            if !inGroup.isEmpty || (root == group && isAlive(group)) { kill(-group, signal) }
            targets += inGroup.filter { !targets.contains($0) }
        }
        let me = getpid()
        targets.removeAll { $0 <= 1 || $0 == me }
        for pid in targets { kill(pid, signal) }
        return targets
    }

    /// Waits until every process (and the group) is gone; after `grace` seconds, kills what is left.
    public static func waitForExit(_ pids: [pid_t], group: pid_t?, grace: TimeInterval) {
        func survivors() -> [pid_t] {
            var left = pids.filter(isAlive)
            if let group { left += members(ofGroup: group).filter { !left.contains($0) } }
            return left
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if survivors().isEmpty { return }
            usleep(50_000)
        }
        let left = survivors()
        guard !left.isEmpty else { return }
        if let group, group > 1, group != getpgrp(), !members(ofGroup: group).isEmpty { kill(-group, SIGKILL) }
        let me = getpid()
        for pid in left where pid > 1 && pid != me { kill(pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline, !survivors().isEmpty { usleep(20_000) }
    }

    /// True while the process exists and has not exited (a zombie waiting to be reaped counts as gone).
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read == size { return info.pbi_status != UInt32(SZOMB) }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Checks whether something accepts connections on a port on this computer.
public enum PortProbe {
    /// True when `127.0.0.1:port` or `[::1]:port` accepts a TCP connection (Node servers often listen on `::1` only).
    public static func isListening(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return connects(family: AF_INET, port: port) || connects(family: AF_INET6, port: port)
    }

    private static func connects(family: Int32, port: Int) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}
#endif

/// Text from terminals and pages, made safe to show as plain lines.
public enum ConsoleText {
    /// Removes terminal escape sequences (colours, cursor moves, titles) and other control characters except tabs.
    public static func strippingEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) else {
            return text
        }
        var result = String.UnicodeScalarView()
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            switch scalar.value {
            case 0x1B:
                guard let next = scalars.first else { continue }
                if next == "[" {
                    // CSI: parameters and intermediates, then one final byte from @ to ~.
                    scalars.removeFirst()
                    while let byte = scalars.popFirst(), !(0x40...0x7E).contains(byte.value) {}
                } else if next == "]" {
                    // OSC: up to BEL or ESC backslash.
                    scalars.removeFirst()
                    while let byte = scalars.popFirst() {
                        if byte.value == 0x07 { break }
                        if byte.value == 0x1B, scalars.first == "\\" { scalars.removeFirst(); break }
                    }
                } else {
                    scalars.removeFirst()
                }
            case 0x09:
                result.append(scalar)
            case 0..<0x20, 0x7F, 0x80...0x9F:
                continue
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }
}
