import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the "Import Claude sessions" sheet and its first-launch card with sample data (made-up folders under the
/// home folder, nothing read from disk) to PNG files (2x), dark and light. Call from the `--render-snapshots` flow:
/// `ImportSnapshots.render(to: outputDirectory, zoom: zoom)`.
@MainActor
enum ImportSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(directory.path): \(error.localizedDescription)")
            return []
        }
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"

        func save<V: View>(_ name: String, width: CGFloat, scheme: ColorScheme, @ViewBuilder _ view: () -> V) {
            let content = ImportSnapshotCanvas(width: width * zoom) { view() }
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width * zoom, height: nil)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            let url = directory.appendingPathComponent(name + suffix + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(url.path) }
        }

        let scan = sampleScan()
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"

            let ready = ClaudeImportModel(engine: nil, permissionMode: .auto, scan: scan)
            save("import-sheet-\(tone)", width: 640, scheme: scheme) { ClaudeImportSheet(model: ready) }

            let trusting = ClaudeImportModel(engine: nil, permissionMode: .auto, scan: scan)
            trusting.trustFolders = true
            trusting.toggle(scan.folders[2])
            save("import-sheet-trust-\(tone)", width: 640, scheme: scheme) { ClaudeImportSheet(model: trusting) }

            let keepVisible = ClaudeImportModel(engine: nil, permissionMode: .auto, scan: scan)
            keepVisible.archiveOutsideDesktopApp = false
            save("import-sheet-archive-off-\(tone)", width: 640, scheme: scheme) { ClaudeImportSheet(model: keepVisible) }

            let scanning = ClaudeImportModel(engine: nil, permissionMode: .auto)
            save("import-sheet-scanning-\(tone)", width: 640, scheme: scheme) { ClaudeImportSheet(model: scanning) }

            let done = ClaudeImportModel(engine: nil, permissionMode: .auto, scan: scan)
            done.showResult(ClaudeImportResult(imported: 38, alreadyThere: 5, folders: 5, trusted: [scan.folders[0].path],
                                               notTrusted: [NSHomeDirectory(): WorkspaceTrustError.tooBroad(NSHomeDirectory()).errorDescription ?? ""]),
                            archivedOutside: 14, pinned: 1)
            save("import-sheet-done-\(tone)", width: 640, scheme: scheme) { ClaudeImportSheet(model: done) }

            save("import-offer-card-\(tone)", width: 380, scheme: scheme) {
                ClaudeImportOfferCard(scan: scan, review: {}, dismiss: {})
                    .padding(24)
            }
        }
        if let path = liveCheck(scan: scan, directory: directory, suffix: suffix, zoom: zoom) { written.append(path) }
        print("Rendered \(written.count) import snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Live check

    /// The sheet in a real window that is never shown (real scroll views, as presented): its natural height must stay
    /// within the screen, so the buttons are always reachable at any zoom.
    private static func liveCheck(scan: ClaudeImportScan, directory: URL, suffix: String, zoom: CGFloat) -> String? {
        let model = ClaudeImportModel(engine: nil, permissionMode: .auto, scan: scan)
        let root = ClaudeImportSheet(model: model)
            .ensembleTheme()
            .environment(\.colorScheme, .dark)
            .environment(\.zoom, zoom)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640 * zoom, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        print("Import sheet live check: \(Int(size.width)) x \(Int(size.height)) pt, screen \(Int(screen)) pt, fits \(size.height <= screen)")
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = directory.appendingPathComponent("import-sheet-live" + suffix + ".png")
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return url.path
    }

    // MARK: Sample data

    static func sampleScan(now: Date = Date()) -> ClaudeImportScan {
        let home = NSHomeDirectory()
        func days(_ value: Double) -> Date { now.addingTimeInterval(-value * 86_400) }
        var counter = 0
        func sessions(_ folder: String, count: Int, from: Double, to: Double, imported: Int = 0, archived: Int = 0,
                      recent: Bool = false, outside: Int = 0, starred: Int = 0) -> [ClaudeImportSession] {
            (0..<count).map { index in
                counter += 1
                let step = count > 1 ? (from - to) / Double(count - 1) : 0
                let updated = days(to + step * Double(index))
                return ClaudeImportSession(
                    id: String(format: "00000000-0000-4000-8000-%012d", counter), directory: folder,
                    title: "Sample session \(counter)", titleSource: .desktopApp, created: updated.addingTimeInterval(-3600),
                    updated: updated, archived: index < archived, starred: index >= count - starred,
                    model: ModelRef(providerID: "claude-code", id: "opus", variant: "high"),
                    transcriptPath: "/dev/null", alreadyImported: index >= count - imported,
                    recentlyWritten: recent && index == 0, inDesktopApp: index >= outside)
            }
        }
        let weather = home + "/Developer/weather-app"
        let notes = home + "/Developer/notes-sync"
        let site = home + "/Developer/portfolio-site"
        let design = home + "/Documents/Design system tokens"
        let api = home + "/Developer/recipes-api"
        let gone = home + "/Developer/old-prototype"
        let scratch = home + "/Developer/scratch"
        let folders = [
            ClaudeImportFolder(path: weather, exists: true, trustedInCLI: true,
                               sessions: sessions(weather, count: 14, from: 46, to: 0, archived: 4, recent: true, outside: 6, starred: 1)),
            ClaudeImportFolder(path: notes, exists: true, trustedInCLI: true, sessions: sessions(notes, count: 9, from: 30, to: 2, archived: 4)),
            ClaudeImportFolder(path: site, exists: true, trustedInCLI: true, sessions: sessions(site, count: 6, from: 61, to: 5, imported: 2)),
            ClaudeImportFolder(path: design, exists: true, sessions: sessions(design, count: 3, from: 20, to: 12, outside: 3)),
            ClaudeImportFolder(path: api, exists: true, trustedInCLI: true, sessions: sessions(api, count: 8, from: 90, to: 33, archived: 5, outside: 8)),
            ClaudeImportFolder(path: scratch, exists: true, sessions: sessions(scratch, count: 4, from: 15, to: 14, imported: 4)),
            ClaudeImportFolder(path: gone, exists: false, trustedInCLI: true, sessions: sessions(gone, count: 2, from: 400, to: 380)),
        ]
        var skipped = ClaudeImportScan.Skipped()
        skipped.deletedInDesktopApp = 3
        skipped.replacedByNewerConversation = 1
        return ClaudeImportScan(
            folders: folders,
            environments: [
                ClaudeImportEnvironment(id: "e1", name: "Weather", kind: .local, folder: weather),
                ClaudeImportEnvironment(id: "e2", name: "Client work", kind: .local, folder: home + "/Developer/client-portal"),
                ClaudeImportEnvironment(id: "e3", name: "Build box", kind: .ssh, host: "dev@build.example.test"),
                ClaudeImportEnvironment(id: "e4", name: "Web sandbox", kind: .cloud),
            ],
            cliTrustedFolders: [weather, notes, site, api], desktopAppFound: true, skipped: skipped)
    }
}

/// Fixed-width background for an import snapshot; the height follows the content.
private struct ImportSnapshotCanvas<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(theme.background)
    }
}
