import Foundation

// Google AI plan use, as the official `agy` reports it (agy 1.5.10, checked 2026-11-18; see
// docs/reference/antigravity-engine-notes.md, "Plan usage").
//
// - `agy -p "/usage" --output-format json` answers agy's own `/usage` command without starting an agent turn, spending
//   quota or leaving a conversation behind (`num_turns: 0`, empty `conversation_id`). `command.data.groups` lists the
//   model groups ("Gemini Models", "Claude and GPT models"), each with a five-hour and a weekly bucket:
//   `{"id": "gemini-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remaining_fraction": 0.98,
//   "reset_time": "2026-11-18T18:20:35Z"}`. `--output-format stream-json` sends the same object as a `command_result`
//   event and again inside `result`. Without `--output-format` it prints one tab-separated line per bucket.
// - Over ACP there is no such command: `available_commands_update` has no usage, quota or credits entry, and a prompt
//   "/usage" goes to the model as a normal turn. So Ensemble runs the print-mode command, never an ACP prompt.
// - When a limit is hit, a failed turn reports agy's error text (agy 1.5.10 reports "the specific error, such as a model
//   or quota error"). No real limit was spent to see it; `AntigravityLimitText` matches the quota wording agy itself
//   uses (its own `RESOURCE_EXHAUSTED|quota|429|exhausted your capacity` check, "individual quota reached", "Your AI
//   credits balance is too low to continue.") and reads a reset time when the text has one.

/// The Google AI plan's limits from agy's `/usage` command.
public struct AntigravityPlanUsage: Codable, Hashable, Sendable {
    /// One limit of a model group.
    public struct Bucket: Codable, Hashable, Sendable, Identifiable {
        /// agy's id: `gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`.
        public var id: String
        /// agy's label: "Five Hour Limit Remaining".
        public var name: String
        /// agy's window: `5h` or `weekly`.
        public var window: String
        /// Share of the limit still left, 0...1; nil when agy sent none (a disabled bucket).
        public var remainingFraction: Double?
        public var resetsAt: Date?
        /// agy marks a bucket the account cannot use as disabled.
        public var disabled: Bool

        public init(id: String, name: String, window: String, remainingFraction: Double?, resetsAt: Date? = nil, disabled: Bool = false) {
            self.id = id
            self.name = name
            self.window = window
            self.remainingFraction = remainingFraction
            self.resetsAt = resetsAt
            self.disabled = disabled
        }

        /// The window in the names Claude's limits use, so both plans share the bars and the ring: `five_hour`,
        /// `seven_day`, else agy's own name.
        public var windowName: String {
            switch window.lowercased() {
            case "5h", "five_hour", "five-hour": "five_hour"
            case "weekly", "7d", "seven_day", "week": "seven_day"
            default: window
            }
        }

        /// Share used, 0...1.
        public var usedFraction: Double? { remainingFraction.map { 1 - min(max($0, 0), 1) } }

        public var isUsedUp: Bool { !disabled && (remainingFraction.map { $0 <= 0 } ?? false) }

        /// agy sends a reset time for every bucket; for one that is untouched it is just now plus the window, so it is
        /// only worth showing once something was used.
        public var showsReset: Bool { resetsAt != nil && (remainingFraction ?? 1) < 1 }
    }

    /// Models that share one five-hour and one weekly limit.
    public struct Group: Codable, Hashable, Sendable, Identifiable {
        /// "Gemini Models", "Claude and GPT models".
        public var name: String
        /// Display names from agy's description ("Models within this group: Gemini 4 Carbon, ...").
        public var models: [String]
        public var buckets: [Bucket]

        /// Buckets are kept five-hour first, then weekly (agy sends weekly first), like Claude's windows.
        public init(name: String, models: [String] = [], buckets: [Bucket]) {
            self.name = name
            self.models = models
            let order = ["five_hour", "seven_day"]
            self.buckets = buckets.enumerated().sorted { a, b in
                let left = (order.firstIndex(of: a.element.windowName) ?? order.count, a.offset)
                let right = (order.firstIndex(of: b.element.windowName) ?? order.count, b.offset)
                return left < right
            }.map(\.element)
        }

        public var id: String { name }

        /// "Gemini models", "Claude and GPT models".
        public var label: String {
            guard let first = name.first else { return name }
            return String(first) + name.dropFirst().replacingOccurrences(of: "Models", with: "models")
        }

        public var isLimited: Bool { buckets.contains(where: \.isUsedUp) }

        /// When a used-up limit resets (the latest, since all of them must reset before work goes on).
        public var limitedUntil: Date? { buckets.filter(\.isUsedUp).compactMap(\.resetsAt).max() }

        /// True for the group a model id belongs to (`gemini-4-carbon`, `claude-opus-4-6-thinking`).
        public func contains(modelID: String) -> Bool {
            let id = Self.slug(modelID)
            return models.contains { name in
                let slug = Self.slug(name)
                return !slug.isEmpty && (id == slug || id.hasPrefix(slug + "-"))
            }
        }

        /// "Gemini 3.8 Flash" and "gemini-3.8-flash" both become "gemini-3-8-flash".
        static func slug(_ text: String) -> String {
            let lowered = text.lowercased()
            var out = ""
            var lastDash = true
            for character in lowered {
                if character.isLetter || character.isNumber {
                    out.append(character)
                    lastDash = false
                } else if !lastDash {
                    out.append("-")
                    lastDash = true
                }
            }
            return out.hasSuffix("-") ? String(out.dropLast()) : out
        }
    }

    public var groups: [Group]
    /// When agy answered.
    public var updated: Date

    public init(groups: [Group], updated: Date = Date()) {
        self.groups = groups
        self.updated = updated
    }

    public var isLimited: Bool { groups.contains(where: \.isLimited) }

    /// The group a session's model counts against: the one that lists it, else the one named after the model's family
    /// ("claude-opus-5" in "Claude and GPT models"), else the Gemini group, else the first.
    public func group(forModel modelID: String?) -> Group? {
        if let modelID {
            if let match = groups.first(where: { $0.contains(modelID: modelID) }) { return match }
            if let family = Group.slug(modelID).split(separator: "-").first,
               let named = groups.first(where: { Group.slug($0.name).split(separator: "-").contains(family) }) {
                return named
            }
        }
        return groups.first { $0.name.lowercased().hasPrefix("gemini") } ?? groups.first
    }

    // MARK: Decoding agy's answer

    /// What came back from `agy -p "/usage"`.
    public enum Answer: Equatable, Sendable {
        case usage(AntigravityPlanUsage)
        /// agy answered with a model turn or without a `usage` command result: this agy has no `/usage` command.
        case notACommand
        /// Nothing usable (an error, empty output, or output that is not agy's).
        case unreadable
    }

    /// Reads `agy -p "/usage" --output-format json` (one object) or `--output-format stream-json` (one event per line).
    public static func decode(_ output: String, now: Date = Date()) -> Answer {
        var sawTurn = false
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let json = JSONValue.acpParse(line: String(line)) else { continue }
            // stream-json: `{"event": "command_result", "command": {...}}` and `{"event": "result", "result": {...}}`.
            let result = json["event"]?.stringValue == "result" ? (json["result"] ?? json) : json
            if let turns = result["num_turns"]?.acpInt, turns > 0 { sawTurn = true }
            if let conversation = result["conversation_id"]?.stringValue, !conversation.isEmpty { sawTurn = true }
            if let command = result["command"], command["name"]?.stringValue == "usage", let data = command["data"] {
                if let usage = decode(commandData: data, now: now) { return .usage(usage) }
            }
            if let text = result["response"]?.stringValue, result["command"]?["name"]?.stringValue == "usage",
               let usage = decode(table: text, now: now) {
                return .usage(usage)
            }
        }
        if sawTurn { return .notACommand }
        if let usage = decode(table: output, now: now) { return .usage(usage) }
        return output.contains("{") && output.contains("\"status\"") ? .notACommand : .unreadable
    }

    /// `command.data` of the `usage` command: `{"groups": [{"name", "description", "buckets": [...]}]}`.
    static func decode(commandData data: JSONValue, now: Date) -> AntigravityPlanUsage? {
        guard let groupValues = data["groups"]?.arrayValue else { return nil }
        let groups: [Group] = groupValues.compactMap { value in
            guard let name = value["name"]?.acpText else { return nil }
            let buckets: [Bucket] = (value["buckets"]?.arrayValue ?? []).compactMap { bucket in
                guard let window = bucket["window"]?.acpText ?? bucket["id"]?.acpText else { return nil }
                let status = bucket["status"]?.stringValue?.lowercased()
                let disabled = bucket["disabled"]?.acpBool == true || status == "disabled"
                return Bucket(id: bucket["id"]?.acpText ?? window, name: bucket["name"]?.stringValue ?? window, window: window,
                              remainingFraction: bucket["remaining_fraction"]?.doubleValue,
                              resetsAt: bucket["reset_time"]?.stringValue.flatMap(parseDate), disabled: disabled)
            }
            return Group(name: name, models: models(in: value["description"]?.stringValue), buckets: buckets)
        }
        guard !groups.isEmpty else { return nil }
        return AntigravityPlanUsage(groups: groups, updated: now)
    }

    /// The plain answer: `Gemini Models<TAB>Five Hour Limit Remaining<TAB>98%<TAB>2026-11-18T18:20:35Z` per line.
    static func decode(table text: String, now: Date) -> AntigravityPlanUsage? {
        var names: [String] = []
        var buckets: [String: [Bucket]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, cells[2].hasSuffix("%"), let percent = Double(cells[2].dropLast()) else { continue }
            let label = cells[1]
            let lower = label.lowercased()
            let window = lower.contains("five") || lower.contains("5") ? "5h" : (lower.contains("week") ? "weekly" : label)
            let bucket = Bucket(id: window, name: label, window: window, remainingFraction: percent / 100,
                                resetsAt: cells.count > 3 ? parseDate(cells[3]) : nil)
            if buckets[cells[0]] == nil { names.append(cells[0]) }
            buckets[cells[0], default: []].append(bucket)
        }
        let groups = names.map { Group(name: $0, buckets: buckets[$0] ?? []) }
        return groups.isEmpty ? nil : AntigravityPlanUsage(groups: groups, updated: now)
    }

    /// "Models within this group: Gemini 4 Carbon, Gemini 4 Argon, Orchestrator (Carbon)" to the names.
    static func models(in description: String?) -> [String] {
        guard let description, let colon = description.firstIndex(of: ":") else { return [] }
        var names: [String] = []
        var current = ""
        var depth = 0
        for character in description[description.index(after: colon)...] {
            switch character {
            case "(": depth += 1; current.append(character)
            case ")": depth = max(0, depth - 1); current.append(character)
            case "," where depth == 0:
                names.append(current)
                current = ""
            default: current.append(character)
            }
        }
        names.append(current)
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) }.filter { !$0.isEmpty }
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: trimmed)
    }
}

/// A turn that agy ended on a plan limit.
public struct AntigravityLimitHit: Codable, Hashable, Sendable {
    /// agy's message.
    public var message: String
    /// When agy said the limit resets, if it did.
    public var resetsAt: Date?
    /// When the turn failed.
    public var date: Date
    public var sessionID: String?

    public init(message: String, resetsAt: Date? = nil, date: Date = Date(), sessionID: String? = nil) {
        self.message = message
        self.resetsAt = resetsAt
        self.date = date
        self.sessionID = sessionID
    }
}

/// Tells agy's plan limit errors from other failures, and reads the reset time when the text has one.
public enum AntigravityLimitText {
    /// True for agy's quota errors: the wording of agy's own quota check (`RESOURCE_EXHAUSTED`, 429, "exhausted your
    /// capacity", "quota"), "individual quota reached", "out of quota", and "Your AI credits balance is too low to
    /// continue." (the plan is used up and credits cannot cover more). Overloaded servers (`MODEL_CAPACITY_EXHAUSTED`),
    /// context window limits, short rate limits that agy retries itself and disk quotas do not count.
    public static func isLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        for excluded in ["model_capacity_exhausted", "model capacity", "context window", "context limit", "disc quota", "disk quota",
                         "storage quota"] where lower.contains(excluded) {
            return false
        }
        if lower.contains("resource_exhausted") || lower.contains("exhausted your capacity") || lower.contains("credits balance is too low") {
            return true
        }
        if lower.contains("quota") {
            for word in ["reached", "exceeded", "exhausted", "used up", "out of", "reset", "limit"] where lower.contains(word) { return true }
        }
        if lower.contains("429"), lower.contains("limit") || lower.contains("quota") { return true }
        if lower.contains("limit reached") || (lower.contains("reached your") && lower.contains("limit")) { return true }
        return false
    }

    /// The limit hit in a failed turn's message, or nil when the message is not a plan limit.
    public static func hit(in text: String, sessionID: String? = nil, now: Date = Date()) -> AntigravityLimitHit? {
        guard isLimit(text) else { return nil }
        return AntigravityLimitHit(message: text, resetsAt: resetDate(in: text, now: now), date: now, sessionID: sessionID)
    }

    /// A reset time in the text: an ISO 8601 time ("until 2026-11-18T18:20:35Z"), or a wait ("reset after 2h34m50s",
    /// "resets in 3 hours, 5 minutes", "retry in 45s").
    public static func resetDate(in text: String, now: Date = Date()) -> Date? {
        if let iso = text.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})"#, options: .regularExpression),
           let date = AntigravityPlanUsage.parseDate(String(text[iso])) {
            return date
        }
        let lower = text.lowercased()
        for marker in ["reset after", "resets after", "reset in", "resets in", "refresh in", "available in", "retry in", "try again in"] {
            guard let range = lower.range(of: marker) else { continue }
            if let seconds = duration(in: String(lower[range.upperBound...])), seconds > 0 { return now.addingTimeInterval(seconds) }
        }
        return nil
    }

    /// "2h34m50s", "3 hours, 5 minutes", "45s" at the start of the text, in seconds.
    static func duration(in text: String) -> TimeInterval? {
        let unit = #"(d|days?|h|hrs?|hours?|m|mins?|minutes?|s|secs?|seconds?)(?![a-z])"#
        let pattern = #"^\s*((\d+(\.\d+)?)\s*"# + unit + #"(\s*,?\s*(and\s+)?)?)+"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let part = String(text[match])
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*"# + unit) else { return nil }
        var total: TimeInterval = 0
        for found in regex.matches(in: part, range: NSRange(part.startIndex..., in: part)) {
            guard let numberRange = Range(found.range(at: 1), in: part), let unitRange = Range(found.range(at: 2), in: part),
                  let number = Double(part[numberRange]) else { continue }
            let name = part[unitRange]
            let scale: TimeInterval = name.hasPrefix("d") ? 86_400 : name.hasPrefix("h") ? 3600 : name.hasPrefix("m") ? 60 : 1
            total += number * scale
        }
        return total > 0 ? total : nil
    }
}

extension PlanLimitMeter {
    /// One Google AI plan group (five-hour and weekly) in the shape of Claude's meter, so the ring, the label and the
    /// tooltip work the same. A used-up bucket counts as rejected; `limitHit` marks the plan limited even when `/usage`
    /// has not caught up yet.
    public init(antigravity group: AntigravityPlanUsage.Group, limitHit: AntigravityLimitHit? = nil) {
        let windows = group.buckets.filter { !$0.disabled && $0.remainingFraction != nil }.map { bucket in
            Window(name: bucket.windowName, utilization: bucket.usedFraction ?? 0, resetsAt: bucket.resetsAt,
                   status: bucket.isUsedUp ? "rejected" : nil)
        }
        self.init(windows: windows, isLimited: group.isLimited || limitHit != nil)
    }
}

/// What Ensemble knows about the Google AI plan: agy's `/usage` answer, why there is none, and the newest turn that
/// stopped on a plan limit.
public struct AntigravityPlanStatus: Hashable, Sendable {
    public enum Problem: String, Hashable, Sendable {
        /// This agy has no `/usage` command (it answered with a model turn, or with something else).
        case notReported
        /// agy did not answer: not signed in, offline, or too slow.
        case noAnswer
    }

    public var usage: AntigravityPlanUsage?
    public var problem: Problem?
    /// The newest turn that stopped on a plan limit, until a later reading or a successful turn shows the plan works.
    public var limitHit: AntigravityLimitHit?

    public init(usage: AntigravityPlanUsage? = nil, problem: Problem? = nil, limitHit: AntigravityLimitHit? = nil) {
        self.usage = usage
        self.problem = problem
        self.limitHit = limitHit
    }

    public var isLimited: Bool { usage?.isLimited == true || limitHit != nil }

    /// The status line's meter for a session on `modelID`: its group's five-hour and weekly limits. With no reading,
    /// an empty meter (the ring without arcs) that is red when a turn stopped on a limit.
    public func meter(forModel modelID: String?) -> PlanLimitMeter {
        guard let group = usage?.group(forModel: modelID) else { return PlanLimitMeter(windows: [], isLimited: limitHit != nil) }
        return PlanLimitMeter(antigravity: group, limitHit: limitHit)
    }

    /// Drops a limit hit that a later reading shows has lifted (nothing used up after the hit), or whose reset has passed.
    public func settled(now: Date = Date()) -> AntigravityPlanStatus {
        var copy = self
        if let hit = copy.limitHit {
            if let reset = hit.resetsAt, reset <= now { copy.limitHit = nil }
            if let usage = copy.usage, usage.updated > hit.date, !usage.isLimited { copy.limitHit = nil }
        }
        return copy
    }
}
