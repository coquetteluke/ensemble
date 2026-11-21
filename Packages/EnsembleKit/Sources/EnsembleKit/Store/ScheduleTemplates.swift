import Foundation

/// A ready-made scheduled task to start from: a name, what it does, the prompt and when it runs. Picking one opens
/// the task editor filled in; nothing is saved until the user presses Save there.
public struct ScheduleTemplate: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// One line under the name.
    public var summary: String
    public var prompt: String
    public var trigger: ScheduleTrigger
    /// SF Symbol name.
    public var symbol: String

    public init(id: String, name: String, summary: String, prompt: String, trigger: ScheduleTrigger, symbol: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.prompt = prompt
        self.trigger = trigger
        self.symbol = symbol
    }

    /// A new task from this template, in Ask mode: every template only reads and reports, and Ask keeps it that way.
    public func task(directory: String, model: ModelRef?) -> ScheduledTask {
        ScheduledTask(name: name, prompt: prompt, directory: directory, model: model, permissionMode: .ask, trigger: trigger)
    }
}

public enum ScheduleTemplates {
    public static let all: [ScheduleTemplate] = [
        ScheduleTemplate(
            id: "morning-summary", name: "Morning summary",
            summary: "What changed since yesterday and what to do next.",
            prompt: "Look at the commits, open branches and uncommitted changes in this folder since yesterday morning. "
                + "Write a short summary: what changed, what is half done, and the three things most worth doing next. Change nothing.",
            trigger: .weekdays(hour: 9, minute: 0), symbol: "sun.max"),
        ScheduleTemplate(
            id: "nightly-tests", name: "Nightly test run",
            summary: "Runs the tests and explains any failure.",
            prompt: "Run the full test suite. If anything fails, find the cause and write it up: the failing test, the reason, "
                + "and a suggested fix. Do not change code.",
            trigger: .daily(hour: 3, minute: 0), symbol: "checkmark.seal"),
        ScheduleTemplate(
            id: "dependency-check", name: "Dependency check",
            summary: "Outdated packages and security advisories.",
            prompt: "Check this project for outdated packages and known security advisories. List what is safe to update now "
                + "and what needs care, with the reason for each. Do not update anything.",
            trigger: .weekly(days: [.monday], hour: 10, minute: 0), symbol: "shippingbox"),
        ScheduleTemplate(
            id: "open-pull-requests", name: "Open pull requests",
            summary: "Review state and failing checks, oldest first.",
            prompt: "List this repository's open pull requests, oldest first, with each one's review state and any failing "
                + "checks. Say which ones are waiting on me. Change nothing.",
            trigger: .weekdays(hour: 9, minute: 30), symbol: "arrow.triangle.pull"),
        ScheduleTemplate(
            id: "loose-ends", name: "Loose ends",
            summary: "New TODO notes and commented-out code.",
            prompt: "Find the TODO and FIXME notes added in the last seven days and any code that was commented out. "
                + "List them by file with one line each. Change nothing.",
            trigger: .weekly(days: [.friday], hour: 16, minute: 0), symbol: "checklist"),
        ScheduleTemplate(
            id: "docs-against-code", name: "Docs against code",
            summary: "Where the README and docs no longer match.",
            prompt: "Compare the README and the docs folder with the code. List anything they describe that the code no "
                + "longer does, with the file and the line. Change nothing.",
            trigger: .weekly(days: [.wednesday], hour: 11, minute: 0), symbol: "doc.text.magnifyingglass"),
    ]
}

/// Searching and ordering the Scheduled screen's list.
public enum ScheduleListing {
    public enum Sort: String, CaseIterable, Identifiable, Sendable {
        case created, name, nextRun

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .created: "Date created"
            case .name: "Name"
            case .nextRun: "Next run"
            }
        }
    }

    /// Tasks whose name, prompt or folder name contains every word of `query` (case and accents ignored).
    public static func filter(_ tasks: [ScheduledTask], query: String) -> [ScheduledTask] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return tasks }
        return tasks.filter { task in
            let haystack = [task.name, task.prompt, Format.folderName(task.directory)].joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// `created` keeps the stored order. `name` is alphabetical, unnamed tasks last. `nextRun` is soonest first,
    /// tasks with no next run (paused) last. Ties keep the stored order.
    public static func sorted(_ tasks: [ScheduledTask], by sort: Sort, nextRun: (ScheduledTask) -> Date?) -> [ScheduledTask] {
        switch sort {
        case .created:
            return tasks
        case .name:
            return tasks.enumerated().sorted { a, b in
                let left = a.element.name.trimmingCharacters(in: .whitespaces)
                let right = b.element.name.trimmingCharacters(in: .whitespaces)
                if left.isEmpty != right.isEmpty { return !left.isEmpty }
                let order = left.localizedCaseInsensitiveCompare(right)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }.map(\.element)
        case .nextRun:
            return tasks.enumerated().map { (offset: $0.offset, task: $0.element, next: nextRun($0.element)) }.sorted { a, b in
                switch (a.next, b.next) {
                case let (left?, right?): left == right ? a.offset < b.offset : left < right
                case (nil, nil): a.offset < b.offset
                case (nil, _): false
                case (_, nil): true
                }
            }.map(\.task)
        }
    }
}
