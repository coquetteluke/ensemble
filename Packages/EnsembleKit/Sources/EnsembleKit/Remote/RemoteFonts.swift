import Foundation
import Observation

// Font syncing between the Mac and the iPhone.
//
// The iPhone starts every round: it sends what it has (`RemoteFontSettings`), the Mac takes over whatever is
// newer and answers with its own state, and the iPhone then fetches the font files it lacks and uploads the
// ones the Mac lacks, in pieces. When something changes on the Mac, the Mac sends its state unasked and the
// iPhone starts a round. The newer choice wins on both devices (`FontLedger`).
//
// Added font files travel only between the owner's own paired devices, inside the encrypted channel. Each side
// checks a received file exactly like one picked in "Add Font" (`CustomFontLibrary.add`).

/// One added font file, as the other device lists it.
public struct RemoteFontFile: Codable, Hashable, Sendable {
    public var name: String
    public var size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// One added family and its files.
public struct RemoteFontFamily: Codable, Hashable, Sendable {
    public var name: String
    public var addedAt: Date
    public var files: [RemoteFontFile]

    public init(name: String, addedAt: Date, files: [RemoteFontFile]) {
        self.name = name
        self.addedAt = addedAt
        self.files = files
    }
}

/// A device's font choices and the fonts added to it.
public struct RemoteFontSettings: Codable, Hashable, Sendable {
    public var ledger: FontLedger
    public var families: [RemoteFontFamily]

    public init(ledger: FontLedger, families: [RemoteFontFamily]) {
        self.ledger = ledger
        self.families = families
    }
}

/// Asks for the piece of a font file that starts at `offset`.
public struct RemoteFontFileRequest: Codable, Hashable, Sendable {
    public var family: String
    public var file: String
    public var offset: Int

    public init(family: String, file: String, offset: Int) {
        self.family = family
        self.file = file
        self.offset = offset
    }
}

/// A piece of a font file. `total` is the size of the whole file.
public struct RemoteFontChunk: Codable, Hashable, Sendable {
    public var family: String
    public var file: String
    public var offset: Int
    public var total: Int
    public var data: Data

    public init(family: String, file: String, offset: Int, total: Int, data: Data) {
        self.family = family
        self.file = file
        self.offset = offset
        self.total = total
        self.data = data
    }
}

/// What the iPhone's side of the sync needs from the connection. `RemoteClient` is the real one.
@MainActor
public protocol FontSyncTransport: AnyObject {
    /// Sends this device's fonts; the Mac merges them and answers with its own.
    func syncFonts(_ mine: RemoteFontSettings) async throws -> RemoteFontSettings
    func fontChunk(_ request: RemoteFontFileRequest) async throws -> RemoteFontChunk
    func uploadFont(_ chunk: RemoteFontChunk) async throws
}

public enum FontSync {
    /// Bytes of a font file per message. As text inside a sealed frame this stays well under the 1 MB a phone
    /// may send in one message, directly or through the relay.
    public static let chunkSize = 192 * 1024

    /// What a store tells the other device: its ledger, and its added fonts that were not removed since.
    @MainActor
    public static func settings(of store: FontStore) -> RemoteFontSettings {
        let families = store.customFamilies
            .filter { !store.isRemoved($0.name, addedAt: $0.addedAt) }
            .map { family in
                RemoteFontFamily(name: family.name, addedAt: family.addedAt, files: family.files.map { file in
                    RemoteFontFile(name: file.lastPathComponent,
                                   size: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                })
            }
        return RemoteFontSettings(ledger: store.ledger, families: families)
    }

    /// Whether `name` may be a font file's name on the wire: a plain file name with a font ending.
    static func isFontFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.contains("/") && !name.hasPrefix(".")
            && CustomFontLibrary.fileExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A new empty folder for files on their way into the library.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ensemble-font-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Where a received file waits before the library checks it. The name is made safe and keeps only the ending.
    static func temporaryFile(named name: String, in folder: URL) -> URL {
        let base = CustomFontLibrary.safeFileName((name as NSString).deletingPathExtension)
        return folder.appendingPathComponent(base + "." + (name as NSString).pathExtension.lowercased())
    }
}

/// The Mac's side: merges what the iPhone sends, hands out pieces of font files, and takes uploaded ones.
@MainActor
public final class FontSyncHost {
    private let store: FontStore
    /// Uploads that are not complete yet, by family and file name.
    private var incoming: [String: Data] = [:]
    /// Most uploads that may be open at once; the oldest is dropped when another starts.
    private let maxIncoming = 4
    private var incomingOrder: [String] = []

    public init(store: FontStore = .shared) {
        self.store = store
    }

    /// Takes over what is newer on the iPhone and answers with the Mac's fonts.
    public func sync(_ phone: RemoteFontSettings) -> RemoteFontSettings {
        store.merge(phone.ledger)
        return FontSync.settings(of: store)
    }

    /// One piece of one of this Mac's added font files. Only files the library lists can be read.
    public func chunk(_ request: RemoteFontFileRequest) throws -> RemoteFontChunk {
        guard let family = store.customFamilies.first(where: { $0.name == request.family }),
              let file = family.files.first(where: { $0.lastPathComponent == request.file }),
              let total = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw RemoteError(.notFound, "That font is not on this Mac.")
        }
        guard request.offset >= 0, request.offset < total, let handle = try? FileHandle(forReadingFrom: file) else {
            throw RemoteError(.badRequest, "That part of the font file does not exist.")
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(request.offset))
        let data = (try? handle.read(upToCount: FontSync.chunkSize)) ?? Data()
        guard !data.isEmpty else { throw RemoteError(.failed, "The font file could not be read.") }
        return RemoteFontChunk(family: request.family, file: request.file, offset: request.offset, total: total, data: data)
    }

    /// Takes one piece of a font file from the iPhone. Pieces come in order from offset 0; the last one adds the
    /// file to the library, which checks it like a file picked in "Add Font".
    public func receive(_ chunk: RemoteFontChunk) throws {
        guard FontSync.isFontFileName(chunk.file), !chunk.family.isEmpty, chunk.family.count <= 200,
              chunk.total > 0, chunk.total <= CustomFontLibrary.maxFileSize,
              !chunk.data.isEmpty, chunk.data.count <= FontSync.chunkSize else {
            throw RemoteError(.badRequest, "That is not a font file this Mac can take.")
        }
        let key = chunk.family + "\u{0}" + chunk.file
        if chunk.offset == 0 {
            incoming[key] = Data()
            incomingOrder.removeAll { $0 == key }
            incomingOrder.append(key)
            while incomingOrder.count > maxIncoming {
                incoming[incomingOrder.removeFirst()] = nil
            }
        }
        guard var buffer = incoming[key], buffer.count == chunk.offset, buffer.count + chunk.data.count <= chunk.total else {
            forget(key)
            throw RemoteError(.badRequest, "The font file arrived out of order. Send it again from the start.")
        }
        buffer.append(chunk.data)
        guard buffer.count == chunk.total else {
            incoming[key] = buffer
            return
        }
        forget(key)
        let folder: URL
        do {
            folder = try FontSync.temporaryFolder()
        } catch {
            throw RemoteError(.failed, "The font file could not be saved on this Mac.")
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = FontSync.temporaryFile(named: chunk.file, in: folder)
        guard (try? buffer.write(to: file)) != nil else {
            throw RemoteError(.failed, "The font file could not be saved on this Mac.")
        }
        if let problem = store.receive([file]).first {
            throw RemoteError(.badRequest, problem)
        }
    }

    /// The Mac's fonts after every change, for the iPhones that sync fonts.
    public func updates() -> AsyncStream<RemoteFontSettings> {
        let store = self.store
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await _ in store.changes() {
                    continuation.yield(FontSync.settings(of: store))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func forget(_ key: String) {
        incoming[key] = nil
        incomingOrder.removeAll { $0 == key }
    }
}

/// The iPhone's side: runs sync rounds over a connection.
@MainActor
public final class FontSyncClient {
    private let store: FontStore
    private weak var transport: (any FontSyncTransport)?
    private var running = false
    private var again = false
    /// Files that were refused once (not a usable font on the other side). They are not sent or fetched again
    /// while the app runs, so a bad file cannot be copied on every round.
    private var refused: Set<String> = []

    /// Why the last round stopped early, in a line. Nil after a round that finished.
    public private(set) var lastProblem: String?
    /// Why the Mac last refused a font file from this iPhone, in a line.
    public private(set) var lastRefusal: String?

    public init(store: FontStore = .shared, transport: any FontSyncTransport) {
        self.store = store
        self.transport = transport
    }

    /// Runs a round. A call during a running round makes that round run once more when it ends.
    public func sync() async {
        guard !running else {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            do {
                try await round()
                lastProblem = nil
            } catch {
                // An older Mac answers that it does not know the message; the fonts stay as they are here.
                lastProblem = error.localizedDescription
                return
            }
        } while again
    }

    /// Keeps the fonts in step with the Mac for as long as the returned task runs: a round when the connection
    /// comes up, when a font is chosen, added or removed here, and when the Mac says its fonts changed.
    public func follow(_ client: RemoteClient) -> Task<Void, Never> {
        let store = self.store
        return Task { @MainActor [weak self, weak client] in
            let local = Task { @MainActor [weak self] in
                for await origin in store.changes() where origin == .here {
                    await self?.sync()
                }
            }
            defer { local.cancel() }
            // The connection state and push count that the last round answered; nil while disconnected.
            var handled: (connected: Bool, pushes: Int)?
            while !Task.isCancelled {
                guard let self, let client else { return }
                let now = (connected: client.state.isConnected, pushes: client.fontSettingsPushes)
                if now.connected, handled?.pushes != now.pushes {
                    handled = now
                    await self.sync()
                    // Look again before waiting: the Mac may have said more while the round ran.
                    continue
                }
                if !now.connected { handled = nil }
                // Wait until the connection or the Mac's fonts change. Nothing can change between the reads
                // above and this, because both run on the main actor without a pause.
                await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = client.state.isConnected
                        _ = client.fontSettingsPushes
                    } onChange: {
                        waiting.resume()
                    }
                }
            }
        }
    }

    private func round() async throws {
        guard let transport else { return }
        let theirs = try await transport.syncFonts(FontSync.settings(of: store))
        store.merge(theirs.ledger)

        // Fetch the files the Mac has and this iPhone lacks.
        var arrived: [URL] = []
        let folder = try FontSync.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for family in theirs.families where !store.isRemoved(family.name, addedAt: family.addedAt) {
            let mine = Set(store.customFamilies.first { $0.name == family.name }?.files.map(\.lastPathComponent) ?? [])
            for file in family.files where !mine.contains(file.name) && FontSync.isFontFileName(file.name)
                && file.size > 0 && file.size <= CustomFontLibrary.maxFileSize
                && !refused.contains(family.name + "/" + file.name) {
                let data = try await download(file, of: family.name, from: transport)
                let url = FontSync.temporaryFile(named: file.name, in: folder)
                try data.write(to: url)
                arrived.append(url)
                refused.insert(family.name + "/" + file.name)
            }
        }
        if !arrived.isEmpty { store.receive(arrived) }
        // What is in the library now was accepted; only what was not stays on the refused list.
        for family in store.customFamilies {
            for file in family.files { refused.remove(family.name + "/" + file.lastPathComponent) }
        }

        // Upload the files this iPhone has and the Mac lacks.
        for family in store.customFamilies where !store.isRemoved(family.name, addedAt: family.addedAt) {
            let theirFiles = Set(theirs.families.first { $0.name == family.name }?.files.map(\.name) ?? [])
            for file in family.files where !theirFiles.contains(file.lastPathComponent)
                && !refused.contains(family.name + "/" + file.lastPathComponent) {
                do {
                    try await upload(file, of: family.name, to: transport)
                } catch let error as RemoteError where error.code == .badRequest {
                    // The Mac checked the file and will not take it. The rest still goes.
                    refused.insert(family.name + "/" + file.lastPathComponent)
                    lastRefusal = error.localizedDescription
                }
            }
        }
    }

    private func download(_ file: RemoteFontFile, of family: String, from transport: any FontSyncTransport) async throws -> Data {
        var data = Data()
        while data.count < file.size {
            let chunk = try await transport.fontChunk(RemoteFontFileRequest(family: family, file: file.name, offset: data.count))
            guard chunk.offset == data.count, !chunk.data.isEmpty, chunk.total == file.size,
                  data.count + chunk.data.count <= file.size else {
                throw RemoteError(.failed, "The font file \(file.name) did not arrive whole.")
            }
            data.append(chunk.data)
        }
        return data
    }

    private func upload(_ file: URL, of family: String, to transport: any FontSyncTransport) async throws {
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count <= CustomFontLibrary.maxFileSize else { return }
        var offset = 0
        while offset < data.count {
            let piece = data.subdata(in: offset..<min(offset + FontSync.chunkSize, data.count))
            try await transport.uploadFont(RemoteFontChunk(family: family, file: file.lastPathComponent, offset: offset,
                                                           total: data.count, data: piece))
            offset += piece.count
        }
    }
}

extension RemoteClient: FontSyncTransport {}
