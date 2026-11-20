import Foundation

/// A project folder chip shown in the Session Hub filter bar.
public struct HubProjectOption: Equatable, Hashable, Identifiable, Sendable {
    public var directory: String
    public var label: String
    public var count: Int
    public var needsYouCount: Int

    public var id: String { directory }

    public init(directory: String, label: String, count: Int, needsYouCount: Int) {
        self.directory = directory
        self.label = label
        self.count = count
        self.needsYouCount = needsYouCount
    }
}

/// One Hub entry distilled down to the fields needed for project pill extraction.
public struct HubProjectEntry: Sendable {
    public var directory: String
    public var lastActivity: Date
    public var needsYou: Bool

    public init(directory: String, lastActivity: Date, needsYou: Bool) {
        self.directory = directory
        self.lastActivity = lastActivity
        self.needsYou = needsYou
    }
}

/// Shared search and project-folder triage filter for Mac and iPhone Duo Session Hub.
public struct HubFilter: Equatable, Sendable {
    public var query: String
    public var selectedDirectory: String?
    public var onlyNeedsYou: Bool

    public init(query: String = "", selectedDirectory: String? = nil, onlyNeedsYou: Bool = false) {
        self.query = query
        self.selectedDirectory = selectedDirectory
        self.onlyNeedsYou = onlyNeedsYou
    }

    public var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedDirectory != nil
            || onlyNeedsYou
    }

    public mutating func clear() {
        query = ""
        selectedDirectory = nil
        onlyNeedsYou = false
    }

    /// Normalizes a folder path by trimming trailing slashes (except root "/").
    public static func normalizedDirectory(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "/" { return "/" }
        var result = trimmed
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Builds deduplicated project filter chips, disambiguating duplicate folder names with their parent name.
    public static func projects(from entries: [HubProjectEntry]) -> [HubProjectOption] {
        struct Aggregate {
            var count: Int
            var needsYouCount: Int
            var latest: Date
        }
        var grouped: [String: Aggregate] = [:]
        for entry in entries {
            let dir = normalizedDirectory(entry.directory)
            guard !dir.isEmpty else { continue }
            if var existing = grouped[dir] {
                existing.count += 1
                if entry.needsYou { existing.needsYouCount += 1 }
                if entry.lastActivity > existing.latest { existing.latest = entry.lastActivity }
                grouped[dir] = existing
            } else {
                grouped[dir] = Aggregate(count: 1, needsYouCount: entry.needsYou ? 1 : 0, latest: entry.lastActivity)
            }
        }

        // Count basenames so two different folders named "app" show "parent/app".
        var basenameCounts: [String: Int] = [:]
        for dir in grouped.keys {
            let base = URL(fileURLWithPath: dir).lastPathComponent
            basenameCounts[base, default: 0] += 1
        }

        let sortedDirs = grouped.keys.sorted { lhs, rhs in
            let a = grouped[lhs]!
            let b = grouped[rhs]!
            if (a.needsYouCount > 0) != (b.needsYouCount > 0) {
                return a.needsYouCount > 0
            }
            if a.latest != b.latest {
                return a.latest > b.latest
            }
            return lhs < rhs
        }

        return sortedDirs.map { dir in
            let agg = grouped[dir]!
            let url = URL(fileURLWithPath: dir)
            let base = url.lastPathComponent.isEmpty ? dir : url.lastPathComponent
            let label: String
            if (basenameCounts[base] ?? 0) > 1 {
                let parent = url.deletingLastPathComponent().lastPathComponent
                label = parent.isEmpty || parent == "/" ? base : "\(parent)/\(base)"
            } else {
                label = base
            }
            return HubProjectOption(
                directory: dir,
                label: label,
                count: agg.count,
                needsYouCount: agg.needsYouCount
            )
        }
    }

    /// Extracts project chips from iPhone Duo `SessionSummary` rows (excluding items hidden from the board).
    public static func projects(from summaries: [SessionSummary], now: Date = Date()) -> [HubProjectOption] {
        let entries: [HubProjectEntry] = summaries.compactMap { summary in
            guard let bucket = HubBoard.bucket(for: summary, now: now) else { return nil }
            return HubProjectEntry(
                directory: summary.directory,
                lastActivity: summary.lastActivity,
                needsYou: bucket == .needsYou
            )
        }
        return projects(from: entries)
    }

    /// Tests whether a single session or room card matches the active filter.
    public func matches(
        title: String,
        directory: String,
        pendingAsk: String? = nil,
        agentNames: [String] = [],
        bucket: HubBucket
    ) -> Bool {
        if onlyNeedsYou && bucket != .needsYou {
            return false
        }
        if let selectedDirectory {
            if Self.normalizedDirectory(directory) != Self.normalizedDirectory(selectedDirectory) {
                return false
            }
        }
        let terms = TranscriptFinder.terms(for: query)
        guard !terms.isEmpty else { return true }

        var parts = [title, directory]
        if let pendingAsk, !pendingAsk.isEmpty {
            parts.append(pendingAsk)
        }
        parts.append(contentsOf: agentNames)
        let haystack = parts.joined(separator: "\n")
        for term in terms {
            if haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return true
    }

    /// Filters remote `SessionSummary` lists for iPhone Duo Session Hub.
    public func filter(_ summaries: [SessionSummary], now: Date = Date()) -> [SessionSummary] {
        guard isActive else { return summaries }
        return summaries.filter { summary in
            guard let bucket = HubBoard.bucket(for: summary, now: now) else { return false }
            return matches(
                title: summary.title,
                directory: summary.directory,
                pendingAsk: summary.pendingAsk,
                agentNames: summary.agentNames,
                bucket: bucket
            )
        }
    }

    /// Returns IDs of finished non-room sessions that are safe for one-tap "Archive finished".
    public static func archivableFinishedSessionIDs(from summaries: [SessionSummary], now: Date = Date()) -> [String] {
        summaries.compactMap { summary in
            guard summary.roomID == nil,
                  !summary.archived,
                  HubBoard.bucket(for: summary, now: now) == .finished else {
                return nil
            }
            return summary.id
        }
    }
}
