import Foundation
import Testing
@testable import EnsembleKit

/// End to end through the store and the preview engine's event stream.
@MainActor
@Suite struct StorePreviewEngineTests {
    private func until(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

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
        try await until { store.selected?.transcriptLoaded == true }
    }

    @Test func promptStreamsAReplyWithToolsAndAPermission() async throws {
        let store = await makeStore()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .ask)
        #expect(store.selectedSessionID == session.id)

        await store.send("Look for TODOs")
        try await until { !session.pendingPermissions.isEmpty }
        #expect(session.activity == .waitingForPermission)
        let request = try #require(session.pendingPermissions.first)

        await store.reply(to: request, decision: .once)
        try await until { session.activity == .idle && !session.items.isEmpty }

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
        try await until { !session.changedFiles.isEmpty }
    }

    @Test func rejectingThePermissionSkipsTheBuild() async throws {
        let store = await makeStore()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .ask)
        await store.send("Build it")
        try await until { !session.pendingPermissions.isEmpty }
        await store.reply(to: try #require(session.pendingPermissions.first), decision: .reject)
        try await until { session.activity == .idle }
        let ranBuild = session.items.contains { if case .tool(let t) = $0 { t.name == "bash" } else { false } }
        #expect(!ranBuild)
    }

    @Test func acceptEditsModeRunsWithoutAsking() async throws {
        let store = await makeStore()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .acceptEdits)
        await store.setPermissionMode(.acceptEdits)
        await store.send("Go")
        try await until { session.activity == .idle && session.items.count > 1 }
        #expect(!session.items.contains { if case .permission = $0 { true } else { false } })
    }

    @Test func stopInterruptsTheTurn() async throws {
        let engine = PreviewEngine(seed: PreviewData.seed(), delayScale: 1)
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .bypass)
        await store.setPermissionMode(.bypass)
        await store.send("Long task")
        try await until { session.items.count > 1 }
        await store.stop()
        try await until { session.activity == .idle }
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
        try await until {
            if case .agentText(_, let text, _, false) = main.items.last { return text.contains("24 tests") }
            return false
        }
        try await until { main.activity == .idle }
        let ranTests = main.items.contains { if case .tool(let t) = $0 { t.title == request.title && t.status == .succeeded } else { false } }
        #expect(ranTests)
    }

    @Test func renameArchiveDeleteAndKeys() async throws {
        let store = await makeStore()
        let id = "ses_readme"
        await store.rename(id, to: "Docs pass")
        #expect(store.session(id)?.title == "Docs pass")
        await store.archive(id)
        #expect(!store.sidebarOrder.contains { $0.id == id })
        await store.delete(id)
        #expect(store.session(id) == nil)

        try await store.setAPIKey(providerID: "xai", key: "test-key-not-real")
        #expect(store.providers.first { $0.id == "xai" }?.connected == true)
        #expect(store.models.first { $0.ref.providerID == "xai" }?.available == true)
        try await store.removeAPIKey(providerID: "xai")
        #expect(store.providers.first { $0.id == "xai" }?.connected == false)
    }

    @Test func switchModelUpdatesTheSession() async throws {
        let store = await makeStore()
        let ref = ModelRef(providerID: "openai", id: "gpt-5.5")
        await store.switchModel(ref)
        #expect(store.selected?.info.model == ref)
        #expect(store.modelName(ref) == "GPT-5.5")
    }
}
