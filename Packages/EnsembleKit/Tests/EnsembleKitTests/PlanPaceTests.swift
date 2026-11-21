import Foundation
import Testing
@testable import EnsembleKit

@Suite struct PlanPaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    @Test func aWeekUsedTooFastRunsOutBeforeTheReset() throws {
        // Four days into the week with 80% used: the last 20% lasts one more day, and the reset is three days off.
        let pace = try #require(PlanPace.project(windowName: "seven_day", utilization: 0.8, resetsAt: now.addingTimeInterval(3 * day), now: now))
        #expect(abs(pace.runsOutAt.timeIntervalSince(now) - day) < 1)
        #expect(abs(pace.shortBy - 2 * day) < 1)
    }

    @Test func aWeekUsedEvenlyLasts() {
        // Half the week gone, half the limit used.
        #expect(PlanPace.project(windowName: "seven_day", utilization: 0.5, resetsAt: now.addingTimeInterval(3.5 * day), now: now) == nil)
        // Slower than even.
        #expect(PlanPace.project(windowName: "seven_day_opus", utilization: 0.3, resetsAt: now.addingTimeInterval(2 * day), now: now) == nil)
    }

    @Test func theFiveHourWindowIsProjectedTheSameWay() throws {
        // Two hours in, 70% used: 30% lasts about 51 minutes, three hours are left.
        let pace = try #require(PlanPace.project(windowName: "five_hour", utilization: 0.7, resetsAt: now.addingTimeInterval(3 * hour), now: now))
        #expect(abs(pace.runsOutAt.timeIntervalSince(now) - (0.3 / 0.7) * 2 * hour) < 1)
        #expect(pace.shortBy > 2 * hour)
    }

    @Test func tooEarlyOrTooLittleToTell() {
        // Ten minutes into a week: any use looks like a terrible rate.
        #expect(PlanPace.project(windowName: "seven_day", utilization: 0.25, resetsAt: now.addingTimeInterval(7 * day - 600), now: now) == nil)
        // Under a fifth used.
        #expect(PlanPace.project(windowName: "seven_day", utilization: 0.15, resetsAt: now.addingTimeInterval(6 * day), now: now) == nil)
    }

    @Test func nothingToSayWithoutAKnownWindowAResetOrRoom() {
        #expect(PlanPace.project(windowName: "monthly", utilization: 0.9, resetsAt: now.addingTimeInterval(day), now: now) == nil)
        #expect(PlanPace.project(windowName: "seven_day", utilization: 0.9, resetsAt: nil, now: now) == nil)
        #expect(PlanPace.project(windowName: "seven_day", utilization: 1, resetsAt: now.addingTimeInterval(day), now: now) == nil)
        #expect(PlanPace.project(windowName: "seven_day", utilization: 0.9, resetsAt: now.addingTimeInterval(-60), now: now) == nil)
    }

    @Test func aNearMissIsNotAWarning() {
        // Runs out about 40 minutes before a weekly reset: under a fiftieth of the week.
        let resets = now.addingTimeInterval(day)
        let utilization = (6 * day) / (7 * day - 2400)
        #expect(PlanPace.project(windowName: "seven_day", utilization: utilization, resetsAt: resets, now: now) == nil)
    }

    @Test func windowLengths() {
        #expect(PlanPace.length(of: "five_hour") == 5 * hour)
        #expect(PlanPace.length(of: "seven_day") == 7 * day)
        #expect(PlanPace.length(of: "seven_day_sonnet") == 7 * day)
        #expect(PlanPace.length(of: "other") == nil)
    }

    @Test func durationsUseTwoUnits() {
        #expect(PlanPace.durationText(20) == "1m")
        #expect(PlanPace.durationText(25 * 60) == "25m")
        #expect(PlanPace.durationText(3 * hour) == "3h")
        #expect(PlanPace.durationText(3 * hour + 20 * 60) == "3h 20m")
        #expect(PlanPace.durationText(day + 17 * hour) == "1d 17h")
        #expect(PlanPace.durationText(2 * day) == "2d")
    }
}
