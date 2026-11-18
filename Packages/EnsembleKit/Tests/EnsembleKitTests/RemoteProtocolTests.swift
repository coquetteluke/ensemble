import CryptoKit
import Foundation
import Testing
@testable import EnsembleKit

@Suite struct RemoteProtocolTests {
    let data = RemoteDemoData.sample(now: Date(timeIntervalSince1970: 1_800_000_000))

    func roundTrip<M>(_ frame: RemoteFrame<M>) throws -> RemoteFrame<M> {
        let encoded = try RemoteCoding.encode(frame)
        return try RemoteCoding.decode(RemoteFrame<M>.self, from: encoded)
    }

    @Test func clientMessagesRoundTrip() throws {
        let room = RemoteDemoData.IDs.roomID
        let messages: [RemoteClientMessage] = [
            .hello(RemoteHello(deviceName: "Test iPhone", deviceID: "dev-1", clientNonce: "bm9uY2U", proof: "cHJvb2Y")),
            .hubSnapshot,
            .openSession(sessionID: "s1"),
            .closeSession(sessionID: "s1"),
            .sendMessage(RemoteSendMessage(target: .session("s1"), text: "hello")),
            .sendMessage(RemoteSendMessage(target: .room(room), text: "plan it", agent: "Ada")),
            .replyPermission(RemotePermissionReply(sessionID: "s1", requestID: "p1", decision: .always)),
            .setPermissionMode(RemoteSetPermissionMode(target: .room(room), mode: .acceptEdits)),
            .interrupt(target: .session("s1")),
            .roomControl(RemoteRoomControl(roomID: room, action: .pause)),
            .roomsRequest,
            .usageRequest,
        ]
        for (i, m) in messages.enumerated() {
            let frame = RemoteClientFrame(m, id: String(i))
            let back = try roundTrip(frame)
            #expect(back == frame)
            #expect(back.version == remoteProtocolVersion)
        }
    }

    @Test func serverMessagesRoundTrip() throws {
        let transcript = try #require(data.transcripts[RemoteDemoData.IDs.roomSession])
        let updates: [RemoteUpdate] = [
            .sessionUpserted(session: data.sessions[0]),
            .sessionRemoved(sessionID: "x"),
            .transcriptUpsert(sessionID: "s", item: .tool(ToolCallInfo(id: "t", name: "bash", title: "ls", status: .running))),
            .textDelta(sessionID: "s", itemID: "a1", delta: " more"),
            .activity(sessionID: "s", activity: .working),
            .permissionAsked(request: data.permissions[0]),
            .permissionReplied(sessionID: "s", requestID: "p", decision: .reject),
            .permissionReplied(sessionID: "s", requestID: "p", decision: nil),
            .permissionModeChanged(target: .session("s"), mode: .bypass),
            .usage(sessionID: "s", usage: Usage(inputTokens: 1, outputTokens: 2, costUSD: 0.5)),
            .roomUpserted(room: data.rooms[0]),
            .roomRemoved(roomID: RemoteDemoData.IDs.roomID),
            .usageSummary(summary: data.usage),
        ]
        var messages: [RemoteServerMessage] = [
            .challenge(RemoteChallenge(serverNonce: RemoteHandshake.encode(RemoteHandshake.makeNonce()))),
            .welcome(RemoteWelcome(macName: "Test Mac", deviceID: "dev-1", appVersion: "0.1.0", serverProof: "cHJvb2Y")),
            .hub(RemoteHubSnapshot(sessions: data.sessions, permissions: data.permissions)),
            .transcript(transcript),
            .rooms(data.rooms),
            .usage(data.usage),
            .ack,
            .error(RemoteError(.unauthorized, "nope")),
        ]
        messages += updates.map { .update($0) }
        for m in messages {
            let frame = RemoteServerFrame(m, replyTo: "9")
            #expect(try roundTrip(frame) == frame)
        }
    }

    @Test func wireShapeIsFlatAndReadable() throws {
        let frame = RemoteClientFrame(.openSession(sessionID: "abc"), id: "3")
        let json = try JSONSerialization.jsonObject(with: RemoteCoding.encode(frame)) as? [String: Any]
        #expect(json?["v"] as? Int == remoteProtocolVersion)
        #expect(json?["id"] as? String == "3")
        #expect(json?["type"] as? String == "openSession")
        #expect((json?["data"] as? [String: Any])?["sessionID"] as? String == "abc")

        let target = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteTarget.session("s1"))) as? [String: String]
        #expect(target == ["kind": "session", "id": "s1"])
    }

    // MARK: Challenge-response

    @Test func proofsVerifyOnlyWithTheRightTokenAndNonces() {
        let token = RemoteToken.generate()
        let server = RemoteHandshake.makeNonce()
        let client = RemoteHandshake.makeNonce()
        #expect(server.count == 32 && server != client)

        let clientProof = RemoteHandshake.clientProof(token: token, serverNonce: server, clientNonce: client)
        let serverProof = RemoteHandshake.serverProof(token: token, serverNonce: server, clientNonce: client)
        #expect(clientProof.count == 32)
        #expect(RemoteHandshake.isValidClientProof(clientProof, token: token, serverNonce: server, clientNonce: client))
        #expect(RemoteHandshake.isValidServerProof(serverProof, token: token, serverNonce: server, clientNonce: client))

        // Wrong token, swapped or fresh nonces, and one proof used as the other all fail.
        #expect(!RemoteHandshake.isValidClientProof(clientProof, token: RemoteToken.generate(), serverNonce: server, clientNonce: client))
        #expect(!RemoteHandshake.isValidClientProof(clientProof, token: token, serverNonce: client, clientNonce: server))
        #expect(!RemoteHandshake.isValidClientProof(clientProof, token: token, serverNonce: RemoteHandshake.makeNonce(), clientNonce: client))
        #expect(!RemoteHandshake.isValidServerProof(clientProof, token: token, serverNonce: server, clientNonce: client))
        #expect(!RemoteHandshake.isValidClientProof(serverProof, token: token, serverNonce: server, clientNonce: client))
        #expect(clientProof != serverProof)
    }

    @Test func proofMatchesTheSpecifiedHMAC() {
        // HMAC-SHA256(token, serverNonce || clientNonce || "ensemble-client"), computed independently.
        let token = "test-token"
        let server = Data(repeating: 1, count: 32)
        let client = Data(repeating: 2, count: 32)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: server + client + Data("ensemble-client".utf8),
                                                            using: SymmetricKey(data: Data(token.utf8))))
        #expect(RemoteHandshake.clientProof(token: token, serverNonce: server, clientNonce: client) == expected)
        let expectedServer = Data(HMAC<SHA256>.authenticationCode(for: client + server + Data("ensemble-server".utf8),
                                                                  using: SymmetricKey(data: Data(token.utf8))))
        #expect(RemoteHandshake.serverProof(token: token, serverNonce: server, clientNonce: client) == expectedServer)
    }

    @Test func nonceEncodingRoundTripsAndChecksLength() {
        let n = RemoteHandshake.makeNonce()
        let text = RemoteHandshake.encode(n)
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(RemoteHandshake.decode(text, expectedCount: 32) == n)
        #expect(RemoteHandshake.decode(text, expectedCount: 16) == nil)
        #expect(RemoteHandshake.decode("not base64 !!", expectedCount: 32) == nil)
        #expect(RemoteHandshake.decode(String(repeating: "A", count: 400), expectedCount: 32) == nil)
    }

    @Test func helloNeverCarriesTheToken() throws {
        let token = RemoteToken.generate()
        let server = RemoteHandshake.makeNonce()
        let client = RemoteHandshake.makeNonce()
        let proof = RemoteHandshake.clientProof(token: token, serverNonce: server, clientNonce: client)
        let hello = RemoteClientFrame(.hello(RemoteHello(deviceName: "p", deviceID: "d", clientNonce: RemoteHandshake.encode(client),
                                                         proof: RemoteHandshake.encode(proof))), id: "1")
        let text = String(decoding: try RemoteCoding.encode(hello), as: UTF8.self)
        #expect(!text.contains(token))
        #expect(!text.contains("\"token\""))
        #expect(remoteProtocolVersion == 2 && remoteMinimumProtocolVersion == 2)
    }

    @Test func unknownTypeIsReported() throws {
        let text = #"{"v":1,"id":"5","type":"teleport","data":{}}"#
        #expect(throws: RemoteWireError.unknownType("teleport")) {
            try RemoteCoding.decode(RemoteClientFrame.self, from: Data(text.utf8))
        }
        let header = try JSONDecoder().decode(RemoteFrameHeader.self, from: Data(text.utf8))
        #expect(header.id == "5")
        #expect(header.type == "teleport")
    }

    @Test func pairingCodeRoundTripsAsJSONAndBase64() throws {
        let pairing = RemotePairing(hosts: ["mac.example.ts.net", "100.100.100.100", "fd7a:115c:a1e0::1"], port: 47823,
                                    token: RemoteToken.generate(), macName: "Test Mac")
        let code = pairing.code()
        #expect(code.hasPrefix("{"))
        #expect(try RemotePairing(code: code) == pairing)
        #expect(try RemotePairing(code: "  \n" + code + "\n") == pairing)

        let b64url = Data(code.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(try RemotePairing(code: b64url) == pairing)
    }

    @Test func oldPairingWithoutVersionStillDecodes() throws {
        let old = #"{"hosts":["h"],"port":47823,"token":"abc","macName":"Mac"}"#
        let p = try RemotePairing(code: old)
        #expect(p.protocolVersion == 1)
        #expect(p.hosts == ["h"])
    }

    @Test func badPairingCodesAreRejected() {
        #expect(throws: RemotePairing.CodeError.unreadable) { try RemotePairing(code: "hello") }
        #expect(throws: RemotePairing.CodeError.missingHosts) {
            try RemotePairing(code: #"{"hosts":[" "],"port":1,"token":"a","macName":"M"}"#)
        }
        #expect(throws: RemotePairing.CodeError.badPort) {
            try RemotePairing(code: #"{"hosts":["h"],"port":70000,"token":"a","macName":"M"}"#)
        }
        #expect(throws: RemotePairing.CodeError.missingToken) {
            try RemotePairing(code: #"{"hosts":["h"],"port":1,"token":"","macName":"M"}"#)
        }
    }

    @Test func webSocketURLsBracketIPv6() {
        #expect(RemotePairing.webSocketURL(host: "mac.example.ts.net", port: 47823)?.absoluteString == "ws://mac.example.ts.net:47823/ensemble")
        #expect(RemotePairing.webSocketURL(host: "fd7a:115c:a1e0::1", port: 1)?.absoluteString == "ws://[fd7a:115c:a1e0::1]:1/ensemble")
    }

    @Test func tokensAreRandomAndCompareCorrectly() {
        let a = RemoteToken.generate()
        let b = RemoteToken.generate()
        #expect(a.count == 43)
        #expect(a != b)
        #expect(RemoteToken.constantTimeEquals(a, a))
        #expect(!RemoteToken.constantTimeEquals(a, b))
        #expect(!RemoteToken.constantTimeEquals(a, String(a.dropLast())))
        #expect(!RemoteToken.constantTimeEquals("", a))
        #expect(RemoteToken.constantTimeEquals("", ""))
    }

    @Test func tokenStoreKeepsOneToken() throws {
        let store = InMemoryRemoteTokenStore()
        let first = try RemoteToken.loadOrCreate(in: store)
        #expect(try RemoteToken.loadOrCreate(in: store) == first)
        try store.deleteToken()
        #expect(try RemoteToken.loadOrCreate(in: store) != first)
    }

    @Test func limiterBlocksAfterRepeatedFailures() {
        var limiter = RemoteHelloLimiter(maxFailures: 3, window: 60, blockDuration: 120)
        let t0 = Date(timeIntervalSince1970: 1000)
        limiter.recordFailure("1.2.3.4", now: t0)
        limiter.recordFailure("1.2.3.4", now: t0.addingTimeInterval(1))
        #expect(!limiter.isBlocked("1.2.3.4", now: t0.addingTimeInterval(2)))
        limiter.recordFailure("1.2.3.4", now: t0.addingTimeInterval(2))
        #expect(limiter.isBlocked("1.2.3.4", now: t0.addingTimeInterval(3)))
        #expect(!limiter.isBlocked("5.6.7.8", now: t0.addingTimeInterval(3)))
        #expect(!limiter.isBlocked("1.2.3.4", now: t0.addingTimeInterval(200)))

        // Failures spread out beyond the window do not add up.
        var slow = RemoteHelloLimiter(maxFailures: 3, window: 60, blockDuration: 120)
        for i in 0..<10 { slow.recordFailure("9.9.9.9", now: t0.addingTimeInterval(Double(i) * 61)) }
        #expect(!slow.isBlocked("9.9.9.9", now: t0.addingTimeInterval(700)))
    }

    @Test func qrCodeRenders() throws {
        let image = try #require(RemoteQRCode.cgImage(for: RemotePairing(hosts: ["h"], port: 1, token: "t", macName: "M").code(), scale: 4))
        #expect(image.width > 50)
        #expect(image.width == image.height)
    }

    #if os(macOS)
    @Test func tailscaleRanges() {
        #expect(RemoteNetworkInfo.isTailscaleIPv4("100.64.0.1"))
        #expect(RemoteNetworkInfo.isTailscaleIPv4("100.127.255.254"))
        #expect(!RemoteNetworkInfo.isTailscaleIPv4("100.128.0.1"))
        #expect(!RemoteNetworkInfo.isTailscaleIPv4("100.63.0.1"))
        #expect(!RemoteNetworkInfo.isTailscaleIPv4("192.168.1.10"))
        #expect(RemoteNetworkInfo.isTailscaleIPv6("fd7a:115c:a1e0::abcd"))
        #expect(!RemoteNetworkInfo.isTailscaleIPv6("fe80::1"))
    }

    @Test func pairingHostOrderAndBindAddresses() {
        let info = RemoteNetworkInfo(tailscaleIPv4: ["100.101.102.103"], tailscaleIPv6: ["fd7a:115c:a1e0::5"],
                                     magicDNSName: "mac.example.ts.net", localHostName: "Mac.local",
                                     lanIPv4: ["192.168.1.20"], computerName: "Mac")
        #expect(info.pairingHosts(includeLocalNetwork: false) == ["mac.example.ts.net", "100.101.102.103", "fd7a:115c:a1e0::5"])
        #expect(info.pairingHosts(includeLocalNetwork: true).suffix(2) == ["Mac.local", "192.168.1.20"])
        #expect(info.bindAddresses(includeLocalNetwork: false) == ["127.0.0.1", "100.101.102.103", "fd7a:115c:a1e0::5"])
        #expect(!info.bindAddresses(includeLocalNetwork: false).contains("0.0.0.0"))
        #expect(info.bindAddresses(includeLocalNetwork: true).last == "192.168.1.20")
    }
    #endif
}
