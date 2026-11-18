import Foundation

// Usage over time. Engines report each session's usage as a running total, with no dates, so Ensemble keeps its own
// ledger: what each session added on each day. While Ensemble runs, growth is counted on the day it is seen. Growth
// that happened while Ensemble was closed (and sessions seen for the first time) is counted on the session's last
// activity day, the best date there is. Saved in `~/Library/Application Support/Ensemble/usage.json`.

/// The periods the Usage view shows.
public enum UsageRange: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case today
    case week
    case month

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    public var label: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }
}

/// What one session added on one day.
public struct UsageEntry: Codable, Hashable, Sendable {
    /// `yyyy-MM-dd` in the local calendar.
    public var day: String
    public var sessionID: String
    /// The top-level session (a subagent's parent), so subagents count toward their session.
    public var rootSessionID: String
    /// The top-level session's title.
    public var title: String
    public var directory: String
    public var providerID: String
    public var modelID: String
    /// The room agent's name, or the model's name for a plain session.
    public var agentName: String
    public var usage: Usage

    public init(day: String, sessionID: String, rootSessionID: String, title: String, directory: String, providerID: String,
                modelID: String, agentName: String, usage: Usage) {
        self.day = day
        self.sessionID = sessionID
        self.rootSessionID = rootSessionID
        self.title = title
        self.directory = directory
        self.providerID = providerID
        self.modelID = modelID
        self.agentName = agentName
        self.usage = usage
    }
}

/// One session's running total, as the store has it now.
public struct UsageSample: Hashable, Sendable {
    public var sessionID: String
    public var rootSessionID: String
    public var title: String
    public var directory: String
    public var providerID: String
    public var modelID: String
    public var agentName: String
    public var total: Usage
    /// The session's last activity (for growth that happened while Ensemble was closed).
    public var updated: Date

    public init(sessionID: String, rootSessionID: String, title: String, directory: String, providerID: String, modelID: String,
                agentName: String, total: Usage, updated: Date) {
        self.sessionID = sessionID
        self.rootSessionID = rootSessionID
        self.title = title
        self.directory = directory
        self.providerID = providerID
        self.modelID = modelID
        self.agentName = agentName
        self.total = total
        self.updated = updated
    }
}

public struct UsageLedger: Codable, Equatable, Sendable {
    public var entries: [UsageEntry]
    /// Each session's running total already counted.
    public var counted: [String: Usage]

    public init(entries: [UsageEntry] = [], counted: [String: Usage] = [:]) {
        self.entries = entries
        self.counted = counted
    }

    // MARK: Days

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 0, month = c.month ?? 0, day = c.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Today and the days before it, newest first.
    public static func dayKeys(_ range: UsageRange, now: Date, calendar: Calendar) -> [String] {
        let today = calendar.startOfDay(for: now)
        return (0..<range.days).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayKey($0, calendar: calendar) }
        }
    }

    // MARK: Recording

    /// Counts what the session added since it was last counted, on `day`. A total that went down (a reverted turn, a
    /// restarted engine process) becomes the new starting point and adds nothing. Returns true when the ledger changed.
    @discardableResult
    public mutating func record(_ sample: UsageSample, day: String) -> Bool {
        let previous = counted[sample.sessionID]
        guard previous != sample.total else { return false }
        counted[sample.sessionID] = sample.total
        let added = previous.map { Self.growth(from: $0, to: sample.total) } ?? sample.total
        guard added != .zero else { return true }
        if let index = entries.firstIndex(where: { $0.day == day && $0.sessionID == sample.sessionID }) {
            entries[index].usage = entries[index].usage + added
            entries[index].title = sample.title
            entries[index].agentName = sample.agentName
            entries[index].providerID = sample.providerID
            entries[index].modelID = sample.modelID
        } else {
            entries.append(UsageEntry(day: day, sessionID: sample.sessionID, rootSessionID: sample.rootSessionID, title: sample.title,
                                      directory: sample.directory, providerID: sample.providerID, modelID: sample.modelID,
                                      agentName: sample.agentName, usage: added))
        }
        return true
    }

    /// What `new` adds over `old`, field by field; a field that went down adds nothing.
    static func growth(from old: Usage, to new: Usage) -> Usage {
        Usage(inputTokens: max(0, new.inputTokens - old.inputTokens),
              outputTokens: max(0, new.outputTokens - old.outputTokens),
              reasoningTokens: max(0, new.reasoningTokens - old.reasoningTokens),
              cacheReadTokens: max(0, new.cacheReadTokens - old.cacheReadTokens),
              cacheWriteTokens: max(0, new.cacheWriteTokens - old.cacheWriteTokens),
              costUSD: max(0, new.costUSD - old.costUSD))
    }

    /// Drops entries before `day` (`yyyy-MM-dd`), and the running totals of sessions that are gone and have no entries
    /// left.
    public mutating func prune(before day: String, keepingSessions live: Set<String>) {
        entries.removeAll { $0.day < day }
        let withEntries = Set(entries.map(\.sessionID))
        counted = counted.filter { live.contains($0.key) || withEntries.contains($0.key) }
    }

    // MARK: Reading

    /// Cost added today by a provider's sessions.
    public func spent(providerID: String, day: String) -> Double {
        entries.reduce(0) { $0 + (($1.day == day && $1.providerID == providerID) ? $1.usage.costUSD : 0) }
    }

    /// Totals for `range`, grouped by provider, agent and session. `billing` says who pays for a model; costs count only
    /// for models billed to an API key. `providerName` names a provider id.
    public func report(_ range: UsageRange, now: Date, calendar: Calendar,
                       billing: (_ providerID: String, _ modelID: String) -> ModelBilling,
                       providerName: (String) -> String) -> UsageReport {
        let days = Set(Self.dayKeys(range, now: now, calendar: calendar))
        let selected = entries.filter { days.contains($0.day) }
        var total = UsageLine(id: "total", name: "Total")
        var providers: [String: UsageLine] = [:]
        var agents: [String: UsageLine] = [:]
        var sessions: [String: UsageLine] = [:]
        var agentProviders: [String: Set<String>] = [:]
        for entry in selected {
            let kind = billing(entry.providerID, entry.modelID)
            total.add(entry.usage, billing: kind)
            providers[entry.providerID, default: UsageLine(id: entry.providerID, name: providerName(entry.providerID))]
                .add(entry.usage, billing: kind)
            agents[entry.agentName, default: UsageLine(id: "agent:" + entry.agentName, name: entry.agentName)]
                .add(entry.usage, billing: kind)
            agentProviders[entry.agentName, default: []].insert(providerName(entry.providerID))
            var line = sessions[entry.rootSessionID] ?? UsageLine(id: entry.rootSessionID, name: entry.title,
                                                                  detail: Format.folderName(entry.directory))
            if entry.sessionID == entry.rootSessionID { line.name = entry.title }
            line.add(entry.usage, billing: kind)
            sessions[entry.rootSessionID] = line
        }
        // Each agent names the providers it used.
        for (name, used) in agentProviders { agents[name]?.detail = used.sorted().joined(separator: ", ") }
        return UsageReport(range: range, total: total, providers: UsageLine.sorted(providers.values),
                           agents: UsageLine.sorted(agents.values), sessions: UsageLine.sorted(sessions.values),
                           sessionCount: sessions.count)
    }
}

/// Usage for one period.
public struct UsageReport: Equatable, Sendable {
    public var range: UsageRange
    public var total: UsageLine
    public var providers: [UsageLine]
    public var agents: [UsageLine]
    public var sessions: [UsageLine]
    /// Top-level sessions that used anything.
    public var sessionCount: Int

    public init(range: UsageRange, total: UsageLine, providers: [UsageLine] = [], agents: [UsageLine] = [],
                sessions: [UsageLine] = [], sessionCount: Int = 0) {
        self.range = range
        self.total = total
        self.providers = providers
        self.agents = agents
        self.sessions = sessions
        self.sessionCount = sessionCount
    }
}

/// One row of the Usage view: a provider, an agent, a session or the total.
public struct UsageLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String?
    /// Every token, and the cost the engines reported (subscription runs included).
    public var usage: Usage = .zero
    /// The cost of the part billed to API keys: what the Usage view shows as cost.
    public var apiCostUSD: Double = 0
    /// Who paid for the usage in this row.
    public var billings: Set<ModelBilling> = []

    public init(id: String, name: String, detail: String? = nil, usage: Usage = .zero, apiCostUSD: Double = 0,
                billings: Set<ModelBilling> = []) {
        self.id = id
        self.name = name
        self.detail = detail
        self.usage = usage
        self.apiCostUSD = apiCostUSD
        self.billings = billings
    }

    mutating func add(_ usage: Usage, billing: ModelBilling) {
        self.usage = self.usage + usage
        billings.insert(billing)
        if billing == .apiKey { apiCostUSD += usage.costUSD }
    }

    /// Input, output and reasoning tokens (cache reads and writes are listed apart).
    public var tokens: Int { usage.inputTokens + usage.outputTokens + usage.reasoningTokens }

    /// True when some of the row is billed to an API key, so a cost is shown.
    public var hasAPICost: Bool { billings.contains(.apiKey) }

    /// What pays when nothing is billed to an API key: "Plan", "Free", "This Mac".
    public var billingLabel: String {
        if billings.contains(.apiKey) { return "API key" }
        if billings.contains(.subscription) { return "Plan" }
        if billings.contains(.free) { return "Free" }
        if billings.contains(.local) { return "This Mac" }
        return ""
    }

    /// Most expensive first, then most tokens.
    static func sorted<S: Sequence>(_ lines: S) -> [UsageLine] where S.Element == UsageLine {
        lines.sorted { a, b in
            if a.apiCostUSD != b.apiCostUSD { return a.apiCostUSD > b.apiCostUSD }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return a.name < b.name
        }
    }
}
