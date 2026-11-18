import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import Security
#endif

// Who may speak on the agent tools socket. A key alone is not enough: any process running as the user can read another
// process's environment (`ps -E`) and could run the real helper with a borrowed key. So every connection must also come
// from the signed `ensemble-agent-tools` helper of this app, started by the exact engine process the key was issued to.

/// The engine process a key belongs to, checked against the helper's parent on every connection.
public enum AgentToolsBinding: Equatable, Sendable {
    /// A `claude` process Ensemble started with this private `--mcp-config` file (one process per session).
    case claude(configPath: String)
    /// An engine process Ensemble started that serves several sessions (ACP agents such as `agy`): the helper's parent
    /// must be a process Ensemble started, but which one is not checked, so "Always for this site" is never used.
    case appChild
    /// The OpenCode server at this address (its process id comes from its own `service.json`).
    case openCode(url: String)

    /// Tied to one engine process, so site grants may be used through it.
    public var isExact: Bool {
        switch self {
        case .claude, .openCode: true
        case .appChild: false
        }
    }
}

/// The process on the other end of a connection.
public struct AgentToolsPeer: Equatable, Sendable {
    public var pid: Int32
    /// The peer's audit token (`LOCAL_PEERTOKEN`), which names the process without the risk of a reused pid.
    public var auditToken: Data?

    public init(pid: Int32, auditToken: Data?) {
        self.pid = pid
        self.auditToken = auditToken
    }
}

/// What the server needs to know about other processes. Faked in tests.
public protocol AgentToolsProcesses: Sendable {
    /// This app's own process id.
    var appPID: Int32 { get }
    func parent(of pid: Int32) -> Int32?
    /// A process's arguments as it was started (argv, without the executable path).
    func arguments(of pid: Int32) -> [String]?
    /// Whether the peer is the signed `ensemble-agent-tools` helper from this app's bundle.
    func isHelper(_ peer: AgentToolsPeer) -> Bool
    /// The process id of the OpenCode server at this address.
    func openCodeServer(at url: String) -> Int32?
}

/// The checks on a peer, kept apart from the system lookups so they can be tested.
public enum AgentToolsPeerCheck {
    /// Why the peer may not use a key with this binding, or nil.
    public static func refusal(_ peer: AgentToolsPeer, binding: AgentToolsBinding, processes: any AgentToolsProcesses) -> String? {
        guard processes.isHelper(peer) else { return "not Ensemble's agent tools helper" }
        guard let parent = processes.parent(of: peer.pid) else { return "the helper's parent is gone" }
        switch binding {
        case .claude(let configPath):
            guard processes.parent(of: parent) == processes.appPID else { return "the helper was not started by an agent Ensemble started" }
            guard let arguments = processes.arguments(of: parent), mcpConfigs(arguments).contains(configPath) else {
                return "the helper was not started by this session's agent"
            }
            return nil
        case .appChild:
            guard processes.parent(of: parent) == processes.appPID else { return "the helper was not started by an agent Ensemble started" }
            return nil
        case .openCode(let url):
            guard let server = processes.openCodeServer(at: url), server == parent else {
                return "the helper was not started by this OpenCode server"
            }
            return nil
        }
    }

    /// Every file named after `--mcp-config` (the flag takes one or more files up to the next flag).
    static func mcpConfigs(_ arguments: [String]) -> Set<String> {
        var found: Set<String> = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--mcp-config" {
                index += 1
                while index < arguments.count, !arguments[index].hasPrefix("--") {
                    found.insert(arguments[index])
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return found
    }

    /// An address as service files and clients write it: no trailing slash, lowercased scheme and host.
    public static func normalizedServer(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text.removeLast() }
        guard let parsed = URL(string: text), let scheme = parsed.scheme, let host = parsed.host(percentEncoded: false) else { return text }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme.lowercased())://\(shownHost.lowercased())" + (parsed.port.map { ":\($0)" } ?? "")
    }
}

#if os(macOS)
/// The real lookups: `sysctl` for parents and arguments, code signing for the helper, OpenCode's service files.
public struct SystemAgentToolsProcesses: AgentToolsProcesses {
    /// The helper in this app's bundle; the peer must be this exact signed binary.
    public let helperPath: String
    /// OpenCode `service.json` files to look servers up in (the shared service and Ensemble's private server).
    public let serviceFiles: [URL]
    /// The signing team the helper must have: this app's own (nil for ad hoc builds).
    public let team: String?

    /// `team` defaults to this app's signing team; tests that run the helper from a test runner name the helper's.
    public init(helperPath: String, serviceFiles: [URL] = SystemAgentToolsProcesses.defaultServiceFiles,
                team: String?? = .none) {
        self.helperPath = helperPath
        self.serviceFiles = serviceFiles
        self.team = team ?? Self.ownTeam()
    }

    /// This process's signing team, or nil (ad hoc or unsigned).
    public static func ownTeam() -> String? {
        var me: SecCode?
        var mine: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess,
              let mine else { return nil }
        return signing(mine)?.team
    }

    public static var defaultServiceFiles: [URL] {
        [ServiceFile.defaultURL, PrivateOpenCodeServer.defaultDataDirectory.appendingPathComponent("state/opencode/service.json")]
    }

    public var appPID: Int32 { getpid() }

    public func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        // argv[0] is the program as it was called.
        return Array(arguments.dropFirst())
    }

    public func isHelper(_ peer: AgentToolsPeer) -> Bool {
        guard let token = peer.auditToken else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var running: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &running) == errSecSuccess, let running else { return false }
        var expected: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: helperPath) as CFURL, [], &expected) == errSecSuccess, let expected,
              SecStaticCodeCheckValidity(expected, [], nil) == errSecSuccess else { return false }
        guard let peerInfo = Self.signing(running), let helperInfo = Self.signing(expected) else { return false }
        // The exact binary (same code directory hash), signed the same way, by the same team as this app.
        return peerInfo.cdhash == helperInfo.cdhash && peerInfo.identifier == helperInfo.identifier
            && peerInfo.team == helperInfo.team && peerInfo.team == team
    }

    public func openCodeServer(at url: String) -> Int32? {
        struct Service: Decodable {
            var url: String
            var pid: Int32?
        }
        let wanted = AgentToolsPeerCheck.normalizedServer(url)
        for file in serviceFiles {
            guard let data = try? Data(contentsOf: file), let service = try? JSONDecoder().decode(Service.self, from: data),
                  AgentToolsPeerCheck.normalizedServer(service.url) == wanted, let pid = service.pid, pid > 0 else { continue }
            return pid
        }
        return nil
    }

    private struct Signing: Equatable {
        var cdhash: Data
        var identifier: String?
        var team: String?
    }

    private static func signing(_ code: SecStaticCode) -> Signing? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let cdhash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return Signing(cdhash: cdhash, identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
                       team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// The peer of a connected Unix socket.
    public static func peer(of fd: Int32) -> AgentToolsPeer? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenData: Data? = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0
            ? withUnsafeBytes(of: &token) { Data($0) } : nil
        return AgentToolsPeer(pid: pid, auditToken: tokenData)
    }
}
#endif
