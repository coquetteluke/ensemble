import Foundation
import Observation

/// The phone side of the remote: connects to the Mac's `RemoteServer` over WebSocket, trying each pairing
/// host in order and reconnecting with backoff, and keeps an observable copy of the hub, rooms, usage and
/// the open chat. Every frame after the handshake is sealed by `RemoteChannel`; one that does not open drops
/// the connection. Also has an in-process mode that talks straight to a `RemoteHost` (demo and previews).
@MainActor @Observable
public final class RemoteClient {
    public enum ConnectionState: Equatable, Sendable {
        /// Not started, or stopped.
        case idle
        case connecting(host: String)
        case connected(host: String)
        /// All hosts failed; trying again in this many seconds.
        case waiting(retryIn: Int)
        /// The Mac refused this phone (wrong token or version). Pair again.
        case rejected(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public private(set) var state: ConnectionState = .idle
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
    public private(set) var usage: RemoteUsageSummary?
    public private(set) var openSessionID: String?
    public private(set) var openTranscript: RemoteTranscript?
    /// Last connection or request problem, for the status screen.
    public private(set) var lastError: String?
    public let deviceName: String
    public let deviceID: String
    public let isInProcess: Bool

    @ObservationIgnored public var handshakeTimeout: Duration = .seconds(6)
    @ObservationIgnored public var requestTimeout: Duration = .seconds(15)
    @ObservationIgnored public var pingInterval: Duration = .seconds(20)
    @ObservationIgnored public var maxBackoffSeconds: Double = 30

    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let localHost: (any RemoteHost)?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// Seals and opens frames on the current connection.
    @ObservationIgnored private var channel: RemoteChannel?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var localUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: CheckedContinuation<RemoteServerMessage, any Error>] = [:]
    @ObservationIgnored private var requestCounter = 0
    @ObservationIgnored private var generation = 0

    /// A client for a paired Mac.
    public init(pairing: RemotePairing, deviceName: String, deviceID: String) {
        self.pairing = pairing
        self.macName = pairing.macName
        self.deviceName = deviceName
        self.deviceID = deviceID
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
        client.usage = data.usage
        client.state = .connected(host: "demo")
        return client
    }

    // MARK: - Connection

    /// Connects and keeps reconnecting until `stop()`.
    public func start() {
        generation += 1
        let gen = generation
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

    private func runLoop(generation gen: Int) async {
        var attempt = 0
        while isCurrent(gen) {
            var hadConnection = false
            // A refusal arrives before the host has proved anything, so a fake host could send one. Keep trying
            // the other hosts and only give up when none of them lets this phone in.
            var refusal: RemoteError?
            for host in pairing.hosts {
                guard isCurrent(gen) else { return }
                guard let url = RemotePairing.webSocketURL(host: host, port: pairing.port) else { continue }
                state = .connecting(host: host)
                let task: URLSessionWebSocketTask
                let sealedChannel: RemoteChannel
                do {
                    (task, sealedChannel) = try await handshake(url: url, host: host)
                } catch let error as RemoteError where error.code == .unauthorized || error.code == .unsupportedVersion {
                    guard isCurrent(gen) else { return }
                    lastError = error.message
                    refusal = error
                    continue
                } catch let error as RemoteError where error.code == .macNotVerified {
                    // Refuse this host: it does not know the pairing token.
                    guard isCurrent(gen) else { return }
                    lastError = "\(host): \(error.message)"
                    continue
                } catch {
                    guard isCurrent(gen) else { return }
                    lastError = "\(host): \(Self.describe(error))"
                    continue
                }
                guard isCurrent(gen) else {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                socket = task
                channel = sealedChannel
                state = .connected(host: host)
                lastError = nil
                attempt = 0
                hadConnection = true
                startPing(task)
                loadInitialState()
                await receiveLoop(task, generation: gen)
                pingTask?.cancel()
                if socket === task {
                    socket = nil
                    channel = nil
                }
                failAllPending(RemoteError(.failed, "Lost the connection to the Mac"))
                break
            }
            guard isCurrent(gen) else { return }
            if !hadConnection, let refusal {
                state = .rejected(refusal.message)
                return
            }
            let delay = hadConnection ? 1 : min(maxBackoffSeconds, pow(2, Double(attempt)))
            attempt += 1
            state = .waiting(retryIn: Int(delay.rounded(.up)))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handshake(url: URL, host: String) async throws -> (URLSessionWebSocketTask, RemoteChannel) {
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        task.resume()
        let timeout = handshakeTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
        }
        defer { timer.cancel() }
        do {
            // 1. The Mac speaks first with a fresh nonce.
            let first = try Self.decode(try await task.receive())
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

            // 2. Prove the token without sending it.
            let clientNonce = RemoteHandshake.makeNonce()
            let proof = RemoteHandshake.clientProof(token: pairing.token, serverNonce: serverNonce, clientNonce: clientNonce)
            let hello = RemoteHello(deviceName: deviceName, deviceID: deviceID,
                                    clientNonce: RemoteHandshake.encode(clientNonce), proof: RemoteHandshake.encode(proof),
                                    dialedHost: host, dialedPort: pairing.port)
            try await task.send(.string(try Self.encode(RemoteClientFrame(.hello(hello), id: nextRequestID()))))

            // 3. The Mac must prove it knows the token too. Its welcome is the first sealed frame; a host without
            //    the token (or a relay that changed the hello) cannot seal it, and a plaintext welcome is refused.
            var sealedChannel = RemoteChannel(token: pairing.token, serverNonce: serverNonce, clientNonce: clientNonce,
                                              dialedHost: host, dialedPort: pairing.port, role: .client,
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
                      RemoteHandshake.isValidServerProof(serverProof, token: pairing.token, serverNonce: serverNonce,
                                                         clientNonce: clientNonce) else {
                    throw RemoteError(.macNotVerified, "This host could not prove it is your Mac, so the iPhone did not connect.")
                }
                // The sealed welcome echoes the device ID the Mac read from the plaintext hello; a mismatch means
                // the hello was changed on the way.
                guard welcome.deviceID == deviceID else {
                    throw RemoteError(.macNotVerified, "The pairing check was changed on the way to the Mac, so the iPhone did not connect.")
                }
                macName = welcome.macName
                macAppVersion = welcome.appVersion
                return (task, sealedChannel)
            case .error(let error):
                throw error
            default:
                throw RemoteError(.badRequest, "The Mac answered hello with \(reply.message.typeName)")
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation gen: Int) async {
        while isCurrent(gen) {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if isCurrent(gen) { lastError = Self.describe(error) }
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
        state = .connecting(host: "demo")
        localUpdatesTask = Task { [weak self] in
            let stream = await host.updates()
            guard let self, self.isCurrent(gen) else { return }
            self.state = .connected(host: "demo")
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
        case .hub(let hub):
            sessions = hub.sessions
            permissions = hub.permissions
        case .transcript(let t):
            if t.sessionID == openSessionID { openTranscript = t }
        case .rooms(let r):
            rooms = r
        case .usage(let u):
            usage = u
        case .update(let u):
            apply(u)
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

    // MARK: - Actions

    public func refreshHub() async throws { try await request(.hubSnapshot) }
    public func refreshRooms() async throws { try await request(.roomsRequest) }
    public func refreshUsage() async throws { try await request(.usageRequest) }

    /// Opens a chat (a session or a room's transcript) and streams its changes until another is opened.
    public func open(sessionID: String) async throws {
        if openSessionID != sessionID {
            if let old = openSessionID { _ = try? await request(.closeSession(sessionID: old)) }
            openSessionID = sessionID
            openTranscript = nil
        }
        try await request(.openSession(sessionID: sessionID))
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

    public func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        try await request(.setPermissionMode(RemoteSetPermissionMode(target: target, mode: mode)))
    }

    public func interrupt(_ target: RemoteTarget) async throws {
        try await request(.interrupt(target: target))
    }

    public func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws {
        try await request(.roomControl(RemoteRoomControl(roomID: roomID, action: action)))
    }

    // MARK: - Lookups for the UI

    public func pendingPermissions(for sessionID: String) -> [PermissionRequest] {
        permissions.filter { $0.sessionID == sessionID }
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
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
        case .transcriptUpsert(let sid, let item):
            guard openTranscript?.sessionID == sid else { return }
            upsertTranscriptItem(item)
        case .textDelta(let sid, let itemID, let delta):
            guard openTranscript?.sessionID == sid, let i = openTranscript?.items.firstIndex(where: { $0.id == itemID }) else { return }
            switch openTranscript?.items[i] {
            case .agentText(let id, let text, let agentID, _)?:
                openTranscript?.items[i] = .agentText(id: id, text: text + delta, agentID: agentID, streaming: true)
            case .reasoning(let id, let text, _)?:
                openTranscript?.items[i] = .reasoning(id: id, text: text + delta, streaming: true)
            default:
                break
            }
        case .activity(let sid, let activity):
            if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].activity = activity }
            if openTranscript?.sessionID == sid { openTranscript?.activity = activity }
            for r in rooms.indices {
                for a in rooms[r].agents.indices where rooms[r].agents[a].sessionID == sid {
                    rooms[r].agents[a].activity = activity
                }
            }
        case .permissionAsked(let p):
            if !permissions.contains(where: { $0.id == p.id }) { permissions.append(p) }
            answeredPermissionIDs.remove(p.id)
            if openTranscript?.sessionID == p.sessionID { upsertTranscriptItem(.permission(p)) }
        case .permissionReplied(_, let requestID, let decision):
            markAnswered(requestID, decision: decision)
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
            if let i = rooms.firstIndex(where: { $0.id == room.id }) { rooms[i] = room } else { rooms.append(room) }
            if openTranscript?.roomID == room.id {
                openTranscript?.permissionMode = room.permissionMode
                openTranscript?.agents = room.agents
            }
        case .roomRemoved(let id):
            rooms.removeAll { $0.id == id }
        case .usageSummary(let summary):
            usage = summary
        }
    }

    private func upsertTranscriptItem(_ item: TranscriptItem) {
        guard openTranscript != nil else { return }
        if let i = openTranscript?.items.firstIndex(where: { $0.id == item.id }) {
            openTranscript?.items[i] = item
        } else {
            openTranscript?.items.append(item)
        }
    }

    // MARK: - Coding

    private nonisolated static func encode(_ frame: RemoteClientFrame) throws -> String {
        String(decoding: try RemoteCoding.encode(frame), as: UTF8.self)
    }

    private nonisolated static func decode(_ message: URLSessionWebSocketTask.Message) throws -> RemoteServerFrame {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: throw RemoteWireError.notText
        }
        return try RemoteCoding.decode(RemoteServerFrame.self, from: data)
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
