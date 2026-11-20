import CryptoKit
import Foundation
import Security
import Synchronization

/// Mutual challenge-response so the pairing token never travels over the wire.
///
/// 1. On connect the Mac sends a random `serverNonce` and a fresh X25519 public key, `macKey` (`challenge`).
/// 2. The phone picks a random `clientNonce` and its own fresh X25519 public key, `phoneKey`, and sends
///    `HMAC-SHA256(token, serverNonce || clientNonce || macKey || phoneKey || "ensemble-client")` with them (`hello`).
/// 3. The Mac checks that proof in constant time and answers with
///    `HMAC-SHA256(token, clientNonce || serverNonce || phoneKey || macKey || "ensemble-server")` (`welcome`).
/// 4. The phone checks the Mac's proof before it trusts anything the Mac sends.
///
/// Both proofs cover both public keys, so a relay that swaps either key makes them fail. The X25519 shared secret
/// of the two keys then goes into the channel keys (see `RemoteChannel`), and both private keys are dropped after the
/// handshake. The HMAC key is the token's UTF-8 bytes. Nonces are 32 random bytes and keys are raw 32 bytes,
/// base64url on the wire.
public enum RemoteHandshake {
    public static let nonceByteCount = 32
    /// Raw length of an X25519 public key.
    public static let keyByteCount = 32
    static let clientLabel = Data("ensemble-client".utf8)
    static let serverLabel = Data("ensemble-server".utf8)

    /// 32 bytes from the system CSPRNG.
    public static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    public static func clientProof(token: String, serverNonce: Data, clientNonce: Data, macKey: Data, phoneKey: Data) -> Data {
        mac(token, clientMessage(serverNonce: serverNonce, clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey))
    }

    public static func serverProof(token: String, serverNonce: Data, clientNonce: Data, macKey: Data, phoneKey: Data) -> Data {
        mac(token, serverMessage(serverNonce: serverNonce, clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey))
    }

    private static func clientMessage(serverNonce: Data, clientNonce: Data, macKey: Data, phoneKey: Data) -> Data {
        serverNonce + clientNonce + macKey + phoneKey + clientLabel
    }

    private static func serverMessage(serverNonce: Data, clientNonce: Data, macKey: Data, phoneKey: Data) -> Data {
        clientNonce + serverNonce + phoneKey + macKey + serverLabel
    }

    /// Constant-time check of the phone's proof.
    public static func isValidClientProof(_ proof: Data, token: String, serverNonce: Data, clientNonce: Data, macKey: Data,
                                          phoneKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: clientMessage(serverNonce: serverNonce, clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey),
            using: key(token))
    }

    /// Constant-time check of the Mac's proof.
    public static func isValidServerProof(_ proof: Data, token: String, serverNonce: Data, clientNonce: Data, macKey: Data,
                                          phoneKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: serverMessage(serverNonce: serverNonce, clientNonce: clientNonce, macKey: macKey, phoneKey: phoneKey),
            using: key(token))
    }

    /// A nonce or proof as base64url without padding.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads base64url; `nil` when it is not valid or not `expectedCount` bytes long.
    public static func decode(_ text: String, expectedCount: Int) -> Data? {
        guard text.count <= 128 else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s), data.count == expectedCount else { return nil }
        return data
    }

    /// An ephemeral key pair for one connection. The private half is a value the caller must drop after the handshake.
    public static func makeKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// The X25519 shared secret (32 bytes) of `privateKey` and the other side's raw public key; `nil` when the public
    /// key is not 32 bytes or gives no usable secret (a low-order point).
    public static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data) -> Data? {
        guard peerKey.count == keyByteCount,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else { return nil }
        return secret.withUnsafeBytes { Data($0) }
    }

    private static func key(_ token: String) -> SymmetricKey {
        SymmetricKey(data: Data(token.utf8))
    }

    private static func mac(_ token: String, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key(token)))
    }
}

/// Pairing token helpers.
public enum RemoteToken {
    /// 32 random bytes from the system CSPRNG, base64url without padding (43 characters).
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares two secrets in time that depends only on their lengths, not on where they differ.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        var diff: UInt8 = x.count == y.count ? 0 : 1
        let n = max(x.count, y.count)
        for i in 0..<n {
            let p: UInt8 = i < x.count ? x[i] : 0
            let q: UInt8 = i < y.count ? y[i] : 0
            diff |= p ^ q
        }
        return diff == 0
    }

    /// The stored token, or a new one saved to the store.
    public static func loadOrCreate(in store: any RemoteTokenStore) throws -> String {
        if let existing = try store.loadToken(), !existing.isEmpty { return existing }
        let fresh = generate()
        try store.saveToken(fresh)
        return fresh
    }
}

/// Counts failed hellos per address and blocks an address that fails too often.
public struct RemoteHelloLimiter: Sendable {
    public var maxFailures: Int
    public var window: TimeInterval
    public var blockDuration: TimeInterval
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(maxFailures: Int = 5, window: TimeInterval = 600, blockDuration: TimeInterval = 900) {
        self.maxFailures = maxFailures
        self.window = window
        self.blockDuration = blockDuration
    }

    var trackedFailureCount: Int { failures.count }

    public func isBlocked(_ address: String, now: Date = Date()) -> Bool {
        if let until = blockedUntil[address], until > now { return true }
        return false
    }

    public mutating func recordFailure(_ address: String, now: Date = Date()) {
        var list = (failures[address] ?? []).filter { now.timeIntervalSince($0) < window }
        list.append(now)
        if list.count >= maxFailures {
            blockedUntil[address] = now.addingTimeInterval(blockDuration)
            failures[address] = nil
        } else {
            failures[address] = list
        }
        // Keep the tables strictly bounded.
        if failures.count > 1024 {
            var pruned: [String: [Date]] = [:]
            pruned.reserveCapacity(min(failures.count, 1024))
            for (key, dates) in failures {
                let active = dates.filter { now.timeIntervalSince($0) < window }
                if !active.isEmpty {
                    pruned[key] = active
                }
            }
            if pruned.count > 1024 {
                let overflow = pruned.count - 1024
                let oldestKeys = pruned
                    .sorted { lhs, rhs in
                        let left = lhs.value.max() ?? .distantPast
                        let right = rhs.value.max() ?? .distantPast
                        return left == right ? lhs.key < rhs.key : left < right
                    }
                    .prefix(overflow)
                    .map(\.key)
                for key in oldestKeys {
                    pruned[key] = nil
                }
            }
            failures = pruned
        }
        if blockedUntil.count > 1024 { blockedUntil = blockedUntil.filter { $0.value > now } }
    }

    public mutating func recordSuccess(_ address: String) {
        failures[address] = nil
    }
}

// MARK: - Storage

/// Where the Mac keeps its pairing token.
public protocol RemoteTokenStore: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

/// Keeps the token in the Keychain as a generic password.
public struct KeychainRemoteTokenStore: RemoteTokenStore {
    public var service: String
    public var account: String

    public init(service: String = RemoteKeychain.defaultService, account: String = "pairing-token") {
        self.service = service
        self.account = account
    }

    public func loadToken() throws -> String? {
        try RemoteKeychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func saveToken(_ token: String) throws {
        try RemoteKeychain.write(Data(token.utf8), service: service, account: account)
    }

    public func deleteToken() throws {
        try RemoteKeychain.delete(service: service, account: account)
    }
}

/// Token store for tests and previews.
public final class InMemoryRemoteTokenStore: RemoteTokenStore {
    private let token: Mutex<String?>

    public init(token: String? = nil) {
        self.token = Mutex(token)
    }

    public func loadToken() throws -> String? { token.withLock { $0 } }
    public func saveToken(_ token: String) throws { self.token.withLock { $0 = token } }
    public func deleteToken() throws { token.withLock { $0 = nil } }
}

/// Saves the phone's pairing in the Keychain (or in memory for tests).
public struct RemotePairingStore: Sendable {
    private final class StorageBox: Sendable {
        let value: Mutex<RemotePairing?>

        init(_ initial: RemotePairing?) {
            self.value = Mutex(initial)
        }
    }

    public var service: String
    public var account: String
    private let memory: StorageBox?

    public init(service: String = RemoteKeychain.defaultService, account: String = "pairing") {
        self.service = service
        self.account = account
        self.memory = nil
    }

    private init(memory: StorageBox) {
        self.service = ""
        self.account = ""
        self.memory = memory
    }

    /// An in-memory store for tests and previews that never touches the Keychain.
    public static func inMemory(initial: RemotePairing? = nil) -> RemotePairingStore {
        RemotePairingStore(memory: StorageBox(initial))
    }

    public func load() -> RemotePairing? {
        if let memory { return memory.value.withLock { $0 } }
        guard let data = try? RemoteKeychain.read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(RemotePairing.self, from: data)
    }

    public func save(_ pairing: RemotePairing) throws {
        if let memory {
            memory.value.withLock { $0 = pairing }
            return
        }
        try RemoteKeychain.write(try JSONEncoder().encode(pairing), service: service, account: account)
    }

    public func delete() throws {
        if let memory {
            memory.value.withLock { $0 = nil }
            return
        }
        try RemoteKeychain.delete(service: service, account: account)
    }
}

/// Small wrapper over Keychain generic passwords.
public enum RemoteKeychain {
    public static let defaultService = "com.coquetteluke.ensemble.remote"

    public struct Failure: Error, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(text)"
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    public static func write(_ data: Data, service: String, account: String, label: String = "Ensemble Remote pairing") throws {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = label
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
    }

    public static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
