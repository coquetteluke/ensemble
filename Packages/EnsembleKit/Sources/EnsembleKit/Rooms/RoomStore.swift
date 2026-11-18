import Foundation
import Synchronization

/// Where rooms are saved. The engine saves after every change.
public protocol RoomStore: Sendable {
    func save(_ state: RoomState) throws
    func load(_ roomID: UUID) throws -> RoomState?
    /// Every saved room, oldest first.
    func list() throws -> [RoomState]
    func delete(_ roomID: UUID) throws
}

enum RoomCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// One JSON file per room: `<directory>/<roomID>.json`. The default directory is
/// `~/Library/Application Support/Ensemble/rooms`.
public struct FileRoomStore: RoomStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Ensemble/rooms` (inside the app container on iOS).
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble", isDirectory: true).appendingPathComponent("rooms", isDirectory: true)
    }

    public static var standard: FileRoomStore { FileRoomStore(directory: defaultDirectory) }

    public func fileURL(for roomID: UUID) -> URL {
        directory.appendingPathComponent("\(roomID.uuidString).json")
    }

    public func save(_ state: RoomState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try RoomCoding.encoder().encode(state)
        try data.write(to: fileURL(for: state.id), options: .atomic)
    }

    public func load(_ roomID: UUID) throws -> RoomState? {
        let url = fileURL(for: roomID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try RoomCoding.decoder().decode(RoomState.self, from: Data(contentsOf: url))
    }

    public func list() throws -> [RoomState] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = RoomCoding.decoder()
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(RoomState.self, from: data)
        }
        .sorted { $0.spec.created < $1.spec.created }
    }

    public func delete(_ roomID: UUID) throws {
        let url = fileURL(for: roomID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Keeps rooms in memory, encoded as JSON so saving and loading go through the same coding as files.
/// For tests and previews.
public final class InMemoryRoomStore: RoomStore {
    private let rooms = Mutex<[UUID: Data]>([:])
    private let saves = Mutex(0)

    public init() {}

    /// How many times `save` ran.
    public var saveCount: Int { saves.withLock { $0 } }

    public func save(_ state: RoomState) throws {
        let data = try RoomCoding.encoder().encode(state)
        rooms.withLock { $0[state.id] = data }
        saves.withLock { $0 += 1 }
    }

    public func load(_ roomID: UUID) throws -> RoomState? {
        guard let data = rooms.withLock({ $0[roomID] }) else { return nil }
        return try RoomCoding.decoder().decode(RoomState.self, from: data)
    }

    public func list() throws -> [RoomState] {
        let all = rooms.withLock { Array($0.values) }
        let decoder = RoomCoding.decoder()
        return try all.map { try decoder.decode(RoomState.self, from: $0) }.sorted { $0.spec.created < $1.spec.created }
    }

    public func delete(_ roomID: UUID) throws {
        _ = rooms.withLock { $0.removeValue(forKey: roomID) }
    }
}
