import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// The font chooser, dark and light: the Settings section for the chat font and for the interface font, a sheet
/// with the same reply set in every font that can be chosen, a transcript in the default chat font and two
/// others, and the whole window with another interface font.
/// Called from `SnapshotRenderer.run`, which has already swapped in a store that reads no saved choice.
///
/// With `ENSEMBLE_SNAPSHOT_FONTS=<folder>` in the environment, the files in that folder are also added through
/// the real "Add Font" path into a temporary library, and the Settings section and a transcript are drawn with
/// the added font chosen (`settings-chat-font-added-*`, `chat-font-transcript-added-*`). The temporary library
/// is deleted afterwards. Nothing in Application Support is read or written.
@MainActor
enum FontSnapshots {
    /// The same reply in every font: a heading, bold, italic, inline code, numbers and a list.
    static let sample = """
    ## Fixing the login redirect

    The loop came from `SessionGuard`, which sent signed-in users back to **/login** whenever the cookie was *older than the token*. I moved the check after the refresh, so a stale cookie is renewed first and 3 of the 4 failing tests pass.

    1. Refresh the token, then read the cookie.
    2. Redirect only when **both** are missing.
    """

    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let fonts = FontStore.shared.choices
        // What `--chat-font` and `--interface-font` asked for, put back after the snapshots that choose their own.
        let chosenChat = FontStore.shared.chat
        let chosenInterface = FontStore.shared.interface
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"

            let formHeight = CGFloat(290 + 63 * fonts.count)
            for role in FontRole.allCases {
                let form = Form { FontSettingsSection(role: role) }.formStyle(.grouped)
                if let path = capture(form, size: CGSize(width: 640, height: formHeight), zoom: zoom, scheme: scheme,
                                      to: directory.appendingPathComponent("settings-\(role.rawValue)-font-\(tone)\(suffix).png")) {
                    written.append(path)
                }
            }

            written += save("chat-font-samples-\(tone)\(suffix)", width: 1240, zoom: zoom, scheme: scheme, to: directory) {
                SampleSheet(fonts: fonts)
            }

            // The transcript itself, through the store the windows read.
            if let session = store.selected {
                for font in [AppFont.standard, .sourceSerif4, .charter] where fonts.contains(font) {
                    FontStore.shared.select(font)
                    written += save("chat-font-transcript-\(font.id)-\(tone)\(suffix)", width: 800, zoom: zoom, scheme: scheme, to: directory) {
                        TranscriptList(items: session.items, resolutions: session.resolutions, agents: store.agents)
                            .environment(\.sessionDirectory, session.directory)
                            .padding(28)
                    }
                }
                FontStore.shared.select(chosenChat)

                // The whole window with another interface font: sidebar, headers and buttons follow it.
                let window = WindowState()
                window.showSidebar = true
                window.showContextPanel = true
                FontStore.shared.select(.avenirNext, for: .interface)
                written += save("main-window-interface-avenir-next-\(tone)\(suffix)", width: 1440, zoom: 1, scheme: scheme, to: directory) {
                    MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
                        .frame(height: 900)
                        .environment(SnapshotRenderer.power)
                }
                FontStore.shared.select(chosenInterface, for: .interface)
            }
        }
        written += renderAddedFonts(to: directory, zoom: zoom, session: store.selected, agents: store.agents)
        return written
    }

    /// The Settings section and a transcript after adding the font files in `ENSEMBLE_SNAPSHOT_FONTS`.
    private static func renderAddedFonts(to directory: URL, zoom: CGFloat, session: SessionModel?, agents: [UUID: AgentSpec]) -> [String] {
        guard let path = ProcessInfo.processInfo.environment["ENSEMBLE_SNAPSHOT_FONTS"], !path.isEmpty else { return [] }
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-snapshot-fonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let added = FontStore(saved: nil, library: CustomFontLibrary(folder: folder))
        let problems = added.add(files)
        print("Added fonts: \(added.customFamilies.map(\.name)), refused: \(problems)")
        guard let font = added.choices.last, font.isCustom else { return [] }
        added.select(font)

        var written: [String] = []
        let shared = FontStore.shared
        FontStore.shared = added
        // Every font that can be chosen now, the added ones last: a way to look at a candidate before bundling it.
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("chat-font-samples-added-\(tone)\(suffix)", width: 1240, zoom: zoom, scheme: scheme, to: directory) {
                SampleSheet(fonts: added.choices)
            }
        }
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            let form = Form { FontSettingsSection(store: added, problems: problems) }.formStyle(.grouped)
            let height = CGFloat(290 + 63 * added.choices.count + 24 * problems.count)
            if let path = capture(form, size: CGSize(width: 640, height: height), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("settings-chat-font-added-\(tone)\(suffix).png")) {
                written.append(path)
            }
            if let session {
                written += save("chat-font-transcript-added-\(tone)\(suffix)", width: 800, zoom: zoom, scheme: scheme, to: directory) {
                    TranscriptList(items: session.items, resolutions: session.resolutions, agents: agents)
                        .environment(\.sessionDirectory, session.directory)
                        .padding(28)
                }
            }
        }
        FontStore.shared = shared
        added.remove(font)
        return written
    }

    /// Two columns of sample cells.
    private struct SampleSheet: View {
        let fonts: [AppFont]
        @Environment(\.theme) private var theme

        var body: some View {
            let rows = stride(from: 0, to: fonts.count, by: 2).map { Array(fonts[$0..<min($0 + 2, fonts.count)]) }
            VStack(alignment: .leading, spacing: theme.z(20)) {
                ForEach(rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: theme.z(20)) {
                        ForEach(row) { font in
                            SampleCell(font: font)
                        }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
            .padding(theme.z(24))
        }
    }

    /// One font: its name and where it comes from in the interface font, then the sample reply set in it.
    private struct SampleCell: View {
        let font: AppFont
        @Environment(\.theme) private var theme

        var body: some View {
            var themed = theme
            themed.chatFont = font
            return VStack(alignment: .leading, spacing: theme.z(10)) {
                HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                    Text(font.name)
                        .font(theme.font(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(font.detail)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                    if font == .standard {
                        Text("Default")
                            .font(theme.font(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                }
                MarkdownView(FontSnapshots.sample)
                    .environment(\.theme, themed)
            }
            .padding(theme.z(16))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.background))
            .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
        }
    }

    private struct ThemedBackground: View {
        @Environment(\.theme) private var theme
        var body: some View { theme.background }
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

    /// A grouped form needs a real window to draw, so it is captured from one that is never shown.
    private static func capture<V: View>(_ view: V, size: CGSize, zoom: CGFloat, scheme: ColorScheme, to url: URL) -> String? {
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let root = view
            .frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
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
