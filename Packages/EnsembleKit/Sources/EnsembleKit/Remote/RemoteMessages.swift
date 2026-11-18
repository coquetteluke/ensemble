import Foundation

// Wire format: every frame is one JSON object
//   {"v": 3, "id": "7", "re": "3", "type": "hello", "data": {...}}
// `v` is the sender's protocol version, `id` is set on phone requests, `re` on Mac replies to a request,
// `type` names the message and `data` holds its payload (absent for messages without one).
//
// Handshake (WebSocket text frames, plaintext): Mac `challenge`, phone `hello`, or a plaintext `error`.
// After a valid hello every frame in both directions is a WebSocket binary frame sealed by `RemoteChannel`,
// starting with the Mac's `welcome`. A plaintext frame after the handshake closes the connection.

/// Keys of the JSON object in every frame.
public enum RemoteWireKey: String, CodingKey {
    case v, id, re, type, data
}

// MARK: - Phone to Mac

/// The phone's answer to the Mac's `challenge`. Carries a proof of the token, never the token itself
/// (see `RemoteHandshake`).
public struct RemoteHello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// Stable id for this phone, so the Mac can list devices.
    public var deviceID: String
    /// 32 random bytes, base64url.
    public var clientNonce: String
    /// `HMAC-SHA256(token, serverNonce || clientNonce || "ensemble-client")`, base64url.
    public var proof: String
    /// The host the phone dialed, exactly as in the pairing code. Bound into the channel keys.
    public var dialedHost: String
    /// The port the phone dialed. Bound into the channel keys.
    public var dialedPort: Int

    public init(protocolVersion: Int = remoteProtocolVersion, deviceName: String, deviceID: String, clientNonce: String, proof: String,
                dialedHost: String, dialedPort: Int) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.clientNonce = clientNonce
        self.proof = proof
        self.dialedHost = dialedHost
        self.dialedPort = dialedPort
    }
}

public struct RemoteSendMessage: Codable, Hashable, Sendable {
    public var target: RemoteTarget
    public var text: String
    /// Agent name to address in a room (`@agent`). `nil` talks to the whole room or the session's agent.
    public var agent: String?

    public init(target: RemoteTarget, text: String, agent: String? = nil) {
        self.target = target
        self.text = text
        self.agent = agent
    }
}

public struct RemotePermissionReply: Codable, Hashable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var decision: PermissionDecision

    public init(sessionID: String, requestID: String, decision: PermissionDecision) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.decision = decision
    }
}

public struct RemoteSetPermissionMode: Codable, Hashable, Sendable {
    public var target: RemoteTarget
    public var mode: PermissionMode

    public init(target: RemoteTarget, mode: PermissionMode) {
        self.target = target
        self.mode = mode
    }
}

public struct RemoteRoomControl: Codable, Hashable, Sendable {
    public var roomID: UUID
    public var action: RemoteRoomAction

    public init(roomID: UUID, action: RemoteRoomAction) {
        self.roomID = roomID
        self.action = action
    }
}

public struct RemoteSessionRef: Codable, Hashable, Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct RemoteTargetRef: Codable, Hashable, Sendable {
    public var target: RemoteTarget
    public init(target: RemoteTarget) { self.target = target }
}

/// Everything the phone can ask the Mac.
public enum RemoteClientMessage: Hashable, Sendable {
    case hello(RemoteHello)
    /// Reply: `.hub`.
    case hubSnapshot
    /// Reply: `.transcript`. Afterwards the Mac streams that session's transcript changes.
    case openSession(sessionID: String)
    /// Stops the transcript stream for a session. Reply: `.ack`.
    case closeSession(sessionID: String)
    /// Reply: `.ack`.
    case sendMessage(RemoteSendMessage)
    /// Reply: `.ack`.
    case replyPermission(RemotePermissionReply)
    /// Reply: `.ack`.
    case setPermissionMode(RemoteSetPermissionMode)
    /// Reply: `.ack`.
    case interrupt(target: RemoteTarget)
    /// Reply: `.ack`.
    case roomControl(RemoteRoomControl)
    /// Reply: `.rooms`.
    case roomsRequest
    /// Reply: `.usage`.
    case usageRequest

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .hubSnapshot: "hubSnapshot"
        case .openSession: "openSession"
        case .closeSession: "closeSession"
        case .sendMessage: "sendMessage"
        case .replyPermission: "replyPermission"
        case .setPermissionMode: "setPermissionMode"
        case .interrupt: "interrupt"
        case .roomControl: "roomControl"
        case .roomsRequest: "roomsRequest"
        case .usageRequest: "usageRequest"
        }
    }

    public func encode(into c: inout KeyedEncodingContainer<RemoteWireKey>) throws {
        try c.encode(typeName, forKey: .type)
        switch self {
        case .hello(let p): try c.encode(p, forKey: .data)
        case .hubSnapshot, .roomsRequest, .usageRequest: break
        case .openSession(let id), .closeSession(let id): try c.encode(RemoteSessionRef(sessionID: id), forKey: .data)
        case .sendMessage(let p): try c.encode(p, forKey: .data)
        case .replyPermission(let p): try c.encode(p, forKey: .data)
        case .setPermissionMode(let p): try c.encode(p, forKey: .data)
        case .interrupt(let t): try c.encode(RemoteTargetRef(target: t), forKey: .data)
        case .roomControl(let p): try c.encode(p, forKey: .data)
        }
    }

    public static func decode(from c: KeyedDecodingContainer<RemoteWireKey>) throws -> RemoteClientMessage {
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello": return .hello(try c.decode(RemoteHello.self, forKey: .data))
        case "hubSnapshot": return .hubSnapshot
        case "openSession": return .openSession(sessionID: try c.decode(RemoteSessionRef.self, forKey: .data).sessionID)
        case "closeSession": return .closeSession(sessionID: try c.decode(RemoteSessionRef.self, forKey: .data).sessionID)
        case "sendMessage": return .sendMessage(try c.decode(RemoteSendMessage.self, forKey: .data))
        case "replyPermission": return .replyPermission(try c.decode(RemotePermissionReply.self, forKey: .data))
        case "setPermissionMode": return .setPermissionMode(try c.decode(RemoteSetPermissionMode.self, forKey: .data))
        case "interrupt": return .interrupt(target: try c.decode(RemoteTargetRef.self, forKey: .data).target)
        case "roomControl": return .roomControl(try c.decode(RemoteRoomControl.self, forKey: .data))
        case "roomsRequest": return .roomsRequest
        case "usageRequest": return .usageRequest
        default: throw RemoteWireError.unknownType(type)
        }
    }
}

// MARK: - Mac to phone

/// First message from the Mac on every connection, before anything else is said.
public struct RemoteChallenge: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    /// 32 random bytes, base64url, new for every connection.
    public var serverNonce: String

    public init(protocolVersion: Int = remoteProtocolVersion, serverNonce: String) {
        self.protocolVersion = protocolVersion
        self.serverNonce = serverNonce
    }
}

/// The Mac accepted the phone's proof. Always the first sealed frame; the phone also checks `serverProof`.
public struct RemoteWelcome: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var macName: String
    /// The phone's own device id, echoed back.
    public var deviceID: String
    /// Ensemble version on the Mac.
    public var appVersion: String
    /// `HMAC-SHA256(token, clientNonce || serverNonce || "ensemble-server")`, base64url.
    public var serverProof: String

    public init(protocolVersion: Int = remoteProtocolVersion, macName: String, deviceID: String, appVersion: String, serverProof: String) {
        self.protocolVersion = protocolVersion
        self.macName = macName
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.serverProof = serverProof
    }
}

private struct RemoteRoomsPayload: Codable { var rooms: [RemoteRoom] }

/// Everything the Mac sends the phone.
public enum RemoteServerMessage: Hashable, Sendable {
    /// Sent once, right after the connection opens.
    case challenge(RemoteChallenge)
    case welcome(RemoteWelcome)
    case hub(RemoteHubSnapshot)
    case transcript(RemoteTranscript)
    case rooms([RemoteRoom])
    case usage(RemoteUsageSummary)
    case update(RemoteUpdate)
    /// The request in `re` was carried out.
    case ack
    case error(RemoteError)

    public var typeName: String {
        switch self {
        case .challenge: "challenge"
        case .welcome: "welcome"
        case .hub: "hub"
        case .transcript: "transcript"
        case .rooms: "rooms"
        case .usage: "usage"
        case .update: "update"
        case .ack: "ack"
        case .error: "error"
        }
    }

    public func encode(into c: inout KeyedEncodingContainer<RemoteWireKey>) throws {
        try c.encode(typeName, forKey: .type)
        switch self {
        case .challenge(let p): try c.encode(p, forKey: .data)
        case .welcome(let p): try c.encode(p, forKey: .data)
        case .hub(let p): try c.encode(p, forKey: .data)
        case .transcript(let p): try c.encode(p, forKey: .data)
        case .rooms(let p): try c.encode(RemoteRoomsPayload(rooms: p), forKey: .data)
        case .usage(let p): try c.encode(p, forKey: .data)
        case .update(let p): try c.encode(p, forKey: .data)
        case .ack: break
        case .error(let p): try c.encode(p, forKey: .data)
        }
    }

    public static func decode(from c: KeyedDecodingContainer<RemoteWireKey>) throws -> RemoteServerMessage {
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "challenge": return .challenge(try c.decode(RemoteChallenge.self, forKey: .data))
        case "welcome": return .welcome(try c.decode(RemoteWelcome.self, forKey: .data))
        case "hub": return .hub(try c.decode(RemoteHubSnapshot.self, forKey: .data))
        case "transcript": return .transcript(try c.decode(RemoteTranscript.self, forKey: .data))
        case "rooms": return .rooms(try c.decode(RemoteRoomsPayload.self, forKey: .data).rooms)
        case "usage": return .usage(try c.decode(RemoteUsageSummary.self, forKey: .data))
        case "update": return .update(try c.decode(RemoteUpdate.self, forKey: .data))
        case "ack": return .ack
        case "error": return .error(try c.decode(RemoteError.self, forKey: .data))
        default: throw RemoteWireError.unknownType(type)
        }
    }
}

// MARK: - Frames

public enum RemoteWireError: Error, Equatable {
    case unknownType(String)
    case notText
}

/// Message types that can travel in a frame.
public protocol RemoteWireMessage: Sendable {
    func encode(into c: inout KeyedEncodingContainer<RemoteWireKey>) throws
    static func decode(from c: KeyedDecodingContainer<RemoteWireKey>) throws -> Self
}

extension RemoteClientMessage: RemoteWireMessage {}
extension RemoteServerMessage: RemoteWireMessage {}

/// One WebSocket frame: protocol version, request id or reply id, and the message.
public struct RemoteFrame<Message: RemoteWireMessage & Hashable>: Codable, Hashable, Sendable {
    public var version: Int
    /// Set on phone requests that expect a reply.
    public var id: String?
    /// Set on Mac replies: the `id` of the request this answers.
    public var replyTo: String?
    public var message: Message

    public init(_ message: Message, id: String? = nil, replyTo: String? = nil, version: Int = remoteProtocolVersion) {
        self.version = version
        self.id = id
        self.replyTo = replyTo
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: RemoteWireKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id)
        replyTo = try c.decodeIfPresent(String.self, forKey: .re)
        message = try Message.decode(from: c)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: RemoteWireKey.self)
        try c.encode(version, forKey: .v)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(replyTo, forKey: .re)
        try message.encode(into: &c)
    }
}

public typealias RemoteClientFrame = RemoteFrame<RemoteClientMessage>
public typealias RemoteServerFrame = RemoteFrame<RemoteServerMessage>

/// Just the envelope of a frame, readable even when the message type is unknown.
public struct RemoteFrameHeader: Decodable, Sendable {
    public var version: Int
    public var id: String?
    public var type: String

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: RemoteWireKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
    }
}

/// JSON settings shared by both ends. Dates use Foundation's default (seconds since 2001 as a Double),
/// which round-trips exactly.
public enum RemoteCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }

    public static func encode<M>(_ frame: RemoteFrame<M>) throws -> Data {
        try encoder().encode(frame)
    }

    public static func decode<M>(_ type: RemoteFrame<M>.Type, from data: Data) throws -> RemoteFrame<M> {
        try decoder().decode(type, from: data)
    }
}
