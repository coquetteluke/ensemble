#if os(macOS)
import CryptoKit
import Foundation
import Network
import Testing
@testable import EnsembleKit

/// Runs the real `RemoteClient`, `RelayDialer`, `RelayHost` and `RemoteServer` against `FakeRelay`.
@MainActor @Suite(.serialized) struct RemoteRelayClientTests {
    final class Harness: Sendable {
        let host: DemoRemoteHost
        let fake: FakeRelay
        let server: RemoteServer
        let token: String
        let identity: RelayIdentity
        let relay: RelayHost
        let serverPort: Int

        var mailbox: String { identity.mailboxID }
        var pairingRelay: RemotePairing.Relay {
            RemotePairing.Relay(url: fake.url.absoluteString, mailbox: identity.mailboxID)
        }

        init(host: DemoRemoteHost, fake: FakeRelay, server: RemoteServer, token: String, identity: RelayIdentity,
             relay: RelayHost, serverPort: Int) {
            self.host = host
            self.fake = fake
            self.server = server
            self.token = token
            self.identity = identity
            self.relay = relay
            self.serverPort = serverPort
        }

        func stop() async {
            await relay.stop()
            await server.stop()
            fake.stop()
        }
    }

    func withHarness(acceptedHosts: [String] = [],
                     _ body: (Harness) async throws -> Void) async throws {
        let host = DemoRemoteHost()
        let fake = try await FakeRelay.start()
        let identity = RelayIdentity.make()
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Relay Mac",
                                                helloTimeout: .seconds(30), acceptedHosts: acceptedHosts)
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()
        let port = try #require(await server.boundPort)
        let relay = RelayHost(relayURL: fake.url, identity: identity, token: token, server: server)
        await relay.start()
        let h = Harness(host: host, fake: fake, server: server, token: token, identity: identity, relay: relay,
                        serverPort: Int(port))
        do {
            try await pollUntil("the relay host to sign in") {
                await h.relay.status == .connected && h.fake.hostIsReady(h.mailbox)
            }
            try await body(h)
            await h.stop()
        } catch {
            await h.stop()
            throw error
        }
    }

    func client(_ h: Harness, hosts: [String], port: Int? = nil, token: String? = nil,
                handshakeTimeout: Duration = .seconds(30)) -> RemoteClient {
        let pairing = RemotePairing(hosts: hosts, port: port ?? h.serverPort, token: token ?? h.token,
                                    macName: "Relay Mac", relay: h.pairingRelay)
        let c = RemoteClient(pairing: pairing, deviceName: "Test iPhone", deviceID: "phone-\(UUID().uuidString)")
        c.handshakeTimeout = handshakeTimeout
        c.requestTimeout = .seconds(60)
        return c
    }

    @Test func relayOnlyPairingConnects() async throws {
        try await withHarness { h in
            let c = client(h, hosts: [], port: remoteDefaultPort)
            c.start()
            defer { c.stop() }

            try await waitUntil("the phone to connect through the relay") {
                c.state == .connected(via: .relay) && c.sessions.count == 4 && c.rooms.count == 1 && c.usage != nil
            }
            #expect(c.macName == "Relay Mac")
            #expect(c.statusText == "Connected through the relay")

            try await c.send("Hello through the relay", to: .session(RemoteDemoData.IDs.fixSession))
            let actions = await h.host.recordedActions
            #expect(actions == [
                .sendMessage(text: "Hello through the relay", target: .session(RemoteDemoData.IDs.fixSession), agent: nil),
            ])

            let devices = await h.server.status.devices
            #expect(devices.count == 1)
            #expect(devices.first?.address.hasPrefix("relay:") == true)
            #expect(h.fake.badHandshakes(h.mailbox).isEmpty)
            c.stop()
        }
    }

    @Test func directWinsWhenBothWork() async throws {
        // 1. Both paths ready at once: direct wins and the relay socket is cancelled cleanly.
        try await withHarness { h in
            let c = client(h, hosts: ["127.0.0.1"])
            c.start()
            defer { c.stop() }

            try await waitUntil("direct connection to win") {
                c.state == .connected(via: .direct(host: "127.0.0.1")) && c.sessions.count == 4
            }
            try await pollUntil("losing relay attempt to settle") {
                let status = await h.server.status
                return status.pendingConnections == 0 && status.devices.count == 1
            }
            let devices = await h.server.status.devices
            #expect(devices.first?.address.hasPrefix("relay:") == false)
            c.stop()
        }

        // 2. Relay finishes first, direct finishes ~60 ms later (within the 300 ms preference window): direct still
        //    wins and the already-completed relay socket is closed cleanly.
        try await withHarness(acceptedHosts: ["::1"]) { h in
            let delayed = try await DelayedTCPProxy.start(listenHost: "::1", listenPort: UInt16(h.serverPort),
                                                          targetHost: "127.0.0.1", targetPort: UInt16(h.serverPort),
                                                          delay: .milliseconds(60))
            defer { delayed.stop() }

            let c = client(h, hosts: ["::1"])
            c.start()
            defer { c.stop() }

            try await waitUntil("delayed direct connection within 300 ms to beat the relay") {
                c.state == .connected(via: .direct(host: "::1")) && c.sessions.count == 4
            }
            try await pollUntil("the superseded relay connection to be closed") {
                let status = await h.server.status
                return status.pendingConnections == 0 && status.devices.count == 1
                    && status.devices.first?.address.hasPrefix("relay:") == false
            }
            c.stop()
        }
    }

    @Test func relayWinsWhenDirectIsUnreachable() async throws {
        try await withHarness { h in
            // 127.0.0.2 hangs until handshakeTimeout (15 s), so the relay wins after its 300 ms direct grace window
            // without waiting out the stalled direct socket.
            let started = ContinuousClock.now
            let c = client(h, hosts: ["127.0.0.2"], handshakeTimeout: .seconds(15))
            c.start()
            defer { c.stop() }

            try await waitUntil("the relay to win once the 300 ms direct window expires") {
                c.state == .connected(via: .relay) && c.sessions.count == 4
            }
            #expect(started.duration(to: .now) < .seconds(10))
            let devices = await h.server.status.devices
            #expect(devices.count == 1)
            #expect(devices.first?.address.hasPrefix("relay:") == true)
            c.stop()
        }
    }

    @Test func macOfflineShowsItsOwnState() async throws {
        try await withHarness { h in
            // The mailbox is claimed, then the Mac disconnects from the relay.
            await h.relay.stop()
            try await pollUntil("the Mac's control socket to close") { !h.fake.hostIsReady(h.mailbox) }

            let c = client(h, hosts: [], port: remoteDefaultPort)
            c.start()
            defer { c.stop() }

            try await waitUntil("macOffline state") {
                if case .macOffline = c.state { return true }
                return false
            }
            #expect(c.statusText == "Your Mac is not connected to the relay")
            #expect(c.state.statusText == "Your Mac is not connected to the relay")

            // When the Mac signs back in to its mailbox, the phone's retry connects on its own.
            let back = RelayHost(relayURL: h.fake.url, identity: h.identity, token: h.token, server: h.server)
            await back.start()
            do {
                try await waitUntil("the phone to connect once the Mac is back") {
                    c.state == .connected(via: .relay) && c.sessions.count == 4
                }
                c.stop()
                await back.stop()
            } catch {
                c.stop()
                await back.stop()
                throw error
            }
        }
    }

    @Test func reconnectsThroughTheRelayAfterADrop() async throws {
        try await withHarness { h in
            let c = client(h, hosts: [], port: remoteDefaultPort)
            c.start()
            defer { c.stop() }

            try await waitUntil("first relay connection") {
                c.state == .connected(via: .relay) && c.sessions.count == 4
            }
            try await c.open(sessionID: RemoteDemoData.IDs.fixSession)
            #expect(c.openTranscript != nil)
            #expect(h.fake.phoneConnections(h.mailbox).count == 1)

            // Simulate switching from Wi-Fi to cellular: the active socket drops and new phone dials fail briefly
            // while the Mac updates its sessions and transcript.
            h.fake.setRefusePhones(h.mailbox, true)
            h.fake.dropPhones(h.mailbox)
            try await waitUntil("client notices the drop") { !c.state.isConnected }
            try await pollUntil("server clears the dropped relayed device") { await h.server.status.devices.isEmpty }

            await h.host.emit(.sessionRemoved(sessionID: RemoteDemoData.IDs.oldSession))
            await h.host.emit(.transcriptUpsert(sessionID: RemoteDemoData.IDs.fixSession,
                                                item: .notice(id: "reloaded-after-drop", text: "Happened while offline")))
            #expect(c.sessions.count == 4)

            // Network returns: the phone reconnects through the relay and reloads hub and open transcript state.
            h.fake.setRefusePhones(h.mailbox, false)
            try await waitUntil("client reconnects through the relay and reloads state") {
                c.state == .connected(via: .relay)
                    && c.sessions.count == 3
                    && c.openTranscript?.items.contains { $0.id == "reloaded-after-drop" } == true
            }
            #expect(h.fake.phoneConnections(h.mailbox).count == 2)
            c.stop()
        }
    }

    @Test func wrongPairingCodeIsRefusedByTheRelay() async throws {
        try await withHarness { h in
            let c = client(h, hosts: [], port: remoteDefaultPort, token: RemoteToken.generate())
            c.start()
            defer { c.stop() }

            try await waitUntil("the relay refusal to put the client in rejected") {
                if case .rejected = c.state { return true }
                return false
            }
            // The relay refused the wrong access proof before waking the Mac.
            #expect(h.fake.phoneConnections(h.mailbox).isEmpty)
            #expect(await h.server.status.devices.isEmpty)
            c.stop()
        }
    }

    @Test func relayDialerErrorsAndAddressRules() async throws {
        try await withHarness { h in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }

            // Plain ws:// on a non-loopback address is refused without dialing.
            let insecure = RemotePairing.Relay(url: "ws://relay.example:8787", mailbox: h.mailbox)
            await #expect(throws: RemoteError.self) {
                _ = try await RelayDialer.connect(relay: insecure, token: h.token, session: session, timeout: .seconds(5))
            }

            // Daily limit frame and close 4029 surface RemoteError(.limit, ...).
            let resetsAt = Int(Date().timeIntervalSince1970) + 3600
            h.fake.setPhoneLimit(h.mailbox, resetsAt: resetsAt)
            do {
                _ = try await RelayDialer.connect(relay: h.pairingRelay, token: h.token, session: session,
                                                  timeout: .seconds(5))
                Issue.record("Expected RelayDialer.connect to throw .limit")
            } catch let error as RemoteError {
                #expect(error.code == .limit)
            }
            h.fake.setPhoneLimit(h.mailbox, resetsAt: nil)

            // Mac offline surfaces RemoteError(.macOffline, ...).
            await h.relay.stop()
            try await pollUntil { !h.fake.hostIsReady(h.mailbox) }
            do {
                _ = try await RelayDialer.connect(relay: h.pairingRelay, token: h.token, session: session,
                                                  timeout: .seconds(5))
                Issue.record("Expected RelayDialer.connect to throw .macOffline")
            } catch let error as RemoteError {
                #expect(error.code == .macOffline)
                #expect(error.message == "Your Mac is not connected to the relay")
            }
        }
    }
}

/// Forwards TCP bytes after a fixed initial delay, so a test can make a direct path finish slightly after the relay
/// while still within the 300 ms direct preference window.
private final class DelayedTCPProxy: Sendable {
    let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(listenHost: String, listenPort: UInt16, targetHost: String, targetPort: UInt16,
                      delay: Duration) async throws -> DelayedTCPProxy {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(listenHost),
                                                 port: NWEndpoint.Port(rawValue: listenPort) ?? .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "delayed-tcp-proxy")
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) * 1e-18
        listener.newConnectionHandler = { inbound in
            inbound.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) {
                let outbound = NWConnection(host: NWEndpoint.Host(targetHost),
                                            port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
                outbound.start(queue: queue)
                pump(from: inbound, to: outbound)
                pump(from: outbound, to: inbound)
            }
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
        return DelayedTCPProxy(listener: listener, port: boundPort)
    }

    func stop() {
        listener.cancel()
    }

    private static func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            pump(from: source, to: destination)
        }
    }
}
#endif
