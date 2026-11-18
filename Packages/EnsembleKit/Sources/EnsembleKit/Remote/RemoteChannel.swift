import CryptoKit
import Foundation

/// Encrypts every frame after the handshake, so a relay on the network can neither read nor change them.
///
/// Keys: HKDF-SHA256 with the pairing token's UTF-8 bytes followed by the 32-byte X25519 shared secret of the two
/// ephemeral keys as input key material (so a leaked token alone cannot open recorded traffic), salt `serverNonce || clientNonce`,
/// and info `ensemble-remote/<version>|<direction>|<host>|<port>`, where version is the protocol version both
/// sides agreed on (the lower of the two), direction is `client-to-server` or `server-to-client`, and host and
/// port are what the phone dialed (host normalised by `normalizedHost`). Each direction has its own 32-byte key.
///
/// Frames: ChaChaPoly, sent as `ciphertext || 16-byte tag`, with `ensemble-remote/<version>` as associated data.
/// The 12-byte nonce is 4 zero bytes and a big-endian 64-bit counter that starts at 0 for each direction and goes
/// up by one per frame. The counter is never sent: a frame that was dropped, reordered, replayed, changed, or
/// sealed with other keys fails to open, and the caller closes the connection.
public struct RemoteChannel: Sendable {
    public enum Role: Sendable { case client, server }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The frame did not open: changed, replayed, out of order, or sealed with other keys.
        case rejected
        /// The counter ran out (never in practice: 2^64 frames).
        case exhausted

        public var errorDescription: String? {
            switch self {
            case .rejected: "A message from the other side could not be verified, so the connection was closed."
            case .exhausted: "The connection has sent too many messages and must reconnect."
            }
        }
    }

    static let tagByteCount = 16
    static let clientToServer = "client-to-server"
    static let serverToClient = "server-to-client"

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let aad: Data
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    /// - Parameter protocolVersion: the version both sides agreed on: the lower of the Mac's (challenge) and the
    ///   phone's (hello). A relay that changes either one makes the keys differ.
    public init(token: String, sharedSecret: Data, serverNonce: Data, clientNonce: Data, dialedHost: String, dialedPort: Int,
                role: Role, protocolVersion: Int = remoteProtocolVersion) {
        let up = Self.deriveKey(token: token, sharedSecret: sharedSecret, serverNonce: serverNonce, clientNonce: clientNonce, version: protocolVersion,
                                host: dialedHost, port: dialedPort, direction: Self.clientToServer)
        let down = Self.deriveKey(token: token, sharedSecret: sharedSecret, serverNonce: serverNonce, clientNonce: clientNonce, version: protocolVersion,
                                  host: dialedHost, port: dialedPort, direction: Self.serverToClient)
        switch role {
        case .client:
            sendKey = up
            receiveKey = down
        case .server:
            sendKey = down
            receiveKey = up
        }
        aad = Self.associatedData(version: protocolVersion)
    }

    /// Seals the next outgoing frame: ciphertext followed by the 16-byte tag.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter < UInt64.max else { throw Failure.exhausted }
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter), authenticating: aad)
        sendCounter += 1
        // A fresh buffer, so the result is indexed from 0 (the box's parts are slices of a larger buffer).
        var out = Data(capacity: box.ciphertext.count + Self.tagByteCount)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// Opens the next incoming frame. Throws `Failure.rejected` for anything that is not exactly the next frame
    /// the other side sealed; the counter does not move, and the caller must close the connection.
    public mutating func open(_ sealed: Data) throws -> Data {
        guard receiveCounter < UInt64.max else { throw Failure.exhausted }
        guard sealed.count >= Self.tagByteCount else { throw Failure.rejected }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                               ciphertext: sealed.prefix(sealed.count - Self.tagByteCount),
                                               tag: sealed.suffix(Self.tagByteCount))
            let plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: aad)
            receiveCounter += 1
            return plaintext
        } catch {
            throw Failure.rejected
        }
    }

    /// Lower case, no brackets around IPv6, no zone, no trailing dot, so both ends derive the same keys.
    public static func normalizedHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let percent = h.firstIndex(of: "%") { h = String(h[..<percent]) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func info(version: Int, host: String, port: Int, direction: String) -> Data {
        Data("ensemble-remote/\(version)|\(direction)|\(normalizedHost(host))|\(port)".utf8)
    }

    static func associatedData(version: Int) -> Data {
        Data("ensemble-remote/\(version)".utf8)
    }

    private static func deriveKey(token: String, sharedSecret: Data, serverNonce: Data, clientNonce: Data, version: Int, host: String, port: Int,
                                  direction: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8) + sharedSecret),
                               salt: serverNonce + clientNonce,
                               info: info(version: version, host: host, port: port, direction: direction),
                               outputByteCount: 32)
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        // 12 bytes is always a valid ChaChaPoly nonce.
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
