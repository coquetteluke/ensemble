import Foundation
#if canImport(Darwin)
import Darwin
#endif

// This file is compiled twice: into EnsembleKit (the server uses its constants and socket helpers) and into the small
// `ensemble-agent-tools` helper in the app bundle (`Apps/AgentToolsBridge/main.swift`), so it uses Foundation and
// Darwin only.

/// The stdio side of Ensemble's agent tools. Each engine starts `ensemble-agent-tools` as an ordinary stdio MCP server;
/// the helper connects to Ensemble's Unix socket, proves which session it serves with that session's secret, then
/// copies bytes both ways until either side closes. It knows nothing about MCP: Ensemble answers every message.
///
/// - The socket lives in a folder only the user can open (0700) and is itself 0600; the helper refuses a socket or
///   folder owned by anyone else.
/// - The secret comes in the environment the engine was told to set (never argv, which `ps` shows to other users) and
///   is the first line sent: `{"ensembleAgentTools":1,"key":"<64 hex>"}`. Ensemble closes the connection on a wrong key.
public enum AgentToolsBridge {
    public static let socketVariable = "ENSEMBLE_AGENT_TOOLS_SOCKET"
    public static let keyVariable = "ENSEMBLE_AGENT_TOOLS_KEY"
    public static let protocolVersion = 1
    /// The helper's file name in `Ensemble.app/Contents/MacOS`.
    public static let executableName = "ensemble-agent-tools"
    /// Bytes in a key (shown as twice as many hex digits).
    public static let keyBytes = 32

    /// The first line the helper sends.
    public static func helloLine(key: String) -> String {
        "{\"ensembleAgentTools\":\(protocolVersion),\"key\":\"\(key)\"}\n"
    }

    /// A key is exactly 64 lowercase hex digits.
    public static func isValidKey(_ key: String) -> Bool {
        key.utf8.count == keyBytes * 2 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A new random key.
    public static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: keyBytes)
        let status = SecRandomCopyBytesShim.fill(&bytes)
        precondition(status, "no random bytes")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    #if canImport(Darwin)
    /// Runs the helper: checks the socket, connects, says hello and relays stdin to the socket and the socket to stdout.
    /// Returns the exit status. Problems go to stderr, which engines keep in their MCP logs.
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let path = environment[socketVariable], !path.isEmpty, let key = environment[keyVariable], isValidKey(key) else {
            fail("Ensemble's agent tools are not set up for this session (missing socket or key).")
            return 2
        }
        if let problem = socketProblem(path) {
            fail(problem)
            return 2
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fail("Could not make a socket.")
            return 1
        }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard connectUnix(fd, path: path) else {
            fail("Ensemble is not running, or its agent tools stopped.")
            return 1
        }
        guard writeAll(fd, Array(helloLine(key: key).utf8)) else {
            fail("Ensemble closed the connection.")
            return 1
        }
        return relay(socket: fd)
    }

    /// Why the helper must not connect to `path`, or nil: it must be a socket owned by this user, in a folder owned by
    /// this user that nobody else can open.
    public static func socketProblem(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "Ensemble's agent tools socket is missing." }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            return "Ensemble's agent tools socket is not owned by this user."
        }
        let folder = (path as NSString).deletingLastPathComponent
        var folderInfo = stat()
        guard lstat(folder, &folderInfo) == 0, (folderInfo.st_mode & S_IFMT) == S_IFDIR, folderInfo.st_uid == getuid(),
              folderInfo.st_mode & 0o077 == 0 else {
            return "Ensemble's agent tools folder is not private to this user."
        }
        return nil
    }

    /// Fills a `sockaddr_un` for `path` and calls `body` with it. False when the path is too long.
    static func withUnixAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// The longest socket path a `sockaddr_un` holds.
    public static var maxSocketPathLength: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }

    static func connectUnix(_ fd: Int32, path: String) -> Bool {
        withUnixAddress(path) { connect(fd, $0, $1) } == 0
    }

    /// Writes every byte, retrying on interrupts. False when the other side is gone.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// Copies stdin to the socket and the socket to stdout. When stdin ends the socket's sending side is shut, so
    /// Ensemble sees the end and closes; when the socket closes the helper exits.
    static func relay(socket fd: Int32) -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var inputOpen = true
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        while true {
            fds[0].fd = inputOpen ? STDIN_FILENO : -1
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return 1
            }
            if inputOpen, fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 {
                    inputOpen = false
                    shutdown(fd, SHUT_WR)
                } else if !writeAll(fd, Array(buffer[0..<count])) {
                    return 0
                }
            }
            if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return 0 }
                if !writeAll(STDOUT_FILENO, Array(buffer[0..<count])) { return 0 }
            }
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("ensemble-agent-tools: " + message + "\n").utf8))
    }
    #endif
}

/// Random bytes from the system's generator (`arc4random_buf` reads the kernel's CSPRNG on Darwin).
enum SecRandomCopyBytesShim {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        #if canImport(Darwin)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return true
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        return true
        #endif
    }
}
