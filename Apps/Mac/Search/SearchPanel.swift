import SwiftUI
import EnsembleKit

/// Command-K: search session titles and transcript text across every session and engine. Results are grouped by
/// session with highlighted snippets; Return opens the session scrolled to the message.
struct SearchPanel: View {
    @Bindable var search: SearchCenter
    let store: SessionStore
    let window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var contentHeight: CGFloat = 0

    static let width: CGFloat = 660

    var body: some View {
        OverlayCard(width: Self.width) {
            VStack(spacing: 0) {
                OverlayField(symbol: "magnifyingglass", placeholder: "Search sessions and messages", text: $search.query)
                filters
                HLine(color: theme.border.opacity(0.7))
                results
                HLine(color: theme.border.opacity(0.7))
                footer
            }
        }
        .onChange(of: search.indexer?.generation) { search.refresh() }
    }

    // MARK: Filters

    private var filters: some View {
        HStack(spacing: theme.z(6)) {
            ForEach(TranscriptSearchFilter.allCases, id: \.self) { filter in
                let enabled = filter != .folder || search.currentFolder != nil
                Button {
                    search.filter = filter
                } label: {
                    Text(filter.label)
                        .font(theme.font(size: 12, weight: search.filter == filter ? .medium : .regular))
                        .foregroundStyle(search.filter == filter ? theme.textPrimary : (enabled ? theme.textSecondary : theme.textTertiary))
                        .padding(.horizontal, theme.z(10))
                        .frame(height: theme.z(24))
                        .background(Capsule().fill(search.filter == filter ? theme.raisedSelection : .clear))
                        .overlay(Capsule().strokeBorder(search.filter == filter ? theme.border : theme.border.opacity(0.6)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(filter == .folder ? (search.currentFolder.map { "Only sessions in \(Format.abbreviatedPath($0))" } ?? "Open a session to search its folder")
                                        : filter == .archived ? "Only archived sessions" : "Every session, archived ones included")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.z(14))
        .padding(.bottom, theme.z(10))
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        let rows = search.rows
        if search.results.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .frame(height: theme.z(150))
        } else if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { resultRows(rows) }
                .padding(.vertical, theme.z(6))
                .frame(maxHeight: theme.z(470), alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { resultRows(rows) }
                        .padding(.vertical, theme.z(6))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, theme.z(60)), theme.z(470)))
                .onChange(of: search.selection) {
                    guard rows.indices.contains(search.selection) else { return }
                    proxy.scrollTo(rows[search.selection].id)
                }
            }
        }
    }

    @ViewBuilder private func resultRows(_ rows: [SearchCenter.Row]) -> some View {
        let selectedID = rows.indices.contains(search.selection) ? rows[search.selection].id : nil
        let isEmptyQuery = TranscriptSearchQuery(search.query).isEmpty
        if isEmptyQuery {
            sectionLabel("Recent sessions")
        }
        ForEach(search.results) { result in
            let header = SearchCenter.Row(sessionID: result.id, itemID: nil)
            SessionResultRow(result: result, selected: selectedID == header.id)
                .id(header.id)
                .onTapGesture { search.open(header, window: window) }
            ForEach(result.matches) { match in
                let row = SearchCenter.Row(sessionID: result.id, itemID: match.itemID)
                MatchResultRow(match: match, selected: selectedID == row.id)
                    .id(row.id)
                    .onTapGesture { search.open(row, window: window) }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, theme.z(18))
            .padding(.top, theme.z(4))
            .padding(.bottom, theme.z(4))
    }

    @ViewBuilder private var emptyState: some View {
        let query = search.query.trimmingCharacters(in: .whitespaces)
        VStack(spacing: theme.z(6)) {
            if query.isEmpty {
                Text(search.filter == .archived ? "No archived sessions" : "No sessions yet")
                    .font(theme.font(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else if search.hasSearched {
                Text("No matches for \u{201C}\(query)\u{201D}")
                    .font(theme.font(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                if search.filter != .all {
                    Button("Search all sessions") { search.filter = .all }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: theme.z(14)) {
            if let indexer = search.indexer, indexer.pendingCount > 0 {
                HStack(spacing: theme.z(6)) {
                    Spinner(size: 9)
                    Text("Indexing \(indexer.pendingCount) more \(indexer.pendingCount == 1 ? "session" : "sessions")")
                }
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            hint(["\u{2191}", "\u{2193}"], "Select")
            hint(["\u{21A9}"], "Open")
            hint(["\u{21E5}"], "Filter")
        }
        .padding(.horizontal, theme.z(14))
        .frame(height: theme.z(34))
    }

    private func hint(_ caps: [String], _ label: String) -> some View {
        HStack(spacing: theme.z(5)) {
            KeyCaps(caps)
            Text(label)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
        }
    }
}

/// A session in the results: title with matches marked, folder and age, archived mark.
private struct SessionResultRow: View {
    let result: TranscriptSearchResult
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Image(systemName: result.session.archived ? "archivebox" : "bubble.left")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(18))
            Text(HighlightedText.attributed(result.title.text, highlights: result.title.highlights, base: theme.textPrimary,
                                            emphasis: theme.textPrimary, background: theme.accent.opacity(0.28),
                                            font: theme.font(size: 13.5, weight: .medium), emphasisFont: theme.font(size: 13.5, weight: .semibold)))
                .lineLimit(1)
                .truncationMode(.tail)
            if result.session.archived {
                Text("Archived")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, theme.z(6))
                    .frame(height: theme.z(17))
                    .background(Capsule().strokeBorder(theme.border))
            }
            Spacer(minLength: theme.z(12))
            if result.matchCount > result.matches.count {
                Text("\(result.matchCount) matches")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            Text("\(Format.folderName(result.session.directory)) \u{00B7} \(age)")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .help(Format.abbreviatedPath(result.session.directory))
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(34))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(selected ? theme.raisedSelection : (hovering ? theme.raisedHover : .clear)))
        .padding(.horizontal, theme.z(8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var age: String {
        let relative = Format.relative(result.session.updated)
        return relative == "now" ? "now" : relative + " ago"
    }
}

/// A matched message under its session: who wrote it and the snippet with the matches marked.
private struct MatchResultRow: View {
    let match: TranscriptSearchMatch
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(14))
            Text(HighlightedText.attributed(match.snippet.text, highlights: match.snippet.highlights, base: theme.textSecondary,
                                            emphasis: theme.textPrimary, background: theme.accent.opacity(0.24),
                                            font: snippetFont, emphasisFont: snippetFont))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, theme.z(38))
        .padding(.trailing, theme.z(12))
        .padding(.vertical, theme.z(6))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(selected ? theme.raisedSelection : (hovering ? theme.raisedHover : .clear)))
        .padding(.horizontal, theme.z(8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(roleLabel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(roleLabel): \(match.snippet.text)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var snippetFont: Font {
        match.role == .tool ? theme.font(size: 12, design: .monospaced) : theme.font(size: 12.5)
    }

    private var symbol: String {
        switch match.role {
        case .user: "person"
        case .agent: "sparkle"
        case .tool: "terminal"
        case .error: "exclamationmark.triangle"
        case .board: "bubble.left.and.bubble.right"
        }
    }

    private var roleLabel: String {
        switch match.role {
        case .user: "Your message"
        case .agent: "Agent message"
        case .tool: "Tool call"
        case .error: "Error"
        case .board: "Board message"
        }
    }
}
