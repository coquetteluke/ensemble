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

/// The Mac Session Hub's buckets (`HubSorter`): every attention state, plans and questions, rooms and archived sessions.
@Suite struct HubSorterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func card(_ id: String = UUID().uuidString, kind: HubCandidate.Kind = .session, hoursAgo: Double,
              requests: [PermissionRequest] = [], decision: RoomDecision? = nil, paused: Bool = false,
              running: Bool = false, failed: Bool = false, question: Bool = false, unread: Bool = false,
              completed: Bool = false, archived: Bool = false) -> HubCandidate {
        HubCandidate(id: id, kind: kind, lastActivity: now.addingTimeInterval(-hoursAgo * 3600), requests: requests,
                     roomDecision: decision, roomPausedForUser: paused, running: running, failed: failed,
                     endedWithQuestion: question, unread: unread, completed: completed, archived: archived)
    }

    func prompt(_ title: String = "swift test", kind: String = "bash") -> PermissionRequest {
        PermissionRequest(id: UUID().uuidString, sessionID: "s", kind: kind, title: title)
    }

    let plan = PermissionRequest(id: "plan", sessionID: "s", kind: InteractionKind.plan, title: "Plan",
                                 plan: PlanProposal(markdown: "# Add a ring\n1. Draw it", proceedMode: .acceptEdits))

    let question = PermissionRequest(id: "q", sessionID: "s", kind: InteractionKind.question, title: "Which colour?",
                                     questions: [AgentQuestion(id: "c", text: "Which colour?",
                                                               options: [.init(label: "Red"), .init(label: "Blue")])])

    // MARK: Needs you

    @Test func openPromptsAreNeedsYouWhileRunningAndAtAnyAge() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 0.1, requests: [prompt()], running: true), now: now) == .needsYou)
        #expect(HubSorter.bucket(for: card(hoursAgo: 30 * 24, requests: [prompt()]), now: now) == .needsYou)
        // A prompt beats the completed mark.
        #expect(HubSorter.bucket(for: card(hoursAgo: 1, requests: [prompt()], completed: true), now: now) == .needsYou)
    }

    @Test func plansAndQuestionsAreNeedsYouWithTheirOwnReason() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 2, requests: [plan]), now: now) == .needsYou)
        #expect(HubSorter.reason(for: card(hoursAgo: 2, requests: [plan]), now: now) == .plan(plan))
        #expect(HubSorter.bucket(for: card(hoursAgo: 2, requests: [question], running: true), now: now) == .needsYou)
        #expect(HubSorter.reason(for: card(hoursAgo: 2, requests: [question]), now: now) == .question(question))
        let bash = prompt()
        #expect(HubSorter.reason(for: card(hoursAgo: 2, requests: [bash, plan]), now: now) == .permission(bash))
    }

    @Test func failedAndAskedAreNeedsYouForAWeek() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 2, failed: true), now: now) == .needsYou)
        #expect(HubSorter.reason(for: card(hoursAgo: 2, failed: true), now: now) == .failed)
        #expect(HubSorter.bucket(for: card(hoursAgo: 6 * 24, question: true), now: now) == .needsYou)
        #expect(HubSorter.reason(for: card(hoursAgo: 6 * 24, question: true), now: now) == .askedQuestion)
        #expect(HubSorter.bucket(for: card(hoursAgo: 8 * 24, failed: true), now: now) == .old)
        #expect(HubSorter.bucket(for: card(hoursAgo: 8 * 24, question: true), now: now) == .old)
    }

    @Test func completedFailureLeavesNeedsYou() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 2, failed: true, completed: true), now: now) == .old)
        #expect(HubSorter.reason(for: card(hoursAgo: 2, failed: true, completed: true), now: now) == .completed)
    }

    // MARK: Running, Finished, Old

    @Test func workingIsRunning() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 0.2, running: true), now: now) == .running)
        // Running wins over a completed mark and an earlier failure.
        #expect(HubSorter.bucket(for: card(hoursAgo: 0.2, running: true, failed: true, completed: true), now: now) == .running)
    }

    @Test func recentAndUnreadAreFinished() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 2 * 24), now: now) == .finished)
        #expect(HubSorter.reason(for: card(hoursAgo: 2 * 24), now: now) == .finished)
        #expect(HubSorter.bucket(for: card(hoursAgo: 5 * 24, unread: true), now: now) == .finished)
        #expect(HubSorter.reason(for: card(hoursAgo: 5 * 24, unread: true), now: now) == .unread)
    }

    @Test func olderOrCompletedIsOld() {
        #expect(HubSorter.bucket(for: card(hoursAgo: 4 * 24), now: now) == .old)
        #expect(HubSorter.reason(for: card(hoursAgo: 4 * 24), now: now) == .quiet)
        #expect(HubSorter.bucket(for: card(hoursAgo: 1, completed: true), now: now) == .old)
        #expect(HubSorter.bucket(for: card(hoursAgo: 1, unread: true, completed: true), now: now) == .old)
    }

    @Test func archivedOnlyWhenAskedForAndThenOld() {
        let archived = card(hoursAgo: 1, requests: [prompt()], running: true, archived: true)
        #expect(HubSorter.bucket(for: archived, now: now) == nil)
        #expect(HubSorter.bucket(for: archived, now: now, showArchived: true) == .old)
        #expect(HubSorter.reason(for: archived, now: now) == .archived)
    }

    // MARK: Rooms

    @Test func roomsWaitingOnTheUserAreNeedsYou() {
        let approve = card(kind: .room, hoursAgo: 0.5, decision: .approvePlan)
        #expect(HubSorter.bucket(for: approve, now: now) == .needsYou)
        #expect(HubSorter.reason(for: approve, now: now) == .roomDecision(.approvePlan))
        let capped = card(kind: .room, hoursAgo: 40 * 24, paused: true)
        #expect(HubSorter.bucket(for: capped, now: now) == .needsYou)
        #expect(HubSorter.reason(for: capped, now: now) == .roomPaused)
        // An agent's prompt in a running room.
        #expect(HubSorter.bucket(for: card(kind: .room, hoursAgo: 0.1, requests: [prompt()], running: true), now: now) == .needsYou)
        // A decision beats a completed mark.
        #expect(HubSorter.bucket(for: card(kind: .room, hoursAgo: 1, decision: .judge, completed: true), now: now) == .needsYou)
    }

    @Test func roomsRunFinishAndAge() {
        #expect(HubSorter.bucket(for: card(kind: .room, hoursAgo: 0.1, running: true), now: now) == .running)
        #expect(HubSorter.bucket(for: card(kind: .room, hoursAgo: 5), now: now) == .finished)
        #expect(HubSorter.bucket(for: card(kind: .room, hoursAgo: 5, completed: true), now: now) == .old)
        #expect(HubSorter.bucket(for: card(kind: .room, hoursAgo: 10 * 24), now: now) == .old)
    }

    @Test func decisionTextNamesTheAgent() {
        let id = UUID()
        let name: (UUID) -> String? = { $0 == id ? "Sonnet" : nil }
        #expect(HubSorter.decisionText(.approvePlan, agentName: name) == "Approve the lead's plan")
        #expect(HubSorter.decisionText(.takeover(agentID: id), agentName: name) == "Sonnet offers to take over")
        #expect(HubSorter.decisionText(.mergeConflict(agentID: id, files: ["a", "b"]), agentName: name)
                == "Merge conflict in Sonnet's piece, 2 files")
        #expect(HubSorter.decisionText(.reviewStalemate(agentID: UUID()), agentName: name) == "Review stuck on an agent's piece")
    }

    // MARK: Board and quick actions

    @Test func arrangeOrdersBucketsAndNewestFirst() {
        let a = card("a", hoursAgo: 5)
        let b = card("b", hoursAgo: 1)
        let c = card("c", hoursAgo: 3, requests: [prompt()])
        let d = card("d", hoursAgo: 0.1, running: true)
        let e = card("e", hoursAgo: 9 * 24)
        let f = card("f", hoursAgo: 1, archived: true)
        let board = HubSorter.arrange([a, b, c, d, e, f], now: now)
        #expect(board.map(\.bucket) == [.needsYou, .running, .finished, .old])
        #expect(board.first { $0.bucket == .finished }?.items.map(\.id) == ["b", "a"])
        #expect(!board.flatMap(\.items).contains { $0.id == "f" })
        let withArchived = HubSorter.arrange([a, f], now: now, showArchived: true)
        #expect(withArchived.map(\.bucket) == [.finished, .old])
        #expect(HubSorter.arrange([], now: now).isEmpty)
    }

    @Test func quickApprovalOnlyForShortSingleLinePrompts() {
        #expect(HubSorter.allowsQuickApproval(prompt("swift test --parallel")))
        #expect(!HubSorter.allowsQuickApproval(prompt("rm -rf build\nrm -rf ~")))
        #expect(!HubSorter.allowsQuickApproval(prompt(String(repeating: "a", count: 200))))
        #expect(!HubSorter.allowsQuickApproval(prompt("echo hi\u{202E}")))
        #expect(!HubSorter.allowsQuickApproval(plan))
        #expect(!HubSorter.allowsQuickApproval(question))
    }

    @Test func asksSomethingReadsTheLastLine() {
        #expect(HubSorter.asksSomething("Done.\n\nShould I also update the README?"))
        #expect(HubSorter.asksSomething("Want me to push it?**"))
        #expect(!HubSorter.asksSomething("What changed?\n\nAll tests pass."))
        #expect(!HubSorter.asksSomething(nil))
        #expect(!HubSorter.asksSomething("   "))
    }
}
