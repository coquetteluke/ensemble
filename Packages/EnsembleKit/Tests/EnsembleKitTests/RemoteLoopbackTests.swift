#if os(macOS)
import CryptoKit
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

    /// The hello and handshake timeouts are long so a slow machine never trips them; tests about them set their own.
    func startServer(heartbeat: Duration = .seconds(15), helloTimeout: Duration = .seconds(30), port: UInt16 = 0,
                     maxDevices: Int = 8, maxPending: Int = 8, maxPendingPerAddress: Int = 3,
                     acceptedHosts: [String] = []) async throws -> Harness {
        let host = DemoRemoteHost()
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: port, bindAddresses: ["127.0.0.1"], macName: "Loopback Mac",
                                                heartbeatInterval: heartbeat, helloTimeout: helloTimeout,
                                                maxDevices: maxDevices, maxPending: maxPending,
                                                maxPendingPerAddress: maxPendingPerAddress, acceptedHosts: acceptedHosts)
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()
        let port = try #require(await server.boundPort)
        return Harness(host: host, server: server, token: token, port: Int(port))
    }

    func client(_ h: Harness, token: String? = nil, hosts: [String] = ["127.0.0.1"],
                handshakeTimeout: Duration = .seconds(30)) -> RemoteClient {
        let pairing = RemotePairing(hosts: hosts, port: h.port, token: token ?? h.token, macName: "Loopback Mac")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test-\(UUID().uuidString)")
        c.handshakeTimeout = handshakeTimeout
        c.requestTimeout = .seconds(60)
        return c
    }

    @Test func rightTokenGetsWelcomeAndHub() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }

        try await waitUntil { c.state == .connected(via: .direct(host: "127.0.0.1")) }
        try await waitUntil { c.sessions.count == 4 && c.rooms.count == 1 && c.usage != nil }
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

        try await waitUntil {
            if case .rejected = c.state { return true }
            return false
        }
        #expect(c.sessions.isEmpty)
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func triesNextHostWhenFirstFails() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        // 127.0.0.2 is loopback too but nothing listens there for this port. A short handshake timeout, so giving up
        // on it does not take long.
        let c = client(h, hosts: ["127.0.0.2", "127.0.0.1"], handshakeTimeout: .seconds(3))
        c.start()
        defer { c.stop() }
        try await waitUntil { c.state == .connected(via: .direct(host: "127.0.0.1")) }
    }

    @Test func actionsReachTheHost() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        try await waitUntil { !c.permissions.isEmpty }

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
        try await waitUntil { c.room(id: RemoteDemoData.IDs.roomID)?.state == .paused }
    }

    @Test func failedActionReturnsError() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        try await waitUntil { c.state.isConnected }

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
        try await waitUntil { c.sessions.count == 4 }

        // Hub-wide update reaches every phone.
        await h.host.emit(.activity(sessionID: RemoteDemoData.IDs.docsSession, activity: .working))
        try await waitUntil { c.sessions.first { $0.id == RemoteDemoData.IDs.docsSession }?.activity == .working }

        // Transcript updates only stream for the open chat.
        try await c.open(sessionID: RemoteDemoData.IDs.roomSession)
        #expect(c.openTranscript?.items.count == 6)
        await h.host.emit(.transcriptUpsert(sessionID: RemoteDemoData.IDs.roomSession,
                                             item: .agentText(id: "live-1", text: "Routes", agentID: RemoteDemoData.IDs.agentA, streaming: true)))
        await h.host.emit(.textDelta(sessionID: RemoteDemoData.IDs.roomSession, itemID: "live-1", delta: " done."))
        try await waitUntil {
            if case .agentText(_, let text, _, _)? = c.openTranscript?.items.last { return text == "Routes done." }
            return false
        }

        // A new permission prompt shows up in the hub list and the open chat.
        let ask = PermissionRequest(id: "live-perm", sessionID: RemoteDemoData.IDs.roomSession, kind: "bash", title: "git push")
        await h.host.emit(.permissionAsked(request: ask))
        try await waitUntil { c.permissions.contains { $0.id == "live-perm" } }
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
        try await waitUntil { a.state.isConnected && b.state.isConnected }
        try await pollUntil { await h.server.status.devices.count == 2 }

        await h.host.emit(.sessionRemoved(sessionID: RemoteDemoData.IDs.oldSession))
        try await waitUntil { a.sessions.count == 3 && b.sessions.count == 3 }

        await h.server.setToken(RemoteToken.generate())
        try await waitUntil {
            if case .rejected = a.state, case .rejected = b.state { return true }
            return false
        }
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func silentConnectionIsClosedWithoutHello() async throws {
        let h = try await startServer(helloTimeout: .seconds(3))
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
        #expect(await Self.receiveFails(task, within: TestWait.ceiling))
    }

    @Test func oldPhoneIsToldToUpdate() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.port))
        // Version 1 sent the raw token; version 2 proved it but sent every frame in plaintext.
        let v1 = #"{"v":1,"id":"1","type":"hello","data":{"token":"x","protocolVersion":1,"deviceName":"Old","deviceID":"old"}}"#
        let hellos: [(RemoteServerFrame) throws -> String] = [
            { _ in v1 },
            { challenge in try Self.version2Hello(token: h.token, challenge: challenge) },
        ]
        for makeHello in hellos {
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()
            defer { task.cancel() }
            let challenge = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(try await task.receive()))
            try await task.send(.string(try makeHello(challenge)))
            let message = try await task.receive()
            guard case .string = message else {
                Issue.record("The refusal of an old phone must be plaintext, it cannot open sealed frames")
                continue
            }
            let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(message))
            guard case .error(let error) = reply.message else {
                Issue.record("Expected an error, got \(reply.message.typeName)")
                continue
            }
            #expect(error.code == .unsupportedVersion)
            #expect(error.message == "Update Ensemble on your iPhone to connect to this Mac.")
            #expect(reply.replyTo == "1")
        }
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func versionThreeIsRefused() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        // A hello that is otherwise complete but says it speaks protocol 3 (frames inside it are version 4).
        let phone = try await rawPhone(h, helloVersion: 3)
        defer { phone.task.cancel() }
        guard case .string = phone.reply else {
            Issue.record("The refusal of an old phone must be plaintext")
            return
        }
        let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(phone.reply))
        guard case .error(let error) = reply.message else {
            Issue.record("Expected an error, got \(reply.message.typeName)")
            return
        }
        #expect(error.code == .unsupportedVersion)
        #expect(await Self.connectionEnds(phone.task, within: TestWait.ceiling))
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func helloWithAVersionThreeFrameHeaderIsRefused() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.port))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel() }
        _ = try await task.receive()
        // What a real protocol 3 phone sends: v=3 in the frame header and no ephemeral key.
        let hello = #"{"v":3,"id":"1","type":"hello","data":{"protocolVersion":3,"deviceName":"Old","deviceID":"old","clientNonce":"\#(RemoteHandshake.encode(RemoteHandshake.makeNonce()))","proof":"\#(RemoteHandshake.encode(RemoteHandshake.makeNonce()))","dialedHost":"127.0.0.1","dialedPort":\#(h.port)}}"#
        try await task.send(.string(hello))
        let message = try await task.receive()
        guard case .string = message else {
            Issue.record("The refusal of an old phone must be plaintext")
            return
        }
        let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(message))
        guard case .error(let error) = reply.message else {
            Issue.record("Expected an error, got \(reply.message.typeName)")
            return
        }
        #expect(error.code == .unsupportedVersion)
    }

    @Test func missingOrMalformedEphemeralKeyIsBadRequest() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["ephemeralKey"] = nil },
            { $0["ephemeralKey"] = "not base64 !!" },
            { $0["ephemeralKey"] = RemoteHandshake.encode(Data(repeating: 1, count: 31)) },
            { $0["ephemeralKey"] = RemoteHandshake.encode(Data(count: 32)) },   // all zero: no usable shared secret
        ]
        for edit in edits {
            let phone = try await rawPhone(h, helloEdit: edit)
            defer { phone.task.cancel() }
            let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(phone.reply))
            guard case .error(let error) = reply.message else {
                Issue.record("Expected an error, got \(reply.message.typeName)")
                continue
            }
            #expect(error.code == .badRequest)
            #expect(await Self.connectionEnds(phone.task, within: TestWait.ceiling))
        }
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func phoneTellsTheUserToUpdateAnOlderMac() async throws {
        let fake = try await FakeMac.start(host: "127.0.0.1", port: 0, protocolVersion: 2)
        defer { fake.stop() }
        let pairing = RemotePairing(hosts: ["127.0.0.1"], port: Int(fake.port), token: RemoteToken.generate(), macName: "Old Mac")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test")
        c.handshakeTimeout = .seconds(30)
        c.start()
        defer { c.stop() }
        try await waitUntil {
            if case .rejected(let message) = c.state { return message == "Update Ensemble on your Mac to connect from this iPhone." }
            return false
        }
        #expect(fake.log.all.isEmpty)   // no hello, no proof
    }

    // MARK: Channel encryption

    @Test func framesAfterTheHandshakeAreSealed() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        var phone = try await rawPhone(h)
        defer { phone.task.cancel() }

        // The welcome is the first sealed frame and carries the Mac's proof.
        guard case .data(let sealedWelcome) = phone.reply else {
            Issue.record("The welcome came in plaintext")
            return
        }
        #expect(sealedWelcome.range(of: Data("Loopback Mac".utf8)) == nil)
        let welcome = try phone.open(phone.reply)
        guard case .welcome(let w) = welcome.message else {
            Issue.record("Expected a welcome, got \(welcome.message.typeName)")
            return
        }
        #expect(w.macName == "Loopback Mac")
        let proof = try #require(RemoteHandshake.decode(w.serverProof, expectedCount: 32))
        #expect(RemoteHandshake.isValidServerProof(proof, token: h.token, serverNonce: phone.serverNonce, clientNonce: phone.clientNonce,
                                                   macKey: phone.macKey, phoneKey: phone.phoneKey))

        // A sealed request gets a sealed reply.
        try await phone.task.send(.data(try phone.seal(.hubSnapshot, id: "2")))
        let message = try await phone.task.receive()
        guard case .data(let sealedHub) = message else {
            Issue.record("The hub came in plaintext")
            return
        }
        #expect(sealedHub.range(of: Data("Fix login redirect loop".utf8)) == nil)
        let hub = try phone.open(message)
        #expect(hub.replyTo == "2")
        guard case .hub(let snapshot) = hub.message else {
            Issue.record("Expected the hub, got \(hub.message.typeName)")
            return
        }
        #expect(snapshot.sessions.map(\.title).contains("Fix login redirect loop"))
        #expect(await h.server.status.devices.map(\.name) == ["Raw Phone"])
    }

    @Test func plaintextAfterTheHandshakeClosesTheConnection() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        var phone = try await rawPhone(h)
        _ = try phone.open(phone.reply)
        let text = String(decoding: try RemoteCoding.encode(RemoteClientFrame(Self.sendHi, id: "2")), as: UTF8.self)
        try await phone.task.send(.string(text))
        #expect(await Self.connectionEnds(phone.task, within: TestWait.ceiling))
        try await pollUntil { await h.server.status.devices.isEmpty }
        #expect(await h.host.recordedActions.isEmpty)
    }

    @Test func tamperedFrameClosesTheConnection() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        var phone = try await rawPhone(h)
        _ = try phone.open(phone.reply)
        var sealed = try phone.seal(Self.sendHi, id: "2")
        sealed[sealed.count / 2] ^= 0x01
        try await phone.task.send(.data(sealed))
        #expect(await Self.connectionEnds(phone.task, within: TestWait.ceiling))
        try await pollUntil { await h.server.status.devices.isEmpty }
        #expect(await h.host.recordedActions.isEmpty)
    }

    @Test func replayedFrameClosesTheConnection() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        var phone = try await rawPhone(h)
        _ = try phone.open(phone.reply)
        let sealed = try phone.seal(Self.sendHi, id: "2")
        try await phone.task.send(.data(sealed))
        // Live updates can come before the ack; each one still has to be opened in order.
        var replies: [RemoteServerFrame] = []
        while !replies.contains(where: { $0.replyTo == "2" }) {
            replies.append(try phone.open(try await phone.task.receive()))
        }
        // The same bytes again: a relay replaying "send this message".
        try await phone.task.send(.data(sealed))
        #expect(await Self.connectionEnds(phone.task, within: TestWait.ceiling))
        try await pollUntil { await h.server.status.devices.isEmpty }
        #expect(await h.host.recordedActions.count == 1)
    }

    @Test func phoneThatDialedAnotherAddressIsRefused() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        for (host, port) in [("127.0.0.1", h.port + 1), ("relay.example", h.port)] {
            let phone = try await rawPhone(h, dialedHost: host, dialedPort: port)
            defer { phone.task.cancel() }
            guard case .string = phone.reply else {
                Issue.record("Expected a plaintext refusal for \(host):\(port)")
                continue
            }
            let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(phone.reply))
            guard case .error(let error) = reply.message else {
                Issue.record("Expected an error, got \(reply.message.typeName)")
                continue
            }
            #expect(error.message.contains("dialed an address this Mac does not use"))
        }
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func relayOnTheNetworkSeesOnlySealedFrames() async throws {
        let h = try await startServer(acceptedHosts: ["::1"])
        defer { Task { await h.server.stop() } }
        // A machine in the middle: the phone dials [::1]:port, the relay passes the bytes on to the Mac.
        let relay = try await TCPRelay.start(listenHost: "::1", port: UInt16(h.port), targetHost: "127.0.0.1", targetPort: UInt16(h.port))
        defer { relay.stop() }
        let c = client(h, hosts: ["::1"])
        c.start()
        defer { c.stop() }
        try await waitUntil { c.state == .connected(via: .direct(host: "::1")) && c.sessions.count == 4 }
        try await c.open(sessionID: RemoteDemoData.IDs.fixSession)
        #expect(c.openTranscript?.items.isEmpty == false)

        let seen = relay.fromMac.all
        #expect(seen.count > 1000)
        for secret in ["Loopback Mac", "\"welcome\"", "\"hub\"", "Fix login redirect loop", "SameSite=Strict"] {
            #expect(seen.range(of: Data(secret.utf8)) == nil, "\(secret) crossed the relay in plaintext")
        }
    }

    @Test func relayThatChangesAFrameGetsTheConnectionDropped() async throws {
        let h = try await startServer(acceptedHosts: ["::1"])
        defer { Task { await h.server.stop() } }
        // Flips a bit in every Mac-to-phone binary frame after the welcome.
        let relay = try await TCPRelay.start(listenHost: "::1", port: UInt16(h.port), targetHost: "127.0.0.1",
                                             targetPort: UInt16(h.port), tamperFromBinaryFrame: 1)
        defer { relay.stop() }
        let c = client(h, hosts: ["::1"])
        c.start()
        defer { c.stop() }
        try await waitUntil { (c.lastError ?? "").contains("could not be verified") }
        try await waitUntil { relay.connectionCount >= 2 }   // dropped, then tried again
        #expect(c.sessions.isEmpty)
        #expect(relay.tamperedFrames >= 1)
    }

    @Test func relayThatChangesTheWelcomeIsNotTrusted() async throws {
        let h = try await startServer(acceptedHosts: ["::1"])
        defer { Task { await h.server.stop() } }
        let relay = try await TCPRelay.start(listenHost: "::1", port: UInt16(h.port), targetHost: "127.0.0.1",
                                             targetPort: UInt16(h.port), tamperFromBinaryFrame: 0)
        defer { relay.stop() }
        let c = client(h, hosts: ["::1"])
        c.start()
        defer { c.stop() }
        try await waitUntil { (c.lastError ?? "").contains("could not prove") }
        #expect(!c.state.isConnected)
        #expect(c.sessions.isEmpty)
    }

    @Test func phoneRefusesAHostThatFailsTheServerProofAndNeverSendsTheToken() async throws {
        let fake = try await FakeMac.start(host: "127.0.0.1", port: 0)
        defer { fake.stop() }
        let token = RemoteToken.generate()
        let pairing = RemotePairing(hosts: ["127.0.0.1"], port: Int(fake.port), token: token, macName: "Fake")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test")
        c.handshakeTimeout = .seconds(30)
        c.start()
        defer { c.stop() }

        try await waitUntil { !fake.log.all.isEmpty && (c.lastError ?? "").contains("could not prove") }
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
        try await waitUntil { c.state == .connected(via: .direct(host: "127.0.0.1")) }
        #expect(fake.log.all.count >= 1)
        try await waitUntil { c.sessions.count == 4 }
    }

    @Test func stalledTCPConnectionIsClosedAtTheDeadline() async throws {
        // The pending connection has to be seen before the deadline closes it, so the deadline is not too short.
        let h = try await startServer(helloTimeout: .seconds(3))
        defer { Task { await h.server.stop() } }
        // Plain TCP that never sends the WebSocket upgrade, so the server-side connection never becomes ready.
        let raw = Self.silentTCP(port: h.port)
        defer { raw.cancel() }
        try await pollUntil { await h.server.status.pendingConnections == 1 }
        #expect(await Self.tcpClosedByServer(raw, within: TestWait.ceiling))
        try await pollUntil { await h.server.status.pendingConnections == 0 }
    }

    @Test func handshakeFloodCannotTakePairedPhoneSlots() async throws {
        // The flood's handshake slots are checked before their deadline clears them, so the deadline is not too short.
        let h = try await startServer(helloTimeout: .seconds(5), maxDevices: 2, maxPending: 2, maxPendingPerAddress: 2)
        defer { Task { await h.server.stop() } }
        let phone = client(h)
        phone.start()
        defer { phone.stop() }
        try await waitUntil { phone.state.isConnected }

        // Six silent connections: only two get a handshake slot, the rest are closed at once.
        let flood = (0..<6).map { _ in Self.silentTCP(port: h.port) }
        defer { flood.forEach { $0.cancel() } }
        let closed = ServerClosures(flood)
        try await waitUntil("four connections to be turned away") { closed.count >= 4 }
        let status = await h.server.status
        #expect(status.pendingConnections == 2)
        #expect(closed.count == 4)
        #expect(status.devices.count == 1)
        #expect(phone.state.isConnected)

        // Once the deadline clears them, a second phone gets in.
        let second = client(h)
        second.start()
        defer { second.stop() }
        try await waitUntil { second.state.isConnected }
        #expect(await h.server.status.devices.count == 2)
        #expect(phone.state.isConnected)
    }

    @Test func pendingLimitIsPerAddressToo() async throws {
        let h = try await startServer(maxPending: 8, maxPendingPerAddress: 2)
        defer { Task { await h.server.stop() } }
        let flood = (0..<5).map { _ in Self.silentTCP(port: h.port) }
        defer { flood.forEach { $0.cancel() } }
        let closed = ServerClosures(flood)
        try await waitUntil("three connections to be turned away") { closed.count >= 3 }
        #expect(await h.server.status.pendingConnections == 2)
        #expect(closed.count == 3)
    }

    @Test func extraPhonesBeyondTheDeviceLimitAreTurnedAway() async throws {
        let h = try await startServer(maxDevices: 1)
        defer { Task { await h.server.stop() } }
        let a = client(h)
        a.start()
        defer { a.stop() }
        try await waitUntil { a.state.isConnected }
        let b = client(h)
        b.start()
        defer { b.stop() }
        try await waitUntil { (b.lastError ?? "").contains("most phones") }
        #expect(!b.state.isConnected)
        #expect(await h.server.status.devices.count == 1)
    }

    // MARK: Relay details and rotation

    @Test func relayDetailsAreSavedAfterWelcome() async throws {
        let h = try await startServer(acceptedHosts: ["::1"])
        defer { Task { await h.server.stop() } }

        let firstRelay = RemotePairing.Relay(url: "wss://relay-one.example", mailbox: RelayIdentity.make().mailboxID)
        await h.server.setActiveRelay(firstRelay)

        // Check raw wire order and sealing first: welcome is frame 0, relayDetails is frame 1, both sealed binary.
        var raw = try await rawPhone(h)
        let welcomeFrame = try raw.open(raw.reply)
        guard case .welcome = welcomeFrame.message else {
            raw.task.cancel()
            Issue.record("Expected welcome first, got \(welcomeFrame.message.typeName)")
            return
        }
        let nextMessage = try await raw.task.receive()
        guard case .data(let sealedRelay) = nextMessage else {
            raw.task.cancel()
            Issue.record("Expected relayDetails to arrive as a sealed binary frame")
            return
        }
        #expect(sealedRelay.range(of: Data(firstRelay.url.utf8)) == nil)
        #expect(sealedRelay.range(of: Data(firstRelay.mailbox.utf8)) == nil)
        let detailsFrame = try raw.open(nextMessage)
        #expect(detailsFrame.message == .relayDetails(firstRelay))
        raw.task.cancel()

        // Through a TCP proxy, verify RemoteClient saves the initial relay and later rotates to previousRelay,
        // while no plaintext frame on the wire carries relayDetails, the relay URL or the mailbox ID.
        let proxy = try await TCPRelay.start(listenHost: "::1", port: UInt16(h.port),
                                             targetHost: "127.0.0.1", targetPort: UInt16(h.port))
        defer { proxy.stop() }

        let initialPairing = RemotePairing(hosts: ["::1"], port: h.port, token: h.token, macName: "Loopback Mac")
        let store = RemotePairingStore.inMemory(initial: initialPairing)
        let c = RemoteClient(pairing: initialPairing, deviceName: "Test Phone",
                             deviceID: "test-\(UUID().uuidString)", pairingStore: store)
        c.handshakeTimeout = .seconds(30)
        c.requestTimeout = .seconds(60)
        c.start()
        defer { c.stop() }

        try await waitUntil("initial relayDetails to be saved") {
            c.state == .connected(via: .direct(host: "::1")) && c.pairing.relay == firstRelay
        }
        #expect(c.pairing.previousRelay == nil)
        #expect(store.load()?.relay == firstRelay)
        #expect(store.load()?.previousRelay == nil)

        // When the Mac moves to a second relay while the phone is connected, the old relay becomes previousRelay.
        let secondRelay = RemotePairing.Relay(url: "wss://relay-two.example", mailbox: RelayIdentity.make().mailboxID)
        await h.server.setActiveRelay(secondRelay)
        try await waitUntil("rotated relayDetails to be saved") {
            c.pairing.relay == secondRelay
        }
        #expect(c.pairing.previousRelay == firstRelay)
        #expect(store.load()?.relay == secondRelay)
        #expect(store.load()?.previousRelay == firstRelay)

        // Reconnecting directly does not drop previousRelay before the new relay itself works.
        let countBeforeReconnect = proxy.connectionCount
        c.reconnectNow()
        try await waitUntil("direct reconnect to complete") {
            proxy.connectionCount > countBeforeReconnect && c.state == .connected(via: .direct(host: "::1"))
        }
        try await c.refreshHub()
        #expect(c.pairing.relay == secondRelay)
        #expect(c.pairing.previousRelay == firstRelay)
        #expect(store.load()?.previousRelay == firstRelay)

        // Malformed or insecure relay details are ignored without overwriting the stored pairing.
        await h.server.setActiveRelay(RemotePairing.Relay(url: "ws://insecure.example", mailbox: firstRelay.mailbox))
        await h.server.setActiveRelay(RemotePairing.Relay(url: "wss://relay.example", mailbox: "short"))
        try await c.refreshHub()
        #expect(c.pairing.relay == secondRelay)
        #expect(c.pairing.previousRelay == firstRelay)
        #expect(store.load()?.relay == secondRelay)

        let wireBytes = proxy.fromMac.all
        #expect(!wireBytes.isEmpty)
        for secret in ["relayDetails", firstRelay.url, firstRelay.mailbox, secondRelay.url, secondRelay.mailbox] {
            #expect(wireBytes.range(of: Data(secret.utf8)) == nil, "\(secret) crossed the wire in plaintext")
        }
    }

    @Test func previousRelayIsTriedWhenTheNewOneFails() async throws {
        let oldFake = try await FakeRelay.start()
        let newFake = try await FakeRelay.start()
        let identity = RelayIdentity.make()
        let token = RemoteToken.generate()
        let host = DemoRemoteHost()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Relay Mac",
                                                helloTimeout: .seconds(30))
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()

        let oldRelay = RemotePairing.Relay(url: oldFake.url.absoluteString, mailbox: identity.mailboxID)
        let newRelay = RemotePairing.Relay(url: newFake.url.absoluteString, mailbox: identity.mailboxID)
        newFake.stop()
        await server.setActiveRelay(newRelay)

        let fallbackHost = RelayHost(relayURL: oldFake.url, identity: identity, token: token, server: server)
        await fallbackHost.start()

        do {
            try await pollUntil("fallback relay host to sign in") {
                await fallbackHost.status == .connected && oldFake.hostIsReady(identity.mailboxID)
            }

            let pairing = RemotePairing(hosts: [], port: remoteDefaultPort, token: token, macName: "Relay Mac",
                                        relay: newRelay, previousRelay: oldRelay)
            let store = RemotePairingStore.inMemory(initial: pairing)
            let c = RemoteClient(pairing: pairing, deviceName: "Test Phone",
                                 deviceID: "phone-\(UUID().uuidString)", pairingStore: store)
            c.handshakeTimeout = .seconds(10)
            c.requestTimeout = .seconds(30)
            c.start()

            do {
                try await waitUntil("phone to connect through previousRelay") {
                    c.state == .connected(via: .relay) && c.sessions.count == 4
                }
                #expect(oldFake.phoneConnections(identity.mailboxID).count == 1)
                #expect(c.pairing.relay == newRelay)
                #expect(c.pairing.previousRelay == oldRelay)
                #expect(store.load()?.relay == newRelay)
                #expect(store.load()?.previousRelay == oldRelay)
                c.stop()
            } catch {
                c.stop()
                throw error
            }

            await fallbackHost.stop()
            await server.stop()
            oldFake.stop()
        } catch {
            await fallbackHost.stop()
            await server.stop()
            oldFake.stop()
            throw error
        }
    }

    @Test func previousRelayIsDroppedAfterTheNewOneWorks() async throws {
        let oldFake = try await FakeRelay.start()
        let newFake = try await FakeRelay.start()
        let identity = RelayIdentity.make()
        let token = RemoteToken.generate()
        let host = DemoRemoteHost()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Relay Mac",
                                                helloTimeout: .seconds(30))
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()

        let oldRelay = RemotePairing.Relay(url: oldFake.url.absoluteString, mailbox: identity.mailboxID)
        let newRelay = RemotePairing.Relay(url: newFake.url.absoluteString, mailbox: identity.mailboxID)
        await server.setActiveRelay(newRelay)

        let fallbackHost = RelayHost(relayURL: oldFake.url, identity: identity, token: token, server: server)
        let primaryHost = RelayHost(relayURL: newFake.url, identity: identity, token: token, server: server)
        await fallbackHost.start()
        await primaryHost.start()

        do {
            try await pollUntil("both relay hosts to sign in") {
                let fallbackStatus = await fallbackHost.status
                let primaryStatus = await primaryHost.status
                return fallbackStatus == .connected
                    && primaryStatus == .connected
                    && oldFake.hostIsReady(identity.mailboxID)
                    && newFake.hostIsReady(identity.mailboxID)
            }

            let pairing = RemotePairing(hosts: [], port: remoteDefaultPort, token: token, macName: "Relay Mac",
                                        relay: newRelay, previousRelay: oldRelay)
            let store = RemotePairingStore.inMemory(initial: pairing)
            let c = RemoteClient(pairing: pairing, deviceName: "Test Phone",
                                 deviceID: "phone-\(UUID().uuidString)", pairingStore: store)
            c.handshakeTimeout = .seconds(10)
            c.requestTimeout = .seconds(30)
            c.start()

            do {
                try await waitUntil("phone to connect through the new relay and drop previousRelay") {
                    c.state == .connected(via: .relay) && c.sessions.count == 4 && c.pairing.previousRelay == nil
                }
                #expect(newFake.phoneConnections(identity.mailboxID).count == 1)
                #expect(oldFake.phoneConnections(identity.mailboxID).isEmpty)
                #expect(c.pairing.relay == newRelay)
                #expect(c.pairing.previousRelay == nil)
                #expect(store.load()?.relay == newRelay)
                #expect(store.load()?.previousRelay == nil)
                c.stop()
            } catch {
                c.stop()
                throw error
            }

            await primaryHost.stop()
            await fallbackHost.stop()
            await server.stop()
            newFake.stop()
            oldFake.stop()
        } catch {
            await primaryHost.stop()
            await fallbackHost.stop()
            await server.stop()
            newFake.stop()
            oldFake.stop()
            throw error
        }
    }

    // MARK: Helpers

    static let sendHi = RemoteClientMessage.sendMessage(RemoteSendMessage(target: .session(RemoteDemoData.IDs.fixSession), text: "hi"))

    /// A phone written out by hand on top of URLSessionWebSocketTask, so tests can send exactly the bytes they want.
    struct RawPhone {
        let task: URLSessionWebSocketTask
        let serverNonce: Data
        let clientNonce: Data
        let macKey: Data
        let phoneKey: Data
        var channel: RemoteChannel
        /// The Mac's answer to the hello, as it came off the socket.
        let reply: URLSessionWebSocketTask.Message

        mutating func seal(_ message: RemoteClientMessage, id: String) throws -> Data {
            try channel.seal(try RemoteCoding.encode(RemoteClientFrame(message, id: id)))
        }

        /// Opens the next sealed frame from the Mac; plaintext is an error.
        mutating func open(_ message: URLSessionWebSocketTask.Message) throws -> RemoteServerFrame {
            guard case .data(let sealed) = message else { throw RemoteChannel.Failure.rejected }
            return try RemoteCoding.decode(RemoteServerFrame.self, from: try channel.open(sealed))
        }
    }

    /// Connects, answers the challenge with a valid proof and returns the Mac's reply without reading it.
    /// - Parameter helloEdit: changes the hello's JSON before it is sent, for tests that need a broken one.
    func rawPhone(_ h: Harness, dialedHost: String = "127.0.0.1", dialedPort: Int? = nil, helloVersion: Int = remoteProtocolVersion,
                  helloEdit: (inout [String: Any]) -> Void = { _ in }) async throws -> RawPhone {
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.port))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let first = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(try await task.receive()))
        guard case .challenge(let challenge) = first.message else { throw RemoteError(.badRequest, "no challenge") }
        let serverNonce = try #require(RemoteHandshake.decode(challenge.serverNonce, expectedCount: 32))
        let macKey = try #require(RemoteHandshake.decode(challenge.ephemeralKey, expectedCount: 32))
        let clientNonce = RemoteHandshake.makeNonce()
        let phoneKeyPair = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = phoneKeyPair.publicKey.rawRepresentation
        let secret = try phoneKeyPair.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey))
            .withUnsafeBytes { Data($0) }
        let proof = RemoteHandshake.clientProof(token: h.token, serverNonce: serverNonce, clientNonce: clientNonce,
                                                macKey: macKey, phoneKey: phoneKey)
        let port = dialedPort ?? h.port
        let hello = RemoteHello(protocolVersion: helloVersion, deviceName: "Raw Phone", deviceID: "raw",
                                clientNonce: RemoteHandshake.encode(clientNonce), ephemeralKey: RemoteHandshake.encode(phoneKey),
                                proof: RemoteHandshake.encode(proof), dialedHost: dialedHost, dialedPort: port)
        var json = try #require(try JSONSerialization.jsonObject(
            with: try RemoteCoding.encode(RemoteClientFrame(.hello(hello), id: "1"))) as? [String: Any])
        var body = try #require(json["data"] as? [String: Any])
        helloEdit(&body)
        json["data"] = body
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        try await task.send(.string(text))
        let reply = try await task.receive()
        let channel = RemoteChannel(token: h.token, sharedSecret: secret, serverNonce: serverNonce, clientNonce: clientNonce,
                                    dialedHost: dialedHost, dialedPort: port, role: .client)
        return RawPhone(task: task, serverNonce: serverNonce, clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey,
                        channel: channel, reply: reply)
    }

    /// A hello as a version 2 phone sent it: a valid proof, and no dialed host or port.
    static func version2Hello(token: String, challenge frame: RemoteServerFrame) throws -> String {
        guard case .challenge(let challenge) = frame.message,
              let serverNonce = RemoteHandshake.decode(challenge.serverNonce, expectedCount: 32) else {
            throw RemoteError(.badRequest, "no challenge")
        }
        let clientNonce = RemoteHandshake.makeNonce()
        let proof = RemoteHandshake.clientProof(token: token, serverNonce: serverNonce, clientNonce: clientNonce,
                                                macKey: Data(repeating: 0, count: 32), phoneKey: Data(repeating: 0, count: 32))
        return #"{"v":2,"id":"1","type":"hello","data":{"protocolVersion":2,"deviceName":"Old","deviceID":"old","clientNonce":""#
            + RemoteHandshake.encode(clientNonce) + #"","proof":""# + RemoteHandshake.encode(proof) + #""}}"#
    }

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

    /// True when the Mac closes the socket within `timeout`. Frames that were already on the way are skipped.
    nonisolated static func connectionEnds(_ task: URLSessionWebSocketTask, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    while true { _ = try await task.receive() }
                } catch {
                    return true
                }
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
        try await waitUntil { c.state.isConnected }
        await h.server.stop()
        try await waitUntil {
            switch c.state {
            case .waiting, .connecting: return true
            default: return false
            }
        }
        #expect(await h.server.status.running == false)
    }

    @Test func inProcessClientWorksWithoutNetwork() async throws {
        let host = DemoRemoteHost()
        let c = RemoteClient(inProcessHost: host)
        c.start()
        defer { c.stop() }
        try await waitUntil { c.sessions.count == 4 }
        try await c.open(sessionID: RemoteDemoData.IDs.fixSession)
        try await c.send("hi", to: .session(RemoteDemoData.IDs.fixSession))
        try await waitUntil {
            if case .user(_, let text, _)? = c.openTranscript?.items.last { return text == "hi" }
            return false
        }
    }
}
/// Counts how many of some TCP connections the server has closed.
final class ServerClosures: Sendable {
    private let closed = Mutex(0)

    init(_ connections: [NWConnection]) {
        for connection in connections { watch(connection) }
    }

    var count: Int { closed.withLock { $0 } }

    private func watch(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] _, _, isComplete, error in
            if isComplete || error != nil {
                closed.withLock { $0 += 1 }
            } else {
                watch(connection)
            }
        }
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

    /// - Parameter protocolVersion: the version it claims in the challenge (an older Mac when below the phone's).
    static func start(host: String, port: UInt16, protocolVersion: Int = remoteProtocolVersion) async throws -> FakeMac {
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
                    let challenge = RemoteChallenge(protocolVersion: protocolVersion,
                                                    serverNonce: RemoteHandshake.encode(RemoteHandshake.makeNonce()),
                                                    ephemeralKey: RemoteHandshake.encode(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
                    send(.challenge(challenge), version: protocolVersion, on: connection)
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

    private static func send(_ message: RemoteServerMessage, replyTo: String? = nil, version: Int = remoteProtocolVersion,
                             on connection: NWConnection) {
        guard var data = try? RemoteCoding.encode(RemoteServerFrame(message, replyTo: replyTo, version: version)) else { return }
        // A Mac older than protocol 4 sends a challenge without an ephemeral key.
        if version < 4, case .challenge = message,
           var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var body = json["data"] as? [String: Any] {
            body["ephemeralKey"] = nil
            json["data"] = body
            data = (try? JSONSerialization.data(withJSONObject: json)) ?? data
        }
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// Thread-safe byte and counter store for `TCPRelay`.
final class RelayLog: Sendable {
    private let bytes = Mutex(Data())
    private let counts = Mutex((connections: 0, tampered: 0))
    func append(_ data: Data) { bytes.withLock { $0.append(data) } }
    var all: Data { bytes.withLock { $0 } }
    func connected() { counts.withLock { $0.connections += 1 } }
    func tampered() { counts.withLock { $0.tampered += 1 } }
    var connections: Int { counts.withLock { $0.connections } }
    var tamperedFrames: Int { counts.withLock { $0.tampered } }
}

/// Binary frames seen on one relayed connection.
final class RelayFrameCounter: Sendable {
    private let value = Mutex(0)
    /// Returns the index of this frame and moves on.
    func next() -> Int { value.withLock { v in defer { v += 1 }; return v } }
}

/// A machine in the middle on the local network: passes raw TCP between the phone and the Mac, records what
/// the Mac sends, and can flip a bit in the Mac's binary WebSocket frames.
final class TCPRelay: Sendable {
    let listener: NWListener
    let fromMac: RelayLog

    var connectionCount: Int { fromMac.connections }
    var tamperedFrames: Int { fromMac.tamperedFrames }

    private init(listener: NWListener, log: RelayLog) {
        self.listener = listener
        self.fromMac = log
    }

    /// - Parameter tamperFromBinaryFrame: on each connection, flip the last byte of every Mac-to-phone binary
    ///   frame from this index on (0 is the welcome). `nil` passes everything through unchanged.
    static func start(listenHost: String, port: UInt16, targetHost: String, targetPort: UInt16,
                      tamperFromBinaryFrame: Int? = nil) async throws -> TCPRelay {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(listenHost), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "tcp-relay")
        let log = RelayLog()
        listener.newConnectionHandler = { phone in
            log.connected()
            let mac = NWConnection(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
            let frames = RelayFrameCounter()
            phone.start(queue: queue)
            mac.start(queue: queue)
            pump(from: phone, to: mac) { $0 }
            pump(from: mac, to: phone) { chunk in
                log.append(chunk)
                // Mac-to-phone frames are not masked; 0x82 is a final binary frame. On loopback each sealed
                // frame arrives as its own chunk, so the last byte of the chunk is the last byte of the tag.
                guard let from = tamperFromBinaryFrame, chunk.first == 0x82 else { return chunk }
                guard frames.next() >= from else { return chunk }
                var changed = Data(chunk)
                changed[changed.count - 1] ^= 0x01
                log.tampered()
                return changed
            }
        }
        let once = RemoteResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return TCPRelay(listener: listener, log: log)
    }

    func stop() {
        listener.cancel()
    }

    private static func pump(from source: NWConnection, to destination: NWConnection, transform: @escaping @Sendable (Data) -> Data) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: transform(data), completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            pump(from: source, to: destination, transform: transform)
        }
    }
}
#endif
