#if os(macOS)
import Darwin
import Foundation
import SystemConfiguration

/// The Mac's addresses that matter for the remote: Tailscale (MagicDNS name and IPs) and the LAN name.
public struct RemoteNetworkInfo: Hashable, Sendable {
    /// Tailscale IPv4 addresses (100.64.0.0/10).
    public var tailscaleIPv4: [String]
    /// Tailscale IPv6 addresses (fd7a:115c:a1e0::/48).
    public var tailscaleIPv6: [String]
    /// MagicDNS name without the trailing dot, from `tailscale status --json`.
    public var magicDNSName: String?
    /// Bonjour name, e.g. `My-Mac.local`.
    public var localHostName: String?
    /// Private IPv4 addresses on Wi-Fi and Ethernet.
    public var lanIPv4: [String]
    /// Computer name shown to the phone.
    public var computerName: String

    public init(tailscaleIPv4: [String] = [], tailscaleIPv6: [String] = [], magicDNSName: String? = nil,
                localHostName: String? = nil, lanIPv4: [String] = [], computerName: String = "Mac") {
        self.tailscaleIPv4 = tailscaleIPv4
        self.tailscaleIPv6 = tailscaleIPv6
        self.magicDNSName = magicDNSName
        self.localHostName = localHostName
        self.lanIPv4 = lanIPv4
        self.computerName = computerName
    }

    public var hasTailscale: Bool { !tailscaleIPv4.isEmpty || !tailscaleIPv6.isEmpty }

    /// Hosts for the pairing code, in the order the phone should try them.
    public func pairingHosts(includeLocalNetwork: Bool) -> [String] {
        var out: [String] = []
        if let name = magicDNSName, hasTailscale { out.append(name) }
        out += tailscaleIPv4
        out += tailscaleIPv6
        if includeLocalNetwork {
            if let name = localHostName { out.append(name) }
            out += lanIPv4
        }
        return Self.unique(out)
    }

    /// Addresses the server listens on: localhost and Tailscale, plus the LAN when allowed. Never every interface.
    public func bindAddresses(includeLocalNetwork: Bool) -> [String] {
        var out = ["127.0.0.1"]
        out += tailscaleIPv4
        out += tailscaleIPv6
        if includeLocalNetwork { out += lanIPv4 }
        return Self.unique(out)
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Detection

    /// Reads interface addresses, and the MagicDNS name from the Tailscale CLI when it is installed.
    public static func detect() async -> RemoteNetworkInfo {
        var info = scanInterfaces()
        info.localHostName = SCDynamicStoreCopyLocalHostName(nil).map { "\($0 as String).local" }
        info.computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        if let status = await RemoteTailscaleCLI.status() {
            if let dns = status.selfNode?.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !dns.isEmpty {
                info.magicDNSName = dns
            }
            // Use the CLI's IPs too, in case the interface scan missed one.
            for ip in status.selfNode?.tailscaleIPs ?? [] {
                if isTailscaleIPv4(ip), !info.tailscaleIPv4.contains(ip) { info.tailscaleIPv4.append(ip) }
                if isTailscaleIPv6(ip), !info.tailscaleIPv6.contains(ip) { info.tailscaleIPv6.append(ip) }
            }
        }
        return info
    }

    /// Scans `getifaddrs` for Tailscale and LAN addresses.
    public static func scanInterfaces() -> RemoteNetworkInfo {
        var info = RemoteNetworkInfo()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return info }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard let ip = numericHost(addr) else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                if isTailscaleIPv4(ip) {
                    if !info.tailscaleIPv4.contains(ip) { info.tailscaleIPv4.append(ip) }
                } else if name.hasPrefix("en") && isPrivateIPv4(ip) {
                    if !info.lanIPv4.contains(ip) { info.lanIPv4.append(ip) }
                }
            case AF_INET6:
                if isTailscaleIPv6(ip), !info.tailscaleIPv6.contains(ip) { info.tailscaleIPv6.append(ip) }
            default:
                break
            }
        }
        return info
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(addr.pointee.sa_len)
        guard getnameinfo(addr, len, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        // Drop a scope suffix such as `%utun4`.
        return text.split(separator: "%").first.map(String.init)
    }

    /// True for 100.64.0.0/10, the range Tailscale assigns.
    public static func isTailscaleIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// True for fd7a:115c:a1e0::/48, Tailscale's IPv6 range.
    public static func isTailscaleIPv6(_ ip: String) -> Bool {
        ip.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }
}

/// Runs `tailscale status --json`.
enum RemoteTailscaleCLI {
    static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    struct Status: Decodable, Sendable {
        struct Node: Decodable, Sendable {
            var dnsName: String?
            var tailscaleIPs: [String]?
            enum CodingKeys: String, CodingKey {
                case dnsName = "DNSName"
                case tailscaleIPs = "TailscaleIPs"
            }
        }
        var backendState: String?
        var selfNode: Node?
        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case selfNode = "Self"
        }
    }

    static func status(timeout: TimeInterval = 4) async -> Status? {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        guard let data = await run(path: path, arguments: ["status", "--json"], timeout: timeout) else { return nil }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        if let state = status.backendState, state != "Running" { return nil }
        return status
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private static func run(path: String, arguments: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let box = ProcessBox()
                let p = box.process
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = arguments
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { if box.process.isRunning { box.process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = try? out.fileHandleForReading.readToEnd()
                p.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
#endif
