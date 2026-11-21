import Foundation
import Testing
@testable import EnsembleKit

@Suite struct ScheduleTemplatesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ name: String, prompt: String = "Do it", directory: String = "/Users/sam/work/app") -> ScheduledTask {
        ScheduledTask(name: name, prompt: prompt, directory: directory)
    }

    @Test func everyTemplateIsCompleteAndRunsOnARealSchedule() {
        let calendar = Calendar(identifier: .gregorian)
        #expect(ScheduleTemplates.all.count >= 4)
        #expect(Set(ScheduleTemplates.all.map(\.id)).count == ScheduleTemplates.all.count)
        for template in ScheduleTemplates.all {
            #expect(!template.name.isEmpty)
            #expect(!template.summary.isEmpty)
            #expect(template.prompt.count > 40)
            #expect(template.trigger.nextFire(after: now, calendar: calendar) != nil)
            // No em dashes anywhere in the app's text.
            #expect(!(template.name + template.summary + template.prompt).contains("\u{2014}"))
        }
    }

    @Test func templatesOnlyReadSoTheyStartInAskMode() {
        for template in ScheduleTemplates.all {
            let made = template.task(directory: "/Users/sam/work/app", model: nil)
            #expect(made.permissionMode == .ask)
            #expect(made.name == template.name)
            #expect(made.prompt == template.prompt)
            #expect(made.trigger == template.trigger)
            #expect(made.directory == "/Users/sam/work/app")
            #expect(!made.paused)
            #expect(template.prompt.localizedCaseInsensitiveContains("change nothing")
                    || template.prompt.localizedCaseInsensitiveContains("do not"))
        }
    }

    @Test func searchMatchesNamePromptAndFolder() {
        let tasks = [task("Morning triage", prompt: "Label the new issues"), task("Nightly tests", directory: "/Users/sam/work/api-server"),
                     task("", prompt: "Write the notes")]
        #expect(ScheduleListing.filter(tasks, query: "").count == 3)
        #expect(ScheduleListing.filter(tasks, query: "  ").count == 3)
        #expect(ScheduleListing.filter(tasks, query: "TRIAGE").map(\.name) == ["Morning triage"])
        #expect(ScheduleListing.filter(tasks, query: "issues label").map(\.name) == ["Morning triage"])
        #expect(ScheduleListing.filter(tasks, query: "api-server").map(\.name) == ["Nightly tests"])
        #expect(ScheduleListing.filter(tasks, query: "notes").count == 1)
        #expect(ScheduleListing.filter(tasks, query: "nothing-here").isEmpty)
    }

    @Test func sortsByNameWithUnnamedLast() {
        let tasks = [task("beta"), task(""), task("Alpha"), task("alpha")]
        let sorted = ScheduleListing.sorted(tasks, by: .name) { _ in nil }
        #expect(sorted.map(\.name) == ["Alpha", "alpha", "beta", ""])
        #expect(ScheduleListing.sorted(tasks, by: .created) { _ in nil }.map(\.name) == ["beta", "", "Alpha", "alpha"])
    }

    @Test func sortsByNextRunWithPausedLast() {
        let tasks = [task("late"), task("paused"), task("soon"), task("also-soon")]
        let next: [String: Date] = ["late": now.addingTimeInterval(900), "soon": now.addingTimeInterval(60),
                                    "also-soon": now.addingTimeInterval(60)]
        let sorted = ScheduleListing.sorted(tasks, by: .nextRun) { next[$0.name] }
        #expect(sorted.map(\.name) == ["soon", "also-soon", "late", "paused"])
    }
}
