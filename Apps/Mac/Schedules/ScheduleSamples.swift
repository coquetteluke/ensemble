import Foundation
import EnsembleKit

/// Times and durations as the Scheduled screen writes them.
enum ScheduleFormat {
    /// "Today 9:00 AM", "Tomorrow 9:00 AM", "Yesterday 9:00 AM", "Wed 9:00 AM" within a week, "Nov 25, 9:00 AM" later.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return date.formatted(.dateTime.month(.abbreviated).day()) + ", " + time
    }

    /// "12s", "4m 12s", "1h 3m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

/// Sample tasks and history for `--preview` and snapshots, on the preview store's sessions and folders.
enum ScheduleSamples {
    static let triageID = UUID(uuidString: "5C4E0D2A-1B7F-4C1E-9A11-000000000001")!
    static let nightlyID = UUID(uuidString: "5C4E0D2A-1B7F-4C1E-9A11-000000000002")!
    static let depsID = UUID(uuidString: "5C4E0D2A-1B7F-4C1E-9A11-000000000003")!
    static let notesID = UUID(uuidString: "5C4E0D2A-1B7F-4C1E-9A11-000000000004")!

    static let gemini = ModelRef(providerID: "google", id: "gemini-3-pro")

    static func contents(now: Date = Date(), calendar: Calendar = .current) -> ScheduleFileContents {
        let home = NSHomeDirectory()
        let ensemble = home + "/Ensemble"
        let portfolio = home + "/Developer/portfolio-site"
        let api = home + "/Developer/api-server"
        let created = now.addingTimeInterval(-30 * 86_400)

        let triage = ScheduledTask(id: triageID, name: "Morning triage",
                                   prompt: "Read the issues opened since yesterday, label them, and list the three that need me first.",
                                   directory: ensemble, model: ModelRef(providerID: "anthropic", id: "claude-opus-5-5"),
                                   permissionMode: .ask, trigger: .weekdays(hour: 9, minute: 0), created: created, checkedThrough: now)
        let nightly = ScheduledTask(id: nightlyID, name: "Nightly test run",
                                    prompt: "Run the full test suite. If anything fails, find the cause and write it up; do not change code.",
                                    directory: api, model: ModelRef(providerID: "openai", id: "gpt-5.5"), permissionMode: .auto,
                                    trigger: .custom(cron: "0 3 * * *"), created: created, checkedThrough: now)
        let deps = ScheduledTask(id: depsID, name: "Dependency check",
                                 prompt: "Check for outdated packages and open a branch with safe minor updates.",
                                 directory: portfolio, model: gemini, permissionMode: .acceptEdits,
                                 trigger: .weekly(days: [.monday, .thursday], hour: 10, minute: 0), paused: true,
                                 created: created, checkedThrough: now)
        var notes = ScheduledTask(id: notesID, name: "End of day notes",
                                  prompt: "Add today's decisions and open questions to the notes.",
                                  directory: ensemble, permissionMode: .bypass, trigger: .daily(hour: 18, minute: 30),
                                  catchUpWindow: 0, keepAwake: false, created: created, checkedThrough: now)
        notes.continueSessionID = "ses_db_debate"

        func last(_ trigger: ScheduleTrigger, back: Int = 0) -> Date {
            let fires = trigger.nextFires(after: now.addingTimeInterval(-9 * 86_400), count: 400, calendar: calendar).filter { $0 <= now }
            return fires.dropLast(back).last ?? now.addingTimeInterval(-3600)
        }

        let triageLast = last(triage.trigger)
        let triagePrevious = last(triage.trigger, back: 1)
        let triageOlder = last(triage.trigger, back: 2)
        let nightlyLast = last(nightly.trigger)
        let depsLast = last(.weekly(days: [.monday, .thursday], hour: 10, minute: 0))
        let notesLast = last(notes.trigger)
        let runs: [ScheduleRun] = [
            ScheduleRun(taskID: triageID, reason: .scheduled, scheduledFor: triageLast, started: triageLast,
                        finished: triageLast.addingTimeInterval(252), status: .succeeded, sessionID: "ses_readme",
                        sessionTitle: ScheduleTitle.sessionTitle(taskName: triage.name, date: triageLast)),
            ScheduleRun(taskID: triageID, reason: .caughtUp, scheduledFor: triagePrevious, started: triagePrevious.addingTimeInterval(5520),
                        finished: triagePrevious.addingTimeInterval(5520 + 318), status: .succeeded, sessionID: "ses_sse_reconnect",
                        sessionTitle: ScheduleTitle.sessionTitle(taskName: triage.name, date: triagePrevious.addingTimeInterval(5520))),
            ScheduleRun(taskID: triageID, reason: .scheduled, scheduledFor: triageOlder, started: triageOlder,
                        finished: triageOlder.addingTimeInterval(14), status: .failed,
                        message: "Model unavailable: anthropic/claude-opus-5-5. Add an Anthropic key in Settings."),
            ScheduleRun(taskID: nightlyID, reason: .scheduled, scheduledFor: nightlyLast, started: nightlyLast, status: .needsYou,
                        sessionID: "ses_rate_limit", sessionTitle: ScheduleTitle.sessionTitle(taskName: nightly.name, date: nightlyLast)),
            ScheduleRun(taskID: depsID, reason: .scheduled, scheduledFor: depsLast, started: depsLast, finished: depsLast,
                        status: .missed, message: "The Mac was asleep or Ensemble was closed for longer than the catch-up window (within 12 hours)."),
            ScheduleRun(taskID: notesID, reason: .manual, started: notesLast.addingTimeInterval(-600),
                        finished: notesLast.addingTimeInterval(-540), status: .skipped, message: "The session it continues was busy."),
        ]
        return ScheduleFileContents(tasks: [triage, nightly, deps, notes], runs: runs.sorted { $0.started > $1.started })
    }
}
