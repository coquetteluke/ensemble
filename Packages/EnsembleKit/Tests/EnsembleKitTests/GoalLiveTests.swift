#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Goal mode against the real OpenCode service and the mock model (`tools/mock-llm`). Runs with `ENSEMBLE_LIVE_TESTS=1`
/// (see `scripts/test-live.sh`). The mock answers GOAL NOT MET to the first turn and GOAL MET to the next, or GOAL NOT
/// MET every time for the budget test.
@MainActor
@Suite(.serialized, .enabled(if: LiveConfig.enabled))
struct GoalLiveTests {
    static let model = ModelRef(providerID: "mock", id: "mock-1")

    /// Adds this suite's rules ahead of the harness's copy of the mock script (the mock reloads it when it changes).
    static func addRules(_ h: LiveHarness) async throws {
        let url = h.directory.appendingPathComponent(".mock-script.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rules = json["rules"] as? [[String: Any]] ?? []
        rules.insert(contentsOf: [
            // Budget: never met.
            ["match": ["budget marker never met"], "text": "Still not there.\nGOAL NOT MET: the budget marker is never met."],
            // Sessions: the second turn meets the goal.
            ["match": ["keep working toward the goal"], "text": "Made the file.\nGOAL MET: goal-marker.txt exists."],
            ["match": ["keep working until this goal is met"], "text": "Looked around.\nGOAL NOT MET: goal-marker.txt is missing."],
            // Rooms: the check after the second run meets the goal.
            ["match": ["goal check after run 1"], "text": "Checked.\nGOAL NOT MET: the room marker needs one more run."],
            ["match": ["goal check after run 2"], "text": "Checked again.\nGOAL MET: the room marker is built."],
            ["match": ["goal: the room marker"], "text": "Worked on the room marker."],
        ] as [[String: Any]], at: 0)
        json["rules"] = rules
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: url)
        try await Task.sleep(for: .milliseconds(300))
    }

    /// A store on the live client, fed by its own event stream (without `start()`, which would touch every session
    /// on the service).
    static func store(_ h: LiveHarness) async throws -> (SessionStore, Task<Void, Never>) {
        let store = SessionStore(engine: h.client)
        let stream = h.client.events()
        let task = Task { @MainActor in for await event in stream { store.apply(event) } }
        try await Task.sleep(for: .milliseconds(500))
        return (store, task)
    }

    func withHarness(_ body: (LiveHarness) async throws -> Void) async throws {
        let harness = try await LiveHarness.start()
        do {
            try await Self.addRules(harness)
            try await body(harness)
        } catch {
            await harness.cleanup()
            throw error
        }
        await harness.cleanup()
    }

    func wait(_ what: String, seconds: Double = 120, details: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard clock.now < deadline else { throw GoalTestTimeout(description: "Timed out waiting for \(what).\n\(details())") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func rows(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { item in
            switch item {
            case .user(_, let text, _): "user:" + (text.split(separator: "\n").first.map(String.init) ?? "")
            case .agentText(_, let text, _, _): "agent:" + (text.split(separator: "\n").last.map(String.init) ?? "")
            case .notice(_, let text): "notice:" + text
            default: nil
            }
        }
    }

    @Test func sessionGoalMetAfterTwoTurns() async throws {
        try await withHarness { h in
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let session = try await store.newSession(directory: h.path, model: Self.model, permissionMode: .bypass)
            h.track(session.id)
            #expect(await store.setGoal("the goal marker file exists", budget: GoalBudget(maxTurns: 5), for: session.id))
            try await wait("the goal to end", details: { rows(session.items).joined(separator: "\n") }) {
                store.goal(for: session.id)?.isActive == false
            }
            let goal = try #require(store.goal(for: session.id))
            #expect(goal.status == .met, "\(rows(session.items))")
            #expect(goal.turns == 2)
            #expect(goal.evidence == "goal-marker.txt exists.")
            // Nothing more goes out once it is met.
            try await Task.sleep(for: .seconds(2))
            let engineRows = rows(try await h.client.transcript(session.id)).filter { !$0.hasPrefix("notice:") }
            #expect(engineRows == [
                "user:[Goal] Keep working until this goal is met: the goal marker file exists",
                "agent:GOAL NOT MET: goal-marker.txt is missing.",
                "user:[Goal] Not met yet: goal-marker.txt is missing.",
                "agent:GOAL MET: goal-marker.txt exists.",
            ])
            #expect(rows(session.items).last == "notice:Goal met: goal-marker.txt exists.")
        }
    }

    @Test func sessionGoalStopsAtTheTurnBudget() async throws {
        try await withHarness { h in
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let session = try await store.newSession(directory: h.path, model: Self.model, permissionMode: .bypass)
            h.track(session.id)
            await store.send("/goal the budget marker never met --turns 2", to: session.id)
            try await wait("the goal to end", details: { rows(session.items).joined(separator: "\n") }) {
                store.goal(for: session.id).map { !$0.isActive } ?? false
            }
            let goal = try #require(store.goal(for: session.id))
            #expect(goal.status == .budgetReached)
            #expect(goal.turns == 2)
            try await Task.sleep(for: .seconds(2))
            let turns = rows(try await h.client.transcript(session.id)).filter { $0.hasPrefix("user:") }
            #expect(turns.count == 2, "\(turns)")
            #expect(rows(session.items).last == "notice:Goal stopped. Budget used up after 2 turns. Last check: the budget marker is never met.")
        }
    }

    @Test func roomGoalMetAfterTwoRuns() async throws {
        try await withHarness { h in
            let agent = AgentSpec(name: "Solo", model: Self.model, role: "Builds", colorHex: "#A78BFA")
            let spec = RoomSpec(title: "Goal room", directory: h.path, agents: [agent], mode: .solo, leadAgentID: agent.id,
                                permissionMode: .bypass)
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: InMemoryRoomStore())
            defer { engine.close() }
            for sid in engine.state.sessions.values { h.track(sid) }
            await engine.setGoal("the room marker", budget: GoalBudget(maxTurns: 3))
            try await wait("the room goal to end", details: { engine.boardDump }) { engine.state.goal?.isActive == false }
            #expect(engine.state.goal?.status == .met, "\(engine.boardDump)")
            #expect(engine.state.goal?.turns == 2)
            #expect(engine.state.run == 2)
            #expect(engine.notices.last == "Goal met: the room marker is built.")
            try await Task.sleep(for: .seconds(2))
            #expect(engine.state.run == 2)
            #expect(engine.state.phase == .finished)
        }
    }
}
#endif
