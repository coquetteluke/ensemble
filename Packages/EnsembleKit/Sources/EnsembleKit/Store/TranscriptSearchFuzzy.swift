import Foundation

/// Fuzzy matching for the command palette: the typed letters must appear in order in the title (or a keyword).
/// Matches at the start of words and consecutive letters score higher, so "tsv" finds "Transcript view: Verbose"
/// and "nse" ranks "New session" first.
public enum FuzzyMatch {
    public struct Result: Hashable, Sendable {
        public var score: Int
        /// Matched characters of the title, as character offsets (empty when only a keyword matched).
        public var positions: [Int]
    }

    /// Scores `query` against `title`, then against each keyword. Any title match ranks above every keyword-only
    /// match. Nil when nothing matches. An empty query matches everything with score 0.
    public static func match(_ query: String, title: String, keywords: [String] = []) -> Result? {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return Result(score: 0, positions: []) }
        if let titleMatch = score(needle, in: title) {
            return Result(score: titleMatch.score + titleBonus, positions: titleMatch.positions)
        }
        let best = keywords.compactMap { score(needle, in: $0)?.score }.max()
        return best.map { Result(score: min($0 / 2, titleBonus - 1), positions: []) }
    }

    static let titleBonus = 1000

    static func score(_ needle: String, in haystack: String) -> Result? {
        let lowered = Array(haystack.lowercased())
        let original = Array(haystack)
        guard lowered.count == original.count else { return nil }
        let query = Array(needle)
        // The query as one piece (at a word start if possible), else letters preferring word starts, else
        // each letter's next occurrence.
        guard let matched = contiguous(query, in: lowered, original: original)
                ?? positions(query, in: lowered, original: original, preferWordStarts: true)
                ?? positions(query, in: lowered, original: original, preferWordStarts: false) else { return nil }
        var score = 0
        var previous = -2
        for position in matched {
            score += 1
            if isWordStart(original, position) { score += 8 }
            if position == previous + 1 { score += 5 }
            if position == 0 { score += 4 }
            previous = position
        }
        // Shorter titles win ties; a title that starts with the query wins outright.
        score -= lowered.count / 8
        if haystack.lowercased().hasPrefix(needle) { score += 20 }
        return Result(score: score, positions: matched)
    }

    private static func contiguous(_ query: [Character], in lowered: [Character], original: [Character]) -> [Int]? {
        guard query.count <= lowered.count else { return nil }
        var first: Int?
        for start in 0...(lowered.count - query.count) where Array(lowered[start..<(start + query.count)]) == query {
            if isWordStart(original, start) { return Array(start..<(start + query.count)) }
            if first == nil { first = start }
        }
        return first.map { Array($0..<($0 + query.count)) }
    }

    private static func positions(_ query: [Character], in lowered: [Character], original: [Character], preferWordStarts: Bool) -> [Int]? {
        var positions: [Int] = []
        var searchFrom = 0
        for q in query {
            var found: Int?
            var index = searchFrom
            while index < lowered.count {
                if lowered[index] == q {
                    // A letter right after the previous match, or at a word start, is taken at once.
                    if !preferWordStarts || isWordStart(original, index) || index == positions.last.map({ $0 + 1 }) {
                        found = index
                        break
                    }
                    if found == nil { found = index }
                }
                index += 1
            }
            guard let position = found else { return nil }
            positions.append(position)
            searchFrom = position + 1
        }
        return positions
    }

    static func isWordStart(_ chars: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = chars[index - 1]
        let current = chars[index]
        if !(before.isLetter || before.isNumber) { return true }
        return before.isLowercase && current.isUppercase
    }
}
