import Foundation
import Testing
@testable import EnsembleKit

/// How a room on the Mac looks on the phone, and the phone's answers carried out through the room engine.
@Suite @MainActor struct RemoteRoomBridgeTests {
    func state(_ mode: RoomMode = .team, _ names: [String] = ["Alpha", "Beta", "Gamma"]) -> RoomState {
        RoomState(spec: RoomFixtures.spec(mode, names, permission: .ask))
    }

    @Test func roomMapsStateAgentsPromptsAndUsage() {
        var s = state()
        let alpha = s.spec.agents[0].id, beta = s.spec.agents[1].id
        s.sessions = [alpha: "ses_a", beta: "ses_b"]
        s.phase = .working
        s.cappedAgents = [beta]
        s.usage = [alpha: Usage(inputTokens: 10, outputTokens: 5, costUSD: 0.25)]
        let late = PermissionRequest(id: "p2", sessionID: "ses_b", kind: "bash", title: "ls", created: Date(timeIntervalSince1970: 20))
        let early = PermissionRequest(id: "p1", sessionID: "ses_child", kind: "edit", title: "a.swift", created: Date(timeIntervalSince1970: 10))

        let room = RemoteRoomBridge.room(s, activity: [alpha: .working], permissions: [late, early], running: true)
        #expect(room.id == s.spec.id)
        #expect(room.sessionID == s.spec.id.uuidString)
        #expect(room.state == .running)
        #expect(room.phaseLabel == "Working")
        #expect(room.agents.map(\.activity) == [.working, .idle, .idle])
        #expect(room.agents.map(\.capped) == [nil, true, nil])
        #expect(room.agents.map(\.sessionID) == ["ses_a", "ses_b", nil])
        #expect(room.permissions.map(\.id) == ["p1", "p2"])
        #expect(room.usage.costUSD == 0.25)
        #expect(room.leadAgentID == alpha)
        #expect(room.decision == nil)

        s.isPaused = true
        s.pauseReason = "Paused."
        let paused = RemoteRoomBridge.room(s, running: false)
        #expect(paused.state == .paused && paused.phaseLabel == "Paused" && paused.pauseReason == "Paused.")
        s.phase = .stopped
        s.isPaused = false
        #expect(RemoteRoomBridge.room(s).state == .stopped)
    }

    @Test func planDecisionShowsThePlanAndItsAssignments() throws {
        var s = state()
        let ids = s.spec.agents.map(\.id)
        s.phase = .awaitingApproval
        s.pendingDecision = .approvePlan
        s.plan = "Build a calculator.\nASSIGN @Alpha: Calc.swift\nASSIGN @Beta: tests"
        s.assignments = [Assignment(agentID: ids[0], task: "Calc.swift"), Assignment(agentID: ids[1], task: "tests")]
        let decision = try #require(RemoteRoomBridge.decision(for: s))
        #expect(decision.kind == .approvePlan)
        #expect(decision.title == "The plan is ready")
        #expect(decision.text == "Build a calculator.")
        #expect(decision.items == [.init(agentID: ids[0], text: "Calc.swift"), .init(agentID: ids[1], text: "tests")])
        #expect(decision.choices.map(\.id) == ["approve", "redo"])
        #expect(decision.choices[1].input == .optional)
        #expect(decision.needsYou)

        // Another plan (or another run) is another decision.
        var changed = s
        changed.plan = "Build a different calculator."
        #expect(RemoteRoomBridge.decision(for: changed)?.id != decision.id)
        var nextRun = s
        nextRun.run += 1
        #expect(RemoteRoomBridge.decision(for: nextRun)?.id != decision.id)
        #expect(RemoteRoomBridge.decision(for: s)?.id == decision.id)

        // No Redo when the user leads (no lead to send it back to).
        s.userIsLead = true
        #expect(RemoteRoomBridge.decision(for: s)?.choices.map(\.id) == ["approve"])
    }

    @Test func everyDecisionKindHasItsChoices() throws {
        let base = state()
        let ids = base.spec.agents.map(\.id)
        var s = base

        s.pendingDecision = .writePlan
        let write = try #require(RemoteRoomBridge.decision(for: s))
        #expect(write.choices.first?.input == .required)
        #expect(write.choices.first?.template?.contains("ASSIGN @Gamma: ") == true)

        s.assignments = [Assignment(agentID: ids[0], task: "x", reviewerID: ids[1], lastReview: "CHANGES: add tests", branch: "ensemble/r/alpha")]
        s.pendingDecision = .reviewStalemate(agentID: ids[0])
        let review = try #require(RemoteRoomBridge.decision(for: s))
        #expect(review.title == "Beta still asks for changes to Alpha's piece after \(RoomEngine.maxFixRounds) fix rounds")
        #expect(review.text == "CHANGES: add tests")
        #expect(review.choices.map(\.id) == ["approvePiece", "anotherRound", "dropPiece"])
        #expect(review.choices.last?.style == .destructive)

        s.pendingDecision = .mergeConflict(agentID: ids[0], files: ["Calc.swift"])
        s.git = GitContext(isRepository: true, baseBranch: "main")
        let merge = try #require(RemoteRoomBridge.decision(for: s))
        #expect(merge.title == "Merging ensemble/r/alpha into main stopped")
        #expect(merge.items == [.init(text: "Calc.swift")])
        #expect(merge.note == "Resolve it on the Mac in ensemble-room-test, commit, then continue.")
        #expect(merge.choices.map(\.id) == ["continueMerge"])

        var rt = state(.roundTable)
        let rids = rt.spec.agents.map(\.id)
        rt.roundTable = RoundTableState(order: rids)
        rt.roundTable?.builderID = rids[0]
        rt.roundTable?.reviews[rids[1]] = .takeover("The tests keep failing.")
        rt.pendingDecision = .takeover(agentID: rids[1])
        let takeover = try #require(RemoteRoomBridge.decision(for: rt))
        #expect(takeover.title == "Beta offers to take over building from Alpha")
        #expect(takeover.text == "The tests keep failing.")
        #expect(takeover.choices.map(\.label) == ["Accept", "Keep Alpha"])

        var debate = state(.debate)
        debate.debate = DebateState(question: "REST or GraphQL?")
        debate.pendingDecision = .judge
        let judge = try #require(RemoteRoomBridge.decision(for: debate))
        #expect(judge.text == "REST or GraphQL?")
        #expect(judge.choices.first?.input == .required)

        // A verdict waits on nobody, so it is not needs you.
        debate.pendingDecision = nil
        debate.phase = .verdict
        debate.debate?.verdict = "REST."
        let verdict = try #require(RemoteRoomBridge.decision(for: debate))
        #expect(verdict.kind == .verdict && !verdict.needsYou)
        #expect(verdict.choices.map(\.id) == ["buildIt", "debateAgain"])
        let row = RemoteRoomBridge.hubRow(RemoteRoomBridge.room(debate))
        #expect(row.pendingAsk == nil && row.pendingPermissions == 0)
    }

    @Test func transcriptCarriesTheBoardThreadThenThePrompts() {
        var s = state()
        let ids = s.spec.agents.map(\.id)
        s.board = [
            BoardMessage(from: .user, kind: .chat, text: "Build it"),
            BoardMessage(from: .room, kind: .notice, text: "Alpha leads."),
            BoardMessage(from: .agent(ids[0]), to: [ids[1]], kind: .chat, text: "Beta, take the tests."),
            BoardMessage(from: .user, to: [ids[1]], kind: .chat, text: "and docs"),
        ]
        let ask = PermissionRequest(id: "p", sessionID: "ses_b", kind: "bash", title: "swift test")
        let items = RemoteRoomBridge.transcriptItems(s, permissions: [ask])
        #expect(items.count == 5)
        guard case .user(_, "Build it", _) = items[0], case .notice(_, "Alpha leads.") = items[1],
              case .board(_, ids[0], [ids[1]], "Beta, take the tests.", _) = items[2],
              case .user(_, "@Beta and docs", _) = items[3], case .permission(ask) = items[4] else {
            Issue.record("Unexpected items: \(items)")
            return
        }
        // Long boards keep the newest messages and say how many stayed on the Mac.
        s.board = (0..<(RemoteRoomBridge.transcriptLimit + 3)).map { BoardMessage(from: .room, kind: .notice, text: "n\($0)") }
        let long = RemoteRoomBridge.transcriptItems(s, permissions: [])
        #expect(long.count == RemoteRoomBridge.transcriptLimit + 1)
        if case .notice(_, let text) = long[0] { #expect(text == "3 earlier messages are on the Mac.") } else { Issue.record("no notice") }
    }

    @Test func hubRowSortsWaitingRoomsIntoNeedsYou() {
        var s = state()
        s.phase = .awaitingApproval
        s.pendingDecision = .approvePlan
        // Even while agents work, a decision keeps the room in Needs you.
        let row = RemoteRoomBridge.hubRow(RemoteRoomBridge.room(s, running: true))
        #expect(row.pendingAsk == "The plan is ready")
        #expect(HubBoard.bucket(for: row) == .needsYou)

        var idle = state()
        idle.board = [BoardMessage(from: .room, kind: .notice, text: "Finished.")]
        let quiet = RemoteRoomBridge.hubRow(RemoteRoomBridge.room(idle))
        #expect(quiet.pendingAsk == nil && HubBoard.bucket(for: quiet) == .finished)

        let ask = PermissionRequest(id: "p", sessionID: "ses_a", kind: "bash", title: "npm test")
        let prompt = RemoteRoomBridge.hubRow(RemoteRoomBridge.room(idle, permissions: [ask], running: true))
        #expect(prompt.pendingAsk == "Approve: npm test")
        #expect(prompt.activity == .working && HubBoard.bucket(for: prompt) == .needsYou)

        var capped = idle
        capped.isPaused = true
        capped.pauseReason = "Every agent reached its spending cap."
        let cappedRow = RemoteRoomBridge.hubRow(RemoteRoomBridge.room(capped), pausedForUser: true)
        #expect(cappedRow.pendingAsk == "Every agent reached its spending cap.")
        #expect(HubBoard.bucket(for: cappedRow) == .needsYou)
    }

    // MARK: Answers through the engine

    func teamAwaitingApproval() async throws -> (RoomEngine, FakeEngine) {
        let fake = FakeEngine()
        fake.on("Alpha", "Task for the room", reply: "PLAN: Build a calculator.\nASSIGN @Alpha: Calc.swift\nASSIGN @Beta: tests")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.team, ["Alpha", "Beta"], permission: .ask), fake: fake)
        await engine.start(task: "Build a small calculator.")
        try await engine.waitFor("plan approval", fake: fake) { $0.state.pendingDecision == .approvePlan }
        return (engine, fake)
    }

    @Test func approveFromThePhoneStartsTheWork() async throws {
        let (engine, fake) = try await teamAwaitingApproval()
        defer { engine.close() }
        let decision = try #require(RemoteRoomBridge.decision(for: engine.state))
        try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: engine.state.id, decisionID: decision.id, choice: "approve"),
                                          engine: engine)
        #expect(engine.state.pendingDecision == nil)
        #expect(engine.state.phase == .working)
        try await engine.waitFor("assignments", fake: fake) { _ in fake.sent.contains { $0.text.contains("Your assignment") } }

        // The same answer again: that decision is gone.
        await #expect(throws: RemoteError.self) {
            try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: engine.state.id, decisionID: decision.id, choice: "approve"),
                                              engine: engine)
        }
    }

    @Test func redoSendsTheFeedbackToTheLead() async throws {
        let (engine, fake) = try await teamAwaitingApproval()
        defer { engine.close() }
        fake.on("Alpha", "Split the tests", reply: "PLAN: Smaller.\nASSIGN @Alpha: Calc.swift\nASSIGN @Beta: tests")
        let decision = try #require(RemoteRoomBridge.decision(for: engine.state))
        try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: engine.state.id, decisionID: decision.id, choice: "redo",
                                                                  text: "  Split the tests  "), engine: engine)
        #expect(engine.state.board.contains { $0.from == .user && $0.text == "Split the tests" })
        try await engine.waitFor("the new plan", fake: fake) { $0.state.pendingDecision == .approvePlan && $0.state.plan?.contains("Smaller") == true }
        #expect(RemoteRoomBridge.decision(for: engine.state)?.id != decision.id)
    }

    @Test func wrongIDsChoicesAndMissingTextAreRefused() async throws {
        let (engine, _) = try await teamAwaitingApproval()
        defer { engine.close() }
        let decision = try #require(RemoteRoomBridge.decision(for: engine.state))
        let room = engine.state.id
        await #expect(throws: RemoteError.self) {
            try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: room, decisionID: "approvePlan-0", choice: "approve"), engine: engine)
        }
        await #expect(throws: RemoteError.self) {
            try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: room, decisionID: decision.id, choice: "dropPiece"), engine: engine)
        }
        await #expect(throws: RemoteError.self) {
            try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: room, decisionID: decision.id, choice: "continueMerge"), engine: engine)
        }
        #expect(engine.state.pendingDecision == .approvePlan)
        #expect(engine.state.phase == .awaitingApproval)
    }

    @Test func aPlanWithoutAssignmentsIsRefusedWithTheRoomsReason() async throws {
        let fake = FakeEngine()
        let spec = RoomFixtures.spec(.team, ["Alpha", "Beta"], lead: nil, permission: .ask)
        let engine = try await RoomFixtures.engine(spec, fake: fake)
        defer { engine.close() }
        engine.takeOver()
        await engine.start(task: "Build it.")
        try await engine.waitFor("write plan") { $0.state.pendingDecision == .writePlan }
        let decision = try #require(RemoteRoomBridge.decision(for: engine.state))
        await #expect(throws: RemoteError.self) {
            try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: spec.id, decisionID: decision.id, choice: "submitPlan"),
                                              engine: engine)
        }
        do {
            try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: spec.id, decisionID: decision.id, choice: "submitPlan",
                                                                      text: "PLAN: no owners"), engine: engine)
            Issue.record("A plan without ASSIGN lines was taken")
        } catch let error as RemoteError {
            #expect(error.code == .failed)
            #expect(error.message == "The plan needs at least one ASSIGN @Name: line.")
        }
        try await RemoteRoomBridge.decide(RemoteRoomDecisionReply(roomID: spec.id, decisionID: decision.id, choice: "submitPlan",
                                                                  text: "PLAN: split\nASSIGN @Alpha: a\nASSIGN @Beta: b"), engine: engine)
        #expect(engine.state.pendingDecision == nil)
    }
}
