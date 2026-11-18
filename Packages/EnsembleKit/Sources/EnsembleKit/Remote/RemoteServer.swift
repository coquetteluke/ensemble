#if os(macOS)
import Foundation
import Network
import Synchronization

/// The Mac side of the iPhone remote: a WebSocket server (Network.framework) that listens on localhost and
/// the Tailscale addresses only, checks the phone's proof of the pairing token (`RemoteHandshake`, the token
/// itself is never sent), proves itself back, and relays a `RemoteHost` to every paired phone.
///
/// Connections that have not proved the token yet are limited separately (in total and per address) and are
/// closed when the hello timeout runs out, whatever state they are in, so they can never use up the slots of
/// paired phones.
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
        /// Connections still in the handshake, in total. Kept apart from `maxDevices`.
        public var maxPending: Int
        /// Connections still in the handshake from one address.
        public var maxPendingPerAddress: Int
        /// Largest message a paired phone may send.
        public var maxMessageBytes: Int
        /// Largest message before the handshake is done (the hello is a few hundred bytes).
        public var maxPendingMessageBytes: Int

        public init(port: UInt16 = UInt16(remoteDefaultPort), bindAddresses: [String] = ["127.0.0.1"], macName: String = "Mac",
                    appVersion: String = "0.1.0", heartbeatInterval: Duration = .seconds(15), helloTimeout: Duration = .seconds(10),
                    maxDevices: Int = 8, maxPending: Int = 8, maxPendingPerAddress: Int = 3,
                    maxMessageBytes: Int = 1 << 20, maxPendingMessageBytes: Int = 4096) {
            self.port = port
            self.bindAddresses = bindAddresses
            self.macName = macName
            self.appVersion = appVersion
            self.heartbeatInterval = heartbeatInterval
            self.helloTimeout = helloTimeout
            self.maxDevices = maxDevices
            self.maxPending = maxPending
            self.maxPendingPerAddress = maxPendingPerAddress
            self.maxMessageBytes = maxMessageBytes
            self.maxPendingMessageBytes = maxPendingMessageBytes
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
        let address: String
        let connectedAt: Date
        var ready = false
        var authenticated = false
        /// Sent in the challenge; `nil` until the connection is ready.
        var serverNonce: Data?
        var deviceID = ""
        var deviceName = ""
        var openSessions: Set<String> = []
        var lastSeen: Date
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
    private let encoder = RemoteCoding.encoder()
    private let decoder = RemoteCoding.decoder()

    public init(host: any RemoteHost, token: String, configuration: Configuration = Configuration()) {
        self.host = host
        self.token = token
        self.config = configuration
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
                    if running {
                        listeners[address] = listener
                        listeningPorts[address] = port
                        failures[address] = nil
                    } else {
                        listener.cancel()
                    }
                case .failure(let error):
                    failures[address] = Self.describe(error)
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
                        Task { await server?.listenerDied(address, error: error) }
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

    private func listenerDied(_ address: String, error: NWError) {
        guard let l = listeners[address] else { return }
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
        let address = Self.remoteAddress(connection.endpoint)
        guard running, !limiter.isBlocked(address) else {
            connection.cancel()
            return
        }
        // Handshakes in progress get their own small budget, so they cannot crowd out paired phones.
        let pending = peers.values.filter { !$0.authenticated }
        if pending.count >= config.maxPending || pending.count(where: { $0.address == address }) >= config.maxPendingPerAddress {
            connection.cancel()
            return
        }
        let id = nextPeerID
        nextPeerID += 1
        peers[id] = Peer(id: id, connection: connection, address: address, connectedAt: Date(), lastSeen: Date())
        // The deadline starts now, not when the WebSocket upgrade finishes: a client that opens TCP and never
        // sends the upgrade request is closed too.
        let timeout = config.helloTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireIfUnauthenticated(id)
        }
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

    /// The WebSocket is open: send the challenge and start reading.
    private func peerReady(_ id: Int) {
        guard peers[id] != nil else { return }
        let nonce = RemoteHandshake.makeNonce()
        peers[id]?.ready = true
        peers[id]?.lastSeen = Date()
        peers[id]?.serverNonce = nonce
        send(.challenge(RemoteChallenge(serverNonce: RemoteHandshake.encode(nonce))), replyTo: nil, to: id)
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
        case .text, .binary:
            if let data = content { await handleFrame(id, data: data) }
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
        guard let peer = peers[id], let serverNonce = peer.serverNonce else { return }
        guard hello.protocolVersion >= remoteMinimumProtocolVersion else {
            send(.error(RemoteError(.unsupportedVersion, Self.updateAppMessage)), replyTo: replyTo, to: id, thenClose: true)
            return
        }
        guard let clientNonce = RemoteHandshake.decode(hello.clientNonce, expectedCount: RemoteHandshake.nonceByteCount),
              let proof = RemoteHandshake.decode(hello.proof, expectedCount: 32),
              clientNonce != serverNonce,
              RemoteHandshake.isValidClientProof(proof, token: token, serverNonce: serverNonce, clientNonce: clientNonce) else {
            limiter.recordFailure(peer.address)
            send(.error(RemoteError(.unauthorized, "This phone is not paired with this Mac. Scan the pairing code again.")),
                 replyTo: replyTo, to: id, thenClose: true)
            return
        }
        guard peers.values.count(where: { $0.authenticated }) < config.maxDevices else {
            send(.error(RemoteError(.busy, "This Mac already has the most phones connected.")), replyTo: replyTo, to: id, thenClose: true)
            return
        }
        limiter.recordSuccess(peer.address)
        peers[id]?.authenticated = true
        peers[id]?.deviceID = String(hello.deviceID.prefix(128))
        peers[id]?.deviceName = String(hello.deviceName.prefix(128))
        let serverProof = RemoteHandshake.serverProof(token: token, serverNonce: serverNonce, clientNonce: clientNonce)
        send(.welcome(RemoteWelcome(macName: config.macName, deviceID: hello.deviceID, appVersion: config.appVersion,
                                    serverProof: RemoteHandshake.encode(serverProof))),
             replyTo: replyTo, to: id)
        publishStatus()
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
        guard let connection = peers[id]?.connection else { return }
        guard let data = try? encoder.encode(RemoteServerFrame(message, replyTo: replyTo)) else { return }
        Self.write(data, on: connection, thenClose: thenClose)
        if thenClose {
            peers[id] = nil
            publishStatus()
        }
    }

    private static func write(_ data: Data, on connection: NWConnection, thenClose: Bool) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
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
        for p in peers.values where p.authenticated {
            if let sid = onlyFor, !p.openSessions.contains(sid) { continue }
            Self.write(data, on: p.connection, thenClose: false)
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
