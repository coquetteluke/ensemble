import CryptoKit
import Foundation
import Observation
import Synchronization

/// How the phone reached the Mac on the active connection.
public enum RemoteConnectionPath: Equatable, Hashable, Sendable {
    case direct(host: String)
    case relay
}

/// The phone side of the remote: connects to the Mac's `RemoteServer` over WebSocket, racing direct pairing
/// hosts and the cloud relay at once and reconnecting with backoff, and keeps an observable copy of the hub,
/// rooms, usage and the open chat. Every frame after the handshake is sealed by `RemoteChannel`; one that does
/// not open drops the connection. Also has an in-process mode that talks straight to a `RemoteHost` (demo and
/// previews).
@MainActor @Observable
public final class RemoteClient {
    public enum ConnectionState: Equatable, Sendable {
        /// Not started, or stopped.
        case idle
        case connecting
        case connected(via: RemoteConnectionPath)
        /// The relay answered, and the Mac is not signed in to its mailbox; trying again in this many seconds.
        case macOffline(retryIn: Int)
        /// The relay's daily budget for this mailbox is spent; trying again in this many seconds.
        case limitReached(retryIn: Int)
        /// All paths failed; trying again in this many seconds.
        case waiting(retryIn: Int)
        /// The Mac or relay refused this phone (wrong token or version). Pair again.
        case rejected(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var statusText: String {
            switch self {
            case .idle: "Offline"
            case .connecting: "Connecting"
            case .connected(via: .direct(let host)): "Connected via \(host)"
            case .connected(via: .relay): "Connected through the relay"
            case .macOffline: "Your Mac is not connected to the relay"
            case .limitReached: "Daily relay limit reached"
            case .waiting(let s): "Retrying in \(s)s"
            case .rejected(let why): why
            }
        }
    }

    public private(set) var state: ConnectionState = .idle
    public var statusText: String {
        isInProcess ? "Demo, no Mac" : state.statusText
    }
    public private(set) var pairing: RemotePairing
    public private(set) var macName: String
    public private(set) var macAppVersion: String?
    public private(set) var sessions: [SessionSummary] = []
    /// Open permission prompts across all sessions.
    public private(set) var permissions: [PermissionRequest] = []
    /// Decisions for prompts answered while this phone was watching (shown on the permission card).
    public private(set) var permissionDecisions: [String: PermissionDecision] = [:]
    /// Prompts known to be answered, by anyone.
    public private(set) var answeredPermissionIDs: Set<String> = []
    public private(set) var rooms: [RemoteRoom] = []
    public private(set) var availableModels: [RemoteModelOption] = []
    public private(set) var recentFolders: [String] = []
    public private(set) var usage: RemoteUsageSummary?
    /// Goes up each time the Mac says its fonts changed. `FontSyncClient` starts a sync round on every step.
    public private(set) var fontSettingsPushes = 0
    public private(set) var openSessionID: String?
    public private(set) var openTranscript: RemoteTranscript?
    /// Room decisions this phone answered, until the Mac's update replaces them.
    public private(set) var answeredDecisionIDs: Set<String> = []
    /// Last connection or request problem, for the status screen.
    public private(set) var lastError: String?
    public let deviceName: String
    public let deviceID: String
    public let isInProcess: Bool

    @ObservationIgnored public var handshakeTimeout: Duration = .seconds(6)
    @ObservationIgnored public var requestTimeout: Duration = .seconds(15)
    @ObservationIgnored public var pingInterval: Duration = .seconds(20)
    @ObservationIgnored public var maxBackoffSeconds: Double = 30
    /// How long to wait for a direct connection after the relay completes its handshake first.
    @ObservationIgnored public var directGraceWindow: Duration = .milliseconds(300)
    /// Told about everything new that needs the user, as it arrives over the live connection (never for what was
    /// already waiting when the phone connected). The app shows these as local notifications.
    @ObservationIgnored public var onAlert: (@MainActor (RemoteAlert) -> Void)?
    /// Called when the Mac replaces a session with a new one (for example after a cross-engine restart).
    @ObservationIgnored public var onSessionReplaced: (@MainActor (String, SessionSummary) -> Void)?
    /// How long a new prompt waits before its alert, so the session or room it belongs to has arrived too.
    @ObservationIgnored public var alertDelay: Duration = .milliseconds(400)
    @ObservationIgnored private var alertedIDs: Set<String> = []

    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let pairingStore: RemotePairingStore?
    @ObservationIgnored private let localHost: (any RemoteHost)?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// Seals and opens frames on the current connection.
    @ObservationIgnored private var channel: RemoteChannel?
    /// The relay the active connection is using, or `nil` when disconnected or connected directly.
    @ObservationIgnored private var connectedRelay: RemotePairing.Relay?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var localUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: CheckedContinuation<RemoteServerMessage, any Error>] = [:]
    @ObservationIgnored private var requestCounter = 1
    @ObservationIgnored private var generation = 0

    /// A client for a paired Mac.
    public init(pairing: RemotePairing, deviceName: String, deviceID: String, pairingStore: RemotePairingStore? = nil) {
        self.pairing = pairing
        self.macName = pairing.macName
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.pairingStore = pairingStore
        self.localHost = nil
        self.isInProcess = false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: config)
    }

    /// A client wired straight to a host in the same process, with no network (demo mode, previews).
    public init(inProcessHost host: any RemoteHost, macName: String = "Demo Mac") {
        self.pairing = RemotePairing(hosts: ["demo"], port: remoteDefaultPort, token: "demo", macName: macName)
        self.macName = macName
        self.deviceName = "Demo"
        self.deviceID = "demo"
        self.pairingStore = nil
        self.localHost = host
        self.isInProcess = true
        self.urlSession = URLSession(configuration: .ephemeral)
    }

    /// A client already filled with sample data, for SwiftUI previews. Actions go to a `DemoRemoteHost`.
    public static func preview(_ data: RemoteDemoData = .sample()) -> RemoteClient {
        let client = RemoteClient(inProcessHost: DemoRemoteHost(data: data))
        client.sessions = data.sessions
        client.permissions = data.permissions
        client.rooms = data.rooms
        client.availableModels = data.availableModels
        client.recentFolders = data.recentFolders
        client.usage = data.usage
        client.state = .connected(via: .direct(host: "demo"))
        return client
    }

    // MARK: - Connection

    /// Connects and keeps reconnecting until `stop()`.
    public func start() {
        generation += 1
        let gen = generation
        loopTask?.cancel()
        loopTask = nil
        pingTask?.cancel()
        pingTask = nil
        localUpdatesTask?.cancel()
        localUpdatesTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        channel = nil
        connectedRelay = nil
        failAllPending(RemoteError(.failed, "Disconnected"))
        if let host = localHost {
            startInProcess(host, generation: gen)
            return
        }
        loopTask = Task { [weak self] in await self?.runLoop(generation: gen) }
    }

    /// Disconnects and stops reconnecting.
    public func stop() {
        generation += 1
        loopTask?.cancel()
        loopTask = nil
        pingTask?.cancel()
        pingTask = nil
        localUpdatesTask?.cancel()
        localUpdatesTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        channel = nil
        connectedRelay = nil
        failAllPending(RemoteError(.failed, "Disconnected"))
        state = .idle
    }

    /// Drops any wait and tries every host again now.
    public func reconnectNow() {
        stop()
        start()
    }

    /// Switches to a new pairing (after scanning a new code) and reconnects.
    public func updatePairing(_ newPairing: RemotePairing) {
        pairing = newPairing
        macName = newPairing.macName
        if state != .idle { reconnectNow() }
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    /// Owns an authenticated WebSocket until the winning path claims it; any losing candidate cancels its socket
    /// cleanly as soon as it is dropped.
    private final class SocketBox: Sendable {
        private let stored: Mutex<URLSessionWebSocketTask?>

        init(_ task: URLSessionWebSocketTask) {
            self.stored = Mutex(task)
        }

        func claim() -> URLSessionWebSocketTask? {
            stored.withLock { slot in
                defer { slot = nil }
                return slot
            }
        }

        func cancel() {
            claim()?.cancel(with: .goingAway, reason: nil)
        }

        deinit {
            stored.withLock { $0 }?.cancel(with: .goingAway, reason: nil)
        }
    }

    private struct ConnectedCandidate: Sendable {
        let path: RemoteConnectionPath
        let directIndex: Int?
        let relay: RemotePairing.Relay?
        let socket: SocketBox
        let channel: RemoteChannel
        let welcome: RemoteWelcome
    }

    private enum RaceEvent: Sendable {
        case connected(ConnectedCandidate)
        case failed(path: RemoteConnectionPath, directIndex: Int?, errorText: String, remoteError: RemoteError?)
        case directGraceExpired
        case priorityGraceExpired
    }

    private enum DialOutcome {
        case connected(ConnectedCandidate)
        case failed(refusal: RemoteError?, macOffline: Bool, limit: RemoteError?, lastError: String?)
    }

    private func runLoop(generation gen: Int) async {
        var attempt = 0
        while isCurrent(gen) {
            switch state {
            case .macOffline, .limitReached:
                break
            default:
                state = .connecting
            }
            let outcome = await dialOnce(pairing: pairing)
            guard isCurrent(gen) else {
                if case .connected(let winner) = outcome { winner.socket.cancel() }
                return
            }
            switch outcome {
            case .connected(let winner):
                guard let task = winner.socket.claim() else { continue }
                macName = winner.welcome.macName
                macAppVersion = winner.welcome.appVersion
                if let usedRelay = winner.relay, usedRelay == pairing.relay, pairing.previousRelay != nil {
                    pairing.previousRelay = nil
                    try? pairingStore?.save(pairing)
                }
                socket = task
                channel = winner.channel
                connectedRelay = winner.relay
                state = .connected(via: winner.path)
                lastError = nil
                attempt = 0
                startPing(task)
                loadInitialState()
                await receiveLoop(task, generation: gen)
                task.cancel(with: .goingAway, reason: nil)
                if socket === task {
                    socket = nil
                    channel = nil
                    connectedRelay = nil
                }
                guard isCurrent(gen) else { return }
                pingTask?.cancel()
                pingTask = nil
                failAllPending(RemoteError(.failed, "Lost the connection to the Mac"))
                state = .waiting(retryIn: 1)
                try? await Task.sleep(for: .seconds(1))

            case .failed(let refusal, let macOffline, let limit, let errorText):
                // A refusal on a direct host arrives before the host proves anything, whereas macOffline and limit
                // from the relay arrive only after the phone proved the access key. Only enter rejected when no path
                // proved the token is still valid.
                if !macOffline && limit == nil, let refusal {
                    lastError = refusal.message
                    state = .rejected(refusal.message)
                    return
                }
                let delay = min(maxBackoffSeconds, pow(2, Double(attempt)))
                attempt += 1
                let retrySeconds = Int(delay.rounded(.up))
                if macOffline {
                    lastError = "Your Mac is not connected to the relay"
                    state = .macOffline(retryIn: retrySeconds)
                } else if let limit {
                    lastError = limit.message
                    state = .limitReached(retryIn: retrySeconds)
                } else {
                    lastError = errorText
                    state = .waiting(retryIn: retrySeconds)
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Starts every direct host and the relay together. Takes a direct connection if one completes before or within
    /// `directGraceWindow` (300 ms) of the relay; otherwise takes the relay and cancels the losers.
    private func dialOnce(pairing: RemotePairing) async -> DialOutcome {
        let directTargets: [(index: Int, host: String, url: URL)] = pairing.hosts.enumerated().compactMap { index, host in
            guard let url = RemotePairing.webSocketURL(host: host, port: pairing.port) else { return nil }
            return (index, host, url)
        }
        let primaryRelay = pairing.relay
        let fallbackRelay = pairing.previousRelay
        let hasRelay = primaryRelay != nil || fallbackRelay != nil
        if directTargets.isEmpty && !hasRelay {
            return .failed(refusal: nil, macOffline: false, limit: nil,
                           lastError: "The pairing code has no address for the Mac.")
        }

        let session = urlSession
        let token = pairing.token
        let port = pairing.port
        let deviceName = self.deviceName
        let deviceID = self.deviceID
        let timeout = handshakeTimeout
        let graceWindow = directGraceWindow

        return await withTaskGroup(of: RaceEvent.self) { group in
            for target in directTargets {
                group.addTask {
                    do {
                        let candidate = try await Self.dialDirect(
                            url: target.url, host: target.host, port: port, directIndex: target.index,
                            token: token, deviceName: deviceName, deviceID: deviceID,
                            session: session, timeout: timeout)
                        return .connected(candidate)
                    } catch let error as RemoteError {
                        return .failed(path: .direct(host: target.host), directIndex: target.index,
                                       errorText: "\(target.host): \(error.message)", remoteError: error)
                    } catch {
                        return .failed(path: .direct(host: target.host), directIndex: target.index,
                                       errorText: "\(target.host): \(Self.describe(error))", remoteError: nil)
                    }
                }
            }

            if hasRelay {
                group.addTask {
                    do {
                        let candidate = try await Self.dialRelay(
                            primary: primaryRelay, fallback: fallbackRelay,
                            token: token, deviceName: deviceName, deviceID: deviceID,
                            session: session, timeout: timeout)
                        return .connected(candidate)
                    } catch let error as RemoteError {
                        return .failed(path: .relay, directIndex: nil, errorText: error.message, remoteError: error)
                    } catch {
                        return .failed(path: .relay, directIndex: nil, errorText: Self.describe(error), remoteError: nil)
                    }
                }
            }

            var inFlightDirect = Set(directTargets.map(\.index))
            var inFlightRelay = hasRelay
            var waitingDirect: ConnectedCandidate?
            var waitingRelay: ConnectedCandidate?
            var directGraceStarted = false
            var priorityGraceStarted = false
            var refusal: RemoteError?
            var sawMacOffline = false
            var limitError: RemoteError?
            var lastErrorText: String?

            defer {
                waitingDirect?.socket.cancel()
                waitingRelay?.socket.cancel()
            }

            for await event in group {
                if Task.isCancelled {
                    if case .connected(let candidate) = event { candidate.socket.cancel() }
                    group.cancelAll()
                    break
                }

                switch event {
                case .connected(let candidate):
                    switch candidate.path {
                    case .direct:
                        if let idx = candidate.directIndex { inFlightDirect.remove(idx) }
                        waitingRelay?.socket.cancel()
                        waitingRelay = nil

                        if let existing = waitingDirect {
                            if (candidate.directIndex ?? .max) < (existing.directIndex ?? .max) {
                                existing.socket.cancel()
                                waitingDirect = candidate
                            } else {
                                candidate.socket.cancel()
                            }
                        } else {
                            waitingDirect = candidate
                        }

                        if let best = waitingDirect,
                           !inFlightDirect.contains(where: { $0 < (best.directIndex ?? 0) }) {
                            waitingDirect = nil
                            group.cancelAll()
                            return .connected(best)
                        }
                        if !priorityGraceStarted {
                            priorityGraceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: .milliseconds(50))
                                return .priorityGraceExpired
                            }
                        }

                    case .relay:
                        inFlightRelay = false
                        if waitingDirect != nil {
                            candidate.socket.cancel()
                        } else if inFlightDirect.isEmpty {
                            group.cancelAll()
                            return .connected(candidate)
                        } else {
                            waitingRelay?.socket.cancel()
                            waitingRelay = candidate
                            if !directGraceStarted {
                                directGraceStarted = true
                                group.addTask {
                                    try? await Task.sleep(for: graceWindow)
                                    return .directGraceExpired
                                }
                            }
                        }
                    }

                case .failed(_, let directIndex, let errorText, let remoteError):
                    if let idx = directIndex { inFlightDirect.remove(idx) } else { inFlightRelay = false }
                    if let remoteError {
                        switch remoteError.code {
                        case .unauthorized, .unsupportedVersion:
                            refusal = remoteError
                            lastErrorText = remoteError.message
                        case .macOffline:
                            sawMacOffline = true
                            lastErrorText = remoteError.message
                        case .limit:
                            limitError = remoteError
                            lastErrorText = remoteError.message
                        default:
                            lastErrorText = errorText
                        }
                    } else {
                        lastErrorText = errorText
                    }

                    if let best = waitingDirect,
                       !inFlightDirect.contains(where: { $0 < (best.directIndex ?? 0) }) {
                        waitingDirect = nil
                        waitingRelay?.socket.cancel()
                        waitingRelay = nil
                        group.cancelAll()
                        return .connected(best)
                    }
                    if let relay = waitingRelay, inFlightDirect.isEmpty {
                        waitingRelay = nil
                        group.cancelAll()
                        return .connected(relay)
                    }
                    if waitingDirect == nil && waitingRelay == nil && inFlightDirect.isEmpty && !inFlightRelay {
                        group.cancelAll()
                        return .failed(refusal: refusal, macOffline: sawMacOffline, limit: limitError,
                                       lastError: lastErrorText)
                    }

                case .priorityGraceExpired:
                    if let best = waitingDirect {
                        waitingDirect = nil
                        waitingRelay?.socket.cancel()
                        waitingRelay = nil
                        group.cancelAll()
                        return .connected(best)
                    }

                case .directGraceExpired:
                    if let best = waitingDirect {
                        waitingDirect = nil
                        waitingRelay?.socket.cancel()
                        waitingRelay = nil
                        group.cancelAll()
                        return .connected(best)
                    }
                    if let relay = waitingRelay {
                        waitingRelay = nil
                        group.cancelAll()
                        return .connected(relay)
                    }
                }
            }

            group.cancelAll()
            return .failed(refusal: refusal, macOffline: sawMacOffline, limit: limitError, lastError: lastErrorText)
        }
    }

    private nonisolated static func dialDirect(url: URL, host: String, port: Int, directIndex: Int,
                                               token: String, deviceName: String, deviceID: String,
                                               session: URLSession, timeout: Duration) async throws -> ConnectedCandidate {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        task.resume()
        let (box, channel, welcome) = try await handshake(
            over: task, token: token, deviceName: deviceName, deviceID: deviceID,
            dialedHost: host, dialedPort: port, timeout: timeout)
        return ConnectedCandidate(path: .direct(host: host), directIndex: directIndex, relay: nil, socket: box,
                                  channel: channel, welcome: welcome)
    }

    private nonisolated static func dialRelay(primary: RemotePairing.Relay?, fallback: RemotePairing.Relay?,
                                              token: String, deviceName: String, deviceID: String,
                                              session: URLSession, timeout: Duration) async throws -> ConnectedCandidate {
        var relays: [RemotePairing.Relay] = []
        if let primary { relays.append(primary) }
        if let fallback, fallback != primary { relays.append(fallback) }
        var lastError: (any Error)?
        var primaryAuthoritativeError: RemoteError?
        for relay in relays {
            try Task.checkCancellation()
            do {
                guard let relayURL = URL(string: relay.url) else {
                    throw RemoteError(.badRequest, "The relay address must start with wss://.")
                }
                let task = try await RelayDialer.connect(relay: relay, token: token, session: session, timeout: timeout)
                let dialedHost = RelayIdentity.channelHost(relayURL: relayURL, mailboxID: relay.mailbox)
                let (box, channel, welcome) = try await handshake(
                    over: task, token: token, deviceName: deviceName, deviceID: deviceID,
                    dialedHost: dialedHost, dialedPort: RelayIdentity.channelPort, timeout: timeout)
                return ConnectedCandidate(path: .relay, directIndex: nil, relay: relay, socket: box,
                                          channel: channel, welcome: welcome)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if relay == primary, let remoteError = error as? RemoteError {
                    switch remoteError.code {
                    case .macOffline, .limit, .unauthorized:
                        primaryAuthoritativeError = remoteError
                    default:
                        break
                    }
                }
                lastError = error
            }
        }
        throw primaryAuthoritativeError ?? lastError ?? RemoteError(.failed, "Could not reach the relay.")
    }

    private nonisolated static func handshake(over task: URLSessionWebSocketTask, token: String,
                                              deviceName: String, deviceID: String,
                                              dialedHost: String, dialedPort: Int,
                                              timeout: Duration) async throws -> (SocketBox, RemoteChannel, RemoteWelcome) {
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            do {
                // 1. The Mac speaks first with a fresh nonce.
                //    Read the version first: an older Mac's challenge has no ephemeral key and would not decode, so the
                //    phone must refuse it by version before it decodes the rest.
                let firstMessage = try await task.receive()
                if let header = try? JSONDecoder().decode(RemoteFrameHeader.self, from: data(firstMessage)),
                   header.version < remoteMinimumProtocolVersion {
                    throw RemoteError(.unsupportedVersion, "Update Ensemble on your Mac to connect from this iPhone.")
                }
                let first = try decode(firstMessage)
                let challenge: RemoteChallenge
                switch first.message {
                case .challenge(let c): challenge = c
                case .error(let error): throw error
                default: throw RemoteError(.badRequest, "The Mac did not start the pairing check")
                }
                guard first.version >= remoteMinimumProtocolVersion, challenge.protocolVersion >= remoteMinimumProtocolVersion else {
                    throw RemoteError(.unsupportedVersion, "Update Ensemble on your Mac to connect from this iPhone.")
                }
                guard let serverNonce = RemoteHandshake.decode(challenge.serverNonce, expectedCount: RemoteHandshake.nonceByteCount) else {
                    throw RemoteError(.macNotVerified, "The host sent an invalid pairing challenge.")
                }

                guard let macKey = RemoteHandshake.decode(challenge.ephemeralKey, expectedCount: RemoteHandshake.keyByteCount) else {
                    throw RemoteError(.macNotVerified, "The host sent an invalid pairing challenge.")
                }

                // 2. Prove the token without sending it. The phone's key pair lives for this handshake only: it is a
                //    local that goes out of scope with the shared secret taken from it.
                let clientNonce = RemoteHandshake.makeNonce()
                let phoneKeyPair = RemoteHandshake.makeKeyPair()
                let phoneKey = phoneKeyPair.publicKey.rawRepresentation
                guard let sharedSecret = RemoteHandshake.sharedSecret(privateKey: phoneKeyPair, peerKey: macKey) else {
                    throw RemoteError(.macNotVerified, "The host sent an invalid pairing challenge.")
                }
                let proof = RemoteHandshake.clientProof(token: token, serverNonce: serverNonce, clientNonce: clientNonce,
                                                        macKey: macKey, phoneKey: phoneKey)
                let hello = RemoteHello(deviceName: deviceName, deviceID: deviceID,
                                        clientNonce: RemoteHandshake.encode(clientNonce), ephemeralKey: RemoteHandshake.encode(phoneKey),
                                        proof: RemoteHandshake.encode(proof), dialedHost: dialedHost, dialedPort: dialedPort)
                try await task.send(.string(try encode(RemoteClientFrame(.hello(hello), id: "1"))))

                // 3. The Mac must prove it knows the token too. Its welcome is the first sealed frame; a host without
                //    the token (or a relay that changed the hello) cannot seal it, and a plaintext welcome is refused.
                var sealedChannel = RemoteChannel(token: token, sharedSecret: sharedSecret, serverNonce: serverNonce,
                                                  clientNonce: clientNonce, dialedHost: dialedHost, dialedPort: dialedPort,
                                                  role: .client,
                                                  protocolVersion: min(remoteProtocolVersion, challenge.protocolVersion))
                let reply: RemoteServerFrame
                switch try await task.receive() {
                case .data(let sealed):
                    guard let plaintext = try? sealedChannel.open(sealed) else {
                        throw RemoteError(.macNotVerified, "This host could not prove it is your Mac, so the iPhone did not connect.")
                    }
                    reply = try RemoteCoding.decode(RemoteServerFrame.self, from: plaintext)
                case .string(let text):
                    // Only a refusal may come in plaintext.
                    let frame = try RemoteCoding.decode(RemoteServerFrame.self, from: Data(text.utf8))
                    if case .error(let error) = frame.message { throw error }
                    throw RemoteError(.macNotVerified, "This host could not prove it is your Mac, so the iPhone did not connect.")
                @unknown default:
                    throw RemoteError(.badRequest, "Unexpected message from the Mac")
                }
                switch reply.message {
                case .welcome(let welcome):
                    guard let serverProof = RemoteHandshake.decode(welcome.serverProof, expectedCount: 32),
                          RemoteHandshake.isValidServerProof(serverProof, token: token, serverNonce: serverNonce,
                                                             clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey) else {
                        throw RemoteError(.macNotVerified, "This host could not prove it is your Mac, so the iPhone did not connect.")
                    }
                    // The sealed welcome echoes the device ID the Mac read from the plaintext hello; a mismatch means
                    // the hello was changed on the way.
                    guard welcome.deviceID == deviceID else {
                        throw RemoteError(.macNotVerified, "The pairing check was changed on the way to the Mac, so the iPhone did not connect.")
                    }
                    try Task.checkCancellation()
                    return (SocketBox(task), sealedChannel, welcome)
                case .error(let error):
                    throw error
                default:
                    throw RemoteError(.badRequest, "The Mac answered hello with \(reply.message.typeName)")
                }
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                throw error
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation gen: Int) async {
        while isCurrent(gen) {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if isCurrent(gen) {
                    if task.closeCode.rawValue == Int(RelayWire.CloseCode.limit) {
                        lastError = "Daily relay limit reached."
                    } else {
                        lastError = Self.describe(error)
                    }
                }
                return
            }
            guard isCurrent(gen) else { return }
            // After the handshake every frame must be the next sealed frame. Anything else (plaintext, changed,
            // replayed, reordered) means someone is interfering: drop the connection and reconnect.
            guard case .data(let sealed) = message, var current = channel, let plaintext = try? current.open(sealed) else {
                lastError = RemoteChannel.Failure.rejected.localizedDescription
                task.cancel(with: .policyViolation, reason: nil)
                return
            }
            channel = current
            // Frames of unknown types (a newer Mac) are skipped.
            guard let frame = try? RemoteCoding.decode(RemoteServerFrame.self, from: plaintext) else { continue }
            handle(frame)
        }
    }

    private func startPing(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        let interval = pingInterval
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                if await !Self.ping(task, timeout: .seconds(10)) {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
    }

    private nonisolated static func ping(_ task: URLSessionWebSocketTask, timeout: Duration) async -> Bool {
        let once = RemoteResumeOnce()
        return await withCheckedContinuation { continuation in
            task.sendPing { error in
                if once.claim() { continuation.resume(returning: error == nil) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    private func loadInitialState() {
        Task {
            try? await refreshHub()
            try? await refreshRooms()
            try? await refreshUsage()
            if let id = openSessionID { _ = try? await request(.openSession(sessionID: id)) }
        }
    }

    // MARK: In-process mode

    private func startInProcess(_ host: any RemoteHost, generation gen: Int) {
        state = .connecting
        localUpdatesTask = Task { [weak self] in
            let stream = await host.updates()
            guard let self, self.isCurrent(gen) else { return }
            self.state = .connected(via: .direct(host: "demo"))
            self.loadInitialState()
            for await update in stream {
                guard self.isCurrent(gen) else { return }
                if let sid = update.transcriptSessionID, sid != self.openSessionID { continue }
                self.handle(RemoteServerFrame(.update(update)))
            }
        }
    }

    // MARK: - Requests

    private func nextRequestID() -> String {
        requestCounter += 1
        return String(requestCounter)
    }

    /// Sends a request and waits for its reply. Replies are applied to the model before this returns.
    @discardableResult
    private func request(_ message: RemoteClientMessage) async throws -> RemoteServerMessage {
        if let host = localHost {
            guard state.isConnected else { throw RemoteError(.failed, "Not connected") }
            let reply = await RemoteDispatcher.respond(to: message, host: host)
            handle(RemoteServerFrame(reply))
            if case .error(let error) = reply { throw error }
            return reply
        }
        guard socket != nil, channel != nil, state.isConnected else { throw RemoteError(.failed, "Not connected to the Mac") }
        let id = nextRequestID()
        let plaintext = try RemoteCoding.encode(RemoteClientFrame(message, id: id))
        let timeout = requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            // Sealed and handed to the socket in one step on this actor, so frames go out in counter order.
            guard let socket, var current = channel else {
                continuation.resume(throwing: RemoteError(.failed, "Not connected to the Mac"))
                return
            }
            let sealed: Data
            do {
                sealed = try current.seal(plaintext)
            } catch {
                continuation.resume(throwing: error)
                return
            }
            channel = current
            pending[id] = continuation
            socket.send(.data(sealed)) { error in
                guard let error else { return }
                Task { @MainActor in self.resolve(id, with: .failure(error)) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.resolve(id, with: .failure(RemoteError(.failed, "The Mac did not answer")))
            }
        }
    }

    private func resolve(_ id: String, with result: Result<RemoteServerMessage, any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAllPending(_ error: any Error) {
        let all = pending
        pending = [:]
        for c in all.values { c.resume(throwing: error) }
    }

    private func handle(_ frame: RemoteServerFrame) {
        switch frame.message {
        case .relayDetails(let relay):
            applyRelayDetails(relay)
        case .hub(let hub):
            sessions = hub.sessions
            permissions = hub.permissions
            availableModels = hub.availableModels
            recentFolders = hub.recentFolders
        case .transcript(let t):
            if t.sessionID == openSessionID { openTranscript = t }
        case .rooms(let r):
            rooms = r
        case .usage(let u):
            usage = u
        case .update(let u):
            apply(u)
        case .sessionCreated(let s):
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
        case .roomCreated(let r):
            if let i = rooms.firstIndex(where: { $0.id == r.id }) { rooms[i] = r } else { rooms.insert(r, at: 0) }
        case .sessionDiff, .sessionDetails, .fontChunk:
            break
        case .fontSettings:
            // Sent unasked when the fonts changed on the Mac; as a reply it goes to the caller below.
            if frame.replyTo == nil { fontSettingsPushes += 1 }
        case .challenge, .welcome, .ack, .error:
            break
        }
        if let re = frame.replyTo {
            if case .error(let error) = frame.message {
                resolve(re, with: .failure(error))
            } else {
                resolve(re, with: .success(frame.message))
            }
        }
    }

    private func applyRelayDetails(_ incoming: RemotePairing.Relay) {
        guard !isInProcess,
              let url = URL(string: incoming.url), RelayDialer.isAllowed(url),
              RelayWire.isMailboxID(incoming.mailbox) else { return }
        if pairing.relay == incoming {
            if connectedRelay == incoming, pairing.previousRelay != nil {
                pairing.previousRelay = nil
                try? pairingStore?.save(pairing)
            }
            return
        }
        if connectedRelay == incoming || pairing.previousRelay == incoming {
            pairing.previousRelay = nil
        } else if pairing.previousRelay == nil, let old = pairing.relay {
            pairing.previousRelay = old
        }
        pairing.relay = incoming
        try? pairingStore?.save(pairing)
    }

    // MARK: - Actions

    public func refreshHub() async throws { try await request(.hubSnapshot) }
    public func refreshRooms() async throws { try await request(.roomsRequest) }
    public func refreshUsage() async throws { try await request(.usageRequest) }

    /// Opens a chat (a session or a room's transcript) and streams its changes until another is opened.
    public func open(sessionID: String) async throws {
        let old = openSessionID
        if old != sessionID {
            openSessionID = sessionID
            openTranscript = nil
            if let old { _ = try? await request(.closeSession(sessionID: old)) }
        }
        guard openSessionID == sessionID else { return }
        try await request(.openSession(sessionID: sessionID))
        if openSessionID != sessionID {
            _ = try? await request(.closeSession(sessionID: sessionID))
        }
    }

    /// Stops streaming the open chat.
    public func closeOpenSession() {
        guard let id = openSessionID else { return }
        openSessionID = nil
        openTranscript = nil
        Task { _ = try? await request(.closeSession(sessionID: id)) }
    }

    public func send(_ text: String, to target: RemoteTarget, agent: String? = nil) async throws {
        try await request(.sendMessage(RemoteSendMessage(target: target, text: text, agent: agent)))
    }

    public func reply(to permission: PermissionRequest, decision: PermissionDecision) async throws {
        try await request(.replyPermission(RemotePermissionReply(sessionID: permission.sessionID, requestID: permission.id,
                                                                 decision: decision)))
        markAnswered(permission.id, decision: decision)
    }

    /// Answers an agent's questions; empty `answers` declines them.
    public func answer(_ question: PermissionRequest, answers: [AgentQuestionAnswer]) async throws {
        try await request(.answerQuestion(RemoteQuestionAnswer(sessionID: question.sessionID, requestID: question.id, answers: answers)))
        markAnswered(question.id, decision: answers.isEmpty ? .reject : .once)
    }

    /// Proceed in one of the plan's modes, or Keep planning (without line comments from the phone).
    public func respond(to plan: PermissionRequest, decision: PlanDecision) async throws {
        try await request(.respondToPlan(RemotePlanResponse(sessionID: plan.sessionID, requestID: plan.id, decision: decision)))
        if case .proceed = decision { markAnswered(plan.id, decision: .once) } else { markAnswered(plan.id, decision: .reject) }
    }

    public func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        try await request(.setPermissionMode(RemoteSetPermissionMode(target: target, mode: mode)))
    }

    public func interrupt(_ target: RemoteTarget) async throws {
        try await request(.interrupt(target: target))
    }

    public func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws {
        try await request(.roomControl(RemoteRoomControl(roomID: roomID, action: action)))
    }

    /// Answers what a room waits on. `text` goes with choices that take it.
    public func decide(_ decision: RemoteRoomDecision, in roomID: UUID, choice: RemoteRoomChoice, text: String? = nil) async throws {
        try await request(.decideRoom(RemoteRoomDecisionReply(roomID: roomID, decisionID: decision.id, choice: choice.id,
                                                              text: choice.input == .none ? nil : text)))
        answeredDecisionIDs.insert(decision.id)
    }

    /// Switches or stages a model in `sessionID` (cross-engine switches take effect on the next sent message).
    public func changeModel(sessionID: String, providerID: String, modelID: String) async throws {
        try await request(.changeModel(RemoteChangeModel(sessionID: sessionID, providerID: providerID, modelID: modelID)))
    }

    /// Starts a new solo session on the Mac and returns its Hub summary.
    @discardableResult
    public func createSession(directory: String, providerID: String, modelID: String, title: String? = nil) async throws -> SessionSummary {
        let reply = try await request(.createSession(RemoteCreateSession(
            directory: directory, providerID: providerID, modelID: modelID, title: title
        )))
        guard case .sessionCreated(let summary) = reply else {
            throw RemoteError(.failed, "Unexpected response from Mac when creating session")
        }
        return summary
    }

    /// Starts a new multi-agent room on the Mac and returns it.
    @discardableResult
    public func createRoom(directory: String, title: String, mode: RoomMode, agents: [RemoteNewRoomAgent]) async throws -> RemoteRoom {
        let reply = try await request(.createRoom(RemoteCreateRoom(
            directory: directory, title: title, mode: mode, agents: agents
        )))
        guard case .roomCreated(let room) = reply else {
            throw RemoteError(.failed, "Unexpected response from Mac when creating room")
        }
        return room
    }

    /// Loads the working-tree git diff for `sessionID`.
    public func sessionDiff(sessionID: String) async throws -> RemoteSessionDiff {
        let reply = try await request(.sessionDiff(sessionID: sessionID))
        guard case .sessionDiff(let diff) = reply else {
            throw RemoteError(.failed, "Unexpected response from Mac when loading changes")
        }
        return diff
    }

    /// Asks the Mac for one session's details. Throws `RemoteError` (for example `.unknownMessage` from an older Mac).
    public func details(sessionID: String) async throws -> RemoteSessionDetails {
        let reply = try await request(.sessionDetails(sessionID: sessionID))
        guard case .sessionDetails(let details) = reply else {
            throw RemoteError(.failed, "Unexpected response from Mac when loading session details")
        }
        return details
    }

    /// Asks another model for an inline second opinion on a completed assistant reply.
    public func requestSecondOpinion(sessionID: String, itemID: String, replyText: String, providerID: String, modelID: String) async throws {
        try await request(.secondOpinion(RemoteSecondOpinionRequest(
            sessionID: sessionID, itemID: itemID, replyText: replyText, providerID: providerID, modelID: modelID
        )))
    }

    /// Archives or unarchives a solo session on the Mac.
    public func archive(sessionID: String, archived: Bool = true) async throws {
        try await request(.archiveSession(RemoteArchiveSession(sessionID: sessionID, archived: archived)))
    }

    // MARK: Fonts (`FontSyncTransport`)

    /// Sends this iPhone's fonts; the Mac merges them and answers with its own. Throws `RemoteError`
    /// (`.unknownMessage` from an older Mac).
    public func syncFonts(_ mine: RemoteFontSettings) async throws -> RemoteFontSettings {
        let reply = try await request(.fontSync(mine))
        guard case .fontSettings(let theirs) = reply else {
            throw RemoteError(.failed, "Unexpected response from Mac when syncing fonts")
        }
        return theirs
    }

    public func fontChunk(_ request: RemoteFontFileRequest) async throws -> RemoteFontChunk {
        let reply = try await self.request(.fontFile(request))
        guard case .fontChunk(let chunk) = reply else {
            throw RemoteError(.failed, "Unexpected response from Mac when fetching a font")
        }
        return chunk
    }

    public func uploadFont(_ chunk: RemoteFontChunk) async throws {
        try await request(.fontUpload(chunk))
    }

    /// Display name for a `(providerID, modelID)` pair using `availableModels`.
    public func modelName(providerID: String?, modelID: String?) -> String? {
        guard let modelID, !modelID.isEmpty else { return nil }
        if let providerID, let exact = availableModels.first(where: { $0.providerID == providerID && $0.modelID == modelID }) {
            return exact.name
        }
        if let byModel = availableModels.first(where: { $0.modelID == modelID }) {
            return byModel.name
        }
        return modelID
    }

    // MARK: - Lookups for the UI

    public func pendingPermissions(for sessionID: String) -> [PermissionRequest] {
        permissions.filter { $0.sessionID == sessionID }
    }

    /// Open prompts from a room's agents and their subagents, oldest first.
    public func pendingPermissions(inRoom roomID: UUID) -> [PermissionRequest] {
        room(id: roomID)?.permissions.filter { !answeredPermissionIDs.contains($0.id) } ?? []
    }

    /// The room's decision while it is still open (not answered from this phone yet).
    public func openDecision(inRoom roomID: UUID) -> RemoteRoomDecision? {
        guard let decision = room(id: roomID)?.decision, !answeredDecisionIDs.contains(decision.id) else { return nil }
        return decision
    }

    public func room(id: UUID?) -> RemoteRoom? {
        guard let id else { return nil }
        return rooms.first { $0.id == id }
    }

    public func isAnswered(_ permissionID: String) -> Bool {
        answeredPermissionIDs.contains(permissionID)
    }

    // MARK: - Applying updates

    private func markAnswered(_ id: String, decision: PermissionDecision?) {
        permissions.removeAll { $0.id == id }
        answeredPermissionIDs.insert(id)
        if let decision { permissionDecisions[id] = decision }
    }

    private func apply(_ update: RemoteUpdate) {
        switch update {
        case .sessionUpserted(let s):
            let before = sessions.first { $0.id == s.id }
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
            if s.activity == .failed, before?.activity != .failed, s.roomID == nil {
                alert(RemoteAlert(id: "failed-\(s.id)-\(s.lastActivity.timeIntervalSinceReferenceDate)", kind: .failed,
                                  sessionID: s.id, title: s.title, body: "The last turn failed"))
            }
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
        case .transcriptUpsert(let sid, let item):
            guard openTranscript?.sessionID == sid else { return }
            upsertTranscriptItem(item)
        case .textDelta(let sid, let itemID, let delta):
            guard openTranscript?.sessionID == sid else { return }
            if let i = openTranscript?.items.firstIndex(where: { $0.id == itemID }) {
                switch openTranscript?.items[i] {
                case .agentText(let id, let text, let agentID, _)?:
                    openTranscript?.items[i] = .agentText(id: id, text: text + delta, agentID: agentID, streaming: true)
                    finishOpenReasoning()
                case .reasoning(let id, let text, _)?:
                    openTranscript?.items[i] = .reasoning(id: id, text: text + delta, streaming: true)
                default:
                    break
                }
            } else {
                finishOpenReasoning()
                openTranscript?.items.append(.agentText(id: itemID, text: delta, agentID: nil, streaming: true))
            }
        case .activity(let sid, let activity):
            if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].activity = activity }
            if openTranscript?.sessionID == sid {
                openTranscript?.activity = activity
                // The Mac never says a thought finished; end it here the way its reducer does.
                switch activity {
                case .idle, .failed:
                    if var items = openTranscript?.items {
                        TranscriptReducer.finishStreaming(&items)
                        openTranscript?.items = items
                    }
                case .waitingForPermission:
                    finishOpenReasoning()
                case .working:
                    break
                }
            }
            for r in rooms.indices {
                for a in rooms[r].agents.indices where rooms[r].agents[a].sessionID == sid {
                    rooms[r].agents[a].activity = activity
                }
            }
        case .permissionAsked(let p):
            if !permissions.contains(where: { $0.id == p.id }) {
                permissions.append(p)
                schedulePermissionAlert(p)
            }
            answeredPermissionIDs.remove(p.id)
            if openTranscript?.sessionID == p.sessionID { upsertTranscriptItem(.permission(p)) }
        case .permissionReplied(_, let requestID, let decision):
            markAnswered(requestID, decision: decision)
            for r in rooms.indices where rooms[r].permissions.contains(where: { $0.id == requestID }) {
                rooms[r].permissions.removeAll { $0.id == requestID }
            }
        case .permissionModeChanged(let target, let mode):
            switch target {
            case .session(let id):
                if openTranscript?.sessionID == id { openTranscript?.permissionMode = mode }
            case .room(let roomID):
                if let i = rooms.firstIndex(where: { $0.id == roomID }) { rooms[i].permissionMode = mode }
                if openTranscript?.roomID == roomID { openTranscript?.permissionMode = mode }
            }
        case .usage(let sid, let u):
            if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].usage = u }
        case .roomUpserted(let room):
            let before = rooms.first { $0.id == room.id }
            if let i = rooms.firstIndex(where: { $0.id == room.id }) { rooms[i] = room } else { rooms.append(room) }
            if let decision = room.decision, decision.needsYou, decision.id != before?.decision?.id {
                alert(RemoteAlert(id: "room-\(room.id.uuidString)-\(decision.id)", kind: .roomDecision, sessionID: room.sessionID,
                                  title: room.title, body: decision.title))
            }
            if openTranscript?.roomID == room.id {
                openTranscript?.permissionMode = room.permissionMode
                openTranscript?.agents = room.agents
            }
        case .roomRemoved(let id):
            rooms.removeAll { $0.id == id }
        case .usageSummary(let summary):
            usage = summary
        case .hubUpdated(let hub):
            sessions = hub.sessions
            permissions = hub.permissions
            availableModels = hub.availableModels
            recentFolders = hub.recentFolders
        case .transcriptUpdated(let t):
            if t.sessionID == openSessionID { openTranscript = t }
        case .sessionReplaced(let oldSessionID, let newSession):
            sessions.removeAll { $0.id == oldSessionID }
            if let i = sessions.firstIndex(where: { $0.id == newSession.id }) {
                sessions[i] = newSession
            } else {
                sessions.insert(newSession, at: 0)
            }
            if openSessionID == oldSessionID {
                Task { @MainActor [weak self] in
                    guard let self, self.openSessionID == oldSessionID else { return }
                    _ = try? await self.request(.closeSession(sessionID: oldSessionID))
                    guard self.openSessionID == oldSessionID else { return }
                    self.openSessionID = newSession.id
                    if var t = self.openTranscript, t.sessionID == oldSessionID {
                        t.sessionID = newSession.id
                        t.modelProviderID = newSession.modelProviderID
                        t.modelID = newSession.modelID
                        t.pendingModelName = newSession.pendingModelName
                        self.openTranscript = t
                    }
                    _ = try? await self.open(sessionID: newSession.id)
                }
            }
            onSessionReplaced?(oldSessionID, newSession)
        }
    }

    // MARK: - Alerts

    private func alert(_ alert: RemoteAlert) {
        guard onAlert != nil, alertedIDs.insert(alert.id).inserted else { return }
        if alertedIDs.count > 2000 { alertedIDs = [alert.id] }
        onAlert?(alert)
    }

    /// Alerts for a new prompt a moment later, once the session row or room it belongs to has arrived, and only if it is
    /// still open by then.
    private func schedulePermissionAlert(_ request: PermissionRequest) {
        guard onAlert != nil, !answeredPermissionIDs.contains(request.id) else { return }
        let delay = alertDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.permissions.contains(where: { $0.id == request.id }) else { return }
            self.alert(self.permissionAlert(request))
        }
    }

    /// Who asks, in a few words, without the command itself (notifications can show on the lock screen).
    func permissionAlert(_ request: PermissionRequest) -> RemoteAlert {
        let room = rooms.first { r in
            r.permissions.contains { $0.id == request.id } || r.agents.contains { $0.sessionID == request.sessionID }
        }
        let session = sessions.first { $0.id == request.sessionID }
        let agent = room?.agents.first { $0.sessionID == request.sessionID }?.name
        let kind: RemoteAlert.Kind = request.isPlan ? .plan : request.isQuestion ? .question : .permission
        var body: String
        switch kind {
        case .plan: body = "The plan is ready"
        case .question: body = "Has a question"
        default:
            switch request.kind {
            case "bash", "shell", "command": body = "Wants to run a command"
            case "edit", "write", "patch", "multiedit": body = "Wants to edit a file"
            case "webfetch", "fetch", "websearch": body = "Wants to open a web page"
            default: body = "Asks for permission"
            }
        }
        if let agent { body = "\(agent): \(body)" }
        return RemoteAlert(id: "permission-\(request.id)", kind: kind, sessionID: room?.sessionID ?? request.sessionID,
                           title: room?.title ?? session?.title ?? "A session", body: body)
    }

    /// Anything but a thought (text, a tool, a prompt) ends the thought before it, as `TranscriptReducer` does on the Mac.
    private func upsertTranscriptItem(_ item: TranscriptItem) {
        guard openTranscript != nil else { return }
        if case .reasoning = item {} else { finishOpenReasoning() }
        if let i = openTranscript?.items.firstIndex(where: { $0.id == item.id }) {
            openTranscript?.items[i] = item
        } else {
            openTranscript?.items.append(item)
        }
    }

    /// Stops streaming reasoning near the end of the open transcript.
    private func finishOpenReasoning() {
        guard var items = openTranscript?.items else { return }
        TranscriptReducer.finishReasoning(&items)
        openTranscript?.items = items
    }

    // MARK: - Coding

    private nonisolated static func encode(_ frame: RemoteClientFrame) throws -> String {
        String(decoding: try RemoteCoding.encode(frame), as: UTF8.self)
    }

    private nonisolated static func data(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
    }

    private nonisolated static func decode(_ message: URLSessionWebSocketTask.Message) throws -> RemoteServerFrame {
        guard !data(message).isEmpty else { throw RemoteWireError.notText }
        return try RemoteCoding.decode(RemoteServerFrame.self, from: data(message))
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost: return "The Mac refused the connection. Is Remote Control on?"
            case .cannotFindHost, .dnsLookupFailed: return "Cannot find the Mac. Is Tailscale on?"
            case .timedOut: return "The Mac did not answer in time."
            case .notConnectedToInternet: return "No network connection."
            case .cancelled: return "Timed out."
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Something new that needs the user, from the live connection.
public struct RemoteAlert: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case permission
        case plan
        case question
        case roomDecision
        case failed
    }

    /// Stable per event, so the same one is never shown twice.
    public var id: String
    public var kind: Kind
    /// The chat to open: a session, or a room's transcript.
    public var sessionID: String
    /// The session or room title.
    public var title: String
    /// What it waits on, in a few words.
    public var body: String

    public init(id: String, kind: Kind, sessionID: String, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.title = title
        self.body = body
    }
}
