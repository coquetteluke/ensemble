import Foundation

/// A subagent, background command or task that has ended, as the Background list's Finished group shows it.
public struct FinishedBackgroundItem: Identifiable, Hashable, Sendable {
    public var item: BackgroundWorkItem
    public var finished: Date
    /// How long it ran, when its start is known.
    public var duration: TimeInterval?

    public var id: String { item.id + "@" + String(finished.timeIntervalSince1970) }

    public init(item: BackgroundWorkItem, finished: Date) {
        self.item = item
        self.finished = finished
        self.duration = item.started.map { max(0, finished.timeIntervalSince($0)) }
    }
}

/// Remembers background work that ended while the app was open. The engines only report what runs now, so this
/// watches that list: a row that was running and is gone has finished. Kept in memory, newest first, up to `limit`.
public struct BackgroundHistory: Equatable, Sendable {
    public private(set) var finished: [FinishedBackgroundItem] = []
    private var running: [String: BackgroundWorkItem] = [:]
    public var limit: Int

    public init(limit: Int = 30) {
        self.limit = limit
    }

    /// Takes the rows running now. Rows seen before that are missing have finished at `date`. Schedules only wait
    /// for their next run, so they are never tracked. Returns true when the Finished group changed.
    @discardableResult
    public mutating func update(running now: [BackgroundWorkItem], at date: Date = Date()) -> Bool {
        let current = Dictionary(now.filter(\.isRunning).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ended = running.values.filter { current[$0.id] == nil }
            .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        running = current
        guard !ended.isEmpty else { return false }
        finished = Array((ended.map { FinishedBackgroundItem(item: $0, finished: date) } + finished).prefix(limit))
        return true
    }

    /// Finished rows that belong to one top-level session.
    public func finished(forSession rootSessionID: String) -> [FinishedBackgroundItem] {
        finished.filter { $0.item.rootSessionID == rootSessionID }
    }

    /// Empties the Finished group; what still runs is kept.
    public mutating func clearFinished() {
        finished.removeAll()
    }

    /// "42s", "3m 05s", "1h 12m": how long a finished row ran.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m " + String(format: "%02ds", total % 60) }
        return "\(total / 3600)h " + String(format: "%02dm", (total % 3600) / 60)
    }
}
