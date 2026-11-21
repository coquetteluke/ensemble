import SwiftUI
import AppKit
import EnsembleKit

/// Left sidebar: New session, Session Hub, Scheduled, search, pinned sessions, rooms, the session list (grouped by
/// project, state or date), Settings. Rows show a needs-you badge, a working spinner, or a failed, unread or
/// completed mark. Option-click or Open in Split shows a session beside the one on screen.
struct SidebarView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    /// Rooms; nil before the app has made the controller.
    var rooms: RoomsController?
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
    /// The user's own folder order (`AttentionSettings.sidebarFolderOrder`), kept in step with UserDefaults.
    @State private var savedFolderOrder = AttentionSettings.sidebarFolderOrder
    /// The folder header being dragged, and the folder it would land next to.
    @State private var draggingFolder: String?
    @State private var folderDropTarget: String?
    /// Watches for the end of a folder drag (`beginFolderDrag`).
    @State private var folderDragWatch: Task<Void, Never>?

    private var attention: AttentionCenter { injectedAttention ?? .shared }
    private var grouping: SidebarGrouping { groupingOverride ?? SidebarGrouping(rawValue: groupingRaw) ?? .project }
    private var sort: SidebarSort { SidebarSort(rawValue: sortRaw) ?? .recent }
    /// Snapshots always show the automatic order.
    private var folderOrder: [String] { isSnapshot ? [] : savedFolderOrder }

    var body: some View {
        let snapshots = store.attentionSnapshots()
        let allEntries = store.sidebarEntries(snapshots: snapshots, marks: attention.marks)
        let entries = allEntries.filter { $0.matches(window.searchText) }
        let arrangement = SidebarArrangement.arrange(entries, grouping: grouping, sort: sort, parents: store.sessionParents,
                                                     folderOrder: folderOrder)
        let prompts = Dictionary(snapshots.map { ($0.id, $0.prompts.count) }, uniquingKeysWith: { a, _ in a })
        // Folder moves work on every folder, also those a search hides.
        let folders = grouping != .project ? [] : window.searchText.isEmpty ? arrangement.groups.map(\.id)
            : SidebarArrangement.arrange(allEntries, grouping: .project, sort: sort, folderOrder: folderOrder).groups.map(\.id)

        VStack(alignment: .leading, spacing: 0) {
            // Title bar area: traffic lights and the sidebar toolbar button live here.
            Color.clear.frame(height: 52)

            VStack(spacing: theme.z(1)) {
                SidebarNavRow(symbol: "plus", title: "New session", accentIcon: true, shortcut: "\u{2318}N") {
                    window.beginNewSession()
                }
                // The Hub's Needs you count: open prompts, plans and questions, failed turns and closing questions,
                // and rooms waiting on a decision (room agents' sessions count inside their room).
                SidebarNavRow(symbol: "square.grid.2x2", title: "Session Hub", selected: window.route == .hub,
                              badge: HubBoardSource(store: store, marks: attention.marks, rooms: rooms).needsYouCount()) {
                    window.route = .hub
                }
                SidebarNavRow(symbol: "clock", title: "Scheduled", selected: window.route == .scheduled,
                              trailing: (ScheduleCenter.shared.scheduler?.activeTaskCount).flatMap { $0 > 0 ? "\($0)" : nil }) {
                    window.route = .scheduled
                }
            }
            .padding(.horizontal, theme.z(8))

            InputField("Search sessions", text: $window.searchText, icon: "magnifyingglass", height: 28)
                .overlay(alignment: .trailing) {
                    if !window.searchText.isEmpty && !isSnapshot {
                        Button {
                            window.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textTertiary)
                                .padding(theme.z(4))
                                .background(Circle().fill(theme.sidebar))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, theme.z(5))
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, theme.z(10))
                .padding(.top, theme.z(12))
                .padding(.bottom, theme.z(4))

            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(14)) {
                    if !arrangement.pinnedRows.isEmpty {
                        pinnedSection(arrangement.pinnedRows, prompts: prompts)
                    }
                    if let rooms, showsRooms(rooms) {
                        RoomsSidebarSection(controller: rooms, search: window.searchText, isShowingRoom: window.route == .room,
                                            onSelect: { window.openRoom($0, rooms: rooms) },
                                            onNewRoom: { rooms.beginNewRoom() },
                                            collapsed: isCollapsed("rooms"), onToggle: { toggle("rooms") })
                    }
                    if !arrangement.groups.isEmpty || (store.isLoaded && !store.projects.isEmpty) {
                        sessionsSection(arrangement.groups, folders: folders, prompts: prompts)
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
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            let stored = AttentionSettings.sidebarFolderOrder
            if stored != savedFolderOrder { savedFolderOrder = stored }
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

    private func pinnedSection(_ rows: [SidebarTreeRow], prompts: [String: Int]) -> some View {
        let collapsed = isCollapsed("pinned")
        return VStack(alignment: .leading, spacing: theme.z(1)) {
            SidebarSectionHeader(title: "Pinned", collapsed: collapsed, onToggle: { toggle("pinned") }) {
                EmptyView()
            }
            if !collapsed {
                ForEach(SidebarTree.visible(rows, folded: foldedLinks)) { row in
                    sessionRow(row, prompts: prompts[row.id] ?? 0, showsFolder: true)
                }
            }
        }
    }

    private func sessionsSection(_ groups: [SidebarGroup], folders: [String], prompts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            SidebarSectionHeader(title: "Sessions", collapsed: nil, onToggle: {}) {
                GroupAndSortMenu(grouping: $groupingRaw, sort: $sortRaw,
                                 hasManualFolderOrder: !folderOrder.isEmpty,
                                 onClearFolderOrder: { saveFolderOrder([]) })
            }
            VStack(alignment: .leading, spacing: theme.z(14)) {
                ForEach(groups) { group in
                    groupSection(group, folders: folders, prompts: prompts)
                }
            }
        }
    }

    private func groupSection(_ group: SidebarGroup, folders: [String], prompts: [String: Int]) -> some View {
        let collapsed = isCollapsed(group.id)
        let movable = grouping == .project && !isSnapshot
        let section = VStack(alignment: .leading, spacing: theme.z(1)) {
            switch group.kind {
            case .project(let directory):
                SidebarGroupHeader(icon: .symbol("folder"), title: group.title, help: Format.abbreviatedPath(directory),
                                   collapsed: collapsed, onToggle: { toggle(group.id) },
                                   onNew: { window.beginNewSession(in: directory) },
                                   move: movable ? SidebarGroupHeader.Move(
                                       canMoveUp: SidebarFolderOrder.canMove(group.id, by: -1, shown: folders),
                                       canMoveDown: SidebarFolderOrder.canMove(group.id, by: 1, shown: folders),
                                       onMove: { step in moveFolder(group.id, by: step, folders: folders) },
                                       onDragStart: { beginFolderDrag(group.id) }) : nil)
            case .state(let state):
                SidebarGroupHeader(icon: stateIcon(state), title: group.title, help: nil,
                                   collapsed: collapsed, onToggle: { toggle(group.id) })
            case .date:
                SidebarGroupHeader(icon: .symbol("calendar"), title: group.title, help: nil,
                                   collapsed: collapsed, onToggle: { toggle(group.id) })
            }
            if !collapsed {
                ForEach(SidebarTree.visible(group.rows, folded: foldedLinks)) { row in
                    sessionRow(row, prompts: prompts[row.id] ?? 0, showsFolder: grouping != .project)
                }
            }
        }
        return section
            .overlay(alignment: dropsAfter(group.id, folders: folders) ? .bottom : .top) {
                if folderDropTarget == group.id, draggingFolder != nil, draggingFolder != group.id {
                    Capsule()
                        .fill(theme.accent)
                        .frame(height: theme.z(2))
                        .padding(.horizontal, theme.z(6))
                        .offset(y: theme.z(dropsAfter(group.id, folders: folders) ? 8 : -8))
                        .allowsHitTesting(false)
                }
            }
            .modifier(FolderDropModifier(enabled: movable, delegate: FolderDropDelegate(
                target: group.id, dragging: $draggingFolder, dropTarget: $folderDropTarget,
                onDrop: { dragged in
                    let after = dropsAfter(group.id, dragged: dragged, folders: folders)
                    saveFolderOrder(SidebarFolderOrder.moving(dragged, to: group.id, after: after, shown: folders, saved: folderOrder))
                })))
    }

    /// Remembers which folder is being dragged, and forgets it when the mouse button comes up. A drag that ends
    /// without a drop (released over the chat, or Escape) tells nobody, and a folder left "being dragged" would make
    /// the next unrelated drag of some text over the sidebar look like a folder move.
    private func beginFolderDrag(_ folder: String) {
        draggingFolder = folder
        folderDropTarget = nil
        folderDragWatch?.cancel()
        folderDragWatch = Task { @MainActor in
            // The press that started the drag is still down; give it a moment to be seen, then wait for the release.
            try? await Task.sleep(for: .milliseconds(150))
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // A drop on a folder is handled first (`FolderDropDelegate.performDrop`); this clears what is left.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            draggingFolder = nil
            folderDropTarget = nil
        }
    }

    /// A folder dragged down lands after the folder it is dropped on; dragged up, before it.
    private func dropsAfter(_ target: String, dragged: String? = nil, folders: [String]) -> Bool {
        guard let dragged = dragged ?? draggingFolder, let from = folders.firstIndex(of: dragged),
              let to = folders.firstIndex(of: target) else { return false }
        return from < to
    }

    private func moveFolder(_ folder: String, by step: Int, folders: [String]) {
        saveFolderOrder(SidebarFolderOrder.moving(folder, by: step, shown: folders, saved: folderOrder))
    }

    private func saveFolderOrder(_ order: [String]) {
        guard !isSnapshot else { return }
        savedFolderOrder = order
        AttentionSettings.sidebarFolderOrder = order
    }

    /// Sessions whose linked sessions are folded away (ignored while searching, like folded groups).
    private var foldedLinks: Set<String> {
        guard window.searchText.isEmpty else { return [] }
        return Set(window.collapsedProjects.compactMap { key in
            key.hasPrefix(Self.linksKeyPrefix) ? String(key.dropFirst(Self.linksKeyPrefix.count)) : nil
        })
    }

    /// Fold keys for linked sessions share `collapsedProjects` with folder paths; folder paths start with "/".
    static let linksKeyPrefix = "links:"

    /// The Rooms section shows once rooms have loaded; while searching, only when a room matches.
    private func showsRooms(_ rooms: RoomsController) -> Bool {
        rooms.isLoaded && (window.searchText.isEmpty || !RoomsSidebarSection.matching(rooms.rooms, window.searchText).isEmpty)
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
    private func sessionRow(_ row: SidebarTreeRow, prompts: Int, showsFolder: Bool) -> some View {
        let entry = row.entry
        let foldKey = Self.linksKeyPrefix + entry.id
        if let session = store.session(entry.id) {
            let selectedID = store.selected.map { $0.info.parentID ?? $0.id }
            let colors = (store.sessionAgentIDs[session.id] ?? []).compactMap { store.agents[$0] }.map { Color(hexString: $0.colorHex) }
            SessionRow(session: session,
                       selected: window.route == .session && selectedID == session.id,
                       status: entry.status,
                       needsYou: prompts,
                       folder: showsFolder ? Format.folderName(session.directory) : nil,
                       agentColors: colors,
                       depth: row.depth,
                       linksFolded: row.hasChildren ? isCollapsed(foldKey) : nil,
                       onToggleLinks: { toggle(foldKey) }) {
                // Option-click opens it beside the session on screen (split view).
                if NSEvent.modifierFlags.contains(.option), window.canOpenBeside(session.id, store: store) {
                    window.openBeside(session.id, store: store)
                } else {
                    window.open(session.id, store: store)
                }
            }
            .contextMenu { rowMenu(session, entry: entry) }
        }
    }

    @ViewBuilder
    private func rowMenu(_ session: SessionModel, entry: SidebarEntry) -> some View {
        let id = session.id
        Button(window.split.contains(sessionID: id) ? "Show in Split" : "Open in Split") { window.openBeside(id, store: store) }
            .disabled(!window.canOpenBeside(id, store: store))
        Divider()
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
        Button("Copy as Markdown") {
            let id = session.id
            Task {
                if !session.transcriptLoaded { await store.loadSession(id) }
                guard let current = store.session(id) else { return }
                let markdown = TranscriptExport.markdown(
                    title: current.title,
                    directory: current.directory,
                    modelName: store.modelName(current.info.model),
                    items: current.items,
                    agents: store.agents,
                    attachments: current.attachments
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
            }
        }
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
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, theme.z(8))
                .frame(height: theme.z(30))
            }
            .buttonStyle(RowButtonStyle(cornerRadius: theme.z(7)))
            .help("Settings (Command-,)")
            .layoutPriority(1)

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
                    .lineLimit(1)
                Spacer(minLength: theme.z(4))
                if badge > 0 {
                    CountBadge(badge)
                        .fixedSize()
                } else if let shortcut, hovering {
                    Text(shortcut)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize()
                } else if let trailing {
                    Text(trailing)
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, theme.z(8))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: theme.z(7)))
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
    /// How many linked-session levels the row sits under (indented one step per level).
    var depth = 0
    /// nil when no sessions are nested under this one; otherwise whether they are folded away.
    var linksFolded: Bool?
    var onToggleLinks: () -> Void = {}
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    /// Indent per linked-session level; deeper levels stop indenting so titles keep room in a narrow sidebar.
    static let indentStep: CGFloat = 18
    static let maxIndentLevels = 6

    var body: some View {
        let dotRing = selected ? theme.selection : (hovering ? theme.hover : theme.sidebar)
        let indent = theme.z(35 + Self.indentStep * CGFloat(min(depth, Self.maxIndentLevels)))
        Button(action: action) {
            HStack(spacing: theme.z(8)) {
                if !agentColors.isEmpty {
                    HStack(spacing: theme.z(-2)) {
                        ForEach(Array(agentColors.prefix(4).enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: theme.z(7), height: theme.z(7))
                                .overlay(Circle().stroke(dotRing, lineWidth: theme.z(1.5)))
                        }
                    }
                    .fixedSize()
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
                if let linksFolded {
                    linksChevron(folded: linksFolded)
                        .padding(.leading, theme.z(-5))
                }
                Spacer(minLength: theme.z(6))
                trailing
                    .fixedSize()
            }
            .padding(.leading, indent)
            .padding(.trailing, theme.z(10))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: theme.z(7)))
        .onHover { hovering = $0 }
        .help(Format.abbreviatedPath(session.directory))
        .accessibilityLabel(accessibilityText)
        .modifier(LinksAccessibilityAction(folded: linksFolded, action: onToggleLinks))
    }

    /// The small chevron after the title of a session that has linked sessions: down when they show, right when folded.
    private func linksChevron(folded: Bool) -> some View {
        Button(action: onToggleLinks) {
            Image(systemName: folded ? "chevron.right" : "chevron.down")
                .font(theme.font(size: 9, weight: .bold))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(16), height: theme.z(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Self.linksLabel(folded: folded))
        .accessibilityLabel(Self.linksLabel(folded: folded))
    }

    static func linksLabel(folded: Bool) -> String {
        folded ? "Show linked sessions" : "Hide linked sessions"
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
                .lineLimit(1)
        }
    }

    /// A dot centred where the badge and spinner sit, so marks line up down the list.
    private func mark(_ color: Color) -> some View {
        StatusDot(color, size: 7)
            .frame(width: theme.z(17), height: theme.z(17))
    }

    private var accessibilityText: String {
        var parts = [session.title]
        if depth > 0 { parts.append("linked session") }
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

/// Lets VoiceOver show or hide a row's linked sessions without finding the small chevron.
private struct LinksAccessibilityAction: ViewModifier {
    let folded: Bool?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let folded {
            content.accessibilityAction(named: Text(SessionRow.linksLabel(folded: folded)), action)
        } else {
            content
        }
    }
}

/// Drops a dragged folder header onto another folder's group (grouping by project only).
/// A folder's group takes folder drops only when folders can move (grouping by project, not in snapshots, which cannot
/// draw drop targets).
private struct FolderDropModifier: ViewModifier {
    let enabled: Bool
    let delegate: FolderDropDelegate

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.text], delegate: delegate)
        } else {
            content
        }
    }
}

private struct FolderDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var dropTarget: String?
    let onDrop: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        dropTarget = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragging == target ? .cancel : .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragging = nil
            dropTarget = nil
        }
        guard let dragged = dragging, dragged != target else { return false }
        withAnimation(.easeOut(duration: 0.15)) { onDrop(dragged) }
        return true
    }
}
