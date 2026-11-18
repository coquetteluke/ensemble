import Foundation

/// Version of the Mac/iPhone protocol. Bump when messages change incompatibly.
/// 2: challenge-response pairing check; the token is never sent.
/// 3: every frame after the handshake is encrypted (`RemoteChannel`); the welcome is the first sealed frame.
/// 4: a fresh X25519 key exchange on every connection. Both sides send an ephemeral public key, both proofs cover
///    both keys, and the shared secret goes into the channel keys, so a leaked token alone cannot open recorded traffic.
public let remoteProtocolVersion = 4
/// Oldest protocol version either side accepts. Older versions sent the token (1), plaintext frames (2), or
/// derived keys from the token alone (3).
public let remoteMinimumProtocolVersion = 4
/// Port the Mac listens on unless the user picks another.
public let remoteDefaultPort = 47823

// MARK: - Pairing

/// What the iPhone needs to reach the Mac. Encoded in the pairing QR code as JSON.
public struct RemotePairing: Codable, Hashable, Sendable {
    /// The Mac's mailbox on a relay (`RelayHost`), for reaching it from any network.
    public struct Relay: Codable, Hashable, Sendable {
        /// `wss://` address of the relay.
        public var url: String
        /// The mailbox ID (`RelayIdentity.mailboxID`).
        public var mailbox: String

        public init(url: String, mailbox: String) {
            self.url = url
            self.mailbox = mailbox
        }
    }

    /// Host names to try in order: the Tailscale MagicDNS name, the Tailscale IPs, then the LAN name. May be empty
    /// when `relay` is set.
    public var hosts: [String]
    public var port: Int
    /// Random secret shared once through the QR code.
    public var token: String
    public var macName: String
    /// Protocol version of the Mac that made the code. Codes without it decode as version 1.
    public var protocolVersion: Int
    /// The relay the Mac is reachable through. Codes without it pair direct only.
    public var relay: Relay?
    /// The relay the Mac used before `relay`, kept until a connection through the new one works.
    public var previousRelay: Relay?

    public init(hosts: [String], port: Int, token: String, macName: String, protocolVersion: Int = remoteProtocolVersion,
                relay: Relay? = nil, previousRelay: Relay? = nil) {
        self.hosts = hosts
        self.port = port
        self.token = token
        self.macName = macName
        self.protocolVersion = protocolVersion
        self.relay = relay
        self.previousRelay = previousRelay
    }

    private enum CodingKeys: String, CodingKey { case hosts, port, token, macName, protocolVersion, relay, previousRelay }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        port = try c.decode(Int.self, forKey: .port)
        token = try c.decode(String.self, forKey: .token)
        macName = try c.decodeIfPresent(String.self, forKey: .macName) ?? "Mac"
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        relay = try c.decodeIfPresent(Relay.self, forKey: .relay)
        previousRelay = try c.decodeIfPresent(Relay.self, forKey: .previousRelay)
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
        // A code may have no direct hosts when it has a relay.
        let hasRelay = pairing.relay.map { !$0.url.isEmpty && !$0.mailbox.isEmpty } ?? false
        guard !hosts.isEmpty || hasRelay else { throw CodeError.missingHosts }
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
    /// True when the agent stopped at its spending cap. Absent from Macs that predate rooms on the phone.
    public var capped: Bool?

    public init(id: UUID, name: String, model: String, colorHex: String, activity: SessionActivity = .idle, sessionID: String? = nil,
                capped: Bool? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.colorHex = colorHex
        self.activity = activity
        self.sessionID = sessionID
        self.capped = capped
    }

    public init(_ spec: AgentSpec, activity: SessionActivity = .idle, sessionID: String? = nil, capped: Bool? = nil) {
        self.init(id: spec.id, name: spec.name, model: spec.model.description, colorHex: spec.colorHex,
                  activity: activity, sessionID: sessionID, capped: capped)
    }
}

// MARK: - Room decisions

/// Something a room waits on the user for, with the answers the phone may give. The Mac writes the title, text and
/// choices, so a phone shows a new kind of decision without an update; `kind` only picks the icon.
/// Added after protocol 3 shipped: older Macs never send it, and older phones ignore it.
public struct RemoteRoomDecision: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case approvePlan
        case writePlan
        case reviewStalemate
        case takeover
        case judge
        case mergeConflict
        case verdict
        /// A kind this phone does not know yet.
        case other

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    /// One line under the text: a plan's assignment (with its agent) or a file in a merge conflict.
    public struct Item: Codable, Hashable, Sendable {
        public var agentID: UUID?
        public var text: String

        public init(agentID: UUID? = nil, text: String) {
            self.agentID = agentID
            self.text = text
        }
    }

    /// Changes whenever the decision or what it is about changes (a new plan, another run). The Mac refuses an answer
    /// to an id that is no longer open, so the phone can never approve a plan it did not show.
    public var id: String
    public var kind: Kind
    public var title: String
    /// The agent it is about.
    public var agentID: UUID?
    /// Markdown: the plan, the last review, the reason for a takeover, the verdict.
    public var text: String?
    public var items: [Item]
    /// One line of instructions under the card.
    public var note: String?
    public var choices: [RemoteRoomChoice]
    /// False for a card that waits on nobody (a debate's verdict with Build it): it is not counted as needs you.
    public var needsYou: Bool

    public init(id: String, kind: Kind, title: String, agentID: UUID? = nil, text: String? = nil, items: [Item] = [],
                note: String? = nil, choices: [RemoteRoomChoice], needsYou: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title
        self.agentID = agentID
        self.text = text
        self.items = items
        self.note = note
        self.choices = choices
        self.needsYou = needsYou
    }

    private enum CodingKeys: String, CodingKey { case id, kind, title, agentID, text, items, note, choices, needsYou }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        title = try c.decode(String.self, forKey: .title)
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        choices = try c.decodeIfPresent([RemoteRoomChoice].self, forKey: .choices) ?? []
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? true
    }
}

/// One answer to a room decision, as a button on the phone.
public struct RemoteRoomChoice: Codable, Hashable, Sendable, Identifiable {
    public enum Style: String, Codable, Sendable {
        case primary
        case standard
        case destructive

        public init(from decoder: any Decoder) throws {
            self = Style(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .standard
        }
    }

    /// Whether the answer carries text the user writes.
    public enum Input: String, Codable, Sendable {
        case none
        case optional
        case required

        public init(from decoder: any Decoder) throws {
            self = Input(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .required
        }
    }

    /// Sent back in `RemoteRoomDecisionReply.choice`.
    public var id: String
    public var label: String
    public var style: Style
    public var input: Input
    public var placeholder: String?
    /// Text the box starts with (the plan outline when you lead).
    public var template: String?

    public init(id: String, label: String, style: Style = .standard, input: Input = .none, placeholder: String? = nil,
                template: String? = nil) {
        self.id = id
        self.label = label
        self.style = style
        self.input = input
        self.placeholder = placeholder
        self.template = template
    }

    private enum CodingKeys: String, CodingKey { case id, label, style, input, placeholder, template }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .standard
        input = try c.decodeIfPresent(Input.self, forKey: .input) ?? .none
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        template = try c.decodeIfPresent(String.self, forKey: .template)
    }
}

/// The phone's answer to `RemoteRoom.decision`.
public struct RemoteRoomDecisionReply: Codable, Hashable, Sendable {
    public var roomID: UUID
    /// `RemoteRoomDecision.id` as the phone showed it.
    public var decisionID: String
    /// `RemoteRoomChoice.id`.
    public var choice: String
    public var text: String?

    public init(roomID: UUID, decisionID: String, choice: String, text: String? = nil) {
        self.roomID = roomID
        self.decisionID = decisionID
        self.choice = choice
        self.text = text
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

    // Added after protocol 3 shipped. Older Macs leave them out (they decode as empty), older phones ignore them.

    /// The run's step in the Mac's words ("Waiting for plan approval", "Debating").
    public var phaseLabel: String?
    /// Why the room is paused.
    public var pauseReason: String?
    /// What the room waits on the user for.
    public var decision: RemoteRoomDecision?
    /// Open permission prompts from the room's agents and their subagents, oldest first. Answer them with
    /// `replyPermission` like any other prompt (each carries its own session id).
    public var permissions: [PermissionRequest]
    /// The room's goal (goal mode), while it runs and after it ends (`RemoteSwarm.swift`).
    public var goal: RemoteGoal?
    /// Each agent's role, state, current step and spend, in roster order (`RemoteSwarm.swift`).
    public var members: [RemoteMember]

    public init(id: UUID, title: String, directory: String, mode: RoomMode, agents: [RemoteAgent], leadAgentID: UUID? = nil,
                state: State, permissionMode: PermissionMode, sessionID: String, usage: Usage = .zero, lastActivity: Date = Date(),
                phaseLabel: String? = nil, pauseReason: String? = nil, decision: RemoteRoomDecision? = nil,
                permissions: [PermissionRequest] = [], goal: RemoteGoal? = nil, members: [RemoteMember] = []) {
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
        self.phaseLabel = phaseLabel
        self.pauseReason = pauseReason
        self.decision = decision
        self.permissions = permissions
        self.goal = goal
        self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, directory, mode, agents, leadAgentID, state, permissionMode, sessionID, usage, lastActivity
        case phaseLabel, pauseReason, decision, permissions, goal, members
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        directory = try c.decode(String.self, forKey: .directory)
        mode = try c.decode(RoomMode.self, forKey: .mode)
        agents = try c.decode([RemoteAgent].self, forKey: .agents)
        leadAgentID = try c.decodeIfPresent(UUID.self, forKey: .leadAgentID)
        state = try c.decode(State.self, forKey: .state)
        permissionMode = try c.decode(PermissionMode.self, forKey: .permissionMode)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        usage = try c.decode(Usage.self, forKey: .usage)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        phaseLabel = try c.decodeIfPresent(String.self, forKey: .phaseLabel)
        pauseReason = try c.decodeIfPresent(String.self, forKey: .pauseReason)
        // A decision this phone cannot read is left out rather than losing the whole room.
        decision = (try? c.decodeIfPresent(RemoteRoomDecision.self, forKey: .decision)) ?? nil
        permissions = (try? c.decodeIfPresent([PermissionRequest].self, forKey: .permissions)) ?? []
        goal = (try? c.decodeIfPresent(RemoteGoal.self, forKey: .goal)) ?? nil
        members = (try? c.decodeIfPresent([RemoteMember].self, forKey: .members)) ?? []
    }

    /// True while a run exists that Stop would end.
    public var isRunActive: Bool {
        state == .running || state == .paused || decision?.needsYou == true
    }

    /// Waiting on the user: a decision or a permission prompt.
    public var needsYou: Bool {
        decision?.needsYou == true || !permissions.isEmpty
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
    /// Subscription plan limits (Claude plan, Google AI plan). Added after protocol 3 shipped: older Macs send none.
    public var plans: [RemotePlanUsage]?

    public init(today: Usage = .zero, week: Usage = .zero, providers: [Row] = [], agents: [Row] = [], updated: Date = Date(),
                plans: [RemotePlanUsage]? = nil) {
        self.today = today
        self.week = week
        self.providers = providers
        self.agents = agents
        self.updated = updated
        self.plans = plans
    }
}

/// One subscription's plan limits for the phone's Usage screen.
public struct RemotePlanUsage: Codable, Hashable, Sendable, Identifiable {
    public struct Window: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// The model group the limit covers ("Gemini models"); nil for plans with one group.
        public var group: String?
        /// "Five-hour limit", "Weekly limit".
        public var label: String
        /// 0...1.
        public var usedFraction: Double
        public var resetsAt: Date?

        public init(id: String, group: String? = nil, label: String, usedFraction: Double, resetsAt: Date? = nil) {
            self.id = id
            self.group = group
            self.label = label
            self.usedFraction = usedFraction
            self.resetsAt = resetsAt
        }
    }

    /// `claude`, `googleAI` (`SubscriptionPlan`).
    public var id: String
    /// "Claude plan", "Google AI plan".
    public var title: String
    public var windows: [Window]
    public var limitReached: Bool
    /// When a reached limit resets, if reported.
    public var resetsAt: Date?
    /// Shown when there are no bars: "agy does not report how much of the plan is left".
    public var note: String?

    public init(id: String, title: String, windows: [Window] = [], limitReached: Bool = false, resetsAt: Date? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.windows = windows
        self.limitReached = limitReached
        self.resetsAt = resetsAt
        self.note = note
    }
}

/// Answers to an agent's questions (`PermissionRequest.questions`) from the phone. Empty `answers` declines.
/// Added after protocol 3 shipped: a Mac without it answers `unknownMessage`, and nothing older changes.
public struct RemoteQuestionAnswer: Codable, Hashable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var answers: [AgentQuestionAnswer]

    public init(sessionID: String, requestID: String, answers: [AgentQuestionAnswer]) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.answers = answers
    }
}

/// Proceed or Keep planning on a plan (`PermissionRequest.plan`) from the phone. The phone offers only the modes the
/// plan names (`PlanProposal.allowedProceedModes`) and keeps planning without line comments; the Mac checks both.
public struct RemotePlanResponse: Codable, Hashable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var decision: PlanDecision

    public init(sessionID: String, requestID: String, decision: PlanDecision) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.decision = decision
    }
}

/// The Session Hub as the phone needs it: every row plus the open permission prompts, so rows can offer
/// Allow and Reject without opening the chat. Plans and questions are in `permissions` too (with `plan` or
/// `questions` set); phones that predate them see them as ordinary prompts, and the Mac refuses Allow for them.
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
    /// The Mac is not signed in to its relay mailbox.
    case macOffline
    /// The relay's daily budget for this mailbox is spent.
    case limit
}

public struct RemoteError: Codable, Hashable, Sendable, Error, LocalizedError {
    public typealias Code = RemoteErrorCode
    public var code: RemoteErrorCode
    public var message: String

    public init(_ code: RemoteErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
