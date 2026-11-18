import CryptoKit
import Foundation
import Synchronization

/// Where the relay lives unless the user picks another.
public enum RelayDefaults {
    public static let url = "wss://relay.coquettemc.com"
}

/// The Mac's place on the relay: a mailbox ID (an address, not a secret: it is in the pairing code and in request
/// paths) and the Ed25519 key that proves the mailbox is this Mac's. Made together with the pairing code and kept in
/// the keychain (`KeychainRelayIdentityStore`); regenerating the code makes a new one.
///
/// Also the relay's shared derivations, used by the Mac and the phone alike:
/// - the access key a phone proves it knows before the relay wakes the Mac, `HKDF-SHA256(token, "ensemble-relay",
///   "ensemble-relay-access")`, one-way so it never reveals the token;
/// - the phone proof, HMAC-SHA256 under the access key over `ensemble-relay-phone|<id>|<nonce>`;
/// - the host signature payload, `ensemble-relay-host|<id>|<nonce>`;
/// - the channel binding for relayed connections, `relay:<relay host>/<id>` on port 443.
///
/// `relay/test/vectors.test.ts` and `RelayIdentityTests` check the same fixed vectors, so the two sides cannot drift.
public struct RelayIdentity: Sendable {
    public let mailboxID: String
    public let hostKey: Curve25519.Signing.PrivateKey

    /// The port a phone names in its hello for a relayed connection, whatever port the relay URL has.
    public static let channelPort = 443

    public init(mailboxID: String, hostKey: Curve25519.Signing.PrivateKey) {
        self.mailboxID = mailboxID
        self.hostKey = hostKey
    }

    /// A new mailbox ID (32 random bytes, base64url) and a new host key.
    public static func make() -> RelayIdentity {
        RelayIdentity(mailboxID: RemoteHandshake.encode(RemoteHandshake.makeNonce()), hostKey: Curve25519.Signing.PrivateKey())
    }

    /// The key a phone proves it knows to the relay: HKDF-SHA256 of the token's UTF-8 bytes, salt `ensemble-relay`,
    /// info `ensemble-relay-access`, 32 bytes.
    public static func accessKey(token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)), salt: Data("ensemble-relay".utf8),
                               info: Data("ensemble-relay-access".utf8), outputByteCount: 32)
    }

    /// What a phone that came through the relay says it dialed: `relay:<relay host>/<mailbox ID>`.
    public static func channelHost(relayURL: URL, mailboxID: String) -> String {
        "relay:\((relayURL.host(percentEncoded: false) ?? "").lowercased())/\(mailboxID)"
    }

    /// What the host signs to claim or sign in to its mailbox: `ensemble-relay-host|<id>|<nonce>` as UTF-8.
    public static func hostSignaturePayload(mailboxID: String, nonce: String) -> Data {
        Data("ensemble-relay-host|\(mailboxID)|\(nonce)".utf8)
    }

    /// A phone's answer to the relay's challenge: HMAC-SHA256 under the access key over
    /// `ensemble-relay-phone|<id>|<nonce>`.
    public static func phoneProof(accessKey: SymmetricKey, mailboxID: String, nonce: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("ensemble-relay-phone|\(mailboxID)|\(nonce)".utf8), using: accessKey))
    }

    /// The raw Ed25519 public key, base64url, as the `claim` frame carries it.
    public var hostPublicKey: String {
        RemoteHandshake.encode(hostKey.publicKey.rawRepresentation)
    }

    /// The host key's signature over the payload for this challenge nonce.
    public func signature(nonce: String) throws -> Data {
        try hostKey.signature(for: Self.hostSignaturePayload(mailboxID: mailboxID, nonce: nonce))
    }

    // MARK: Storage

    private struct Stored: Codable {
        var mailboxID: String
        /// The raw 32-byte Ed25519 private key, base64url.
        var hostKey: String
    }

    /// The form the keychain keeps: the mailbox ID and the raw host key. Only stores call this.
    func encoded() throws -> Data {
        try JSONEncoder().encode(Stored(mailboxID: mailboxID, hostKey: RemoteHandshake.encode(hostKey.rawRepresentation)))
    }

    /// Reads the stored form; nil when it is not a whole, valid identity.
    init?(encoded data: Data) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), RelayWire.isMailboxID(stored.mailboxID),
              let raw = RemoteHandshake.decode(stored.hostKey, expectedCount: 32),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        self.init(mailboxID: stored.mailboxID, hostKey: key)
    }

    /// The stored identity, or a new one saved to the store.
    public static func loadOrCreate(in store: any RelayIdentityStore) throws -> RelayIdentity {
        if let existing = try store.loadIdentity() { return existing }
        return try regenerate(in: store)
    }

    /// A new identity in place of the stored one, for a regenerated pairing code. Phones paired with the old code can
    /// no longer reach the old mailbox's Mac.
    public static func regenerate(in store: any RelayIdentityStore) throws -> RelayIdentity {
        let fresh = make()
        try store.saveIdentity(fresh)
        return fresh
    }
}

/// Printing an identity shows the mailbox only, never the key.
extension RelayIdentity: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RelayIdentity(mailbox: \(mailboxID))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["mailboxID": mailboxID], displayStyle: .struct) }
}

// MARK: - Stores

/// Where the Mac keeps its relay identity.
public protocol RelayIdentityStore: Sendable {
    func loadIdentity() throws -> RelayIdentity?
    func saveIdentity(_ identity: RelayIdentity) throws
    func deleteIdentity() throws
}

/// Keeps the identity in the keychain as a generic password, next to the pairing token.
public struct KeychainRelayIdentityStore: RelayIdentityStore {
    public var service: String
    public var account: String

    public init(service: String = RemoteKeychain.defaultService, account: String = "relay-identity") {
        self.service = service
        self.account = account
    }

    public func loadIdentity() throws -> RelayIdentity? {
        try RemoteKeychain.read(service: service, account: account).flatMap(RelayIdentity.init(encoded:))
    }

    public func saveIdentity(_ identity: RelayIdentity) throws {
        try RemoteKeychain.write(try identity.encoded(), service: service, account: account, label: "Ensemble relay identity")
    }

    public func deleteIdentity() throws {
        try RemoteKeychain.delete(service: service, account: account)
    }
}

/// Identity store for tests and previews. Keeps the same stored form as the keychain store.
public final class InMemoryRelayIdentityStore: RelayIdentityStore {
    private let stored = Mutex<Data?>(nil)

    public init() {}

    public func loadIdentity() throws -> RelayIdentity? {
        stored.withLock { $0 }.flatMap(RelayIdentity.init(encoded:))
    }

    public func saveIdentity(_ identity: RelayIdentity) throws {
        let data = try identity.encoded()
        stored.withLock { $0 = data }
    }

    public func deleteIdentity() throws {
        stored.withLock { $0 = nil }
    }
}
