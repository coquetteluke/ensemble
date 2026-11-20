#if os(macOS)
import CryptoKit
import Foundation
import Network
import Synchronization

/// The Mac side of the iPhone remote: a WebSocket server (Network.framework) that listens on localhost and
/// the Tailscale addresses only, checks the phone's proof of the pairing token (`RemoteHandshake`, the token
/// itself is never sent), proves itself back, and relays a `RemoteHost` to every paired phone.
///
/// After a valid hello every frame in both directions is sealed by `RemoteChannel` (binary WebSocket frames,
/// starting with the welcome). A frame that does not open as the next one, or any plaintext frame, closes the
/// connection, so a relay on the local network can neither read nor change the traffic.
///
/// Connections that have not proved the token yet are limited separately (in total and per address) and are
/// closed when the hello timeout runs out, whatever state they are in, so they can never use up the slots of
/// paired phones.
///
/// Phones that come through the relay arrive as connections the Mac dialed out (`RelayHost` opens a data socket per
/// phone and hands it to `adopt`). They take the same path as accepted ones, with the address `relay:<connection id>`,
/// so failed relayed phones never block each other in the hello limiter. Their hello must name the relay identity
/// (`relay:<relay host>/<mailbox>` on 443, registered with `addRelayChannelHost`), and a direct phone may not.
public actor RemoteServer {
    public struct Configuration: Sendable {
        /// 0 picks a free port (tests). Several addresses with port 0 each get their own port.
        public var port: UInt16
        /// Exact addresses to listen on, e.g. `127.0.0.1` and the Tailscale IPs. Never a wildcard.
        public var bindAddresses: [String]
        public var macName: String
        public var appVersion: String
        public var heartbeatInterval: Duration
        /// A connection that has not proved the token this long after it was accepted is closed.
        public var helloTimeout: Duration
        /// Paired phones connected at once.
        public var maxDevices: Int
        /// Direct connections still in the handshake, in total. Kept apart from `maxDevices` and `maxRelayedPending`.
        public var maxPending: Int
        /// Relayed connections still in the handshake per relay identity (or across nil-identity relayed connections).
        public var maxRelayedPending: Int
        /// Connections still in the handshake from one address.
        public var maxPendingPerAddress: Int
        /// Largest message a paired phone may send.
        public var maxMessageBytes: Int
        /// Largest message before the handshake is done (the hello is a few hundred bytes).
        public var maxPendingMessageBytes: Int
        /// Host names the phone may say it dialed, besides the bind addresses and `localhost`: the MagicDNS
        /// name and the LAN name from the pairing code. A phone that dialed anything else is refused.
        public var acceptedHosts: [String]
        /// The relay details paired phones should save over the sealed channel right after `welcome`.
        public var activeRelay: RemotePairing.Relay?

        public init(port: UInt16 = UInt16(remoteDefaultPort), bindAddresses: [String] = ["127.0.0.1"], macName: String = "Mac",
                    appVersion: String = "0.1.0", heartbeatInterval: Duration = .seconds(15), helloTimeout: Duration = .seconds(10),
                    maxDevices: Int = 8, maxPending: Int = 8, maxRelayedPending: Int = 4, maxPendingPerAddress: Int = 3,
                    maxMessageBytes: Int = 1 << 20, maxPendingMessageBytes: Int = 4096, acceptedHosts: [String] = [],
                    activeRelay: RemotePairing.Relay? = nil) {
            self.port = port
            self.bindAddresses = bindAddresses
            self.macName = macName
            self.appVersion = appVersion
            self.heartbeatInterval = heartbeatInterval
            self.helloTimeout = helloTimeout
            self.maxDevices = maxDevices
            self.maxPending = maxPending
            self.maxRelayedPending = maxRelayedPending
            self.maxPendingPerAddress = maxPendingPerAddress
            self.maxMessageBytes = maxMessageBytes
            self.maxPendingMessageBytes = maxPendingMessageBytes
            self.acceptedHosts = acceptedHosts
            self.activeRelay = activeRelay
        }
    }

    /// A paired phone that is connected now.
    public struct Device: Sendable, Hashable, Identifiable {
        public var id: Int
        public var deviceID: String
        public var name: String
        public var address: String
        public var connectedAt: Date
    }

    public struct Status: Sendable, Equatable {
        public var running: Bool
        /// `address:port` for every listener that is up.
        public var listening: [String]
        /// Addresses that could not be bound, with the reason.
        public var failedAddresses: [String: String]
        public var devices: [Device]
        /// Connections still in the handshake.
        public var pendingConnections: Int

        public static let stopped = Status(running: false, listening: [], failedAddresses: [:], devices: [], pendingConnections: 0)
    }

    public enum StartError: Error, LocalizedError {
        case noListener([String: String])

        public var errorDescription: String? {
            switch self {
            case .noListener(let failures):
                let detail = failures.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
                return "Remote Control could not listen on any address. \(detail)"
            }
        }
    }

    private struct Peer {
        let id: Int
        let connection: NWConnection
        /// The remote IP, or `relay:<connection id>` for a phone that came through the relay.
        let address: String
        /// The relay's id for this phone, when it came through a relay host.
        let relayConnection: String?
        let connectedAt: Date
        var ready = false
        var authenticated = false
        /// Sent in the challenge; `nil` until the connection is ready.
        var serverNonce: Data?
        /// This connection's ephemeral X25519 key; `nil` until the challenge is sent and again once the hello was
        /// handled, so the private half never outlives the handshake.
        var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
        /// Seals and opens every frame once the phone has proved the token.
        var channel: RemoteChannel?
        var deviceID = ""
        var deviceName = ""
        var openSessions: Set<String> = []
        var lastSeen: Date
        /// The relay identity a relayed phone came through or dialed (normalised).
        var relayChannelHost: String?
    }

    private let host: any RemoteHost
    private var token: String
    private var config: Configuration
    private let queue = DispatchQueue(label: "com.coquetteluke.ensemble.remote-server")
    private var running = false
    private var listeners: [String: NWListener] = [:]
    private var listeningPorts: [String: UInt16] = [:]
    private var failures: [String: String] = [:]
    private var peers: [Int: Peer] = [:]
    private var nextPeerID = 1
    private var limiter = RemoteHelloLimiter()
    private var updatesTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    /// Relay identities phones may name, normalised, with how many relay hosts registered each.
    private var relayChannelHosts: [String: Int] = [:]
    private var relayFailureContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var activeRelay: RemotePairing.Relay?
    private let encoder = RemoteCoding.encoder()
    private let decoder = RemoteCoding.decoder()

    public init(host: any RemoteHost, token: String, configuration: Configuration = Configuration()) {
        self.host = host
        self.token = token
        self.config = configuration
        self.activeRelay = configuration.activeRelay
    }

    // MARK: - Lifecycle

    /// Starts listening. Succeeds when at least one address is up; throws when none could be bound.
    public func start() async throws {
        guard !running else { return }
        running = true
        failures = [:]
        startUpdates()
        startHeartbeat()
        await openListeners(config.bindAddresses)
        if listeners.isEmpty {
            let reasons = failures
            stop()
            failures = reasons
            throw StartError.noListener(reasons)
        }
        publishStatus()
    }

    /// Closes every listener and connection.
    public func stop() {
        running = false
        updatesTask?.cancel()
        updatesTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for l in listeners.values {
            l.stateUpdateHandler = nil
            l.newConnectionHandler = nil
            l.cancel()
        }
        listeners = [:]
        listeningPorts = [:]
        for p in peers.values { p.connection.cancel() }
        peers = [:]
        publishStatus()
    }

    /// Updates the host names a phone may have dialed (the MagicDNS name can change).
    public func setAcceptedHosts(_ hosts: [String]) {
        config.acceptedHosts = hosts
    }

    /// Changes the listen addresses while running (Tailscale came up or went away).
    public func rebind(to addresses: [String]) async {
        config.bindAddresses = addresses
        guard running else { return }
        let wanted = Set(addresses)
        for (address, l) in listeners where !wanted.contains(address) {
            l.stateUpdateHandler = nil
            l.newConnectionHandler = nil
            l.cancel()
            listeners[address] = nil
            listeningPorts[address] = nil
        }
        failures = failures.filter { wanted.contains($0.key) }
        await openListeners(addresses.filter { listeners[$0] == nil })
        publishStatus()
    }

    /// Replaces the token (Regenerate code). Every connected phone is dropped and must pair again.
    public func setToken(_ newToken: String) {
        token = newToken
        for p in peers.values { p.connection.cancel() }
        peers = [:]
        publishStatus()
    }

    /// Sets the relay details sent to paired phones over the sealed channel right after `welcome`, and pushes a
    /// changed non-nil relay to every paired phone already connected.
    public func setActiveRelay(_ relay: RemotePairing.Relay?) {
        guard relay != activeRelay else { return }
        activeRelay = relay
        guard let relay else { return }
        let authenticatedIDs = peers.compactMap { $0.value.authenticated ? $0.key : nil }
        for id in authenticatedIDs {
            sendSealed(.relayDetails(relay), to: id)
        }
    }

    /// Largest message a paired phone may send; a relay host opens its data sockets with this limit.
    var maxMessageBytes: Int { config.maxMessageBytes }

    /// The port of the first listener that came up (useful with port 0).
    public var boundPort: UInt16? {
        config.bindAddresses.lazy.compactMap { self.listeningPorts[$0] }.first
    }

    public var status: Status {
        Status(running: running,
               listening: config.bindAddresses.compactMap { a in listeningPorts[a].map { Self.display(a, $0) } },
               failedAddresses: failures,
               devices: devices,
               pendingConnections: peers.values.count { !$0.authenticated })
    }

    /// Status now and after every change.
    public func statusUpdates() -> AsyncStream<Status> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        statusContinuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusContinuation(id) }
        }
        return stream
    }

    private var devices: [Device] {
        peers.values.filter(\.authenticated).sorted { $0.id < $1.id }.map {
            Device(id: $0.id, deviceID: $0.deviceID, name: $0.deviceName, address: $0.address, connectedAt: $0.connectedAt)
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations[id] = nil
    }

    private func publishStatus() {
        let s = status
        for c in statusContinuations.values { c.yield(s) }
    }

    private static func display(_ address: String, _ port: UInt16) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    // MARK: - Listeners

    private func openListeners(_ addresses: [String]) async {
        await withTaskGroup(of: (String, Result<(NWListener, UInt16), any Error>).self) { group in
            for address in addresses {
                let params = makeParameters(address: address)
                group.addTask { [weak self] in
                    (address, await Self.startListener(params: params, address: address, server: self))
                }
            }
            for await (address, result) in group {
                switch result {
                case .success(let (listener, port)):
                    if running && config.bindAddresses.contains(address) && listeners[address] == nil {
                        listeners[address] = listener
                        listeningPorts[address] = port
                        failures[address] = nil
                    } else {
                        listener.stateUpdateHandler = nil
                        listener.newConnectionHandler = nil
                        listener.cancel()
                    }
                case .failure(let error):
                    if running && config.bindAddresses.contains(address) && listeners[address] == nil {
                        failures[address] = Self.describe(error)
                    }
                }
            }
        }
    }

    private func makeParameters(address: String) -> NWParameters {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = config.maxMessageBytes
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: config.port) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        return params
    }

    private static func startListener(params: NWParameters, address: String, server: RemoteServer?) async -> Result<(NWListener, UInt16), any Error> {
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            return .failure(error)
        }
        let once = RemoteResumeOnce()
        let queue = DispatchQueue(label: "com.coquetteluke.ensemble.remote-listener")
        listener.newConnectionHandler = { [weak server] connection in
            Task { await server?.accept(connection) }
        }
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [weak server] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: .success((listener, listener.port?.rawValue ?? 0))) }
                case .failed(let error), .waiting(let error):
                    if once.claim() {
                        listener.cancel()
                        continuation.resume(returning: .failure(error))
                    } else {
                        Task { await server?.listenerDied(address, listener: listener, error: error) }
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(returning: .failure(CancellationError())) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func listenerDied(_ address: String, listener: NWListener, error: any Error) {
        guard let l = listeners[address], l === listener else { return }
        l.stateUpdateHandler = nil
        l.newConnectionHandler = nil
        l.cancel()
        listeners[address] = nil
        listeningPorts[address] = nil
        failures[address] = Self.describe(error)
        publishStatus()
    }

    private static func describe(_ error: any Error) -> String {
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code):
                if code == .EADDRINUSE { return "port already in use" }
                if code == .EADDRNOTAVAIL { return "address not available" }
                return String(describing: code)
            default: return nw.debugDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard let id = admit(connection, address: Self.remoteAddress(connection.endpoint), relayConnection: nil,
                             relayChannelHost: nil) else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.peerReady(id) }
            case .failed, .cancelled:
                Task { await self?.dropPeer(id) }
            case .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        publishStatus()
    }

    /// Takes a phone that came through the relay: a WebSocket the Mac dialed to the relay, already open and with the
    /// relay's data token sent, so the Mac speaks first with the usual challenge. From here it is handled like an
    /// accepted connection, with the address `relay:<id>` so the hello limiter counts each relayed phone on its own,
    /// and a separate pending handshake budget per `relayChannelHost`.
    public func adopt(_ connection: NWConnection, relayConnection id: String, relayChannelHost: String? = nil) {
        let normalizedChannelHost = relayChannelHost.map(RemoteChannel.normalizedHost)
        guard let peerID = admit(connection, address: "relay:\(id)", relayConnection: id,
                                 relayChannelHost: normalizedChannelHost) else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.peerReady(peerID) }
            case .failed, .cancelled:
                Task { await self?.dropPeer(peerID) }
            case .waiting:
                connection.cancel()
            default:
                break
            }
        }
        // The handler above only hears changes from now on.
        switch connection.state {
        case .setup: connection.start(queue: queue)
        case .ready: peerReady(peerID)
        case .failed, .cancelled: dropPeer(peerID)
        default: break
        }
        publishStatus()
    }

    /// Lets phones that came through a relay host name this relay identity (`RelayIdentity.channelHost`) in their
    /// hello. Counted, so two relay hosts with the same identity can each add and remove it.
    public func addRelayChannelHost(_ host: String) {
        relayChannelHosts[RemoteChannel.normalizedHost(host), default: 0] += 1
    }

    /// Undoes one `addRelayChannelHost`. When no relay host uses the identity any more, phones connected or still in
    /// the handshake through it are closed.
    public func removeRelayChannelHost(_ host: String) {
        let key = RemoteChannel.normalizedHost(host)
        guard let count = relayChannelHosts[key] else { return }
        if count > 1 {
            relayChannelHosts[key] = count - 1
            return
        }
        relayChannelHosts[key] = nil
        for (id, p) in peers where p.relayChannelHost == key {
            p.connection.cancel()
            peers[id] = nil
        }
        publishStatus()
    }

    /// Relay connection ids of relayed phones that failed the pairing check, so the relay host can report them
    /// (`badHandshake`) and the relay can block the phone's address.
    public func relayHandshakeFailures() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(64))
        relayFailureContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRelayFailureContinuation(id) }
        }
        return stream
    }

    private func removeRelayFailureContinuation(_ id: UUID) {
        relayFailureContinuations[id] = nil
    }

    /// Registers a new connection that has not proved the token, or closes it when the address is blocked or the
    /// handshake budget is used up. Returns its peer id.
    private func admit(_ connection: NWConnection, address: String, relayConnection: String?,
                       relayChannelHost: String?) -> Int? {
        guard running, !limiter.isBlocked(address) else {
            connection.cancel()
            return nil
        }
        // Direct and relayed handshakes in progress get separate small budgets, so neither can crowd out paired phones
        // or the other path.
        if relayConnection == nil {
            let directPending = peers.values.filter { $0.relayConnection == nil && !$0.authenticated }
            if directPending.count >= config.maxPending
                || directPending.count(where: { $0.address == address }) >= config.maxPendingPerAddress {
                connection.cancel()
                return nil
            }
        } else {
            let relayedPending = peers.values.filter { $0.relayConnection != nil && !$0.authenticated }
            let relayedPendingForBucket = relayedPending.count(where: { $0.relayChannelHost == relayChannelHost })
            if relayedPendingForBucket >= config.maxRelayedPending
                || relayedPending.count(where: { $0.address == address }) >= config.maxPendingPerAddress {
                connection.cancel()
                return nil
            }
        }
        let id = nextPeerID
        nextPeerID += 1
        peers[id] = Peer(id: id, connection: connection, address: address, relayConnection: relayConnection, connectedAt: Date(),
                         lastSeen: Date(), relayChannelHost: relayChannelHost)
        // The deadline starts now, not when the WebSocket upgrade finishes: a client that opens TCP and never
        // sends the upgrade request is closed too.
        let timeout = config.helloTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireIfUnauthenticated(id)
        }
        return id
    }

    /// The WebSocket is open: send the challenge and start reading. Once per connection.
    private func peerReady(_ id: Int) {
        guard let peer = peers[id], !peer.ready else { return }
        let nonce = RemoteHandshake.makeNonce()
        peers[id]?.ready = true
        peers[id]?.lastSeen = Date()
        peers[id]?.serverNonce = nonce
        let keyPair = RemoteHandshake.makeKeyPair()
        peers[id]?.ephemeralKey = keyPair
        send(.challenge(RemoteChallenge(serverNonce: RemoteHandshake.encode(nonce),
                                        ephemeralKey: RemoteHandshake.encode(keyPair.publicKey.rawRepresentation))),
             replyTo: nil, to: id)
        receiveNext(id)
    }

    private func expireIfUnauthenticated(_ id: Int) {
        guard let p = peers[id], !p.authenticated else { return }
        p.connection.cancel()
        peers[id] = nil
        publishStatus()
    }

    private func dropPeer(_ id: Int) {
        guard let p = peers.removeValue(forKey: id) else { return }
        p.connection.cancel()
        publishStatus()
    }

    private func receiveNext(_ id: Int) {
        guard let connection = peers[id]?.connection else { return }
        connection.receiveMessage { [weak self] content, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let opcode = metadata?.opcode
            let failed = error != nil
            Task { await self?.received(id, content: content, opcode: opcode, failed: failed) }
        }
    }

    private func received(_ id: Int, content: Data?, opcode: NWProtocolWebSocket.Opcode?, failed: Bool) async {
        guard peers[id] != nil else { return }
        if failed {
            dropPeer(id)
            return
        }
        peers[id]?.lastSeen = Date()
        switch opcode {
        case .close:
            dropPeer(id)
            return
        case .text where peers[id]?.channel == nil:
            // Handshake frames are plaintext text.
            if let data = content { await handleFrame(id, data: data) }
        case .binary where peers[id]?.channel != nil:
            // After the handshake only sealed binary frames are accepted. Anything that does not open as the
            // next frame (changed, replayed, reordered, other keys) closes the connection.
            guard let data = content, var channel = peers[id]?.channel, let plaintext = try? channel.open(data) else {
                dropPeer(id)
                return
            }
            peers[id]?.channel = channel
            await handleFrame(id, data: plaintext)
        case .text, .binary:
            // Plaintext after the handshake, or binary before it.
            dropPeer(id)
            return
        default:
            break
        }
        guard peers[id] != nil else { return }
        receiveNext(id)
    }

    private func handleFrame(_ id: Int, data: Data) async {
        guard let peer = peers[id] else { return }
        if !peer.authenticated {
            guard data.count <= config.maxPendingMessageBytes else {
                peer.connection.cancel()
                peers[id] = nil
                publishStatus()
                return
            }
            // Version 1 phones send the raw token in hello. Refuse them before reading anything else.
            if let header = try? decoder.decode(RemoteFrameHeader.self, from: data), header.version < remoteMinimumProtocolVersion {
                send(.error(RemoteError(.unsupportedVersion, Self.updateAppMessage)), replyTo: header.id, to: id, thenClose: true)
                return
            }
        }
        let frame: RemoteClientFrame
        do {
            frame = try decoder.decode(RemoteClientFrame.self, from: data)
        } catch {
            let header = try? decoder.decode(RemoteFrameHeader.self, from: data)
            if !peer.authenticated {
                send(.error(RemoteError(.badRequest, "Say hello first")), replyTo: header?.id, to: id, thenClose: true)
                return
            }
            if case RemoteWireError.unknownType(let type)? = error as? RemoteWireError {
                send(.error(RemoteError(.unknownMessage, "This Mac does not know the message \(type)")), replyTo: header?.id, to: id)
            } else {
                send(.error(RemoteError(.badRequest, "Could not read the message")), replyTo: header?.id, to: id)
            }
            return
        }

        guard peer.authenticated else {
            guard case .hello(let hello) = frame.message else {
                send(.error(RemoteError(.unauthorized, "Say hello first")), replyTo: frame.id, to: id, thenClose: true)
                return
            }
            handleHello(id, hello: hello, replyTo: frame.id)
            return
        }

        await handleRequest(id, message: frame.message, replyTo: frame.id)
    }

    static let updateAppMessage = "Update Ensemble on your iPhone to connect to this Mac."

    private func handleHello(_ id: Int, hello: RemoteHello, replyTo: String?) {
        guard let peer = peers[id], let serverNonce = peer.serverNonce, let macKeyPair = peer.ephemeralKey else { return }
        // One hello per connection: the private key is gone whatever the outcome (a failure closes the connection).
        peers[id]?.ephemeralKey = nil
        guard hello.protocolVersion >= remoteMinimumProtocolVersion else {
            send(.error(RemoteError(.unsupportedVersion, Self.updateAppMessage)), replyTo: replyTo, to: id, thenClose: true)
            return
        }
        let macKey = macKeyPair.publicKey.rawRepresentation
        guard let phoneKey = RemoteHandshake.decode(hello.ephemeralKey, expectedCount: RemoteHandshake.keyByteCount),
              let sharedSecret = RemoteHandshake.sharedSecret(privateKey: macKeyPair, peerKey: phoneKey) else {
            send(.error(RemoteError(.badRequest, "This phone sent an invalid key. Update Ensemble on your iPhone.")),
                 replyTo: replyTo, to: id, thenClose: true)
            return
        }
        guard let clientNonce = RemoteHandshake.decode(hello.clientNonce, expectedCount: RemoteHandshake.nonceByteCount),
              let proof = RemoteHandshake.decode(hello.proof, expectedCount: 32),
              clientNonce != serverNonce,
              RemoteHandshake.isValidClientProof(proof, token: token, serverNonce: serverNonce, clientNonce: clientNonce,
                                                       macKey: macKey, phoneKey: phoneKey) else {
            if let relayConnection = peer.relayConnection {
                for c in relayFailureContinuations.values { c.yield(relayConnection) }
            } else if !peer.address.hasPrefix("relay:") {
                limiter.recordFailure(peer.address)
            }
            send(.error(RemoteError(.unauthorized, "This phone is not paired with this Mac. Scan the pairing code again.")),
                 replyTo: replyTo, to: id, thenClose: true)
            return
        }
        guard isOwnAddress(hello.dialedHost, port: hello.dialedPort, relayed: peer.relayConnection != nil,
                           expectedRelayChannelHost: peer.relayChannelHost) else {
            send(.error(RemoteError(.badRequest, "This phone dialed an address this Mac does not use. Scan the pairing code again.")),
                 replyTo: replyTo, to: id, thenClose: true)
            return
        }
        guard peers.values.count(where: { $0.authenticated }) < config.maxDevices else {
            send(.error(RemoteError(.busy, "This Mac already has the most phones connected.")), replyTo: replyTo, to: id, thenClose: true)
            return
        }
        limiter.recordSuccess(peer.address)
        peers[id]?.authenticated = true
        if peer.relayConnection != nil { peers[id]?.relayChannelHost = RemoteChannel.normalizedHost(hello.dialedHost) }
        peers[id]?.deviceID = String(hello.deviceID.prefix(128))
        peers[id]?.deviceName = String(hello.deviceName.prefix(128))
        // From here on every frame is sealed, starting with the welcome, so a relay cannot splice in its own.
        peers[id]?.channel = RemoteChannel(token: token, sharedSecret: sharedSecret, serverNonce: serverNonce,
                                           clientNonce: clientNonce, dialedHost: hello.dialedHost, dialedPort: hello.dialedPort, role: .server,
                                           protocolVersion: min(remoteProtocolVersion, hello.protocolVersion))
        let serverProof = RemoteHandshake.serverProof(token: token, serverNonce: serverNonce, clientNonce: clientNonce,
                                                       macKey: macKey, phoneKey: phoneKey)
        sendSealed(.welcome(RemoteWelcome(macName: config.macName, deviceID: hello.deviceID, appVersion: config.appVersion,
                                          serverProof: RemoteHandshake.encode(serverProof))),
                   replyTo: replyTo, to: id)
        if let activeRelay {
            sendSealed(.relayDetails(activeRelay), to: id)
        }
        publishStatus()
    }

    /// True when `host:port` is one of this Mac's addresses: a bind address, `localhost`, or an accepted name,
    /// on a port it listens on. A phone that came through a relay must instead name a registered relay identity on
    /// port 443, so keys made for one mailbox never open another's frames, and neither kind can pose as the other.
    private func isOwnAddress(_ host: String, port: Int, relayed: Bool, expectedRelayChannelHost: String? = nil) -> Bool {
        let normalized = RemoteChannel.normalizedHost(host)
        if relayed {
            if let expectedRelayChannelHost, normalized != expectedRelayChannelHost { return false }
            return port == RelayIdentity.channelPort && relayChannelHosts[normalized] != nil
        }
        let names = Set((config.bindAddresses + config.acceptedHosts + ["localhost"]).map(RemoteChannel.normalizedHost))
        let ports = Set(listeningPorts.values.map(Int.init))
        return names.contains(normalized) && ports.contains(port)
    }

    private func handleRequest(_ id: Int, message: RemoteClientMessage, replyTo: String?) async {
        let reply = await RemoteDispatcher.respond(to: message, host: host)
        guard peers[id] != nil else { return }
        switch (message, reply) {
        case (.openSession(let sessionID), .transcript):
            peers[id]?.openSessions.insert(sessionID)
        case (.closeSession(let sessionID), _):
            peers[id]?.openSessions.remove(sessionID)
        default:
            break
        }
        send(reply, replyTo: replyTo, to: id)
    }

    // MARK: - Sending

    private func send(_ message: RemoteServerMessage, replyTo: String?, to id: Int, thenClose: Bool = false) {
        if case .relayDetails = message {
            sendSealed(message, replyTo: replyTo, to: id)
            return
        }
        guard peers[id] != nil else { return }
        guard let data = try? encoder.encode(RemoteServerFrame(message, replyTo: replyTo)) else { return }
        sendEncoded(data, to: id, thenClose: thenClose)
    }

    /// Writes one frame over the peer's sealed channel only; never writes plaintext, even if called out of turn.
    private func sendSealed(_ message: RemoteServerMessage, replyTo: String? = nil, to id: Int) {
        guard let peer = peers[id], peer.authenticated, var channel = peer.channel else { return }
        guard let data = try? encoder.encode(RemoteServerFrame(message, replyTo: replyTo)),
              let sealed = try? channel.seal(data) else {
            dropPeer(id)
            return
        }
        peers[id]?.channel = channel
        Self.write(sealed, on: peer.connection, binary: true, thenClose: false)
    }

    /// Writes one encoded frame: sealed binary once the phone is paired, plaintext text during the handshake.
    /// Sealing and writing happen together on the actor, so frames reach the wire in counter order.
    private func sendEncoded(_ data: Data, to id: Int, thenClose: Bool = false) {
        guard let peer = peers[id] else { return }
        if var channel = peer.channel {
            guard let sealed = try? channel.seal(data) else {
                dropPeer(id)
                return
            }
            peers[id]?.channel = channel
            Self.write(sealed, on: peer.connection, binary: true, thenClose: thenClose)
        } else if !peer.authenticated {
            Self.write(data, on: peer.connection, binary: false, thenClose: thenClose)
        } else {
            // A paired phone without a channel cannot happen; never fall back to plaintext.
            dropPeer(id)
            return
        }
        if thenClose {
            peers[id] = nil
            publishStatus()
        }
    }

    private static func write(_ data: Data, on connection: NWConnection, binary: Bool, thenClose: Bool) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: binary ? .binary : .text)
        let context = NWConnection.ContentContext(identifier: binary ? "binary" : "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            if thenClose { connection.cancel() }
        })
    }

    private func startUpdates() {
        let host = self.host
        updatesTask = Task { [weak self] in
            let stream = await host.updates()
            for await update in stream {
                guard let self else { return }
                await self.broadcast(update)
            }
        }
    }

    private func broadcast(_ update: RemoteUpdate) {
        guard let data = try? encoder.encode(RemoteServerFrame(.update(update))) else { return }
        let onlyFor = update.transcriptSessionID
        for (id, p) in peers where p.authenticated {
            if let sid = onlyFor, !p.openSessions.contains(sid) { continue }
            sendEncoded(data, to: id)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let interval = config.heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.heartbeat()
            }
        }
    }

    private func heartbeat() {
        let now = Date()
        let interval = config.heartbeatInterval
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        let limit = seconds * 3 + 1
        for (id, p) in peers where p.ready {
            if now.timeIntervalSince(p.lastSeen) > limit {
                dropPeer(id)
                continue
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(queue) { [weak self] error in
                guard error == nil else { return }
                Task { await self?.markSeen(id) }
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            p.connection.send(content: Data("ping".utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    private func markSeen(_ id: Int) {
        peers[id]?.lastSeen = Date()
    }

    private static func remoteAddress(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            let text: String
            switch host {
            case .ipv4(let a): text = "\(a)"
            case .ipv6(let a): text = "\(a)"
            case .name(let n, _): text = n
            @unknown default: text = "\(host)"
            }
            return text.split(separator: "%").first.map(String.init) ?? text
        default:
            return "\(endpoint)"
        }
    }
}

#endif
