#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The phone ends a "Thinking" row on its own, the way `TranscriptReducer` does on the Mac, so it works against a
/// Mac that never says the reasoning finished.
@MainActor @Suite(.serialized) struct RemoteThinkingTests {
    let sid = RemoteDemoData.IDs.docsSession

    func connected() async throws -> (DemoRemoteHost, RemoteServer, RemoteClient) {
        let host = DemoRemoteHost()
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Loopback Mac",
                                                heartbeatInterval: .seconds(15), helloTimeout: .seconds(30))
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()
        let port = try #require(await server.boundPort)
        let pairing = RemotePairing(hosts: ["127.0.0.1"], port: Int(port), token: token, macName: "Loopback Mac")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test-\(UUID().uuidString)")
        c.handshakeTimeout = .seconds(30)
        c.requestTimeout = .seconds(60)
        // Chosen before connecting, so the client's own first load is the only time it fetches the transcript (a
        // later fetch would replace the rows these tests stream in).
        try? await c.open(sessionID: sid)
        c.start()
        try await waitUntil { c.state.isConnected && c.usage != nil && c.openTranscript?.sessionID == sid }
        return (host, server, c)
    }

    func reasoning(_ c: RemoteClient, _ id: String) -> (text: String, streaming: Bool)? {
        for item in c.openTranscript?.items ?? [] {
            if case .reasoning(let rid, let text, let streaming) = item, rid == id { return (text, streaming) }
        }
        return nil
    }

    func agentText(_ c: RemoteClient, _ id: String) -> (text: String, streaming: Bool)? {
        for item in c.openTranscript?.items ?? [] {
            if case .agentText(let tid, let text, _, let streaming) = item, tid == id { return (text, streaming) }
        }
        return nil
    }

    /// Starts a thought the way `MacRemoteHost` does: an upsert, then deltas.
    func startThinking(_ host: DemoRemoteHost, _ c: RemoteClient, id: String) async throws {
        await host.emit(.activity(sessionID: sid, activity: .working))
        await host.emit(.transcriptUpsert(sessionID: sid, item: .reasoning(id: id, text: "Let me", streaming: true)))
        await host.emit(.textDelta(sessionID: sid, itemID: id, delta: " look."))
        try await waitUntil { reasoning(c, id)?.text == "Let me look." }
        #expect(reasoning(c, id)?.streaming == true)
    }

    @Test func reasoningThenTextStopsThinking() async throws {
        let (host, server, c) = try await connected()
        defer { c.stop(); Task { await server.stop() } }
        try await startThinking(host, c, id: "r1")

        await host.emit(.textDelta(sessionID: sid, itemID: "t1", delta: "Here it is."))
        try await waitUntil { agentText(c, "t1") != nil }
        #expect(reasoning(c, "r1")?.streaming == false)
        #expect(agentText(c, "t1")?.streaming == true)
    }

    @Test func reasoningThenTextUpsertStopsThinking() async throws {
        let (host, server, c) = try await connected()
        defer { c.stop(); Task { await server.stop() } }
        try await startThinking(host, c, id: "r2")

        await host.emit(.transcriptUpsert(sessionID: sid, item: .agentText(id: "t2", text: "Done", agentID: nil, streaming: true)))
        try await waitUntil { agentText(c, "t2") != nil }
        #expect(reasoning(c, "r2")?.streaming == false)
    }

    @Test func reasoningThenToolStopsThinking() async throws {
        let (host, server, c) = try await connected()
        defer { c.stop(); Task { await server.stop() } }
        try await startThinking(host, c, id: "r3")

        let tool = ToolCallInfo(id: "tool-1", name: "read", title: "README.md", status: .running)
        await host.emit(.transcriptUpsert(sessionID: sid, item: .tool(tool)))
        try await waitUntil { c.openTranscript?.items.contains { $0.id == "tool-1" } == true }
        #expect(reasoning(c, "r3")?.streaming == false)
    }

    @Test func reasoningThenTurnEndStopsThinking() async throws {
        let (host, server, c) = try await connected()
        defer { c.stop(); Task { await server.stop() } }
        try await startThinking(host, c, id: "r4")

        await host.emit(.activity(sessionID: sid, activity: .idle))
        try await waitUntil { c.openTranscript?.activity == .idle }
        #expect(reasoning(c, "r4")?.streaming == false)
    }

    @Test func failedTurnStopsTextAndThinking() async throws {
        let (host, server, c) = try await connected()
        defer { c.stop(); Task { await server.stop() } }
        try await startThinking(host, c, id: "r5")
        await host.emit(.textDelta(sessionID: sid, itemID: "t5", delta: "Half"))
        try await waitUntil { agentText(c, "t5") != nil }

        await host.emit(.activity(sessionID: sid, activity: .failed))
        try await waitUntil { c.openTranscript?.activity == .failed }
        #expect(reasoning(c, "r5")?.streaming == false)
        #expect(agentText(c, "t5")?.streaming == false)
    }

    @Test func waitingForPermissionStopsThinkingButNotText() async throws {
        let (host, server, c) = try await connected()
        defer { c.stop(); Task { await server.stop() } }
        await host.emit(.activity(sessionID: sid, activity: .working))
        await host.emit(.textDelta(sessionID: sid, itemID: "t6", delta: "Going to run it."))
        await host.emit(.transcriptUpsert(sessionID: sid, item: .reasoning(id: "r6", text: "Hmm", streaming: true)))
        try await waitUntil { reasoning(c, "r6") != nil }

        await host.emit(.activity(sessionID: sid, activity: .waitingForPermission))
        try await waitUntil { c.openTranscript?.activity == .waitingForPermission }
        #expect(reasoning(c, "r6")?.streaming == false)
        #expect(agentText(c, "t6")?.streaming == true)
    }
}
#endif
