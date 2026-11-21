import Foundation
import CryptoKit

/// Pictures kept as files so the transcript can show them: copies taken out of an engine's stored transcript (where
/// a picture is base64 text inside a line that can be megabytes long), and pictures pasted or dropped into the
/// message box, which never had a file.
///
/// A copy is named by a hash of its bytes, so loading the same session again writes nothing. Files not used for
/// `maxAge` are removed the first time a cache is used in a run.
public struct MessagePictureCache: Sendable {
    public let directory: URL
    public var maxAge: TimeInterval = 60 * 60 * 24 * 45

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Caches/Ensemble/pictures`.
    public static var appDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Ensemble/pictures", isDirectory: true)
    }

    /// The file for a picture stored as base64 text, written if it is not there yet. Nil when the text is not base64
    /// or the file cannot be written.
    public func store(base64: String, mediaType: String?) -> URL? {
        let digest = SHA256.hash(data: Data(base64.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(name + "." + MessageAttachments.fileExtension(forMediaType: mediaType))
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            // Used again: keeps it past the next clean-up.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return write(data, to: url)
    }

    /// Saves picture bytes that have no file (a paste or a drop) under a new name.
    public func store(data: Data, fileExtension: String = "png") -> URL? {
        guard !data.isEmpty else { return nil }
        return write(data, to: directory.appendingPathComponent("\(MessageAttachments.pastedPrefix)\(UUID().uuidString.lowercased()).\(fileExtension)"))
    }

    private func write(_ data: Data, to url: URL) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.pruneOnce(self)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Removes files last used more than `maxAge` ago. Returns how many were removed.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    private static let pruned = PrunedDirectories()

    private static func pruneOnce(_ cache: MessagePictureCache) {
        if pruned.insert(cache.directory.path) { cache.prune() }
    }

    private final class PrunedDirectories: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func insert(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }
    }
}

/// Engines whose stored transcripts keep the pictures and files attached to the user's messages. The store checks
/// with `as?` and uses this instead of `transcript(_:)`, so the file is read once. A row with nothing attached has no
/// entry in the table.
///
/// Rows from this call carry only what the user typed: no "[image]" marker and no "Attached: name" line, because the
/// attachments say it.
public protocol EngineMessageAttachments: Sendable {
    func attachedTranscript(_ sessionID: String) async throws -> AttachedTranscript
}
