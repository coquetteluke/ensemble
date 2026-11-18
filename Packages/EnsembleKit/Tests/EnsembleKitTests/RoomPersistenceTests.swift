import Foundation
import Testing
@testable import EnsembleKit

@Suite @MainActor struct RoomPersistenceTests {
    /// A state with every optional part filled in.
    func richState() -> RoomState {
        let spec = RoomFixtures.spec(.roundTable, ["Alpha", "Beta"], permission: .bypass, caps: ["Beta": 2.5])
        let a = spec.agents[0].id, b = spec.agents[1].id
        var state = RoomState(spec: spec)
        state.runMode = .team
        state.briefedMode = .roundTable
        state.run = 3
        state.sessions = [a: "ses_1", b: "ses_2"]
        state.board = [
            BoardMessage(from: .user, kind: .chat, text: "Build it"),
            BoardMessage(from: .agent(a), to: [b], kind: .question, round: 2, text: "which file?"),
            BoardMessage(from: .room, kind: .notice, text: "Paused."),
        ]
        state.phase = .working
        state.isPaused = true
        state.pauseReason = "Paused."
        state.task = "Build it"
        state.plan = "PLAN: x"
        state.assignments = [
            Assignment(agentID: a, task: "a", status: .inReview, reviewerID: b, fixRounds: 1, lastReview: "fix it",
                       branch: "ensemble/r/alpha", worktreePath: "/tmp/w/a", changedFiles: ["A.swift"]),
        ]
        state.debate = DebateState(question: "q", round: 2, totalRounds: 2,
                                   arguments: [DebateArgument(round: 1, agentID: a, text: "yes")], judgeID: a, verdict: "yes")
        var rt = RoundTableState(order: [a, b])
        rt.agreed = [a]
        rt.lastProposal = [a: "plan a"]
        rt.reviews = [b: .changes("more tests"), a: .takeover("me")]
        rt.builderID = b
        state.roundTable = rt
        state.pendingDecision = .mergeConflict(agentID: a, files: ["X.swift"])
        state.usage = [a: Usage(inputTokens: 10, outputTokens: 5, costUSD: 0.123456789)]
        state.cappedAgents = [b]
        state.userIsLead = true
        state.git = GitContext(isRepository: true, baseBranch: "main")
        state.duties = [a: [Duty(purpose: .review(authorID: b), retried: true), Duty(purpose: .argue(round: 2))]]
        state.outbox = [b: [OutgoingMessage(channel: .prompt, text: "hi", duty: .work, nudge: .plan)]]
        state.interruptedAgents = [a]
        return state
    }

    @Test func inMemoryRoundTrip() throws {
        let store = InMemoryRoomStore()
        let state = richState()
        try store.save(state)
        #expect(try store.load(state.id) == state)
        #expect(try store.list().map(\.id) == [state.id])
        try store.delete(state.id)
        #expect(try store.load(state.id) == nil)
    }

    @Test func fileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-rooms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileRoomStore(directory: dir)
        let state = richState()
        try store.save(state)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(state.id.uuidString).json").path))
        #expect(try store.load(state.id) == state)

        var other = RoomState(spec: RoomFixtures.spec(.solo, ["Solo"]))
        other.spec.created = state.spec.created.addingTimeInterval(10)
        try store.save(other)
        #expect(try store.list().map(\.id) == [state.id, other.id])
        try store.delete(state.id)
        #expect(try store.list().map(\.id) == [other.id])
        #expect(try store.load(UUID()) == nil)
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        let path = FileRoomStore.defaultDirectory.path
        #expect(path.hasSuffix("Application Support/Ensemble/rooms"))
    }

    @Test func olderFilesWithMissingFieldsStillLoad() throws {
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"])
        let specJSON = try JSONEncoder().encode(spec)
        let json = "{\"spec\":\(String(decoding: specJSON, as: UTF8.self)),\"phase\":\"verdict\"}"
        let state = try JSONDecoder().decode(RoomState.self, from: Data(json.utf8))
        #expect(state.phase == .verdict)
        #expect(state.runMode == .debate)
        #expect(state.board.isEmpty)
    }

    @Test func engineSavesEveryChange() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Spaces.")
        let store = InMemoryRoomStore()
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1)
        let engine = try await RoomFixtures.engine(spec, fake: fake, store: store)
        #expect(try store.load(spec.id)?.sessions.count == 2)
        await engine.start(task: "Tabs or spaces?")
        try await engine.waitFor("verdict", fake: fake) { $0.state.phase == .verdict }
        let saved = try #require(try store.load(spec.id))
        #expect(saved == engine.state)
        #expect(saved.debate?.verdict == "Spaces.")
        #expect(store.saveCount > 10)
    }

    @Test func reloadedRunningRoomComesBackPausedAndResumes() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Round 1 of 1", reply: "Tabs.")
        fake.on("Beta", "Round 1 of 1", reply: "Spaces.", hold: true)
        fake.on("Beta", "The room resumed", reply: "Spaces, still.")
        fake.on("Alpha", "You are the judge", reply: "VERDICT: Spaces.")
        let store = InMemoryRoomStore()
        let spec = RoomFixtures.spec(.debate, ["Alpha", "Beta"], rounds: 1)
        let first = try await RoomFixtures.engine(spec, fake: fake, store: store)
        await first.start(task: "Tabs or spaces?")
        try await first.waitFor("Alpha's argument and Beta working", fake: fake) { engine in
            engine.state.debate?.arguments.count == 1 && fake.isHeld("Beta")
        }

        // Ensemble quits: the first engine stops listening; Beta's turn finishes unseen.
        first.close()
        await fake.release("Beta")

        let second = try #require(try RoomEngine.load(roomID: spec.id, api: fake, store: store))
        let beta = second.id(of: "Beta")
        #expect(second.state.isPaused)
        #expect(second.state.phase == .debating)
        #expect(second.state.interruptedAgents == [beta])
        #expect(second.notices.last == "Paused because Ensemble closed during the run. Resume to continue.")

        await second.resume()
        try await second.waitFor("verdict", fake: fake) { $0.state.phase == .verdict }
        #expect(second.state.debate?.arguments.map(\.text) == ["Tabs.", "Spaces, still."])
        #expect(try store.load(spec.id) == second.state)
    }
}
