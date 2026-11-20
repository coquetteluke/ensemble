import SwiftUI
import EnsembleKit

/// Command-Shift-P: every app command with fuzzy search. Return runs the selected one.
struct CommandPalettePanel: View {
    @Bindable var search: SearchCenter
    let store: SessionStore
    let window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var contentHeight: CGFloat = 0

    static let width: CGFloat = 620

    /// A command that matched the typed text, with the matched letters of its title.
    struct Entry: Identifiable {
        let command: AppCommand
        let positions: [Int]
        var id: AppCommandID { command.id }
    }

    /// Enabled commands matching the palette text, best first (registry order when nothing is typed).
    static func visibleCommands(search: SearchCenter, context: CommandContext) -> [Entry] {
        let commands = CommandRegistry.commands(context).filter(\.isEnabled)
        let query = search.paletteQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return commands.map { Entry(command: $0, positions: []) } }
        return commands.enumerated().compactMap { index, command -> (Entry, Int, Int)? in
            guard let match = FuzzyMatch.match(query, title: command.title, keywords: command.id.keywords + [command.id.area.rawValue]) else { return nil }
            return (Entry(command: command, positions: match.positions), match.score, index)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .map(\.0)
    }

    private var context: CommandContext {
        CommandContext(store: store, window: window, search: search, openWindow: openWindow, openSettings: openSettings)
    }

    var body: some View {
        let entries = Self.visibleCommands(search: search, context: context)
        OverlayCard(width: Self.width) {
            VStack(spacing: 0) {
                OverlayField(symbol: "command", placeholder: "Type a command", text: $search.paletteQuery)
                HLine(color: theme.border.opacity(0.7))
                if entries.isEmpty {
                    Text("No command matches \u{201C}\(search.paletteQuery)\u{201D}")
                        .font(theme.font(size: 13.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: theme.z(110))
                } else {
                    list(entries)
                }
            }
        }
    }

    @ViewBuilder private func list(_ entries: [Entry]) -> some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                CommandRow(entry: entry, selected: index == search.paletteSelection)
                    .id(entry.id)
                    .onTapGesture {
                        search.close()
                        entry.command.run()
                    }
            }
        }
        .padding(.vertical, theme.z(6))

        if isSnapshot {
            rows.frame(maxHeight: theme.z(420), alignment: .top).fixedSize(horizontal: false, vertical: true).clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, theme.z(44)), theme.z(420)))
                .onChange(of: search.paletteSelection) {
                    guard entries.indices.contains(search.paletteSelection) else { return }
                    proxy.scrollTo(entries[search.paletteSelection].id)
                }
            }
        }
    }
}

/// One command: icon, title with matched letters in bold, area, shortcut.
private struct CommandRow: View {
    let entry: CommandPalettePanel.Entry
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let id = entry.command.id
        HStack(spacing: theme.z(10)) {
            Image(systemName: id.symbol)
                .font(theme.font(size: 13))
                .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                .frame(width: theme.z(20))
            Text(HighlightedText.attributed(entry.command.title, highlights: entry.positions.map { $0..<($0 + 1) },
                                            base: theme.textPrimary, emphasis: theme.accent, background: nil,
                                            font: theme.font(size: 13.5), emphasisFont: theme.font(size: 13.5, weight: .semibold)))
                .lineLimit(1)
            Spacer(minLength: theme.z(12))
            Text(id.area.rawValue)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            if let shortcut = id.shortcut {
                KeyCaps(shortcut.caps)
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(34))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(selected ? theme.selection : (hovering ? theme.hover : .clear)))
        .padding(.horizontal, theme.z(8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Command-slash: every keyboard shortcut, grouped by area.
struct ShortcutOverlayPanel: View {
    let search: SearchCenter
    @Environment(\.theme) private var theme

    static let width: CGFloat = 820

    var body: some View {
        let groups = CommandRegistry.shortcutGroups
        let columns = Self.columns(groups)
        OverlayCard(width: Self.width) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard shortcuts")
                        .font(theme.font(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    IconButton("xmark", help: "Close (Esc)", size: 26) { search.close() }
                }
                .padding(.leading, theme.z(22))
                .padding(.trailing, theme.z(14))
                .frame(height: theme.z(50))
                HLine(color: theme.border.opacity(0.7))
                HStack(alignment: .top, spacing: theme.z(28)) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: theme.z(20)) {
                            ForEach(column) { group in groupView(group) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, theme.z(22))
                .padding(.vertical, theme.z(18))
            }
        }
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.z(7)) {
            Text(group.area.rawValue)
                .font(theme.font(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, theme.z(1))
            ForEach(group.rows) { row in
                HStack(spacing: theme.z(10)) {
                    Text(row.title)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: theme.z(8))
                    KeyCaps(row.caps)
                }
            }
        }
    }

    /// Groups spread over three columns, keeping each column about the same height (rows per column).
    static func columns(_ groups: [ShortcutGroup], count: Int = 3) -> [[ShortcutGroup]] {
        var columns = Array(repeating: [ShortcutGroup](), count: count)
        var heights = Array(repeating: 0, count: count)
        for group in groups {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(group)
            heights[shortest] += group.rows.count + 2
        }
        return columns.filter { !$0.isEmpty }
    }
}
