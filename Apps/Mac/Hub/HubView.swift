import SwiftUI
import EnsembleKit

/// The Session Hub: every session and room sorted into Needs you, Running, Finished and Old, with what each waits on and
/// the answers that fit in place (Allow once or Reject a short command, answer a question, Proceed or Keep planning,
/// reply, mark completed, archive). Up and Down move between cards, Return opens one, Command-Return sends the open
/// reply. Updates live.
struct HubView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    var rooms: RoomsController?

    @Environment(\.hubSnapshotOptions) private var snapshotOptions
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    /// Snapshots inject their own; the app uses `AttentionCenter.shared`.
    @Environment(AttentionCenter.self) private var injectedAttention: AttentionCenter?
    @AppStorage("hubShowOld") private var showOldStored = false
    @AppStorage("hubShowArchived") private var showArchivedStored = false
    @State private var selection: String?
    @FocusState private var boardFocused: Bool

    static let columnWidth: CGFloat = 860

    private var attention: AttentionCenter { injectedAttention ?? .shared }
    private var oldExpanded: Bool { snapshotOptions?.oldExpanded ?? showOldStored }
    private var showArchived: Bool { snapshotOptions?.showArchived ?? showArchivedStored }

    var body: some View {
        if isSnapshot || snapshotOptions != nil {
            board(now: snapshotOptions?.now ?? Date())
        } else {
            // Ages and the 3- and 7-day windows move on by themselves.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                board(now: context.date)
            }
        }
    }

    private func board(now: Date) -> some View {
        let source = HubBoardSource(store: store, marks: attention.marks, rooms: rooms, showArchived: showArchived)
        let sections = source.sections(now: now)
        let order = keyboardOrder(sections)
        let selected = snapshotOptions?.selection ?? selection
        return ScrollViewReader { proxy in
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(26)) {
                    HubTotals(sections: sections) { bucket in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("section-" + bucket.rawValue, anchor: .top) }
                    }
                    if !sections.contains(where: { $0.bucket == .needsYou }) {
                        HubEmptyNeedsYou(loaded: store.isLoaded)
                    }
                    ForEach(sections) { section in
                        sectionView(section.bucket, items: section.items, now: now, selected: selected)
                            .id("section-" + section.bucket.rawValue)
                    }
                }
                .frame(maxWidth: theme.z(Self.columnWidth), alignment: .leading)
                .padding(.horizontal, theme.z(28))
                .padding(.top, theme.z(14))
                .padding(.bottom, theme.z(48))
                .frame(maxWidth: .infinity)
            }
            .focusable(!isSnapshot)
            .focused($boardFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: order, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: order, proxy: proxy) }
            .onKeyPress(.return) {
                guard let id = selection, let item = sections.flatMap(\.items).first(where: { $0.id == id }) else { return .ignored }
                open(item)
                return .handled
            }
            .onKeyPress(.escape) {
                guard window.hubReplySessionID != nil else { return .ignored }
                window.closeHubReply()
                return .handled
            }
            .onAppear { if !isSnapshot { boardFocused = true } }
            .onChange(of: order) { _, ids in
                if let current = selection, !ids.contains(current) { selection = nil }
            }
        }
        .background(theme.background)
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ bucket: HubBucket, items: [HubCardItem], now: Date, selected: String?) -> some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if bucket == .old {
                oldHeader(count: items.count)
            } else {
                HubSectionHeader(title: bucket.label, count: items.count)
            }
            if bucket != .old || oldExpanded {
                VStack(alignment: .leading, spacing: theme.z(bucket == .old ? 2 : 10)) {
                    ForEach(items) { item in
                        card(item, now: now, selected: selected == item.id)
                            .id(item.id)
                    }
                }
            }
        }
    }

    private func oldHeader(count: Int) -> some View {
        HStack(spacing: theme.z(10)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showOldStored.toggle() }
            } label: {
                HStack(spacing: theme.z(6)) {
                    Image(systemName: "chevron.right")
                        .font(theme.font(size: 9, weight: .bold))
                        .rotationEffect(.degrees(oldExpanded ? 90 : 0))
                        .frame(width: theme.z(10))
                    HubSectionHeader(title: HubBucket.old.label, count: count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help(oldExpanded ? "Hide old sessions" : "Show old sessions")
            Spacer(minLength: theme.z(8))
            if oldExpanded {
                Toggle("Show archived", isOn: Binding(get: { showArchived }, set: { showArchivedStored = $0 }))
                    .toggleStyle(CompactSwitchStyle())
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func card(_ item: HubCardItem, now: Date, selected: Bool) -> some View {
        let select = {
            selection = item.id
            if !isSnapshot { boardFocused = true }
        }
        if item.isRoom {
            if let rooms, let roomID = item.roomID, let room = rooms.state(roomID) {
                if item.bucket == .old {
                    HubOldRow(item: item, title: room.spec.title, directory: room.spec.directory, date: item.candidate.lastActivity,
                              now: now, selected: selected, onOpen: { open(item) }, onSelect: select)
                } else {
                    HubRoomCard(rooms: rooms, room: room, item: item, now: now, selected: selected, attention: attention,
                                onOpen: { open(item) }, onSelect: select)
                }
            }
        } else if let session = store.session(item.id) {
            if item.bucket == .old {
                HubOldRow(item: item, title: session.title, directory: session.directory, date: session.info.updated, now: now,
                          selected: selected, onOpen: { open(item) }, onSelect: select,
                          onArchive: { archived in Task { await store.archive(session.id, archived: archived) } })
            } else {
                HubSessionCard(store: store, window: window, session: session, item: item, now: now, selected: selected,
                               attention: attention, onOpen: { open(item) }, onSelect: select)
            }
        }
    }

    // MARK: Keyboard

    /// Cards in the order Up and Down move through (Old only while it is shown).
    private func keyboardOrder(_ sections: [HubBoardSection]) -> [String] {
        sections.filter { $0.bucket != .old || oldExpanded }.flatMap { $0.items.map(\.id) }
    }

    private func move(_ step: Int, in order: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let next: String
        if let current = selection, let index = order.firstIndex(of: current) {
            next = order[min(max(index + step, 0), order.count - 1)]
        } else {
            next = step > 0 ? order[0] : order[order.count - 1]
        }
        selection = next
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(next) }
        return .handled
    }

    /// Opens a card: the session (Option: beside the one on screen) or the room.
    private func open(_ item: HubCardItem) {
        if let roomID = item.roomID, let rooms {
            window.openRoom(roomID, rooms: rooms)
        } else if NSEvent.modifierFlags.contains(.option), window.canOpenBeside(item.id, store: store) {
            window.openBeside(item.id, store: store)
        } else {
            window.open(item.id, store: store)
        }
    }
}

/// Fixed state for Session Hub snapshots: the time, the selected card, and whether Old and archived sessions show.
struct HubSnapshotOptions {
    var now: Date
    var selection: String?
    var oldExpanded = true
    var showArchived = true
}

extension EnvironmentValues {
    @Entry var hubSnapshotOptions: HubSnapshotOptions? = nil
}

/// Section title with its count.
struct HubSectionHeader: View {
    let title: String
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(7)) {
            Text(title)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("\(count)")
                .font(theme.font(size: 12).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The three counts at the top: Needs you, Running, Finished. Each scrolls to its section.
private struct HubTotals: View {
    let sections: [HubBoardSection]
    let onSelect: (HubBucket) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            ForEach([HubBucket.needsYou, .running, .finished], id: \.self) { bucket in
                let count = sections.first { $0.bucket == bucket }?.items.count ?? 0
                Button { onSelect(bucket) } label: {
                    VStack(alignment: .leading, spacing: theme.z(4)) {
                        Text(bucket.label)
                            .font(theme.font(size: 12))
                            .foregroundStyle(tint(bucket, count) ?? theme.textSecondary)
                        Text("\(count)")
                            .font(theme.font(size: 22, weight: .medium).monospacedDigit())
                            .foregroundStyle(tint(bucket, count) ?? theme.textPrimary)
                    }
                    .padding(.horizontal, theme.z(14))
                    .padding(.vertical, theme.z(11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(fill(bucket, count)))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border.opacity(0.7)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .help(count == 0 ? bucket.label : "Show \(bucket.label)")
                .accessibilityLabel("\(bucket.label): \(count)")
            }
        }
    }

    private func tint(_ bucket: HubBucket, _ count: Int) -> Color? {
        guard count > 0 else { return nil }
        switch bucket {
        case .needsYou: return theme.accent
        case .running, .finished, .old: return nil
        }
    }

    private func fill(_ bucket: HubBucket, _ count: Int) -> Color {
        bucket == .needsYou && count > 0 ? theme.accent.opacity(theme.isDark ? 0.12 : 0.08) : theme.elevated
    }
}

/// Shown in place of the Needs you section when nothing waits on the user.
private struct HubEmptyNeedsYou: View {
    let loaded: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Image(systemName: loaded ? "checkmark.circle" : "hourglass")
                .font(theme.font(size: 14))
                .foregroundStyle(loaded ? theme.success : theme.textTertiary)
            Text(loaded ? "Nothing is waiting on you." : "Loading sessions")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, theme.z(2))
    }
}
