import SwiftUI
import AppKit
import EnsembleKit

/// A code editor installed on this Mac that files can be opened in.
struct ExternalEditor: Identifiable, Hashable {
    enum LineSupport: Hashable {
        /// `scheme://file/<path>:<line>:<column>` (VS Code and editors built on it).
        case fileURLScheme(String)
        /// `zed://file/<path>:<line>:<column>`.
        case zed
        /// `xed --line <line> <path>`.
        case xed
    }

    let bundleID: String
    let name: String
    let appURL: URL
    let lines: LineSupport
    var id: String { bundleID }
}

@MainActor
enum ExternalEditors {
    /// Editors Ensemble knows how to open a file at a line in. Only installed ones are offered.
    static let known: [(bundleID: String, name: String, lines: ExternalEditor.LineSupport)] = [
        ("com.apple.dt.Xcode", "Xcode", .xed),
        ("com.microsoft.VSCode", "Visual Studio Code", .fileURLScheme("vscode")),
        ("com.todesktop.230313mzl4w4u92", "Cursor", .fileURLScheme("cursor")),
        ("dev.zed.Zed", "Zed", .zed),
        ("dev.zed.Zed-Preview", "Zed Preview", .zed),
        ("com.exafunction.windsurf", "Windsurf", .fileURLScheme("windsurf")),
    ]

    private static var cache: (editors: [ExternalEditor], checked: Date)?

    /// Installed editors, found with Launch Services (checked again after a minute, so a new install shows up).
    static var installed: [ExternalEditor] {
        if let cache, Date().timeIntervalSince(cache.checked) < 60 { return cache.editors }
        let editors = known.compactMap { entry -> ExternalEditor? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            return ExternalEditor(bundleID: entry.bundleID, name: entry.name, appURL: url, lines: entry.lines)
        }
        cache = (editors, Date())
        return editors
    }

    static func icon(for editor: ExternalEditor) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: editor.appURL.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Opens the file in the editor, at the line when there is one.
    static func open(_ link: FileLink, in editor: ExternalEditor) {
        let fileURL = URL(fileURLWithPath: link.path)
        if let line = link.line {
            switch editor.lines {
            case .fileURLScheme(let scheme):
                if let url = lineURL(scheme: scheme, link: link, line: line) {
                    NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration())
                    return
                }
            case .zed:
                if let url = lineURL(scheme: "zed", link: link, line: line) {
                    NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration())
                    return
                }
            case .xed:
                let xed = URL(fileURLWithPath: "/usr/bin/xed")
                if FileManager.default.isExecutableFile(atPath: xed.path) {
                    let process = Process()
                    process.executableURL = xed
                    process.arguments = ["--line", String(line), link.path]
                    if (try? process.run()) != nil { return }
                }
            }
        }
        NSWorkspace.shared.open([fileURL], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    static func lineURL(scheme: String, link: FileLink, line: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = link.path + ":\(line)" + (link.column.map { ":\($0)" } ?? "")
        return components.url
    }
}

/// The actions every file offers, in the viewer's header and in a file link's right-click menu.
@MainActor
enum FileActions {
    static func copyPath(_ link: FileLink) { copyToPasteboard(link.path) }

    static func reveal(_ link: FileLink) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: link.path)])
    }

    static func openWithDefaultApp(_ link: FileLink) {
        NSWorkspace.shared.open(URL(fileURLWithPath: link.path))
    }

    /// "Open in" entries: each installed editor, then the default app for the file type.
    static func openInItems(for link: FileLink) -> [FileLinkMenuItem] {
        ExternalEditors.installed.map { editor in
            FileLinkMenuItem(id: editor.bundleID, title: editor.name) { ExternalEditors.open(link, in: editor) }
        } + [FileLinkMenuItem(id: "default-app", title: "Default app") { openWithDefaultApp(link) }]
    }

    /// The right-click menu of a file link.
    static func menu(for link: FileLink, openInViewer: @escaping @MainActor @Sendable (FileLink) -> Void) -> [FileLinkMenuItem] {
        [
            FileLinkMenuItem(id: "viewer", title: "Open in file viewer", symbol: "doc.text.magnifyingglass") { openInViewer(link) },
            FileLinkMenuItem(id: "open-in", title: "Open in", symbol: "arrow.up.forward.app", children: openInItems(for: link)),
            FileLinkMenuItem(id: "copy", title: "Copy path", symbol: "doc.on.doc") { copyPath(link) },
            FileLinkMenuItem(id: "reveal", title: "Reveal in Finder", symbol: "folder") { reveal(link) },
        ]
    }
}
