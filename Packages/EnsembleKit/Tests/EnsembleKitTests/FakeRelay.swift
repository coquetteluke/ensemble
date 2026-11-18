#if os(macOS)
import CryptoKit
import Foundation
import Network
import Synchronization
@testable import EnsembleKit

/// A stand-in for the Cloudflare relay on 127.0.0.1 that speaks the relay wire format:
/// - host control sockets: challenge, `claim` or `auth`, `ready`, `phone` notices, `badHandshake`, `limit`, and the
///   text "ping" answered with "pong";
/// - phone sockets: challenge, `access` proof, `waiting`, `paired`;
/// - Mac data sockets: the `data` token must be the first frame.
///
/// After `paired`, frames pass between the phone and its data socket unchanged, and when one closes the other is
/// closed. Close codes and deadlines are the relay's: 10 s to answer a challenge, 15 s for a waiting phone to be paired
/// and for a data socket to send its token, each closing with 4008.
///
/// Network.framework's WebSocket server never tells the server which path the client asked for, and the relay routes
/// on the path, so this does the HTTP upgrade and the WebSocket framing itself on a plain TCP listener.
final class FakeRelay: Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let state = Mutex(State())

    /// The port it listens on, on 127.0.0.1.
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// `ws://127.0.0.1:<port>`, the relay address to give a `RelayHost`.
    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    private init(listener: NWListener, queue: DispatchQueue) {
        self.listener = listener
        self.queue = queue
    }

    static func start() async throws -> FakeRelay {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "fake-relay")
        let relay = FakeRelay(listener: listener, queue: queue)
        listener.newConnectionHandler = { [weak relay] connection in
            guard let relay else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            relay.readUpgrade(connection, buffer: [])
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
        return relay
    }

    func stop() {
        listener.cancel()
        let sockets = state.withLock { s in
            defer { s.sockets = [:] }
            return s.sockets.values.map(\.socket)
        }
        for socket in sockets { socket.connection.cancel() }
    }

    // MARK: - What tests look at and change

    /// The frame types the host sent on its control sockets for this mailbox, in order ("claim", "auth",
    /// "badHandshake"). Keep-alive pings are counted in `pings` instead.
    func hostFrames(_ mailbox: String) -> [String] { state.withLock { $0.hostFrames[mailbox] ?? [] } }

    /// Connection ids the host reported as bad handshakes.
    func badHandshakes(_ mailbox: String) -> [String] { state.withLock { $0.badHandshakes[mailbox] ?? [] } }

    /// Connection ids of phones that proved the access key, in order: the ids the host was told about.
    func phoneConnections(_ mailbox: String) -> [String] { state.withLock { $0.phoneConnections[mailbox] ?? [] } }

    /// The Ed25519 public key that holds the mailbox.
    func hostKey(_ mailbox: String) -> Data? { state.withLock { $0.mailboxes[mailbox]?.hostKey } }

    /// The access key the host registered.
    func accessKey(_ mailbox: String) -> Data? { state.withLock { $0.mailboxes[mailbox]?.accessKey } }

    /// True while a signed-in control socket is open for the mailbox.
    func hostIsReady(_ mailbox: String) -> Bool {
        state.withLock { s in s.sockets.values.contains { $0.socket.mailbox == mailbox && $0.socket.role == .host && $0.authed } }
    }

    /// Text "ping" frames received on control sockets.
    var pings: Int { state.withLock { $0.pings } }

    /// Data sockets the Mac has opened.
    var dataSocketCount: Int { state.withLock { $0.dataSockets } }

    /// Data sockets whose first frame was not a `data` frame.
    var dataSocketsWithoutToken: Int { state.withLock { $0.dataWithoutToken } }

    /// Holds the mailbox for another Mac, as if it had claimed it.
    func hold(_ mailbox: String, hostKey: Data, accessKey: Data) {
        state.withLock { $0.mailboxes[mailbox] = Mailbox(hostKey: hostKey, accessKey: accessKey) }
    }

    /// The next `claim` for this mailbox is refused with 4009, as if another Mac claimed it a moment before.
    func takeNextClaim(_ mailbox: String) {
        state.withLock { _ = $0.takeOnClaim.insert(mailbox) }
    }

    /// Forgets the mailbox (the 90-day clean-up, or a redeploy that lost storage). With a code, every socket of the
    /// mailbox is closed with it.
    func forget(_ mailbox: String, closingWith code: UInt16? = nil) {
        let sockets = state.withLock { s in
            s.mailboxes[mailbox] = nil
            return s.sockets.values.map(\.socket).filter { $0.mailbox == mailbox }
        }
        guard let code else { return }
        for socket in sockets { close(socket, code: code, reason: "gone") }
    }

    /// Sends the daily limit frame on the mailbox's signed-in control socket.
    func sendLimit(_ mailbox: String, resetsAt: Int) {
        let hosts = state.withLock { s in
            s.sockets.values.filter { $0.socket.mailbox == mailbox && $0.socket.role == .host && $0.authed }.map(\.socket)
        }
        for host in hosts { send(#"{"t":"limit","kind":"daily","resetsAt":\#(resetsAt)}"#, to: host) }
    }

    // MARK: - State

    private struct Mailbox {
        var hostKey: Data?
        var accessKey: Data?
    }

    private struct Info {
        let socket: Socket
        var nonce: String?
        var authed = false
        /// Phone: the single-use token the Mac must present on its data socket.
        var token: String?
        /// The other socket of a pair.
        var peer: Int?
    }

    private struct State {
        var mailboxes: [String: Mailbox] = [:]
        var sockets: [Int: Info] = [:]
        var nextID = 1
        var hostFrames: [String: [String]] = [:]
        var badHandshakes: [String: [String]] = [:]
        var phoneConnections: [String: [String]] = [:]
        var takeOnClaim: Set<String> = []
        var pings = 0
        var dataSockets = 0
        var dataWithoutToken = 0
    }

    enum Role: String, Sendable { case host, phone, data }

    /// One upgraded WebSocket.
    final class Socket: Sendable {
        let id: Int
        let connection: NWConnection
        let mailbox: String
        let role: Role
        /// Phone: assigned on connect. Data: from the path.
        let conn: String?
        let io = Mutex(IO())

        struct IO {
            var buffer: [UInt8] = []
            /// A fragmented message being put together.
            var fragmentOpcode: UInt8?
            var fragments: [UInt8] = []
            var closing = false
        }

        init(id: Int, connection: NWConnection, mailbox: String, role: Role, conn: String?) {
            self.id = id
            self.connection = connection
            self.mailbox = mailbox
            self.role = role
            self.conn = conn
        }
    }

    private enum Effect {
        case send(Socket, opcode: UInt8, payload: [UInt8])
        case close(Socket, code: UInt16, reason: String)
    }

    // MARK: - HTTP upgrade

    private func readUpgrade(_ connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(contentsOf: data) }
            if let end = Self.headerEnd(buffer) {
                let head = String(decoding: buffer[..<end], as: UTF8.self)
                self.upgrade(connection, head: head, rest: Array(buffer[(end + 4)...]))
            } else if isComplete || error != nil || buffer.count > 16 << 10 {
                connection.cancel()
            } else {
                self.readUpgrade(connection, buffer: buffer)
            }
        }
    }

    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }

    private func upgrade(_ connection: NWConnection, head: String, rest: [UInt8]) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard requestLine.count >= 2, requestLine[0] == "GET", let key = headers["sec-websocket-key"],
              let route = Self.route(String(requestLine[1])) else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .idempotent)

        let conn = route.role == .phone ? RemoteHandshake.encode(Self.randomBytes(16)) : route.conn
        let nonce = route.role == .data ? nil : RemoteHandshake.encode(Self.randomBytes(32))
        let socket: Socket = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            let socket = Socket(id: id, connection: connection, mailbox: route.mailbox, role: route.role, conn: conn)
            s.sockets[id] = Info(socket: socket, nonce: nonce)
            if route.role == .data { s.dataSockets += 1 }
            return socket
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.gone(socket)
            default: break
            }
        }
        if let nonce { send(#"{"t":"challenge","nonce":"\#(nonce)"}"#, to: socket) }
        if route.role == .data {
            expire(socket, after: Self.pairSeconds) { $0.peer != nil }
        } else {
            expire(socket, after: Self.challengeSeconds) { $0.authed }
        }
        socket.io.withLock { $0.buffer = rest }
        process(socket)
        receive(socket)
    }

    private struct Route {
        let mailbox: String
        let role: Role
        let conn: String?
    }

    /// `/v1/mailbox/<id>/host`, `/v1/mailbox/<id>/phone` or `/v1/mailbox/<id>/data/<conn>`.
    private static func route(_ path: String) -> Route? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, parts[0].isEmpty, parts[1] == "v1", parts[2] == "mailbox", RelayWire.isMailboxID(parts[3]) else { return nil }
        switch (parts[4], parts.count) {
        case ("host", 5): return Route(mailbox: parts[3], role: .host, conn: nil)
        case ("phone", 5): return Route(mailbox: parts[3], role: .phone, conn: nil)
        case ("data", 6) where RelayWire.isConnID(parts[5]): return Route(mailbox: parts[3], role: .data, conn: parts[5])
        default: return nil
        }
    }

    // MARK: - Framing

    private func receive(_ socket: Socket) {
        socket.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                socket.io.withLock { $0.buffer.append(contentsOf: data) }
                self.process(socket)
            }
            if isComplete || error != nil {
                socket.connection.cancel()
                self.gone(socket)
                return
            }
            self.receive(socket)
        }
    }

    /// Takes every whole frame out of the buffer and handles it.
    private func process(_ socket: Socket) {
        while let message = socket.io.withLock({ Self.nextMessage(&$0) }) {
            handle(socket, opcode: message.opcode, payload: message.payload)
        }
    }

    /// The next whole message (fragments joined), or a control frame, from the buffer.
    private static func nextMessage(_ io: inout Socket.IO) -> (opcode: UInt8, payload: [UInt8])? {
        while let frame = parseFrame(io.buffer) {
            io.buffer.removeFirst(frame.length)
            if frame.opcode >= 0x8 { return (frame.opcode, frame.payload) }
            if frame.opcode != 0 {
                io.fragmentOpcode = frame.opcode
                io.fragments = []
            }
            io.fragments.append(contentsOf: frame.payload)
            if frame.fin, let opcode = io.fragmentOpcode {
                io.fragmentOpcode = nil
                defer { io.fragments = [] }
                return (opcode, io.fragments)
            }
        }
        return nil
    }

    private static func parseFrame(_ b: [UInt8]) -> (fin: Bool, opcode: UInt8, payload: [UInt8], length: Int)? {
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var length = Int(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | Int(b[$1]) }
            offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard b.count >= offset + 4 else { return nil }
            mask = Array(b[offset..<(offset + 4)])
            offset += 4
        }
        guard b.count >= offset + length else { return nil }
        var payload = Array(b[offset..<(offset + length)])
        if masked {
            for i in payload.indices { payload[i] ^= mask[i % 4] }
        }
        return (fin, opcode, payload, offset + length)
    }

    private static func frame(opcode: UInt8, payload: [UInt8]) -> Data {
        var out: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        out.append(contentsOf: payload)
        return Data(out)
    }

    private func send(_ text: String, to socket: Socket) {
        send(opcode: 0x1, payload: Array(text.utf8), to: socket)
    }

    private func send(opcode: UInt8, payload: [UInt8], to socket: Socket) {
        guard !socket.io.withLock({ $0.closing }) else { return }
        socket.connection.send(content: Self.frame(opcode: opcode, payload: payload), completion: .idempotent)
    }

    /// Sends a close frame, then ends the TCP connection once the client answers or a second has passed.
    private func close(_ socket: Socket, code: UInt16, reason: String) {
        let first = socket.io.withLock { io in
            defer { io.closing = true }
            return !io.closing
        }
        guard first else { return }
        let payload = [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8)
        socket.connection.send(content: Self.frame(opcode: 0x8, payload: payload), completion: .idempotent)
        queue.asyncAfter(deadline: .now() + 1) { socket.connection.cancel() }
        unpair(socket)
    }

    /// The relay's deadlines.
    static let challengeSeconds = 10.0
    static let pairSeconds = 15.0

    /// Closes the socket with 4008 unless it has got as far as `done` within `seconds`.
    private func expire(_ socket: Socket, after seconds: Double, done: @escaping @Sendable (Info) -> Bool) {
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let late = self.state.withLock { s in s.sockets[socket.id].map { !done($0) } ?? false }
            if late { self.close(socket, code: 4008, reason: "timeout") }
        }
    }

    private func perform(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .send(let socket, let opcode, let payload): send(opcode: opcode, payload: payload, to: socket)
            case .close(let socket, let code, let reason): close(socket, code: code, reason: reason)
            }
        }
    }

    /// The TCP connection ended.
    private func gone(_ socket: Socket) {
        unpair(socket)
        state.withLock { _ = $0.sockets.removeValue(forKey: socket.id) }
    }

    /// Closes the other socket of a pair.
    private func unpair(_ socket: Socket) {
        let peer: Socket? = state.withLock { s in
            guard let peerID = s.sockets[socket.id]?.peer else { return nil }
            s.sockets[socket.id]?.peer = nil
            s.sockets[peerID]?.peer = nil
            return s.sockets[peerID]?.socket
        }
        if let peer { close(peer, code: 1000, reason: "peer closed") }
    }

    // MARK: - Messages

    private func handle(_ socket: Socket, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x9:
            send(opcode: 0xA, payload: payload, to: socket)
            return
        case 0xA:
            return
        case 0x8:
            if socket.io.withLock({ $0.closing }) {
                socket.connection.cancel()
            } else {
                let code: UInt16 = payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : 1000
                close(socket, code: code, reason: "")
            }
            return
        default:
            break
        }
        let effects: [Effect] = state.withLock { s in
            guard let info = s.sockets[socket.id] else { return [] }
            // A pair forwards everything, text or binary, unchanged.
            if let peerID = info.peer, let peer = s.sockets[peerID]?.socket {
                return [.send(peer, opcode: opcode, payload: payload)]
            }
            switch socket.role {
            case .host: return hostMessage(&s, socket, opcode: opcode, payload: payload)
            case .phone: return phoneMessage(&s, socket, opcode: opcode, payload: payload)
            case .data: return dataMessage(&s, socket, opcode: opcode, payload: payload)
            }
        }
        perform(effects)
    }

    private func hostMessage(_ s: inout State, _ socket: Socket, opcode: UInt8, payload: [UInt8]) -> [Effect] {
        if opcode == 0x1, payload == Array("ping".utf8) {
            s.pings += 1
            return [.send(socket, opcode: 0x1, payload: Array("pong".utf8))]
        }
        let mailbox = socket.mailbox
        guard opcode == 0x1, let frame = Self.controlFrame(payload) else { return [.close(socket, code: 4002, reason: "protocol")] }
        s.hostFrames[mailbox, default: []].append(frame["t"] ?? "")
        let authed = s.sockets[socket.id]?.authed ?? false
        switch (frame["t"], authed) {
        case ("badHandshake", true):
            guard Self.keys(frame, ["t", "conn"]), let conn = frame["conn"], RelayWire.isConnID(conn) else {
                return [.close(socket, code: 4002, reason: "protocol")]
            }
            s.badHandshakes[mailbox, default: []].append(conn)
            return []
        case ("claim", false):
            guard Self.keys(frame, ["t", "hostKey", "accessKey", "sig"]),
                  let hostKey = frame["hostKey"].flatMap({ RemoteHandshake.decode($0, expectedCount: 32) }),
                  let accessKey = frame["accessKey"].flatMap({ RemoteHandshake.decode($0, expectedCount: 32) }),
                  let sig = frame["sig"].flatMap({ RemoteHandshake.decode($0, expectedCount: 64) }) else {
                return [.close(socket, code: 4002, reason: "protocol")]
            }
            if s.takeOnClaim.remove(mailbox) != nil || s.mailboxes[mailbox]?.hostKey != nil {
                return [.close(socket, code: 4009, reason: "taken")]
            }
            guard Self.verify(hostKey: hostKey, sig: sig, mailbox: mailbox, nonce: s.sockets[socket.id]?.nonce) else {
                return [.close(socket, code: 4001, reason: "unauthorized")]
            }
            s.mailboxes[mailbox] = Mailbox(hostKey: hostKey, accessKey: accessKey)
            return becomeHost(&s, socket)
        case ("auth", false):
            guard Self.keys(frame, ["t", "sig"]), let sig = frame["sig"].flatMap({ RemoteHandshake.decode($0, expectedCount: 64) }) else {
                return [.close(socket, code: 4002, reason: "protocol")]
            }
            guard let hostKey = s.mailboxes[mailbox]?.hostKey else { return [.close(socket, code: 4004, reason: "no such mailbox")] }
            guard Self.verify(hostKey: hostKey, sig: sig, mailbox: mailbox, nonce: s.sockets[socket.id]?.nonce) else {
                return [.close(socket, code: 4001, reason: "unauthorized")]
            }
            return becomeHost(&s, socket)
        default:
            return [.close(socket, code: 4002, reason: "protocol")]
        }
    }

    /// Signs this socket in and replaces any older control socket of the mailbox (4009).
    private func becomeHost(_ s: inout State, _ socket: Socket) -> [Effect] {
        var effects: [Effect] = []
        for (id, info) in s.sockets where id != socket.id && info.socket.mailbox == socket.mailbox && info.socket.role == .host && info.authed {
            s.sockets[id]?.authed = false
            effects.append(.close(info.socket, code: 4009, reason: "replaced"))
        }
        s.sockets[socket.id]?.authed = true
        s.sockets[socket.id]?.nonce = nil
        effects.append(.send(socket, opcode: 0x1, payload: Array(#"{"t":"ready"}"#.utf8)))
        return effects
    }

    private func phoneMessage(_ s: inout State, _ socket: Socket, opcode: UInt8, payload: [UInt8]) -> [Effect] {
        guard let info = s.sockets[socket.id], !info.authed, opcode == 0x1, let frame = Self.controlFrame(payload),
              frame["t"] == "access", Self.keys(frame, ["t", "proof"]),
              let proof = frame["proof"].flatMap({ RemoteHandshake.decode($0, expectedCount: 32) }) else {
            return [.close(socket, code: 4002, reason: "protocol")]
        }
        guard let accessKey = s.mailboxes[socket.mailbox]?.accessKey else { return [.close(socket, code: 4004, reason: "no such mailbox")] }
        let message = Data("ensemble-relay-phone|\(socket.mailbox)|\(info.nonce ?? "")".utf8)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: accessKey)) else {
            return [.close(socket, code: 4001, reason: "unauthorized")]
        }
        guard let host = s.sockets.values.first(where: { $0.socket.mailbox == socket.mailbox && $0.socket.role == .host && $0.authed })?.socket,
              let conn = socket.conn else {
            return [.send(socket, opcode: 0x1, payload: Array(#"{"t":"error","code":"macOffline","message":"The Mac is offline."}"#.utf8)),
                    .close(socket, code: 4010, reason: "mac offline")]
        }
        let token = RemoteHandshake.encode(Self.randomBytes(32))
        s.sockets[socket.id]?.authed = true
        s.sockets[socket.id]?.nonce = nil
        s.sockets[socket.id]?.token = token
        s.phoneConnections[socket.mailbox, default: []].append(conn)
        expire(socket, after: Self.pairSeconds) { $0.peer != nil }
        return [.send(socket, opcode: 0x1, payload: Array(#"{"t":"waiting"}"#.utf8)),
                .send(host, opcode: 0x1, payload: Array(#"{"t":"phone","conn":"\#(conn)","token":"\#(token)"}"#.utf8))]
    }

    private func dataMessage(_ s: inout State, _ socket: Socket, opcode: UInt8, payload: [UInt8]) -> [Effect] {
        guard opcode == 0x1, let frame = Self.controlFrame(payload), frame["t"] == "data", Self.keys(frame, ["t", "token"]),
              let token = frame["token"] else {
            s.dataWithoutToken += 1
            return [.close(socket, code: 4002, reason: "protocol")]
        }
        guard let match = s.sockets.first(where: { $0.value.socket.role == .phone && $0.value.socket.mailbox == socket.mailbox
                                                   && $0.value.socket.conn == socket.conn }),
              match.value.authed, match.value.peer == nil, let expected = match.value.token, expected == token else {
            return [.close(socket, code: 4001, reason: "unauthorized")]
        }
        s.sockets[match.key]?.token = nil
        s.sockets[match.key]?.peer = socket.id
        s.sockets[socket.id]?.peer = match.key
        s.sockets[socket.id]?.authed = true
        return [.send(match.value.socket, opcode: 0x1, payload: Array(#"{"t":"paired"}"#.utf8))]
    }

    // MARK: - Helpers

    /// A control frame as string fields. Numbers are kept as their text. Not a frame: nil.
    private static func controlFrame(_ payload: [UInt8]) -> [String: String]? {
        guard payload.count <= 2048, let object = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any],
              object["t"] is String else { return nil }
        var out: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let text as String: out[key] = text
            case let number as NSNumber: out[key] = number.stringValue
            default: return nil
            }
        }
        return out
    }

    /// Exactly these keys, as the relay requires.
    private static func keys(_ frame: [String: String], _ wanted: Set<String>) -> Bool {
        Set(frame.keys) == wanted
    }

    private static func verify(hostKey: Data, sig: Data, mailbox: String, nonce: String?) -> Bool {
        guard let nonce, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: hostKey) else { return false }
        return key.isValidSignature(sig, for: Data("ensemble-relay-host|\(mailbox)|\(nonce)".utf8))
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}

// MARK: - A phone on the relay

extension FakeRelay {
    enum PhoneError: Error {
        case unexpected(String)
    }

    /// Dials the mailbox as a phone, proves the access key and returns the socket once the relay says `paired`. The
    /// Mac's challenge is the next thing on it.
    func dialPhone(mailbox: String, accessKey: SymmetricKey) async throws -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: url.appending(path: "v1/mailbox/\(mailbox)/phone"))
        task.maximumMessageSize = 64 << 20
        task.resume()
        do {
            guard case .challenge(let nonce) = try await Self.control(task) else { throw PhoneError.unexpected("no challenge") }
            let proof = RelayIdentity.phoneProof(accessKey: accessKey, mailboxID: mailbox, nonce: nonce)
            try await task.send(.string(RelayWire.encode(.access(proof: RemoteHandshake.encode(proof)))))
            guard case .waiting = try await Self.control(task) else { throw PhoneError.unexpected("not waiting") }
            guard case .paired = try await Self.control(task) else { throw PhoneError.unexpected("not paired") }
            return task
        } catch {
            task.cancel()
            throw error
        }
    }

    private static func control(_ task: URLSessionWebSocketTask) async throws -> RelayControlFrame {
        guard case .string(let text) = try await task.receive(), let frame = RelayWire.decode(text) else {
            throw PhoneError.unexpected("not a control frame")
        }
        return frame
    }
}
#endif
