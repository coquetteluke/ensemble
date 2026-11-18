import Foundation

/// A model reference in OpenCode's format: `providerID/modelID#variant` (variant optional).
public struct ModelRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var providerID: String
    public var id: String
    public var variant: String?

    public init(providerID: String, id: String, variant: String? = nil) {
        self.providerID = providerID
        self.id = id
        self.variant = variant
    }

    /// Parses `provider/model` or `provider/model#variant`. The model part may itself contain `/`
    /// (OpenRouter ids such as `openrouter/anthropic/claude-opus-5.5`).
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash])
        var rest = String(trimmed[trimmed.index(after: slash)...])
        var variant: String?
        if let hash = rest.lastIndex(of: "#") {
            variant = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        guard !provider.isEmpty, !rest.isEmpty else { return nil }
        self.init(providerID: provider, id: rest, variant: (variant?.isEmpty ?? true) ? nil : variant)
    }

    public var description: String {
        variant.map { "\(providerID)/\(id)#\($0)" } ?? "\(providerID)/\(id)"
    }
}

/// How much an agent may do without asking.
public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case ask
    case acceptEdits
    case auto
    case bypass

    public var label: String {
        switch self {
        case .ask: "Ask permissions"
        case .acceptEdits: "Accept edits"
        case .auto: "Auto mode"
        case .bypass: "Bypass permissions"
        }
    }
}

/// One AI teammate: a model with a name, a role and a colour.
public struct AgentSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var model: ModelRef
    /// Plain-language job description added to the agent's instructions.
    public var role: String
    /// `#RRGGBB`.
    public var colorHex: String
    /// Stop this agent when its spend in a room reaches this many US dollars. `nil` means no cap.
    public var spendingCapUSD: Double?

    public init(id: UUID = UUID(), name: String, model: ModelRef, role: String = "", colorHex: String, spendingCapUSD: Double? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.role = role
        self.colorHex = colorHex
        self.spendingCapUSD = spendingCapUSD
    }
}

public enum RoomMode: String, Codable, CaseIterable, Sendable {
    /// One agent, a normal chat.
    case solo
    /// The lead plans and splits the work; agents build in parallel and review each other.
    case team
    /// Agents argue in rounds, then a judge writes the decision.
    case debate
    /// Agents agree on a plan in turns; one builds while the others review.
    case roundTable

    public var label: String {
        switch self {
        case .solo: "Solo"
        case .team: "Team"
        case .debate: "Debate"
        case .roundTable: "Round table"
        }
    }
}

/// A project folder plus one or more agents working in a mode. A plain chat is a solo room.
public struct RoomSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// Absolute path of the project folder.
    public var directory: String
    public var agents: [AgentSpec]
    public var mode: RoomMode
    public var leadAgentID: UUID?
    public var permissionMode: PermissionMode
    public var created: Date
    /// Debate rounds before the verdict.
    public var debateRounds: Int

    public init(id: UUID = UUID(), title: String, directory: String, agents: [AgentSpec], mode: RoomMode,
                leadAgentID: UUID? = nil, permissionMode: PermissionMode = .auto, created: Date = Date(), debateRounds: Int = 3) {
        self.id = id
        self.title = title
        self.directory = directory
        self.agents = agents
        self.mode = mode
        self.leadAgentID = leadAgentID
        self.permissionMode = permissionMode
        self.created = created
        self.debateRounds = debateRounds
    }
}

/// Token use and cost, summed however the caller needs (per message, session, agent or provider).
public struct Usage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, costUSD: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
    }

    public static let zero = Usage()

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
              reasoningTokens: a.reasoningTokens + b.reasoningTokens, cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
              cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens, costUSD: a.costUSD + b.costUSD)
    }
}

/// A model the engine can run, from `GET /api/model`.
public struct ModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var ref: ModelRef
    public var name: String
    public var providerName: String
    public var contextLimit: Int?
    public var variants: [String]
    /// False when the provider has no key yet.
    public var available: Bool

    public var id: String { ref.description }

    public init(ref: ModelRef, name: String, providerName: String, contextLimit: Int? = nil, variants: [String] = [], available: Bool = true) {
        self.ref = ref
        self.name = name
        self.providerName = providerName
        self.contextLimit = contextLimit
        self.variants = variants
        self.available = available
    }
}

/// A provider the user can add a key for (Anthropic, OpenAI, xAI, Google, OpenRouter, ...).
public struct ProviderInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var connected: Bool

    public init(id: String, name: String, connected: Bool) {
        self.id = id
        self.name = name
        self.connected = connected
    }
}
