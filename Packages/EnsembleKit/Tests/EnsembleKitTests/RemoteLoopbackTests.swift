#if os(macOS)
import Foundation
import Network
import Synchronization
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

    func startServer(heartbeat: Duration = .seconds(15), helloTimeout: Duration = .seconds(3), port: UInt16 = 0,
                     maxDevices: Int = 8, maxPending: Int = 8, maxPendingPerAddress: Int = 3) async throws -> Harness {
        let host = DemoRemoteHost()
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: port, bindAddresses: ["127.0.0.1"], macName: "Loopback Mac",
                                                heartbeatInterval: heartbeat, helloTimeout: helloTimeout,
                                                maxDevices: maxDevices, maxPending: maxPending,
                                                maxPendingPerAddress: maxPendingPerAddress)
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
        defer { task.cancel() }
        // The Mac speaks first with a challenge; nothing else comes before a valid hello.
        let first = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(try await task.receive()))
        guard case .challenge(let challenge) = first.message else {
            Issue.record("Expected a challenge, got \(first.message.typeName)")
            return
        }
        #expect(RemoteHandshake.decode(challenge.serverNonce, expectedCount: 32) != nil)
        // No hello: the server closes the socket after its 3 s hello timeout.
        #expect(await Self.receiveFails(task, within: .seconds(8)))
    }

    @Test func oldPhoneIsToldToUpdate() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.port))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel() }
        _ = try await task.receive() // challenge
        // A version 1 hello carried the raw token.
        let v1 = #"{"v":1,"id":"1","type":"hello","data":{"token":"x","protocolVersion":1,"deviceName":"Old","deviceID":"old"}}"#
        try await task.send(.string(v1))
        let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(try await task.receive()))
        guard case .error(let error) = reply.message else {
            Issue.record("Expected an error, got \(reply.message.typeName)")
            return
        }
        #expect(error.code == .unsupportedVersion)
        #expect(error.message.contains("Update Ensemble"))
        #expect(reply.replyTo == "1")
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func phoneRefusesAHostThatFailsTheServerProofAndNeverSendsTheToken() async throws {
        let fake = try await FakeMac.start(host: "127.0.0.1", port: 0)
        defer { fake.stop() }
        let token = RemoteToken.generate()
        let pairing = RemotePairing(hosts: ["127.0.0.1"], port: Int(fake.port), token: token, macName: "Fake")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test")
        c.handshakeTimeout = .seconds(3)
        c.start()
        defer { c.stop() }

        #expect(await eventually { !fake.log.all.isEmpty && (c.lastError ?? "").contains("could not prove") })
        #expect(!c.state.isConnected)
        #expect(c.sessions.isEmpty)
        let sent = fake.log.all
        #expect(sent.allSatisfy { !$0.contains(token) })
        #expect(sent.first?.contains("\"proof\"") == true)
    }

    @Test func phoneSkipsTheFakeHostAndConnectsToTheRealMac() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        // Same port on another loopback address, answering with a bad proof.
        let fake = try await FakeMac.start(host: "::1", port: UInt16(h.port))
        defer { fake.stop() }
        let c = client(h, hosts: ["::1", "127.0.0.1"])
        c.start()
        defer { c.stop() }
        #expect(await eventually(.seconds(8)) { c.state == .connected(host: "127.0.0.1") })
        #expect(fake.log.all.count >= 1)
        #expect(await eventually { c.sessions.count == 4 })
    }

    @Test func stalledTCPConnectionIsClosedAtTheDeadline() async throws {
        let h = try await startServer(helloTimeout: .seconds(1))
        defer { Task { await h.server.stop() } }
        // Plain TCP that never sends the WebSocket upgrade, so the server-side connection never becomes ready.
        let raw = Self.silentTCP(port: h.port)
        defer { raw.cancel() }
        #expect(await eventually { await h.server.status.pendingConnections == 1 })
        #expect(await Self.tcpClosedByServer(raw, within: .seconds(5)))
        #expect(await eventually { await h.server.status.pendingConnections == 0 })
    }

    @Test func handshakeFloodCannotTakePairedPhoneSlots() async throws {
        let h = try await startServer(helloTimeout: .seconds(2), maxDevices: 2, maxPending: 2, maxPendingPerAddress: 2)
        defer { Task { await h.server.stop() } }
        let phone = client(h)
        phone.start()
        defer { phone.stop() }
        #expect(await eventually { phone.state.isConnected })

        // Six silent connections: only two get a handshake slot, the rest are closed at once.
        let flood = (0..<6).map { _ in Self.silentTCP(port: h.port) }
        defer { flood.forEach { $0.cancel() } }
        try await Task.sleep(for: .milliseconds(500))
        let status = await h.server.status
        #expect(status.pendingConnections == 2)
        #expect(status.devices.count == 1)
        #expect(phone.state.isConnected)

        // Once the deadline clears them, a second phone gets in.
        let second = client(h)
        second.start()
        defer { second.stop() }
        #expect(await eventually(.seconds(10)) { second.state.isConnected })
        #expect(await h.server.status.devices.count == 2)
        #expect(phone.state.isConnected)
    }

    @Test func pendingLimitIsPerAddressToo() async throws {
        let h = try await startServer(helloTimeout: .seconds(3), maxPending: 8, maxPendingPerAddress: 2)
        defer { Task { await h.server.stop() } }
        let flood = (0..<5).map { _ in Self.silentTCP(port: h.port) }
        defer { flood.forEach { $0.cancel() } }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await h.server.status.pendingConnections == 2)
    }

    @Test func extraPhonesBeyondTheDeviceLimitAreTurnedAway() async throws {
        let h = try await startServer(maxDevices: 1)
        defer { Task { await h.server.stop() } }
        let a = client(h)
        a.start()
        defer { a.stop() }
        #expect(await eventually { a.state.isConnected })
        let b = client(h)
        b.start()
        defer { b.stop() }
        #expect(await eventually { (b.lastError ?? "").contains("most phones") })
        #expect(!b.state.isConnected)
        #expect(await h.server.status.devices.count == 1)
    }

    // MARK: Helpers

    nonisolated static func data(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
    }

    /// True when the next receive fails (the server closed the socket) within `timeout`.
    nonisolated static func receiveFails(_ task: URLSessionWebSocketTask, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { _ = try await task.receive(); return false } catch { return true }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            task.cancel()
            return first
        }
    }

    nonisolated static func silentTCP(port: Int) -> NWConnection {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        c.start(queue: .global())
        return c
    }

    /// True when the server ends the TCP connection within `timeout`.
    nonisolated static func tcpClosedByServer(_ connection: NWConnection, within timeout: Duration) async -> Bool {
        let once = RemoteResumeOnce()
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if once.claim() { continuation.resume(returning: isComplete || error != nil) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
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
/// Thread-safe list of the hello frames a fake host received.
final class HelloLog: Sendable {
    private let items = Mutex<[String]>([])
    func append(_ text: String) { items.withLock { $0.append(text) } }
    var all: [String] { items.withLock { $0 } }
}

/// A host that speaks the protocol but does not know the token: it sends a challenge, records the hello and
/// answers with a made-up server proof.
final class FakeMac: Sendable {
    let listener: NWListener
    let port: UInt16
    let log: HelloLog

    private init(listener: NWListener, port: UInt16, log: HelloLog) {
        self.listener = listener
        self.port = port
        self.log = log
    }

    static func start(host: String, port: UInt16) async throws -> FakeMac {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "fake-mac")
        let log = HelloLog()
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    send(.challenge(RemoteChallenge(serverNonce: RemoteHandshake.encode(RemoteHandshake.makeNonce()))), on: connection)
                    receive(on: connection, log: log)
                }
            }
            connection.start(queue: queue)
        }
        let once = RemoteResumeOnce()
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return FakeMac(listener: listener, port: boundPort, log: log)
    }

    func stop() {
        listener.cancel()
    }

    private static func receive(on connection: NWConnection, log: HelloLog) {
        connection.receiveMessage { content, _, _, error in
            guard error == nil, let content else { return }
            let text = String(decoding: content, as: UTF8.self)
            log.append(text)
            if let frame = try? RemoteCoding.decode(RemoteClientFrame.self, from: content), case .hello(let hello) = frame.message {
                // A believable welcome, but the proof is random because this host has no token.
                let welcome = RemoteWelcome(macName: "Fake", deviceID: hello.deviceID, appVersion: "9.9",
                                            serverProof: RemoteHandshake.encode(RemoteHandshake.makeNonce()))
                send(.welcome(welcome), replyTo: frame.id, on: connection)
            }
            receive(on: connection, log: log)
        }
    }

    private static func send(_ message: RemoteServerMessage, replyTo: String? = nil, on connection: NWConnection) {
        guard let data = try? RemoteCoding.encode(RemoteServerFrame(message, replyTo: replyTo)) else { return }
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
#endif
