import SwiftUI
import EnsembleKit

/// The Files tab of the side panel: the open file on the left (`FileViewerPane`), and the session folder's tree with
/// a search field on the right. Click a file to open it; file paths in the conversation open here too. A panel too
/// narrow for both shows one at a time, with a button to switch.
struct FilesPane: View {
    /// The file shown, or nil when none is open yet.
    let link: FileLink?
    /// The session's (or room's) folder: the tree's root.
    let base: String
    let onOpen: (String) -> Void
    let onClose: () -> Void
    /// Snapshots pass the file's content, since they cannot wait for the load.
    var snapshotContent: FileViewerContent?
    @Environment(\.theme) private var theme
    @State private var showsTreeWhenNarrow = false

    static let treeWidth: CGFloat = 232
    static let width: CGFloat = FileViewerPane.width + treeWidth
    /// Below this the viewer and the tree take turns.
    static let bothFromWidth: CGFloat = 600

    var body: some View {
        GeometryReader { proxy in
            let both = proxy.size.width >= theme.z(Self.bothFromWidth)
            let showsTree = both || link == nil || showsTreeWhenNarrow
            let showsViewer = both || !showsTree
            HStack(spacing: 0) {
                if showsViewer {
                    viewer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottomTrailing) {
                            if !both { switchButton("list.bullet.indent", help: "Show the folder's files") { showsTreeWhenNarrow = true } }
                        }
                }
                if showsTree {
                    if showsViewer { VLine() }
                    FileTreeColumn(root: base, selectedPath: link?.path, onOpen: { path in
                        showsTreeWhenNarrow = false
                        onOpen(path)
                    }, onClose: both ? nil : onClose)
                        .frame(width: showsViewer ? theme.z(Self.treeWidth) : nil)
                        .frame(maxWidth: showsViewer ? nil : .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottomTrailing) {
                            if !both, link != nil { switchButton("doc.text", help: "Back to the open file") { showsTreeWhenNarrow = false } }
                        }
                }
            }
        }
        .background(theme.panel)
    }

    @ViewBuilder private var viewer: some View {
        if let link {
            FileViewerPane(link: link, base: base, onClose: onClose, content: snapshotContent)
                .id(link.path)
        } else {
            VStack(spacing: theme.z(8)) {
                Color.clear.frame(height: 52)
                Spacer()
                Image(systemName: "doc.text")
                    .font(theme.font(size: 26, weight: .light))
                    .foregroundStyle(theme.textTertiary)
                Text("No file open")
                    .font(theme.font(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text("Pick a file in the list, or click a file path in the conversation.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: theme.z(260))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func switchButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .frame(width: theme.z(30), height: theme.z(30))
                .background(Circle().fill(theme.elevated))
                .overlay(Circle().strokeBorder(theme.border))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .padding(theme.z(12))
    }
}

/// The folder's tree: a search field, then folders that open in place and files that open in the viewer. Typing in
/// the field lists matching files from the whole folder instead.
struct FileTreeColumn: View {
    let root: String
    let selectedPath: String?
    let onOpen: (String) -> Void
    /// Set when the column is the whole pane (no viewer beside it), so it carries the pane's close button.
    var onClose: (() -> Void)?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var children: [String: [FileTreeEntry]] = [:]
    @State private var results: [FileTreeEntry]?

    var body: some View {
        VStack(spacing: 0) {
            // The window's toolbar buttons and the tab strip sit in this band.
            Color.clear.frame(height: 52)
            HStack(spacing: theme.z(7)) {
                Image(systemName: "magnifyingglass")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                if isSnapshot {
                    Text("Search files")
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $query, prompt: Text("Search files").foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .autocorrectionDisabled()
                }
                if let onClose {
                    IconButton("xmark", help: "Close", size: 22, action: onClose)
                }
            }
            .font(theme.font(size: 12.5))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(28))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
            .padding(.horizontal, theme.z(10))
            .padding(.bottom, theme.z(8))
            HLine()
            list
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
        .task(id: root) {
            guard !isSnapshot else { return }
            expanded = []
            children = [root: FileTree.list(root)]
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !isSnapshot, !text.isEmpty else {
                results = nil
                return
            }
            // A short pause, so a fast typist starts one search and not one per letter.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let folder = root
            let found = await Task.detached(priority: .userInitiated) {
                FileTree.search(root: folder, query: text, isCancelled: { Task.isCancelled })
            }.value
            if !Task.isCancelled { results = found }
        }
    }

    private var topLevel: [FileTreeEntry] {
        isSnapshot ? Self.sampleEntries(root: root) : (children[root] ?? [])
    }

    @ViewBuilder private var list: some View {
        if let results {
            if results.isEmpty {
                note("No files match")
            } else {
                rows { ForEach(results) { entry in row(entry, depth: 0, detail: FileTree.folder(of: entry.path, under: root)) } }
            }
        } else if topLevel.isEmpty {
            note(children[root] == nil && !isSnapshot ? "Loading" : "This folder is empty")
        } else {
            rows { tree(topLevel, depth: 0) }
        }
    }

    @ViewBuilder private func rows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, theme.z(6))
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.vertical, theme.z(6))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12.5))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, theme.z(22))
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tree(_ entries: [FileTreeEntry], depth: Int) -> AnyView {
        AnyView(ForEach(entries) { entry in
            row(entry, depth: depth, detail: nil)
            if entry.isDirectory, expanded.contains(entry.path), let inside = children[entry.path] {
                if inside.isEmpty {
                    Text("Empty")
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, theme.z(CGFloat(depth + 1) * 14 + 34))
                        .frame(height: theme.z(22))
                } else {
                    tree(inside, depth: depth + 1)
                }
            }
        })
    }

    private func row(_ entry: FileTreeEntry, depth: Int, detail: String?) -> some View {
        FileTreeRow(entry: entry, depth: depth, detail: detail, isOpen: expanded.contains(entry.path),
                    isSelected: entry.path == selectedPath) {
            if entry.isDirectory {
                toggle(entry.path)
            } else {
                onOpen(entry.path)
            }
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            if children[path] == nil { children[path] = FileTree.list(path) }
            expanded.insert(path)
        }
    }

    /// Snapshots never read the disk: a small made-up project.
    static func sampleEntries(root: String) -> [FileTreeEntry] {
        let names: [(String, Bool)] = [("Apps", true), ("Packages", true), ("docs", true), ("scripts", true), ("CLAUDE.md", false),
                                       ("LICENSE", false), ("README.md", false), ("project.yml", false)]
        return names.map { FileTreeEntry(path: root + "/" + $0.0, name: $0.0, isDirectory: $0.1) }
    }
}

/// One row of the tree: indentation, a chevron for folders, the icon, the name, and for search results the folder.
private struct FileTreeRow: View {
    let entry: FileTreeEntry
    let depth: Int
    let detail: String?
    let isOpen: Bool
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(5)) {
                Image(systemName: entry.isDirectory ? (isOpen ? "chevron.down" : "chevron.right") : "circle")
                    .font(theme.font(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .opacity(entry.isDirectory ? 1 : 0)
                    .frame(width: theme.z(10))
                Image(systemName: symbol)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(entry.isDirectory ? theme.textSecondary : theme.textTertiary)
                    .frame(width: theme.z(16))
                Text(entry.name)
                    .font(theme.font(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, theme.z(CGFloat(depth) * 14 + 8))
            .padding(.trailing, theme.z(8))
            .frame(height: theme.z(24))
            .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                .fill(isSelected ? theme.selection : (hovering ? theme.hover : .clear)))
            .padding(.horizontal, theme.z(6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.path)
        .accessibilityLabel(entry.isDirectory ? "\(entry.name), folder" : entry.name)
    }

    private var symbol: String {
        if entry.isLink { return "arrow.up.right.square" }
        if entry.isDirectory { return isOpen ? "folder.fill" : "folder" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": return "photo"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "": return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
