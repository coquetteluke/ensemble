import SwiftUI
import EnsembleKit

/// Left sidebar: New session, Session Hub, Scheduled, search, pinned sessions, the session list (grouped by
/// project, state or date), Settings. Rows show a needs-you badge, a working spinner, or a failed, unread or
/// completed mark.
struct SidebarView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    /// Snapshots pass a fixed grouping; the app uses the saved choice.
    var groupingOverride: SidebarGrouping?
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isSnapshot) private var isSnapshot
    /// Snapshots inject their own; the app uses `AttentionCenter.shared`.
    @Environment(AttentionCenter.self) private var injectedAttention: AttentionCenter?

    @AppStorage(AttentionSettings.Key.sidebarGrouping) private var groupingRaw = SidebarGrouping.project.rawValue
    @AppStorage(AttentionSettings.Key.sidebarSort) private var sortRaw = SidebarSort.recent.rawValue

    @State private var renaming: SessionModel?
    @State private var renameText = ""
    @State private var deleting: SessionModel?

    private var attention: AttentionCenter { injectedAttention ?? .shared }
    private var grouping: SidebarGrouping { groupingOverride ?? SidebarGrouping(rawValue: groupingRaw) ?? .project }
    private var sort: SidebarSort { SidebarSort(rawValue: sortRaw) ?? .recent }

    var body: some View {
        let snapshots = store.attentionSnapshots()
        let entries = store.sidebarEntries(snapshots: snapshots, marks: attention.marks).filter { $0.matches(window.searchText) }
        let arrangement = SidebarArrangement.arrange(entries, grouping: grouping, sort: sort)
        let prompts = Dictionary(snapshots.map { ($0.id, $0.prompts.count) }, uniquingKeysWith: { a, _ in a })

        VStack(alignment: .leading, spacing: 0) {
            // Title bar area: traffic lights and the sidebar toolbar button live here.
            Color.clear.frame(height: 52)

            VStack(spacing: theme.z(1)) {
                SidebarNavRow(symbol: "plus", title: "New session", accentIcon: true, shortcut: "\u{2318}N") {
                    window.beginNewSession()
                }
                SidebarNavRow(symbol: "square.grid.2x2", title: "Session Hub", selected: window.route == .hub,
                              badge: store.needsYouTotal) {
                    window.route = .hub
                }
                SidebarNavRow(symbol: "clock", title: "Scheduled", selected: window.route == .scheduled,
                              trailing: store.schedules.isEmpty ? nil : "\(store.schedules.filter { !$0.paused }.count)") {
                    window.route = .scheduled
                }
            }
            .padding(.horizontal, theme.z(8))

            InputField("Search sessions", text: $window.searchText, icon: "magnifyingglass", height: theme.z(28))
                .padding(.horizontal, theme.z(10))
                .padding(.top, theme.z(12))
                .padding(.bottom, theme.z(4))

            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(14)) {
                    if !arrangement.pinned.isEmpty {
                        pinnedSection(arrangement.pinned, prompts: prompts)
                    }
                    if !arrangement.groups.isEmpty || (store.isLoaded && !store.projects.isEmpty) {
                        sessionsSection(arrangement.groups, prompts: prompts)
                    }
                    if arrangement.isEmpty && store.isLoaded {
                        Text(window.searchText.isEmpty ? "No sessions yet" : "No matches")
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, theme.z(10))
                            .padding(.top, theme.z(8))
                    }
                }
                .padding(.horizontal, theme.z(8))
                .padding(.top, theme.z(10))
                .padding(.bottom, theme.z(16))
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HLine()
            footer
        }
        .background(theme.sidebar)
        .background {
            if !isSnapshot { AttentionWindowReader { attention.registerMainWindow($0) } }
        }
        .task(id: ObjectIdentifier(store)) {
            guard !isSnapshot else { return }
            attention.registerOpenWindow { openWindow(id: "main") }
            attention.attach(store: store, window: window)
        }
        .alert("Rename session", isPresented: renameShown) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let session = renaming { Task { await store.rename(session.id, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this session?", isPresented: deleteShown, presenting: deleting) { session in
            Button("Delete \"\(session.title)\"", role: .destructive) {
                let id = session.id
                Task {
                    await store.delete(id)
                    if store.session(id) == nil { attention.forget(id) }
                }
                deleting = nil
            }
        } message: { _ in
            Text("The transcript is removed from the engine. This cannot be undone.")
        }
    }

    // MARK: Sections

    private func pinnedSection(_ entries: [SidebarEntry], prompts: [String: Int]) -> some View {
        let collapsed = isCollapsed("pinned")
        return VStack(alignment: .leading, spacing: theme.z(1)) {
            SidebarSectionHeader(title: "Pinned", collapsed: collapsed, onToggle: { toggle("pinned") }) {
                EmptyView()
            }
            if !collapsed {
                ForEach(entries) { entry in
                    sessionRow(entry, prompts: prompts[entry.id] ?? 0, showsFolder: true)
                }
            }
        }
    }

    private func sessionsSection(_ groups: [SidebarGroup], prompts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            SidebarSectionHeader(title: "Sessions", collapsed: nil, onToggle: {}) {
                GroupAndSortMenu(grouping: $groupingRaw, sort: $sortRaw)
            }
            VStack(alignment: .leading, spacing: theme.z(14)) {
                ForEach(groups) { group in
                    groupSection(group, prompts: prompts)
                }
            }
        }
    }

    private func groupSection(_ group: SidebarGroup, prompts: [String: Int]) -> some View {
        let collapsed = isCollapsed(group.id)
        return VStack(alignment: .leading, spacing: theme.z(1)) {
            switch group.kind {
            case .project(let directory):
                SidebarGroupHeader(icon: .symbol("folder"), title: group.title, help: Format.abbreviatedPath(directory),
                                   collapsed: collapsed, onToggle: { toggle(group.id) },
                                   onNew: { window.beginNewSession(in: directory) })
            case .state(let state):
                SidebarGroupHeader(icon: stateIcon(state), title: group.title, help: nil,
                                   collapsed: collapsed, onToggle: { toggle(group.id) })
            case .date:
                SidebarGroupHeader(icon: .symbol("calendar"), title: group.title, help: nil,
                                   collapsed: collapsed, onToggle: { toggle(group.id) })
            }
            if !collapsed {
                ForEach(group.entries) { entry in
                    sessionRow(entry, prompts: prompts[entry.id] ?? 0, showsFolder: grouping != .project)
                }
            }
        }
    }

    private func stateIcon(_ state: SidebarStateGroup) -> SidebarGroupHeader.Icon {
        switch state {
        case .needsYou: .dot(theme.accent)
        case .running: .symbol("circle.dotted")
        case .unread: .dot(theme.contextBlue)
        case .idle: .dot(theme.textTertiary.opacity(0.6))
        case .completed: .symbol("checkmark")
        }
    }

    private func isCollapsed(_ id: String) -> Bool {
        window.collapsedProjects.contains(id) && window.searchText.isEmpty
    }

    private func toggle(_ id: String) {
        if window.collapsedProjects.contains(id) { window.collapsedProjects.remove(id) } else { window.collapsedProjects.insert(id) }
    }

    // MARK: Rows

    @ViewBuilder
    private func sessionRow(_ entry: SidebarEntry, prompts: Int, showsFolder: Bool) -> some View {
        if let session = store.session(entry.id) {
            let selectedID = store.selected.map { $0.info.parentID ?? $0.id }
            let colors = (store.sessionAgentIDs[session.id] ?? []).compactMap { store.agents[$0] }.map { Color(hexString: $0.colorHex) }
            SessionRow(session: session,
                       selected: window.route == .session && selectedID == session.id,
                       status: entry.status,
                       needsYou: prompts,
                       folder: showsFolder ? Format.folderName(session.directory) : nil,
                       agentColors: colors) {
                window.open(session.id, store: store)
            }
            .contextMenu { rowMenu(session, entry: entry) }
        }
    }

    @ViewBuilder
    private func rowMenu(_ session: SessionModel, entry: SidebarEntry) -> some View {
        let id = session.id
        Button(entry.pinned ? "Unpin" : "Pin") { attention.setPinned(id, !entry.pinned) }
        Button("Rename") {
            renameText = session.title
            renaming = session
        }
        Divider()
        if attention.marks.isUnread(id) {
            Button("Mark as read") { attention.setUnread(id, false) }
        } else {
            Button("Mark as unread") { attention.setUnread(id, true) }
        }
        if attention.marks.isCompleted(id) {
            Button("Mark as not completed") { attention.setCompleted(id, false) }
        } else {
            Button("Mark as completed") { attention.setCompleted(id, true) }
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
        }
        Divider()
        Button("Archive") { Task { await store.archive(id) } }
        Button("Delete", role: .destructive) { deleting = session }
        Divider()
        PowerMenuItems(holder: .session(id))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: theme.z(6)) {
            Button {
                openSettings()
            } label: {
                HStack(spacing: theme.z(9)) {
                    Image(systemName: "gearshape")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: theme.z(18))
                    Text("Settings")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textSidebar)
                }
                .padding(.horizontal, theme.z(8))
                .frame(height: theme.z(30))
            }
            .buttonStyle(RowButtonStyle())
            .help("Settings (Command-,)")

            Spacer(minLength: theme.z(4))

            HStack(spacing: theme.z(6)) {
                StatusDot(engineColor, size: 6)
                Text(engineLabel)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .help(store.isPreview ? "Using built-in sample data. No engine is connected." : "OpenCode engine")
            .padding(.trailing, theme.z(6))
        }
        .padding(.horizontal, theme.z(8))
        .padding(.vertical, theme.z(8))
    }

    private var engineLabel: String {
        if store.isPreview { return "Preview data" }
        if let version = store.engineVersion { return "Engine \(version)" }
        return "Engine offline"
    }

    private var engineColor: Color {
        if store.isPreview { return theme.warning }
        return store.engineVersion == nil ? theme.danger : theme.success
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil && !isSnapshot }, set: { if !$0 { renaming = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil && !isSnapshot }, set: { if !$0 { deleting = nil } })
    }
}

/// New session, Session Hub and Scheduled rows.
struct SidebarNavRow: View {
    let symbol: String
    let title: String
    var selected = false
    var accentIcon = false
    var badge = 0
    var trailing: String?
    var shortcut: String?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(9)) {
                if accentIcon {
                    Image(systemName: symbol)
                        .font(theme.font(size: 10, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: theme.z(18), height: theme.z(18))
                        .background(Circle().fill(theme.accent))
                } else {
                    Image(systemName: symbol)
                        .font(theme.font(size: 13))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .frame(width: theme.z(18))
                }
                Text(title)
                    .font(theme.font(size: 13, weight: accentIcon ? .medium : .regular))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSidebar)
                Spacer(minLength: theme.z(4))
                if badge > 0 {
                    CountBadge(badge)
                } else if let shortcut, hovering {
                    Text(shortcut)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                } else if let trailing {
                    Text(trailing)
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, theme.z(8))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .onHover { hovering = $0 }
    }
}

/// One session in the sidebar: agent dots, title (and its folder when the list is not grouped by project),
/// then one mark: a needs-you badge, the working spinner, a red failed dot, a blue unread dot, a completed
/// check, or the age.
struct SessionRow: View {
    let session: SessionModel
    let selected: Bool
    let status: SidebarRowStatus
    let needsYou: Int
    var folder: String?
    let agentColors: [Color]
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(8)) {
                if !agentColors.isEmpty {
                    HStack(spacing: theme.z(-2)) {
                        ForEach(Array(agentColors.prefix(4).enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: theme.z(7), height: theme.z(7))
                                .overlay(Circle().stroke(selected ? theme.selection : theme.sidebar, lineWidth: 1.5))
                        }
                    }
                }
                // The folder shows only when it fits whole next to the whole title; otherwise the title alone.
                ViewThatFits(in: .horizontal) {
                    if let folder {
                        HStack(spacing: theme.z(6)) {
                            title
                            Text(folder)
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                        .fixedSize()
                    }
                    title
                }
                Spacer(minLength: theme.z(6))
                trailing
            }
            .padding(.leading, theme.z(30))
            .padding(.trailing, theme.z(10))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .help(Format.abbreviatedPath(session.directory))
        .accessibilityLabel(accessibilityText)
    }

    private var title: some View {
        Text(session.title)
            .font(theme.font(size: 13))
            .foregroundStyle(titleColor)
            .lineLimit(1)
    }

    private var titleColor: Color {
        if selected { return theme.textPrimary }
        return status == .completed ? theme.textTertiary : theme.textSidebar
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .needsYou:
            CountBadge(max(needsYou, 1))
        case .running:
            Spinner(size: 11)
                .frame(width: theme.z(17))
        case .failed:
            mark(theme.danger)
        case .unread:
            mark(theme.contextBlue)
        case .completed:
            Image(systemName: "checkmark")
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(17))
        case .idle:
            Text(Format.relative(session.info.updated))
                .font(theme.font(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
        }
    }

    /// A dot centred where the badge and spinner sit, so marks line up down the list.
    private func mark(_ color: Color) -> some View {
        StatusDot(color, size: 7)
            .frame(width: theme.z(17), height: theme.z(17))
    }

    private var accessibilityText: String {
        var parts = [session.title]
        if let folder { parts.append(folder) }
        switch status {
        case .needsYou: parts.append(needsYou == 1 ? "1 waiting for you" : "\(needsYou) waiting for you")
        case .running: parts.append("running")
        case .failed: parts.append("failed")
        case .unread: parts.append("unread")
        case .completed: parts.append("completed")
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }
}
