import Foundation

/// `ASSIGN @name: task` from a lead's plan.
public struct ParsedAssignment: Equatable, Hashable, Sendable {
    /// The roster name as written in the room (canonical spelling), or the raw name when it is not in the roster.
    public var name: String
    public var task: String

    public init(name: String, task: String) {
        self.name = name
        self.task = task
    }
}

/// A block of lines starting with `@name` (or `@all`) that the room delivers to those agents.
public struct AddressedMessage: Equatable, Hashable, Sendable {
    /// Roster names (canonical spelling). Empty when `toAll`.
    public var names: [String]
    public var toAll: Bool
    public var text: String

    public init(names: [String], toAll: Bool, text: String) {
        self.names = names
        self.toAll = toAll
        self.text = text
    }
}

public enum ReviewVerdict: Equatable, Hashable, Sendable {
    case approve
    case changes(String)
}

/// What the engine understood from one agent turn.
public struct ParsedReply: Equatable, Sendable {
    public var plan: String?
    public var assignments: [ParsedAssignment] = []
    public var done = false
    public var approve = false
    public var changes: String?
    public var agree = false
    public var takeover = false
    public var verdict: String?
    public var addressed: [AddressedMessage] = []
    /// The reply without its addressed blocks: what goes to the board for the user and the lead.
    public var boardText: String = ""

    public init() {}

    /// CHANGES wins over APPROVE when a reply has both.
    public var reviewVerdict: ReviewVerdict? {
        if let changes { return .changes(changes) }
        if approve { return .approve }
        return nil
    }

    public var hasKeyword: Bool {
        plan != nil || !assignments.isEmpty || done || approve || changes != nil || agree || takeover || verdict != nil
    }
}

/// Reads the room keywords out of an agent's reply.
///
/// Keywords count at the start of a line, case-insensitively, after list markers (`-`, `*`, `1.`),
/// headings, checkboxes and bold or code marks. A short label is allowed before the review words
/// (`Review: APPROVE`, `**Status:** DONE`). Text inside code fences and block quotes is ignored.
/// To keep prose like "Done with step one, now..." from counting, a mixed-case keyword must be
/// followed by punctuation or the end of the line; an all-caps keyword may be followed by words.
/// An all-caps DONE, APPROVE, AGREE or TAKEOVER at the very end of the reply also counts.
public struct RoomReplyParser: Sendable {
    public var agentNames: [String]

    public init(agentNames: [String] = []) {
        self.agentNames = agentNames.sorted { $0.count > $1.count }
    }

    // MARK: Public

    public func parse(_ text: String) -> ParsedReply {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var reply = ParsedReply()
        var boardLines: [String] = []
        var planLines: [String]?
        var verdictLines: [String]?
        var changesLines: [String]?
        var assignIndex: Int?
        var inFence = false
        var lastContentLine: String?

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if Self.isFence(trimmed) {
                inFence.toggle()
                boardLines.append(raw)
                planLines?.append(raw)
                verdictLines?.append(raw)
                changesLines?.append(raw)
                assignIndex = nil
                i += 1
                continue
            }
            if inFence || trimmed.hasPrefix(">") {
                boardLines.append(raw)
                planLines?.append(raw)
                verdictLines?.append(raw)
                changesLines?.append(raw)
                i += 1
                continue
            }
            if !trimmed.isEmpty { lastContentLine = trimmed }

            if let address = parseAddressLine(trimmed) {
                var body: [String] = address.text.isEmpty ? [] : [address.text]
                var j = i + 1
                while j < lines.count {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || Self.isFence(next) || next.hasPrefix(">") || Self.normalize(next).first == "@"
                        || keyword(in: next) != nil { break }
                    body.append(next)
                    lastContentLine = next
                    j += 1
                }
                let message = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    reply.addressed.append(AddressedMessage(names: address.names, toAll: address.toAll, text: message))
                }
                assignIndex = nil
                i = j
                continue
            }

            boardLines.append(raw)

            if let kw = keyword(in: trimmed) {
                switch kw {
                case .plan(let rest):
                    planLines = rest.isEmpty ? [] : [rest]
                    changesLines = nil
                    assignIndex = nil
                    i += 1
                    continue
                case .assign(let name, let task):
                    reply.assignments.append(ParsedAssignment(name: name, task: task))
                    assignIndex = reply.assignments.count - 1
                    changesLines = nil
                case .done:
                    reply.done = true
                    changesLines = nil
                    assignIndex = nil
                case .approve:
                    reply.approve = true
                    changesLines = nil
                    assignIndex = nil
                case .changes(let rest):
                    changesLines = rest.isEmpty ? [] : [rest]
                    assignIndex = nil
                    i += 1
                    planLines?.append(raw)
                    verdictLines?.append(raw)
                    continue
                case .agree:
                    reply.agree = true
                    changesLines = nil
                    assignIndex = nil
                case .takeover:
                    reply.takeover = true
                    changesLines = nil
                    assignIndex = nil
                case .verdict(let rest):
                    verdictLines = rest.isEmpty ? [] : [rest]
                    // "VERDICT: APPROVE" in a review still counts as the review word.
                    applyReviewWord(in: rest, to: &reply)
                    changesLines = nil
                    assignIndex = nil
                    planLines?.append(raw)
                    i += 1
                    continue
                }
                planLines?.append(raw)
                verdictLines?.append(raw)
                i += 1
                continue
            }

            // Continuation lines.
            if let idx = assignIndex {
                if !trimmed.isEmpty, raw.first?.isWhitespace == true {
                    reply.assignments[idx].task += "\n" + trimmed
                } else {
                    assignIndex = nil
                }
            }
            planLines?.append(raw)
            verdictLines?.append(raw)
            changesLines?.append(raw)
            i += 1
        }

        if let planLines { reply.plan = Self.joinSection(planLines) }
        if let verdictLines { reply.verdict = Self.joinSection(verdictLines) }
        if let changesLines {
            let text = Self.joinSection(changesLines)
            reply.changes = Self.isEmptyChanges(text) ? nil : text
        }

        if let last = lastContentLine { applyTrailingKeyword(last, to: &reply) }

        reply.boardText = Self.joinSection(boardLines)
        return reply
    }

    /// `@name rest` or `@all rest` at the start of a user's message: who it goes to and the text without the address.
    public func leadingAddress(_ text: String) -> AddressedMessage? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        guard let address = parseAddressLine(lines[firstIndex].trimmingCharacters(in: .whitespaces)) else { return nil }
        var body = [address.text]
        body.append(contentsOf: lines[(firstIndex + 1)...])
        let message = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AddressedMessage(names: address.names, toAll: address.toAll, text: message)
    }

    /// The canonical roster name for a name an agent wrote (`beta`, `@Beta`, `**Beta**`).
    public func rosterName(for written: String) -> String? {
        var s = Substring(written.trimmingCharacters(in: .whitespaces))
        s = s.drop { $0 == "@" || Self.isEmphasis($0) }
        while let last = s.last, Self.isEmphasis(last) || last == ":" || last == "," || last == "." { s = s.dropLast() }
        return agentNames.first { $0.compare(String(s), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    // MARK: Keywords

    enum LineKeyword: Equatable {
        case plan(String)
        case assign(String, String)
        case done
        case approve
        case changes(String)
        case agree
        case takeover
        case verdict(String)
    }

    static let changesWords = ["CHANGES REQUESTED", "REQUESTED CHANGES", "REQUEST CHANGES", "CHANGES NEEDED", "CHANGES"]
    static let approveWords = ["APPROVED", "APPROVE"]
    static let doneWords = ["DONE"]
    static let agreeWords = ["I AGREE", "AGREED", "AGREE"]
    static let takeoverWords = ["TAKEOVER", "TAKE OVER", "TAKING OVER"]
    static let reviewLabels: Set<String> = [
        "review", "my review", "decision", "final decision", "status", "result", "outcome", "vote", "my vote",
        "final", "final answer", "answer", "response", "recommendation",
    ]

    func keyword(in line: String) -> LineKeyword? {
        let s = Self.normalize(line)
        guard !s.isEmpty else { return nil }
        if let assign = matchAssign(s) { return assign }
        if let rest = Self.match(s, ["FINAL VERDICT", "VERDICT"]) { return .verdict(rest) }
        if let rest = Self.match(s, ["PROPOSED PLAN", "UPDATED PLAN", "REVISED PLAN", "THE PLAN", "PLAN"]) { return .plan(rest) }
        return Self.reviewWord(in: Self.stripLabel(s) ?? s)
    }

    static func reviewWord(in s: Substring) -> LineKeyword? {
        if let rest = match(s, changesWords) { return .changes(rest) }
        if match(s, approveWords) != nil { return .approve }
        if match(s, doneWords) != nil { return .done }
        if match(s, agreeWords) != nil { return .agree }
        if match(s, takeoverWords) != nil { return .takeover }
        return nil
    }

    private func applyReviewWord(in text: String, to reply: inout ParsedReply) {
        let s = Self.normalize(text)
        switch Self.reviewWord(in: s) {
        case .approve?: reply.approve = true
        case .changes(let rest)?:
            if !Self.isEmptyChanges(rest) { reply.changes = rest }
        default: break
        }
    }

    /// An all-caps keyword ending the last line: "All tests pass. **DONE**".
    private func applyTrailingKeyword(_ line: String, to reply: inout ParsedReply) {
        var s = Substring(line)
        while let last = s.last, !(last.isLetter || last.isNumber) { s = s.dropLast() }
        let words: [(String, WritableKeyPath<ParsedReply, Bool>)] = [
            ("DONE", \.done), ("APPROVED", \.approve), ("APPROVE", \.approve),
            ("AGREED", \.agree), ("AGREE", \.agree), ("TAKEOVER", \.takeover),
        ]
        for (word, path) in words where s.hasSuffix(word) {
            let before = s.dropLast(word.count)
            if let c = before.last, c.isLetter || c.isNumber { continue }
            reply[keyPath: path] = true
            return
        }
    }

    // MARK: Assign

    private func matchAssign(_ s: Substring) -> LineKeyword? {
        for word in ["ASSIGNMENT", "ASSIGNED", "ASSIGN"] {
            guard s.count > word.count, Self.hasPrefixIgnoringCase(s, word) else { continue }
            var rest = s.dropFirst(word.count)
            guard let first = rest.first, !(first.isLetter || first.isNumber) else { continue }
            rest = rest.drop { $0.isWhitespace || Self.isEmphasis($0) || $0 == ":" || $0 == "-" }
            if Self.hasPrefixIgnoringCase(rest, "to ") { rest = rest.dropFirst(3).drop { $0.isWhitespace } }
            guard let (name, afterName) = parseName(rest, requireAt: false, allowUnknown: true) else { continue }
            var task = afterName.drop { $0.isWhitespace || Self.isEmphasis($0) }
            task = task.drop { ":-,=>\u{2013}\u{2014}".contains($0) || $0.isWhitespace || Self.isEmphasis($0) }
            return .assign(name, Self.clean(task))
        }
        return nil
    }

    // MARK: Addresses

    struct AddressLine: Equatable {
        var names: [String]
        var toAll: Bool
        var text: String
    }

    static let allWords = ["everyone", "everybody", "all", "team", "room"]

    func parseAddressLine(_ line: String) -> AddressLine? {
        var rest = Self.normalize(line)
        guard rest.first == "@" else { return nil }
        var names: [String] = []
        var toAll = false
        while rest.first == "@" {
            let body = rest.dropFirst()
            if let word = Self.allWords.first(where: { Self.wordPrefix(body, $0) }) {
                toAll = true
                rest = body.dropFirst(word.count)
            } else if let (name, after) = parseName(rest, requireAt: true) {
                if !names.contains(name) { names.append(name) }
                rest = after
            } else {
                break
            }
            rest = rest.drop { $0.isWhitespace || Self.isEmphasis($0) || $0 == "," || $0 == "&" || $0 == "/" }
            if Self.hasPrefixIgnoringCase(rest, "and @") { rest = rest.dropFirst(4) }
        }
        guard toAll || !names.isEmpty else { return nil }
        if toAll { names = [] }
        let text = rest.drop { ":-,\u{2013}\u{2014}".contains($0) || $0.isWhitespace || Self.isEmphasis($0) }
        return AddressLine(names: names, toAll: toAll, text: Self.clean(text))
    }

    /// A roster name at the start of `s` (after an optional `@`). Longest roster name wins, so
    /// multi-word names work. Without a roster, any word after `@` counts; with `allowUnknown`, an
    /// `@word` that is not in the roster comes back as written (so the engine can say who is missing).
    private func parseName(_ s: Substring, requireAt: Bool, allowUnknown: Bool = false) -> (String, Substring)? {
        var t = s
        let hadAt = t.first == "@"
        if hadAt { t = t.dropFirst() } else if requireAt { return nil }
        t = t.drop { Self.isEmphasis($0) }
        if !agentNames.isEmpty {
            for name in agentNames {
                guard t.count >= name.count else { continue }
                let head = t.prefix(name.count)
                guard head.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { continue }
                let after = t.dropFirst(name.count)
                if let c = after.first, c.isLetter || c.isNumber { continue }
                return (name, after)
            }
            guard allowUnknown && hadAt else { return nil }
        }
        guard hadAt || !requireAt else { return nil }
        let word = t.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        var name = String(word)
        while name.hasSuffix(".") || name.hasSuffix("-") { name.removeLast() }
        guard !name.isEmpty else { return nil }
        return (name, t.dropFirst(name.count))
    }

    // MARK: Text helpers

    static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    static func isEmphasis(_ c: Character) -> Bool {
        c == "*" || c == "_" || c == "`" || c == "~"
    }

    static func hasPrefixIgnoringCase(_ s: Substring, _ prefix: String) -> Bool {
        guard s.count >= prefix.count else { return false }
        return s.prefix(prefix.count).compare(prefix, options: [.caseInsensitive]) == .orderedSame
    }

    static func wordPrefix(_ s: Substring, _ word: String) -> Bool {
        guard hasPrefixIgnoringCase(s, word) else { return false }
        if let c = s.dropFirst(word.count).first, c.isLetter || c.isNumber { return false }
        return true
    }

    /// Strips list markers, headings, checkboxes and leading emphasis or symbols. Keeps a leading `@`.
    static func normalize(_ line: String) -> Substring {
        var s = Substring(line).drop { $0.isWhitespace }
        var changed = true
        while changed, !s.isEmpty {
            changed = false
            for box in ["[ ]", "[x]", "[X]"] where s.hasPrefix(box) {
                s = s.dropFirst(box.count).drop { $0.isWhitespace }
                changed = true
            }
            if changed { continue }
            if let first = s.first, first.isNumber {
                let digits = s.prefix { $0.isNumber }
                let after = s.dropFirst(digits.count)
                if digits.count <= 3, let mark = after.first, mark == "." || mark == ")" {
                    let next = after.dropFirst().first
                    if next == nil || next!.isWhitespace {
                        s = after.dropFirst().drop { $0.isWhitespace }
                        changed = true
                        continue
                    }
                }
            }
            if let c = s.first, c != "@", c != "[", c.isPunctuation || c.isSymbol {
                s = s.dropFirst().drop { $0.isWhitespace }
                changed = true
            }
        }
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return s
    }

    /// Matches one of `variants` at the start of `s`. Returns the rest of the line after the keyword and
    /// its separator, or `nil`. See the type comment for the punctuation rule.
    static func match(_ s: Substring, _ variants: [String]) -> String? {
        for v in variants {
            guard hasPrefixIgnoringCase(s, v) else { continue }
            let caps = s.prefix(v.count) == Substring(v)
            var rest = s.dropFirst(v.count)
            rest = rest.drop { isEmphasis($0) }
            guard let c = rest.first else { return "" }
            if c.isLetter || c.isNumber { continue }
            if c == "," {
                if caps { return clean(rest.dropFirst()) }
                continue
            }
            if c.isWhitespace {
                let after = rest.drop { $0.isWhitespace || isEmphasis($0) }
                guard let d = after.first else { return "" }
                if d.isLetter || d.isNumber || d == "@" {
                    if caps { return clean(after) }
                    continue
                }
                if ":-.!;=>,\u{2013}\u{2014}".contains(d) { return clean(after.dropFirst()) }
                return clean(after)
            }
            return clean(rest.dropFirst())
        }
        return nil
    }

    /// `Review: APPROVE` -> `APPROVE`.
    static func stripLabel(_ s: Substring) -> Substring? {
        guard let colon = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: colon) <= 24 else { return nil }
        let label = s[..<colon].filter { !isEmphasis($0) }.trimmingCharacters(in: .whitespaces).lowercased()
        guard reviewLabels.contains(label) else { return nil }
        return s[s.index(after: colon)...].drop { $0.isWhitespace || isEmphasis($0) }
    }

    /// Trims whitespace and bold or italic marks. Backticks stay, so `file.swift` keeps its code marks.
    static func clean<S: StringProtocol>(_ s: S) -> String {
        let marks: (Character) -> Bool = { $0.isWhitespace || $0 == "*" || $0 == "_" }
        var t = Substring(s)
        t = t.drop(while: marks)
        while let last = t.last, marks(last) { t = t.dropLast() }
        return String(t)
    }

    static func joinSection(_ lines: [String]) -> String {
        var out = lines
        while let first = out.first, first.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func isEmptyChanges(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["", "none", "no", "n/a", "na", "nothing", "no changes", "none needed", "no changes needed"].contains(t)
    }
}
