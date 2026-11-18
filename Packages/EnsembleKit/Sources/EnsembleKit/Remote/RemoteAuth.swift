import Foundation
import Security
import Synchronization

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

    public func isBlocked(_ address: String, now: Date = Date()) -> Bool {
        if let until = blockedUntil[address], until > now { return true }
        return false
    }

    public mutating func recordFailure(_ address: String, now: Date = Date()) {
        var list = (failures[address] ?? []).filter { now.timeIntervalSince($0) < window }
        list.append(now)
        failures[address] = list
        if list.count >= maxFailures {
            blockedUntil[address] = now.addingTimeInterval(blockDuration)
            failures[address] = []
        }
        // Keep the tables small.
        if failures.count > 1024 { failures = failures.filter { !$0.value.isEmpty } }
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

/// Saves the phone's pairing in the Keychain.
public struct RemotePairingStore: Sendable {
    public var service: String
    public var account: String

    public init(service: String = RemoteKeychain.defaultService, account: String = "pairing") {
        self.service = service
        self.account = account
    }

    public func load() -> RemotePairing? {
        guard let data = try? RemoteKeychain.read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(RemotePairing.self, from: data)
    }

    public func save(_ pairing: RemotePairing) throws {
        try RemoteKeychain.write(try JSONEncoder().encode(pairing), service: service, account: account)
    }

    public func delete() throws {
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

    public static func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Ensemble Remote pairing"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
    }

    public static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
