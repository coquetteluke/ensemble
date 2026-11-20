import SwiftUI
import AppKit
import EnsembleKit

/// The main window: sidebar, centre (transcript and composer, two to four sessions side by side, a room, or Hub /
/// Scheduled), and the right-hand pane (context panel, file or review), which follows the focused split pane.
struct MainView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    /// Rooms; nil before the app has made the controller.
    var rooms: RoomsController?
    /// Search, command palette, shortcut list and file links for this window (the app passes its own).
    var search = SearchCenter()
    /// Snapshots pass a fixed value; the app uses the stored setting.
    var remoteControlOverride: Bool?

    @AppStorage("remoteControlEnabled") private var remoteControl = false
    @AppStorage(Zoom.storageKey) private var zoom = 1.0
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.openSettings) private var openSettings
    @State private var showPromoteSheet = false
    @State private var promotingToRoom = false

    static let sidebarWidth: CGFloat = 260
    static let panelWidth: CGFloat = 303
    /// The narrowest the centre gets when a wide pane (file viewer, review) opens on the right.
    static let centreMinWidth: CGFloat = 400
    /// Room the window's six toolbar buttons (background, changes, browser, terminal, customizations, context panel)
    /// take at the top right, when no pane is open.
    static let toolbarButtonsWidth: CGFloat = 246

    /// Snapshots pass a fixed zoom; the app uses the stored View > Zoom setting.
    var zoomOverride: CGFloat?
    /// Snapshots pass the file viewer's content, since they cannot wait for it to load.
    var snapshotFileContent: FileViewerContent?
    /// Snapshots pass a ready review, since they cannot wait for git.
    var snapshotReview: ReviewModel?

    var body: some View {
        content
            .ensembleTheme()
            .environment(\.zoom, zoomOverride ?? CGFloat(Zoom.clamped(zoom)))
            .onAppear {
                // File links open in this window's right-hand pane; the palette's New room uses the rooms.
                search.window = window
                search.rooms = rooms
                if !isSnapshot { window.installZoomShortcut() }
            }
    }

    private var content: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if window.showSidebar {
                    SidebarView(store: store, window: window, rooms: rooms)
                        .frame(width: theme.z(Self.sidebarWidth))
                        .transition(.move(edge: .leading))
                    VLine()
                }
                CenterColumn(store: store, window: window, rooms: rooms)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsSidePane {
                    VLine()
                    sidePane
                        .frame(width: sidePaneWidth(windowWidth: proxy.size.width))
                        .frame(maxHeight: proxy.size.height, alignment: .top)
                        .clipped()
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(theme.background)
        .overlay(alignment: .topLeading) { if isSnapshot { SnapshotWindowChrome(window: window) } }
        .ignoresSafeArea()
        .environment(\.transcriptActions, actions)
        .searchLayer(search, store: store, window: window)
        .powerSessionSync(store: store)
        // Snapshots of each session's folder as its turns start, for the review pane's per-turn filter.
        .task(id: ObjectIdentifier(store)) { if !isSnapshot { ReviewCenter.shared.follow(store) } }
        .modifier(RoomsWindowSync(store: store, window: window, rooms: rooms))
        .modifier(SplitWindowSync(store: store, window: window))
        .modifier(BrowserWindowSync(store: store))
        .modifier(AgentToolsWindowSync(store: store, window: window))
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                IconButton("sidebar.left", help: window.showSidebar ? "Hide sidebar" : "Show sidebar", size: 28) {
                    window.toggleSidebar()
                }
            }
            .sharedBackgroundVisibility(.hidden)
            // The six window buttons sit at the top right, where the title row leaves room for them
            // (`toolbarButtonsWidth`). `.primaryAction` would put them on the leading edge, over the title.
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
                BackgroundToolbarButton(store: store, window: window, rooms: rooms)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .automatic) {
                ReviewToolbarButton(isOpen: window.reviewOpen) { window.toggleReview() }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .automatic) {
                BrowserToolbarButton(isOpen: window.browserOpen) { window.toggleBrowser() }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .automatic) {
                TerminalToolbarButton(isOpen: window.terminalOpen) { window.toggleTerminal() }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .automatic) {
                IconButton("puzzlepiece.extension", help: "Customizations: what each agent loads in this folder", size: 28) {
                    CustomizationsFocus.shared.show(folder: currentFolder)
                    openSettings()
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .automatic) {
                IconButton("sidebar.right", help: window.contextPanelVisible ? "Hide context panel (Option-Command-I)" : "Show context panel (Option-Command-I)",
                           size: 28, active: window.contextPanelVisible) {
                    window.toggleContextPanel()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $window.showNewSession) {
            NewSessionSheet(store: store, window: window)
                .ensembleTheme()
        }
        .sheet(isPresented: $showPromoteSheet) {
            if let session = store.selected, let activeRooms {
                PromoteToRoomSheet(
                    store: store,
                    session: session,
                    rooms: activeRooms,
                    isCreating: $promotingToRoom
                ) { roomID in
                    window.openRoom(roomID, rooms: activeRooms)
                }
                .ensembleTheme()
            }
        }
        .background { if !isSnapshot { commandShortcuts } }
        .onReceive(NotificationCenter.default.publisher(for: .ensemblePromoteToRoom)) { _ in
            openPromoteSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ensembleCopyTranscriptMarkdown)) { _ in
            copyTranscriptMarkdown()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ensembleFindInCurrentView)) { _ in
            window.findRequestToken &+= 1
        }
        .claudeImport(store: store)
        .alert("Something went wrong", isPresented: errorShown, presenting: store.lastError) { _ in
            Button("OK") { store.lastError = nil }
        } message: { message in
            Text(message)
        }
        .alert(trustTitle, isPresented: trustShown, presenting: store.pendingFolderTrust) { pending in
            Button("Trust and Start") {
                Task { await ModelSwitcher.trustAndRetry(pending, store: store, window: window) }
            }
            Button("Cancel", role: .cancel) { store.pendingFolderTrust = nil }
        } message: { pending in
            Text(Self.trustMessage(pending))
        }
    }

    private var activeRooms: RoomsController? {
        rooms ?? RoomsController.live ?? AgentToolsCenter.shared.rooms
    }

    private var commandShortcuts: some View {
        ZStack {
            Button("Switch model") {
                if window.route == .session, store.selected != nil { window.requestedMenu = .model }
            }
            .appShortcut(.switchModel)
            Button("Open Session Hub") {
                window.route = .hub
            }
            .appShortcut(.openHub)
            Button("Focus composer") {
                if window.route == .session, store.selected != nil { window.composerFocusToken &+= 1 }
            }
            .appShortcut(.focusComposer)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func openPromoteSheet() {
        guard window.route == .session, let session = store.selected,
              !session.isSubagent, store.sessionAgentIDs[session.id] == nil,
              store.models.filter(\.available).count >= 2,
              activeRooms != nil, !promotingToRoom else { return }
        showPromoteSheet = true
    }

    private func copyTranscriptMarkdown() {
        let markdown: String
        if window.route == .room, let engine = activeRooms?.selectedEngine {
            let agentsByID = Dictionary(engine.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let items: [TranscriptItem] = engine.state.board.map { message in
                switch message.from {
                case .user:
                    .user(id: message.id.uuidString, text: message.text, date: message.date)
                case .agent(let agentID):
                    if message.to.isEmpty {
                        .agentText(id: message.id.uuidString, text: message.text, agentID: agentID, streaming: false)
                    } else {
                        .board(id: message.id.uuidString, fromAgentID: agentID, toAgentIDs: message.to, text: message.text, date: message.date)
                    }
                case .room:
                    .notice(id: message.id.uuidString, text: message.text)
                }
            }
            markdown = TranscriptExport.markdown(
                title: engine.state.spec.title,
                directory: engine.state.spec.directory,
                modelName: nil,
                items: items,
                agents: agentsByID
            )
        } else if window.route == .session, let session = store.selected {
            markdown = TranscriptExport.markdown(
                title: session.title,
                directory: session.directory,
                modelName: store.modelName(session.info.model),
                items: session.items,
                agents: store.agents
            )
        } else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private var trustShown: Binding<Bool> {
        Binding(get: { store.pendingFolderTrust != nil && !isSnapshot }, set: { if !$0 { store.pendingFolderTrust = nil } })
    }

    private var trustTitle: String {
        store.pendingFolderTrust?.onlyThisFolder == true ? "Trust your home folder?" : "Trust this folder?"
    }

    static func trustMessage(_ pending: PendingFolderTrust) -> String {
        let folder = Format.abbreviatedPath(pending.folder)
        let reason = "\(pending.modelName) loads a folder's own settings, hooks and MCP servers, so it only starts in folders you trust."
        if pending.onlyThisFolder {
            return reason + " Only \(folder) itself is trusted, not the folders inside it. You can remove it in Settings, General."
        }
        return reason + " Trusting \(folder) also trusts the folders inside it. You can remove it in Settings, General."
    }

    /// The right-hand pane: always for a session; elsewhere only a file or review pane (a room shows its own panel
    /// in place of the context panel).
    private var showsSidePane: Bool {
        guard window.showContextPanel else { return false }
        return window.route == .session || window.sidePane != .context
    }

    /// The one place the right-hand pane is drawn. The file viewer and review pane plug in here.
    @ViewBuilder private var sidePane: some View {
        switch window.sidePane {
        case .context:
            ContextPanelView(store: store, session: store.selected, remoteControl: remoteControlBinding)
        case .file(let path, let line):
            FileViewerPane(link: search.filePreview ?? FileLink(path: path, line: line), base: paneBaseDirectory,
                           onClose: { window.closeSidePane() }, content: snapshotFileContent)
                .id(path)
        case .review:
            if let snapshotReview {
                ReviewPane(model: snapshotReview, topInset: 52, onClose: { window.closeSidePane() })
            } else if window.route == .room, let room = rooms?.selectedEngine {
                ReviewPane(store: store, room: room, topInset: 52, onClose: { window.closeSidePane() })
                    .id(room.state.id)
            } else if let session = store.selected {
                ReviewPane(store: store, session: session, topInset: 52, onClose: { window.closeSidePane() })
                    .id(session.id)
            } else {
                SidePanePlaceholder(symbol: "plus.forwardslash.minus", title: "Changes", detail: "No session selected") {
                    window.closeSidePane()
                }
            }
        case .browser:
            if window.route != .room, let session = store.selected {
                BrowserPane(page: BrowserCenter.shared.page(for: session), store: store, session: session,
                            onClose: { window.closeSidePane() })
                    .id(session.id)
            } else {
                SidePanePlaceholder(symbol: "globe", title: "Browser",
                                    detail: window.route == .room ? "The browser works in a session, not in a room" : "No session selected") {
                    window.closeSidePane()
                }
            }
        case .terminal:
            TerminalPane(store: store, rooms: rooms, route: window.route, onClose: { window.closeSidePane() })
        }
    }

    /// The folder on screen, for Customizations: the room's in a room, else the selected (focused) session's.
    private var currentFolder: String? {
        if window.route == .room, let room = rooms?.selectedEngine { return room.state.spec.directory }
        return store.selected?.directory
    }

    /// The folder file paths in the pane are shown relative to: the room's folder in a room, else the session's.
    private var paneBaseDirectory: String {
        if window.route == .room, let room = rooms?.selectedEngine { return room.state.spec.directory }
        return store.selected?.directory ?? ""
    }

    /// The pane's own width, narrowed (down to the context panel's width) so the centre keeps
    /// `centreMinWidth` when the window is small or zoomed in.
    private func sidePaneWidth(windowWidth: CGFloat) -> CGFloat {
        let wanted = theme.z(window.sidePane.width)
        let sidebar = window.showSidebar ? theme.z(Self.sidebarWidth) : 0
        let room = windowWidth - sidebar - theme.z(Self.centreMinWidth)
        return max(theme.z(Self.panelWidth), min(wanted, room))
    }

    private var windowTitle: String {
        if window.route == .room, let room = rooms?.selectedEngine { return room.state.spec.title }
        return store.selected?.title ?? "Ensemble"
    }

    private var remoteControlBinding: Binding<Bool> {
        if let remoteControlOverride { return .constant(remoteControlOverride) }
        return $remoteControl
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { store.lastError != nil && !isSnapshot }, set: { if !$0 { store.lastError = nil } })
    }

    private var actions: TranscriptActions {
        guard let session = store.selected else { return TranscriptActions(openSession: { [window, store] id in window.open(id, store: store) },
                                                                          historySupported: store.supportsHistory) }
        return Self.transcriptActions(store: store, session: session, window: window, paneWindow: window, ownsShortcuts: true)
    }

    /// What a transcript's buttons do for `session`. `paneWindow` is the state of the composer showing it (a split
    /// pane's own state, else the window's); subagent links open in that pane. Only the session that `ownsShortcuts`
    /// answers Command-Y, Option-Command-Y and Command-period, so two panes never share a prompt's keys.
    static func transcriptActions(store: SessionStore, session: SessionModel, window: WindowState, paneWindow: WindowState,
                                  ownsShortcuts: Bool) -> TranscriptActions {
        let sessionID = session.id
        return TranscriptActions(
            openSession: { id in paneWindow.open(id, store: store) },
            replyPermission: { request, decision in Task { await store.reply(to: request, decision: decision) } },
            fork: { messageID in
                Task {
                    if await store.fork(sessionID, atMessageID: messageID) != nil { window.composerFocusToken &+= 1 }
                }
            },
            rewind: { messageID in
                store.beginRewind(sessionID, messageID: messageID)
            },
            edit: { messageID in
                Task {
                    if let text = await store.editMessage(sessionID, messageID: messageID) {
                        paneWindow.drafts[sessionID] = text
                        paneWindow.composerFocusToken &+= 1
                    }
                }
            },
            historySupported: store.supportsHistory,
            workingAgentName: session.isWorking ? agentName(for: session, store: store) : nil,
            shortcutPermissionID: ownsShortcuts ? session.pendingPermissions.last?.id : nil
        )
    }

    /// The working agent's name: the room agent, or the model.
    private static func agentName(for session: SessionModel, store: SessionStore) -> String {
        if let id = session.agentID, let agent = store.agents[id] { return agent.name }
        return store.modelName(session.info.model)
    }
}

/// Centre column: header, then the conversation, a room, or a placeholder screen.
struct CenterColumn: View {
    let store: SessionStore
    @Bindable var window: WindowState
    var rooms: RoomsController?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // A room draws its own header (title, mode, phase, Pause, Stop, Take over); split panes draw one each.
            if window.route != .room && !showsSplit { CenterHeader(store: store, window: window, rooms: rooms) }
            switch window.route {
            case .session:
                if showsSplit {
                    SplitSessionsView(store: store, window: window)
                } else if let session = store.selected {
                    ConversationView(store: store, session: session, window: window)
                } else {
                    EmptySessionView(store: store, window: window)
                }
            case .hub:
                HubView(store: store, window: window, rooms: rooms)
            case .scheduled:
                ScheduledView(store: store, window: window)
            case .usage:
                UsageScreen(store: store)
            case .room:
                if let rooms, let engine = rooms.selectedEngine {
                    RoomView(controller: rooms, engine: engine,
                             leadingInset: window.showSidebar ? 0 : 110,
                             trailingInset: window.showContextPanel ? 0 : MainView.toolbarButtonsWidth,
                             showsSidePanel: window.contextPanelVisible,
                             openSession: { id in window.open(id, store: store) })
                        .environment(\.interactionStore, store)
                        .id(engine.state.id)
                } else {
                    NoRoomView(rooms: rooms)
                }
            }
        }
        .background(theme.background)
    }

    private var showsSplit: Bool { window.route == .session && window.split.isActive }
}

/// Shown for the room route when no room is open (it was deleted, or rooms are still loading).
struct NoRoomView: View {
    let rooms: RoomsController?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.z(14)) {
            Color.clear.frame(height: 52)
            Spacer()
            Image(systemName: "person.3")
                .font(theme.font(size: 28, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("No room selected")
                .font(theme.font(size: 15, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            if let rooms {
                Button("New room") { rooms.beginNewRoom() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right-hand pane for a file or review view that is not built yet: what it is for and a close button.
struct SidePanePlaceholder: View {
    let symbol: String
    let title: String
    let detail: String?
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(0)) {
            // The window's toolbar button sits in this strip.
            Color.clear.frame(height: 52)
            HStack(spacing: theme.z(8)) {
                Image(systemName: symbol)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Text(title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(4))
                IconButton("xmark", help: "Close", size: 24, action: onClose)
            }
            .padding(.horizontal, theme.z(14))
            if let detail {
                Text(detail)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, theme.z(14))
                    .padding(.top, theme.z(4))
            }
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
    }
}

/// Split view upkeep: restores the window's saved layout once sessions load, keeps the focused pane on the selected
/// session, and drops panes whose sessions were deleted or archived.
private struct SplitWindowSync: ViewModifier {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        content
            .onChange(of: store.isLoaded, initial: true) { _, loaded in
                // Sample data keeps its own layout, so its sessions never land in the real one.
                if loaded && !isSnapshot { window.restoreSplit(store: store, key: AppEngine.usePreview ? "preview" : "main") }
            }
            .onChange(of: store.selectedSessionID) { _, id in window.followSelection(id) }
            .onChange(of: paneSessionsValid) { _, _ in window.pruneSplit(store: store) }
    }

    /// One flag per pane: its session still exists and is not archived.
    private var paneSessionsValid: [Bool] {
        window.split.panes.map { pane in store.session(pane.sessionID).map { !$0.info.archived } ?? false }
    }
}

/// Room upkeep for the main window: the new room sheet, room agents' names and colours in the session list, the
/// room route when its room goes away, room errors, and Keep awake for running rooms.
private struct RoomsWindowSync: ViewModifier {
    let store: SessionStore
    @Bindable var window: WindowState
    let rooms: RoomsController?
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if let rooms {
            content
                .sheet(isPresented: Bindable(rooms).showNewRoom) {
                    NewRoomSheet(controller: rooms, recentFolders: store.projects.map(\.directory)) { id in
                        window.openRoom(id, rooms: rooms)
                    }
                    .ensembleTheme()
                }
                .onChange(of: rooms.roomSessionIDs, initial: true) { rooms.syncAgents(into: store) }
                .onChange(of: rooms.selectedRoomID) { _, id in
                    if id == nil, window.route == .room { window.route = .session }
                }
                .alert("Something went wrong", isPresented: errorShown(rooms), presenting: rooms.lastError) { _ in
                    Button("OK") { rooms.lastError = nil }
                } message: { message in
                    Text(message)
                }
                .powerRoomSync(working: Set(rooms.rooms.map(\.id).filter { rooms.isRunning($0) }),
                               existing: rooms.isLoaded ? Set(rooms.rooms.map(\.id)) : nil)
        } else {
            content
        }
    }

    private func errorShown(_ rooms: RoomsController) -> Binding<Bool> {
        Binding(get: { rooms.lastError != nil && !isSnapshot }, set: { if !$0 { rooms.lastError = nil } })
    }
}

/// Title row in the window's title bar area.
struct CenterHeader: View {
    let store: SessionStore
    @Bindable var window: WindowState
    var rooms: RoomsController? = nil
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showPromoteSheet = false
    @State private var promotingToRoom = false

    private var activeRooms: RoomsController? {
        rooms ?? RoomsController.live ?? AgentToolsCenter.shared.rooms
    }

    private func addAgentDisabled(for session: SessionModel) -> Bool {
        store.models.filter(\.available).count < 2 || promotingToRoom || activeRooms == nil
    }

    var body: some View {
        HStack(spacing: theme.z(8)) {
            if !window.showSidebar {
                Color.clear.frame(width: 110, height: 1)
            }
            switch window.route {
            case .session:
                if let session = store.selected {
                    if let parentID = session.info.parentID, let parent = store.session(parentID) {
                        Button {
                            window.open(parent.id, store: store)
                        } label: {
                            HStack(spacing: theme.z(4)) {
                                Image(systemName: "chevron.left").font(theme.font(size: 10, weight: .semibold))
                                Text(parent.title).lineLimit(1)
                            }
                            .font(theme.font(size: 13))
                            .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        Text("/").foregroundStyle(theme.textTertiary)
                        Image(systemName: "person.2.fill")
                            .font(theme.font(size: 10))
                            .foregroundStyle(theme.accent)
                    }
                    Text(session.title)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(Format.abbreviatedPath(session.directory))
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    SessionGoalPill(store: store, sessionID: session.id)
                }
            case .hub:
                Text("Session Hub").font(theme.font(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            case .scheduled:
                Text("Scheduled").font(theme.font(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            case .usage:
                Text("Usage").font(theme.font(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            case .room:
                EmptyView()
            }
            Spacer(minLength: theme.z(12))
            if window.route == .session, let session = store.selected {
                if !session.isSubagent, store.sessionAgentIDs[session.id] == nil, !isSnapshot {
                    let disabled = addAgentDisabled(for: session)
                    Button {
                        if activeRooms != nil { showPromoteSheet = true }
                    } label: {
                        HStack(spacing: theme.z(5)) {
                            Image(systemName: "person.badge.plus")
                                .font(theme.font(size: 11, weight: .medium))
                            Text(promotingToRoom ? "Creating..." : "Add agent")
                                .font(theme.font(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(disabled)
                    .help(disabled ? "Needs at least 2 available models" : "Add agents and continue in a room")
                }
                // Room for the window's toolbar button when no pane is open on the right.
                TranscriptViewModeMenu()
                    .padding(.trailing, window.showContextPanel ? theme.z(12) : MainView.toolbarButtonsWidth)
            }
        }
        .padding(.leading, theme.z(20))
        .frame(height: 52)
        .background(theme.background)
        .zIndex(1)
        .sheet(isPresented: $showPromoteSheet) {
            if let session = store.selected, let activeRooms {
                PromoteToRoomSheet(
                    store: store,
                    session: session,
                    rooms: activeRooms,
                    isCreating: $promotingToRoom
                ) { roomID in
                    window.openRoom(roomID, rooms: activeRooms)
                }
                .ensembleTheme()
            }
        }
    }
}

/// Shown when no session is selected.
struct EmptySessionView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.z(14)) {
            Image(systemName: "square.and.pencil")
                .font(theme.font(size: 28, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text(store.isLoaded ? "No session selected" : "Loading sessions")
                .font(theme.font(size: 15, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            if store.isLoaded {
                Button("New session") { window.beginNewSession() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Traffic lights and toolbar buttons drawn into snapshots (real windows draw their own).
struct SnapshotWindowChrome: View {
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
            Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
            Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 22)
        }
        .padding(.leading, 20)
        .frame(height: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            HStack(spacing: 22) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 14))
                    .foregroundStyle(window.reviewOpen ? theme.textPrimary : theme.textSecondary)
                Image(systemName: "globe")
                    .font(.system(size: 14))
                    .foregroundStyle(window.browserOpen ? theme.textPrimary : theme.textSecondary)
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundStyle(window.terminalOpen ? theme.textPrimary : theme.textSecondary)
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundStyle(window.contextPanelVisible ? theme.textPrimary : theme.textSecondary)
            }
            .padding(.trailing, 20)
        }
        .allowsHitTesting(false)
    }
}
