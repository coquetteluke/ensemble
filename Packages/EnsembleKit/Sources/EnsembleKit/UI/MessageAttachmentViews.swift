import SwiftUI
import ImageIO
import QuickLook

public extension EnvironmentValues {
    /// Pictures and files attached to the transcript's user messages, by message row id
    /// (`SessionModel.attachments`).
    @Entry var messageAttachments: [String: [MessageAttachment]] = [:]
}

/// Small versions of attached pictures, made with ImageIO straight from the file (the full picture is never
/// decoded) and kept in memory while the app runs.
public enum PictureThumbnails {
    private final class Box: @unchecked Sendable {
        let cache = NSCache<NSString, CGImage>()
        init() { cache.countLimit = 400 }
    }

    private static let box = Box()

    private static func key(_ path: String, _ maxPixel: Int) -> NSString { "\(maxPixel)|\(path)" as NSString }

    public static func cached(_ path: String, maxPixel: Int) -> CGImage? {
        box.cache.object(forKey: key(path, maxPixel))
    }

    /// Reads and scales the picture now, on the calling thread. Nil when the file is missing or not a picture.
    public static func load(_ path: String, maxPixel: Int) -> CGImage? {
        if let image = cached(path, maxPixel: maxPixel) { return image }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        box.cache.setObject(image, forKey: key(path, maxPixel))
        return image
    }

    /// The same, off the main thread.
    public static func loadInBackground(_ path: String, maxPixel: Int) async -> CGImage? {
        if let image = cached(path, maxPixel: maxPixel) { return image }
        return await Task.detached(priority: .userInitiated) { load(path, maxPixel: maxPixel) }.value
    }
}

/// The pictures and files of one message, above its text: pictures as thumbnails, other files as chips with
/// their names. On a Mac a click opens Quick Look on the file, with the message's other attachments beside it.
public struct MessageAttachmentStrip: View {
    let attachments: [MessageAttachment]
    @Environment(\.theme) private var theme
    @State private var preview: URL?

    public init(attachments: [MessageAttachment]) {
        self.attachments = attachments
    }

    public var body: some View {
        TrailingFlow(spacing: theme.z(6)) {
            ForEach(attachments) { attachment in
                item(attachment)
            }
        }
        .quickLookPreview($preview, in: attachments.compactMap(\.fileURL))
    }

    @ViewBuilder private func item(_ attachment: MessageAttachment) -> some View {
        let url = attachment.fileURL
        if attachment.kind == .image, let path = attachment.path {
            Button {
                preview = url
            } label: {
                PictureThumbnail(path: path, label: attachment.label)
            }
            .buttonStyle(.plain)
            .help("Open \(attachment.label) in Quick Look")
            .accessibilityLabel("\(attachment.label), open in Quick Look")
        } else if let url {
            Button {
                preview = url
            } label: {
                AttachmentChip(attachment: attachment)
            }
            .buttonStyle(.plain)
            .help("Open \(attachment.label) in Quick Look")
        } else {
            // No file on this device (the phone, or a picture this Mac cannot read).
            AttachmentChip(attachment: attachment)
        }
    }
}

/// One attached picture at thumbnail size. Shows a chip with its name when the file cannot be read.
public struct PictureThumbnail: View {
    let path: String
    let label: String
    /// Height in points before zoom; the width follows the picture's shape.
    var height: CGFloat = 96
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var loaded: CGImage?
    @State private var failed = false

    public init(path: String, label: String = "Picture", height: CGFloat = 96) {
        self.path = path
        self.label = label
        self.height = height
    }

    private var maxPixel: Int { Int(height * 2 * 3) }

    public var body: some View {
        // A snapshot is drawn once, so its pictures are read on the spot.
        let image = loaded ?? PictureThumbnails.cached(path, maxPixel: maxPixel)
            ?? (isSnapshot ? PictureThumbnails.load(path, maxPixel: maxPixel) : nil)
        Group {
            if let image {
                let shape = CGFloat(image.width) / CGFloat(max(image.height, 1))
                let side = theme.z(height)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: min(max(side * shape, side * 0.6), side * 2.4), height: side)
                    .clipShape(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous))
            } else if failed {
                AttachmentChip(attachment: MessageAttachment(kind: .image, name: label == "Picture" ? nil : label))
            } else {
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .fill(theme.userBubble)
                    .frame(width: theme.z(height), height: theme.z(height))
            }
        }
        .task(id: path) {
            guard loaded == nil, !isSnapshot else { return }
            if let image = await PictureThumbnails.loadInBackground(path, maxPixel: maxPixel) {
                loaded = image
            } else {
                failed = true
            }
        }
    }
}

/// A file (or a picture that cannot be drawn here) as an icon and a name.
public struct AttachmentChip: View {
    let attachment: MessageAttachment
    @Environment(\.theme) private var theme

    public init(attachment: MessageAttachment) {
        self.attachment = attachment
    }

    public var body: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: attachment.kind == .image ? "photo" : "doc")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textSecondary)
            Text(attachment.label)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(28))
        .frame(maxWidth: theme.z(260), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                .fill(theme.userBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachment.kind == .image ? "Picture \(attachment.name ?? "")" : "File \(attachment.label)")
    }
}

/// Lays its children out in rows that fill from the right edge, like the message bubble they sit above.
struct TrailingFlow: Layout {
    var spacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            if used + needed > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((index, size))
        }
        return rows.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map { $0.reduce(CGFloat(0)) { $0 + $1.size.width } + spacing * CGFloat($0.count - 1) }.max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowHeight = row.map(\.size.height).max() ?? 0
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.size.width } + spacing * CGFloat(row.count - 1)
            var x = bounds.maxX - rowWidth
            for entry in row {
                subviews[entry.index].place(at: CGPoint(x: x, y: y + (rowHeight - entry.size.height) / 2), anchor: .topLeading,
                                            proposal: ProposedViewSize(entry.size))
                x += entry.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
