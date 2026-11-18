import SwiftUI
import AppKit
import EnsembleKit

/// A file's text, split into syntax-coloured lines, ready to show.
struct FileViewerContent: Sendable {
    enum Kind: Sendable, Equatable {
        case text
        /// Not text (an image, a binary): offered to other apps instead.
        case binary
        case unreadable(String)
    }

    var kind: Kind
    var lines: [AttributedString] = []
    /// Lines in the file, including ones past the display limit.
    var totalLines = 0

    static let maxBytes = 4 * 1024 * 1024
    static let maxLines = 20_000

    var isTruncated: Bool { totalLines > lines.count }

    /// Reads and colours a file off the main thread.
    static func load(_ path: String, theme: Theme) async -> FileViewerContent {
        await Task.detached(priority: .userInitiated) { read(path, theme: theme) }.value
    }

    static func read(_ path: String, theme: Theme) -> FileViewerContent {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return FileViewerContent(kind: .unreadable("This file could not be opened."))
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        if data.prefix(8192).contains(0) { return FileViewerContent(kind: .binary) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return FileViewerContent(kind: .binary)
        }
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = rawLines.prefix(maxLines).joined(separator: "\n")
        let language = (path as NSString).pathExtension.lowercased()
        let highlighted = SyntaxHighlighter.highlight(shown, language: language.isEmpty ? nil : language, theme: theme)
        return FileViewerContent(kind: .text, lines: split(highlighted), totalLines: rawLines.count)
    }

    /// Text already in memory (snapshots), coloured the same way.
    static func make(_ text: String, language: String?, theme: Theme) -> FileViewerContent {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return FileViewerContent(kind: .text, lines: split(SyntaxHighlighter.highlight(text, language: language, theme: theme)), totalLines: lines.count)
    }

    /// The coloured text cut at line breaks, keeping each run's colour.
    static func split(_ text: AttributedString) -> [AttributedString] {
        var lines = [AttributedString()]
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let color = run.foregroundColor
            for (index, part) in piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { lines.append(AttributedString()) }
                guard !part.isEmpty else { continue }
                var segment = AttributedString(String(part).replacingOccurrences(of: "\t", with: "    "))
                segment.foregroundColor = color
                lines[lines.count - 1].append(segment)
            }
        }
        return lines
    }
}

/// The file viewer on the right of the window: line numbers, syntax colours, scrolled to the line an agent
/// mentioned, with Copy path, Reveal in Finder and Open in.
struct FileViewerPane: View {
    let link: FileLink
    /// The session's folder, for showing the path relative to it.
    let base: String
    let onClose: () -> Void
    /// Space left for the title bar (the panel toggle sits there).
    var topInset: CGFloat = 52
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var content: FileViewerContent?
    @State private var copied = false

    static let width: CGFloat = 520

    /// Snapshots pass the content in, since they cannot wait for the load.
    init(link: FileLink, base: String, onClose: @escaping () -> Void, topInset: CGFloat = 52, content: FileViewerContent? = nil) {
        self.link = link
        self.base = base
        self.onClose = onClose
        self.topInset = topInset
        self._content = State(initialValue: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            header
            HLine()
            bodyView
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
        .task(id: "\(link.path)|\(theme.isDark)") {
            guard !isSnapshot else { return }
            content = await FileViewerContent.load(link.path, theme: theme)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "doc.text")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textTertiary)
            VStack(alignment: .leading, spacing: theme.z(1)) {
                Text(link.fileName)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(folderText)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(link.path)
            Spacer(minLength: theme.z(6))
            IconButton(copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy path", size: 26) {
                FileActions.copyPath(link)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            IconButton("folder", help: "Reveal in Finder", size: 26) { FileActions.reveal(link) }
            OpenInMenu(link: link)
            IconButton("xmark", help: "Close the file viewer", size: 26, action: onClose)
        }
        .padding(.leading, theme.z(14))
        .padding(.trailing, theme.z(8))
        .frame(height: theme.z(46))
    }

    /// "Sources/App" relative to the session folder, or the abbreviated folder when outside it.
    private var folderText: String {
        let folder = (link.path as NSString).deletingLastPathComponent
        let relative = Format.relativePath(folder, base: base)
        let shown = folder == base ? Format.folderName(base) : relative
        return link.line.map { "\(shown), line \($0)" } ?? shown
    }

    // MARK: Body

    @ViewBuilder private var bodyView: some View {
        switch content?.kind {
        case nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            message("This file is not text", detail: "Open it in another app with Open in.")
        case .unreadable(let reason):
            message("Could not show this file", detail: reason)
        case .text:
            if let content { CodeLines(content: content, targetLine: link.line) }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: theme.z(6)) {
            Text(title)
                .font(theme.font(size: 13.5, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text(detail)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "Open in" menu: installed editors, then the default app.
private struct OpenInMenu: View {
    let link: FileLink
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                ForEach(ExternalEditors.installed) { editor in
                    Button {
                        ExternalEditors.open(link, in: editor)
                    } label: {
                        Label { Text(editor.name) } icon: { Image(nsImage: ExternalEditors.icon(for: editor)) }
                    }
                }
                if !ExternalEditors.installed.isEmpty { Divider() }
                Button("Default app") { FileActions.openWithDefaultApp(link) }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(link.line.map { "Open in another app at line \($0)" } ?? "Open in another app")
        }
    }

    private var label: some View {
        HStack(spacing: theme.z(4)) {
            Text("Open in")
            Image(systemName: "chevron.down").font(theme.font(size: 8.5, weight: .semibold))
        }
        .font(theme.font(size: 12, weight: .medium))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, theme.z(9))
        .frame(height: theme.z(24))
        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).strokeBorder(theme.border))
        .contentShape(Rectangle())
    }
}

/// Numbered, coloured lines; the target line is marked and scrolled to.
private struct CodeLines: View {
    let content: FileViewerContent
    let targetLine: Int?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let digits = max(3, String(content.lines.count).count)
        let numberWidth = theme.z(CGFloat(digits) * 7.6 + 14)
        if isSnapshot {
            // No scrolling in snapshots: start a few lines above the target.
            let start = max(0, (targetLine ?? 1) - 8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(start..<min(content.lines.count, start + 60), id: \.self) { index in
                    line(index, numberWidth: numberWidth)
                }
            }
            .padding(.vertical, theme.z(8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(content.lines.indices, id: \.self) { index in
                            line(index, numberWidth: numberWidth).id(index + 1)
                        }
                        if content.isTruncated {
                            Text("Showing the first \(content.lines.count.formatted()) of \(content.totalLines.formatted()) lines")
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.leading, numberWidth + theme.z(12))
                                .padding(.vertical, theme.z(10))
                        }
                    }
                    .padding(.vertical, theme.z(8))
                }
                .task(id: targetLine) {
                    guard let targetLine else { return }
                    try? await Task.sleep(for: .milliseconds(60))
                    proxy.scrollTo(min(targetLine, content.lines.count), anchor: .center)
                }
            }
        }
    }

    private func line(_ index: Int, numberWidth: CGFloat) -> some View {
        let number = index + 1
        let isTarget = number == targetLine
        return HStack(alignment: .firstTextBaseline, spacing: theme.z(12)) {
            Text("\(number)")
                .font(theme.font(size: 11.5, design: .monospaced))
                .foregroundStyle(isTarget ? theme.textPrimary : theme.textTertiary)
                .frame(width: numberWidth, alignment: .trailing)
            Text(content.lines[index])
                .font(theme.font(size: 12, design: .monospaced))
                .lineSpacing(theme.z(2))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableText()
        }
        .padding(.trailing, theme.z(12))
        .padding(.vertical, theme.z(1.5))
        .background(isTarget ? theme.accent.opacity(0.14) : .clear)
        .overlay(alignment: .leading) {
            if isTarget { Rectangle().fill(theme.accent).frame(width: theme.z(2)) }
        }
    }
}
