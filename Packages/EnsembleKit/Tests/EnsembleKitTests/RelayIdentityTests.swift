import CryptoKit
import Foundation
import Testing
@testable import EnsembleKit

struct RelayIdentityTests {
    // MARK: Vectors shared with the relay

    // `relay/test/vectors.test.ts` computes these with the relay's own checks and WebCrypto. Inputs are counting bytes
    // and the expected values are written in short pieces, so nothing here looks like a real key.

    /// 32 bytes counting up from `start`.
    static func counting(_ start: UInt8) -> Data {
        Data((0..<32).map { start + UInt8($0) })
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func fromHex(_ text: String) -> Data {
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    static let mailboxID = RemoteHandshake.encode(counting(0))
    static let nonce = RemoteHandshake.encode(counting(32))
    static let hostSeed = counting(64)
    static let pairingToken = RemoteHandshake.encode(counting(96))

    static let expectedAccessKey = ["163b3003", "d153f7d3", "89a854db", "83247261", "cb8204e7", "ce16cebc", "4597f84e", "c95b0242"].joined()
    static let expectedPhoneProof = ["02921705", "5be2ead1", "a209742b", "58c5d3d1", "920d1a1f", "5a0cf585", "90f5eef0", "6cc3be00"].joined()
    static let expectedHostPublicKey = ["2543b92f", "f1095511", "476adc83", "69db6ddc", "933665a1", "1978dda1", "404ee106", "6ca9559d"].joined()
    static let expectedHostSignature = [
        "d5a954cd", "2f2c1e4c", "a285ee4a", "7cff6396", "241803a0", "407c47f9", "df2ada7a", "4df57d30",
        "03cc60e5", "f9ce3296", "60bd98fc", "c2babdb9", "a6c95d7b", "ab9c3812", "98879887", "dda5eb05",
    ].joined()

    @Test func inputsMatchTheRelayTest() {
        #expect(Self.mailboxID.count == 43)
        #expect(Self.nonce.count == 43)
        #expect(Self.pairingToken.count == 43)
        #expect(RelayWire.isMailboxID(Self.mailboxID))
    }

    @Test func accessKeyMatchesTheRelayVector() {
        let key = RelayIdentity.accessKey(token: Self.pairingToken)
        #expect(Self.hex(key.withUnsafeBytes { Data($0) }) == Self.expectedAccessKey)
    }

    @Test func accessKeyIsStablePerToken() {
        let token = RemoteToken.generate()
        let a = RelayIdentity.accessKey(token: token).withUnsafeBytes { Data($0) }
        let b = RelayIdentity.accessKey(token: token).withUnsafeBytes { Data($0) }
        let other = RelayIdentity.accessKey(token: RemoteToken.generate()).withUnsafeBytes { Data($0) }
        #expect(a.count == 32)
        #expect(a == b)
        #expect(a != other)
        // One-way: the key is not the token's bytes.
        #expect(a != Data(token.utf8).prefix(32))
    }

    @Test func phoneProofMatchesTheRelayVector() {
        let key = SymmetricKey(data: Self.fromHex(Self.expectedAccessKey))
        let proof = RelayIdentity.phoneProof(accessKey: key, mailboxID: Self.mailboxID, nonce: Self.nonce)
        #expect(Self.hex(proof) == Self.expectedPhoneProof)
        // Bound to the nonce.
        let other = RelayIdentity.phoneProof(accessKey: key, mailboxID: Self.mailboxID, nonce: RemoteHandshake.encode(Self.counting(33)))
        #expect(other != proof)
    }

    @Test func hostSignaturePayloadMatchesTheRelayVector() throws {
        let payload = RelayIdentity.hostSignaturePayload(mailboxID: Self.mailboxID, nonce: Self.nonce)
        #expect(String(decoding: payload, as: UTF8.self) == "ensemble-relay-host|\(Self.mailboxID)|\(Self.nonce)")

        // The key made from the seed is the one the relay derived, and the relay's signature over its payload verifies
        // over ours, so both sides sign and check the same bytes.
        let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hostSeed)
        #expect(Self.hex(hostKey.publicKey.rawRepresentation) == Self.expectedHostPublicKey)
        #expect(hostKey.publicKey.isValidSignature(Self.fromHex(Self.expectedHostSignature), for: payload))

        // And what the identity signs, the relay's key accepts.
        let identity = RelayIdentity(mailboxID: Self.mailboxID, hostKey: hostKey)
        let signature = try identity.signature(nonce: Self.nonce)
        #expect(hostKey.publicKey.isValidSignature(signature, for: payload))
        #expect(!hostKey.publicKey.isValidSignature(signature,
                                                    for: RelayIdentity.hostSignaturePayload(mailboxID: Self.mailboxID,
                                                                                            nonce: RemoteHandshake.encode(Self.counting(33)))))
    }

    // MARK: Identity

    @Test func newIdentityHasAMailboxIDTheRelayAccepts() {
        let a = RelayIdentity.make()
        let b = RelayIdentity.make()
        #expect(RelayWire.isMailboxID(a.mailboxID))
        #expect(a.mailboxID != b.mailboxID)
        #expect(a.hostKey.publicKey.rawRepresentation != b.hostKey.publicKey.rawRepresentation)
    }

    @Test func channelHostIsRelayHostAndMailbox() throws {
        let url = try #require(URL(string: RelayDefaults.url))
        #expect(RelayDefaults.url == "wss://relay.coquettemc.com")
        #expect(RelayIdentity.channelHost(relayURL: url, mailboxID: "X") == "relay:relay.coquettemc.com/X")
        let local = try #require(URL(string: "ws://127.0.0.1:8787"))
        #expect(RelayIdentity.channelHost(relayURL: local, mailboxID: Self.mailboxID) == "relay:127.0.0.1/\(Self.mailboxID)")
        #expect(RelayIdentity.channelPort == 443)
    }

    @Test func identityNeverPrintsItsKey() throws {
        let identity = RelayIdentity(mailboxID: Self.mailboxID, hostKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hostSeed))
        var dumped = ""
        dump(identity, to: &dumped)
        let raw = Self.hostSeed
        for text in [String(describing: identity), String(reflecting: identity), "\(identity)", dumped] {
            #expect(text.contains(Self.mailboxID))
            #expect(!text.contains(Self.hex(raw)))
            #expect(!text.contains(RemoteHandshake.encode(raw)))
            #expect(!text.contains(raw.base64EncodedString()))
            #expect(!text.contains("hostKey"))
        }
    }

    // MARK: Store

    @Test func storeKeepsOneIdentityUntilItIsRegenerated() throws {
        let store = InMemoryRelayIdentityStore()
        #expect(try store.loadIdentity() == nil)
        let first = try RelayIdentity.loadOrCreate(in: store)
        let again = try RelayIdentity.loadOrCreate(in: store)
        #expect(again.mailboxID == first.mailboxID)
        #expect(again.hostKey.rawRepresentation == first.hostKey.rawRepresentation)

        // Regenerating the pairing code replaces the identity: a new mailbox and a new key.
        let fresh = try RelayIdentity.regenerate(in: store)
        #expect(fresh.mailboxID != first.mailboxID)
        #expect(fresh.hostKey.rawRepresentation != first.hostKey.rawRepresentation)
        let loaded = try #require(try store.loadIdentity())
        #expect(loaded.mailboxID == fresh.mailboxID)
        #expect(loaded.hostKey.rawRepresentation == fresh.hostKey.rawRepresentation)

        try store.deleteIdentity()
        #expect(try store.loadIdentity() == nil)
    }

    @Test func storedFormHoldsTheMailboxAndTheRawKey() throws {
        let identity = RelayIdentity(mailboxID: Self.mailboxID, hostKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hostSeed))
        let data = try identity.encoded()
        let back = try #require(RelayIdentity(encoded: data))
        #expect(back.mailboxID == Self.mailboxID)
        #expect(back.hostKey.rawRepresentation == Self.hostSeed)
        // Anything else is not an identity.
        #expect(RelayIdentity(encoded: Data("{}".utf8)) == nil)
        #expect(RelayIdentity(encoded: Data(#"{"mailboxID":"short","hostKey":"\#(RemoteHandshake.encode(Self.hostSeed))"}"#.utf8)) == nil)
        #expect(RelayIdentity(encoded: Data(#"{"mailboxID":"\#(Self.mailboxID)","hostKey":"AAEC"}"#.utf8)) == nil)
    }

    @Test func keychainStoreUsesTheRemoteServiceAndItsOwnAccount() {
        let store = KeychainRelayIdentityStore()
        #expect(store.service == RemoteKeychain.defaultService)
        #expect(store.account == "relay-identity")
    }

    // MARK: Pairing code

    @Test func pairingCodeWithOnlyARelayDecodes() throws {
        let relay = RemotePairing.Relay(url: RelayDefaults.url, mailbox: RelayIdentity.make().mailboxID)
        let pairing = RemotePairing(hosts: [], port: remoteDefaultPort, token: RemoteToken.generate(), macName: "Mac", relay: relay)
        let decoded = try RemotePairing(code: pairing.code())
        #expect(decoded == pairing)
        #expect(decoded.relay == relay)
        #expect(decoded.hosts.isEmpty)
        #expect(decoded.previousRelay == nil)

        // A code may leave the hosts out entirely when it has a relay.
        let bare = #"{"port":1,"token":"a","macName":"M","relay":{"url":"wss://relay.example","mailbox":"\#(relay.mailbox)"}}"#
        #expect(try RemotePairing(code: bare).relay?.url == "wss://relay.example")
    }

    @Test func pairingCodeWithNeitherHostsNorRelayIsRefused() {
        #expect(throws: RemotePairing.CodeError.missingHosts) {
            try RemotePairing(code: #"{"hosts":[],"port":1,"token":"a","macName":"M"}"#)
        }
        #expect(throws: RemotePairing.CodeError.missingHosts) {
            try RemotePairing(code: #"{"port":1,"token":"a","macName":"M"}"#)
        }
        #expect(throws: RemotePairing.CodeError.missingHosts) {
            try RemotePairing(code: #"{"hosts":[],"port":1,"token":"a","macName":"M","relay":{"url":"","mailbox":""}}"#)
        }
    }

    @Test func pairingKeepsThePreviousRelay() throws {
        let old = RemotePairing.Relay(url: "wss://old.example", mailbox: RelayIdentity.make().mailboxID)
        let new = RemotePairing.Relay(url: RelayDefaults.url, mailbox: old.mailbox)
        let pairing = RemotePairing(hosts: ["mac.example.ts.net"], port: 47823, token: RemoteToken.generate(), macName: "Mac",
                                    relay: new, previousRelay: old)
        let decoded = try RemotePairing(code: pairing.code())
        #expect(decoded.relay == new)
        #expect(decoded.previousRelay == old)
        // A code without a relay leaves both out.
        let direct = RemotePairing(hosts: ["h"], port: 1, token: "a", macName: "M")
        #expect(!direct.code().contains("relay"))
    }

    // MARK: Wire

    @Test func controlFramesMatchTheTable() throws {
        let k32 = RemoteHandshake.encode(Data(repeating: 7, count: 32))
        let k64 = RemoteHandshake.encode(Data(repeating: 9, count: 64))
        let conn = RemoteHandshake.encode(Data(repeating: 3, count: 16))
        let frames: [(RelayControlFrame, [String: AnyHashable])] = [
            (.challenge(nonce: k32), ["t": "challenge", "nonce": k32]),
            (.claim(hostKey: k32, accessKey: k32, sig: k64), ["t": "claim", "hostKey": k32, "accessKey": k32, "sig": k64]),
            (.auth(sig: k64), ["t": "auth", "sig": k64]),
            (.ready, ["t": "ready"]),
            (.phone(conn: conn, token: k32), ["t": "phone", "conn": conn, "token": k32]),
            (.data(token: k32), ["t": "data", "token": k32]),
            (.badHandshake(conn: conn), ["t": "badHandshake", "conn": conn]),
            (.access(proof: k32), ["t": "access", "proof": k32]),
            (.waiting, ["t": "waiting"]),
            (.paired, ["t": "paired"]),
            (.limit(resetsAt: 1_700_000_000), ["t": "limit", "kind": "daily", "resetsAt": 1_700_000_000]),
            (.error(code: .macOffline, message: "offline"), ["t": "error", "code": "macOffline", "message": "offline"]),
        ]
        for (frame, fields) in frames {
            let text = RelayWire.encode(frame)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(Set(object.keys) == Set(fields.keys), "\(text)")
            for (key, value) in fields {
                #expect((object[key] as? AnyHashable) == value, "\(key) in \(text)")
            }
            #expect(RelayWire.decode(text) == frame)
        }
    }

    @Test func unreadableOrOversizedFramesDecodeToNil() {
        #expect(RelayWire.decode("pong") == nil)
        #expect(RelayWire.decode(#"{"t":"teleport"}"#) == nil)
        #expect(RelayWire.decode(#"{"t":"error","code":"busy","message":"\#(String(repeating: "x", count: 2100))"}"#) == nil)
    }

    @Test func identifiersFollowTheRelayRules() {
        #expect(RelayWire.isConnID(RemoteHandshake.encode(Data(count: 16))))
        #expect(!RelayWire.isConnID(RemoteHandshake.encode(Data(count: 32))))
        #expect(!RelayWire.isConnID("a/b" + String(RemoteHandshake.encode(Data(count: 16)).dropFirst(3))))
        #expect(!RelayWire.isMailboxID(RemoteHandshake.encode(Data(count: 32)) + "a"))
    }
}
