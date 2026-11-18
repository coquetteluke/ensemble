import SwiftUI

/// One line of a unified diff with its old and new line numbers.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case context, addition, deletion, hunk }
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
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
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line == "\\ No newline at end of file" {
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

/// Coloured unified diff with line numbers. Long diffs show the first `maxLines` with a button for the rest.
public struct DiffView: View {
    let lines: [DiffLine]
    var maxLines: Int?
    @Environment(\.theme) private var theme
    @State private var showAll = false

    public init(diff: String, maxLines: Int? = 40) {
        self.lines = DiffParser.parse(diff)
        self.maxLines = maxLines
    }

    public var body: some View {
        let limit = (showAll || maxLines == nil) ? lines.count : min(lines.count, maxLines ?? lines.count)
        let shown = Array(lines.prefix(limit))
        let numberWidth = CGFloat(max(2, String(lines.compactMap { $0.newNumber ?? $0.oldNumber }.max() ?? 0).count)) * theme.z(7.6) + theme.z(8)

        VStack(alignment: .leading, spacing: 0) {
            AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        row(line, numberWidth: numberWidth)
                    }
                }
                .frame(minWidth: 0, alignment: .leading)
            }
            if limit < lines.count {
                Button("Show \(lines.count - limit) more lines") { showAll = true }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(6))
            }
        }
        .padding(.vertical, theme.z(4))
    }

    @ViewBuilder private func row(_ line: DiffLine, numberWidth: CGFloat) -> some View {
        switch line.kind {
        case .hunk:
            Text(line.text)
                .font(theme.font(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, theme.z(10))
                .padding(.vertical, theme.z(3))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.diffHunkBackground)
        default:
            HStack(spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(theme.textTertiary.opacity(0.8))
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(theme.textTertiary.opacity(0.8))
                Text(sign(line.kind))
                    .frame(width: theme.z(22), alignment: .center)
                    .foregroundStyle(signColor(line.kind))
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, theme.z(12))
            }
            .font(theme.font(size: 12, design: .monospaced))
            .padding(.vertical, theme.z(1.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(line.kind))
        }
    }

    private func sign(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "-"
        default: " "
        }
    }

    private func signColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: theme.diffAddText
        case .deletion: theme.diffRemoveText
        default: theme.textTertiary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: theme.diffAddBackground
        case .deletion: theme.diffRemoveBackground
        default: .clear
        }
    }
}
