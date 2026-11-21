import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the screens added from the comparison in `docs/PARITY.md` to PNG files (2x), dark and light, with
/// sample data. Call from the `--render-snapshots` flow: `ParitySnapshots.render(to: outputDirectory, zoom: zoom)`.
/// `--render-snapshots <dir> --only parity` renders these alone.
@MainActor
enum ParitySnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(directory.path): \(error.localizedDescription)")
            return []
        }

        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = true
        // Marks in memory, never the user's saved ones.
        let marks = SessionAttentionMarks(fileURL: nil)
        let center = AttentionCenter(marks: marks, canStart: false)
        var written: [String] = []

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme,
                           @ViewBuilder _ view: () -> V) {
            let width = baseWidth * zoom
            let height = baseHeight.map { $0 * zoom }
            let content = ParitySnapshotCanvas(width: width, height: height) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(center)
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = directory.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            if let main = store.selected {
                // The title row: the title you click to rename, the menu beside it drawn open, and the rename field.
                save("title-menu-\(tone)\(suffix)", width: 760, height: nil, scheme: scheme) {
                    TitleMenuSnapshot(store: store, session: main, window: window)
                }
            }
        }

        print("Rendered \(written.count) parity snapshots:")
        for path in written { print(path) }
        return written
    }
}

private struct ParitySnapshotCanvas<Content: View>: View {
    let width: CGFloat
    let height: CGFloat?
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .frame(width: width, height: height, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: height == nil)
            .background(theme.background)
    }
}

/// A popover's content on a card with the popover's border and shadow.
struct SnapshotPopoverCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).strokeBorder(theme.border))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.14), radius: theme.z(14), y: theme.z(6))
    }
}

/// The window's title row with the session menu open under the title, then the same row while renaming.
private struct TitleMenuSnapshot: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CenterHeader(store: store, window: window)
            SnapshotPopoverCard {
                SessionMenuList(sections: SessionMenu.sections(SessionMenuState(pinned: false, unread: false))) { _ in }
            }
            .padding(.leading, theme.z(120))
            .padding(.bottom, theme.z(22))
            HLine()
            HStack(spacing: theme.z(8)) {
                SessionTitleControl(store: store, session: session, window: window, snapshotRenaming: true)
                Text(Format.abbreviatedPath(session.directory))
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            .padding(.leading, theme.z(20))
            .frame(height: theme.z(52))
        }
    }
}
