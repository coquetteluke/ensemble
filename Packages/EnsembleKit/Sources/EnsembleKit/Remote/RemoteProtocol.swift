import Foundation

/// Version of the Mac/iPhone protocol. Bump when messages change incompatibly.
/// 2: challenge-response pairing check; the token is never sent.
public let remoteProtocolVersion = 2
/// Oldest protocol version either side accepts. Version 1 sent the raw token, so it is refused.
public let remoteMinimumProtocolVersion = 2
/// Port the Mac listens on unless the user picks another.
public let remoteDefaultPort = 47823

// MARK: - Pairing

/// What the iPhone needs to reach the Mac. Encoded in the pairing QR code as JSON.
public struct RemotePairing: Codable, Hashable, Sendable {
    /// Host names to try in order: the Tailscale MagicDNS name, the Tailscale IPs, then the LAN name.
    public var hosts: [String]
    public var port: Int
    /// Random secret shared once through the QR code.
    public var token: String
    public var macName: String
    /// Protocol version of the Mac that made the code. Codes without it decode as version 1.
    public var protocolVersion: Int

    public init(hosts: [String], port: Int, token: String, macName: String, protocolVersion: Int = remoteProtocolVersion) {
        self.hosts = hosts
        self.port = port
        self.token = token
        self.macName = macName
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey { case hosts, port, token, macName, protocolVersion }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decode([String].self, forKey: .hosts)
        port = try c.decode(Int.self, forKey: .port)
        token = try c.decode(String.self, forKey: .token)
        macName = try c.decodeIfPresent(String.self, forKey: .macName) ?? "Mac"
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
    }

    public enum CodeError: Error, Equatable, LocalizedError {
        case unreadable
        case missingHosts
        case badPort
        case missingToken

        public var errorDescription: String? {
            switch self {
            case .unreadable: "This is not an Ensemble pairing code."
            case .missingHosts: "The pairing code has no address for the Mac."
            case .badPort: "The pairing code has an invalid port."
            case .missingToken: "The pairing code has no token."
            }
        }
    }

    /// The text put in the QR code and copied as the pairing code: compact JSON.
    public func code() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Reads a pairing code: the JSON from the QR code, or the same JSON in base64 or base64url.
    public init(code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        var data = Data(trimmed.utf8)
        if !trimmed.hasPrefix("{") {
            guard let decoded = Self.base64Data(trimmed) else { throw CodeError.unreadable }
            data = decoded
        }
        guard let pairing = try? JSONDecoder().decode(RemotePairing.self, from: data) else { throw CodeError.unreadable }
        let hosts = pairing.hosts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !hosts.isEmpty else { throw CodeError.missingHosts }
        guard (1...65535).contains(pairing.port) else { throw CodeError.badPort }
        guard !pairing.token.isEmpty else { throw CodeError.missingToken }
        self = pairing
        self.hosts = hosts
    }

    private static func base64Data(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.filter { !$0.isWhitespace }
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    /// WebSocket URLs for the hosts, in order.
    public var webSocketURLs: [URL] {
        hosts.compactMap { Self.webSocketURL(host: $0, port: port) }
    }

    /// `ws://host:port/ensemble`, with IPv6 literals in brackets.
    public static func webSocketURL(host: String, port: Int) -> URL? {
        var h = host
        if h.contains(":") && !h.hasPrefix("[") { h = "[\(h)]" }
        return URL(string: "ws://\(h):\(port)/ensemble")
    }
}

// MARK: - Shared payload types

/// Where a message, permission mode or interrupt goes: one session, or a whole room.
public enum RemoteTarget: Hashable, Sendable {
    case session(String)
    case room(UUID)
}

extension RemoteTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "session": self = .session(try c.decode(String.self, forKey: .id))
        case "room": self = .room(try c.decode(UUID.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown target kind \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let id):
            try c.encode("session", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .room(let id):
            try c.encode("room", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

public enum RemoteRoomAction: String, Codable, Sendable, CaseIterable {
    case pause
    case resume
    case stop

    public var label: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop"
        }
    }
}

/// One agent in a room, as the phone needs it: name, colour, model and what it is doing.
public struct RemoteAgent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// `providerID/modelID#variant`.
    public var model: String
    /// `#RRGGBB`.
    public var colorHex: String
    public var activity: SessionActivity
    /// The agent's own engine session, if the phone wants to open it alone.
    public var sessionID: String?

    public init(id: UUID, name: String, model: String, colorHex: String, activity: SessionActivity = .idle, sessionID: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.colorHex = colorHex
        self.activity = activity
        self.sessionID = sessionID
    }

    public init(_ spec: AgentSpec, activity: SessionActivity = .idle, sessionID: String? = nil) {
        self.init(id: spec.id, name: spec.name, model: spec.model.description, colorHex: spec.colorHex,
                  activity: activity, sessionID: sessionID)
    }
}

/// A room as the phone sees it.
public struct RemoteRoom: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case idle
        case running
        case paused
        case stopped

        public var label: String {
            switch self {
            case .idle: "Idle"
            case .running: "Running"
            case .paused: "Paused"
            case .stopped: "Stopped"
            }
        }
    }

    public var id: UUID
    public var title: String
    public var directory: String
    public var mode: RoomMode
    public var agents: [RemoteAgent]
    public var leadAgentID: UUID?
    public var state: State
    public var permissionMode: PermissionMode
    /// The combined room transcript; open it with `openSession`. Same id as the room's Session Hub row.
    public var sessionID: String
    public var usage: Usage
    public var lastActivity: Date

    public init(id: UUID, title: String, directory: String, mode: RoomMode, agents: [RemoteAgent], leadAgentID: UUID? = nil,
                state: State, permissionMode: PermissionMode, sessionID: String, usage: Usage = .zero, lastActivity: Date = Date()) {
        self.id = id
        self.title = title
        self.directory = directory
        self.mode = mode
        self.agents = agents
        self.leadAgentID = leadAgentID
        self.state = state
        self.permissionMode = permissionMode
        self.sessionID = sessionID
        self.usage = usage
        self.lastActivity = lastActivity
    }
}

/// Everything the phone needs to show one chat.
public struct RemoteTranscript: Codable, Hashable, Sendable {
    public var sessionID: String
    public var title: String
    public var items: [TranscriptItem]
    public var activity: SessionActivity
    public var permissionMode: PermissionMode?
    /// Set for room transcripts.
    public var roomID: UUID?
    /// Agents that may speak in this chat (names and colours for rows, `@agent` choices for the composer).
    public var agents: [RemoteAgent]

    public init(sessionID: String, title: String, items: [TranscriptItem], activity: SessionActivity = .idle,
                permissionMode: PermissionMode? = nil, roomID: UUID? = nil, agents: [RemoteAgent] = []) {
        self.sessionID = sessionID
        self.title = title
        self.items = items
        self.activity = activity
        self.permissionMode = permissionMode
        self.roomID = roomID
        self.agents = agents
    }
}

/// Usage and spending for the phone's Usage screen.
public struct RemoteUsageSummary: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var usage: Usage
        public var capUSD: Double?
        public var colorHex: String?

        public init(id: String, label: String, usage: Usage, capUSD: Double? = nil, colorHex: String? = nil) {
            self.id = id
            self.label = label
            self.usage = usage
            self.capUSD = capUSD
            self.colorHex = colorHex
        }
    }

    public var today: Usage
    public var week: Usage
    public var providers: [Row]
    public var agents: [Row]
    public var updated: Date

    public init(today: Usage = .zero, week: Usage = .zero, providers: [Row] = [], agents: [Row] = [], updated: Date = Date()) {
        self.today = today
        self.week = week
        self.providers = providers
        self.agents = agents
        self.updated = updated
    }
}

/// The Session Hub as the phone needs it: every row plus the open permission prompts, so rows can offer
/// Allow and Reject without opening the chat.
public struct RemoteHubSnapshot: Codable, Hashable, Sendable {
    public var sessions: [SessionSummary]
    public var permissions: [PermissionRequest]

    public init(sessions: [SessionSummary], permissions: [PermissionRequest] = []) {
        self.sessions = sessions
        self.permissions = permissions
    }
}

/// A live change pushed from the Mac. Codable twin of the engine events the phone cares about.
public enum RemoteUpdate: Codable, Hashable, Sendable {
    /// A Session Hub row appeared or changed.
    case sessionUpserted(session: SessionSummary)
    case sessionRemoved(sessionID: String)
    /// A transcript row appeared or changed. Sent only to phones that have the session open.
    case transcriptUpsert(sessionID: String, item: TranscriptItem)
    /// Streaming text appended to an `agentText` or `reasoning` row. Sent only to phones that have the session open.
    case textDelta(sessionID: String, itemID: String, delta: String)
    case activity(sessionID: String, activity: SessionActivity)
    case permissionAsked(request: PermissionRequest)
    case permissionReplied(sessionID: String, requestID: String, decision: PermissionDecision?)
    case permissionModeChanged(target: RemoteTarget, mode: PermissionMode)
    case usage(sessionID: String, usage: Usage)
    case roomUpserted(room: RemoteRoom)
    case roomRemoved(roomID: UUID)
    case usageSummary(summary: RemoteUsageSummary)

    /// The session whose transcript this update changes, for updates that only phones with the chat open need.
    public var transcriptSessionID: String? {
        switch self {
        case .transcriptUpsert(let id, _), .textDelta(let id, _, _): id
        default: nil
        }
    }
}

/// Why the Mac refused a request.
public enum RemoteErrorCode: String, Codable, Sendable {
    /// Wrong or missing token. The phone must pair again.
    case unauthorized
    /// The phone's protocol is too old or too new for this Mac.
    case unsupportedVersion
    /// Too many failed pairing attempts from this address.
    case rateLimited
    /// The message could not be read.
    case badRequest
    /// The message type is not known to this Mac.
    case unknownMessage
    case notFound
    /// The Mac tried and the action failed.
    case failed
    /// The Mac is not accepting more phones.
    case busy
    /// The host could not prove it knows the pairing token, so the phone refused it. Never sent by a Mac.
    case macNotVerified
}

public struct RemoteError: Codable, Hashable, Sendable, Error, LocalizedError {
    public var code: RemoteErrorCode
    public var message: String

    public init(_ code: RemoteErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
