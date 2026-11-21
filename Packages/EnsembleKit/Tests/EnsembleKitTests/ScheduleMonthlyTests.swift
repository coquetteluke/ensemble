import Foundation
import Testing
@testable import EnsembleKit

@Suite struct ScheduleMonthlyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func aMonthlyTaskRunsOnItsDayEveryMonth() {
        let trigger = ScheduleTrigger.monthly(day: 15, hour: 9, minute: 30)
        #expect(trigger.cronText == "30 9 15 * *")
        #expect(trigger.kind == .monthly)
        let fires = trigger.nextFires(after: date(2026, 11, 20), count: 3, calendar: calendar)
        #expect(fires == [date(2026, 12, 15, 9, 30), date(2027, 1, 15, 9, 30), date(2027, 2, 15, 9, 30)])
    }

    @Test func februaryIsNeverSkipped() {
        let trigger = ScheduleTrigger.monthly(day: 28, hour: 6, minute: 0)
        let fires = trigger.nextFires(after: date(2027, 1, 29), count: 2, calendar: calendar)
        #expect(fires == [date(2027, 2, 28, 6), date(2027, 3, 28, 6)])
    }

    @Test func daysOutsideOneToTwentyEightAreRefused() {
        #expect(ScheduleTrigger.monthly(day: 31, hour: 9, minute: 0).validationError(calendar: calendar, now: date(2026, 11, 20))
                == "Choose a day from 1 to 28, so the task runs every month.")
        #expect(ScheduleTrigger.monthly(day: 0, hour: 9, minute: 0).nextFire(after: date(2026, 11, 20), calendar: calendar) == nil)
        #expect(ScheduleTrigger.monthly(day: 1, hour: 9, minute: 0).validationError(calendar: calendar, now: date(2026, 11, 20)) == nil)
        #expect(ScheduleTrigger.monthly(day: 5, hour: 24, minute: 0).validationError(calendar: calendar, now: date(2026, 11, 20)) != nil)
    }

    @Test func theSummaryNamesTheDay() {
        #expect(ScheduleTrigger.monthly(day: 1, hour: 9, minute: 0).summary(calendar: calendar) == "Monthly on the 1st at 9:00\u{202F}AM"
                || ScheduleTrigger.monthly(day: 1, hour: 9, minute: 0).summary(calendar: calendar) == "Monthly on the 1st at 9:00 AM")
        #expect(ScheduleTrigger.ordinal(2) == "2nd")
        #expect(ScheduleTrigger.ordinal(3) == "3rd")
        #expect(ScheduleTrigger.ordinal(11) == "11th")
        #expect(ScheduleTrigger.ordinal(12) == "12th")
        #expect(ScheduleTrigger.ordinal(13) == "13th")
        #expect(ScheduleTrigger.ordinal(21) == "21st")
        #expect(ScheduleTrigger.ordinal(28) == "28th")
    }

    @Test func itSurvivesSavingAndLoading() throws {
        let trigger = ScheduleTrigger.monthly(day: 7, hour: 18, minute: 45)
        let data = try JSONEncoder().encode(trigger)
        #expect(try JSONDecoder().decode(ScheduleTrigger.self, from: data) == trigger)
        // A file from before monthly existed still loads.
        let old = Data(#"{"kind":"weekly","hour":9,"minute":0,"days":[1,3]}"#.utf8)
        #expect(try JSONDecoder().decode(ScheduleTrigger.self, from: old) == .weekly(days: [.monday, .wednesday], hour: 9, minute: 0))
        // A monthly entry without a day falls back to the first.
        let bare = Data(#"{"kind":"monthly","hour":8,"minute":15}"#.utf8)
        #expect(try JSONDecoder().decode(ScheduleTrigger.self, from: bare) == .monthly(day: 1, hour: 8, minute: 15))
    }

    @Test func switchingKindKeepsTheTimeOfDay() {
        let daily = ScheduleTrigger.daily(hour: 14, minute: 5)
        guard case .monthly(let day, let hour, let minute) = daily.converted(to: .monthly, calendar: calendar) else {
            Issue.record("Expected a monthly trigger")
            return
        }
        #expect(ScheduleTrigger.monthlyDays.contains(day))
        #expect(hour == 14)
        #expect(minute == 5)
        let monthly = ScheduleTrigger.monthly(day: 9, hour: 7, minute: 0)
        #expect(monthly.converted(to: .monthly, calendar: calendar) == monthly)
        #expect(monthly.converted(to: .daily, calendar: calendar) == .daily(hour: 7, minute: 0))
        #expect(monthly.converted(to: .custom, calendar: calendar) == .custom(cron: "0 7 9 * *"))
        #expect(ScheduleTrigger.Kind.allCases.map(\.label) == ["Hourly", "Daily", "Weekdays", "Weekly", "Monthly", "Custom"])
    }
}
