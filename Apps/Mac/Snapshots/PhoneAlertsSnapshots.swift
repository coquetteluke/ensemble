import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders Settings > Alerts with "Send alerts through ntfy" to PNG files (2x), dark and light: set up with a test sent,
/// and refusing a plain-http server. Uses sample settings in memory, never the keychain.
/// Call from the `--render-snapshots` flow: `PhoneAlertsSnapshots.render(to: outputDirectory, zoom: zoom)`.
@MainActor
enum PhoneAlertsSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        var written: [String] = []
        let size = CGSize(width: 600, height: 700)

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            let ready = NtfyAlertCenter(storage: .memory(.init(server: "https://ntfy.sh", topic: "ensemble-k7m2q9xw4tnc8vhe5rpd",
                                                               accessToken: "tk_sample")),
                                        defaults: nil, enabled: true, hideTitles: false)
            let form = Form {
                AttentionSettingsSection()
                NtfyAlertsSection(center: ready)
            }
            .formStyle(.grouped)
            if let path = capture(form, size: size, zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("settings-alerts-ntfy-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let off = NtfyAlertCenter(storage: .memory(), defaults: nil, enabled: false, hideTitles: false)
            let offForm = Form { NtfyAlertsSection(center: off) }.formStyle(.grouped)
            if let path = capture(offForm, size: CGSize(width: 600, height: 260), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("settings-alerts-ntfy-off-\(tone)\(suffix).png")) {
                written.append(path)
            }
        }

        // The refusal of plain http to an ordinary server, with the reason on screen.
        let refusing = NtfyAlertCenter(storage: .memory(), defaults: nil, enabled: true, hideTitles: true)
        let refused = Form { NtfyRefusalSnapshot(center: refusing) }.formStyle(.grouped)
        if let path = capture(refused, size: CGSize(width: 600, height: 560), zoom: zoom, scheme: .dark,
                              to: directory.appendingPathComponent("settings-alerts-ntfy-http-refused-dark\(suffix).png")) {
            written.append(path)
        }

        print("Rendered \(written.count) phone alert snapshots:")
        for path in written { print(path) }
        return written
    }

    /// Hosts `view` in a window that is never shown and draws it with `cacheDisplay` (grouped forms are drawn by AppKit).
    private static func capture<V: View>(_ view: V, size: CGSize, zoom: CGFloat, scheme: ColorScheme, to url: URL) -> String? {
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let root = view
            .frame(width: scaled.width, height: scaled.height)
            .ensembleTheme()
            .environment(\.zoom, zoom)
            .environment(\.isSnapshot, true)
            .preferredColorScheme(scheme)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: scaled)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let image = rep.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }
}

/// The ntfy section after Save with a plain-http server that is neither this Mac nor a Tailscale name.
private struct NtfyRefusalSnapshot: View {
    let center: NtfyAlertCenter

    var body: some View {
        NtfyAlertsSection(center: center, draft: .init(server: "http://ntfy.example.com", topic: "ensemble-k7m2q9xw4tnc8vhe5rpd",
                                                       accessToken: nil),
                          problem: NtfyAlerts.Failure.insecureServer.errorDescription)
    }
}
