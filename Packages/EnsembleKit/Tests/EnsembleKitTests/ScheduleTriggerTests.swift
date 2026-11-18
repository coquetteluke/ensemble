import Foundation
import Testing
@testable import EnsembleKit

/// Calendars and dates for schedule tests.
enum ScheduleTestTime {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A wall-clock time in `zone` (the first one, when the clocks go back).
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
                     zone: String = "UTC") -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// A moment in UTC.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        date(year, month, day, hour, minute, zone: "UTC")
    }
}

@Suite("Cron expressions")
struct ScheduleCronTests {
    let utc = ScheduleTestTime.calendar("UTC")

    @Test func parsesFieldsStepsRangesAndLists() throws {
        let cron = try CronExpression("*/15 9-17 * * 1-5")
        #expect(cron.minutes == [0, 15, 30, 45])
        #expect(cron.hours == Set(9...17))
        #expect(cron.daysOfMonth == Set(1...31))
        #expect(cron.months == Set(1...12))
        #expect(cron.daysOfWeek == [1, 2, 3, 4, 5])

        let lists = try CronExpression("0,30 8,12-14/2 1,15 */3 *")
        #expect(lists.minutes == [0, 30])
        #expect(lists.hours == [8, 12, 14])
        #expect(lists.daysOfMonth == [1, 15])
        #expect(lists.months == [1, 4, 7, 10])

        // `a/n` runs from a to the end of the range.
        #expect(try CronExpression("5/20 * * * *").minutes == [5, 25, 45])
    }

    @Test func acceptsNamesInAnyCaseAndSundayAsSeven() throws {
        let cron = try CronExpression("0 9 * JAN,jul Mon-FRI")
        #expect(cron.months == [1, 7])
        #expect(cron.daysOfWeek == [1, 2, 3, 4, 5])
        #expect(try CronExpression("0 9 * * 7").daysOfWeek == [0])
        #expect(try CronExpression("0 9 * * 5-7").daysOfWeek == [0, 5, 6])
    }

    @Test func expandsMacros() throws {
        #expect(try CronExpression("@daily").hours == [0])
        #expect(try CronExpression("@hourly").minutes == [0])
        #expect(try CronExpression("@weekly").daysOfWeek == [0])
        #expect(try CronExpression("@monthly").daysOfMonth == [1])
        #expect(try CronExpression("@yearly").months == [1])
    }

    @Test func rejectsBadExpressionsWithReadableMessages() {
        #expect(throws: CronParseError.fieldCount(4)) { try CronExpression("0 9 * *") }
        #expect(throws: CronParseError.empty) { try CronExpression("   ") }
        #expect(throws: CronParseError.outOfRange(field: "minute", value: 60, range: 0...59)) { try CronExpression("60 * * * *") }
        #expect(throws: CronParseError.outOfRange(field: "hour", value: 24, range: 0...23)) { try CronExpression("0 24 * * *") }
        #expect(throws: CronParseError.invalid(field: "day of week", value: "Funday")) { try CronExpression("0 9 * * Funday") }
        #expect(throws: CronParseError.invalid(field: "minute", value: "*/0")) { try CronExpression("*/0 * * * *") }
        #expect(throws: CronParseError.invalid(field: "hour", value: "17-9")) { try CronExpression("0 17-9 * * *") }
        #expect(throws: CronParseError.invalid(field: "minute", value: "1,,2")) { try CronExpression("1,,2 * * * *") }
        #expect(throws: CronParseError.unsupportedMacro("@reboot")) { try CronExpression("@reboot") }
        let message = CronParseError.fieldCount(4).localizedDescription
        #expect(message.contains("5 fields"))
        #expect(!message.contains("\u{2014}"))
    }

    @Test func nextFireIsStrictlyAfter() throws {
        let cron = try CronExpression("0 9 * * *")
        let nine = ScheduleTestTime.utc(2026, 11, 18, 9)
        #expect(cron.nextFire(after: nine, calendar: utc) == ScheduleTestTime.utc(2026, 11, 19, 9))
        #expect(cron.nextFire(after: nine.addingTimeInterval(-1), calendar: utc) == nine)
        #expect(cron.nextFire(after: nine.addingTimeInterval(-0.001), calendar: utc) == nine)
    }

    @Test func eitherDayFieldMatchesWhenBothAreRestricted() throws {
        // The 13th, or any Friday (Vixie cron).
        let cron = try CronExpression("0 0 13 * 5")
        let fires = cron.nextFires(after: ScheduleTestTime.utc(2026, 11, 1, 0), count: 4, calendar: utc)
        #expect(fires == [ScheduleTestTime.utc(2026, 11, 6, 0), ScheduleTestTime.utc(2026, 11, 13, 0),
                          ScheduleTestTime.utc(2026, 11, 20, 0), ScheduleTestTime.utc(2026, 11, 27, 0)])
        // A day field starting with `*` makes both fields count: Fridays on odd days (Nov 13, then Nov 27).
        let starred = try CronExpression("0 0 */2 * 5")
        #expect(starred.nextFires(after: ScheduleTestTime.utc(2026, 11, 1, 0), count: 2, calendar: utc)
            == [ScheduleTestTime.utc(2026, 11, 13, 0), ScheduleTestTime.utc(2026, 11, 27, 0)])
    }

    @Test func findsRareDatesAndGivesUpOnImpossibleOnes() throws {
        let leap = try CronExpression("0 0 29 2 *")
        #expect(leap.nextFire(after: ScheduleTestTime.utc(2026, 3, 1, 0), calendar: utc) == ScheduleTestTime.utc(2028, 2, 29, 0))
        #expect(try CronExpression("0 0 30 2 *").nextFire(after: ScheduleTestTime.utc(2026, 3, 1, 0), calendar: utc) == nil)
        #expect(ScheduleTrigger.custom(cron: "0 0 31 4 *").validationError(calendar: utc, now: ScheduleTestTime.utc(2026, 1, 1, 0))
            == "This schedule never matches a real date.")
    }

    @Test func halfHourTimeZonesUseLocalHours() throws {
        let kolkata = ScheduleTestTime.calendar("Asia/Kolkata")
        let cron = try CronExpression("0 9 * * *")
        #expect(cron.nextFire(after: ScheduleTestTime.utc(2026, 11, 18, 0), calendar: kolkata) == ScheduleTestTime.utc(2026, 11, 18, 3, 30))
    }
}

@Suite("Schedule triggers")
struct ScheduleTriggerTests {
    let newYork = ScheduleTestTime.calendar("America/New_York")
    let london = ScheduleTestTime.calendar("Europe/London")
    let utc = ScheduleTestTime.calendar("UTC")

    @Test func eachKindHasTheRightCron() {
        #expect(ScheduleTrigger.hourly(minute: 15).cronText == "15 * * * *")
        #expect(ScheduleTrigger.daily(hour: 9, minute: 5).cronText == "5 9 * * *")
        #expect(ScheduleTrigger.weekdays(hour: 18, minute: 0).cronText == "0 18 * * 1-5")
        #expect(ScheduleTrigger.weekly(days: [.friday, .monday], hour: 7, minute: 30).cronText == "30 7 * * 1,5")
        #expect(ScheduleTrigger.custom(cron: " 0 3 * * * ").cronText == "0 3 * * *")
    }

    @Test func dailyWeekdaysWeeklyAndHourlyFireAtTheirTimes() {
        // Friday 2026-11-20, 10:00 in New York.
        let friday = ScheduleTestTime.date(2026, 11, 20, 10, zone: "America/New_York")
        #expect(ScheduleTrigger.daily(hour: 9, minute: 0).nextFire(after: friday, calendar: newYork)
            == ScheduleTestTime.date(2026, 11, 21, 9, zone: "America/New_York"))
        #expect(ScheduleTrigger.weekdays(hour: 9, minute: 0).nextFire(after: friday, calendar: newYork)
            == ScheduleTestTime.date(2026, 11, 23, 9, zone: "America/New_York"))
        #expect(ScheduleTrigger.weekly(days: [.wednesday, .sunday], hour: 8, minute: 15).nextFires(after: friday, count: 2, calendar: newYork)
            == [ScheduleTestTime.date(2026, 11, 22, 8, 15, zone: "America/New_York"),
                ScheduleTestTime.date(2026, 11, 25, 8, 15, zone: "America/New_York")])
        #expect(ScheduleTrigger.hourly(minute: 45).nextFire(after: friday, calendar: newYork)
            == ScheduleTestTime.date(2026, 11, 20, 10, 45, zone: "America/New_York"))
    }

    @Test func aTimeSkippedBySpringForwardRunsRightAfterTheJump() {
        // New York, 2026-03-08: 2:00 EST jumps to 3:00 EDT (07:00 UTC). 2:30 does not exist that day.
        let trigger = ScheduleTrigger.daily(hour: 2, minute: 30)
        let saturday = ScheduleTestTime.utc(2026, 3, 7, 12)
        let fires = trigger.nextFires(after: saturday, count: 2, calendar: newYork)
        #expect(fires == [ScheduleTestTime.utc(2026, 3, 8, 7), ScheduleTestTime.utc(2026, 3, 9, 6, 30)])
        // Hourly carries on after the jump, without an extra run.
        let hourly = ScheduleTrigger.hourly(minute: 30).nextFires(after: ScheduleTestTime.utc(2026, 3, 8, 6), count: 2, calendar: newYork)
        #expect(hourly == [ScheduleTestTime.utc(2026, 3, 8, 6, 30), ScheduleTestTime.utc(2026, 3, 8, 7, 30)])
        // London, 2026-03-29: 1:00 GMT jumps to 2:00 BST (01:00 UTC).
        #expect(ScheduleTrigger.daily(hour: 1, minute: 30).nextFire(after: ScheduleTestTime.utc(2026, 3, 28, 12), calendar: london)
            == ScheduleTestTime.utc(2026, 3, 29, 1))
        // A time outside the skipped hour is not moved.
        #expect(ScheduleTrigger.daily(hour: 9, minute: 0).nextFire(after: ScheduleTestTime.utc(2026, 3, 8, 0), calendar: newYork)
            == ScheduleTestTime.utc(2026, 3, 8, 13))
    }

    @Test func aTimeRepeatedByFallBackRunsOnce() {
        // New York, 2026-11-01: 2:00 EDT goes back to 1:00 EST (06:00 UTC), so 1:30 happens twice.
        let daily = ScheduleTrigger.daily(hour: 1, minute: 30).nextFires(after: ScheduleTestTime.utc(2026, 10, 31, 12), count: 2,
                                                                         calendar: newYork)
        #expect(daily == [ScheduleTestTime.utc(2026, 11, 1, 5, 30), ScheduleTestTime.utc(2026, 11, 2, 6, 30)])
        // Hourly runs in both hours.
        let hourly = ScheduleTrigger.hourly(minute: 30).nextFires(after: ScheduleTestTime.utc(2026, 11, 1, 5), count: 3, calendar: newYork)
        #expect(hourly == [ScheduleTestTime.utc(2026, 11, 1, 5, 30), ScheduleTestTime.utc(2026, 11, 1, 6, 30),
                           ScheduleTestTime.utc(2026, 11, 1, 7, 30)])
        // London, 2026-10-25: 2:00 BST goes back to 1:00 GMT (01:00 UTC).
        #expect(ScheduleTrigger.daily(hour: 1, minute: 15).nextFires(after: ScheduleTestTime.utc(2026, 10, 24, 12), count: 2, calendar: london)
            == [ScheduleTestTime.utc(2026, 10, 25, 0, 15), ScheduleTestTime.utc(2026, 10, 26, 1, 15)])
    }

    @Test func dailyTimeStaysOnTheWallClockAcrossTheChange() {
        // 9:00 New York is 14:00 UTC before the change and 13:00 after.
        let fires = ScheduleTrigger.daily(hour: 9, minute: 0).nextFires(after: ScheduleTestTime.utc(2026, 3, 7, 0), count: 2, calendar: newYork)
        #expect(fires == [ScheduleTestTime.utc(2026, 3, 7, 14), ScheduleTestTime.utc(2026, 3, 8, 13)])
    }

    @Test func validatesTriggers() {
        #expect(ScheduleTrigger.weekly(days: [], hour: 9, minute: 0).validationError() == "Choose at least one day.")
        #expect(ScheduleTrigger.daily(hour: 25, minute: 0).validationError() != nil)
        #expect(ScheduleTrigger.custom(cron: "0 9 * *").validationError()?.contains("5 fields") == true)
        #expect(ScheduleTrigger.custom(cron: "0 9 * * 1-5").validationError() == nil)
        #expect(ScheduleTrigger.daily(hour: 9, minute: 0).validationError() == nil)
    }

    @Test func summariesSayWhenInWords() {
        let calendar = newYork
        #expect(ScheduleTrigger.hourly(minute: 5).summary(calendar: calendar) == "Every hour at :05")
        #expect(ScheduleTrigger.daily(hour: 9, minute: 0).summary(calendar: calendar).hasPrefix("Every day at 9:00"))
        #expect(ScheduleTrigger.weekdays(hour: 9, minute: 0).summary(calendar: calendar).hasPrefix("Weekdays at "))
        #expect(ScheduleTrigger.weekly(days: [.monday], hour: 9, minute: 0).summary(calendar: calendar).hasPrefix("Every Monday at "))
        #expect(ScheduleTrigger.weekly(days: [.friday, .monday, .wednesday], hour: 9, minute: 0).summary(calendar: calendar)
            .hasPrefix("Mon, Wed and Fri at "))
        #expect(ScheduleTrigger.weekly(days: ScheduleWeekday.workdays, hour: 9, minute: 0).summary(calendar: calendar).hasPrefix("Weekdays"))
        #expect(ScheduleTrigger.custom(cron: "0 3 * * *").summary(calendar: calendar) == "Cron 0 3 * * *")
        for trigger in [ScheduleTrigger.hourly(minute: 0), .daily(hour: 9, minute: 0), .custom(cron: "@daily")] {
            #expect(!trigger.summary(calendar: calendar).contains("\u{2014}"))
        }
    }

    @Test func switchingKindKeepsTheTime() {
        let daily = ScheduleTrigger.daily(hour: 7, minute: 45)
        #expect(daily.converted(to: .weekdays) == .weekdays(hour: 7, minute: 45))
        #expect(daily.converted(to: .hourly) == .hourly(minute: 45))
        #expect(daily.converted(to: .custom) == .custom(cron: "45 7 * * *"))
        if case .weekly(let days, 7, 45) = daily.converted(to: .weekly) { #expect(days.count == 1) } else { Issue.record("not weekly") }
    }

    @Test func triggersSurviveEncoding() throws {
        let all: [ScheduleTrigger] = [.hourly(minute: 10), .daily(hour: 9, minute: 0), .weekdays(hour: 17, minute: 30),
                                      .weekly(days: [.sunday, .saturday], hour: 10, minute: 0), .custom(cron: "*/5 * * * *")]
        let data = try JSONEncoder().encode(all)
        #expect(try JSONDecoder().decode([ScheduleTrigger].self, from: data) == all)
    }

    @Test func weekdaysFollowTheCalendarsFirstDay() {
        var us = utc
        us.firstWeekday = 1
        var europe = utc
        europe.firstWeekday = 2
        #expect(ScheduleWeekday.ordered(us).first == .sunday)
        #expect(ScheduleWeekday.ordered(europe).first == .monday)
        #expect(ScheduleWeekday.ordered(europe).count == 7)
    }

    @Test func sessionTitlesNameTheTaskAndDate() {
        let title = ScheduleTitle.sessionTitle(taskName: "Morning triage", date: ScheduleTestTime.utc(2026, 11, 18, 9), calendar: utc)
        #expect(title.hasPrefix("Morning triage, Nov 18"))
        #expect(ScheduleTitle.sessionTitle(taskName: "  ", date: Date(), calendar: utc).hasPrefix("Scheduled task, "))
    }
}
