import Foundation

/// A picture or file attached to one of the user's messages.
///
/// Attachments travel beside the transcript, keyed by the id of the message row they belong to (a
/// `[String: [MessageAttachment]]`), so `TranscriptItem.user` keeps its shape and data written before attachments
/// existed still decodes. The bytes are never in here: a Mac reads the file at `path`, and a phone only gets the
/// name and kind (`forRemote`).
public struct MessageAttachment: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Shown as a thumbnail.
        case image
        /// Shown as a chip with its name.
        case file
    }

    public var id: String
    public var kind: Kind
    /// The file's name. Nil for a picture that never had one (pasted, or stored inside an engine's transcript).
    public var name: String?
    /// For example `image/png`.
    public var mediaType: String?
    /// Where this Mac can read the whole file: the file that was attached, or the copy Ensemble took out of the
    /// engine's transcript. Nil on the phone, and when the bytes are not on this Mac.
    public var path: String?

    public init(id: String = UUID().uuidString, kind: Kind, name: String? = nil, mediaType: String? = nil, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mediaType = mediaType
        self.path = path
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, mediaType, path }

    /// Missing keys fall back to defaults and a kind this build does not know becomes a plain file, so one new field
    /// or kind never costs the whole transcript.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .file
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        mediaType = try? c.decodeIfPresent(String.self, forKey: .mediaType)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
    }

    /// The copy a phone gets: no path on the Mac's disk.
    public var forRemote: MessageAttachment {
        var copy = self
        copy.path = nil
        return copy
    }

    /// What a chip says: the file's name, or "Picture" for a picture without one.
    public var label: String {
        if let name, !name.isEmpty { return name }
        return kind == .image ? "Picture" : "File"
    }

    public var fileURL: URL? { path.map { URL(fileURLWithPath: $0) } }
}

public enum MessageAttachments {
    /// File extensions shown as pictures, with their media types.
    public static let imageMediaTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff", "bmp": "image/bmp",
    ]

    /// How the picture cache names a picture that was pasted or dropped without a file (`MessagePictureCache`).
    public static let pastedPrefix = "pasted-"

    /// The file extension for a picture's media type ("image/png" gives "png").
    public static func fileExtension(forMediaType mediaType: String?) -> String {
        guard let mediaType = mediaType?.lowercased() else { return "png" }
        if mediaType == "image/jpeg" { return "jpg" }
        return imageMediaTypes.first { $0.value == mediaType && $0.key != "jpeg" && $0.key != "tif" }?.key ?? "png"
    }

    /// Attachments for files the user attached in the composer. Pictures are told by their extension.
    public static func forFiles(_ files: [URL]) -> [MessageAttachment] {
        files.filter(\.isFileURL).map { url in
            let mediaType = imageMediaTypes[url.pathExtension.lowercased()]
            // A picture pasted or dropped without a file was saved under a made-up name: it has no name to show.
            let name = displayName(url.lastPathComponent)
            return MessageAttachment(kind: mediaType == nil ? .file : .image, name: name, mediaType: mediaType, path: url.path)
        }
    }

    /// A few plain words for a message's attachments where they cannot be drawn (the phone's fallback text, exports):
    /// "Picture", "2 pictures", "notes.pdf", "2 pictures, notes.pdf".
    public static func summary(_ attachments: [MessageAttachment]) -> String {
        let pictures = attachments.filter { $0.kind == .image }.count
        var parts: [String] = []
        if pictures == 1 { parts.append("Picture") } else if pictures > 1 { parts.append("\(pictures) pictures") }
        parts += attachments.filter { $0.kind == .file }.map(\.label)
        return parts.joined(separator: ", ")
    }

    /// The files of a message's attachments that are still on this Mac, to send them again (Retry, Edit).
    public static func files(_ attachments: [MessageAttachment]) -> [URL] {
        attachments.compactMap(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The name to show for a file: nil for a picture saved under a made-up name (pasted or dropped without a file).
    public static func displayName(_ fileName: String?) -> String? {
        guard let fileName, !fileName.isEmpty, !fileName.hasPrefix(pastedPrefix) else { return nil }
        return fileName
    }

    /// The table a phone gets: no paths.
    public static func forRemote(_ attachments: [String: [MessageAttachment]]) -> [String: [MessageAttachment]] {
        attachments.mapValues { $0.map(\.forRemote) }
    }
}

/// A transcript with the attachments of its user messages, by row id.
public struct AttachedTranscript: Sendable, Equatable {
    public var items: [TranscriptItem]
    public var attachments: [String: [MessageAttachment]]

    public init(items: [TranscriptItem] = [], attachments: [String: [MessageAttachment]] = [:]) {
        self.items = items
        self.attachments = attachments
    }
}
