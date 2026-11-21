import EnsembleKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo or file waiting in the mobile composer to be uploaded and sent with the next message.
struct StagedRemoteAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: MessageAttachment.Kind
    let data: Data

    init(id: UUID = UUID(), name: String, kind: MessageAttachment.Kind, data: Data) {
        self.id = id
        self.name = name
        self.kind = kind
        self.data = data
    }

    var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

enum RemoteAttachmentError: LocalizedError {
    case empty
    case tooLarge(String)
    case unreadable(String)
    case tooMany

    var errorDescription: String? {
        switch self {
        case .empty: "That file is empty."
        case .tooLarge(let name): "\(name) is larger than the 15 MB limit."
        case .unreadable(let name): "Could not read \(name)."
        case .tooMany: "You can attach up to \(RemoteAttachments.maxAttachmentsPerMessage) items per message."
        }
    }
}

/// Normalizes picked photos and files into bounded `StagedRemoteAttachment` payloads ready for chunked upload.
enum RemoteAttachmentLoader {
    /// Max pixel edge when re-encoding large camera/library photos so uploads stay fast over relay and direct LAN.
    private static let maxPhotoDimension: CGFloat = 2048

    static func preparePhoto(data: Data, suggestedName: String? = nil) throws -> StagedRemoteAttachment {
        guard !data.isEmpty else { throw RemoteAttachmentError.empty }
        let baseName = suggestedName?.isEmpty == false ? suggestedName! : "photo.jpg"
        let ext = URL(fileURLWithPath: baseName).pathExtension.lowercased()

        // Keep modest PNG/GIF/WebP files as-is to preserve lossless screenshots or animation.
        if (ext == "png" || ext == "gif" || ext == "webp") && data.count <= 3 * 1024 * 1024 {
            return StagedRemoteAttachment(
                name: RemoteAttachments.sanitizeFilename(baseName, kind: .image),
                kind: .image,
                data: data
            )
        }

        if let image = UIImage(data: data) {
            return try prepareImage(image, suggestedName: baseName)
        }

        guard data.count <= RemoteAttachments.maxFileBytes else {
            throw RemoteAttachmentError.tooLarge(baseName)
        }
        return StagedRemoteAttachment(
            name: RemoteAttachments.sanitizeFilename(baseName, kind: .image),
            kind: .image,
            data: data
        )
    }

    static func prepareImage(_ image: UIImage, suggestedName: String = "photo.jpg") throws -> StagedRemoteAttachment {
        let resized = downscaled(image, maxEdge: maxPhotoDimension)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) ?? resized.pngData() else {
            throw RemoteAttachmentError.unreadable(suggestedName)
        }
        guard jpeg.count <= RemoteAttachments.maxFileBytes else {
            throw RemoteAttachmentError.tooLarge(suggestedName)
        }
        let stem = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
        let cleanStem = stem.isEmpty ? "photo" : stem
        let name = RemoteAttachments.sanitizeFilename("\(cleanStem).jpg", kind: .image)
        return StagedRemoteAttachment(name: name, kind: .image, data: jpeg)
    }

    static func prepareFile(url: URL) throws -> StagedRemoteAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            throw RemoteAttachmentError.unreadable(name)
        }
        if let fileSize = values?.fileSize, fileSize > RemoteAttachments.maxFileBytes {
            throw RemoteAttachmentError.tooLarge(name)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RemoteAttachmentError.unreadable(name)
        }
        guard !data.isEmpty else { throw RemoteAttachmentError.empty }
        guard data.count <= RemoteAttachments.maxFileBytes else {
            throw RemoteAttachmentError.tooLarge(name)
        }

        let ext = url.pathExtension.lowercased()
        let isImage = MessageAttachments.imageMediaTypes[ext] != nil
        if isImage {
            return try preparePhoto(data: data, suggestedName: name)
        }
        return StagedRemoteAttachment(
            name: RemoteAttachments.sanitizeFilename(name, kind: .file),
            kind: .file,
            data: data
        )
    }

    static func loadPhotosPickerItems(_ items: [PhotosPickerItem]) async -> (loaded: [StagedRemoteAttachment], firstError: String?) {
        var loaded: [StagedRemoteAttachment] = []
        var firstError: String?
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    if firstError == nil { firstError = "Could not load selected photo." }
                    continue
                }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let name = "photo-\(index + 1).\(ext)"
                loaded.append(try preparePhoto(data: data, suggestedName: name))
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (loaded, firstError)
    }

    private static func downscaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let ratio = maxEdge / longest
        let target = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Horizontal strip of pending photo thumbnails and file chips inside the mobile composer.
struct StagedAttachmentStrip: View {
    let attachments: [StagedRemoteAttachment]
    let disabled: Bool
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    if item.kind == .image, let image = UIImage(data: item.data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                                )
                            removeButton(for: item)
                                .offset(x: 4, y: -4)
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: item.kind == .image ? "photo" : "doc.fill")
                                .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                                    .foregroundStyle(RemoteTheme.primaryText)
                                    .lineLimit(1)
                                Text(item.byteCountText)
                                    .font(RemoteTheme.font(size: 10.5, relativeTo: .caption2).monospacedDigit())
                                    .foregroundStyle(RemoteTheme.secondaryText)
                            }
                            .frame(maxWidth: 140, alignment: .leading)
                            Button {
                                onRemove(item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(RemoteTheme.font(size: 14, relativeTo: .caption))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                                    .frame(minWidth: 24, minHeight: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                            .accessibilityLabel("Remove \(item.name)")
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .padding(.vertical, 6)
                        .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                        )
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func removeButton(for item: StagedRemoteAttachment) -> some View {
        Button {
            onRemove(item.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(RemoteTheme.primaryText, RemoteTheme.card)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Remove \(item.name)")
    }
}

/// Native camera capture sheet for attaching a photo directly in chat.
struct CameraPickerSheet: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPickerSheet
        init(parent: CameraPickerSheet) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPicked(image)
            }
            parent.dismiss()
        }
    }
}
