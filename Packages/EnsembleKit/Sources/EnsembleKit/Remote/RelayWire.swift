import Foundation

/// The relay's error codes, sent in an `error` control frame.
public enum RelayErrorCode: String, Codable, Sendable, CaseIterable {
    case macOffline
    case unauthorized
    case taken
    case busy
    case tooBig
    case limit
}

/// One control frame of the relay wire format (`relay/src/wire.ts`). Control frames are JSON text frames of at most
/// 2 KiB, tagged by `t`, with exactly these keys.
///
/// | Frame | Direction |
/// |---|---|
/// | `challenge` | relay to host or phone, on connect |
/// | `claim` | host to relay, first time |
/// | `auth` | host to relay, later |
/// | `ready` | relay to host |
/// | `phone` | relay to host, a phone proved the access key |
/// | `data` | host to relay, the first frame on a data socket |
/// | `badHandshake` | host to relay |
/// | `access` | phone to relay |
/// | `waiting`, `paired` | relay to phone |
/// | `limit` | relay to anyone, the daily budget is spent |
/// | `error` | relay to anyone |
public enum RelayControlFrame: Equatable, Sendable {
    case challenge(nonce: String)
    case claim(hostKey: String, accessKey: String, sig: String)
    case auth(sig: String)
    case ready
    case phone(conn: String, token: String)
    case data(token: String)
    case badHandshake(conn: String)
    case access(proof: String)
    case waiting
    case paired
    /// The daily budget is spent until `resetsAt` (unix seconds). The only kind is `daily`.
    case limit(resetsAt: Int)
    case error(code: RelayErrorCode, message: String)
}

extension RelayControlFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, nonce, hostKey, accessKey, sig, conn, token, proof, kind, resetsAt, code, message
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "challenge": self = .challenge(nonce: try c.decode(String.self, forKey: .nonce))
        case "claim":
            self = .claim(hostKey: try c.decode(String.self, forKey: .hostKey), accessKey: try c.decode(String.self, forKey: .accessKey),
                          sig: try c.decode(String.self, forKey: .sig))
        case "auth": self = .auth(sig: try c.decode(String.self, forKey: .sig))
        case "ready": self = .ready
        case "phone": self = .phone(conn: try c.decode(String.self, forKey: .conn), token: try c.decode(String.self, forKey: .token))
        case "data": self = .data(token: try c.decode(String.self, forKey: .token))
        case "badHandshake": self = .badHandshake(conn: try c.decode(String.self, forKey: .conn))
        case "access": self = .access(proof: try c.decode(String.self, forKey: .proof))
        case "waiting": self = .waiting
        case "paired": self = .paired
        case "limit":
            guard try c.decode(String.self, forKey: .kind) == "daily" else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown limit kind")
            }
            self = .limit(resetsAt: try c.decode(Int.self, forKey: .resetsAt))
        case "error": self = .error(code: try c.decode(RelayErrorCode.self, forKey: .code), message: try c.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "Unknown relay frame \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .challenge(let nonce):
            try c.encode("challenge", forKey: .t)
            try c.encode(nonce, forKey: .nonce)
        case .claim(let hostKey, let accessKey, let sig):
            try c.encode("claim", forKey: .t)
            try c.encode(hostKey, forKey: .hostKey)
            try c.encode(accessKey, forKey: .accessKey)
            try c.encode(sig, forKey: .sig)
        case .auth(let sig):
            try c.encode("auth", forKey: .t)
            try c.encode(sig, forKey: .sig)
        case .ready:
            try c.encode("ready", forKey: .t)
        case .phone(let conn, let token):
            try c.encode("phone", forKey: .t)
            try c.encode(conn, forKey: .conn)
            try c.encode(token, forKey: .token)
        case .data(let token):
            try c.encode("data", forKey: .t)
            try c.encode(token, forKey: .token)
        case .badHandshake(let conn):
            try c.encode("badHandshake", forKey: .t)
            try c.encode(conn, forKey: .conn)
        case .access(let proof):
            try c.encode("access", forKey: .t)
            try c.encode(proof, forKey: .proof)
        case .waiting:
            try c.encode("waiting", forKey: .t)
        case .paired:
            try c.encode("paired", forKey: .t)
        case .limit(let resetsAt):
            try c.encode("limit", forKey: .t)
            try c.encode("daily", forKey: .kind)
            try c.encode(resetsAt, forKey: .resetsAt)
        case .error(let code, let message):
            try c.encode("error", forKey: .t)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }
}

/// Helpers for the relay wire format.
public enum RelayWire {
    /// Largest control frame, in UTF-8 bytes.
    public static let maxControlBytes = 2048

    /// Close codes the relay uses.
    public enum CloseCode {
        public static let unauthorized: UInt16 = 4001
        public static let protocolError: UInt16 = 4002
        public static let noMailbox: UInt16 = 4004
        public static let timeout: UInt16 = 4008
        public static let taken: UInt16 = 4009
        public static let macOffline: UInt16 = 4010
        public static let tooBig: UInt16 = 4013
        public static let limit: UInt16 = 4029
    }

    /// Compact JSON text for a control frame.
    public static func encode(_ frame: RelayControlFrame) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(frame) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a control frame; nil for anything that is not one or is over 2 KiB.
    public static func decode(_ text: String) -> RelayControlFrame? {
        guard text.utf8.count <= maxControlBytes else { return nil }
        return try? JSONDecoder().decode(RelayControlFrame.self, from: Data(text.utf8))
    }

    /// A mailbox ID: 32 bytes, base64url without padding (43 characters).
    public static func isMailboxID(_ text: String) -> Bool {
        text.utf8.count == 43 && isBase64URL(text)
    }

    /// A relay connection ID: 16 bytes, base64url without padding (22 characters).
    public static func isConnID(_ text: String) -> Bool {
        text.utf8.count == 22 && isBase64URL(text)
    }

    private static func isBase64URL(_ text: String) -> Bool {
        text.utf8.allSatisfy { c in
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
        }
    }
}
