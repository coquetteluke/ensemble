import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Renders the sidebar with linked sessions (sessions started from another session) nested three levels deep, one
/// branch folded so both chevrons show, in dark and light: `sidebar-linked-sessions-<tone>.png`. Uses its own sample
/// sessions and links in memory, never the user's.
@MainActor
enum LinkedSessionsSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(directory.path): \(error.localizedDescription)")
            return []
        }

        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let notes = "/Users/sample/Developer/notes-app"
        let site = "/Users/sample/Developer/website"
        func session(_ id: String, _ title: String, _ folder: String, minutes: Double) -> EngineSession {
            EngineSession(id: id, title: title, directory: folder, created: ago(minutes + 30), updated: ago(minutes))
        }
        let store = SessionStore(engine: PreviewEngine())
        store.seed(StoreSeed(
            sessions: [
                session("plan", "Plan offline sync", notes, minutes: 40),
                session("resolver", "Write the conflict resolver", notes, minutes: 12),
                session("merges", "Test merges when both devices edited the same note while offline", notes, minutes: 2),
                session("settings", "Sketch the sync settings screen", notes, minutes: 25),
                session("banner", "Copy for the sync error banner", notes, minutes: 20),
                session("share", "Fix the share sheet crash", notes, minutes: 90),
                session("pricing", "Update the pricing page", site, minutes: 300),
                session("small", "Check pricing on small screens", site, minutes: 280),
            ],
            activities: ["merges": .working],
            selectedSessionID: "resolver"))
        for (child, parent) in [("resolver", "plan"), ("merges", "resolver"), ("settings", "plan"), ("banner", "settings"),
                                ("small", "pricing")] {
            store.sessionLinks.record(child: child, parent: parent)
        }
        let window = WindowState()
        window.showSidebar = true
        window.collapsedProjects = ["links:settings"]
        let marks = SessionAttentionMarks(fileURL: nil)
        marks.replace(pinned: [:], unread: ["pricing"], completed: ["share": now])
        let center = AttentionCenter(marks: marks, canStart: false)

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            let width = MainView.sidebarWidth * zoom
            let height: CGFloat = 600 * zoom
            let content = SidebarView(store: store, window: window, groupingOverride: .project)
                .frame(width: width, height: height, alignment: .topLeading)
                .modifier(SidebarBackground())
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(center)
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
            guard let image = renderer.cgImage else {
                print("Failed to render sidebar-linked-sessions-\(tone)")
                continue
            }
            let url = directory.appendingPathComponent("sidebar-linked-sessions-\(tone)\(suffix).png")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { written.append(url.path) }
            }
        }
        print("Rendered \(written.count) linked session snapshots:")
        for path in written { print(path) }
        return written
    }
}

private struct SidebarBackground: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View { content.background(theme.sidebar) }
}
