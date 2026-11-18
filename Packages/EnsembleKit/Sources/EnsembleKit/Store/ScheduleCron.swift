import Foundation

/// A five-field cron expression (`minute hour day-of-month month day-of-week`), the custom trigger of a scheduled task.
///
/// Fields take `*`, numbers, ranges (`1-5`), lists (`1,15`), steps (`*/15`, `0-30/10`, `5/20`) and names (`MON`, `JAN`,
/// any case). Day of week runs 0 to 7 (0 and 7 are Sunday). The macros `@hourly`, `@daily` (`@midnight`), `@weekly`,
/// `@monthly` and `@yearly` (`@annually`) are accepted.
///
/// Matching follows Vixie cron: when both day fields are restricted (neither starts with `*`), a day matches if either
/// matches; otherwise it must match both (so `*` leaves the decision to the other field).
///
/// Daylight saving time, also as in Vixie cron:
/// - A time that does not exist because the clocks went forward runs at the moment after the jump (2:30 runs at 3:00),
///   for expressions with a fixed hour. Expressions whose hour field starts with `*` simply carry on after the jump.
/// - A time that happens twice because the clocks went back runs once, the first time, for expressions with a fixed
///   hour. Expressions whose hour field starts with `*` run in both hours.
public struct CronExpression: Hashable, Sendable, CustomStringConvertible {
    /// The text as written (trimmed).
    public let source: String
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    /// 0 is Sunday, 6 is Saturday.
    public let daysOfWeek: Set<Int>
    let dayOfMonthStar: Bool
    let dayOfWeekStar: Bool
    let hourStar: Bool

    /// The longest search for the next time. Eight years covers every February 29 (1896 to 1904 is the longest gap).
    static let searchLimit: TimeInterval = 8 * 366 * 86_400

    public var description: String { source }

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CronParseError.empty }
        source = trimmed
        var fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if fields.count == 1, let macro = fields.first, macro.hasPrefix("@") {
            guard let expanded = Self.macros[macro.lowercased()] else { throw CronParseError.unsupportedMacro(macro) }
            fields = expanded.split(separator: " ").map(String.init)
        }
        guard fields.count == 5 else { throw CronParseError.fieldCount(fields.count) }
        minutes = try Self.parseField(fields[0], field: .minute)
        hours = try Self.parseField(fields[1], field: .hour)
        daysOfMonth = try Self.parseField(fields[2], field: .dayOfMonth)
        months = try Self.parseField(fields[3], field: .month)
        daysOfWeek = Set(try Self.parseField(fields[4], field: .dayOfWeek).map { $0 == 7 ? 0 : $0 })
        hourStar = fields[1].hasPrefix("*")
        dayOfMonthStar = fields[2].hasPrefix("*")
        dayOfWeekStar = fields[4].hasPrefix("*")
    }

    static let macros: [String: String] = [
        "@hourly": "0 * * * *",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *",
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
    ]

    // MARK: Matching

    /// True when `date` (to the minute) is one of the expression's times, ignoring the daylight saving rules.
    public func matches(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
        guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let weekday = c.weekday else {
            return false
        }
        return months.contains(month) && dayMatches(day: day, weekday: weekday - 1) && hours.contains(hour)
            && minutes.contains(minute)
    }

    func dayMatches(day: Int, weekday: Int) -> Bool {
        let domOK = daysOfMonth.contains(day)
        let dowOK = daysOfWeek.contains(weekday)
        return (dayOfMonthStar || dayOfWeekStar) ? (domOK && dowOK) : (domOK || dowOK)
    }

    // MARK: Next time

    /// The first time strictly after `date`, or nil when there is none within eight years (February 30, say).
    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        var transitions = TransitionCursor(timeZone: calendar.timeZone, start: date)
        guard var t = calendar.dateInterval(of: .minute, for: date)?.end else { return nil }
        if let gap = gapFire(from: date, to: t, calendar: calendar, transitions: &transitions) { return gap }
        let limit = date.addingTimeInterval(Self.searchLimit)
        var steps = 0
        while t <= limit && steps < 200_000 {
            steps += 1
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: t)
            guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let weekday = c.weekday else {
                return nil
            }
            let next: Date?
            if !months.contains(month) {
                next = calendar.dateInterval(of: .month, for: t)?.end
            } else if !dayMatches(day: day, weekday: weekday - 1) {
                next = calendar.dateInterval(of: .day, for: t)?.end
            } else if !hours.contains(hour) {
                next = calendar.dateInterval(of: .hour, for: t)?.end
            } else if !minutes.contains(minute) {
                if let later = minutes.filter({ $0 > minute }).min() {
                    next = t.addingTimeInterval(TimeInterval((later - minute) * 60))
                } else {
                    next = calendar.dateInterval(of: .hour, for: t)?.end
                }
            } else if !hourStar && isSecondOccurrence(t, timeZone: calendar.timeZone) {
                next = calendar.dateInterval(of: .minute, for: t)?.end
            } else {
                return t
            }
            guard let next, next > t else { return nil }
            if let gap = gapFire(from: t, to: next, calendar: calendar, transitions: &transitions) { return gap }
            t = next
        }
        return nil
    }

    /// The next `count` times after `date`.
    public func nextFires(after date: Date, count: Int, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = date
        while result.count < count, let next = nextFire(after: cursor, calendar: calendar) {
            result.append(next)
            cursor = next
        }
        return result
    }

    // MARK: Daylight saving

    /// Walks the time zone's transitions forward as the search moves on.
    struct TransitionCursor {
        let timeZone: TimeZone
        var next: Date?

        init(timeZone: TimeZone, start: Date) {
            self.timeZone = timeZone
            next = timeZone.nextDaylightSavingTimeTransition(after: start)
        }

        /// The transition in `(from, to]`, if any. Moves past transitions at or before `to`.
        mutating func transition(in from: Date, _ to: Date) -> Date? {
            var found: Date?
            while let candidate = next, candidate <= to {
                if candidate > from { found = candidate }
                next = timeZone.nextDaylightSavingTimeTransition(after: candidate)
            }
            return found
        }
    }

    /// When the clocks jump forward inside `(from, to]` and a fixed-hour time of this expression falls in the skipped
    /// wall-clock stretch on a matching day, the moment of the jump.
    func gapFire(from: Date, to: Date, calendar: Calendar, transitions: inout TransitionCursor) -> Date? {
        guard let transition = transitions.transition(in: from, to) else { return nil }
        guard !hourStar else { return nil }
        let zone = calendar.timeZone
        let jump = zone.secondsFromGMT(for: transition) - zone.secondsFromGMT(for: transition.addingTimeInterval(-1))
        guard jump > 0 else { return nil }
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: transition)
        guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let weekday = c.weekday,
              months.contains(month), dayMatches(day: day, weekday: weekday - 1) else { return nil }
        // The skipped wall times are [after - jump, after) in minutes of the day.
        let after = hour * 60 + minute
        let start = after - jump / 60
        for wall in max(start, 0)..<after where hours.contains(wall / 60) && minutes.contains(wall % 60) {
            return transition
        }
        return nil
    }

    /// True when `date` is the second time its wall-clock time happens because the clocks went back.
    func isSecondOccurrence(_ date: Date, timeZone zone: TimeZone) -> Bool {
        guard let transition = zone.nextDaylightSavingTimeTransition(after: date.addingTimeInterval(-6 * 3600)),
              transition <= date else { return false }
        let drop = zone.secondsFromGMT(for: transition.addingTimeInterval(-1)) - zone.secondsFromGMT(for: transition)
        guard drop > 0 else { return false }
        return date < transition.addingTimeInterval(TimeInterval(drop))
    }

    // MARK: Parsing

    enum Field {
        case minute, hour, dayOfMonth, month, dayOfWeek

        var name: String {
            switch self {
            case .minute: "minute"
            case .hour: "hour"
            case .dayOfMonth: "day of month"
            case .month: "month"
            case .dayOfWeek: "day of week"
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .minute: 0...59
            case .hour: 0...23
            case .dayOfMonth: 1...31
            case .month: 1...12
            case .dayOfWeek: 0...7
            }
        }

        var names: [String: Int] {
            switch self {
            case .month:
                ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
            case .dayOfWeek:
                ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
            default:
                [:]
            }
        }
    }

    static func parseField(_ text: String, field: Field) throws -> Set<Int> {
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !part.isEmpty else { throw CronParseError.invalid(field: field.name, value: text) }
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2 else { throw CronParseError.invalid(field: field.name, value: part) }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed >= 1 else { throw CronParseError.invalid(field: field.name, value: part) }
                step = parsed
            }
            let base = pieces[0]
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = field.range.lowerBound
                upper = field.range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                lower = try value(String(base[..<dash]), field: field)
                upper = try value(String(base[base.index(after: dash)...]), field: field)
                guard lower <= upper else { throw CronParseError.invalid(field: field.name, value: part) }
            } else {
                lower = try value(base, field: field)
                upper = pieces.count == 2 ? field.range.upperBound : lower
            }
            for number in stride(from: lower, through: upper, by: step) { values.insert(number) }
        }
        return values
    }

    static func value(_ text: String, field: Field) throws -> Int {
        let number: Int
        if let parsed = Int(text) {
            number = parsed
        } else if let named = field.names[text.lowercased()] {
            number = named
        } else {
            throw CronParseError.invalid(field: field.name, value: text)
        }
        guard field.range.contains(number) else {
            throw CronParseError.outOfRange(field: field.name, value: number, range: field.range)
        }
        return number
    }
}

/// Why a cron expression could not be read.
public enum CronParseError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case fieldCount(Int)
    case invalid(field: String, value: String)
    case outOfRange(field: String, value: Int, range: ClosedRange<Int>)
    case unsupportedMacro(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a cron expression."
        case .fieldCount(let count):
            "A cron expression has 5 fields (minute, hour, day of month, month, day of week); this one has \(count)."
        case .invalid(let field, let value):
            "\u{201C}\(value)\u{201D} is not a valid \(field)."
        case .outOfRange(let field, let value, let range):
            "\(value) is not a valid \(field). Use \(range.lowerBound) to \(range.upperBound)."
        case .unsupportedMacro(let macro):
            "\(macro) is not supported. Use @hourly, @daily, @weekly, @monthly or @yearly."
        }
    }
}
