import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

private final class ModelChangeGate: @unchecked Sendable {
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

private final class PausableCreateFakeEngine: RouterFakeEngine, @unchecked Sendable {
    private let createGate = Mutex<ModelChangeGate?>(nil)

    func pauseNextCreate(with gate: ModelChangeGate) {
        createGate.withLock { $0 = gate }
    }

    override func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession {
        if let gate = createGate.withLock({ value -> ModelChangeGate? in
            let next = value
            value = nil
            return next
        }) {
            await gate.pause()
        }
        return try await super.createSession(directory: directory, model: model, agent: agent, permissionMode: permissionMode, parentID: parentID)
    }
}

/// Picking a model of another engine: an empty session starts over on that engine, a session with history is offered a
/// new session, and nothing ends in an error.
@MainActor
@Suite struct ModelChangeTests {
    private let haiku = ModelRef(providerID: "claude-code", id: "haiku")
    private let gpt = ModelRef(providerID: "openai", id: "gpt-6")

    private func makeStore() -> (SessionStore, RouterFakeEngine, RouterFakeEngine) {
        let openCode = RouterFakeEngine(name: "opencode")
        let claude = RouterFakeEngine(name: "claude")
        let router = EngineRouter(fallback: openCode)
        router.register(claude, providers: ["claude-code": .subscription, "claude-code-api": .apiKey], id: "claude", name: "Claude")
        return (SessionStore(engine: router), openCode, claude)
    }

    @Test func emptySessionStartsOverOnTheOtherEngine() async throws {
        let (store, openCode, claude) = makeStore()
        let old = try await store.newSession(directory: "/tmp/project", model: gpt, permissionMode: .acceptEdits)
        store.extraFolders[old.id] = ["/tmp/other"]
        let result = await store.changeModel(haiku, for: old.id)
        guard case .restarted(let from, let to) = result else {
            Issue.record("Expected a restart, got \(result)")
            return
        }
        #expect(from == old.id)
        let replacement = try #require(store.session(to))
        #expect(replacement.info.model == haiku)
        #expect(replacement.directory == "/tmp/project")
        #expect(replacement.permissionMode == .acceptEdits)
        #expect(store.extraFolders[to] == ["/tmp/other"])
        #expect(store.selectedSessionID == to)
        #expect(store.session(old.id) == nil)
        #expect(openCode.calls.contains("delete:\(old.id)"))
        #expect(claude.calls.contains("create:claude-code/haiku:nil"))
        #expect(store.lastError == nil)
    }

    @Test func sessionWithHistoryIsOfferedANewSession() async throws {
        let (store, openCode, claude) = makeStore()
        let info = EngineSession(id: "ses_history", title: "Fix the build", directory: "/tmp/project", model: gpt)
        openCode.setSessions([info])
        store.seed(StoreSeed(sessions: [info], transcripts: [info.id: [.user(id: "u1", text: "Run the tests", date: Date())]],
                             modes: [info.id: .auto]))
        let result = await store.changeModel(haiku, for: info.id)
        #expect(result == .stagedForNextMessage(haiku))
        #expect(store.stagedModel(for: info.id) == haiku)
        #expect(store.lastError == nil)
        #expect(store.session(info.id)?.info.model == gpt)
        #expect(!openCode.calls.contains { $0.hasPrefix("switch:") || $0.hasPrefix("delete:") })

        let fresh = try #require(await store.startSession(like: info.id, model: haiku))
        #expect(fresh.info.model == haiku && fresh.directory == "/tmp/project" && fresh.permissionMode == .auto)
        #expect(store.selectedSessionID == fresh.id)
        #expect(store.session(info.id) != nil)
        #expect(claude.calls.first == "create:claude-code/haiku:nil")
    }

    @Test func modelOfTheSameEngineSwitchesInPlace() async throws {
        let (store, openCode, _) = makeStore()
        let session = try await store.newSession(directory: "/tmp/project", model: gpt, permissionMode: .auto)
        let grok = ModelRef(providerID: "xai", id: "grok-5")
        #expect(await store.changeModel(grok, for: session.id) == .switched)
        #expect(openCode.calls.contains("switch:\(session.id):xai/grok-5"))
        #expect(store.session(session.id)?.info.model == grok)
    }

    @Test func untrustedFolderEngineCountsAsTheFallback() async throws {
        let openCode = RouterFakeEngine(name: "opencode")
        let untrusted = RouterFakeEngine(name: "untrusted")
        let trust = WorkspaceTrust(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString).json"))
        let router = EngineRouter(fallback: openCode, trust: trust)
        router.registerForUntrustedFolders(untrusted)
        let session = try await router.createSession(directory: "/tmp/untrusted-\(UUID().uuidString)", model: gpt, agent: nil,
                                                     permissionMode: .auto, parentID: nil)
        #expect(router.ownerID(ofSession: session.id) == EngineRouter.untrustedOpenCodeID)
        #expect(await router.engineChange(forSession: session.id, to: ModelRef(providerID: "xai", id: "grok-5")) == nil)
        try await router.switchModel(session.id, model: ModelRef(providerID: "xai", id: "grok-5"))
        #expect(untrusted.calls.last == "switch:\(session.id):xai/grok-5")
    }

    @Test func changeModelDoesNotDeleteSessionIfMessageArrivesDuringRestart() async throws {
        let openCode = RouterFakeEngine(name: "opencode")
        let claude = PausableCreateFakeEngine(name: "claude")
        let router = EngineRouter(fallback: openCode)
        router.register(claude, providers: ["claude-code": .subscription], id: "claude", name: "Claude")
        let store = SessionStore(engine: router)

        let original = try await store.newSession(directory: "/tmp/project", model: gpt, permissionMode: .auto)
        let gate = ModelChangeGate()
        claude.pauseNextCreate(with: gate)

        let restartTask = Task { await store.changeModel(haiku, for: original.id) }
        await gate.waitUntilPaused()

        // A concurrent restart request on the same session is rejected while one is in flight.
        let concurrentResult = await store.changeModel(haiku, for: original.id)
        #expect(concurrentResult == .failed)

        // User starts using the original session before the replacement finishes creating.
        await store.send("Keep this session alive", to: original.id)

        gate.release()
        let result = await restartTask.value

        #expect(result == .stagedForNextMessage(haiku))
        #expect(store.session(original.id) != nil)
        #expect(store.selectedSessionID == original.id)
        #expect(store.stagedModel(for: original.id) == haiku)
        #expect(!openCode.calls.contains("delete:\(original.id)"))
        #expect(claude.calls.contains { $0.hasPrefix("delete:claude-") })
        #expect(original.items.contains {
            if case .user(_, let text, _) = $0 { return text == "Keep this session alive" }
            return false
        })
    }
}
