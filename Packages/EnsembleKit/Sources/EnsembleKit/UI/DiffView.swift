import SwiftUI

/// One line of a unified diff with its old and new line numbers.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case context, addition, deletion, hunk }
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public enum DiffParser {
    /// Parses a unified diff. File headers (`diff --git`, `index`, `---`, `+++`) are dropped.
    public static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line == "\\ No newline at end of file"
                || line.hasPrefix("similarity index") || line.hasPrefix("rename from ") || line.hasPrefix("rename to ")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                continue
            }
            if line.hasPrefix("@@") {
                let (o, n) = hunkStarts(line)
                oldLine = o
                newLine = n
                lines.append(DiffLine(kind: .hunk, text: line, oldNumber: nil, newNumber: nil))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .addition, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .deletion, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            } else {
                if line.isEmpty, raw.endIndex == diff.endIndex { continue }
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append(DiffLine(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return lines
    }

    /// Start lines from `@@ -12,7 +12,9 @@`.
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 1 }
            let numbers = part.dropFirst().split(separator: ",")
            return Int(numbers.first ?? "1") ?? 1
        }
        return (start("-"), start("+"))
    }
}

/// A diff parsed once for display: its lines, the hunk ranges and the changed words inside changed lines.
/// Views that redraw often (the review pane) keep one of these instead of parsing on every update.
public struct ParsedDiff: Hashable, Sendable {
    public var lines: [DiffLine]
    /// Changed character ranges (character offsets into `text`) of paired removed and added lines, by line index.
    public var wordChanges: [Int: [Range<Int>]]
    /// `@@` ranges in order.
    public var hunks: [HunkRange]

    public struct HunkRange: Hashable, Sendable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int

        /// First new-side line the hunk covers, and the line after it (a hunk adding nothing sits after `newStart`).
        var newBegin: Int { newCount == 0 ? newStart + 1 : newStart }
        var newEnd: Int { newCount == 0 ? newStart + 1 : newStart + newCount }
        var oldEnd: Int { oldCount == 0 ? oldStart + 1 : oldStart + oldCount }
    }

    public init(_ diff: String, wordHighlight: Bool = true) {
        lines = DiffParser.parse(diff)
        hunks = lines.filter { $0.kind == .hunk }.map { line in
            let r = GitDiffParsing.hunkRanges(line.text)
            return HunkRange(oldStart: r.oldStart, oldCount: r.oldCount, newStart: r.newStart, newCount: r.newCount)
        }
        wordChanges = wordHighlight ? Self.pairWordChanges(lines) : [:]
    }

    /// What a diff view draws, in order.
    public enum Row: Hashable, Sendable {
        case line(Int)
        case hunk(line: Int, hunk: Int)
        /// Unchanged new-side lines `start ..< start + count`; old numbers are new numbers plus `oldOffset`.
        case gap(id: Int, start: Int, count: Int, oldOffset: Int)
        case gapLine(newNumber: Int, oldNumber: Int, text: String)
    }

    /// Rows for display. With `showGaps`, the unchanged lines before, between and after hunks become gap
    /// rows (the region after the last hunk needs the new file's line count), and gaps in `expanded` are
    /// drawn line by line from `newText`.
    public func rows(showGaps: Bool, newLineCount: Int? = nil, expanded: Set<Int> = [], newText: [String]? = nil) -> [Row] {
        var rows: [Row] = []
        var hunkIndex = 0
        var nextNew = 1
        var oldOffset = 0
        func appendGap(id: Int, start: Int, count: Int, oldOffset: Int) {
            guard count > 0 else { return }
            if expanded.contains(id), let text = newText, start >= 1, start - 1 + count <= text.count {
                for n in start..<(start + count) {
                    rows.append(.gapLine(newNumber: n, oldNumber: n + oldOffset, text: text[n - 1]))
                }
            } else {
                rows.append(.gap(id: id, start: start, count: count, oldOffset: oldOffset))
            }
        }
        for (index, line) in lines.enumerated() {
            if line.kind == .hunk {
                if showGaps, hunkIndex < hunks.count {
                    let hunk = hunks[hunkIndex]
                    appendGap(id: hunkIndex, start: nextNew, count: hunk.newBegin - nextNew, oldOffset: oldOffset)
                    nextNew = hunk.newEnd
                    oldOffset = hunk.oldEnd - hunk.newEnd
                }
                rows.append(.hunk(line: index, hunk: hunkIndex))
                hunkIndex += 1
            } else {
                rows.append(.line(index))
            }
        }
        if showGaps, !hunks.isEmpty, let total = newText?.count ?? newLineCount {
            appendGap(id: hunks.count, start: nextNew, count: total - nextNew + 1, oldOffset: oldOffset)
        }
        return rows
    }

    /// Pairs each run of removed lines with the added lines right after it, line by line, and finds the
    /// words that changed. Pairs that share too little are left whole.
    static func pairWordChanges(_ lines: [DiffLine]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .deletion else {
                i += 1
                continue
            }
            let deletions = i
            while i < lines.count, lines[i].kind == .deletion { i += 1 }
            let additions = i
            while i < lines.count, lines[i].kind == .addition { i += 1 }
            let pairs = min(additions - deletions, i - additions)
            guard pairs > 0, pairs <= 200 else { continue }
            for k in 0..<pairs {
                let old = lines[deletions + k].text
                let new = lines[additions + k].text
                if let changes = WordDiff.changedRanges(old: old, new: new) {
                    if !changes.old.isEmpty { result[deletions + k] = changes.old }
                    if !changes.new.isEmpty { result[additions + k] = changes.new }
                }
            }
        }
        return result
    }
}

/// Word-level differences between two versions of a line.
public enum WordDiff {
    /// Words, runs of spaces, and single punctuation marks.
    static func tokens(_ text: String) -> [Substring] {
        var tokens: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        func kind(_ c: Character) -> Int { c.isLetter || c.isNumber || c == "_" ? 0 : (c.isWhitespace ? 1 : 2) }
        while index < text.endIndex {
            let k = kind(text[index])
            var next = text.index(after: index)
            if k != 2 {
                while next < text.endIndex, kind(text[next]) == k { next = text.index(after: next) }
            }
            tokens.append(text[start..<next])
            start = next
            index = next
        }
        return tokens
    }

    /// Character ranges that changed on each side, or nil when the lines share too little for word
    /// highlights to help (or are too long to compare).
    public static func changedRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old != new else { return nil }
        let a = tokens(old)
        let b = tokens(new)
        guard a.count <= 400, b.count <= 400, !a.isEmpty, !b.isEmpty else { return nil }
        // Longest common subsequence of tokens.
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var keepA = [Bool](repeating: false, count: n)
        var keepB = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                keepA[i] = true
                keepB[j] = true
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // Too little in common: highlighting most of both lines says nothing.
        let shared = zip(a, keepA).filter { $0.1 && !$0.0.allSatisfy(\.isWhitespace) }.reduce(0) { $0 + $1.0.count }
        let longest = max(old.filter { !$0.isWhitespace }.count, new.filter { !$0.isWhitespace }.count)
        guard longest > 0, Double(shared) / Double(longest) >= 0.35 else { return nil }
        return (ranges(a, keepA), ranges(b, keepB))
    }

    /// Merges unkept tokens into character ranges; changed tokens separated by one kept space join up.
    private static func ranges(_ tokens: [Substring], _ keep: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var offset = 0
        for (token, kept) in zip(tokens, keep) {
            let range = offset..<(offset + token.count)
            offset += token.count
            guard !kept else { continue }
            if let last = result.last, range.lowerBound - last.upperBound <= 1 {
                result[result.count - 1] = last.lowerBound..<range.upperBound
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// How a diff is drawn.
public struct DiffDisplayOptions: Sendable {
    /// Wrap long lines instead of scrolling sideways (the review pane).
    public var wrapLines: Bool
    /// Show the unchanged lines between hunks as rows that can be opened.
    public var showGaps: Bool
    /// Number of lines in the new file, for the unchanged lines after the last hunk.
    public var newLineCount: Int?
    /// Rows shown before a "Show more" button; nil shows everything.
    public var maxLines: Int?
    /// Snapshots draw this line index as if the pointer were over it.
    public var hoveredLine: Int?

    public init(wrapLines: Bool = false, showGaps: Bool = false, newLineCount: Int? = nil, maxLines: Int? = 40, hoveredLine: Int? = nil) {
        self.wrapLines = wrapLines
        self.showGaps = showGaps
        self.newLineCount = newLineCount
        self.maxLines = maxLines
        self.hoveredLine = hoveredLine
    }
}

/// What a diff lets you do: add a comment from a line's gutter, show views under lines and beside hunk headers,
/// and open unchanged regions.
public struct DiffInteraction {
    /// Clicking a line's gutter (its numbers). Nil hides the add button.
    public var onGutterTap: (@MainActor (DiffLine) -> Void)?
    /// A view drawn under a line (comments).
    public var lineAccessory: (@MainActor (DiffLine) -> AnyView?)?
    /// A view at the end of a hunk header, by hunk index (Stage hunk).
    public var hunkAccessory: (@MainActor (Int) -> AnyView?)?
    /// The new file's lines, to fill an unchanged region when it is opened.
    public var loadNewText: (@MainActor () -> [String]?)?
    /// Help text for the gutter button.
    public var gutterHelp: String

    public init(onGutterTap: (@MainActor (DiffLine) -> Void)? = nil, lineAccessory: (@MainActor (DiffLine) -> AnyView?)? = nil,
                hunkAccessory: (@MainActor (Int) -> AnyView?)? = nil, loadNewText: (@MainActor () -> [String]?)? = nil,
                gutterHelp: String = "Comment on this line") {
        self.onGutterTap = onGutterTap
        self.lineAccessory = lineAccessory
        self.hunkAccessory = hunkAccessory
        self.loadNewText = loadNewText
        self.gutterHelp = gutterHelp
    }
}

/// Coloured unified diff with line numbers. Long diffs show the first `maxLines` with a button for the rest.
/// The review pane also wraps lines, highlights changed words, collapses unchanged regions between hunks and
/// takes comments from the gutter.
public struct DiffView: View {
    let parsed: ParsedDiff
    let options: DiffDisplayOptions
    let interaction: DiffInteraction
    @Environment(\.theme) private var theme
    @State private var showAll = false
    @State private var expandedGaps: Set<Int> = []
    @State private var newText: [String]?

    public init(diff: String, maxLines: Int? = 40) {
        self.parsed = ParsedDiff(diff, wordHighlight: false)
        self.options = DiffDisplayOptions(maxLines: maxLines)
        self.interaction = DiffInteraction()
    }

    public init(parsed: ParsedDiff, options: DiffDisplayOptions, interaction: DiffInteraction = DiffInteraction()) {
        self.parsed = parsed
        self.options = options
        self.interaction = interaction
    }

    var lines: [DiffLine] { parsed.lines }

    func rows() -> [ParsedDiff.Row] {
        parsed.rows(showGaps: options.showGaps, newLineCount: options.newLineCount, expanded: expandedGaps, newText: newText)
    }

    public var body: some View {
        let all = rows()
        let limit = (showAll || options.maxLines == nil) ? all.count : min(all.count, options.maxLines ?? all.count)
        let shown = Array(all.prefix(limit))
        let largest = max(lines.compactMap { $0.newNumber ?? $0.oldNumber }.max() ?? 0, newText?.count ?? options.newLineCount ?? 0)
        let numberWidth = CGFloat(max(2, String(largest).count)) * theme.z(7.6) + theme.z(8)

        VStack(alignment: .leading, spacing: 0) {
            if options.wrapLines {
                rowStack(shown, numberWidth: numberWidth)
            } else {
                AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                    rowStack(shown, numberWidth: numberWidth)
                        .frame(minWidth: 0, alignment: .leading)
                }
            }
            if limit < all.count {
                Button("Show \(all.count - limit) more lines") { showAll = true }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(6))
            }
        }
        .padding(.vertical, options.wrapLines ? 0 : theme.z(4))
    }

    private func rowStack(_ shown: [ParsedDiff.Row], numberWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.self) { row in
                switch row {
                case .line(let index):
                    lineRow(lines[index], index: index, numberWidth: numberWidth)
                    if let accessory = interaction.lineAccessory?(lines[index]) {
                        accessory
                    }
                case .hunk(let index, let hunk):
                    hunkRow(lines[index].text, hunk: hunk)
                case .gap(let id, _, let count, _):
                    gapRow(id: id, count: count)
                case .gapLine(let newNumber, let oldNumber, let text):
                    let line = DiffLine(kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber)
                    lineRow(line, index: -newNumber, numberWidth: numberWidth)
                    if let accessory = interaction.lineAccessory?(line) {
                        accessory
                    }
                }
            }
        }
    }

    private func hunkRow(_ text: String, hunk: Int) -> some View {
        HStack(spacing: theme.z(8)) {
            Text(text)
                .font(theme.font(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let accessory = interaction.hunkAccessory?(hunk) {
                accessory
            }
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.diffHunkBackground)
    }

    @ViewBuilder private func gapRow(id: Int, count: Int) -> some View {
        let canOpen = interaction.loadNewText != nil || newText != nil
        let label = HStack(spacing: theme.z(6)) {
            Image(systemName: "chevron.up.chevron.down")
                .font(theme.font(size: 9.5, weight: .semibold))
            Text(count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
                .font(theme.font(size: 11.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.diffHunkBackground.opacity(0.6))
        .contentShape(Rectangle())
        if canOpen {
            Button {
                if newText == nil { newText = interaction.loadNewText?() }
                if newText != nil { expandedGaps.insert(id) }
            } label: { label }
                .buttonStyle(.plain)
                .help("Show the unchanged lines")
        } else {
            label
        }
    }

    private func lineRow(_ line: DiffLine, index: Int, numberWidth: CGFloat) -> some View {
        DiffLineRow(line: line, wordChanges: index >= 0 ? parsed.wordChanges[index] : nil, numberWidth: numberWidth,
                    wrap: options.wrapLines, snapshotHover: options.hoveredLine == index,
                    onGutterTap: interaction.onGutterTap, gutterHelp: interaction.gutterHelp)
    }
}

/// One diff line. Its own view so pointer hover redraws only this row.
private struct DiffLineRow: View {
    let line: DiffLine
    let wordChanges: [Range<Int>]?
    let numberWidth: CGFloat
    let wrap: Bool
    let snapshotHover: Bool
    let onGutterTap: (@MainActor (DiffLine) -> Void)?
    let gutterHelp: String
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    var body: some View {
        let showAdd = onGutterTap != nil && (hovering || (isSnapshot && snapshotHover))
        HStack(alignment: .top, spacing: 0) {
            gutter(showAdd: showAdd)
            Text(sign)
                .frame(width: theme.z(wrap ? 16 : 22), alignment: .center)
                .foregroundStyle(signColor)
            lineText
                .padding(.trailing, theme.z(12))
        }
        .font(theme.font(size: 12, design: .monospaced))
        .padding(.vertical, theme.z(1.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .background(showAdd ? theme.accent.opacity(0.06) : .clear)
        .onHover { inside in
            guard onGutterTap != nil else { return }
            hovering = inside
        }
    }

    @ViewBuilder private func gutter(showAdd: Bool) -> some View {
        let numbers = HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
        }
        .foregroundStyle(theme.textTertiary.opacity(0.8))
        .overlay(alignment: .leading) {
            if showAdd {
                Image(systemName: "plus")
                    .font(theme.font(size: 9.5, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: theme.z(16), height: theme.z(16))
                    .background(RoundedRectangle(cornerRadius: theme.z(4), style: .continuous).fill(theme.accent))
                    .padding(.leading, theme.z(4))
            }
        }
        if let onGutterTap {
            Button { onGutterTap(line) } label: { numbers.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(gutterHelp)
        } else {
            numbers
        }
    }

    @ViewBuilder private var lineText: some View {
        let base = Text(highlighted(line.text.isEmpty ? " " : line.text))
            .foregroundStyle(theme.textPrimary)
        if wrap {
            base
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            base.fixedSize(horizontal: true, vertical: false)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let wordChanges, !wordChanges.isEmpty else { return attributed }
        let color = line.kind == .addition
            ? theme.diffAddText.opacity(theme.isDark ? 0.32 : 0.24)
            : theme.diffRemoveText.opacity(theme.isDark ? 0.32 : 0.24)
        let count = text.count
        for range in wordChanges where range.lowerBound < count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: min(range.upperBound, count))
            attributed[start..<end].backgroundColor = color
        }
        return attributed
    }

    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        default: " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .addition: theme.diffAddText
        case .deletion: theme.diffRemoveText
        default: theme.textTertiary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: theme.diffAddBackground
        case .deletion: theme.diffRemoveBackground
        default: .clear
        }
    }
}
