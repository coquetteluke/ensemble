import Foundation
import Testing
@testable import EnsembleKit

@Suite struct SearchStartTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, _ status: SidebarRowStatus, minutesAgo: Double) -> SidebarEntry {
        SidebarEntry(id: id, title: id, directory: "/Users/sam/work", created: now.addingTimeInterval(-86_400),
                     updated: now.addingTimeInterval(-minutesAgo * 60), status: status)
    }

    @Test func sessionsFallIntoTheFirstGroupThatFits() {
        let start = SearchStart.build([
            entry("idle-old", .idle, minutesAgo: 600),
            entry("prompt", .needsYou, minutesAgo: 30),
            entry("failed", .failed, minutesAgo: 5),
            entry("running", .running, minutesAgo: 1),
            entry("unread", .unread, minutesAgo: 2),
            entry("done", .completed, minutesAgo: 90),
        ])
        #expect(start.sections.map(\.kind) == [.needsYou, .working, .recent])
        #expect(start.sections[0].entries.map(\.id) == ["failed", "prompt"])
        #expect(start.sections[1].entries.map(\.id) == ["running"])
        #expect(start.sections[2].entries.map(\.id) == ["unread", "done", "idle-old"])
        #expect(start.entries.count == 6)
    }

    @Test func emptyGroupsAreLeftOut() {
        let start = SearchStart.build([entry("a", .idle, minutesAgo: 3), entry("b", .idle, minutesAgo: 1)])
        #expect(start.sections.map(\.kind) == [.recent])
        #expect(start.sections[0].entries.map(\.id) == ["b", "a"])
        #expect(SearchStart.build([]).sections.isEmpty)
    }

    @Test func groupsAreCapped() {
        let many = (0..<12).map { entry("r\($0)", .running, minutesAgo: Double($0)) }
            + (0..<12).map { entry("i\($0)", .idle, minutesAgo: Double($0)) }
        let start = SearchStart.build(many, groupLimit: 5, recentLimit: 6)
        #expect(start.sections.first { $0.kind == .working }?.entries.map(\.id) == ["r0", "r1", "r2", "r3", "r4"])
        #expect(start.sections.first { $0.kind == .recent }?.entries.count == 6)
    }

    @Test func titlesAreShort() {
        #expect(SearchStart.Section.Kind.allCases.map(\.title) == ["Needs you", "Working", "Recent"])
    }

    @Test func aTieOnTimeIsSettledByID() {
        let start = SearchStart.build([entry("a", .idle, minutesAgo: 1), entry("b", .idle, minutesAgo: 1)])
        #expect(start.sections[0].entries.map(\.id) == ["b", "a"])
    }
}
