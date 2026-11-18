import Foundation
import Synchronization

/// Where scheduled tasks and their history are kept.
public protocol ScheduleStorage: Sendable {
    /// Nil when nothing was saved yet.
    func load() throws -> ScheduleFileContents?
    func save(_ contents: ScheduleFileContents) throws
}

/// `~/Library/Application Support/Ensemble/schedules.json`, readable only by the user (prompts can be private).
public struct ScheduleFileStorage: ScheduleStorage {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: ScheduleFileStorage {
        ScheduleFileStorage(url: EnsembleSupportFolder.url.appendingPathComponent("schedules.json"))
    }

    /// A file that cannot be read is moved aside (`schedules.unreadable-<time>.json`) before the error is thrown, so the
    /// next save never overwrites it.
    public func load() throws -> ScheduleFileContents? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try ScheduleCoding.decoder().decode(ScheduleFileContents.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            throw ScheduleStorageError.unreadable(keptAs: aside.lastPathComponent)
        }
    }

    public func save(_ contents: ScheduleFileContents) throws {
        try EnsembleSupportFolder.write(try ScheduleCoding.encoder().encode(contents), to: url)
    }
}

public enum ScheduleStorageError: Error, Equatable, LocalizedError {
    case unreadable(keptAs: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "The file could not be read. It was kept as \(name)."
        }
    }
}

/// Keeps the file in memory (previews, snapshots, tests).
public final class InMemoryScheduleStorage: ScheduleStorage {
    private let contents: Mutex<ScheduleFileContents?>

    public init(_ initial: ScheduleFileContents? = nil) {
        contents = Mutex(initial)
    }

    public func load() throws -> ScheduleFileContents? { contents.withLock { $0 } }

    public func save(_ new: ScheduleFileContents) throws { contents.withLock { $0 = new } }

    /// What was saved last.
    public var saved: ScheduleFileContents? { contents.withLock { $0 } }
}

/// JSON with ISO 8601 dates to the millisecond (whole seconds could round a check past a scheduled time).
enum ScheduleCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }
}

/// `~/Library/Application Support/Ensemble`.
public enum EnsembleSupportFolder {
    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble", isDirectory: true)
    }

    /// Writes atomically, with the folder and the file readable only by the user.
    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
