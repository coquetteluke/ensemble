import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

private final class TranscriptLoadGate: @unchecked Sendable {
    private struct State {
        var arrived = false
        var released = false
        var arrivalWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func pause() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (notify, resumeNow): (CheckedContinuation<Void, Never>?, Bool) = state.withLock { s in
                s.arrived = true
                let waiter = s.arrivalWaiter
                s.arrivalWaiter = nil
                if s.released {
                    return (waiter, true)
                } else {
                    s.releaseWaiter = continuation
                    return (waiter, false)
                }
            }
            notify?.resume()
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate = state.withLock { s -> Bool in
                if s.arrived { return true }
                s.arrivalWaiter = continuation
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            s.released = true
            let w = s.releaseWaiter
            s.releaseWaiter = nil
            return w
        }
        waiter?.resume()
    }
}

private final class DelayedTranscriptFakeEngine: RouterFakeEngine, @unchecked Sendable {
    private struct LoadState {
        var scriptedTranscript: [String: [TranscriptItem]] = [:]
        var gate: TranscriptLoadGate?
        var transcriptFetchCount = 0
    }

    private let loadState = Mutex(LoadState())

    var transcriptFetchCount: Int { loadState.withLock { $0.transcriptFetchCount } }

    func setScriptedTranscript(_ items: [TranscriptItem], for sessionID: String) {
        loadState.withLock { $0.scriptedTranscript[sessionID] = items }
    }

    func pauseNextTranscript(with gate: TranscriptLoadGate) {
        loadState.withLock { $0.gate = gate }
    }

    override func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        let gate = loadState.withLock { s -> TranscriptLoadGate? in
            s.transcriptFetchCount += 1
            let next = s.gate
            s.gate = nil
            return next
        }
        if let gate { await gate.pause() }
        log("transcript:\(sessionID)")
        return loadState.withLock { $0.scriptedTranscript[sessionID] ?? [] }
    }
}

/// End to end through the store and the preview engine's event stream.
@MainActor
@Suite struct StorePreviewEngineTests {
    private func makeStore() async -> SessionStore {
        let engine = PreviewEngine(seed: PreviewData.seed(), delayScale: 0)
        let store = SessionStore(engine: engine)
        await store.start()
        return store
    }

    @Test func startLoadsSessionsModelsAndPendingPermissions() async throws {
        let store = await makeStore()
        #expect(store.sessions.count == PreviewData.seed().sessions.count)
        #expect(!store.models.isEmpty)
        #expect(!store.connectors.isEmpty)
        #expect(store.needsYouTotal == 2)
        #expect(store.selectedSessionID != nil)
        try await waitUntil("the selected transcript") { store.selected?.transcriptLoaded == true }
    }

    @Test func promptStreamsAReplyWithToolsAndAPermission() async throws {
        let store = await makeStore()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .ask)
        #expect(store.selectedSessionID == session.id)

        await store.send("Look for TODOs")
        try await waitUntil("the permission prompt") { !session.pendingPermissions.isEmpty }
        #expect(session.activity == .waitingForPermission)
        let request = try #require(session.pendingPermissions.first)

        await store.reply(to: request, decision: .once)
        try await waitUntil("the turn to end") { session.activity == .idle && !session.items.isEmpty }

        #expect(session.resolutions[request.id] == .allowedOnce)
        let kinds = session.items.map { item -> String in
            switch item {
            case .user: "user"
            case .agentText: "text"
            case .reasoning: "reasoning"
            case .tool(let tool): "tool:\(tool.name):\(tool.status.rawValue)"
            case .permission: "permission"
            default: "other"
            }
        }
        #expect(kinds.first == "user")
        #expect(kinds.contains("reasoning"))
        #expect(kinds.contains("tool:grep:succeeded"))
        #expect(kinds.contains("tool:bash:succeeded"))
        #expect(kinds.contains("tool:edit:succeeded"))
        #expect(kinds.contains("permission"))
        #expect(kinds.last == "text")
        #expect(!session.items.contains { if case .agentText(_, _, _, true) = $0 { true } else { false } }, "nothing still streaming")
        #expect(session.usage.inputTokens > 0)
        #expect(session.title == "Look for TODOs", "the engine titles the session from the first message")
        try await waitUntil("the changed files") { !session.changedFiles.isEmpty }
    }

    @Test func rejectingThePermissionSkipsTheBuild() async throws {
        let store = await makeStore()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .ask)
        await store.send("Build it")
        try await waitUntil("the permission prompt") { !session.pendingPermissions.isEmpty }
        await store.reply(to: try #require(session.pendingPermissions.first), decision: .reject)
        try await waitUntil("the turn to end") { session.activity == .idle }
        let ranBuild = session.items.contains { if case .tool(let t) = $0 { t.name == "bash" } else { false } }
        #expect(!ranBuild)
    }

    @Test func acceptEditsModeRunsWithoutAsking() async throws {
        let store = await makeStore()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .acceptEdits)
        await store.setPermissionMode(.acceptEdits)
        await store.send("Go")
        try await waitUntil("the turn to end") { session.activity == .idle && session.items.count > 1 }
        #expect(!session.items.contains { if case .permission = $0 { true } else { false } })
    }

    @Test func stopInterruptsTheTurn() async throws {
        // A long turn, so it is still running when the test stops it.
        let engine = PreviewEngine(seed: PreviewData.seed(), delayScale: TestWait.longTurnScale)
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .bypass)
        await store.setPermissionMode(.bypass)
        await store.send("Long task")
        try await waitUntil("the reply to start") { session.items.count > 1 }
        await store.stop()
        try await waitUntil("the turn to end") { session.activity == .idle }
        if case .notice(_, let text) = try #require(session.items.last) {
            #expect(text == "Interrupted")
        } else {
            Issue.record("expected an Interrupted notice")
        }
    }

    @Test func answeringASeededPermissionContinuesTheSession() async throws {
        let store = await makeStore()
        let main = try #require(store.session(PreviewData.mainSessionID))
        await store.loadSession(main.id)
        #expect(main.transcriptLoaded)
        let request = try #require(main.pendingPermissions.first)
        await store.reply(to: request, decision: .once)
        #expect(main.resolutions[request.id] == .allowedOnce)
        try await waitUntil("the reply about the tests") {
            if case .agentText(_, let text, _, false) = main.items.last { return text.contains("24 tests") }
            return false
        }
        try await waitUntil("the turn to end") { main.activity == .idle }
        let ranTests = main.items.contains { if case .tool(let t) = $0 { t.title == request.title && t.status == .succeeded } else { false } }
        #expect(ranTests)
    }

    @Test func renameArchiveDeleteAndKeys() async throws {
        let store = await makeStore()
        let id = "ses_readme"
        await store.rename(id, to: "Docs pass")
        #expect(store.session(id)?.title == "Docs pass")
        await store.archive(id)
        #expect(store.session(id)?.info.archived == true)
        #expect(!store.sidebarOrder.contains { $0.id == id })

        // Barrier: the engine's events come through one ordered stream, so once an engine-side rename of
        // another session shows up, every echo of the calls above has been applied as well.
        try await drainEvents(store, marker: "Barrier 1")
        #expect(store.session(id)?.title == "Docs pass")
        #expect(store.session(id)?.info.archived == true, "late echoes did not unarchive it")
        #expect(!store.sidebarOrder.contains { $0.id == id })

        await store.delete(id)
        #expect(store.session(id) == nil)
        try await drainEvents(store, marker: "Barrier 2")
        #expect(store.session(id) == nil, "late events did not bring the deleted session back")
        #expect(!store.sessions.contains { $0.id == id })

        try await store.setAPIKey(providerID: "xai", key: "test-key-not-real")
        #expect(store.providers.first { $0.id == "xai" }?.connected == true)
        #expect(store.models.first { $0.ref.providerID == "xai" }?.available == true)
        try await store.removeAPIKey(providerID: "xai")
        #expect(store.providers.first { $0.id == "xai" }?.connected == false)
    }

    /// Renames another session on the engine side (bypassing the store) and waits for that event.
    private func drainEvents(_ store: SessionStore, marker: String) async throws {
        let other = try #require(store.session("ses_astro"))
        try await store.engine.renameSession(other.id, title: marker)
        try await waitUntil("the barrier rename") { other.title == marker }
    }

    @Test func sessionsGetTodaysPermissionRulesOncePerLaunch() async throws {
        let engine = PreviewEngine(seed: PreviewData.seed(), delayScale: 0)
        // Rules an older Ensemble wrote for Auto: same shape, missing today's newest rule.
        let old = Array(PermissionRules.ruleset(for: .auto).dropLast())
        #expect(PermissionRules.outdatedMode(for: old) == .auto)
        engine.storeRules(old, for: "ses_readme")
        try await engine.setPermissionMode("ses_astro", mode: .ask)

        let store = SessionStore(engine: engine)
        await store.start()
        await store.permissionSyncTask?.value

        #expect(try await engine.permissionRules("ses_readme") == PermissionRules.ruleset(for: .auto), "outdated rules rewritten")
        #expect(store.session("ses_readme")?.permissionMode == .auto)
        #expect(store.session("ses_astro")?.permissionMode == .ask, "the mode is read from the engine's rules")
        #expect(store.session(PreviewData.mainSessionID)?.permissionMode == .ask)
        #expect(store.session("ses_rate_limit")?.permissionMode == .bypass)

        // Once per launch: rules that go stale later are not rewritten again until the next launch.
        engine.storeRules(old, for: "ses_readme")
        store.select("ses_readme")
        await store.syncPermissionRules("ses_readme")
        #expect(try await engine.permissionRules("ses_readme") == old)

        // A new store (the next launch) checks again.
        let next = SessionStore(engine: engine)
        await next.start()
        await next.permissionSyncTask?.value
        #expect(try await engine.permissionRules("ses_readme") == PermissionRules.ruleset(for: .auto))
        next.stopListening()
        store.stopListening()
    }

    @Test func aModePickedDuringTheCheckWins() async throws {
        let engine = PreviewEngine(seed: PreviewData.seed(), delayScale: 0)
        try await engine.setPermissionMode("ses_astro", mode: .ask)
        let store = SessionStore(engine: engine)
        await store.start()
        await store.setPermissionMode(.bypass, for: "ses_astro")
        await store.permissionSyncTask?.value
        #expect(store.session("ses_astro")?.permissionMode == .bypass)
        #expect(try await engine.permissionRules("ses_astro") == PermissionRules.ruleset(for: .bypass))
        store.stopListening()
    }

    @Test func switchModelUpdatesTheSession() async throws {
        let store = await makeStore()
        let ref = ModelRef(providerID: "openai", id: "gpt-5.5")
        await store.switchModel(ref)
        #expect(store.selected?.info.model == ref)
        #expect(store.modelName(ref) == "GPT-5.5")
    }

    @Test func loadSessionCoalescesConcurrentCallsAndPreservesLiveItems() async throws {
        let engine = DelayedTranscriptFakeEngine(name: "delayed")
        let existing = EngineSession(id: "ses_live", title: "Live session", directory: "/tmp/demo")
        engine.setSessions([existing])
        engine.setScriptedTranscript([
            .user(id: "u1", text: "Earlier prompt", date: Date(timeIntervalSince1970: 100)),
            .agentText(id: "a1", text: "Earlier reply", agentID: nil, streaming: false),
        ], for: existing.id)

        let gate = TranscriptLoadGate()
        engine.pauseNextTranscript(with: gate)

        let store = SessionStore(engine: engine)
        await store.start()
        defer { store.stopListening() }

        let session = try #require(store.session(existing.id))
        // `store.start()` selected `ses_live` and started the first load; start another concurrent load directly.
        await gate.waitUntilPaused()
        let secondLoad = Task { await store.loadSession(existing.id) }

        // While transcript fetch is in flight, append a new optimistic user message and live streaming events.
        await store.send("Live follow-up", to: existing.id)
        engine.send(.reasoningDelta(sessionID: existing.id, itemID: "r-live", delta: "Checking files"))
        engine.send(.toolUpdated(sessionID: existing.id, ToolCallInfo(id: "t-live", name: "bash", title: "swift test", status: .running)))
        engine.send(.textDelta(sessionID: existing.id, itemID: "a-live", delta: "Streaming answer"))
        try await waitUntil("live items arrive before transcript finishes") {
            session.items.contains { $0.id == "a-live" }
                && session.items.contains { $0.id == "r-live" }
                && session.items.contains { $0.id == "t-live" }
        }

        gate.release()
        await secondLoad.value

        // The two overlapping loads coalesced into a single engine transcript fetch.
        #expect(engine.transcriptFetchCount == 1)
        #expect(session.transcriptLoaded)
        #expect(session.items.contains { $0.id == "u1" })
        #expect(session.items.contains { $0.id == "a1" })
        #expect(session.items.contains {
            if case .user(_, let text, _) = $0 { return text == "Live follow-up" }
            return false
        })
        #expect(session.items.contains {
            // The tool that started after it ends the reasoning stream, so only the row and its text matter here.
            if case .reasoning(let id, let text, _) = $0 {
                return id == "r-live" && text == "Checking files"
            }
            return false
        })
        #expect(session.items.contains {
            if case .tool(let tool) = $0 { return tool.id == "t-live" && tool.status == .running }
            return false
        })
        #expect(session.items.contains {
            if case .agentText(let id, let text, _, let streaming) = $0 {
                return id == "a-live" && text == "Streaming answer" && streaming
            }
            return false
        })

        // A follow-up reload while still streaming also preserves active live items without duplicating them.
        await store.loadSession(existing.id)
        #expect(engine.transcriptFetchCount == 2)
        #expect(session.items.filter { $0.id == "a-live" }.count == 1)
        #expect(session.items.filter { $0.id == "t-live" }.count == 1)
        #expect(session.items.filter {
            if case .user(_, let text, _) = $0 { return text == "Live follow-up" }
            return false
        }.count == 1)
    }
}
