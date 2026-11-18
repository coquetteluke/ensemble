import Foundation
import Security

/// The optional Anthropic API key for Claude agents set to API billing, kept in the login Keychain under Ensemble's own
/// service name. This is never Claude Code's own login: Ensemble does not read or touch that Keychain item.
struct ClaudeKeychain: Sendable {
    let service: String
    let account: String

    static let defaultService = "Ensemble Claude API key"

    init(service: String = ClaudeKeychain.defaultService, account: String = "anthropic") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    var hasKey: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw ClaudeCodeError.keychain(Self.message(added)) }
        } else if status != errSecSuccess {
            throw ClaudeCodeError.keychain(Self.message(status))
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClaudeCodeError.keychain(Self.message(status)) }
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}
