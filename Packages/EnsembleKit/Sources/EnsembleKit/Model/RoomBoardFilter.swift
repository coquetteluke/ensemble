import Foundation

/// High-level message category filter for multi-agent rooms.
public enum RoomBoardCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case decisions
    case discussions
    case hideNotices

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .decisions: "Plans & verdicts"
        case .discussions: "Reviews & Qs"
        case .hideNotices: "Hide notices"
        }
    }

    public var shortLabel: String {
        switch self {
        case .all: "All"
        case .decisions: "Decisions"
        case .discussions: "Reviews"
        case .hideNotices: "No notices"
        }
    }
}

/// Filter and jump helpers for Mac room boards and iPhone Duo room transcripts.
public struct RoomBoardFilter: Equatable, Sendable {
    public var agentID: UUID?
    public var category: RoomBoardCategory
    public var query: String

    public init(agentID: UUID? = nil, category: RoomBoardCategory = .all, query: String = "") {
        self.agentID = agentID
        self.category = category
        self.query = query
    }

    public var isActive: Bool {
        agentID != nil || category != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func clear() {
        agentID = nil
        category = .all
        query = ""
    }

    // MARK: - Mac BoardMessage filtering

    public func matches(_ message: BoardMessage, agents: [UUID: AgentSpec] = [:]) -> Bool {
        if let agentID {
            let fromMatch: Bool
            if case .agent(let senderID) = message.from {
                fromMatch = senderID == agentID
            } else {
                fromMatch = false
            }
            let toMatch = message.to.contains(agentID)
            if !fromMatch && !toMatch { return false }
        }

        switch category {
        case .all:
            break
        case .decisions:
            let decisionKinds: Set<BoardMessageKind> = [.plan, .verdict, .assignment]
            if !decisionKinds.contains(message.kind) { return false }
        case .discussions:
            let discussionKinds: Set<BoardMessageKind> = [.question, .review, .argument]
            let isDirectAgentMessage: Bool = {
                if case .agent = message.from, !message.to.isEmpty { return true }
                return false
            }()
            if !discussionKinds.contains(message.kind) && !isDirectAgentMessage { return false }
        case .hideNotices:
            if message.from == .room || message.kind == .notice { return false }
        }

        let terms = TranscriptFinder.terms(for: query)
        if !terms.isEmpty {
            let haystack = TranscriptFinder.searchableText(of: message, agents: agents)
            for term in terms {
                if haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                    return false
                }
            }
        }
        return true
    }

    public func filter(_ messages: [BoardMessage], agents: [UUID: AgentSpec] = [:]) -> [BoardMessage] {
        guard isActive else { return messages }
        return messages.filter { matches($0, agents: agents) }
    }

    /// Returns the newest message sent by (or directed to, as fallback) the given agent.
    public static func latestMessageID(for agentID: UUID, in messages: [BoardMessage]) -> UUID? {
        if let sent = messages.last(where: {
            if case .agent(let senderID) = $0.from { return senderID == agentID }
            return false
        }) {
            return sent.id
        }
        return messages.last(where: { $0.to.contains(agentID) })?.id
    }

    /// Counts messages authored by each agent on the board.
    public static func messageCountsByAgent(in messages: [BoardMessage]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for message in messages {
            if case .agent(let id) = message.from {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - iPhone Duo Remote TranscriptItem filtering

    public func matches(_ item: TranscriptItem, agents: [UUID: RemoteAgent] = [:]) -> Bool {
        if let agentID {
            let matchesAgent: Bool
            switch item {
            case .agentText(_, _, let senderID, _):
                matchesAgent = senderID == agentID
            case .board(_, let from, let to, _, _):
                matchesAgent = from == agentID || to.contains(agentID)
            case .permission(let request):
                matchesAgent = agents[agentID]?.sessionID == request.sessionID
            default:
                matchesAgent = false
            }
            if !matchesAgent { return false }
        }

        switch category {
        case .all:
            break
        case .decisions:
            switch item {
            case .permission:
                break
            case .agentText(_, let text, _, _), .board(_, _, _, let text, _):
                let upper = text.uppercased()
                let isDecisionLike = upper.contains("PLAN") || upper.contains("VERDICT") || upper.contains("ASSIGN")
                if !isDecisionLike { return false }
            default:
                return false
            }
        case .discussions:
            switch item {
            case .board(_, _, let to, _, _):
                if to.isEmpty { return false }
            case .agentText(_, let text, _, _):
                let upper = text.uppercased()
                if !upper.contains("REVIEW") && !upper.contains("QUESTION") && !text.contains("?") {
                    return false
                }
            default:
                return false
            }
        case .hideNotices:
            if case .notice = item { return false }
        }

        let terms = TranscriptFinder.terms(for: query)
        if !terms.isEmpty {
            var haystack = TranscriptFinder.searchableText(of: item)
            switch item {
            case .agentText(_, _, let senderID, _):
                if let senderID, let name = agents[senderID]?.name { haystack += "\n" + name }
            case .board(_, let from, let to, _, _):
                if let name = agents[from]?.name { haystack += "\n" + name }
                for id in to {
                    if let name = agents[id]?.name { haystack += "\n" + name }
                }
            default:
                break
            }
            for term in terms {
                if haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                    return false
                }
            }
        }
        return true
    }

    public func filter(_ items: [TranscriptItem], agents: [UUID: RemoteAgent] = [:]) -> [TranscriptItem] {
        guard isActive else { return items }
        return items.filter { matches($0, agents: agents) }
    }

    /// Returns the newest item authored by (or directed to, as fallback) the given agent in a remote transcript.
    public static func latestItemID(for agentID: UUID, in items: [TranscriptItem]) -> String? {
        if let authored = items.last(where: { item in
            switch item {
            case .agentText(_, _, let senderID, _): return senderID == agentID
            case .board(_, let from, _, _, _): return from == agentID
            default: return false
            }
        }) {
            return authored.id
        }
        return items.last(where: { item in
            if case .board(_, _, let to, _, _) = item {
                return to.contains(agentID)
            }
            return false
        })?.id
    }

    /// Counts items authored by each agent in a remote room transcript.
    public static func itemCountsByAgent(in items: [TranscriptItem]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in items {
            switch item {
            case .agentText(_, _, let senderID, _):
                if let senderID { counts[senderID, default: 0] += 1 }
            case .board(_, let from, _, _, _):
                counts[from, default: 0] += 1
            default:
                break
            }
        }
        return counts
    }
}
