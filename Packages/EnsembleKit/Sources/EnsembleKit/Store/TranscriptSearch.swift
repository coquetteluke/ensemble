import Foundation

// Search across every session's transcript (Command-K). This file holds the pure parts: what text of a
// transcript is searchable, how a typed query becomes terms, how a match becomes a highlighted snippet and how
// sessions are ranked. `TranscriptSearchIndex` stores the text in SQLite; `TranscriptSearchIndexer` keeps it current.

// MARK: - Searchable text

/// One searchable message of a transcript.
public struct TranscriptSearchEntry: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable, CaseIterable {
        case user, agent, tool, error, board
    }

    public var itemID: String
    public var role: Role
    /// Position in the transcript (0 = first item).
    public var ordinal: Int
    public var text: String

    public init(itemID: String, role: Role, ordinal: Int, text: String) {
        self.itemID = itemID
        self.role = role
        self.ordinal = ordinal
        self.text = text
    }
}

public enum TranscriptSearchText {
    /// Longest text kept per message. Longer messages are cut; matches past this point are not found.
    public static let maxEntryLength = 20_000

    /// The searchable messages of a transcript: what you wrote, what agents wrote (Markdown marks removed),
    /// tool call titles (the command or file), board messages and errors. Thinking, notices, permission
    /// prompts and tool output are left out.
    public static func entries(_ items: [TranscriptItem]) -> [TranscriptSearchEntry] {
        var entries: [TranscriptSearchEntry] = []
        for (ordinal, item) in items.enumerated() {
            let role: TranscriptSearchEntry.Role
            let text: String
            switch item {
            case .user(_, let value, _):
                role = .user
                text = value
            case .agentText(_, let value, _, _):
                role = .agent
                text = plain(value)
            case .tool(let tool):
                role = .tool
                text = tool.title
            case .board(_, _, _, let value, _):
                role = .board
                text = plain(value)
            case .error(_, let message):
                role = .error
                text = message
            case .reasoning, .permission, .notice:
                continue
            }
            let cleaned = collapseWhitespace(String(text.prefix(maxEntryLength)))
            guard !cleaned.isEmpty else { continue }
            entries.append(TranscriptSearchEntry(itemID: item.id, role: role, ordinal: ordinal, text: cleaned))
        }
        return entries
    }

    /// Markdown as plain reading text: fences, heading and quote marks, emphasis and backticks removed,
    /// links reduced to their text.
    public static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            while line.hasPrefix("#") || line.hasPrefix(">") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line.removeFirst(2) }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")
        // [label](url) -> label
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: mark, with: "")
        }
        return text
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Query

/// What was typed into the search field, as lowercased word terms. Every term must appear in a message,
/// each as the start of a word ("recon" finds "reconnect").
public struct TranscriptSearchQuery: Hashable, Sendable {
    public var terms: [String]

    public init(_ raw: String) {
        var seen: Set<String> = []
        terms = TranscriptSearchQuery.words(raw).filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// The SQLite FTS5 expression: every term quoted and matched as a prefix.
    public var ftsExpression: String {
        terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    /// Lowercased, accent-free runs of letters and digits, the same way SQLite's `unicode61` tokenizer splits words.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(TextFolding.fold(character))
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Case and accent folding, one character at a time so offsets stay the same as in the original text.
enum TextFolding {
    static func fold(_ character: Character) -> Character {
        if let ascii = character.asciiValue {
            return (65...90).contains(ascii) ? Character(UnicodeScalar(ascii + 32)) : character
        }
        let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.count == 1 ? folded.first ?? character : character
    }

    static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    /// Character ranges where a term starts a word in `chars` (already folded).
    static func matches(of terms: [String], in folded: [Character]) -> [(range: Range<Int>, term: Int, wholeWord: Bool)] {
        var found: [(Range<Int>, Int, Bool)] = []
        let termChars = terms.map(Array.init)
        var i = 0
        while i < folded.count {
            if TextFolding.isWordCharacter(folded[i]), i == 0 || !TextFolding.isWordCharacter(folded[i - 1]) {
                var best: (length: Int, term: Int)?
                for (index, term) in termChars.enumerated() where !term.isEmpty && i + term.count <= folded.count {
                    if Array(folded[i..<(i + term.count)]) == term, term.count > (best?.length ?? 0) {
                        best = (term.count, index)
                    }
                }
                if let best {
                    let end = i + best.length
                    let whole = end == folded.count || !TextFolding.isWordCharacter(folded[end])
                    found.append((i..<end, best.term, whole))
                    i = end
                    continue
                }
            }
            i += 1
        }
        return found
    }
}

// MARK: - Snippets

/// A short piece of a message around the matched words, with the matches marked.
public struct TranscriptSnippet: Hashable, Sendable {
    public var text: String
    /// Matched words, as character offsets into `text`.
    public var highlights: [Range<Int>]

    public init(text: String, highlights: [Range<Int>]) {
        self.text = text
        self.highlights = highlights
    }

    /// Highlights of every term in `text` (for titles, which are shown whole).
    public static func marking(_ text: String, terms: [String]) -> TranscriptSnippet {
        let folded = text.map(TextFolding.fold)
        return TranscriptSnippet(text: text, highlights: TextFolding.matches(of: terms, in: folded).map(\.range))
    }

    /// The part of `text` with the most distinct terms close together, about `length` characters long, cut at
    /// word boundaries with an ellipsis where text was left out.
    public static func make(_ text: String, terms: [String], length: Int = 150) -> TranscriptSnippet {
        let chars = Array(text.map { $0.isNewline ? " " : $0 })
        let folded = chars.map(TextFolding.fold)
        let matches = TextFolding.matches(of: terms, in: folded)
        guard !chars.isEmpty else { return TranscriptSnippet(text: "", highlights: []) }
        if chars.count <= length {
            return TranscriptSnippet(text: String(chars), highlights: matches.map(\.range))
        }

        // The match whose window holds the most distinct terms; the earliest wins a tie.
        var anchor = matches.first?.range.lowerBound ?? 0
        var bestDistinct = 0
        for match in matches {
            let windowEnd = match.range.lowerBound + length * 2 / 3
            let distinct = Set(matches.filter { $0.range.lowerBound >= match.range.lowerBound && $0.range.lowerBound < windowEnd }.map(\.term)).count
            if distinct > bestDistinct {
                bestDistinct = distinct
                anchor = match.range.lowerBound
            }
        }

        // Some words of context before the match, then cut at word boundaries.
        var start = max(0, anchor - length / 3)
        if start > 0 {
            while start < anchor, chars[start - 1] != " " { start += 1 }
        }
        var end = min(chars.count, start + length)
        if end < chars.count {
            var cut = end
            while cut > start + length / 2, chars[cut - 1] != " " { cut -= 1 }
            if cut > start + length / 2 { end = cut }
        }
        while start < end, chars[start] == " " { start += 1 }
        while end > start, chars[end - 1] == " " { end -= 1 }

        let prefix = start > 0 ? "\u{2026}" : ""
        let suffix = end < chars.count ? "\u{2026}" : ""
        let shift = prefix.count - start
        let highlights = matches
            .filter { $0.range.lowerBound >= start && $0.range.upperBound <= end }
            .map { ($0.range.lowerBound + shift)..<($0.range.upperBound + shift) }
        return TranscriptSnippet(text: prefix + String(chars[start..<end]) + suffix, highlights: highlights)
    }
}

// MARK: - Results and ranking

/// Which sessions a search looks in.
public enum TranscriptSearchFilter: String, CaseIterable, Hashable, Sendable {
    /// Every session, archived ones included (marked as archived).
    case all
    /// Sessions in the folder of the session on screen.
    case folder
    /// Archived sessions only.
    case archived

    public var label: String {
        switch self {
        case .all: "All"
        case .folder: "This folder"
        case .archived: "Archived"
        }
    }
}

/// A session as search needs it, taken from the store when the search runs (so renames and archiving show at once).
public struct TranscriptSearchSession: Hashable, Sendable {
    public var id: String
    public var title: String
    public var directory: String
    public var updated: Date
    public var archived: Bool

    public init(id: String, title: String, directory: String, updated: Date, archived: Bool) {
        self.id = id
        self.title = title
        self.directory = directory
        self.updated = updated
        self.archived = archived
    }
}

/// A message the index matched, before ranking.
public struct TranscriptSearchRawHit: Hashable, Sendable {
    public var sessionID: String
    public var itemID: String
    public var role: TranscriptSearchEntry.Role
    public var ordinal: Int
    public var text: String
    /// SQLite's bm25 rank: lower (more negative) is a better match.
    public var rank: Double

    public init(sessionID: String, itemID: String, role: TranscriptSearchEntry.Role, ordinal: Int, text: String, rank: Double) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.role = role
        self.ordinal = ordinal
        self.text = text
        self.rank = rank
    }
}

/// One matched message under a session in the results.
public struct TranscriptSearchMatch: Identifiable, Hashable, Sendable {
    public var itemID: String
    public var role: TranscriptSearchEntry.Role
    public var snippet: TranscriptSnippet
    public var id: String { itemID }

    public init(itemID: String, role: TranscriptSearchEntry.Role, snippet: TranscriptSnippet) {
        self.itemID = itemID
        self.role = role
        self.snippet = snippet
    }
}

/// One session in the results, with its best matching messages.
public struct TranscriptSearchResult: Identifiable, Hashable, Sendable {
    public var session: TranscriptSearchSession
    public var title: TranscriptSnippet
    public var matches: [TranscriptSearchMatch]
    /// Every matched message in the session, including ones not shown.
    public var matchCount: Int
    public var score: Double
    public var id: String { session.id }

    public init(session: TranscriptSearchSession, title: TranscriptSnippet, matches: [TranscriptSearchMatch], matchCount: Int, score: Double) {
        self.session = session
        self.title = title
        self.matches = matches
        self.matchCount = matchCount
        self.score = score
    }
}

public enum TranscriptSearchRanker {
    /// Sessions `filter` lets through. `folder` is the folder of the session on screen.
    public static func passes(_ session: TranscriptSearchSession, filter: TranscriptSearchFilter, folder: String?) -> Bool {
        switch filter {
        case .all: true
        case .folder: folder.map { session.directory == $0 } ?? false
        case .archived: session.archived
        }
    }

    /// Groups matched messages by session and orders the sessions. A title holding every term ranks first, then
    /// sessions with more and better matches (your own words and whole words count more), then newer sessions.
    /// An empty query lists the newest sessions.
    public static func rank(query: TranscriptSearchQuery, hits: [TranscriptSearchRawHit], sessions: [TranscriptSearchSession],
                            filter: TranscriptSearchFilter, folder: String?, now: Date = Date(),
                            matchesPerSession: Int = 3, limit: Int = 60) -> [TranscriptSearchResult] {
        let visible = sessions.filter { passes($0, filter: filter, folder: folder) }
        if query.isEmpty {
            return visible.sorted { $0.updated > $1.updated }.prefix(limit).map {
                TranscriptSearchResult(session: $0, title: TranscriptSnippet(text: $0.title, highlights: []), matches: [], matchCount: 0, score: 0)
            }
        }

        let hitsBySession = Dictionary(grouping: hits, by: \.sessionID)
        var results: [TranscriptSearchResult] = []
        for session in visible {
            let titleFolded = session.title.map(TextFolding.fold)
            let titleMatches = TextFolding.matches(of: query.terms, in: titleFolded)
            let titleTerms = Set(titleMatches.map(\.term))
            let sessionHits = hitsBySession[session.id] ?? []
            guard !titleTerms.isEmpty || !sessionHits.isEmpty else { continue }

            var score = 0.0
            if titleTerms.count == query.terms.count {
                score += 100
            } else if sessionHits.isEmpty {
                // A title holding only some of the terms, and no message holding them all: not a result.
                continue
            } else {
                score += 30 * Double(titleTerms.count) / Double(query.terms.count)
            }

            // Best messages first: whole words and your own messages count more, then SQLite's rank, then newest.
            let scored = sessionHits.map { hit -> (hit: TranscriptSearchRawHit, value: Double) in
                let folded = Array(hit.text.prefix(4000)).map(TextFolding.fold)
                let wholeWords = Set(TextFolding.matches(of: query.terms, in: folded).filter(\.wholeWord).map(\.term)).count
                let value = weight(hit.role) * (1 + 0.5 * Double(wholeWords) / Double(query.terms.count)) + min(1, max(0, -hit.rank) / 10)
                return (hit, value)
            }
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.hit.ordinal > b.hit.ordinal
            }
            score += scored.prefix(3).reduce(0) { $0 + $1.value * 10 }
            score += log2(1 + Double(sessionHits.count)) * 5
            let ageDays = max(0, now.timeIntervalSince(session.updated)) / 86_400
            score += 10 * exp(-ageDays / 30)

            let matches = scored.prefix(matchesPerSession).map {
                TranscriptSearchMatch(itemID: $0.hit.itemID, role: $0.hit.role, snippet: TranscriptSnippet.make($0.hit.text, terms: query.terms))
            }
            results.append(TranscriptSearchResult(session: session,
                                                  title: TranscriptSnippet(text: session.title, highlights: titleMatches.map(\.range)),
                                                  matches: Array(matches), matchCount: sessionHits.count, score: score))
        }
        return Array(results.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.session.updated > b.session.updated
        }.prefix(limit))
    }

    static func weight(_ role: TranscriptSearchEntry.Role) -> Double {
        switch role {
        case .user: 1.3
        case .agent, .board: 1.0
        case .tool: 0.7
        case .error: 0.6
        }
    }
}
