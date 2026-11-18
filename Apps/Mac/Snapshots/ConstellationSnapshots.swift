import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Frames of the working spinner (the app icon's constellation): large at five moments of one round, then at its real
/// size next to the working text. Dark and light at the requested zoom. Called from `SnapshotRenderer.run`.
@MainActor
enum ConstellationSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let moments = stride(from: 0.0, to: ConstellationSpinner.period, by: ConstellationSpinner.period / 5).map { $0 }
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("constellation-frames-\(tone)\(suffix)", width: 560, zoom: zoom, scheme: scheme, to: directory) {
                Frames(moments: moments)
            }
        }
        return written
    }

    private struct Frames: View {
        let moments: [Double]
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: theme.z(18)) {
                HStack(spacing: theme.z(18)) {
                    ForEach(moments, id: \.self) { moment in
                        ConstellationSpinner(size: 64, frozenAt: moment)
                    }
                }
                HStack(spacing: theme.z(22)) {
                    ForEach(moments, id: \.self) { moment in
                        HStack(spacing: theme.z(8)) {
                            ConstellationSpinner(size: 16, frozenAt: moment)
                            Text("Thinking")
                                .font(theme.font(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(theme.z(20))
        }
    }

    private static func save<V: View>(_ name: String, width: CGFloat, zoom: CGFloat, scheme: ColorScheme, to directory: URL,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = view()
            .frame(width: w, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(ThemedBackground())
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }

    private struct ThemedBackground: View {
        @Environment(\.theme) private var theme
        var body: some View { theme.background }
    }
}
