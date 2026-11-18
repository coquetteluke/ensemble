import SwiftUI
import EnsembleKit

/// What the centre of the window shows.
enum Route: Hashable {
    case session
    case hub
    case scheduled
    /// Usage across sessions, providers and agents (`UsageScreen`).
    case usage
    /// The room `RoomsController.selectedRoomID` names.
    case room
}

/// What the right-hand pane shows while it is open.
enum SidePane: Hashable {
    /// The context panel for a session; a room shows its own panel (agents, pieces, rounds).
    case context
    /// A file, scrolled to a line when given.
    case file(path: String, line: Int?)
    /// The review pane (changes of the session or room).
    case review
    /// The browser (`BrowserPane`), with the session's dev servers.
    case browser
    /// Terminal tabs in the session's (or room's) folder (`TerminalPane`).
    case terminal

    /// Width before zoom.
    var width: CGFloat {
        switch self {
        case .context: 303
        case .file: FileViewerPane.width
        case .review: 560
        case .browser: BrowserPane.width
        case .terminal: TerminalPane.width
        }
    }
}

/// Window-level UI state that is not engine data: panels, drafts, sheets, search, split panes.
///
/// In split view each pane gets its own `WindowState` (`paneState(_:)`) so its composer has its own focus, menus and
/// usage popover; everything else (route, panels, drafts, sheets) a pane state reads and writes on the window's state
/// (`host`). The window's state hands composer focus, menus and the usage popover on to the focused pane.
@Observable @MainActor
final class WindowState {
    /// On a split pane's own state: the window's state, which keeps everything but the pane's composer focus, menus and
    /// usage popover.
    @ObservationIgnored private(set) weak var host: WindowState?
    /// On a split pane's own state: which pane it is.
    @ObservationIgnored let paneID: UUID?

    init() {
        paneID = nil
    }

    private init(paneOf host: WindowState, paneID: UUID) {
        self.host = host
        self.paneID = paneID
    }

    private var routeValue: Route = .session
    var route: Route {
        get { host?.route ?? routeValue }
        set { if let host { host.route = newValue } else { routeValue = newValue } }
    }

    private var showSidebarValue = true
    var showSidebar: Bool {
        get { host?.showSidebar ?? showSidebarValue }
        set { if let host { host.showSidebar = newValue } else { showSidebarValue = newValue } }
    }

    private var showContextPanelValue: Bool = UserDefaults.standard.object(forKey: "showContextPanel") as? Bool ?? true
    /// Whether the right-hand pane is open. Option-Command-I opens and closes it with the context panel in it.
    var showContextPanel: Bool {
        get { host?.showContextPanel ?? showContextPanelValue }
        set { if let host { host.showContextPanel = newValue } else { showContextPanelValue = newValue } }
    }

    private var sidePaneValue: SidePane = .context
    /// What the right-hand pane shows (`showContextPanel` says whether it is open). It follows the focused split pane.
    var sidePane: SidePane {
        get { host?.sidePane ?? sidePaneValue }
        set { if let host { host.sidePane = newValue } else { sidePaneValue = newValue } }
    }

    /// Whether the context panel was open before a file or review pane replaced it.
    @ObservationIgnored private var contextWasOpen = true

    private var showNewSessionValue = false
    var showNewSession: Bool {
        get { host?.showNewSession ?? showNewSessionValue }
        set { if let host { host.showNewSession = newValue } else { showNewSessionValue = newValue } }
    }

    private var newSessionDirectoryValue: String?
    /// Folder to preselect in the new session sheet.
    var newSessionDirectory: String? {
        get { host == nil ? newSessionDirectoryValue : host?.newSessionDirectory }
        set { if let host { host.newSessionDirectory = newValue } else { newSessionDirectoryValue = newValue } }
    }

    private var draftsValue: [String: String] = [:]
    /// Unsent text per session (the composer's and the Session Hub's reply box share it).
    var drafts: [String: String] {
        get { host?.drafts ?? draftsValue }
        set { if let host { host.drafts = newValue } else { draftsValue = newValue } }
    }

    private var attachmentsValue: [String: [URL]] = [:]
    var attachments: [String: [URL]] {
        get { host?.attachments ?? attachmentsValue }
        set { if let host { host.attachments = newValue } else { attachmentsValue = newValue } }
    }

    private var searchTextValue = ""
    var searchText: String {
        get { host?.searchText ?? searchTextValue }
        set { if let host { host.searchText = newValue } else { searchTextValue = newValue } }
    }

    private var collapsedProjectsValue: Set<String> = []
    var collapsedProjects: Set<String> {
        get { host?.collapsedProjects ?? collapsedProjectsValue }
        set { if let host { host.collapsedProjects = newValue } else { collapsedProjectsValue = newValue } }
    }

    private var focusTokenValue = 0
    /// Bumped to move keyboard focus into the composer (the focused pane's, in split view).
    var composerFocusToken: Int {
        get { activePane?.composerFocusToken ?? focusTokenValue }
        set { if let pane = activePane { pane.composerFocusToken = newValue } else { focusTokenValue = newValue } }
    }

    private var requestedMenuValue: ComposerMenu?
    /// A composer menu a slash command asked to open (the composer opens it and clears this).
    var requestedMenu: ComposerMenu? {
        get { activePane.map(\.requestedMenu) ?? requestedMenuValue }
        set { if let pane = activePane { pane.requestedMenu = newValue } else { requestedMenuValue = newValue } }
    }

    private var showUsageValue = false
    /// Set by /usage; the status line opens its usage popover.
    var showUsage: Bool {
        get { activePane?.showUsage ?? showUsageValue }
        set { if let pane = activePane { pane.showUsage = newValue } else { showUsageValue = newValue } }
    }

    /// The Session Hub card whose reply box is open (Command-Return sends its draft).
    private var hubReplyValue: String?
    var hubReplySessionID: String? {
        get { host == nil ? hubReplyValue : host?.hubReplySessionID }
        set { if let host { host.hubReplySessionID = newValue } else { hubReplyValue = newValue } }
    }

    // MARK: Split view (kept on the window's state)

    /// Sessions side by side; inactive (no panes) when the window shows one session.
    private(set) var split = SplitLayout()
    /// Each pane's own state, made when first needed.
    @ObservationIgnored private var paneStates: [UUID: WindowState] = [:]
    /// Where the layout is saved; nil for windows that never save (snapshots).
    @ObservationIgnored private var splitStorageKey: String?

    @ObservationIgnored private var zoomKeyMonitor: Any?

    // MARK: Zoom (stored in UserDefaults under `Zoom.storageKey`; views read it with @AppStorage)

    static var zoom: Double {
        get { Zoom.clamped(UserDefaults.standard.object(forKey: Zoom.storageKey) as? Double ?? 1) }
        set { UserDefaults.standard.set(Zoom.clamped(newValue), forKey: Zoom.storageKey) }
    }

    func zoomIn() { Self.zoom = Zoom.zoomIn(from: Self.zoom) }
    func zoomOut() { Self.zoom = Zoom.zoomOut(from: Self.zoom) }
    func resetZoom() { Self.zoom = 1 }

    /// The menu shows Command-+; this also accepts Command-= (the same key without Shift), like browsers.
    func installZoomShortcut() {
        guard zoomKeyMonitor == nil else { return }
        zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command, event.charactersIgnoringModifiers == "=" else { return event }
            MainActor.assumeIsolated { self?.zoomIn() }
            return nil
        }
    }

    /// True while the pane shows the context panel (or a room's own panel).
    var contextPanelVisible: Bool { showContextPanel && sidePane == .context }

    /// Shows or hides the context panel. With a file or review pane open, switches the pane to the context panel.
    func toggleContextPanel() {
        if let host { return host.toggleContextPanel() }
        withAnimation(.easeOut(duration: 0.18)) {
            if showContextPanel && sidePane != .context {
                sidePane = .context
            } else {
                showContextPanel.toggle()
                sidePane = .context
            }
        }
        UserDefaults.standard.set(showContextPanel, forKey: "showContextPanel")
    }

    /// Opens a file or review pane on the right, in place of the context panel.
    func openSidePane(_ pane: SidePane) {
        if let host { return host.openSidePane(pane) }
        if sidePane == .context { contextWasOpen = showContextPanel }
        withAnimation(.easeOut(duration: 0.18)) {
            sidePane = pane
            showContextPanel = true
        }
    }

    /// True while the pane shows the review (changes of the session or room on screen).
    var reviewOpen: Bool { showContextPanel && sidePane == .review }

    /// Opens or closes the review pane (Option-Command-R).
    func toggleReview() {
        if reviewOpen { closeSidePane() } else { openSidePane(.review) }
    }

    /// True while the pane shows the browser.
    var browserOpen: Bool { showContextPanel && sidePane == .browser }

    /// Opens or closes the browser pane (Option-Command-B).
    func toggleBrowser() {
        if browserOpen { closeSidePane() } else { openSidePane(.browser) }
    }

    /// True while the pane shows the terminal.
    var terminalOpen: Bool { showContextPanel && sidePane == .terminal }

    /// Shows or hides the terminal pane (Control-backquote). Hiding it puts focus back in the composer; the shells
    /// keep running.
    func toggleTerminal() {
        if terminalOpen {
            closeSidePane()
            composerFocusToken &+= 1
        } else {
            openSidePane(.terminal)
        }
    }

    /// Closes a file or review pane: the context panel comes back if it was open before.
    func closeSidePane() {
        if let host { return host.closeSidePane() }
        guard sidePane != .context else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            sidePane = .context
            showContextPanel = contextWasOpen
        }
    }

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) { showSidebar.toggle() }
    }

    func beginNewSession(in directory: String? = nil) {
        newSessionDirectory = directory
        showNewSession = true
    }

    /// Shows a session. In split view it opens in the focused pane (or focuses the pane already showing it); from a
    /// pane's own state, in that pane.
    func open(_ sessionID: String, store: SessionStore) {
        if let host, let paneID {
            host.show(sessionID, inPane: paneID, store: store)
            return
        }
        route = .session
        followSelection(sessionID)
        store.select(sessionID)
        composerFocusToken &+= 1
    }

    /// Shows a room in the centre of the window.
    func openRoom(_ roomID: UUID, rooms: RoomsController) {
        rooms.select(roomID)
        route = .room
    }

    /// Opens the Nth session in sidebar order (Cmd-1 to Cmd-9), in the focused pane in split view.
    func openSession(number: Int, store: SessionStore) {
        let order = AttentionCenter.shared.sidebarOrder(store: store)
        guard number >= 1, number <= order.count else { return }
        open(order[number - 1].id, store: store)
    }

    func draft(for sessionID: String) -> String { drafts[sessionID] ?? "" }

    /// Sends the draft and attachments of the session this composer belongs to: the pane's own session for a split
    /// pane's state, else the selected session (the focused pane's in split view). On the Session Hub it sends the
    /// open reply box instead (Command-Return).
    func sendDraft(store: SessionStore) {
        if host == nil, route == .hub {
            if let id = hubReplySessionID { sendHubReply(to: id, store: store) }
            return
        }
        guard route == .session, let session = composerSession(store: store) else { return }
        let text = draft(for: session.id).trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments[session.id] ?? []
        guard !text.isEmpty || !files.isEmpty else { return }
        if files.isEmpty, let command = SlashCommands.parse(text),
           runSlashCommand(command.name, arguments: command.arguments, store: store, session: session) {
            drafts[session.id] = ""
            return
        }
        drafts[session.id] = ""
        attachments[session.id] = []
        Task { await store.send(text, files: files, to: session.id) }
    }

    /// The session whose composer this state serves.
    private func composerSession(store: SessionStore) -> SessionModel? {
        if let host, let paneID {
            return host.split.pane(paneID).flatMap { store.session($0.sessionID) }
        }
        return store.selected
    }

    // MARK: Session Hub reply box

    /// Opens the Session Hub's reply box on one card (one at a time).
    func openHubReply(_ sessionID: String) { hubReplySessionID = sessionID }

    func closeHubReply() { hubReplySessionID = nil }

    /// Sends a Hub reply box's draft as a message to that session (queued while its agent works) and closes the box.
    /// Slash commands are not run from the Hub; the text goes as it is.
    func sendHubReply(to sessionID: String, store: SessionStore) {
        let text = draft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.session(sessionID) != nil else { return }
        drafts[sessionID] = ""
        if hubReplySessionID == sessionID { hubReplySessionID = nil }
        Task { await store.send(text, to: sessionID) }
    }

    // MARK: Split view

    /// A split pane's own state, for its composer, transcript and status line.
    func paneState(_ paneID: UUID) -> WindowState {
        if let host { return host.paneState(paneID) }
        if let state = paneStates[paneID] { return state }
        let state = WindowState(paneOf: self, paneID: paneID)
        paneStates[paneID] = state
        return state
    }

    /// The focused pane's own state while the window is split (on the window's state only).
    private var activePane: WindowState? {
        guard host == nil, split.isActive, let id = split.focusedID else { return nil }
        return paneState(id)
    }

    /// True when another session can open beside the ones on screen.
    func canOpenBeside(_ sessionID: String, store: SessionStore) -> Bool {
        let layout = host?.split ?? split
        if layout.contains(sessionID: sessionID) { return layout.isActive }
        if layout.isActive { return !layout.isFull }
        guard let selected = store.selected else { return false }
        return selected.id != sessionID && store.session(sessionID) != nil
    }

    /// Opens a session beside the one on screen (Option-click, Open in Split): starts a split with the selected session,
    /// or adds a pane right of the focused one. A session already in a pane gets focus; with four panes open it shows
    /// in the focused pane.
    func openBeside(_ sessionID: String, store: SessionStore) {
        if let host { return host.openBeside(sessionID, store: store) }
        guard store.session(sessionID) != nil else { return }
        route = .session
        if let pane = split.pane(showing: sessionID) {
            focusPane(pane.id, store: store)
            return
        }
        if split.isActive {
            if split.isFull {
                open(sessionID, store: store)
                return
            }
            updateSplit { $0.insert(sessionID, after: $0.focusedID) }
        } else {
            guard let current = store.selected, current.id != sessionID else {
                open(sessionID, store: store)
                return
            }
            updateSplit { $0.start(current.id, beside: sessionID) }
        }
        store.select(sessionID)
        composerFocusToken &+= 1
    }

    /// Opens the most recent session that is not on screen beside the others (the palette's Open in Split).
    func openNextBeside(store: SessionStore) {
        let shown = Set(split.panes.map(\.sessionID) + [store.selectedSessionID].compactMap { $0 })
        guard let next = AttentionCenter.shared.sidebarOrder(store: store).first(where: { !shown.contains($0.id) }) else { return }
        openBeside(next.id, store: store)
    }

    /// Makes a pane the focused one: its session becomes the window's selected session.
    func focusPane(_ paneID: UUID, store: SessionStore) {
        if let host { return host.focusPane(paneID, store: store) }
        guard let pane = split.pane(paneID) else { return }
        if split.focusedID != paneID { updateSplit { $0.focus(paneID) } }
        if store.selectedSessionID != pane.sessionID { store.select(pane.sessionID) }
    }

    /// Shows another session in a pane and focuses it. A session already in another pane gets focus there instead.
    func show(_ sessionID: String, inPane paneID: UUID, store: SessionStore) {
        if let host { return host.show(sessionID, inPane: paneID, store: store) }
        route = .session
        if let existing = split.pane(showing: sessionID) {
            focusPane(existing.id, store: store)
        } else {
            updateSplit {
                $0.show(sessionID, in: paneID)
                $0.focus(paneID)
            }
            store.select(sessionID)
        }
        paneState(paneID).composerFocusToken &+= 1
    }

    /// Closes a pane (Control-Command-W closes the focused one). With one pane left the window shows that session alone.
    func closePane(_ paneID: UUID, store: SessionStore) {
        if let host { return host.closePane(paneID, store: store) }
        let remaining = updateSplit { $0.remove(paneID) }
        paneStates[paneID] = nil
        if let remaining {
            paneStates = [:]
            store.select(remaining)
        } else if let focused = split.focused, store.selectedSessionID != focused.sessionID {
            store.select(focused.sessionID)
        }
        composerFocusToken &+= 1
    }

    /// Back to one session: the focused pane's.
    func closeSplit(store: SessionStore) {
        if let host { return host.closeSplit(store: store) }
        guard split.isActive else { return }
        let keep = split.focused?.sessionID
        updateSplit { $0.clear() }
        paneStates = [:]
        if let keep, store.selectedSessionID != keep { store.select(keep) }
    }

    /// Moves to the next or previous pane.
    func focusNeighbourPane(_ step: Int, store: SessionStore) {
        if let host { return host.focusNeighbourPane(step, store: store) }
        guard split.isActive, let index = split.panes.firstIndex(where: { $0.id == split.focusedID }) else { return }
        let count = split.panes.count
        focusPane(split.panes[((index + step) % count + count) % count].id, store: store)
        composerFocusToken &+= 1
    }

    /// Drags the divider right of pane `index`; `save` once the drag ends.
    func resizeSplit(divider index: Int, from start: [Double], by delta: Double, minFraction: Double, save: Bool) {
        updateSplit(save: save) { $0.resize(divider: index, from: start, by: delta, minFraction: minFraction) }
    }

    func equalizePanes() {
        updateSplit { $0.equalize() }
    }

    /// Keeps the focused pane on the selected session when something else selects one (a new session, a fork, a
    /// subagent link): a session already in a pane gets focus there, any other replaces the focused pane's session.
    func followSelection(_ sessionID: String?) {
        guard host == nil, split.isActive, let sessionID, split.focused?.sessionID != sessionID else { return }
        if let pane = split.pane(showing: sessionID) {
            updateSplit { $0.focus(pane.id) }
        } else if let focused = split.focusedID {
            updateSplit { $0.show(sessionID, in: focused) }
        }
    }

    /// Drops panes whose sessions were deleted or archived.
    func pruneSplit(store: SessionStore) {
        guard host == nil, split.isActive else { return }
        let remaining = updateSplit { layout in
            layout.keepPanes { id in store.session(id).map { !$0.info.archived } ?? false }
        }
        paneStates = paneStates.filter { split.pane($0.key) != nil }
        if let remaining {
            store.select(remaining)
        } else if let focused = split.focused, store.selectedSessionID != focused.sessionID {
            store.select(focused.sessionID)
        }
    }

    /// Restores this window's saved layout once sessions have loaded, and saves every later change under `key`.
    func restoreSplit(store: SessionStore, key: String = "main") {
        guard host == nil, splitStorageKey == nil else { return }
        splitStorageKey = "splitLayout." + key
        guard let data = UserDefaults.standard.data(forKey: "splitLayout." + key),
              var saved = try? JSONDecoder().decode(SplitLayout.self, from: data), saved.isWellFormed else { return }
        saved.keepPanes { id in store.session(id).map { !$0.info.archived } ?? false }
        guard saved.isWellFormed else { return }
        split = saved
        if let focused = saved.focused { store.select(focused.sessionID) }
    }

    /// Snapshots: shows these sessions side by side, the one at `focused` selected.
    func showSplitForSnapshot(_ sessionIDs: [String], focused: Int, store: SessionStore) {
        var layout = SplitLayout()
        guard sessionIDs.count >= 2 else { return }
        layout.start(sessionIDs[0], beside: sessionIDs[1])
        for id in sessionIDs.dropFirst(2) { layout.insert(id, after: layout.panes.last?.id) }
        if layout.panes.indices.contains(focused) { layout.focus(layout.panes[focused].id) }
        layout.equalize()
        split = layout
        paneStates = [:]
        route = .session
        if let pane = layout.focused { store.select(pane.sessionID) }
    }

    @discardableResult
    private func updateSplit<T>(save: Bool = true, _ change: (inout SplitLayout) -> T) -> T {
        var layout = split
        let result = change(&layout)
        if layout != split { split = layout }
        if save { saveSplit() }
        return result
    }

    private func saveSplit() {
        guard let splitStorageKey else { return }
        if split.isActive, let data = try? JSONEncoder().encode(split) {
            UserDefaults.standard.set(data, forKey: splitStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: splitStorageKey)
        }
    }

    // MARK: Slash commands

    /// Runs Ensemble's own command, or the engine's. Returns false when the name is neither, so the text
    /// is sent as a normal message.
    @discardableResult
    func runSlashCommand(_ name: String, arguments: String, store: SessionStore, session: SessionModel) -> Bool {
        let args = arguments.trimmingCharacters(in: .whitespaces)
        switch name.lowercased() {
        case "new":
            beginNewSession(in: session.directory)
        case "model":
            let query = args.lowercased()
            if !query.isEmpty, let model = store.models.first(where: {
                $0.available && ($0.name.lowercased().contains(query) || $0.ref.description.lowercased().contains(query))
            }) {
                Task { await store.switchModel(model.ref, for: session.id) }
            } else {
                requestedMenu = .model
            }
        case "effort":
            guard let options = store.options(for: session.info.model), !options.effortLevels.isEmpty else {
                store.addNotice("This model has no effort setting", to: session.id)
                return true
            }
            let query = args.lowercased().replacingOccurrences(of: " ", with: "")
            if let level = options.effortLevels.first(where: { $0.rawValue == query || $0.label.lowercased().replacingOccurrences(of: " ", with: "") == query }) {
                Task { await store.setEffort(level, for: session.id) }
            } else {
                requestedMenu = .effort
            }
        case "fast":
            guard store.options(for: session.info.model)?.supportsFastMode == true else {
                store.addNotice("Fast mode is not available for this model", to: session.id)
                return true
            }
            let on = args.lowercased() == "on" ? true : (args.lowercased() == "off" ? false : !session.fastMode)
            Task { await store.setFastMode(on, for: session.id) }
        case "mode":
            let query = args.lowercased()
            let mode: PermissionMode? = switch query {
            case "ask", "ask permissions": .ask
            case "edits", "accept", "acceptedits", "accept edits": .acceptEdits
            case "auto", "auto mode": .auto
            case "bypass", "bypass permissions": .bypass
            default: nil
            }
            if let mode { Task { await store.setPermissionMode(mode, for: session.id) } } else { requestedMenu = .mode }
        case "compact":
            if store.engineHasCommand("compact", sessionID: session.id) {
                Task { await store.runCommand("compact", arguments: args, in: session.id) }
            } else {
                store.addNotice("This engine cannot compact the conversation", to: session.id)
            }
        case "fork":
            guard store.supportsHistory else {
                store.addNotice("This engine does not support forking", to: session.id)
                return true
            }
            Task { if await store.fork(session.id, atMessageID: nil) != nil { composerFocusToken &+= 1 } }
        case "rewind":
            guard store.supportsHistory else {
                store.addNotice("This engine does not support rewinding", to: session.id)
                return true
            }
            guard !session.isWorking else {
                store.addNotice("Rewind is unavailable while the agent is working", to: session.id)
                return true
            }
            if !store.beginRewindOfLastMessage(session.id) {
                store.addNotice("Nothing to rewind yet", to: session.id)
            }
        case "clear":
            Task {
                try? await store.newSession(directory: session.directory, model: session.info.model, permissionMode: session.permissionMode)
                composerFocusToken &+= 1
            }
        case "hub":
            route = .hub
        case "usage":
            route = .usage
        case "btw":
            if let reason = store.sideQuestionUnavailableReason(session.id) {
                store.addNotice(reason, to: session.id)
            } else if args.isEmpty {
                store.openSideQuestion(for: session.id)
            } else {
                Task { await store.askSideQuestion(args, about: session.id) }
            }
        case "help":
            store.addNotice("Return sends, Shift-Return adds a line, Shift-Tab switches the permission mode, Esc stops the agent, "
                            + "Command-semicolon asks a side question, "
                            + "Command-1 to 9 switch sessions, Option-Command-I shows the context panel. Type / for commands.", to: session.id)
        default:
            guard store.commandsControl != nil, store.engineHasCommand(name, sessionID: session.id) else { return false }
            Task { await store.runCommand(name, arguments: args, in: session.id) }
        }
        return true
    }
}

/// Composer menus a command can open.
enum ComposerMenu: Hashable {
    case model, mode, effort
}

/// App appearance setting. Dark is the default.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match system"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}
