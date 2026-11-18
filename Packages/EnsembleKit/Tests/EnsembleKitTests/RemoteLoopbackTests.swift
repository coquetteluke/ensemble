#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Runs the real RemoteServer on 127.0.0.1 with a DemoRemoteHost and talks to it with the real RemoteClient.
@MainActor @Suite(.serialized) struct RemoteLoopbackTests {
    struct Harness {
        let host: DemoRemoteHost
        let server: RemoteServer
        let token: String
        let port: Int
    }

    func startServer(heartbeat: Duration = .seconds(15)) async throws -> Harness {
        let host = DemoRemoteHost()
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Loopback Mac",
                                                heartbeatInterval: heartbeat, helloTimeout: .seconds(3))
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()
        let port = try #require(await server.boundPort)
        return Harness(host: host, server: server, token: token, port: Int(port))
    }

    func client(_ h: Harness, token: String? = nil, hosts: [String] = ["127.0.0.1"]) -> RemoteClient {
        let pairing = RemotePairing(hosts: hosts, port: h.port, token: token ?? h.token, macName: "Loopback Mac")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test-\(UUID().uuidString)")
        c.handshakeTimeout = .seconds(3)
        c.requestTimeout = .seconds(5)
        return c
    }

    /// Polls `condition` on the main actor until it is true or the timeout passes.
    func eventually(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test func rightTokenGetsWelcomeAndHub() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }

        #expect(await eventually { c.state == .connected(host: "127.0.0.1") })
        #expect(await eventually { c.sessions.count == 4 && c.rooms.count == 1 && c.usage != nil })
        #expect(c.macName == "Loopback Mac")
        #expect(c.permissions.map(\.id) == [RemoteDemoData.IDs.permission])

        let status = await h.server.status
        #expect(status.devices.count == 1)
        #expect(status.devices.first?.name == "Test Phone")
        #expect(status.listening == ["127.0.0.1:\(h.port)"])
    }

    @Test func wrongTokenIsRejected() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h, token: RemoteToken.generate())
        c.start()
        defer { c.stop() }

        #expect(await eventually {
            if case .rejected = c.state { return true }
            return false
        })
        #expect(c.sessions.isEmpty)
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func triesNextHostWhenFirstFails() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        // 127.0.0.2 is loopback too but nothing listens there for this port.
        let c = client(h, hosts: ["127.0.0.2", "127.0.0.1"])
        c.start()
        defer { c.stop() }
        #expect(await eventually(.seconds(8)) { c.state == .connected(host: "127.0.0.1") })
    }

    @Test func actionsReachTheHost() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { !c.permissions.isEmpty })

        let permission = try #require(c.permissions.first)
        try await c.reply(to: permission, decision: .once)
        try await c.send("Run it again with coverage", to: .session(RemoteDemoData.IDs.fixSession))
        try await c.send("Grace, review the routes", to: .room(RemoteDemoData.IDs.roomID), agent: "Grace")
        try await c.setPermissionMode(.auto, for: .session(RemoteDemoData.IDs.fixSession))
        try await c.controlRoom(RemoteDemoData.IDs.roomID, action: .pause)
        try await c.interrupt(.session(RemoteDemoData.IDs.roomSession))

        let recorded = await h.host.recordedActions
        #expect(recorded == [
            .replyPermission(sessionID: RemoteDemoData.IDs.fixSession, requestID: RemoteDemoData.IDs.permission, decision: .once),
            .sendMessage(text: "Run it again with coverage", target: .session(RemoteDemoData.IDs.fixSession), agent: nil),
            .sendMessage(text: "Grace, review the routes", target: .room(RemoteDemoData.IDs.roomID), agent: "Grace"),
            .setPermissionMode(mode: .auto, target: .session(RemoteDemoData.IDs.fixSession)),
            .controlRoom(roomID: RemoteDemoData.IDs.roomID, action: .pause),
            .interrupt(target: .session(RemoteDemoData.IDs.roomSession)),
        ])
        #expect(c.permissions.isEmpty)
        #expect(c.permissionDecisions[RemoteDemoData.IDs.permission] == .once)
        #expect(await eventually { c.room(id: RemoteDemoData.IDs.roomID)?.state == .paused })
    }

    @Test func failedActionReturnsError() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.state.isConnected })

        await #expect(throws: RemoteError.self) {
            try await c.open(sessionID: "does-not-exist")
        }
        await #expect(throws: RemoteError.self) {
            try await c.send("   ", to: .session(RemoteDemoData.IDs.fixSession))
        }
        // The connection survives errors.
        try await c.refreshHub()
        #expect(c.state.isConnected)
    }

    @Test func liveUpdatesArrive() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.sessions.count == 4 })

        // Hub-wide update reaches every phone.
        await h.host.emit(.activity(sessionID: RemoteDemoData.IDs.docsSession, activity: .working))
        #expect(await eventually { c.sessions.first { $0.id == RemoteDemoData.IDs.docsSession }?.activity == .working })

        // Transcript updates only stream for the open chat.
        try await c.open(sessionID: RemoteDemoData.IDs.roomSession)
        #expect(c.openTranscript?.items.count == 6)
        await h.host.emit(.transcriptUpsert(sessionID: RemoteDemoData.IDs.roomSession,
                                             item: .agentText(id: "live-1", text: "Routes", agentID: RemoteDemoData.IDs.agentA, streaming: true)))
        await h.host.emit(.textDelta(sessionID: RemoteDemoData.IDs.roomSession, itemID: "live-1", delta: " done."))
        #expect(await eventually {
            if case .agentText(_, let text, _, _)? = c.openTranscript?.items.last { return text == "Routes done." }
            return false
        })

        // A new permission prompt shows up in the hub list and the open chat.
        let ask = PermissionRequest(id: "live-perm", sessionID: RemoteDemoData.IDs.roomSession, kind: "bash", title: "git push")
        await h.host.emit(.permissionAsked(request: ask))
        #expect(await eventually { c.permissions.contains { $0.id == "live-perm" } })
        #expect(c.openTranscript?.items.contains { $0.id == "live-perm" } == true)
    }

    @Test func severalPhonesAndRegenerateDropsThem() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let a = client(h)
        let b = client(h)
        a.start()
        b.start()
        defer { a.stop(); b.stop() }
        #expect(await eventually { a.state.isConnected && b.state.isConnected })
        #expect(await eventually { await h.server.status.devices.count == 2 })

        await h.host.emit(.sessionRemoved(sessionID: RemoteDemoData.IDs.oldSession))
        #expect(await eventually { a.sessions.count == 3 && b.sessions.count == 3 })

        await h.server.setToken(RemoteToken.generate())
        #expect(await eventually {
            if case .rejected = a.state, case .rejected = b.state { return true }
            return false
        })
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func silentConnectionIsClosedWithoutHello() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.port))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        // No hello: the server closes the socket after its 3 s hello timeout.
        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { _ = try await task.receive(); return false } catch { return true }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            task.cancel()
            return first
        }
        #expect(closed)
    }

    @Test func stopClosesListener() async throws {
        let h = try await startServer()
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.state.isConnected })
        await h.server.stop()
        #expect(await eventually {
            switch c.state {
            case .waiting, .connecting: return true
            default: return false
            }
        })
        #expect(await h.server.status.running == false)
    }

    @Test func inProcessClientWorksWithoutNetwork() async throws {
        let host = DemoRemoteHost()
        let c = RemoteClient(inProcessHost: host)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.sessions.count == 4 })
        try await c.open(sessionID: RemoteDemoData.IDs.fixSession)
        try await c.send("hi", to: .session(RemoteDemoData.IDs.fixSession))
        #expect(await eventually {
            if case .user(_, let text, _)? = c.openTranscript?.items.last { return text == "hi" }
            return false
        })
    }
}
#endif
