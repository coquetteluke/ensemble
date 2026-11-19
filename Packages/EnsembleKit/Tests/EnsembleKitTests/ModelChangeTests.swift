import Foundation
import Testing
@testable import EnsembleKit

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
}
