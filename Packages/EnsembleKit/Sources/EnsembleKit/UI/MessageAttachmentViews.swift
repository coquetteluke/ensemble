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

    private static func key(_ path: String, _ shortSide: Int) -> NSString { "\(shortSide)|\(path)" as NSString }

    public static func cached(_ path: String, shortSide: Int) -> CGImage? {
        box.cache.object(forKey: key(path, shortSide))
    }

    /// Reads and scales the picture now, on the calling thread, so its shorter side has about `shortSide` pixels (a
    /// wide screenshot stays sharp at thumbnail height). Never scaled up. Nil when the file is missing or not a picture.
    public static func load(_ path: String, shortSide: Int) -> CGImage? {
        if let image = cached(path, shortSide: shortSide) { return image }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var maxPixel = shortSide
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, min(width, height) > 0 {
            let scale = min(1, Double(shortSide) / min(width, height))
            // The longer side, capped so a very long strip cannot ask for a huge bitmap.
            maxPixel = min(Int((max(width, height) * scale).rounded(.up)), 4096)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        box.cache.setObject(image, forKey: key(path, shortSide))
        return image
    }

    /// The same, off the main thread.
    public static func loadInBackground(_ path: String, shortSide: Int) async -> CGImage? {
        if let image = cached(path, shortSide: shortSide) { return image }
        return await Task.detached(priority: .userInitiated) { load(path, shortSide: shortSide) }.value
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

    /// The thumbnail's frame for a picture of this shape. Most pictures are `height` tall and as wide as their shape
    /// asks. A wide strip (a cropped toolbar) is shown whole at 3.5 times the height wide and as short as that makes
    /// it, instead of being cut to its middle; a very tall or very thin picture is cut so it stays large enough to see
    /// and click.
    static func frame(pixelWidth: Int, pixelHeight: Int, height: CGFloat) -> CGSize {
        let shape = CGFloat(max(pixelWidth, 1)) / CGFloat(max(pixelHeight, 1))
        let widest = height * 3.5
        if height * shape > widest {
            return CGSize(width: widest, height: max(widest / shape, height * 0.3))
        }
        return CGSize(width: max(height * shape, height * 0.6), height: height)
    }

    public var body: some View {
        // Two pixels per point at the zoomed height.
        let shortSide = Int((theme.z(height) * 2).rounded(.up))
        // A snapshot is drawn once, so its pictures are read on the spot.
        let image = loaded ?? PictureThumbnails.cached(path, shortSide: shortSide)
            ?? (isSnapshot ? PictureThumbnails.load(path, shortSide: shortSide) : nil)
        Group {
            if let image {
                let size = Self.frame(pixelWidth: image.width, pixelHeight: image.height, height: theme.z(height))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous))
            } else if failed || isSnapshot || !FileManager.default.fileExists(atPath: path) {
                // The file is gone or is not a picture: its name, so the message still says something was attached.
                AttachmentChip(attachment: MessageAttachment(kind: .image, name: label == "Picture" ? nil : label))
            } else {
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .fill(theme.userBubble)
                    .frame(width: theme.z(height), height: theme.z(height))
            }
        }
        .task(id: "\(shortSide)|\(path)") {
            guard !isSnapshot else { return }
            if let image = await PictureThumbnails.loadInBackground(path, shortSide: shortSide) {
                loaded = image
                failed = false
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
