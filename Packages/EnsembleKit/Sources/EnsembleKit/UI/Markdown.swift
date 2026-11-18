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
    public static func attributed(_ source: String, theme: Theme, size: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = .system(size: size - 1, design: .monospaced)
                attributed[run.range].backgroundColor = theme.inlineCodeBackground
                attributed[run.range].foregroundColor = theme.inlineCodeText
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = theme.accent
            }
        }
        return attributed
    }
}

// MARK: - Views

/// Renders agent Markdown: headings, lists, inline code, fenced code with a copy button, quotes, tables.
public struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat
    var textColor: Color?
    @Environment(\.theme) private var theme

    public init(_ text: String, fontSize: CGFloat = 14, textColor: Color? = nil) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
    }

    public var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color { textColor ?? theme.textPrimary }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text, theme: theme, size: headingSize(level)))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()

        case .paragraph(let text):
            Text(MarkdownInline.attributed(text, theme: theme, size: fontSize))
                .font(.system(size: fontSize))
                .foregroundStyle(color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()

        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                        } else {
                            Text(item.marker)
                                .font(.system(size: fontSize).monospacedDigit())
                                .foregroundStyle(theme.textSecondary)
                                .frame(minWidth: 12, alignment: .trailing)
                        }
                        Text(MarkdownInline.attributed(item.text, theme: theme, size: fontSize))
                            .font(.system(size: fontSize))
                            .foregroundStyle(color)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableText()
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }

        case .code(let language, let code):
            CodeBlockView(code: code, language: language)

        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(theme.border).frame(width: 3)
                Text(MarkdownInline.attributed(text, theme: theme, size: fontSize))
                    .font(.system(size: fontSize))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectableText()
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            HLine().padding(.vertical, 4)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, fontSize: fontSize - 1)
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
    @Environment(\.theme) private var theme

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    Text(MarkdownInline.attributed(c < header.count ? header[c] : "", theme: theme, size: fontSize))
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
            Rectangle().fill(theme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(MarkdownInline.attributed(c < row.count ? row[c] : "", theme: theme, size: fontSize))
                            .font(.system(size: fontSize))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.separator))
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
                    .font(.system(size: 11.5))
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
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(copied ? theme.success : theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                Text(SyntaxHighlighter.highlight(code, language: language, theme: theme))
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: true, vertical: true)
                    .selectableText()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
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
