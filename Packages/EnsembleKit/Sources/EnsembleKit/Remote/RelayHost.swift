#if os(macOS)
import CryptoKit
import Foundation
import Network

/// Where the Mac's relay connection stands.
public enum RelayHostStatus: Equatable, Sendable {
    case off
    case connecting
    /// Signed in to the mailbox; phones can reach the Mac through the relay.
    case connected
    case unreachable(String)
    /// The relay's daily budget for this mailbox is spent until `resetsAt`, or the relay refused a claim for now
    /// (`resetsAt` is nil then).
    case limitReached(resetsAt: Date?)
    /// The mailbox belongs to another key. Make a new identity and pairing code.
    case mailboxTaken
}

/// The Mac's side of the relay: keeps a control socket to its mailbox and serves phones through it.
///
/// - The control socket (`/v1/mailbox/<id>/host`) answers the relay's challenge by signing in (`auth`). A mailbox the
///   relay does not know (close 4004: never claimed, cleaned up after 90 days, or lost in a redeploy) is claimed with
///   the same ID and key, registering the access key derived from the pairing token. A mailbox held by another key
///   (4009 on a claim, 4001 on a sign-in) makes the status `mailboxTaken`, and the host stops trying.
/// - Once signed in it sends the text "ping" every 30 s, which the relay answers with "pong" without waking, and
///   reconnects when the relay stops answering.
/// - For every `phone` notice it opens a data socket (`/v1/mailbox/<id>/data/<conn>`), sends the phone's token as the
///   first frame, and hands the socket to `RemoteServer.adopt`, which runs the usual handshake with the Mac speaking
///   first. Phones that fail the pairing check are reported back as `badHandshake`, so the relay can block their
///   address.
/// - Lost connections are retried after 1, 2, 4, 8 s and so on, up to a minute.
///
/// The relay URL must be `wss://`; plain `ws://` is allowed only for `127.0.0.1` and `localhost` (tests and a local
/// `wrangler dev`). The host key is used only to sign the relay's challenges and never leaves this process.
public actor RelayHost {
    struct Timing: Sendable {
        /// How often the control socket sends "ping".
        var pingInterval: Duration = .seconds(30)
        /// Opening a socket, and on the control socket getting through to `ready`. The relay itself allows 10 s for
        /// the answer to its challenge and 15 s for a data socket's token.
        var connectTimeout: Duration = .seconds(15)
        /// Data sockets still opening at once. The relay lets at most 3 phones wait.
        var maxOpeningDataSockets = 8
    }

    private enum SignIn { case auth, claim }

    /// How one control connection ended.
    private enum Ending {
        /// 4004: the relay does not know the mailbox.
        case forgotten
        /// The mailbox belongs to another key.
        case taken
        /// A newer control socket for the mailbox took over (4009 after `ready`).
        case replaced
        /// The relay refused a claim for now.
        case claimLimited
        case failed(String)
        case stopped
    }

    private enum ControlEvent: Sendable {
        case open
        case text(String)
        case closed(UInt16)
        case failed(String)
        case deadline
        case tick
    }

    private let relayURL: URL
    private let identity: RelayIdentity
    /// The access key phones prove they know, base64url, registered by a claim.
    private let accessKey: String
    private let server: RemoteServer
    private let timing: Timing
    private let channelHost: String
    private let queue = DispatchQueue(label: "com.coquetteluke.ensemble.relay-host")

    private var running = false
    private var generation = 0
    private var registered = false
    private var runTask: Task<Void, Never>?
    private var failuresTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var control: NWConnection?
    private var signedIn = false
    private var dataMessageBytes = 1 << 20
    /// Data sockets that are still opening, by relay connection id.
    private var opening: [String: NWConnection] = [:]
    /// Relay connection ids handed to the server lately, newest last, so bad handshakes are reported only for phones
    /// that came through this relay.
    private var adopted: [String] = []
    private var limitResetsAt: Date?
    private var statusContinuations: [UUID: AsyncStream<RelayHostStatus>.Continuation] = [:]

    public private(set) var status: RelayHostStatus = .off

    public init(relayURL: URL, identity: RelayIdentity, token: String, server: RemoteServer) {
        self.init(relayURL: relayURL, identity: identity, token: token, server: server, timing: Timing())
    }

    init(relayURL: URL, identity: RelayIdentity, token: String, server: RemoteServer, timing: Timing) {
        self.relayURL = relayURL
        self.identity = identity
        self.accessKey = RemoteHandshake.encode(RelayIdentity.accessKey(token: token).withUnsafeBytes { Data($0) })
        self.server = server
        self.timing = timing
        self.channelHost = RelayIdentity.channelHost(relayURL: relayURL, mailboxID: identity.mailboxID)
    }

    // MARK: - Lifecycle

    /// Connects and keeps the mailbox until `stop()`.
    public func start() async {
        guard !running else { return }
        running = true
        generation += 1
        let gen = generation
        guard Self.isAllowed(relayURL) else {
            publish(.unreachable("The relay address must start with wss://."))
            return
        }
        publish(.connecting)
        dataMessageBytes = await server.maxMessageBytes
        await server.addRelayChannelHost(channelHost)
        guard isCurrent(gen) else {
            await server.removeRelayChannelHost(channelHost)
            return
        }
        registered = true
        let failures = await server.relayHandshakeFailures()
        guard isCurrent(gen) else { return }
        failuresTask = Task { [weak self] in
            for await conn in failures {
                await self?.reportBadHandshake(conn)
            }
        }
        runTask = Task { [weak self] in
            await self?.run(generation: gen)
        }
    }

    /// Closes the control socket and every data socket that is still opening, and drops phones connected through
    /// this relay.
    public func stop() async {
        guard running else { return }
        running = false
        generation += 1
        runTask?.cancel()
        runTask = nil
        failuresTask?.cancel()
        failuresTask = nil
        limitTask?.cancel()
        limitTask = nil
        closeControl()
        for connection in opening.values { connection.cancel() }
        opening = [:]
        adopted = []
        limitResetsAt = nil
        publish(.off)
        if registered {
            registered = false
            await server.removeRelayChannelHost(channelHost)
        }
    }

    /// Status now and after every change.
    public func statusUpdates() -> AsyncStream<RelayHostStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RelayHostStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        statusContinuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusContinuation(id) }
        }
        return stream
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations[id] = nil
    }

    private func publish(_ new: RelayHostStatus) {
        guard new != status else { return }
        status = new
        for c in statusContinuations.values { c.yield(new) }
    }

    /// Connected, unless the day's budget is spent.
    private func publishSignedIn() {
        if let until = limitResetsAt, until > Date() {
            publish(.limitReached(resetsAt: until))
        } else {
            limitResetsAt = nil
            publish(.connected)
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        running && generation == gen && !Task.isCancelled
    }

    /// `wss://` anywhere, plain `ws://` only to this Mac.
    static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "wss": return true
        case "ws": return host == "127.0.0.1" || host == "localhost"
        default: return false
        }
    }

    /// The wait before the next attempt after `failures` failed ones in a row: 1, 2, 4, 8, 16, 32 s, then a minute.
    static func backoff(failures: Int) -> Duration {
        .seconds(min(60, 1 << min(max(failures, 0), 6)))
    }

    // MARK: - Control socket

    private func run(generation gen: Int) async {
        var failures = 0
        var signIn = SignIn.auth
        while isCurrent(gen) {
            publish(.connecting)
            let (ending, wasSignedIn) = await connectControl(signIn: signIn, generation: gen)
            guard isCurrent(gen) else { return }
            if wasSignedIn {
                failures = 0
                signIn = .auth
            }
            var delay = Self.backoff(failures: failures)
            switch ending {
            case .forgotten:
                // Claim the same ID with the same key. Straight away when the sign-in was refused; a socket that was
                // signed in and then dropped as unknown waits like any other drop.
                let refusedSignIn = signIn == .auth && !wasSignedIn
                signIn = .claim
                if refusedSignIn { continue }
                failures += 1
            case .taken:
                publish(.mailboxTaken)
                return
            case .replaced:
                // Another copy of the app signed in with this identity. Wait long, so the two do not keep taking
                // the mailbox from each other.
                publish(.unreachable("Another Ensemble signed in to this relay mailbox."))
                delay = .seconds(60)
            case .claimLimited:
                publish(.limitReached(resetsAt: nil))
                failures += 1
            case .failed(let reason):
                publish(.unreachable(reason))
                failures += 1
            case .stopped:
                return
            }
            try? await Task.sleep(for: delay)
        }
    }

    /// Runs one control connection from dialing to its end. Returns how it ended and whether it got signed in.
    private func connectControl(signIn: SignIn, generation gen: Int) async -> (Ending, Bool) {
        let connection = NWConnection(to: .url(endpoint("host")), using: parameters(maxMessageBytes: 16 << 10))
        let (events, continuation) = AsyncStream<ControlEvent>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.yield(.open)
            case .waiting(let error), .failed(let error):
                continuation.yield(.failed(Self.describe(error)))
            case .cancelled:
                continuation.yield(.failed("The relay connection closed."))
            default:
                break
            }
        }
        control = connection
        signedIn = false
        connection.start(queue: queue)
        let connectTimeout = timing.connectTimeout
        let deadline = Task {
            try? await Task.sleep(for: connectTimeout)
            if !Task.isCancelled { continuation.yield(.deadline) }
        }
        var pinger: Task<Void, Never>?
        defer {
            deadline.cancel()
            pinger?.cancel()
            connection.stateUpdateHandler = nil
            continuation.finish()
            // `stop()` closes the socket itself, with a close frame.
            if control === connection {
                control = nil
                signedIn = false
                connection.cancel()
            }
        }

        var answered = false
        var wasSignedIn = false
        var claimRefusedForNow = false
        var lastHeard = ContinuousClock.now
        for await event in events {
            guard isCurrent(gen) else { return (.stopped, wasSignedIn) }
            switch event {
            case .open:
                Self.receive(on: connection, into: continuation)
            case .text(let text):
                lastHeard = .now
                guard text != "pong", let frame = RelayWire.decode(text) else { continue }
                switch frame {
                case .challenge(let nonce) where !answered:
                    guard RemoteHandshake.decode(nonce, expectedCount: 32) != nil, let reply = signInFrame(signIn, nonce: nonce) else {
                        return (.failed("The relay sent an invalid challenge."), false)
                    }
                    answered = true
                    Self.sendText(RelayWire.encode(reply), on: connection)
                case .ready where answered && !wasSignedIn:
                    wasSignedIn = true
                    signedIn = true
                    deadline.cancel()
                    publishSignedIn()
                    let interval = timing.pingInterval
                    pinger = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: interval)
                            if !Task.isCancelled { continuation.yield(.tick) }
                        }
                    }
                case .phone(let conn, let token) where wasSignedIn:
                    openDataSocket(conn: conn, token: token)
                case .limit(let resetsAt):
                    limitReached(until: Date(timeIntervalSince1970: TimeInterval(resetsAt)))
                case .error(.limit, _) where !wasSignedIn:
                    claimRefusedForNow = true
                default:
                    break
                }
            case .closed(let code):
                return (ending(code: code, signIn: signIn, wasSignedIn: wasSignedIn, claimRefusedForNow: claimRefusedForNow), wasSignedIn)
            case .failed(let reason):
                return (.failed(reason), wasSignedIn)
            case .deadline:
                if !wasSignedIn { return (.failed("The relay did not answer."), false) }
            case .tick:
                // Two pings without a word back: the connection is gone even if TCP has not noticed.
                if lastHeard.duration(to: .now) > timing.pingInterval * 2 + .seconds(5) {
                    return (.failed("The relay stopped answering."), wasSignedIn)
                }
                Self.sendText("ping", on: connection)
            }
        }
        return (.stopped, wasSignedIn)
    }

    private func ending(code: UInt16, signIn: SignIn, wasSignedIn: Bool, claimRefusedForNow: Bool) -> Ending {
        switch code {
        case RelayWire.CloseCode.noMailbox:
            return .forgotten
        case RelayWire.CloseCode.taken:
            if wasSignedIn { return .replaced }
            return signIn == .claim ? .taken : .failed("The relay refused the sign-in.")
        case RelayWire.CloseCode.unauthorized:
            // The signature is always right for this Mac's key, so a refused sign-in means another key holds it.
            return signIn == .auth && !wasSignedIn ? .taken : .failed("The relay refused the sign-in.")
        case RelayWire.CloseCode.limit where claimRefusedForNow:
            return .claimLimited
        case RelayWire.CloseCode.timeout:
            return .failed("The relay closed the connection after a timeout.")
        case RelayWire.CloseCode.protocolError:
            return .failed("The relay did not accept a message from this Mac.")
        default:
            return .failed("The relay closed the connection.")
        }
    }

    private func signInFrame(_ signIn: SignIn, nonce: String) -> RelayControlFrame? {
        guard let signature = try? identity.signature(nonce: nonce) else { return nil }
        let sig = RemoteHandshake.encode(signature)
        switch signIn {
        case .auth: return .auth(sig: sig)
        case .claim: return .claim(hostKey: identity.hostPublicKey, accessKey: accessKey, sig: sig)
        }
    }

    /// Closes the control socket with a normal close frame.
    private func closeControl() {
        guard let connection = control else { return }
        control = nil
        signedIn = false
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func limitReached(until date: Date) {
        limitResetsAt = date
        if signedIn { publishSignedIn() }
        limitTask?.cancel()
        let wait = max(0, date.timeIntervalSinceNow)
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.limitOver(date)
        }
    }

    private func limitOver(_ date: Date) {
        guard limitResetsAt == date else { return }
        limitResetsAt = nil
        if signedIn { publish(.connected) }
    }

    // MARK: - Data sockets

    /// A phone proved the access key: open its data socket.
    private func openDataSocket(conn: String, token: String) {
        // The id goes into a URL path, so it must be exactly the relay's form.
        guard running, RelayWire.isConnID(conn), RemoteHandshake.decode(token, expectedCount: 32) != nil,
              opening[conn] == nil, opening.count < timing.maxOpeningDataSockets else { return }
        let connection = NWConnection(to: .url(endpoint("data/\(conn)")), using: parameters(maxMessageBytes: dataMessageBytes))
        opening[conn] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.dataSocketReady(conn, connection: connection, token: token) }
            case .waiting:
                connection.cancel()
            case .failed, .cancelled:
                Task { await self?.dataSocketGone(conn, connection: connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        let timeout = timing.connectTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.dataSocketGone(conn, connection: connection)
        }
    }

    private func dataSocketReady(_ conn: String, connection: NWConnection, token: String) async {
        guard opening[conn] === connection else { return }
        opening[conn] = nil
        guard running else {
            connection.cancel()
            return
        }
        // The relay pairs this socket with the phone on its first frame, the token. The Mac's challenge follows it.
        Self.sendText(RelayWire.encode(.data(token: token)), on: connection)
        // Remembered before the hand-over, so a bad handshake reported during it is recognised.
        adopted.append(conn)
        if adopted.count > 256 { adopted.removeFirst(adopted.count - 256) }
        await server.adopt(connection, relayConnection: conn)
    }

    /// A data socket that never opened, or took too long.
    private func dataSocketGone(_ conn: String, connection: NWConnection) {
        guard opening[conn] === connection else { return }
        opening[conn] = nil
        connection.cancel()
    }

    private func reportBadHandshake(_ conn: String) {
        guard adopted.contains(conn), signedIn, let control else { return }
        Self.sendText(RelayWire.encode(.badHandshake(conn: conn)), on: control)
    }

    // MARK: - Helpers

    private func endpoint(_ route: String) -> URL {
        relayURL.appending(path: "v1/mailbox/\(identity.mailboxID)/\(route)")
    }

    private func parameters(maxMessageBytes: Int) -> NWParameters {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = maxMessageBytes
        let params: NWParameters = relayURL.scheme?.lowercased() == "wss" ? .tls : .tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    private nonisolated static func sendText(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Reads control frames one at a time into the event stream, until a close or an error.
    private nonisolated static func receive(on connection: NWConnection, into continuation: AsyncStream<ControlEvent>.Continuation) {
        connection.receiveMessage { content, context, _, error in
            if let error {
                continuation.yield(.failed(describe(error)))
                return
            }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                continuation.yield(.failed("The relay connection closed."))
                return
            }
            switch metadata.opcode {
            case .close:
                continuation.yield(.closed(closeCode(metadata.closeCode)))
                return
            case .text:
                continuation.yield(.text(String(decoding: content ?? Data(), as: UTF8.self)))
            case .binary:
                continuation.yield(.failed("The relay sent an unexpected message."))
                return
            default:
                break
            }
            receive(on: connection, into: continuation)
        }
    }

    private nonisolated static func closeCode(_ code: NWProtocolWebSocket.CloseCode) -> UInt16 {
        switch code {
        case .protocolCode(let defined): defined.rawValue
        case .applicationCode(let value): value
        case .privateCode(let value): value
        @unknown default: 0
        }
    }

    private nonisolated static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "Could not reach the relay: \(String(cString: strerror(code.rawValue)))."
        case .dns: "Could not find the relay address."
        case .tls: "Could not make a secure connection to the relay."
        default: "Could not reach the relay."
        }
    }
}
#endif
