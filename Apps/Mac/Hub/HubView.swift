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
    @State private var filter = HubFilter()
    @State private var archivingFinished = false
    @FocusState private var boardFocused: Bool
    @FocusState private var filterFocused: Bool

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
        let allSections = source.sections(now: now)
        let totalItemCount = allSections.reduce(0) { $0 + $1.items.count }
        let projects = projectOptions(from: allSections)
        let sections = filteredSections(from: allSections)
        let order = keyboardOrder(sections)
        let selected = snapshotOptions?.selection ?? selection
        return ScrollViewReader { proxy in
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(26)) {
                    VStack(alignment: .leading, spacing: theme.z(12)) {
                        HubTotals(sections: sections) { bucket in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("section-" + bucket.rawValue, anchor: .top) }
                        }
                        if totalItemCount >= 2 || filter.isActive {
                            HubTriageBar(
                                filter: $filter,
                                focused: $filterFocused,
                                projects: projects,
                                onExitSearch: {
                                    filterFocused = false
                                    if !isSnapshot { boardFocused = true }
                                }
                            )
                        }
                    }
                    if !filter.isActive && !allSections.contains(where: { $0.bucket == .needsYou }) {
                        HubEmptyNeedsYou(loaded: store.isLoaded)
                    }
                    if filter.isActive && sections.isEmpty {
                        HubEmptyFilterCard {
                            filter.clear()
                        }
                    }
                    ForEach(sections) { section in
                        sectionView(section.bucket, items: section.items, now: now, selected: selected)
                            .id("section-" + section.bucket.rawValue)
                    }
                }
                .frame(maxWidth: theme.z(Self.columnWidth), alignment: .leading)
                .padding(.top, theme.z(14))
                .padding(.bottom, theme.z(48))
                .modifier(AdaptiveInsetModifier(wide: 28, narrow: 16))
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
                if window.hubReplySessionID != nil {
                    window.closeHubReply()
                    return .handled
                }
                if filter.isActive {
                    filter.clear()
                    return .handled
                }
                return .ignored
            }
            .onAppear { if !isSnapshot { boardFocused = true } }
            .onChange(of: order) { _, ids in
                if let current = selection, !ids.contains(current) { selection = nil }
            }
            .onChange(of: projects) { _, currentProjects in
                guard let selectedDir = filter.selectedDirectory else { return }
                let normalized = HubFilter.normalizedDirectory(selectedDir)
                if !currentProjects.contains(where: { HubFilter.normalizedDirectory($0.directory) == normalized }) {
                    filter.selectedDirectory = nil
                }
            }
            .onChange(of: window.findRequestToken) {
                guard !isSnapshot, window.route == .hub else { return }
                filterFocused = true
            }
        }
        .background(theme.background)
    }

    // MARK: Filtering

    private func projectOptions(from sections: [HubBoardSection]) -> [HubProjectOption] {
        let entries: [HubProjectEntry] = sections.flatMap { section in
            section.items.compactMap { item -> HubProjectEntry? in
                let directory: String?
                if item.isRoom {
                    directory = item.roomID.flatMap { rooms?.state($0)?.spec.directory }
                } else {
                    directory = store.session(item.id)?.directory
                }
                guard let directory, !directory.isEmpty else { return nil }
                return HubProjectEntry(
                    directory: directory,
                    lastActivity: item.candidate.lastActivity,
                    needsYou: section.bucket == .needsYou
                )
            }
        }
        return HubFilter.projects(from: entries)
    }

    private func filteredSections(from sections: [HubBoardSection]) -> [HubBoardSection] {
        guard filter.isActive else { return sections }
        return sections.compactMap { section in
            let matched = section.items.filter { matchesFilter($0, bucket: section.bucket) }
            return matched.isEmpty ? nil : HubBoardSection(bucket: section.bucket, items: matched)
        }
    }

    private func matchesFilter(_ item: HubCardItem, bucket: HubBucket) -> Bool {
        if item.isRoom {
            guard let roomID = item.roomID, let room = rooms?.state(roomID) else { return false }
            let agentNames = room.spec.agents.map(\.name)
            let pendingAsk: String? = switch item.reason {
            case .permission(let request): request.title
            case .plan(let request): request.plan?.title ?? request.title
            case .question(let request): request.questions?.first?.text ?? request.title
            case .roomDecision(let decision):
                HubSorter.decisionText(decision, agentName: { id in room.spec.agents.first { $0.id == id }?.name })
            case .roomPaused: room.pauseReason
            default: nil
            }
            return filter.matches(
                title: room.spec.title,
                directory: room.spec.directory,
                pendingAsk: pendingAsk,
                agentNames: agentNames,
                bucket: bucket
            )
        } else {
            guard let session = store.session(item.id) else { return false }
            let roomAgentNames = (store.sessionAgentIDs[session.id] ?? []).compactMap { store.agents[$0]?.name }
            let agentNames = roomAgentNames.isEmpty ? [store.modelName(session.info.model)] : roomAgentNames
            let pendingAsk: String? = switch item.reason {
            case .permission(let request): request.title
            case .plan(let request): request.plan?.title ?? request.title
            case .question(let request): request.questions?.first?.text ?? request.title
            case .askedQuestion: HubText.lastWords(of: session.id, store: store)
            case .failed: HubText.failure(of: session.id, store: store)
            default: nil
            }
            return filter.matches(
                title: session.title,
                directory: session.directory,
                pendingAsk: pendingAsk,
                agentNames: agentNames,
                bucket: bucket
            )
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ bucket: HubBucket, items: [HubCardItem], now: Date, selected: String?) -> some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if bucket == .old {
                oldHeader(count: items.count)
            } else if bucket == .finished {
                finishedHeader(items: items)
            } else {
                HubSectionHeader(title: bucket.label, count: items.count)
            }
            if bucket != .old || oldExpanded || filter.isActive {
                VStack(alignment: .leading, spacing: theme.z(bucket == .old ? 2 : 10)) {
                    ForEach(items) { item in
                        card(item, now: now, selected: selected == item.id)
                            .id(item.id)
                    }
                }
            }
        }
    }

    private func finishedHeader(items: [HubCardItem]) -> some View {
        let archivableIDs: [String] = items.compactMap { item in
            guard !item.isRoom, let session = store.session(item.id), !session.info.archived else { return nil }
            return session.id
        }
        return HStack(spacing: theme.z(10)) {
            HubSectionHeader(title: HubBucket.finished.label, count: items.count)
            Spacer(minLength: theme.z(8))
            if !archivableIDs.isEmpty {
                HubArchiveAllButton(count: archivableIDs.count, isBusy: archivingFinished) {
                    archiveFinished(archivableIDs)
                }
            }
        }
    }

    private func archiveFinished(_ ids: [String]) {
        guard !archivingFinished, !ids.isEmpty else { return }
        archivingFinished = true
        Task {
            defer { archivingFinished = false }
            for id in ids {
                guard let session = store.session(id),
                      !session.isWorking,
                      session.pendingPermissions.isEmpty,
                      !session.info.archived else { continue }
                await store.archive(id, archived: true)
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
            // Every click in a card lands here, including a click in its message box. That click is to type,
            // so the keyboard stays with the box instead of going back to the list.
            let typingHere = window.hubReplySessionID != nil && window.hubReplySessionID == item.id
            if !isSnapshot, !typingHere { boardFocused = true }
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
        sections.filter { $0.bucket != .old || oldExpanded || filter.isActive }.flatMap { $0.items.map(\.id) }
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
                .lineLimit(1)
            Text("\(count)")
                .font(theme.font(size: 12).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
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
                HubTotalTile(bucket: bucket, count: count) { onSelect(bucket) }
            }
        }
    }
}

private struct HubTotalTile: View {
    let bucket: HubBucket
    let count: Int
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let highlighted = bucket == .needsYou && count > 0
        let activeHover = hovering && count > 0
        Button(action: action) {
            VStack(alignment: .leading, spacing: theme.z(4)) {
                Text(bucket.label)
                    .font(theme.font(size: 12))
                    .foregroundStyle(highlighted ? theme.accent : theme.textSecondary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(theme.font(size: 22, weight: .medium).monospacedDigit())
                    .foregroundStyle(highlighted ? theme.accent : theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, theme.z(14))
            .padding(.vertical, theme.z(11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .fill(fill(highlighted: highlighted, hovering: activeHover))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .strokeBorder(highlighted ? theme.accent.opacity(theme.isDark ? 0.35 : 0.3) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .onHover { hovering = $0 }
        .help(count == 0 ? bucket.label : "Show \(bucket.label)")
        .accessibilityLabel("\(bucket.label): \(count)")
    }

    private func fill(highlighted: Bool, hovering: Bool) -> Color {
        if highlighted {
            return theme.accent.opacity(theme.isDark ? (hovering ? 0.16 : 0.12) : (hovering ? 0.12 : 0.08))
        }
        return hovering ? theme.elevatedHover : theme.elevated
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

/// Live search and project filter bar under the Session Hub totals.
private struct HubTriageBar: View {
    @Binding var filter: HubFilter
    var focused: FocusState<Bool>.Binding
    let projects: [HubProjectOption]
    let onExitSearch: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(8)) {
                HStack(spacing: theme.z(7)) {
                    Image(systemName: "magnifyingglass")
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                    if isSnapshot {
                        Text(filter.query.isEmpty ? "Filter sessions and rooms" : filter.query)
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(filter.query.isEmpty ? theme.textTertiary : theme.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("", text: $filter.query,
                                  prompt: Text("Filter sessions and rooms").foregroundStyle(theme.textTertiary))
                            .textFieldStyle(.plain)
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textPrimary)
                            .focused(focused)
                            .onExitCommand {
                                if !filter.query.isEmpty {
                                    filter.query = ""
                                } else {
                                    onExitSearch()
                                }
                            }
                    }
                    if !filter.query.isEmpty {
                        Button {
                            filter.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search text")
                    }
                }
                .padding(.horizontal, theme.z(10))
                .frame(height: theme.z(30))
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                        .strokeBorder(focused.wrappedValue ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1)
                )

                if filter.isActive {
                    Button {
                        filter.clear()
                    } label: {
                        Text("Clear")
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, theme.z(10))
                            .frame(height: theme.z(30))
                            .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.accent.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.accent.opacity(0.3)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Clear all filters")
                }
            }

            if projects.count >= 2 {
                AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                    HStack(spacing: theme.z(6)) {
                        HubProjectPill(
                            label: "All",
                            count: nil,
                            needsYou: false,
                            selected: filter.selectedDirectory == nil
                        ) {
                            filter.selectedDirectory = nil
                        }
                        ForEach(projects) { option in
                            let selected = filter.selectedDirectory.map {
                                HubFilter.normalizedDirectory($0) == HubFilter.normalizedDirectory(option.directory)
                            } ?? false
                            HubProjectPill(
                                label: option.label,
                                count: option.count,
                                needsYou: option.needsYouCount > 0,
                                selected: selected
                            ) {
                                filter.selectedDirectory = selected ? nil : option.directory
                            }
                        }
                    }
                    .padding(.vertical, theme.z(1))
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct HubProjectPill: View {
    let label: String
    let count: Int?
    let needsYou: Bool
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(5)) {
                if needsYou {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: theme.z(5.5), height: theme.z(5.5))
                }
                Text(label)
                    .font(theme.font(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? theme.textPrimary : (hovering ? theme.textPrimary : theme.textSecondary))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(theme.font(size: 11).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(25))
            .background(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .fill(selected ? theme.selection : (hovering ? theme.elevatedHover : theme.elevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .strokeBorder(selected ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

private struct HubArchiveAllButton: View {
    let count: Int
    let isBusy: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(5)) {
                Image(systemName: "archivebox")
                    .font(theme.font(size: 10.5))
                Text(isBusy ? "Archiving..." : "Archive all (\(count))")
                    .font(theme.font(size: 11.5, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(hovering && !isBusy ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, theme.z(8))
            .frame(height: theme.z(23))
            .background(
                RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                    .fill(hovering && !isBusy ? theme.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .help("Archive all finished sessions")
        .accessibilityLabel("Archive all \(count) finished sessions")
    }
}

private struct HubEmptyFilterCard: View {
    let onClear: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(12)) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textTertiary)
            Text("No sessions match this filter")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: theme.z(8))
            Button("Clear filters", action: onClear)
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.separator))
    }
}
