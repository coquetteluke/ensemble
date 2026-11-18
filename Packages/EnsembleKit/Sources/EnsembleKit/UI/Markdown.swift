import SwiftUI

// MARK: - Parser

/// A block of Markdown as the transcript renders it.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, code: String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
}

public struct MarkdownListItem: Hashable, Sendable {
    /// "•" for bullets, "1." for numbered items.
    public var marker: String
    public var text: String
    /// Nesting depth (0 = top level).
    public var indent: Int
    /// Task list state, when the item is `- [ ]` or `- [x]`.
    public var checked: Bool?
}

/// Small block-level Markdown parser: headings, paragraphs, bullet and numbered lists, fenced code
/// (an unclosed fence runs to the end, which suits streaming text), quotes, rules and pipe tables.
/// Inline syntax (bold, italic, code, links) is handled by `AttributedString(markdown:)`.
public enum MarkdownParser {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(tableCells(t))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let first = listItem(line) {
                flushParagraph()
                var items = [first]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if let item = listItem(next) {
                        items.append(item)
                        i += 1
                    } else if !next.trimmingCharacters(in: .whitespaces).isEmpty, next.hasPrefix("  "),
                              !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        items[items.count - 1].text += " " + next.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func tableCells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listItem(_ line: String) -> MarkdownListItem? {
        var spaces = 0
        for ch in line {
            if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 4 } else { break }
        }
        let body = line.trimmingCharacters(in: .whitespaces)
        let indent = spaces / 2
        var marker: String
        var text: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            marker = "\u{2022}"
            text = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            text = after.dropFirst(2)
        }
        var checked: Bool?
        if text.hasPrefix("[ ] ") {
            checked = false
            text = text.dropFirst(4)
        } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            checked = true
            text = text.dropFirst(4)
        }
        if checked != nil { marker = "" }
        return MarkdownListItem(marker: marker, text: String(text), indent: indent, checked: checked)
    }
}

// MARK: - Inline styling

public enum MarkdownInline {
    /// Inline Markdown (bold, italic, code, links) as an attributed string with Ensemble's code style.
    /// With `fileBase` (the session's folder), file paths inside it become `ensemble-file` links.
    public static func attributed(_ source: String, theme: Theme, size: CGFloat, fileBase: String? = nil) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = theme.font(size: size - 1, design: .monospaced)
                attributed[run.range].backgroundColor = theme.inlineCodeBackground
                attributed[run.range].foregroundColor = theme.inlineCodeText
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = theme.accent
            }
        }
        if let fileBase, !fileBase.isEmpty { addFileLinks(&attributed, base: fileBase, theme: theme) }
        return attributed
    }

    /// Marks file paths that exist inside `base`: a whole code span holding a path, or paths in plain text.
    /// Text that already is a link is left alone.
    static func addFileLinks(_ attributed: inout AttributedString, base: String, theme: Theme) {
        var found: [(Range<AttributedString.Index>, FileLink)] = []
        for run in attributed.runs where run.link == nil {
            let text = String(attributed[run.range].characters)
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                if let link = FilePathDetector.link(forCode: text, base: base) { found.append((run.range, link)) }
                continue
            }
            for match in FilePathDetector.matches(in: text, base: base) {
                let start = text.distance(from: text.startIndex, to: match.range.lowerBound)
                let length = text.distance(from: match.range.lowerBound, to: match.range.upperBound)
                let lower = attributed.characters.index(run.range.lowerBound, offsetBy: start)
                let upper = attributed.characters.index(lower, offsetBy: length)
                found.append((lower..<upper, match.link))
            }
        }
        for (range, link) in found {
            attributed[range].link = link.url
            attributed[range].foregroundColor = theme.accent
        }
    }
}

/// Inline Markdown text. File links in it get a hit area each, so a click opens the file and a right-click
/// shows the file's menu (from `\.fileLinkActions`); other text stays selectable around them.
struct InlineMarkdownText: View {
    let attributed: AttributedString
    @Environment(\.fileLinkActions) private var actions

    init(_ attributed: AttributedString) { self.attributed = attributed }

    var body: some View {
        let parts = FileLinkText(attributed)
        if let actions, !parts.links.isEmpty {
            parts.text
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    FileLinkHitAreas(layouts: layouts, links: parts.links, actions: actions)
                }
        } else {
            Text(attributed)
        }
    }
}

/// The text split at file links, each link tagged so its position can be found after layout.
private struct FileLinkText {
    var text: Text
    var links: [FileLink] = []

    init(_ attributed: AttributedString) {
        var text = Text(verbatim: "")
        var links: [FileLink] = []
        for (url, range) in attributed.runs[\.link] {
            var piece = Text(AttributedString(attributed[range]))
            if let url, let link = FileLink(url: url) {
                piece = piece.customAttribute(FileLinkTextAttribute(index: links.count))
                links.append(link)
            }
            text = Text("\(text)\(piece)")
        }
        self.text = text
        self.links = links
    }
}

private struct FileLinkTextAttribute: TextAttribute {
    let index: Int
}

/// Clear boxes over each laid-out file link run, for the click, the pointer and the right-click menu.
private struct FileLinkHitAreas: View {
    let layouts: Text.LayoutKey.Value
    let links: [FileLink]
    let actions: FileLinkActions
    @Environment(\.sessionDirectory) private var base
    @Environment(\.showsFileLinkAreas) private var showsAreas

    private struct Area: Identifiable {
        let id: Int
        let rect: CGRect
        let link: FileLink
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(areas(proxy)) { area in
                (showsAreas ? Color.red.opacity(0.35) : Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: area.rect.width, height: area.rect.height)
                    .position(x: area.rect.midX, y: area.rect.midY)
                    .onTapGesture { actions.open(area.link) }
                    .contextMenu { FileLinkMenuContent(items: actions.menu(area.link)) }
                    .help("Open \(area.link.display(base: base))")
                    .accessibilityElement()
                    .accessibilityLabel("Open \(area.link.display(base: base))")
                    .accessibilityAddTraits(.isLink)
                    .linkPointer()
            }
        }
    }

    private func areas(_ proxy: GeometryProxy) -> [Area] {
        var areas: [Area] = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line {
                    guard let tag = run[FileLinkTextAttribute.self], tag.index < links.count else { continue }
                    let rect = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    areas.append(Area(id: areas.count, rect: rect, link: links[tag.index]))
                }
            }
        }
        return areas
    }
}

/// The right-click menu of a file link.
struct FileLinkMenuContent: View {
    let items: [FileLinkMenuItem]

    var body: some View {
        ForEach(items) { item in
            if item.children.isEmpty {
                Button {
                    item.action?()
                } label: {
                    if let symbol = item.symbol { Label(item.title, systemImage: symbol) } else { Text(item.title) }
                }
                .disabled(item.action == nil)
            } else {
                Menu {
                    FileLinkMenuContent(items: item.children)
                } label: {
                    if let symbol = item.symbol { Label(item.title, systemImage: symbol) } else { Text(item.title) }
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder func linkPointer() -> some View {
        #if os(macOS)
        pointerStyle(.link)
        #else
        self
        #endif
    }
}

// MARK: - Views

/// Renders agent Markdown: headings, lists, inline code, fenced code with a copy button, quotes, tables.
public struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat
    var textColor: Color?
    /// While the text is still streaming, a `widget` or `svg` block at the end waits instead of rendering half a page.
    var streaming: Bool
    /// Agent writing uses the serif (`MessageType`); false keeps the interface sans, as for thinking text.
    var serif: Bool
    @Environment(\.theme) private var theme
    @Environment(\.fileLinkActions) private var fileLinkActions
    @Environment(\.sessionDirectory) private var sessionDirectory

    public init(_ text: String, fontSize: CGFloat = 14, textColor: Color? = nil, streaming: Bool = false, serif: Bool = true) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
        self.streaming = streaming
        self.serif = serif
    }

    public var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: theme.z(serif ? 12 : 10)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { [fileLinkActions] url in
            guard let link = FileLink(url: url) else { return .systemAction }
            fileLinkActions?.open(link)
            return .handled
        })
    }

    private var color: Color { textColor ?? theme.textPrimary }

    /// The session folder file paths are looked up in: only when the app handles file links, and not while the
    /// text is still arriving.
    private var fileBase: String? {
        guard fileLinkActions != nil, !streaming, !sessionDirectory.isEmpty else { return nil }
        return sessionDirectory
    }

    private func inline(_ text: String, size: CGFloat) -> InlineMarkdownText {
        InlineMarkdownText(MarkdownInline.attributed(text, theme: theme, size: size, fileBase: fileBase))
    }

    private func bodyFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        serif ? theme.messageFont(size: size, weight: weight) : theme.font(size: size, weight: weight)
    }

    private func tracking(_ size: CGFloat) -> CGFloat { serif ? theme.messageTracking(size) : 0 }

    private var lineSpacing: CGFloat { serif ? theme.messageLineSpacing(fontSize) : theme.z(3) }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, size: headingSize(level))
                .font(bodyFont(headingSize(level), weight: .semibold))
                .tracking(tracking(headingSize(level)))
                .foregroundStyle(color)
                .padding(.top, theme.z(level <= 2 ? 6 : 2))
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()

        case .paragraph(let text):
            inline(text, size: fontSize)
                .font(bodyFont(fontSize))
                .tracking(tracking(fontSize))
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()

        case .list(let items):
            VStack(alignment: .leading, spacing: theme.z(5)) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(theme.font(size: fontSize - 2))
                                .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                        } else {
                            Text(item.marker)
                                .font(bodyFont(fontSize).monospacedDigit())
                                .foregroundStyle(theme.textSecondary)
                                .frame(minWidth: theme.z(12), alignment: .trailing)
                        }
                        inline(item.text, size: fontSize)
                            .font(bodyFont(fontSize))
                            .tracking(tracking(fontSize))
                            .foregroundStyle(color)
                            .lineSpacing(lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableText()
                    }
                    .padding(.leading, theme.z(CGFloat(item.indent) * 18))
                }
            }

        case .code(let language, let code):
            // Only the last block of a streaming message can still be arriving.
            switch language?.lowercased() {
            case "widget", "html-widget":
                WidgetBlockView(source: code, pending: streaming && isLast)
            case "svg":
                SVGBlockView(source: code, pending: streaming && isLast)
            default:
                CodeBlockView(code: code, language: language)
            }

        case .quote(let text):
            HStack(spacing: theme.z(10)) {
                RoundedRectangle(cornerRadius: theme.z(1)).fill(theme.border).frame(width: theme.z(3))
                inline(text, size: fontSize)
                    .font(bodyFont(fontSize))
                    .tracking(tracking(fontSize))
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectableText()
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            HLine().padding(.vertical, theme.z(4))

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, fontSize: fontSize - 1, serif: serif, fileBase: fileBase)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: fontSize + 6
        case 2: fontSize + 3
        case 3: fontSize + 1
        default: fontSize
        }
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let fontSize: CGFloat
    let serif: Bool
    var fileBase: String?
    @Environment(\.theme) private var theme

    private func cellFont(weight: Font.Weight = .regular) -> Font {
        serif ? theme.messageFont(size: fontSize, weight: weight) : theme.font(size: fontSize, weight: weight)
    }

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: theme.z(16), verticalSpacing: theme.z(6)) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    InlineMarkdownText(MarkdownInline.attributed(c < header.count ? header[c] : "", theme: theme, size: fontSize, fileBase: fileBase))
                        .font(cellFont(weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
            Rectangle().fill(theme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        InlineMarkdownText(MarkdownInline.attributed(c < row.count ? row[c] : "", theme: theme, size: fontSize, fileBase: fileBase))
                            .font(cellFont())
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }
        }
        .padding(theme.z(12))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.separator))
    }
}

/// Fenced code block: language label, copy button, monospaced text with light syntax colouring.
public struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.theme) private var theme
    @State private var copied = false

    public init(code: String, language: String?) {
        self.code = code
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Button {
                    copyToPasteboard(code)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    HStack(spacing: theme.z(4)) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(copied ? theme.success : theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, theme.z(12))
            .padding(.top, theme.z(8))
            .padding(.bottom, theme.z(2))

            AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                Text(SyntaxHighlighter.highlight(code, language: language, theme: theme))
                    .font(theme.font(size: 12.5, design: .monospaced))
                    .lineSpacing(theme.z(2.5))
                    .fixedSize(horizontal: true, vertical: true)
                    .selectableText()
                    .padding(.horizontal, theme.z(12))
                    .padding(.top, theme.z(4))
                    .padding(.bottom, theme.z(11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
    }
}

// MARK: - Syntax colouring

/// A deliberately small highlighter: comments, strings, numbers, keywords and capitalised type names.
public enum SyntaxHighlighter {
    static let keywords: Set<String> = [
        // Swift
        "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch",
        "default", "for", "in", "while", "import", "public", "private", "internal", "fileprivate", "static",
        "init", "self", "Self", "true", "false", "nil", "async", "await", "throws", "throw", "try", "catch",
        "do", "extension", "protocol", "some", "any", "where", "break", "continue", "defer", "inout", "mutating",
        "override", "final", "lazy", "weak", "actor", "nonisolated", "typealias", "associatedtype", "is", "as",
        // JS / TS
        "const", "function", "new", "this", "null", "undefined", "export", "from", "type", "interface",
        "extends", "implements", "yield", "of", "typeof", "instanceof",
        // Python / shell / others
        "def", "elif", "pass", "with", "lambda", "None", "True", "False", "and", "or", "not", "fn", "pub",
        "impl", "use", "mod", "match", "package", "go", "fi", "then", "done", "echo",
    ]

    public static func highlight(_ code: String, language: String?, theme: Theme) -> AttributedString {
        let lang = (language ?? "").lowercased()
        let hashComments = ["python", "py", "sh", "bash", "zsh", "shell", "yaml", "yml", "ruby", "rb", "toml"].contains(lang)
        let plain = ["text", "txt", "plain", "log", "output", "diff", "markdown", "md"].contains(lang)

        var result = AttributedString()
        func append(_ s: String, _ color: Color?) {
            var piece = AttributedString(s)
            piece.foregroundColor = color ?? theme.textPrimary
            result.append(piece)
        }
        if plain || code.count > 40_000 {
            append(code, nil)
            return result
        }

        let chars = Array(code)
        var i = 0
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { append(buffer, nil); buffer = "" }
        }

        while i < chars.count {
            let c = chars[i]
            // Line comments
            if (c == "/" && i + 1 < chars.count && chars[i + 1] == "/") || (hashComments && c == "#") {
                flush()
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                append(String(chars[i..<j]), theme.syntaxComment)
                i = j
                continue
            }
            // Block comments
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                flush()
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(chars.count, j + 2)
                append(String(chars[i..<j]), theme.syntaxComment)
                i = j
                continue
            }
            // Strings
            if c == "\"" || c == "'" || c == "`" {
                flush()
                var j = i + 1
                while j < chars.count, chars[j] != c, chars[j] != "\n" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                j = min(chars.count, j + 1)
                append(String(chars[i..<j]), theme.syntaxString)
                i = j
                continue
            }
            // Numbers
            if c.isNumber, buffer.last.map({ !$0.isLetter && $0 != "_" }) ?? true {
                flush()
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                append(String(chars[i..<j]), theme.syntaxNumber)
                i = j
                continue
            }
            // Words
            if c.isLetter || c == "_" || c == "@" {
                flush()
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if keywords.contains(word) || word.hasPrefix("@") {
                    append(word, theme.syntaxKeyword)
                } else if let first = word.first, first.isUppercase {
                    append(word, theme.syntaxType)
                } else {
                    append(word, nil)
                }
                i = j
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return result
    }
}
