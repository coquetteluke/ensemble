import Foundation

/// One matched row in a transcript or room board search.
public struct TranscriptFindMatch: Equatable, Hashable, Sendable {
    public var itemID: String
    public var occurrenceCount: Int

    public init(itemID: String, occurrenceCount: Int) {
        self.itemID = itemID
        self.occurrenceCount = occurrenceCount
    }
}

/// Active highlight state passed into transcript views while live Find is open.
public struct TranscriptFindHighlight: Equatable, Sendable {
    public var matchedItemIDs: Set<String>
    public var activeItemID: String?
    public var scrollToken: Int

    public init(matchedItemIDs: Set<String> = [], activeItemID: String? = nil, scrollToken: Int = 0) {
        self.matchedItemIDs = matchedItemIDs
        self.activeItemID = activeItemID
        self.scrollToken = scrollToken
    }

    public var isEmpty: Bool { matchedItemIDs.isEmpty }
}

/// Result of searching a live transcript or room board for a query.
public struct TranscriptFindResult: Equatable, Sendable {
    public var query: String
    public var matches: [TranscriptFindMatch]
    public var matchedItemIDs: Set<String>
    public var totalOccurrences: Int

    public init(query: String, matches: [TranscriptFindMatch]) {
        self.query = query
        self.matches = matches
        self.matchedItemIDs = Set(matches.map(\.itemID))
        self.totalOccurrences = matches.reduce(0) { $0 + $1.occurrenceCount }
    }

    public static let empty = TranscriptFindResult(query: "", matches: [])

    public var isEmpty: Bool { matches.isEmpty }
    public var matchCount: Int { matches.count }

    /// Clamps an arbitrary index into valid bounds for `matches` (0 when empty).
    public func clampedIndex(_ index: Int) -> Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(0, index), matches.count - 1)
    }

    /// Returns the item ID for the active match index, clamping safely if items changed.
    public func activeItemID(at index: Int) -> String? {
        guard !matches.isEmpty else { return nil }
        return matches[clampedIndex(index)].itemID
    }

    /// Next match index with wrap-around.
    public func nextIndex(after index: Int) -> Int {
        guard !matches.isEmpty else { return 0 }
        return (clampedIndex(index) + 1) % matches.count
    }

    /// Previous match index with wrap-around.
    public func previousIndex(before index: Int) -> Int {
        guard !matches.isEmpty else { return 0 }
        let current = clampedIndex(index)
        return (current - 1 + matches.count) % matches.count
    }

    /// Builds the highlight descriptor for transcript views at the given index.
    public func highlight(at index: Int, scrollToken: Int = 0) -> TranscriptFindHighlight {
        TranscriptFindHighlight(
            matchedItemIDs: matchedItemIDs,
            activeItemID: activeItemID(at: index),
            scrollToken: scrollToken
        )
    }

    /// Short counter text such as "2 of 7" or "No matches".
    public func statusText(at index: Int) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(clampedIndex(index) + 1) of \(matches.count)"
    }
}

/// Live in-transcript search across user messages, agent replies, reasoning, tool calls, diffs,
/// permissions, board messages, notices, and errors.
public enum TranscriptFinder {
    private static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Splits a query into non-empty search terms.
    public static func terms(for query: String) -> [String] {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Searches a list of `TranscriptItem`s in display order.
    public static func search(_ query: String, in items: [TranscriptItem]) -> TranscriptFindResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTerms = terms(for: trimmed)
        guard !queryTerms.isEmpty else { return .empty }

        var matches: [TranscriptFindMatch] = []
        for item in items {
            let haystack = searchableText(of: item)
            guard let count = matchCount(trimmedQuery: trimmed, terms: queryTerms, in: haystack) else {
                continue
            }
            matches.append(TranscriptFindMatch(itemID: item.id, occurrenceCount: count))
        }
        return TranscriptFindResult(query: trimmed, matches: matches)
    }

    /// Searches a Mac room's board messages in display order.
    public static func search(
        _ query: String,
        in messages: [BoardMessage],
        agents: [UUID: AgentSpec] = [:]
    ) -> TranscriptFindResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTerms = terms(for: trimmed)
        guard !queryTerms.isEmpty else { return .empty }

        var matches: [TranscriptFindMatch] = []
        for message in messages {
            let haystack = searchableText(of: message, agents: agents)
            guard let count = matchCount(trimmedQuery: trimmed, terms: queryTerms, in: haystack) else {
                continue
            }
            matches.append(TranscriptFindMatch(itemID: message.id.uuidString, occurrenceCount: count))
        }
        return TranscriptFindResult(query: trimmed, matches: matches)
    }

    /// Extracts all user-visible searchable text from a transcript item.
    public static func searchableText(of item: TranscriptItem) -> String {
        switch item {
        case .user(_, let text, _):
            return text
        case .agentText(_, let text, _, _):
            return text
        case .reasoning(_, let text, _):
            return text
        case .tool(let tool):
            var parts: [String] = [tool.name, tool.title]
            if !tool.inputJSON.isEmpty, tool.inputJSON != "{}" {
                parts.append(tool.inputJSON)
            }
            if let output = tool.outputPreview, !output.isEmpty {
                parts.append(output)
            }
            if let diff = tool.diff, !diff.isEmpty {
                parts.append(diff)
            }
            return parts.joined(separator: "\n")
        case .permission(let request):
            var parts: [String] = [request.kind, request.title]
            if let detail = request.detail, !detail.isEmpty {
                parts.append(detail)
            }
            if let plan = request.plan {
                parts.append(plan.markdown)
            }
            if let questions = request.questions {
                for q in questions {
                    parts.append(q.text)
                    if let header = q.header { parts.append(header) }
                    for opt in q.options {
                        parts.append(opt.label)
                        if let detail = opt.detail { parts.append(detail) }
                    }
                }
            }
            return parts.joined(separator: "\n")
        case .board(_, _, _, let text, _):
            return text
        case .error(_, let message):
            return message
        case .notice(_, let text):
            return text
        }
    }

    /// Extracts searchable text from a room board message, including sender and recipient names.
    public static func searchableText(of message: BoardMessage, agents: [UUID: AgentSpec] = [:]) -> String {
        var parts: [String] = [message.text]
        switch message.from {
        case .agent(let id):
            if let name = agents[id]?.name { parts.append(name) }
        case .user:
            parts.append("You")
        case .room:
            parts.append("Room")
        }
        for recipientID in message.to {
            if let name = agents[recipientID]?.name { parts.append(name) }
        }
        return parts.joined(separator: "\n")
    }

    private static func matchCount(trimmedQuery: String, terms: [String], in haystack: String) -> Int? {
        guard !haystack.isEmpty else { return nil }
        for term in terms {
            if haystack.range(of: term, options: compareOptions) == nil {
                return nil
            }
        }
        let exact = countOccurrences(of: trimmedQuery, in: haystack)
        if exact > 0 { return exact }
        var total = 0
        for term in terms {
            total += countOccurrences(of: term, in: haystack)
        }
        return max(1, total)
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let range = haystack.range(of: needle, options: compareOptions, range: start..<haystack.endIndex) {
            count += 1
            // Guard against zero-length matches from combining characters.
            start = range.upperBound > start ? range.upperBound : haystack.index(after: start)
        }
        return count
    }
}
