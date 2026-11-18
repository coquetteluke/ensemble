import Foundation
import Testing
@testable import EnsembleKit

@Suite struct HubBucketingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ activity: SessionActivity, hoursAgo: Double, permissions: Int = 0, question: Bool = false,
                 ask: String? = nil, archived: Bool = false, doneHoursAgo: Double? = nil) -> SessionSummary {
        SessionSummary(id: UUID().uuidString, title: "t", directory: "/tmp", activity: activity,
                       lastActivity: now.addingTimeInterval(-hoursAgo * 3600), pendingAsk: ask,
                       pendingPermissions: permissions, endedWithQuestion: question, archived: archived,
                       markedDoneAt: doneHoursAgo.map { now.addingTimeInterval(-$0 * 3600) })
    }

    @Test func permissionPromptIsNeedsYouEvenWhileWorking() {
        #expect(HubBoard.bucket(for: session(.working, hoursAgo: 0.1, permissions: 1), now: now) == .needsYou)
        #expect(HubBoard.bucket(for: session(.waitingForPermission, hoursAgo: 30 * 24), now: now) == .needsYou)
    }

    @Test func workingIsRunning() {
        #expect(HubBoard.bucket(for: session(.working, hoursAgo: 0.5), now: now) == .running)
    }

    @Test func questionWithinAWeekIsNeedsYou() {
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 6 * 24, question: true), now: now) == .needsYou)
        #expect(HubBoard.bucket(for: session(.failed, hoursAgo: 2), now: now) == .needsYou)
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 1, ask: "Pick an API"), now: now) == .needsYou)
    }

    @Test func oldQuestionDropsToOld() {
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 8 * 24, question: true), now: now) == .old)
    }

    @Test func quietRecentSessionIsFinishedThenOld() {
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 2 * 24), now: now) == .finished)
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 4 * 24), now: now) == .old)
    }

    @Test func archivedAndMarkedDoneLeaveTheBoard() {
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 1, question: true, archived: true), now: now) == nil)
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 3, question: true, doneHoursAgo: 1), now: now) == nil)
        // New activity after "mark done" brings it back.
        #expect(HubBoard.bucket(for: session(.idle, hoursAgo: 1, question: true, doneHoursAgo: 3), now: now) == .needsYou)
    }

    @Test func groupSortsNewestFirst() {
        let a = session(.idle, hoursAgo: 5)
        let b = session(.idle, hoursAgo: 1)
        let groups = HubBoard.group([a, b], now: now)
        #expect(groups[.finished]?.map(\.id) == [b.id, a.id])
    }
}
