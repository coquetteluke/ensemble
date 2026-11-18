#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The background list against the real OpenCode service and the mock model (`ENSEMBLE_LIVE_TESTS=1`): a running
/// subagent and a background shell show in the store's list, and Stop ends each of them.
@MainActor
@Suite(.serialized, .enabled(if: LiveConfig.enabled))
struct BackgroundLiveTests {
    /// Rules added to the harness's mock script: a parent that starts a slow subagent, a slow child, and a parent that
    /// starts `sleep` in the background. The match words do not appear in the reports the parent gets back.
    static let rules: [[String: Any]] = [
        ["match": ["start the long job"],
         "tool": ["name": "subagent", "arguments": ["agent": "general", "description": "Long child job", "prompt": "child slow work please"]],
         "then": "Started the helper."],
        ["match": ["child slow work"], "text": "Slow child output that takes a while.", "chunks": 80, "delay": 0.5],
        ["match": ["start the background sleep"],
         "tool": ["name": "shell", "arguments": ["command": "sleep 120", "background": true]],
         "then": "Sleeping in the background."],
    ]

    static func addRules(_ harness: LiveHarness) throws {
        let url = harness.directory.appendingPathComponent(".mock-script.json")
        var script = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        script["rules"] = rules + (script["rules"] as? [[String: Any]] ?? [])
        try JSONSerialization.data(withJSONObject: script).write(to: url)
    }

    /// A store on the live client fed by its own event stream (without `start()`, which would touch every session on the
    /// service).
    static func store(_ h: LiveHarness) async throws -> (SessionStore, Task<Void, Never>) {
        let store = SessionStore(engine: h.client)
        store.sideQuestionRecordURL = nil
        store.background.timerEnabled = false
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

    static func waitUntil(_ what: String, timeout: Double = 30, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveTimeout(what: what)
    }

    @Test func runningSubagentShowsAndStopEndsIt() async throws {
        try await withMainHarness { h in
            try Self.addRules(h)
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let parent = try await h.createSession(.bypass)
            try await Self.waitUntil("the store to know the session") { store.session(parent.id) != nil }

            let mark = await h.recorder.mark()
            try await h.client.prompt(parent.id, text: "please start the long job", files: [])
            try await Self.waitUntil("the subagent in the background list") {
                store.backgroundItems.contains { $0.kind == .subagent && $0.rootSessionID == parent.id }
            }
            let item = try #require(store.backgroundItems.first { $0.kind == .subagent && $0.rootSessionID == parent.id })
            let childID = try #require(item.openSessionID)
            h.track(childID)
            #expect(item.title == "Long child job")
            #expect(store.backgroundWork().contains { $0.id == parent.id && $0.items.contains { $0.id == item.id } })
            #expect(store.backgroundRunningCount >= 1)

            await store.stopBackground(item)
            #expect(store.lastError == nil)
            let ended = try await h.recorder.waitFor("the subagent to stop", after: mark) { event in
                if case .executionEnded(let id, _, _) = event { return id == childID }
                return false
            }
            if case .executionEnded(_, let outcome, _) = ended { #expect(outcome == "interrupted") }
            try await Self.waitUntil("the subagent to leave the list") {
                !store.backgroundItems.contains { $0.id == item.id }
            }
            // Only the subagent stopped: the parent's own turn ended normally.
            let parentOutcomes = await h.recorder.all().dropFirst(mark).compactMap { event -> String? in
                if case .executionEnded(let id, let outcome, _) = event, id == parent.id { return outcome }
                return nil
            }
            #expect(!parentOutcomes.contains("interrupted"))
        }
    }

    @Test func backgroundShellShowsAndStopKillsIt() async throws {
        try await withMainHarness { h in
            try Self.addRules(h)
            let (store, events) = try await Self.store(h)
            defer { events.cancel() }
            let session = try await h.createSession(.bypass)
            try await Self.waitUntil("the store to know the session") { store.session(session.id) != nil }

            #expect(try await h.run(session.id, "please start the background sleep") == "succeeded")
            try await Self.waitUntil("the shell in the background list") {
                await store.refreshBackgroundTasks()
                return store.backgroundItems.contains { $0.kind == .shell && $0.rootSessionID == session.id }
            }
            let item = try #require(store.backgroundItems.first { $0.kind == .shell && $0.rootSessionID == session.id })
            #expect(item.title == "sleep 120")
            #expect(item.openSessionID == session.id)

            await store.stopBackground(item)
            #expect(store.lastError == nil)
            #expect(!store.backgroundItems.contains { $0.id == item.id })
            let left = try await h.client.backgroundTasks().filter { $0.sessionID == session.id }
            #expect(left.isEmpty)
        }
    }
}
#endif
