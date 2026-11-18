import Foundation

/// What a check decides for one task.
public enum ScheduleDecision: Equatable, Sendable {
    /// Nothing is due. `next` is the next time (nil when the trigger never runs).
    case wait(next: Date?)
    /// Run once now, for `slot`, the newest time that passed. `caughtUp` is true when that time passed more than
    /// `SchedulePlanner.onTimeGrace` ago (the Mac slept through it, or Ensemble was closed). `dropped` counts the older
    /// passed times that do not get their own run.
    case run(slot: Date, caughtUp: Bool, dropped: Int)
    /// Every time that passed is older than the catch-up window, so nothing runs. `slot` is the newest of them.
    case missed(slot: Date)
}

/// The catch-up rules, kept free of clocks and timers so they can be tested on their own.
///
/// - A time that passed within `onTimeGrace` runs as an ordinary run (timers fire a little late).
/// - Times that passed while the Mac slept or Ensemble was closed run once, for the newest of them, if it passed less
///   than the task's catch-up window ago (default 12 hours). The run is marked caught up.
/// - When every passed time is older than the window, nothing runs and the newest one is recorded as missed.
public enum SchedulePlanner {
    public static let onTimeGrace: TimeInterval = 5 * 60
    /// Bounds the walk over passed times (an every-minute cron missed for weeks).
    static let maxSteps = 5000

    public static func decide(trigger: ScheduleTrigger, checkedThrough: Date, now: Date, catchUpWindow: TimeInterval,
                              calendar: Calendar) -> ScheduleDecision {
        guard let expression = try? trigger.expression() else { return .wait(next: nil) }
        guard let first = expression.nextFire(after: checkedThrough, calendar: calendar) else { return .wait(next: nil) }
        guard first <= now else { return .wait(next: first) }

        // Times at or after `windowStart` may still run.
        let windowStart = now.addingTimeInterval(-max(catchUpWindow, onTimeGrace))
        var newest: Date?
        var count = 0
        var cursor: Date? = first >= windowStart ? first : expression.nextFire(after: windowStart.addingTimeInterval(-0.001),
                                                                                 calendar: calendar)
        while let slot = cursor, slot <= now, count < maxSteps {
            newest = slot
            count += 1
            cursor = expression.nextFire(after: slot, calendar: calendar)
        }

        guard let newest else {
            // Nothing inside the window: find the newest passed time for the history row.
            var latest = first
            var steps = 0
            while steps < maxSteps, let next = expression.nextFire(after: latest, calendar: calendar), next <= now {
                latest = next
                steps += 1
            }
            return .missed(slot: latest)
        }
        let olderDropped = first < windowStart ? 1 : 0
        return .run(slot: newest, caughtUp: now.timeIntervalSince(newest) > onTimeGrace, dropped: count - 1 + olderDropped)
    }
}
