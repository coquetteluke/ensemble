import Foundation
import Synchronization

/// One piece of a photo or file uploaded from a phone or iPad to the Mac before sending a message.
public struct RemoteAttachmentChunk: Codable, Hashable, Sendable {
    public var uploadID: String
    public var name: String
    public var kind: MessageAttachment.Kind
    public var offset: Int
    public var totalBytes: Int
    public var data: Data

    public init(uploadID: String, name: String, kind: MessageAttachment.Kind, offset: Int, totalBytes: Int, data: Data) {
        self.uploadID = uploadID
        self.name = name
        self.kind = kind
        self.offset = offset
        self.totalBytes = totalBytes
        self.data = data
    }
}


/// Request from a phone or iPad for a display-sized preview of an image attached to a session message.
public struct RemoteAttachmentPreviewRequest: Codable, Hashable, Sendable {
    public var sessionID: String
    public var attachmentID: String

    public init(sessionID: String, attachmentID: String) {
        self.sessionID = sessionID
        self.attachmentID = attachmentID
    }
}

/// Display-sized image bytes returned by the Mac for one attachment, cached on the phone/iPad after first fetch.
public struct RemoteAttachmentPreview: Codable, Hashable, Sendable {
    public var attachmentID: String
    public var mediaType: String
    public var data: Data

    public init(attachmentID: String, mediaType: String = "image/jpeg", data: Data) {
        self.attachmentID = attachmentID
        self.mediaType = mediaType
        self.data = data
    }
}

/// Limits and filename safety helpers shared by the phone uploader and the Mac receiver.
public enum RemoteAttachments {
    /// Raw bytes per WebSocket frame (base64 + JSON stays well under the 1 MiB frame limit).
    public static let chunkSize = 192 * 1024
    /// Largest single photo or file a phone or iPad may upload.
    public static let maxFileBytes = 15 * 1024 * 1024
    /// Most attachments allowed on one message.
    public static let maxAttachmentsPerMessage = 10
    /// Most staged uploads kept waiting before a message claims them.
    public static let maxPendingUploads = 24
    /// Cap on total pending staged bytes waiting across uploads.
    public static let maxStagedBytes = 60 * 1024 * 1024

    /// Allows only safe ASCII identifier characters so an upload id can never traverse directories.
    public static func isValidUploadID(_ id: String) -> Bool {
        guard id.count >= 8, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)   // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)  // A-Z
                || (scalar.value >= 97 && scalar.value <= 122) // a-z
                || scalar.value == 45 || scalar.value == 95    // - _
        }
    }

    /// Cleans a client-supplied filename down to a safe single path component.
    public static func sanitizeFilename(_ raw: String, kind: MessageAttachment.Kind) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let base = normalized.split(separator: "/").last.map(String.init) ?? ""
        let cleanedScalars = base.unicodeScalars.filter { scalar in
            scalar.value >= 32 && scalar.value != 127 && scalar != "/" && scalar != "\\" && scalar != ":"
        }
        var name = String(String.UnicodeScalarView(cleanedScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == "." || name == ".." {
            return kind == .image ? "photo.jpg" : "file"
        }
        if name.count > 120 {
            let ext = URL(fileURLWithPath: name).pathExtension
            if !ext.isEmpty && ext.count <= 12 {
                let stem = String(name.prefix(120 - ext.count - 1))
                name = "\(stem).\(ext)"
            } else {
                name = String(name.prefix(120))
            }
        }
        if kind == .image {
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            if MessageAttachments.imageMediaTypes[ext] == nil {
                name += ".jpg"
            }
        }
        return name
    }
}

/// Receives chunked photo and file uploads on the Mac, verifies bounds and ordering, and hands finished
/// file URLs to `sendMessage` when claimed.
public actor RemoteAttachmentInbox {
    public struct StagedFile: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let kind: MessageAttachment.Kind
    }

    private struct Entry {
        let url: URL
        let name: String
        let kind: MessageAttachment.Kind
        let totalBytes: Int
        var receivedBytes: Int
        let createdAt: Date
    }

    public let directory: URL
    public let maxAge: TimeInterval
    private var entries: [String: Entry] = [:]

    private static let prunedDirectories = Mutex<Set<String>>([])

    public init(directory: URL = RemoteAttachmentInbox.appDirectory, maxAge: TimeInterval = 60 * 60 * 24 * 45) {
        self.directory = directory
        self.maxAge = maxAge
    }

    /// `~/Library/Caches/Ensemble/remote-uploads`.
    public static var appDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Ensemble/remote-uploads", isDirectory: true)
    }

    public func receive(_ chunk: RemoteAttachmentChunk) throws {
        guard RemoteAttachments.isValidUploadID(chunk.uploadID) else {
            throw RemoteError(.badRequest, "Invalid attachment upload id.")
        }
        guard chunk.totalBytes > 0, chunk.totalBytes <= RemoteAttachments.maxFileBytes else {
            throw RemoteError(.badRequest, "Attachment exceeds the 15 MB limit.")
        }
        guard !chunk.data.isEmpty, chunk.data.count <= RemoteAttachments.chunkSize else {
            throw RemoteError(.badRequest, "Invalid attachment chunk size.")
        }
        guard chunk.offset >= 0, chunk.offset + chunk.data.count <= chunk.totalBytes else {
            throw RemoteError(.badRequest, "Attachment chunk is out of bounds.")
        }

        if chunk.offset == 0 {
            guard entries[chunk.uploadID] == nil else {
                throw RemoteError(.badRequest, "Duplicate attachment upload id.")
            }
            guard entries.count < RemoteAttachments.maxPendingUploads else {
                throw RemoteError(.badRequest, "Too many pending attachment uploads.")
            }
            let currentPendingBytes = entries.values.reduce(0) { $0 + $1.totalBytes }
            guard currentPendingBytes + chunk.totalBytes <= RemoteAttachments.maxStagedBytes else {
                throw RemoteError(.badRequest, "Pending attachment upload limit reached.")
            }

            let safeName = RemoteAttachments.sanitizeFilename(chunk.name, kind: chunk.kind)
            let folder = directory.appendingPathComponent(chunk.uploadID, isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            Self.pruneOnce(directory: directory, maxAge: maxAge)

            let fileURL = folder.appendingPathComponent(safeName, isDirectory: false)
            try chunk.data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            entries[chunk.uploadID] = Entry(
                url: fileURL,
                name: safeName,
                kind: chunk.kind,
                totalBytes: chunk.totalBytes,
                receivedBytes: chunk.data.count,
                createdAt: Date()
            )
            return
        }

        guard var entry = entries[chunk.uploadID] else {
            throw RemoteError(.badRequest, "Unknown attachment upload id.")
        }
        guard entry.totalBytes == chunk.totalBytes, entry.kind == chunk.kind else {
            throw RemoteError(.badRequest, "Attachment metadata changed mid-upload.")
        }
        guard chunk.offset == entry.receivedBytes else {
            throw RemoteError(.badRequest, "Attachment chunk arrived out of order.")
        }

        let handle = try FileHandle(forWritingTo: entry.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: chunk.data)
        entry.receivedBytes += chunk.data.count
        entries[chunk.uploadID] = entry
    }

    public func claim(_ uploadIDs: [String]) throws -> [StagedFile] {
        guard !uploadIDs.isEmpty else { return [] }
        guard uploadIDs.count <= RemoteAttachments.maxAttachmentsPerMessage else {
            throw RemoteError(.badRequest, "Too many attachments on one message.")
        }
        var seen = Set<String>()
        var files: [StagedFile] = []
        for id in uploadIDs {
            guard seen.insert(id).inserted else {
                throw RemoteError(.badRequest, "Duplicate attachment in message.")
            }
            guard let entry = entries[id] else {
                throw RemoteError(.badRequest, "Attachment upload was not found on this Mac.")
            }
            guard entry.receivedBytes == entry.totalBytes else {
                throw RemoteError(.badRequest, "Attachment upload is incomplete.")
            }
            files.append(StagedFile(url: entry.url, name: entry.name, kind: entry.kind))
        }
        for id in uploadIDs {
            entries.removeValue(forKey: id)
        }
        return files
    }

    private static func pruneOnce(directory: URL, maxAge: TimeInterval) {
        let shouldRun = prunedDirectories.withLock { seen in
            seen.insert(directory.path).inserted
        }
        guard shouldRun else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for child in children {
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < cutoff {
                try? fm.removeItem(at: child)
            }
        }
    }
}
