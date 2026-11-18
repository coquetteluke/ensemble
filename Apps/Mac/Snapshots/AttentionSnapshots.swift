import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the attention pieces with sample data to PNG files (2x): the sidebar with pinned, needs-you, running,
/// failed, unread and completed sessions in each grouping, the full window, the Alerts settings and the menu
/// bar icon. Call from the `--render-snapshots` flow: `AttentionSnapshots.render(to: outputDirectory, zoom: zoom)`.
/// Uses its own marks in memory, never the user's saved ones.
@MainActor
enum AttentionSnapshots {
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
        let marks = SessionAttentionMarks(fileURL: nil)
        marks.replace(pinned: ["ses_db_debate": Date()], unread: ["ses_readme"], completed: ["ses_astro": Date()])
        let center = AttentionCenter(marks: marks, canStart: false)
        var written: [String] = []

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat?, scheme: ColorScheme = .dark,
                           background: KeyPath<Theme, Color> = \.background, grows: Bool = true,
                           @ViewBuilder _ view: () -> V) {
            let width = grows ? baseWidth * zoom : baseWidth
            let height = grows ? baseHeight.map { $0 * zoom } : baseHeight
            let content = AttentionSnapshotCanvas(width: width, height: height, background: background) { view() }
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
            if let path = write(image, to: directory.appendingPathComponent(name + ".png")) { written.append(path) }
        }

        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            for grouping in SidebarGrouping.allCases {
                save("sidebar-attention-\(grouping.rawValue)-\(tone)\(suffix)", width: MainView.sidebarWidth, height: 860,
                     scheme: scheme, background: \.sidebar) {
                    SidebarView(store: store, window: window, groupingOverride: grouping)
                }
            }
            save("main-window-attention-\(tone)\(suffix)", width: 1440, height: 900, scheme: scheme, grows: false) {
                MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
            }
            save("menu-bar-icon-\(tone)\(suffix)", width: 320, height: 28, scheme: scheme, background: \.panel) {
                MenuBarIconSnapshot(center: center)
            }
        }

        // Grouped forms are drawn by AppKit, so the Alerts settings are captured from a real offscreen window.
        if let path = captureOffscreen(AttentionSettingsTab().frame(width: 560, height: 360),
                                       size: CGSize(width: 560, height: 360), zoom: zoom,
                                       to: directory.appendingPathComponent("settings-alerts\(suffix).png")) {
            written.append(path)
        }

        print("Rendered \(written.count) attention snapshots:")
        for path in written { print(path) }
        return written
    }

    private static func write(_ image: CGImage, to url: URL) -> String? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }

    /// Hosts `view` in a window that is never shown and draws it with `cacheDisplay`.
    private static func captureOffscreen<V: View>(_ view: V, size: CGSize, zoom: CGFloat, to url: URL) -> String? {
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let root = view
            .ensembleTheme()
            .environment(\.zoom, zoom)
            .environment(\.isSnapshot, true)
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: scaled)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let image = rep.cgImage else { return nil }
        return write(image, to: url)
    }
}

/// Fixed-size background for an attention snapshot.
private struct AttentionSnapshotCanvas<Content: View>: View {
    let width: CGFloat
    let height: CGFloat?
    let background: KeyPath<Theme, Color>
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .frame(width: width, height: height, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: height == nil)
            .background(theme[keyPath: background])
    }
}

/// The menu bar icon on a strip like the menu bar, idle and with agents running.
private struct MenuBarIconSnapshot: View {
    let center: AttentionCenter
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(18)) {
            Spacer()
            HStack(spacing: 3) { Image(systemName: "point.3.connected.trianglepath.dotted") }
            HStack(spacing: 3) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("3").monospacedDigit()
            }
            HStack(spacing: 3) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                Text("2").monospacedDigit()
            }
        }
        .font(theme.font(size: 13.5))
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, theme.z(12))
        .frame(maxHeight: .infinity)
    }
}
