import Foundation

/// What the iPhone needs to reach the Mac. Encoded in the pairing QR code as JSON.
public struct RemotePairing: Codable, Hashable, Sendable {
    /// Host names to try in order, e.g. the Tailscale MagicDNS name, the Tailscale IP, the LAN name.
    public var hosts: [String]
    public var port: Int
    /// Random secret shared once through the QR code.
    public var token: String
    public var macName: String

    public init(hosts: [String], port: Int, token: String, macName: String) {
        self.hosts = hosts
        self.port = port
        self.token = token
        self.macName = macName
    }
}

/// Version of the Mac/iPhone protocol. Bump when messages change incompatibly.
public let remoteProtocolVersion = 1

// Messages between the Mac's RemoteServer and the iPhone are defined in milestone M4 (WP-H).
