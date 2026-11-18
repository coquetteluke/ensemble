import Foundation

/// A small file that exists while Ensemble has (or is about to have) lid lock on. It is written before
/// `pmset disablesleep 1` runs and removed after Ensemble turns it back off, so after a crash the next
/// launch knows the lid lock was Ensemble's and can turn it off.
public struct PowerMarker: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Ensemble/power-lid-lock.marker`.
    public static var standard: PowerMarker {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return PowerMarker(url: base.appendingPathComponent("Ensemble/power-lid-lock.marker"))
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func write(now: Date = Date()) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "Ensemble turned on pmset disablesleep at \(ISO8601DateFormatter().string(from: now)), pid \(ProcessInfo.processInfo.processIdentifier)\n"
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
