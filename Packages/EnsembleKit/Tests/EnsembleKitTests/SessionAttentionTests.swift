import Foundation
import Testing
@testable import EnsembleKit

@Suite("Session attention tracker")
struct SessionAttentionTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func prompt(_ id: String, session: String = "a") -> PermissionRequest {
        PermissionRequest(id: id, sessionID: session, kind: "bash", title: "swift test", created: t0)
    }

    func snap(_ id: String = "a", prompts: [PermissionRequest] = [], active: Bool = false, failed: Bool = false) -> SessionAttentionSnapshot {
        SessionAttentionSnapshot(id: id, title: "Title \(id)", directory: "/p", prompts: prompts, active: active,
                                 working: active && prompts.isEmpty, failed: failed)
    }

    @Test func baselineProducesNoEvents() {
        var tracker = SessionAttentionTracker()
        let events = tracker.update([snap(prompts: [prompt("p1")], active: true)], now: t0)
        #expect(events.isEmpty)
        #expect(tracker.hasBaseline)
        // The prompt open at launch is not announced later either.
        #expect(tracker.update([snap(prompts: [prompt("p1")], active: true)], now: t0 + 1).isEmpty)
    }

    @Test func newPromptIsAnnouncedOnce() {
        var tracker = SessionAttentionTracker()
        _ = tracker.update([snap(active: true)], now: t0)
        let first = tracker.update([snap(prompts: [prompt("p1")], active: true)], now: t0 + 1)
        #expect(first == [.needsYou(sessionID: "a", request: prompt("p1"))])
        #expect(tracker.update([snap(prompts: [prompt("p1")], active: true)], now: t0 + 2).isEmpty)
        // Answered, then reloaded with the same id after a reconnect: no second alert.
        #expect(tracker.update([snap(active: true)], now: t0 + 3) == [.promptClosed(sessionID: "a", requestID: "p1")])
        #expect(tracker.update([snap(prompts: [prompt("p1")], active: true)], now: t0 + 4).isEmpty)
    }

    @Test func turnEndIsDelayedThenFinished() {
        var tracker = SessionAttentionTracker(settleDelay: 2)
        _ = tracker.update([snap()], now: t0)
        #expect(tracker.update([snap(active: true)], now: t0 + 1) == [.started(sessionID: "a")])
        #expect(tracker.update([snap()], now: t0 + 5).isEmpty)
        #expect(tracker.nextDeadline == t0 + 7)
        #expect(tracker.flush(now: t0 + 6).isEmpty)
        #expect(tracker.flush(now: t0 + 7) == [.finished(sessionID: "a")])
        #expect(tracker.flush(now: t0 + 20).isEmpty)
        #expect(tracker.nextDeadline == nil)
    }

    @Test func briefIdleBetweenStepsIsOneTurn() {
        var tracker = SessionAttentionTracker(settleDelay: 2)
        _ = tracker.update([snap(active: true)], now: t0)
        #expect(tracker.update([snap()], now: t0 + 1).isEmpty)
        // Back to work within the delay: no finished, no second started.
        #expect(tracker.update([snap(active: true)], now: t0 + 2).isEmpty)
        #expect(tracker.flush(now: t0 + 10).isEmpty)
        #expect(tracker.update([snap()], now: t0 + 11).isEmpty)
        #expect(tracker.flush(now: t0 + 13) == [.finished(sessionID: "a")])
    }

    @Test func turnThatEndsWithAPromptOpenIsNotFinished() {
        var tracker = SessionAttentionTracker(settleDelay: 1)
        _ = tracker.update([snap(prompts: [prompt("old")], active: true)], now: t0)
        #expect(tracker.update([snap(prompts: [prompt("old")])], now: t0 + 1).isEmpty)
        #expect(tracker.flush(now: t0 + 3).isEmpty)
    }

    @Test func failedTurnIsReportedAsFailed() {
        var tracker = SessionAttentionTracker(settleDelay: 1)
        _ = tracker.update([snap(active: true)], now: t0)
        #expect(tracker.update([snap(failed: true)], now: t0 + 1).isEmpty)
        #expect(tracker.update([snap(failed: true)], now: t0 + 2) == [.failed(sessionID: "a")])
    }

    @Test func failureWithoutSeenWorkIsStillReported() {
        var tracker = SessionAttentionTracker(settleDelay: 1)
        _ = tracker.update([snap()], now: t0)
        _ = tracker.update([snap(failed: true)], now: t0 + 1)
        #expect(tracker.flush(now: t0 + 2) == [.failed(sessionID: "a")])
    }

    @Test func removedSessionClosesPromptsAndCancelsEnd() {
        var tracker = SessionAttentionTracker(settleDelay: 1)
        _ = tracker.update([snap(active: true), snap("b", prompts: [prompt("p", session: "b")], active: true)], now: t0)
        _ = tracker.update([snap(), snap("b", prompts: [prompt("p", session: "b")], active: true)], now: t0 + 1)
        let events = tracker.update([], now: t0 + 1.5)
        #expect(events == [.promptClosed(sessionID: "b", requestID: "p")])
        #expect(tracker.flush(now: t0 + 5).isEmpty)
    }

    @Test func totalsCountSessionsNotPrompts() {
        let snapshots = [snap("a", prompts: [prompt("1"), prompt("2")], active: true), snap("b", active: true), snap("c")]
        let totals = SessionAttentionTotals.count(snapshots, extraNeedsYou: 2)
        #expect(totals == SessionAttentionTotals(needsYou: 3, running: 1))
        #expect(totals.badgeLabel == "3")
        #expect(SessionAttentionTotals(needsYou: 0).badgeLabel == "")
        #expect(SessionAttentionTotals(needsYou: 140).badgeLabel == "99+")
    }

    @Test func excerptDropsMarkdownAndCode() {
        let text = """
        ## Done

        All **42** tests pass. I changed `EventStream.swift`:
        ```swift
        let x = 1
        ```
        - Reconnects after sleep
        """
        #expect(SessionAttentionText.excerpt(text) == "Done All 42 tests pass. I changed EventStream.swift: Reconnects after sleep")
        let long = String(repeating: "word ", count: 80)
        let cut = SessionAttentionText.excerpt(long, limit: 30)
        #expect(cut.count <= 33)
        #expect(cut.hasSuffix("..."))
        #expect(SessionAttentionText.ask(prompt("x")) == "Allow this command? swift test")
    }
}

@Suite("Session marks")
@MainActor
struct SessionAttentionMarksTests {
    func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ens-marks-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("session-marks.json")
    }

    @Test func marksPersistAcrossInstances() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let marks = SessionAttentionMarks(fileURL: url)
        marks.setPinned("a", true)
        marks.setUnread("b", true)
        marks.setCompleted("c", true)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = SessionAttentionMarks(fileURL: url)
        #expect(reloaded.isPinned("a"))
        #expect(reloaded.isUnread("b"))
        #expect(reloaded.isCompleted("c"))
        #expect(!reloaded.isPinned("b"))
    }

    @Test func completingClearsUnreadAndForgetDropsEverything() {
        let marks = SessionAttentionMarks(fileURL: nil)
        marks.setUnread("a", true)
        marks.setPinned("a", true)
        marks.setCompleted("a", true)
        #expect(!marks.isUnread("a"))
        #expect(marks.isCompleted("a"))
        marks.forget("a")
        #expect(!marks.isPinned("a") && !marks.isCompleted("a"))
    }

    @Test func unreadableFileStartsEmpty() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let marks = SessionAttentionMarks(fileURL: url)
        #expect(marks.pinned.isEmpty && marks.unread.isEmpty && marks.completed.isEmpty)
    }
}

@Suite("Sidebar arrangement")
struct SidebarArrangementTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    func makeEntry(_ id: String, _ title: String, dir: String = "/a/app", hoursAgo: Double = 1, createdHoursAgo: Double = 10,
               status: SidebarRowStatus = .idle, pinned: Bool = false) -> SidebarEntry {
        SidebarEntry(id: id, title: title, directory: dir, created: now.addingTimeInterval(-createdHoursAgo * 3600),
                     updated: now.addingTimeInterval(-hoursAgo * 3600), status: status, pinned: pinned)
    }

    @Test func statusPriority() {
        #expect(SidebarRowStatus.resolve(prompts: 1, running: true, failed: true, unread: true, completed: true) == .needsYou)
        #expect(SidebarRowStatus.resolve(prompts: 0, running: true, failed: true, unread: true, completed: false) == .running)
        #expect(SidebarRowStatus.resolve(prompts: 0, running: false, failed: true, unread: true, completed: false) == .failed)
        #expect(SidebarRowStatus.resolve(prompts: 0, running: false, failed: true, unread: false, completed: true) == .completed)
        #expect(SidebarRowStatus.resolve(prompts: 0, running: false, failed: false, unread: true, completed: false) == .unread)
        #expect(SidebarRowStatus.resolve(prompts: 0, running: false, failed: false, unread: false, completed: false) == .idle)
    }

    @Test func pinnedComeFirstAndLeaveTheirGroup() {
        let entries = [makeEntry("1", "One", hoursAgo: 1), makeEntry("2", "Two", hoursAgo: 2, pinned: true), makeEntry("3", "Three", dir: "/a/site", hoursAgo: 3)]
        let result = SidebarArrangement.arrange(entries, grouping: .project, sort: .recent, now: now, calendar: calendar)
        #expect(result.pinned.map(\.id) == ["2"])
        #expect(result.groups.map(\.title) == ["app", "site"])
        #expect(result.groups[0].entries.map(\.id) == ["1"])
        #expect(result.order.map(\.id) == ["2", "1", "3"])
    }

    @Test func projectsSortByNameOrActivity() {
        let entries = [makeEntry("1", "b", dir: "/x/zeta", hoursAgo: 1), makeEntry("2", "a", dir: "/x/alpha", hoursAgo: 5),
                       makeEntry("3", "c", dir: "/x/alpha", hoursAgo: 9, createdHoursAgo: 0.5)]
        #expect(SidebarArrangement.arrange(entries, grouping: .project, sort: .recent).groups.map(\.title) == ["zeta", "alpha"])
        let byName = SidebarArrangement.arrange(entries, grouping: .project, sort: .name)
        #expect(byName.groups.map(\.title) == ["alpha", "zeta"])
        #expect(byName.groups[0].entries.map(\.title) == ["a", "c"])
        let byCreated = SidebarArrangement.arrange(entries, grouping: .project, sort: .created)
        #expect(byCreated.groups.map(\.title) == ["alpha", "zeta"])
        #expect(byCreated.groups[0].entries.map(\.id) == ["3", "2"])
    }

    @Test func groupByStateUsesFixedOrderAndFoldsFailedIntoNeedsYou() {
        let entries = [makeEntry("1", "Done", status: .completed), makeEntry("2", "Broke", status: .failed),
                       makeEntry("3", "Busy", status: .running), makeEntry("4", "Ask", hoursAgo: 0.1, status: .needsYou),
                       makeEntry("5", "New", status: .unread), makeEntry("6", "Quiet")]
        let result = SidebarArrangement.arrange(entries, grouping: .state, sort: .recent, now: now, calendar: calendar)
        #expect(result.groups.map(\.title) == ["Needs you", "Running", "Unread", "Idle", "Completed"])
        #expect(result.groups[0].entries.map(\.id) == ["4", "2"])
        #expect(result.groups.map(\.id).first == "state:needsYou")
    }

    @Test func groupByDate() {
        let entries = [makeEntry("1", "Now", hoursAgo: 0.5), makeEntry("2", "Yesterday", hoursAgo: 30),
                       makeEntry("3", "Week", hoursAgo: 24 * 5), makeEntry("4", "Month", hoursAgo: 24 * 20), makeEntry("5", "Old", hoursAgo: 24 * 90)]
        // Noon UTC so "0.5 hours ago" is still today.
        let noon = Date(timeIntervalSince1970: 1_800_014_400)
        let shifted = entries.map { e -> SidebarEntry in
            var e = e
            e.updated = e.updated.addingTimeInterval(noon.timeIntervalSince(now))
            return e
        }
        let result = SidebarArrangement.arrange(shifted, grouping: .date, sort: .recent, now: noon, calendar: calendar)
        #expect(result.groups.map(\.title) == ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"])
    }

    @Test func searchMatchesTitleOrFolder() {
        let e = makeEntry("1", "Fix the login", dir: "/Users/x/portfolio-site")
        #expect(e.matches("LOGIN"))
        #expect(e.matches("portfolio"))
        #expect(e.matches(" "))
        #expect(!e.matches("astro"))
    }
}

@Suite("Session attention from the store")
@MainActor
struct SessionAttentionStoreTests {
    @Test func snapshotsFoldSubagentsIntoTheirSession() {
        let store = SessionStore(engine: PreviewEngine(delayScale: 0))
        store.seed(PreviewData.seed())
        let snapshots = store.attentionSnapshots()
        let ids = Set(snapshots.map(\.id))
        #expect(!ids.contains(PreviewData.childSessionID))
        let main = snapshots.first { $0.id == PreviewData.mainSessionID }
        #expect(main?.needsYou == true)
        #expect(main?.active == true)
        #expect(main?.working == false)
        #expect(snapshots.first { $0.id == "ses_sse_reconnect" }?.working == true)
        #expect(snapshots.first { $0.id == "ses_rate_limit" }?.failed == true)

        let marks = SessionAttentionMarks(fileURL: nil)
        marks.setPinned("ses_readme", true)
        marks.setUnread("ses_readme", true)
        marks.setCompleted("ses_rate_limit", true)
        let entries = Dictionary(uniqueKeysWithValues: store.sidebarEntries(marks: marks).map { ($0.id, $0) })
        #expect(entries[PreviewData.mainSessionID]?.status == .needsYou)
        #expect(entries["ses_sse_reconnect"]?.status == .running)
        #expect(entries["ses_readme"]?.status == .unread)
        #expect(entries["ses_readme"]?.pinned == true)
        #expect(entries["ses_rate_limit"]?.status == .completed)
        #expect(store.lastAgentText(PreviewData.mainSessionID) != nil)
    }
}
