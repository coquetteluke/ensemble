import Foundation

/// A day of the week, numbered as in cron (0 is Sunday).
public enum ScheduleWeekday: Int, Codable, CaseIterable, Hashable, Comparable, Sendable {
    case sunday = 0, monday, tuesday, wednesday, thursday, friday, saturday

    public static let workdays: Set<ScheduleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    public static func < (a: ScheduleWeekday, b: ScheduleWeekday) -> Bool { a.rawValue < b.rawValue }

    /// "Mon", in the calendar's language.
    public func shortName(_ calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols.indices.contains(rawValue) ? symbols[rawValue] : "\(rawValue)"
    }

    /// "Monday", in the calendar's language.
    public func name(_ calendar: Calendar) -> String {
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(rawValue) ? symbols[rawValue] : "\(rawValue)"
    }

    /// Every day in the calendar's week order (Monday first in most of Europe, Sunday first in the US).
    public static func ordered(_ calendar: Calendar) -> [ScheduleWeekday] {
        let first = max(0, min(6, calendar.firstWeekday - 1))
        return (0..<7).compactMap { ScheduleWeekday(rawValue: (first + $0) % 7) }
    }
}

/// When a scheduled task runs: the trigger card's choice.
public enum ScheduleTrigger: Hashable, Sendable {
    /// Every hour at `minute`.
    case hourly(minute: Int)
    /// Every day at a time.
    case daily(hour: Int, minute: Int)
    /// Monday to Friday at a time.
    case weekdays(hour: Int, minute: Int)
    /// The chosen days at a time.
    case weekly(days: Set<ScheduleWeekday>, hour: Int, minute: Int)
    /// A five-field cron expression.
    case custom(cron: String)

    public enum Kind: String, CaseIterable, Codable, Hashable, Sendable {
        case hourly, daily, weekdays, weekly, custom

        public var label: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            case .custom: "Custom"
            }
        }
    }

    public static let `default` = ScheduleTrigger.daily(hour: 9, minute: 0)

    public var kind: Kind {
        switch self {
        case .hourly: .hourly
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekly: .weekly
        case .custom: .custom
        }
    }

    /// The time of day, for the kinds that have one.
    public var timeOfDay: (hour: Int, minute: Int)? {
        switch self {
        case .daily(let hour, let minute), .weekdays(let hour, let minute), .weekly(_, let hour, let minute): (hour, minute)
        case .hourly, .custom: nil
        }
    }

    /// The same schedule as a cron expression.
    public var cronText: String {
        switch self {
        case .hourly(let minute):
            "\(minute) * * * *"
        case .daily(let hour, let minute):
            "\(minute) \(hour) * * *"
        case .weekdays(let hour, let minute):
            "\(minute) \(hour) * * 1-5"
        case .weekly(let days, let hour, let minute):
            "\(minute) \(hour) * * \(days.isEmpty ? "*" : days.sorted().map { String($0.rawValue) }.joined(separator: ","))"
        case .custom(let cron):
            cron.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func expression() throws -> CronExpression {
        if case .weekly(let days, _, _) = self, days.isEmpty { throw ScheduleTriggerError.noDays }
        if let time = timeOfDay, !(0...23).contains(time.hour) || !(0...59).contains(time.minute) {
            throw ScheduleTriggerError.badTime
        }
        if case .hourly(let minute) = self, !(0...59).contains(minute) { throw ScheduleTriggerError.badTime }
        return try CronExpression(cronText)
    }

    /// The first time strictly after `date`, or nil when the trigger is invalid or never runs.
    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        (try? expression())?.nextFire(after: date, calendar: calendar)
    }

    public func nextFires(after date: Date, count: Int, calendar: Calendar) -> [Date] {
        (try? expression())?.nextFires(after: date, count: count, calendar: calendar) ?? []
    }

    /// Why the trigger cannot be saved, or nil when it can.
    public func validationError(calendar: Calendar = .current, now: Date = Date()) -> String? {
        let parsed: CronExpression
        do {
            parsed = try expression()
        } catch {
            return error.localizedDescription
        }
        if parsed.nextFire(after: now, calendar: calendar) == nil { return "This schedule never matches a real date." }
        return nil
    }

    /// "Every day at 9:00 AM", "Weekdays at 9:00 AM", "Mon, Wed and Fri at 9:00 AM", "Every hour at :15".
    public func summary(calendar: Calendar = .current) -> String {
        switch self {
        case .hourly(let minute):
            return "Every hour at :" + Self.twoDigits(minute)
        case .daily(let hour, let minute):
            return "Every day at " + Self.time(hour: hour, minute: minute, calendar: calendar)
        case .weekdays(let hour, let minute):
            return "Weekdays at " + Self.time(hour: hour, minute: minute, calendar: calendar)
        case .weekly(let days, let hour, let minute):
            let time = Self.time(hour: hour, minute: minute, calendar: calendar)
            if days.count == 7 { return "Every day at " + time }
            if days == ScheduleWeekday.workdays { return "Weekdays at " + time }
            let ordered = ScheduleWeekday.ordered(calendar).filter { days.contains($0) }
            if ordered.count == 1, let day = ordered.first { return "Every \(day.name(calendar)) at " + time }
            if ordered.isEmpty { return "No days chosen" }
            return Self.list(ordered.map { $0.shortName(calendar) }) + " at " + time
        case .custom(let cron):
            return "Cron " + cron.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// "9:00 AM" or "09:00", as the calendar's locale writes times.
    public static func time(hour: Int, minute: Int, calendar: Calendar) -> String {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return "\(hour):\(twoDigits(minute))" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The same time of day in another kind, for the trigger card when the kind changes.
    public func converted(to kind: Kind, calendar: Calendar = .current) -> ScheduleTrigger {
        let time = timeOfDay ?? (9, hourlyMinute ?? 0)
        switch kind {
        case .hourly: return .hourly(minute: hourlyMinute ?? time.minute)
        case .daily: return .daily(hour: time.hour, minute: time.minute)
        case .weekdays: return .weekdays(hour: time.hour, minute: time.minute)
        case .weekly:
            if case .weekly = self { return self }
            let today = ScheduleWeekday(rawValue: calendar.component(.weekday, from: Date()) - 1) ?? .monday
            return .weekly(days: [today], hour: time.hour, minute: time.minute)
        case .custom:
            if case .custom = self { return self }
            return .custom(cron: cronText)
        }
    }

    var hourlyMinute: Int? {
        if case .hourly(let minute) = self { return minute }
        return nil
    }
}

public enum ScheduleTriggerError: Error, Equatable, Sendable, LocalizedError {
    case noDays
    case badTime

    public var errorDescription: String? {
        switch self {
        case .noDays: "Choose at least one day."
        case .badTime: "Choose a time between 00:00 and 23:59."
        }
    }
}

extension ScheduleTrigger: Codable {
    private enum CodingKeys: String, CodingKey { case kind, hour, minute, days, cron }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        let minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        switch kind {
        case .hourly: self = .hourly(minute: minute)
        case .daily: self = .daily(hour: hour, minute: minute)
        case .weekdays: self = .weekdays(hour: hour, minute: minute)
        case .weekly:
            let days = try container.decodeIfPresent([ScheduleWeekday].self, forKey: .days) ?? []
            self = .weekly(days: Set(days), hour: hour, minute: minute)
        case .custom:
            self = .custom(cron: try container.decodeIfPresent(String.self, forKey: .cron) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .hourly(let minute):
            try container.encode(minute, forKey: .minute)
        case .daily(let hour, let minute), .weekdays(let hour, let minute):
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let days, let hour, let minute):
            try container.encode(days.sorted(), forKey: .days)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .custom(let cron):
            try container.encode(cron, forKey: .cron)
        }
    }
}
