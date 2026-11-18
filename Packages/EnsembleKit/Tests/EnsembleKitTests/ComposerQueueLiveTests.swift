#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Queued messages, Send now and side questions against the real OpenCode service and the mock model.
/// Runs with `ENSEMBLE_LIVE_TESTS=1` (see `scripts/test-live.sh`).
@MainActor
@Suite(.serialized, .enabled(if: LiveConfig.enabled))
struct ComposerQueueLiveTests {
    /// Adds this suite's rules to the harness's copy of the mock script (the mock reloads it when it changes).
    static func addRules(_ h: LiveHarness) async throws {
        let url = h.directory.appendingPathComponent(".mock-script.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rules = json["rules"] as? [[String: Any]] ?? []
        rules.insert(contentsOf: [
            ["match": ["steer slow marker"], "steps": [
                ["tool": ["name": "shell", "arguments": ["command": "sleep 3"]]],
                ["text": "First turn done."],
            ]],
            ["match": ["steer extra marker"], "text": "Got the steer."],
            ["match": ["queue one marker"], "text": "Reply one."],
            ["match": ["queue two marker"], "text": "Reply two."],
            ["match": ["side question about this conversation", "what did you say"], "text": "Side answer from the copy."],
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

    /// `withHarness` on the main actor (the store lives there).
    func withMainHarness(_ body: (LiveHarness) async throws -> Void) async throws {
        let harness = try await LiveHarness.start()
        do {
            try await body(harness)
        } catch {
            await harness.cleanup()
            throw error
        }
        await harness.cleanup()
    }

    func executions(_ h: LiveHarness, _ id: String, after mark: Int) async -> [String] {
        await h.recorder.all().dropFirst(mark).compactMap { if case .executionEnded(id, let outcome, _) = $0 { outcome } else { nil } }
    }

    func rows(_ transcript: [TranscriptItem]) -> [String] {
        transcript.compactMap { item in
            switch item {
            case .user(_, let text, _): "user:" + text
            case .agentText(_, let text, _, _): "agent:" + text
            default: nil
            }
        }
    }

    @Test func sendNowSteersTheRunningTurn() async throws {
        try await withMainHarness { h in
            try await Self.addRules(h)
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let session = try await store.newSession(directory: h.path, model: ModelRef(providerID: "mock", id: "mock-1"), permissionMode: .bypass)
            h.track(session.id)
            let mark = await h.recorder.mark()
            await store.send("steer slow marker", to: session.id)
            _ = try await h.recorder.waitFor("the tool to run", after: mark) { event in
                if case .toolUpdated(session.id, let tool) = event { return tool.status == .running }
                return false
            }
            await store.send("steer extra marker", to: session.id)
            #expect(store.queue(for: session.id).map(\.text) == ["steer extra marker"])
            #expect(store.sendNowBehavior(for: session.id) == .steer)
            await store.sendNow(try #require(store.queue(for: session.id).first).id, in: session.id)
            #expect(store.queue(for: session.id).isEmpty)
            _ = try await h.waitForEnd(of: session.id, after: mark, timeout: 30)
            try await Task.sleep(for: .seconds(1))
            #expect(await executions(h, session.id, after: mark) == ["succeeded"], "one run: the turn was not stopped")
            let transcript = rows(try await h.client.transcript(session.id))
            #expect(transcript == ["user:steer slow marker", "user:steer extra marker", "agent:Got the steer."])
        }
    }

    @Test func heldMessagesGoOutInOrderOnePerTurn() async throws {
        try await withMainHarness { h in
            try await Self.addRules(h)
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let session = try await store.newSession(directory: h.path, model: ModelRef(providerID: "mock", id: "mock-1"), permissionMode: .bypass)
            h.track(session.id)
            let mark = await h.recorder.mark()
            await store.send("steer slow marker", to: session.id)
            await store.send("queue one marker", to: session.id)
            await store.send("queue two marker", to: session.id)
            #expect(store.queue(for: session.id).count == 2)
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline, await executions(h, session.id, after: mark).count < 3 {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(await executions(h, session.id, after: mark) == ["succeeded", "succeeded", "succeeded"])
            #expect(store.queue(for: session.id).isEmpty)
            let transcript = rows(try await h.client.transcript(session.id))
            #expect(transcript == ["user:steer slow marker", "agent:First turn done.", "user:queue one marker", "agent:Reply one.",
                                   "user:queue two marker", "agent:Reply two."])
        }
    }

    @Test func sideQuestionUsesAnAskModeCopyAndClosesIt() async throws {
        try await withMainHarness { h in
            try await Self.addRules(h)
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let session = try await store.newSession(directory: h.path, model: ModelRef(providerID: "mock", id: "mock-1"), permissionMode: .bypass)
            h.track(session.id)
            #expect(try await h.run(session.id, "hello there") == "succeeded")
            let before = try await h.client.transcript(session.id)

            await store.askSideQuestion("What did you say?", about: session.id)
            let forkID = try #require(store.sideQuestions[session.id]?.forkSessionID)
            h.track(forkID)
            #expect(try await h.client.permissionMode(forkID) == .ask, "the copy does not keep Bypass")
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, store.sideQuestions[session.id]?.phase == .asking {
                try await Task.sleep(for: .milliseconds(100))
            }
            let question = try #require(store.sideQuestions[session.id])
            #expect(question.phase == .answered)
            #expect(store.sideQuestionAnswer(question).text == "Side answer from the copy.")
            #expect(try await h.client.transcript(session.id) == before, "the session asked about is unchanged")

            await store.closeSideQuestion(for: session.id)
            #expect(try await !h.client.listSessions().contains { $0.id == forkID })
        }
    }
}

/// Send now on the Claude engine: one short haiku turn on the user's own subscription.
/// Runs with `ENSEMBLE_LIVE_CLAUDE=1`.
@Suite("Claude steering live", .serialized, .enabled(if: ClaudeLive.enabled))
struct ClaudeSteeringLiveTests {
    @Test func steeringJoinsTheRunningTurn() async throws {
        let harness = try ClaudeLiveHarness()
        defer { harness.finish() }
        let engine = harness.engine()
        let session = try await engine.createSession(directory: harness.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        let id = session.id
        var mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Use the Bash tool to run exactly: sleep 8 . Use no other tools. Then reply with one short sentence.", files: [])
        // `sleep` may run without asking; answer the prompt when there is one.
        let first = try await harness.recorder.wait("permission or the command", after: mark) {
            switch $0 {
            case .permissionAsked: true
            case .toolUpdated(id, let tool): tool.name == "Bash" && tool.status == .running
            case .executionEnded(id, _, _): true
            default: false
            }
        }
        if case .permissionAsked(let request) = first {
            try await engine.replyPermission(sessionID: id, requestID: request.id, decision: .once, message: nil)
        }
        let running = try await harness.recorder.wait("the command to run", after: mark) {
            switch $0 {
            case .toolUpdated(id, let tool): tool.name == "Bash" && tool.status == .running
            case .executionEnded(id, _, _): true
            default: false
            }
        }
        if case .executionEnded = running {
            let seen = await harness.recorder.events.dropFirst(mark).map { String(describing: $0).prefix(160) }
            Issue.record("The turn ended before the command ran: \(seen)")
            return
        }
        try await engine.steer(id, text: "One more thing: end your reply with the word PINEAPPLE in capitals.", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        try await Task.sleep(for: .seconds(3))
        let ends = await harness.recorder.events.dropFirst(mark).filter { if case .executionEnded(id, _, _) = $0 { true } else { false } }
        let text = await harness.recorder.texts(after: mark, session: id).joined()
        print("STEER ends=\(ends.count) text=\(text)")
        #expect(text.contains("PINEAPPLE"))
        let last = await harness.recorder.events.last { if case .activity(id, _) = $0 { true } else { false } }
        #expect(last == .activity(sessionID: id, .idle))

        // The engine's turn count is right afterwards: Stop is ignored when idle, and the next prompt runs normally.
        try await engine.interrupt(id)
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        // Steering an idle session starts a turn like a prompt.
        mark = await harness.recorder.mark()
        try await engine.steer(id, text: "Reply with exactly: idle steer", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        #expect(await harness.recorder.texts(after: mark, session: id).joined().contains("idle steer"))
        await engine.shutdown()
    }
}
#endif
