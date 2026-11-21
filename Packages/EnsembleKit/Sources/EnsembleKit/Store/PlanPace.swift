import Foundation

/// Whether a plan limit will be used up before it resets, at the rate it has been used so far in its window.
/// Shown as one line under the limit's bar, so a long session does not hit the limit by surprise.
public struct PlanPace: Equatable, Sendable {
    /// When the window reaches 100% if use continues at the same rate.
    public var runsOutAt: Date
    /// How long before the reset that is.
    public var shortBy: TimeInterval

    public init(runsOutAt: Date, shortBy: TimeInterval) {
        self.runsOutAt = runsOutAt
        self.shortBy = shortBy
    }

    /// How long a named window lasts: five hours, or seven days for the weekly ones. Nil for names not known.
    public static func length(of windowName: String) -> TimeInterval? {
        if windowName == "five_hour" { return 5 * 3600 }
        if windowName.hasPrefix("seven_day") { return 7 * 24 * 3600 }
        return nil
    }

    /// The projection for one window, or nil when there is nothing to warn about: the window's length or reset
    /// time is not known, it is already used up, too little of the window has passed or been used to tell a rate
    /// (under a tenth of its time, or under a fifth of the limit), or the limit lasts until the reset (or falls
    /// short by less than a fiftieth of the window, which is noise).
    public static func project(windowName: String, utilization: Double, resetsAt: Date?, now: Date) -> PlanPace? {
        guard let length = length(of: windowName), let resetsAt, resetsAt > now else { return nil }
        guard utilization >= 0.2, utilization < 1 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-length))
        guard elapsed >= length * 0.1 else { return nil }
        let rate = utilization / elapsed
        let runsOutAt = now.addingTimeInterval((1 - utilization) / rate)
        let shortBy = resetsAt.timeIntervalSince(runsOutAt)
        guard shortBy >= length * 0.02 else { return nil }
        return PlanPace(runsOutAt: runsOutAt, shortBy: shortBy)
    }

    /// "25m", "3h 20m", "1d 17h": a duration in its two largest units, rounded to the minute.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let rest = hours % 24
        return rest == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(rest)h"
    }
}
