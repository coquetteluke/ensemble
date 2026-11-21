#if os(macOS)
import Foundation
import Security
import Testing
@testable import EnsembleKit

@Suite struct SecretVaultTests {
    /// A stand-in login keychain. `locked` items need approval: each read of one counts as a password prompt.
    final class FakeKeychain: @unchecked Sendable {
        var items: [String: Data] = [:]
        var locked: Set<String> = []
        var refuse = false
        private(set) var prompts = 0
        private(set) var writes = 0
        private(set) var deletes: [String] = []

        func key(_ s: String, _ a: String) -> String { "\(s)|\(a)" }

        var backend: KeychainBackend {
            KeychainBackend(
                read: { s, a in
                    let k = self.key(s, a)
                    guard let data = self.items[k] else { return .missing }
                    if self.locked.contains(k) {
                        self.prompts += 1
                        if self.refuse { return .refused(errSecAuthFailed) }
                        self.locked.remove(k)
                    }
                    return .value(data)
                },
                write: { data, s, a, _ in
                    self.writes += 1
                    self.items[self.key(s, a)] = data
                    return errSecSuccess
                },
                delete: { s, a in
                    let k = self.key(s, a)
                    guard self.items[k] != nil else { return errSecItemNotFound }
                    self.deletes.append(k)
                    self.items[k] = nil
                    return errSecSuccess
                })
        }
    }

    let remote = "com.coquetteluke.ensemble.remote"

    @Test func everythingGoesIntoOneItem() throws {
        let keychain = FakeKeychain()
        let vault = SecretVault(backend: keychain.backend)
        try vault.write(Data("token".utf8), service: remote, account: "pairing-token")
        try vault.write(Data("relay".utf8), service: remote, account: "relay-identity")
        try vault.write(Data("sk".utf8), service: "Ensemble Claude API key", account: "anthropic")
        #expect(Array(keychain.items.keys) == ["com.coquetteluke.ensemble|secrets"])
        // A later launch reads them all back from that one item.
        let later = SecretVault(backend: keychain.backend)
        #expect(try later.read(service: remote, account: "pairing-token") == Data("token".utf8))
        #expect(try later.read(service: remote, account: "relay-identity") == Data("relay".utf8))
        #expect(try later.read(service: "Ensemble Claude API key", account: "anthropic") == Data("sk".utf8))
    }

    @Test func anUpdateAsksOnceNotOncePerSecret() throws {
        let keychain = FakeKeychain()
        let old = SecretVault(backend: keychain.backend)
        try old.write(Data("token".utf8), service: remote, account: "pairing-token")
        try old.write(Data("relay".utf8), service: remote, account: "relay-identity")
        try old.write(Data("alerts".utf8), service: "com.coquetteluke.ensemble.alerts", account: "ntfy")
        // The new build is a stranger to the item, so reading it needs approval.
        keychain.locked = ["com.coquetteluke.ensemble|secrets"]
        let updated = SecretVault(backend: keychain.backend)
        _ = try updated.read(service: remote, account: "pairing-token")
        _ = try updated.read(service: remote, account: "relay-identity")
        _ = try updated.read(service: "com.coquetteluke.ensemble.alerts", account: "ntfy")
        try updated.write(Data("token2".utf8), service: remote, account: "pairing-token")
        #expect(keychain.prompts == 1)
    }

    @Test func movesOldSeparateItemsInOnceAndRemovesThem() throws {
        let keychain = FakeKeychain()
        keychain.items["\(remote)|pairing-token"] = Data("token".utf8)
        keychain.items["\(remote)|relay-identity"] = Data("relay".utf8)
        keychain.locked = ["\(remote)|pairing-token", "\(remote)|relay-identity"]
        let vault = SecretVault(backend: keychain.backend)
        #expect(try vault.read(service: remote, account: "pairing-token") == Data("token".utf8))
        #expect(try vault.read(service: remote, account: "relay-identity") == Data("relay".utf8))
        #expect(keychain.prompts == 2)
        #expect(Set(keychain.deletes) == ["\(remote)|pairing-token", "\(remote)|relay-identity"])
        #expect(Array(keychain.items.keys) == ["com.coquetteluke.ensemble|secrets"])
        // The next launch of the same build: nothing more to move, nothing asked.
        let next = SecretVault(backend: keychain.backend)
        #expect(try next.read(service: remote, account: "pairing-token") == Data("token".utf8))
        #expect(keychain.prompts == 2)
    }

    @Test func somethingNeverSavedIsLookedForOnlyOnce() throws {
        let keychain = FakeKeychain()
        let vault = SecretVault(backend: keychain.backend)
        #expect(try vault.read(service: "Ensemble Claude API key", account: "anthropic") == nil)
        let writes = keychain.writes
        #expect(try vault.read(service: "Ensemble Claude API key", account: "anthropic") == nil)
        #expect(keychain.writes == writes)
        // Not even after a restart.
        let next = SecretVault(backend: keychain.backend)
        keychain.items["Ensemble Claude API key|anthropic"] = Data("planted later".utf8)
        #expect(try next.read(service: "Ensemble Claude API key", account: "anthropic") == nil)
    }

    @Test func aRefusedPromptIsAnErrorNotAnEmptyAnswer() throws {
        let keychain = FakeKeychain()
        let old = SecretVault(backend: keychain.backend)
        try old.write(Data("token".utf8), service: remote, account: "pairing-token")
        keychain.locked = ["com.coquetteluke.ensemble|secrets"]
        keychain.refuse = true
        let vault = SecretVault(backend: keychain.backend)
        #expect(throws: SecretVault.Failure.refused(errSecAuthFailed)) { try vault.read(service: remote, account: "pairing-token") }
        // Nothing is overwritten, and the prompt does not come straight back during this launch.
        #expect(throws: SecretVault.Failure.refused(errSecAuthFailed)) { try vault.write(Data("new".utf8), service: remote, account: "pairing-token") }
        #expect(keychain.prompts == 1)
        keychain.refuse = false
        let relaunched = SecretVault(backend: keychain.backend)
        #expect(try relaunched.read(service: remote, account: "pairing-token") == Data("token".utf8))
    }

    @Test func aRefusedOldItemIsAnErrorToo() throws {
        let keychain = FakeKeychain()
        keychain.items["\(remote)|pairing-token"] = Data("token".utf8)
        keychain.locked = ["\(remote)|pairing-token"]
        keychain.refuse = true
        let vault = SecretVault(backend: keychain.backend)
        #expect(throws: SecretVault.Failure.refused(errSecAuthFailed)) { try vault.read(service: remote, account: "pairing-token") }
        #expect(keychain.items["\(remote)|pairing-token"] == Data("token".utf8))
    }

    @Test func forgettingRemovesItEverywhere() throws {
        let keychain = FakeKeychain()
        keychain.items["\(remote)|pairing-token"] = Data("old".utf8)
        let vault = SecretVault(backend: keychain.backend)
        try vault.delete(service: remote, account: "pairing-token")
        #expect(keychain.items["\(remote)|pairing-token"] == nil)
        #expect(try SecretVault(backend: keychain.backend).read(service: remote, account: "pairing-token") == nil)
    }

    @Test func leavesAnItemItCannotReadAlone() throws {
        let keychain = FakeKeychain()
        keychain.items["com.coquetteluke.ensemble|secrets"] = Data("not the vault format".utf8)
        let vault = SecretVault(backend: keychain.backend)
        #expect(throws: SecretVault.Failure.unreadable) { try vault.write(Data("x".utf8), service: remote, account: "pairing-token") }
        #expect(keychain.items["com.coquetteluke.ensemble|secrets"] == Data("not the vault format".utf8))
    }

    @Test func onlyEnsemblesOwnServicesUseIt() {
        #expect(SecretVault.services.contains(RemoteKeychain.defaultService))
        #expect(SecretVault.services.contains(ClaudeKeychain.defaultService))
        #expect(SecretVault.services.contains("com.coquetteluke.ensemble.alerts"))
        #expect(!SecretVault.services.contains("Ensemble test 1234"))
    }
}
#endif
