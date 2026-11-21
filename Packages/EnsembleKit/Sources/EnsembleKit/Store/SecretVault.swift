#if os(macOS)
import Foundation
import Security

/// All of the Mac app's saved secrets in ONE login keychain item: the iPhone pairing code, the relay key, the alert
/// settings and the optional Anthropic API key.
///
/// Why one item: the app has no Apple team id, so macOS ties "Always Allow" to the exact build, and after every
/// update it asks for the login password once per item it reads (measured on macOS 27.2). One item means one
/// question per update instead of one per secret. The item is read once per launch and kept in memory.
///
/// Items an older version kept separately are moved in the first time each is asked for (macOS may ask for each
/// of those one last time), then the old item is removed.
final class SecretVault: @unchecked Sendable {
    /// The services whose items live in the vault. Anything else (tests use their own service names) is untouched.
    static let services: Set<String> = [
        "com.coquetteluke.ensemble.remote",
        "com.coquetteluke.ensemble.alerts",
        "Ensemble Claude API key",
    ]

    static let shared = SecretVault(backend: .login)

    enum Failure: Error, Equatable, LocalizedError {
        /// macOS was asked for the saved data and the request was refused (or the password prompt was cancelled).
        case refused(OSStatus)
        /// The saved data could not be read back as the vault's own format. It is left untouched.
        case unreadable
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .refused: "macOS did not let Ensemble open its saved data in your keychain. Quit and reopen Ensemble, and choose Always Allow."
            case .unreadable: "Ensemble's saved data in your keychain could not be read. It was left as it is."
            case .failed(let status): "Ensemble could not save to your keychain. \(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")"
            }
        }
    }

    /// The vault's contents. Keys are "service\naccount".
    private struct Contents: Codable, Equatable {
        var version = 1
        var items: [String: Data] = [:]
        /// Keys whose old separate item was already looked for, so it is not looked for again.
        var checked: Set<String> = []
    }

    private enum State {
        case unloaded
        case loaded(Contents)
        case refused(OSStatus)
    }

    let backend: KeychainBackend
    let vaultService: String
    let vaultAccount: String
    private let lock = NSLock()
    private var state = State.unloaded

    init(backend: KeychainBackend, vaultService: String = "com.coquetteluke.ensemble", vaultAccount: String = "secrets") {
        self.backend = backend
        self.vaultService = vaultService
        self.vaultAccount = vaultAccount
    }

    private static func key(_ service: String, _ account: String) -> String { "\(service)\n\(account)" }

    func read(service: String, account: String) throws -> Data? {
        try locked { contents in
            let key = Self.key(service, account)
            if let data = contents.items[key] { return data }
            guard !contents.checked.contains(key) else { return nil }
            // Not in the vault yet: an older version may have kept it as its own item.
            switch backend.read(service, account) {
            case .missing:
                contents.checked.insert(key)
                try save(contents)
                return nil
            case .value(let data):
                contents.items[key] = data
                contents.checked.insert(key)
                try save(contents)
                _ = backend.delete(service, account)
                return data
            case .refused(let status):
                // Never answer "nothing saved" for something that is there: the caller would make a new pairing.
                throw Failure.refused(status)
            }
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        try locked { contents in
            let key = Self.key(service, account)
            contents.items[key] = data
            contents.checked.insert(key)
            try save(contents)
            _ = backend.delete(service, account)
        }
    }

    func delete(service: String, account: String) throws {
        try locked { contents in
            let key = Self.key(service, account)
            contents.items[key] = nil
            contents.checked.insert(key)
            try save(contents)
            _ = backend.delete(service, account)
        }
    }

    /// Loads the vault once per launch, runs `body` on its contents and keeps any change in memory. A load that was
    /// refused is not retried until the next launch, so a cancelled prompt does not come straight back.
    private func locked<T>(_ body: (inout Contents) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var contents: Contents
        switch state {
        case .loaded(let current):
            contents = current
        case .refused(let status):
            throw Failure.refused(status)
        case .unloaded:
            switch backend.read(vaultService, vaultAccount) {
            case .missing:
                contents = Contents()
            case .value(let data):
                guard let decoded = try? JSONDecoder().decode(Contents.self, from: data) else { throw Failure.unreadable }
                contents = decoded
            case .refused(let status):
                state = .refused(status)
                throw Failure.refused(status)
            }
        }
        let result = try body(&contents)
        state = .loaded(contents)
        return result
    }

    private func save(_ contents: Contents) throws {
        let data = try JSONEncoder().encode(contents)
        let status = backend.write(data, vaultService, vaultAccount, "Ensemble")
        guard status == errSecSuccess else { throw Failure.failed(status) }
    }
}

/// The login keychain, one generic password at a time.
struct KeychainBackend: Sendable {
    enum ReadResult: Equatable {
        case missing
        case value(Data)
        case refused(OSStatus)
    }

    var read: @Sendable (_ service: String, _ account: String) -> ReadResult
    var write: @Sendable (_ data: Data, _ service: String, _ account: String, _ label: String) -> OSStatus
    /// Best effort: removes an item if there is one. Never shows a prompt; an item it may not remove stays.
    var delete: @Sendable (_ service: String, _ account: String) -> OSStatus

    static let login = KeychainBackend(
        read: { service, account in
            var query = baseQuery(service, account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return .missing }
            guard status == errSecSuccess, let data = result as? Data else { return .refused(status) }
            return .value(data)
        },
        write: { data, service, account, label in
            let query = baseQuery(service, account)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecItemNotFound else { return status }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil)
        },
        delete: { service, account in
            // The "may macOS show a prompt" switch is one setting for the whole process, so callers take turns.
            interaction.lock()
            defer { interaction.unlock() }
            var allowed = DarwinBoolean(true)
            SecKeychainGetUserInteractionAllowed(&allowed)
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
            return SecItemDelete(baseQuery(service, account) as CFDictionary)
        })

    private static let interaction = NSLock()

    private static func baseQuery(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
#endif
