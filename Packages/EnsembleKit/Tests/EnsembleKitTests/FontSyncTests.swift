import CoreText
import Foundation
import Testing
@testable import EnsembleKit

/// A Mac for the font sync tests: sample sessions from `DemoRemoteHost`, fonts from a `FontSyncHost`.
@MainActor final class FontTestMac: RemoteHost {
    let demo = DemoRemoteHost()
    let fonts: FontSyncHost

    init(store: FontStore) { fonts = FontSyncHost(store: store) }

    func hubSnapshot() async -> RemoteHubSnapshot { await demo.hubSnapshot() }
    func transcript(sessionID: String) async throws -> RemoteTranscript { try await demo.transcript(sessionID: sessionID) }
    func rooms() async -> [RemoteRoom] { await demo.rooms() }
    func usageSummary() async -> RemoteUsageSummary { await demo.usageSummary() }
    func updates() async -> AsyncStream<RemoteUpdate> { await demo.updates() }
    func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws {
        try await demo.sendMessage(text, to: target, agent: agent)
    }
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws {
        try await demo.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision)
    }
    func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {
        try await demo.setPermissionMode(mode, for: target)
    }
    func interrupt(_ target: RemoteTarget) async throws { try await demo.interrupt(target) }
    func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws { try await demo.controlRoom(roomID, action: action) }

    func syncFonts(_ phone: RemoteFontSettings) async throws -> RemoteFontSettings { fonts.sync(phone) }
    func fontChunk(_ request: RemoteFontFileRequest) async throws -> RemoteFontChunk { try fonts.chunk(request) }
    func receiveFontChunk(_ chunk: RemoteFontChunk) async throws { try fonts.receive(chunk) }
    func fontSettingsUpdates() async -> AsyncStream<RemoteFontSettings> { fonts.updates() }
}

/// The connection without a socket: every message goes through the wire format and the dispatcher, as on the
/// real connection, and is counted by type.
@MainActor final class DispatchTransport: FontSyncTransport {
    let host: any RemoteHost
    private(set) var sent: [String: Int] = [:]

    init(host: any RemoteHost) { self.host = host }

    private func send(_ message: RemoteClientMessage) async throws -> RemoteServerMessage {
        let request = try RemoteCoding.decode(RemoteClientFrame.self, from: RemoteCoding.encode(RemoteClientFrame(message, id: "1")))
        sent[request.message.typeName, default: 0] += 1
        let reply = await RemoteDispatcher.respond(to: request.message, host: host)
        let frame = try RemoteCoding.decode(RemoteServerFrame.self, from: RemoteCoding.encode(RemoteServerFrame(reply, replyTo: "1")))
        if case .error(let error) = frame.message { throw error }
        return frame.message
    }

    func syncFonts(_ mine: RemoteFontSettings) async throws -> RemoteFontSettings {
        guard case .fontSettings(let theirs) = try await send(.fontSync(mine)) else { throw RemoteError(.failed, "wrong reply") }
        return theirs
    }

    func fontChunk(_ request: RemoteFontFileRequest) async throws -> RemoteFontChunk {
        guard case .fontChunk(let chunk) = try await send(.fontFile(request)) else { throw RemoteError(.failed, "wrong reply") }
        return chunk
    }

    func uploadFont(_ chunk: RemoteFontChunk) async throws {
        _ = try await send(.fontUpload(chunk))
    }
}

/// Two devices with a font library each, in temporary folders.
@MainActor struct FontPair {
    let macFolder = TestFont.temporaryFolder()
    let phoneFolder = TestFont.temporaryFolder()
    let downloads = TestFont.temporaryFolder()
    let mac: FontStore
    let phone: FontStore

    init() {
        mac = FontStore(saved: nil, library: CustomFontLibrary(folder: macFolder))
        phone = FontStore(saved: nil, library: CustomFontLibrary(folder: phoneFolder))
    }

    func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Removes the folders and unregisters whatever is still in the libraries.
    func cleanUp() {
        for store in [mac, phone] {
            for family in store.customFamilies { store.remove(.custom(family: family.name)) }
        }
        for folder in [macFolder, phoneFolder, downloads] { try? FileManager.default.removeItem(at: folder) }
    }
}

@Suite @MainActor struct FontSyncTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func theNewerChoiceWinsOnBothDevices() async throws {
        let mac = FontStore.temporary()
        let phone = FontStore.temporary()
        phone.select(.sourceSerif4, for: .chat, at: at(100))
        mac.select(.newYork, for: .chat, at: at(200))
        mac.select(.sanFrancisco, for: .interface, at: at(50))
        phone.select(.ensembleSerif, for: .interface, at: at(300))

        let transport = DispatchTransport(host: FontTestMac(store: mac))
        let sync = FontSyncClient(store: phone, transport: transport)
        await sync.sync()

        #expect(sync.lastProblem == nil)
        // Chat: the Mac chose later. Interface: the iPhone chose later.
        #expect(mac.chat == .newYork && phone.chat == .newYork)
        #expect(mac.interface == .ensembleSerif && phone.interface == .ensembleSerif)
        #expect(mac.ledger == phone.ledger)
        #expect(transport.sent == ["fontSync": 1])

        // Nothing new: another round changes nothing.
        let before = mac.ledger
        await sync.sync()
        #expect(mac.ledger == before && phone.ledger == before)
    }

    @Test func mergeIgnoresOlderChoicesAndKeepsNewerRemovals() {
        let store = FontStore.temporary()
        store.select(.sourceSerif4, for: .chat, at: at(500))

        var older = FontLedger.initial
        older.chat = .init(id: AppFont.newYork.id, changedAt: at(400))
        older.removed = ["Some Family": at(10)]
        #expect(store.merge(older))
        #expect(store.chat == .sourceSerif4)
        #expect(store.ledger.removed == ["Some Family": at(10)])

        // The same again is no change, and an older removal does not replace a newer one.
        #expect(!store.merge(older))
        var stale = older
        stale.removed = ["Some Family": at(5)]
        #expect(!store.merge(stale))
        #expect(store.ledger.removed == ["Some Family": at(10)])
    }

    /// The other device's clock runs ahead. A choice made here afterwards must still count as the newer one.
    @Test func aChoiceMadeHereBeatsWhatThisDeviceHasAlreadySeen() {
        var ahead = FontLedger.initial
        ahead.chat = .init(id: AppFont.newYork.id, changedAt: at(5_000))
        let store = FontStore.temporary()
        store.merge(ahead)
        #expect(store.chat == .newYork)

        store.select(.sourceSerif4, at: at(1_000))
        #expect(store.chat == .sourceSerif4)
        #expect(store.ledger.chat.changedAt > at(5_000))

        let other = FontStore.temporary()
        other.merge(ahead)
        other.merge(store.ledger)
        #expect(other.chat == .sourceSerif4)
    }

    @Test func addedFontsTravelBothWaysAndRemovalsFollow() async throws {
        let pair = FontPair()
        defer { pair.cleanUp() }
        let transport = DispatchTransport(host: FontTestMac(store: pair.mac))
        let sync = FontSyncClient(store: pair.phone, transport: transport)

        // Added and chosen on the Mac: the iPhone gets both files and the choice.
        let first = TestFont.uniqueFamily()
        #expect(pair.mac.add([try TestFont.write(family: first, to: pair.downloads),
                              try TestFont.write(family: first, italic: true, to: pair.downloads)]).isEmpty)
        let firstFont = try #require(pair.mac.choices.last)
        #expect(firstFont.id == "custom:\(first)")
        pair.mac.select(firstFont)
        #expect(pair.phone.chat == .standard)
        await sync.sync()
        #expect(sync.lastProblem == nil)
        #expect(pair.phone.customFamilies.map(\.name) == [first])
        #expect(pair.phone.chat == firstFont)
        #expect(pair.files(in: pair.phoneFolder) == pair.files(in: pair.macFolder))
        #expect(pair.files(in: pair.phoneFolder).count == 2)
        for name in pair.files(in: pair.macFolder) {
            let onMac = try Data(contentsOf: pair.macFolder.appendingPathComponent(name))
            let onPhone = try Data(contentsOf: pair.phoneFolder.appendingPathComponent(name))
            #expect(onMac == onPhone)
            #expect(onMac.count > FontSync.chunkSize)
        }
        // Each file is larger than one piece, so it came in several.
        #expect((transport.sent["fontFile"] ?? 0) >= 4)
        #expect(transport.sent["fontUpload"] == nil)

        // Added on the iPhone: the Mac gets it.
        let second = TestFont.uniqueFamily()
        #expect(pair.phone.add([try TestFont.write(family: second, to: pair.downloads, name: "Second.ttf")]).isEmpty)
        await sync.sync()
        #expect(Set(pair.mac.customFamilies.map(\.name)) == [first, second])
        #expect(pair.files(in: pair.macFolder) == pair.files(in: pair.phoneFolder))
        #expect((transport.sent["fontUpload"] ?? 0) >= 2)

        // Removed on the iPhone while it is the chosen font: gone on the Mac too, and both are on the default.
        pair.phone.remove(firstFont)
        await sync.sync()
        #expect(pair.mac.customFamilies.map(\.name) == [second])
        #expect(pair.mac.chat == .standard && pair.phone.chat == .standard)
        #expect(pair.files(in: pair.macFolder).count == 1)
        // It does not come back on a later round.
        await sync.sync()
        #expect(pair.phone.customFamilies.map(\.name) == [second])
        #expect(pair.mac.customFamilies.map(\.name) == [second])

        // Added again on the Mac later: that is newer than the removal, so both have it again.
        #expect(pair.mac.add([try TestFont.write(family: first, to: pair.downloads)]).isEmpty)
        await sync.sync()
        #expect(Set(pair.phone.customFamilies.map(\.name)) == [first, second])
        #expect(Set(pair.mac.customFamilies.map(\.name)) == [first, second])
    }

    @Test func anOlderMacLeavesTheFontsAsTheyAre() async throws {
        let phone = FontStore.temporary()
        phone.select(.sourceSerif4)
        // `DemoRemoteHost` answers font messages the way a Mac from before font syncing does.
        let transport = DispatchTransport(host: DemoRemoteHost())
        let sync = FontSyncClient(store: phone, transport: transport)
        await sync.sync()
        #expect(phone.chat == .sourceSerif4)
        #expect(sync.lastProblem == "This Mac cannot sync fonts with the iPhone.")
    }

    @Test func theMacTakesOnlyRealFontFilesInOrder() async throws {
        let pair = FontPair()
        defer { pair.cleanUp() }
        let host = FontSyncHost(store: pair.mac)
        let font = try TestFont.data(family: TestFont.uniqueFamily())
        let piece = font.prefix(FontSync.chunkSize)

        func refused(_ chunk: RemoteFontChunk) -> String? {
            do {
                try host.receive(chunk)
                return nil
            } catch {
                return (error as? RemoteError)?.code.rawValue ?? "other"
            }
        }
        // Names that are not a plain font file name.
        for name in ["../Evil.ttf", "sub/Evil.ttf", ".hidden.ttf", "Evil.sh", "Evil", ""] {
            #expect(refused(RemoteFontChunk(family: "F", file: name, offset: 0, total: font.count, data: Data(piece))) == "badRequest")
        }
        // Too large, empty, a piece larger than the size limit of one piece, no family.
        #expect(refused(RemoteFontChunk(family: "F", file: "A.ttf", offset: 0, total: CustomFontLibrary.maxFileSize + 1, data: Data(piece))) == "badRequest")
        #expect(refused(RemoteFontChunk(family: "F", file: "A.ttf", offset: 0, total: font.count, data: Data())) == "badRequest")
        #expect(refused(RemoteFontChunk(family: "F", file: "A.ttf", offset: 0, total: font.count, data: font)) == "badRequest")
        #expect(refused(RemoteFontChunk(family: "", file: "A.ttf", offset: 0, total: font.count, data: Data(piece))) == "badRequest")
        // A piece that does not follow the one before.
        #expect(refused(RemoteFontChunk(family: "F", file: "A.ttf", offset: 0, total: font.count, data: Data(piece))) == nil)
        #expect(refused(RemoteFontChunk(family: "F", file: "A.ttf", offset: 5, total: font.count, data: Data(piece))) == "badRequest")
        // A piece without a start.
        #expect(refused(RemoteFontChunk(family: "F", file: "B.ttf", offset: piece.count, total: font.count, data: Data(piece))) == "badRequest")
        // The right ending and a complete upload, but not a font inside.
        let notes = Data("These are notes, not a font.".utf8)
        #expect(refused(RemoteFontChunk(family: "F", file: "Notes.ttf", offset: 0, total: notes.count, data: notes)) == "badRequest")

        #expect(pair.mac.customFamilies.isEmpty)
        #expect(pair.files(in: pair.macFolder).isEmpty)
    }

    @Test func theMacHandsOutOnlyItsAddedFontFiles() async throws {
        let pair = FontPair()
        defer { pair.cleanUp() }
        let host = FontSyncHost(store: pair.mac)
        let family = TestFont.uniqueFamily()
        #expect(pair.mac.add([try TestFont.write(family: family, to: pair.downloads)]).isEmpty)
        let name = try #require(pair.files(in: pair.macFolder).first)
        let size = try Data(contentsOf: pair.macFolder.appendingPathComponent(name)).count

        let first = try host.chunk(RemoteFontFileRequest(family: family, file: name, offset: 0))
        #expect(first.total == size && first.data.count == FontSync.chunkSize && first.offset == 0)
        let last = try host.chunk(RemoteFontFileRequest(family: family, file: name, offset: size - 10))
        #expect(last.data.count == 10)

        func refused(_ request: RemoteFontFileRequest) -> String? {
            do {
                _ = try host.chunk(request)
                return nil
            } catch {
                return (error as? RemoteError)?.code.rawValue ?? "other"
            }
        }
        #expect(refused(RemoteFontFileRequest(family: family, file: name, offset: size)) == "badRequest")
        #expect(refused(RemoteFontFileRequest(family: family, file: name, offset: -1)) == "badRequest")
        // A file of the bundled fonts, a path out of the folder, another family: not handed out.
        #expect(refused(RemoteFontFileRequest(family: family, file: "../" + name, offset: 0)) == "notFound")
        #expect(refused(RemoteFontFileRequest(family: family, file: "InterVariable.ttf", offset: 0)) == "notFound")
        #expect(refused(RemoteFontFileRequest(family: "Inter Variable", file: "InterVariable.ttf", offset: 0)) == "notFound")
        #expect(refused(RemoteFontFileRequest(family: "Nobody", file: name, offset: 0)) == "notFound")
    }

    @Test func fontMessagesSurviveTheWireFormat() throws {
        let ledger = FontLedger(chat: .init(id: "custom:My Serif", changedAt: at(1_700_000_000.25)),
                                interface: .init(id: "inter", changedAt: .distantPast),
                                removed: ["Old Family": at(12)])
        let settings = RemoteFontSettings(ledger: ledger, families: [
            RemoteFontFamily(name: "My Serif", addedAt: at(99), files: [RemoteFontFile(name: "MySerif-Regular.otf", size: 1_234)]),
        ])
        let chunk = RemoteFontChunk(family: "My Serif", file: "MySerif-Regular.otf", offset: 5, total: 9, data: Data([0, 255, 7, 8]))
        let fromPhone: [(RemoteClientMessage, String)] = [
            (.fontSync(settings), "fontSync"),
            (.fontFile(RemoteFontFileRequest(family: "My Serif", file: "MySerif-Regular.otf", offset: 5)), "fontFile"),
            (.fontUpload(chunk), "fontUpload"),
        ]
        for (message, type) in fromPhone {
            let data = try RemoteCoding.encode(RemoteClientFrame(message, id: "7"))
            #expect(String(decoding: data, as: UTF8.self).contains("\"type\":\"\(type)\""))
            #expect(try RemoteCoding.decode(RemoteClientFrame.self, from: data).message == message)
        }
        let fromMac: [(RemoteServerMessage, String)] = [(.fontSettings(settings), "fontSettings"), (.fontChunk(chunk), "fontChunk")]
        for (message, type) in fromMac {
            let data = try RemoteCoding.encode(RemoteServerFrame(message, replyTo: "7"))
            #expect(String(decoding: data, as: UTF8.self).contains("\"type\":\"\(type)\""))
            #expect(try RemoteCoding.decode(RemoteServerFrame.self, from: data).message == message)
        }
        // One piece as text inside a frame stays far below the 1 MB a phone may send in one message.
        let full = RemoteFontChunk(family: "My Serif", file: "MySerif-Regular.otf", offset: 0, total: FontSync.chunkSize,
                                   data: Data(repeating: 0xAB, count: FontSync.chunkSize))
        #expect(try RemoteCoding.encode(RemoteClientFrame(.fontUpload(full), id: "8")).count < 400 * 1024)
    }
}

#if os(macOS)
/// The real `RemoteServer` on 127.0.0.1 and the real `RemoteClient`: a font chosen or added on one device
/// reaches the other over the encrypted connection, with no call from the test in between.
@MainActor @Suite(.serialized) struct FontSyncLoopbackTests {
    @Test func choicesAndAddedFontsFollowOverTheRealConnection() async throws {
        let pair = FontPair()
        defer { pair.cleanUp() }
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Loopback Mac",
                                                heartbeatInterval: .seconds(15), helloTimeout: .seconds(30))
        let server = RemoteServer(host: FontTestMac(store: pair.mac), token: token, configuration: config)
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)

        let client = RemoteClient(pairing: RemotePairing(hosts: ["127.0.0.1"], port: Int(port), token: token, macName: "Loopback Mac"),
                                  deviceName: "Test Phone", deviceID: "test-\(UUID().uuidString)")
        client.handshakeTimeout = .seconds(30)
        client.requestTimeout = .seconds(60)
        let sync = FontSyncClient(store: pair.phone, transport: client)
        let following = sync.follow(client)
        defer { following.cancel() }

        // Chosen on the iPhone before it ever connected: it reaches the Mac when the connection comes up.
        pair.phone.select(.sanFrancisco, for: .interface)
        client.start()
        defer { client.stop() }
        try await waitUntil("the iPhone's interface font on the Mac") { pair.mac.interface == .sanFrancisco }

        // Chosen on the Mac: the Mac says so unasked and the iPhone follows.
        pair.mac.select(.sourceSerif4, for: .chat)
        try await waitUntil("the Mac's chat font on the iPhone") { pair.phone.chat == .sourceSerif4 }
        #expect(client.fontSettingsPushes >= 1)

        // Chosen on the iPhone while connected.
        pair.phone.select(.newYork, for: .chat)
        try await waitUntil("the iPhone's chat font on the Mac") { pair.mac.chat == .newYork }

        // A font added and chosen on the Mac arrives on the iPhone, file for file.
        let family = TestFont.uniqueFamily()
        #expect(pair.mac.add([try TestFont.write(family: family, to: pair.downloads),
                              try TestFont.write(family: family, italic: true, to: pair.downloads)]).isEmpty)
        let added = try #require(pair.mac.choices.last)
        pair.mac.select(added, for: .chat)
        try await waitUntil("the added font on the iPhone") { pair.phone.chat == added }
        #expect(pair.files(in: pair.phoneFolder) == pair.files(in: pair.macFolder))
        for name in pair.files(in: pair.macFolder) {
            #expect(try Data(contentsOf: pair.macFolder.appendingPathComponent(name))
                == Data(contentsOf: pair.phoneFolder.appendingPathComponent(name)))
        }

        // A font added on the iPhone arrives on the Mac.
        let other = TestFont.uniqueFamily()
        #expect(pair.phone.add([try TestFont.write(family: other, to: pair.downloads, name: "Other.ttf")]).isEmpty)
        try await waitUntil("the iPhone's added font on the Mac") { pair.mac.customFamilies.contains { $0.name == other } }

        // Removed on the Mac: gone on the iPhone, and both chat fonts are back on the default.
        pair.mac.remove(added)
        try await waitUntil("the removal on the iPhone") { !pair.phone.customFamilies.contains { $0.name == family } }
        #expect(pair.phone.chat == .standard && pair.mac.chat == .standard)
        #expect(pair.phone.customFamilies.map(\.name) == [other])
        #expect(sync.lastProblem == nil)
    }
}
#endif
