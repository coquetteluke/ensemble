#if os(macOS)
import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import EnsembleKit

/// A real `RelayHost` and `RemoteServer` against `FakeRelay`, with phones written out by hand on URLSession.
@Suite(.serialized) struct RelayHostTests {
    struct Harness {
        let fake: FakeRelay
        let server: RemoteServer
        let token: String
        let identity: RelayIdentity
        let relay: RelayHost
        let serverPort: Int

        var mailbox: String { identity.mailboxID }
        var channelHost: String { RelayIdentity.channelHost(relayURL: fake.url, mailboxID: identity.mailboxID) }
        var accessKey: SymmetricKey { RelayIdentity.accessKey(token: token) }

        func stop() async {
            await relay.stop()
            await server.stop()
            fake.stop()
        }
    }

    /// - Parameter prepare: sets up the fake relay before the host starts.
    func start(timing: RelayHost.Timing = RelayHost.Timing(),
               maxPending: Int = 8,
               maxRelayedPending: Int = 4,
               prepare: (FakeRelay, RelayIdentity) -> Void = { _, _ in }) async throws -> Harness {
        let fake = try await FakeRelay.start()
        let identity = RelayIdentity.make()
        prepare(fake, identity)
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Relay Mac",
                                                helloTimeout: .seconds(30), maxPending: maxPending,
                                                maxRelayedPending: maxRelayedPending)
        let server = RemoteServer(host: DemoRemoteHost(), token: token, configuration: config)
        try await server.start()
        let port = try #require(await server.boundPort)
        let relay = RelayHost(relayURL: fake.url, identity: identity, token: token, server: server, timing: timing)
        await relay.start()
        return Harness(fake: fake, server: server, token: token, identity: identity, relay: relay, serverPort: Int(port))
    }

    func connected(_ h: Harness) async throws {
        try await pollUntil("the relay host to sign in") { await h.relay.status == .connected && h.fake.hostIsReady(h.mailbox) }
    }

    // MARK: Mailbox

    @Test func claimsOnFirstStartAndAuthenticatesOnTheSecond() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)
        // The relay has never seen this mailbox, so the sign-in is refused as unknown (4004) and the host claims it.
        #expect(h.fake.hostFrames(h.mailbox) == ["auth", "claim"])
        #expect(h.fake.hostKey(h.mailbox) == h.identity.hostKey.publicKey.rawRepresentation)
        #expect(h.fake.accessKey(h.mailbox) == h.accessKey.withUnsafeBytes { Data($0) })

        // A second host with the same identity (the app started again) only signs in.
        await h.relay.stop()
        try await pollUntil { !h.fake.hostIsReady(h.mailbox) }
        let again = RelayHost(relayURL: h.fake.url, identity: h.identity, token: h.token, server: h.server)
        await again.start()
        defer { Task { await again.stop() } }
        try await pollUntil { await again.status == .connected && h.fake.hostIsReady(h.mailbox) }
        #expect(h.fake.hostFrames(h.mailbox) == ["auth", "claim", "auth"])
    }

    @Test func forgottenMailboxIsClaimedAgainWithTheSameIDAndKey() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)
        let key = try #require(h.fake.hostKey(h.mailbox))

        // A redeploy that lost storage: the control socket drops and the relay no longer knows the mailbox.
        h.fake.forget(h.mailbox, closingWith: 1012)
        try await pollUntil("the host to claim again") { h.fake.hostFrames(h.mailbox).count >= 4 }
        try await connected(h)
        #expect(h.fake.hostFrames(h.mailbox) == ["auth", "claim", "auth", "claim"])
        #expect(h.fake.hostKey(h.mailbox) == key)

        // The relay's clean-up closes with 4004 itself: claimed again at once.
        h.fake.forget(h.mailbox, closingWith: 4004)
        try await pollUntil("the host to claim a third time") { h.fake.hostFrames(h.mailbox).count >= 5 }
        try await connected(h)
        #expect(h.fake.hostFrames(h.mailbox).suffix(1) == ["claim"])
        #expect(h.fake.hostKey(h.mailbox) == key)
    }

    @Test func claimRefusedAsTakenSetsMailboxTaken() async throws {
        let h = try await start { fake, identity in fake.takeNextClaim(identity.mailboxID) }
        defer { Task { await h.stop() } }
        try await pollUntil { await h.relay.status == .mailboxTaken }
        #expect(h.fake.hostFrames(h.mailbox) == ["auth", "claim"])
        // It does not keep trying a mailbox it cannot have.
        try await Task.sleep(for: .seconds(3))
        #expect(h.fake.hostFrames(h.mailbox) == ["auth", "claim"])
        #expect(await h.relay.status == .mailboxTaken)
    }

    @Test func mailboxHeldByAnotherKeySetsMailboxTaken() async throws {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let h = try await start { fake, identity in
            fake.hold(identity.mailboxID, hostKey: other, accessKey: FakeRelay.randomBytes(32))
        }
        defer { Task { await h.stop() } }
        try await pollUntil { await h.relay.status == .mailboxTaken }
        #expect(h.fake.hostFrames(h.mailbox) == ["auth"])
        #expect(h.fake.hostKey(h.mailbox) == other)
    }

    @Test func limitFrameSetsLimitReached() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)
        let resetsAt = Int(Date().timeIntervalSince1970) + 3600
        h.fake.sendLimit(h.mailbox, resetsAt: resetsAt)
        try await pollUntil { await h.relay.status == .limitReached(resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt))) }
        // The control socket stays signed in.
        #expect(h.fake.hostIsReady(h.mailbox))
    }

    @Test func controlSocketSendsPingAsItsKeepAlive() async throws {
        var timing = RelayHost.Timing()
        timing.pingInterval = .milliseconds(200)
        let h = try await start(timing: timing)
        defer { Task { await h.stop() } }
        try await connected(h)
        try await pollUntil { h.fake.pings >= 3 }
        #expect(await h.relay.status == .connected)
        #expect(h.fake.hostFrames(h.mailbox) == ["auth", "claim"])
    }

    // MARK: Phones

    @Test func phoneNoticeOpensADataSocketAndTheHandshakeCompletes() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)

        let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
        defer { task.cancel() }
        var phone = try await RelayPhone.handshake(over: task, token: h.token, dialedHost: h.channelHost)
        let welcome = try phone.open(phone.reply)
        guard case .welcome(let w) = welcome.message else {
            Issue.record("Expected a welcome, got \(welcome.message.typeName)")
            return
        }
        #expect(w.macName == "Relay Mac")
        let proof = try #require(RemoteHandshake.decode(w.serverProof, expectedCount: 32))
        #expect(RemoteHandshake.isValidServerProof(proof, token: h.token, serverNonce: phone.serverNonce, clientNonce: phone.clientNonce,
                                                   macKey: phone.macKey, phoneKey: phone.phoneKey))

        // Sealed requests go through the relay both ways.
        try await task.send(.data(try phone.seal(.hubSnapshot, id: "2")))
        var reply = try phone.open(try await task.receive())
        while reply.replyTo != "2" { reply = try phone.open(try await task.receive()) }
        guard case .hub(let hub) = reply.message else {
            Issue.record("Expected the hub, got \(reply.message.typeName)")
            return
        }
        #expect(!hub.sessions.isEmpty)

        let devices = await h.server.status.devices
        #expect(devices.count == 1)
        #expect(devices.first?.address.hasPrefix("relay:") == true)
        #expect(h.fake.dataSocketCount == 1)
        #expect(h.fake.dataSocketsWithoutToken == 0)
        #expect(h.fake.badHandshakes(h.mailbox).isEmpty)
    }

    @Test func badHandshakeOnARelayedConnectionIsReported() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)

        // This phone knows the access key but not the pairing token.
        let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
        defer { task.cancel() }
        let phone = try await RelayPhone.handshake(over: task, token: RemoteToken.generate(), dialedHost: h.channelHost)
        #expect(try RelayPhone.refusal(phone.reply)?.code == .unauthorized)
        try await pollUntil("the bad handshake to reach the relay") { !h.fake.badHandshakes(h.mailbox).isEmpty }
        #expect(h.fake.badHandshakes(h.mailbox) == h.fake.phoneConnections(h.mailbox))
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func failedRelayedPhonesDoNotBlockAGoodOne() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)

        // Five strangers fail the pairing check through the relay. Direct, that many failures from one address
        // block it; relayed phones are counted per relay connection, so they do not block each other.
        for _ in 0..<5 {
            let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
            let phone = try await RelayPhone.handshake(over: task, token: RemoteToken.generate(), dialedHost: h.channelHost)
            #expect(try RelayPhone.refusal(phone.reply)?.code == .unauthorized)
            task.cancel()
        }
        try await pollUntil { h.fake.badHandshakes(h.mailbox).count == 5 }

        let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
        defer { task.cancel() }
        var phone = try await RelayPhone.handshake(over: task, token: h.token, dialedHost: h.channelHost)
        guard case .welcome = try phone.open(phone.reply).message else {
            Issue.record("The sixth phone was not let in")
            return
        }
        #expect(await h.server.status.devices.count == 1)
    }

    @Test func relayedPendingIsSeparateFromDirectPendingAndCappedAtMaxRelayedPending() async throws {
        #expect(RemoteServer.Configuration().maxRelayedPending == 4)

        // Direct pending is 2 while relayed pending is 3, so saturating relayed pending also exceeds maxPending.
        let h = try await start(maxPending: 2, maxRelayedPending: 3)
        defer { Task { await h.stop() } }
        try await connected(h)

        var stalledRelayed: [URLSessionWebSocketTask] = []
        defer { stalledRelayed.forEach { $0.cancel() } }
        for _ in 0..<3 {
            let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
            stalledRelayed.append(task)
            let first = try RemoteCoding.decode(RemoteServerFrame.self, from: RelayPhone.data(try await task.receive()))
            guard case .challenge = first.message else {
                Issue.record("Expected challenge on relayed connection within maxRelayedPending")
                return
            }
        }
        #expect(await h.server.status.pendingConnections == 3)

        // The next unauthenticated relayed connection hits maxRelayedPending and is closed before getting a challenge.
        let fourthGotChallenge: Bool = await {
            do {
                let fourth = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
                defer { fourth.cancel() }
                let frame = try RemoteCoding.decode(RemoteServerFrame.self, from: RelayPhone.data(try await fourth.receive()))
                if case .challenge = frame.message { return true }
                return false
            } catch {
                return false
            }
        }()
        #expect(!fourthGotChallenge)
        #expect(await h.server.status.pendingConnections == 3)

        // A direct connection still succeeds because relayed handshakes do not count against direct maxPending.
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.serverPort))
        let direct = URLSession.shared.webSocketTask(with: url)
        direct.resume()
        defer { direct.cancel() }
        var directPhone = try await RelayPhone.handshake(over: direct, token: h.token, dialedHost: "127.0.0.1",
                                                         dialedPort: h.serverPort)
        guard case .welcome(let w) = try directPhone.open(directPhone.reply).message else {
            Issue.record("Direct phone should succeed while relayed pending slots are full")
            return
        }
        #expect(w.macName == "Relay Mac")
        #expect(await h.server.status.devices.count == 1)

        // Stopping the relay host removes its channel host and drops pending relayed handshakes immediately,
        // without touching the direct phone.
        await h.relay.stop()
        try await pollUntil("pending relayed handshakes to be cancelled") {
            await h.server.status.pendingConnections == 0
        }
        #expect(await h.server.status.devices.count == 1)

        // Keep 2-argument adopt source compatibility covered.
        await h.server.stop()
        await h.server.adopt(NWConnection(host: "127.0.0.1", port: 1, using: .tcp),
                             relayConnection: "abcdefghijklmnopqrstuv")
    }

    @Test func relayedPhoneMustHaveDialedTheRelayIdentity() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)

        // Through the relay, the phone must have dialed relay:<host>/<mailbox> on 443, not one of the Mac's direct
        // addresses, and not another mailbox.
        let wrong = [("127.0.0.1", h.serverPort), (h.channelHost, h.serverPort),
                     (RelayIdentity.channelHost(relayURL: h.fake.url, mailboxID: RelayIdentity.make().mailboxID), 443)]
        for (host, port) in wrong {
            let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
            let phone = try await RelayPhone.handshake(over: task, token: h.token, dialedHost: host, dialedPort: port)
            let error = try RelayPhone.refusal(phone.reply)
            #expect(error?.message.contains("dialed an address this Mac does not use") == true, "\(host):\(port)")
            task.cancel()
        }

        // And a phone that reached the Mac directly cannot say it came through the relay.
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.serverPort))
        let direct = URLSession.shared.webSocketTask(with: url)
        direct.resume()
        defer { direct.cancel() }
        let phone = try await RelayPhone.handshake(over: direct, token: h.token, dialedHost: h.channelHost)
        #expect(try RelayPhone.refusal(phone.reply)?.message.contains("dialed an address this Mac does not use") == true)
        #expect(await h.server.status.devices.isEmpty)
    }

    @Test func stoppingTheHostClosesItsControlSocketAndRelayedPhones() async throws {
        let h = try await start()
        defer { Task { await h.stop() } }
        try await connected(h)
        let task = try await h.fake.dialPhone(mailbox: h.mailbox, accessKey: h.accessKey)
        defer { task.cancel() }
        var phone = try await RelayPhone.handshake(over: task, token: h.token, dialedHost: h.channelHost)
        _ = try phone.open(phone.reply)
        try await pollUntil { await h.server.status.devices.count == 1 }

        await h.relay.stop()
        #expect(await h.relay.status == .off)
        try await pollUntil("the relayed phone to be dropped") { await h.server.status.devices.isEmpty }
        try await pollUntil("the control socket to close") { !h.fake.hostIsReady(h.mailbox) }
    }

    // MARK: Addresses and retries

    @Test func plainWebSocketsOnlyForLoopback() async throws {
        for (text, allowed) in [("wss://relay.coquettemc.com", true), ("wss://relay.example:8443", true),
                                ("wss://relay.example:8443/base", false), ("wss://relay.example/?q=1", false),
                                ("ws://127.0.0.1:8787", true), ("ws://localhost:8787", true),
                                ("ws://relay.coquettemc.com", false), ("ws://192.168.1.2:8787", false),
                                ("https://relay.coquettemc.com", false), ("wss://", false)] {
            let url = try #require(URL(string: text))
            #expect(RelayHost.isAllowed(url) == allowed, "\(text)")
        }

        let server = RemoteServer(host: DemoRemoteHost(), token: RemoteToken.generate(),
                                  configuration: RemoteServer.Configuration(port: 0))
        let relay = RelayHost(relayURL: try #require(URL(string: "ws://relay.example:8787")), identity: .make(),
                              token: RemoteToken.generate(), server: server)
        await relay.start()
        defer { Task { await relay.stop() } }
        guard case .unreachable(let reason) = await relay.status else {
            Issue.record("A plain ws:// relay address that is not loopback must not be dialed")
            return
        }
        #expect(reason.contains("wss://"))
    }

    @Test func reconnectsBackOffToAMinute() {
        let delays = (0..<9).map { RelayHost.backoff(failures: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test func preChallengeUnauthorizedDoesNotSetMailboxTaken() async throws {
        let scripted = try await ScriptedRelayHostServer.start(mode: .preChallengeUnauthorizedOnce)
        defer { scripted.stop() }

        let token = RemoteToken.generate()
        let server = RemoteServer(host: DemoRemoteHost(), token: token,
                                  configuration: RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Relay Mac"))
        try await server.start()
        defer { Task { await server.stop() } }

        let relay = RelayHost(relayURL: scripted.url, identity: .make(), token: token, server: server)
        await relay.start()
        defer { Task { await relay.stop() } }

        try await pollUntil("the host to retry past pre-challenge 4001 and sign in") {
            await relay.status == .connected
        }
        #expect(scripted.recordedFrames == ["auth"])
    }

    @Test func droppedClaimAfterCommitRetriesWithAuthAndConnects() async throws {
        let scripted = try await ScriptedRelayHostServer.start(mode: .dropClaimAfterCommit)
        defer { scripted.stop() }

        let token = RemoteToken.generate()
        let server = RemoteServer(host: DemoRemoteHost(), token: token,
                                  configuration: RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Relay Mac"))
        try await server.start()
        defer { Task { await server.stop() } }

        let relay = RelayHost(relayURL: scripted.url, identity: .make(), token: token, server: server)
        await relay.start()
        defer { Task { await relay.stop() } }

        try await pollUntil("the host to retry a dropped claim with auth and sign in") {
            await relay.status == .connected
        }
        #expect(scripted.recordedFrames == ["auth", "claim", "auth"])
    }
}

/// Minimal scripted WebSocket server for host control-socket edge cases (pre-challenge closes and dropped claims).
private final class ScriptedRelayHostServer: Sendable {
    enum Mode: Sendable {
        case preChallengeUnauthorizedOnce
        case dropClaimAfterCommit
    }

    private struct State {
        var connectionCount = 0
        var frames: [String] = []
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let mode: Mode
    private let state = Mutex(State())

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }
    var recordedFrames: [String] { state.withLock { $0.frames } }

    private init(listener: NWListener, queue: DispatchQueue, mode: Mode) {
        self.listener = listener
        self.queue = queue
        self.mode = mode
    }

    static func start(mode: Mode) async throws -> ScriptedRelayHostServer {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "scripted-relay-host-server")
        let server = ScriptedRelayHostServer(listener: listener, queue: queue, mode: mode)
        listener.newConnectionHandler = { [weak server] connection in
            guard let server else {
                connection.cancel()
                return
            }
            server.accept(connection)
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
        return server
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            let attempt = self.state.withLock { s -> Int in
                s.connectionCount += 1
                return s.connectionCount
            }
            if self.mode == .preChallengeUnauthorizedOnce, attempt == 1 {
                Self.sendClose(code: RelayWire.CloseCode.unauthorized, on: connection)
                return
            }
            let nonce = RemoteHandshake.encode(RemoteHandshake.makeNonce())
            Self.sendText(#"{"t":"challenge","nonce":"\#(nonce)"}"#, on: connection)
            self.receive(on: connection, attempt: attempt)
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, attempt: Int) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text,
                  let content else { return }
            let text = String(decoding: content, as: UTF8.self)
            if text == "ping" {
                Self.sendText("pong", on: connection)
                self.receive(on: connection, attempt: attempt)
                return
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any],
                  let type = obj["t"] as? String else {
                Self.sendClose(code: RelayWire.CloseCode.protocolError, on: connection)
                return
            }
            self.state.withLock { $0.frames.append(type) }

            switch self.mode {
            case .preChallengeUnauthorizedOnce:
                if type == "auth" {
                    Self.sendText(#"{"t":"ready"}"#, on: connection)
                    self.receive(on: connection, attempt: attempt)
                } else {
                    Self.sendClose(code: RelayWire.CloseCode.protocolError, on: connection)
                }
            case .dropClaimAfterCommit:
                if type == "auth", attempt == 1 {
                    Self.sendClose(code: RelayWire.CloseCode.noMailbox, on: connection)
                } else if type == "claim", attempt == 2 {
                    // Simulate a transport drop right after storage commit and before ready reaches the host.
                    connection.cancel()
                } else if type == "auth", attempt >= 3 {
                    Self.sendText(#"{"t":"ready"}"#, on: connection)
                    self.receive(on: connection, attempt: attempt)
                } else if type == "claim", attempt >= 3 {
                    Self.sendClose(code: RelayWire.CloseCode.taken, on: connection)
                } else {
                    Self.sendClose(code: RelayWire.CloseCode.protocolError, on: connection)
                }
            }
        }
    }

    private static func sendText(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private static func sendClose(code: UInt16, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// A phone's side of the Ensemble handshake over a socket that already reaches the Mac (through the relay or
/// direct), written out by hand so tests choose the token and the dialed address.
struct RelayPhone {
    let task: URLSessionWebSocketTask
    let serverNonce: Data
    let clientNonce: Data
    let macKey: Data
    let phoneKey: Data
    var channel: RemoteChannel
    /// The Mac's answer to the hello, as it came off the socket.
    let reply: URLSessionWebSocketTask.Message

    /// Reads the Mac's challenge, answers it with a proof for `token` and returns the Mac's reply unread.
    static func handshake(over task: URLSessionWebSocketTask, token: String, dialedHost: String,
                          dialedPort: Int = RelayIdentity.channelPort) async throws -> RelayPhone {
        let first = try RemoteCoding.decode(RemoteServerFrame.self, from: data(try await task.receive()))
        guard case .challenge(let challenge) = first.message else { throw RemoteError(.badRequest, "no challenge") }
        let serverNonce = try #require(RemoteHandshake.decode(challenge.serverNonce, expectedCount: 32))
        let macKey = try #require(RemoteHandshake.decode(challenge.ephemeralKey, expectedCount: 32))
        let clientNonce = RemoteHandshake.makeNonce()
        let keyPair = RemoteHandshake.makeKeyPair()
        let phoneKey = keyPair.publicKey.rawRepresentation
        let secret = try #require(RemoteHandshake.sharedSecret(privateKey: keyPair, peerKey: macKey))
        let proof = RemoteHandshake.clientProof(token: token, serverNonce: serverNonce, clientNonce: clientNonce,
                                                macKey: macKey, phoneKey: phoneKey)
        let hello = RemoteHello(deviceName: "Relay Phone", deviceID: "relay-phone",
                                clientNonce: RemoteHandshake.encode(clientNonce), ephemeralKey: RemoteHandshake.encode(phoneKey),
                                proof: RemoteHandshake.encode(proof), dialedHost: dialedHost, dialedPort: dialedPort)
        let text = String(decoding: try RemoteCoding.encode(RemoteClientFrame(.hello(hello), id: "1")), as: UTF8.self)
        try await task.send(.string(text))
        let reply = try await task.receive()
        let channel = RemoteChannel(token: token, sharedSecret: secret, serverNonce: serverNonce, clientNonce: clientNonce,
                                    dialedHost: dialedHost, dialedPort: dialedPort, role: .client)
        return RelayPhone(task: task, serverNonce: serverNonce, clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey,
                          channel: channel, reply: reply)
    }

    mutating func seal(_ message: RemoteClientMessage, id: String) throws -> Data {
        try channel.seal(try RemoteCoding.encode(RemoteClientFrame(message, id: id)))
    }

    /// Opens the next sealed frame from the Mac; plaintext is an error.
    mutating func open(_ message: URLSessionWebSocketTask.Message) throws -> RemoteServerFrame {
        guard case .data(let sealed) = message else { throw RemoteChannel.Failure.rejected }
        return try RemoteCoding.decode(RemoteServerFrame.self, from: try channel.open(sealed))
    }

    /// The Mac's plaintext refusal, or nil when the reply is not one.
    static func refusal(_ message: URLSessionWebSocketTask.Message) throws -> RemoteError? {
        guard case .string = message else { return nil }
        let frame = try RemoteCoding.decode(RemoteServerFrame.self, from: data(message))
        guard case .error(let error) = frame.message else { return nil }
        return error
    }

    static func data(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
    }
}
#endif
