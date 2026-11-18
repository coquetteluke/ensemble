import SwiftUI
import EnsembleKit

/// What the centre of the window shows.
enum Route: Hashable {
    case session
    case hub
    case scheduled
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

    /// Width before zoom.
    var width: CGFloat {
        switch self {
        case .context: 303
        case .file: FileViewerPane.width
        case .review: 560
        }
    }
}

/// Window-level UI state that is not engine data: panels, drafts, sheets, search.
@Observable @MainActor
final class WindowState {
    var route: Route = .session
    var showSidebar = true
    /// Whether the right-hand pane is open. Option-Command-I opens and closes it with the context panel in it.
    var showContextPanel: Bool = UserDefaults.standard.object(forKey: "showContextPanel") as? Bool ?? true
    /// What the right-hand pane shows (`showContextPanel` says whether it is open).
    var sidePane: SidePane = .context
    /// Whether the context panel was open before a file or review pane replaced it.
    @ObservationIgnored private var contextWasOpen = true
    var showNewSession = false
    /// Folder to preselect in the new session sheet.
    var newSessionDirectory: String?
    var drafts: [String: String] = [:]
    var attachments: [String: [URL]] = [:]
    var searchText = ""
    var collapsedProjects: Set<String> = []
    /// Bumped to move keyboard focus into the composer.
    var composerFocusToken = 0
    /// A composer menu a slash command asked to open (the composer opens it and clears this).
    var requestedMenu: ComposerMenu?
    /// Set by /usage; the status line opens its usage popover.
    var showUsage = false
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

    /// Closes a file or review pane: the context panel comes back if it was open before.
    func closeSidePane() {
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

    func open(_ sessionID: String, store: SessionStore) {
        route = .session
        store.select(sessionID)
        composerFocusToken &+= 1
    }

    /// Shows a room in the centre of the window.
    func openRoom(_ roomID: UUID, rooms: RoomsController) {
        rooms.select(roomID)
        route = .room
    }

    /// Opens the Nth session in sidebar order (Cmd-1 to Cmd-9).
    func openSession(number: Int, store: SessionStore) {
        let order = AttentionCenter.shared.sidebarOrder(store: store)
        guard number >= 1, number <= order.count else { return }
        open(order[number - 1].id, store: store)
    }

    func draft(for sessionID: String) -> String { drafts[sessionID] ?? "" }

    /// Sends the selected session's draft and attachments.
    func sendDraft(store: SessionStore) {
        guard route == .session, let session = store.selected else { return }
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
            let lastUser = session.items.last { if case .user = $0 { true } else { false } }
            guard let lastUser else {
                store.addNotice("Nothing to rewind yet", to: session.id)
                return true
            }
            Task {
                if let text = await store.editMessage(session.id, messageID: lastUser.id) {
                    drafts[session.id] = text
                    composerFocusToken &+= 1
                }
            }
        case "clear":
            Task {
                try? await store.newSession(directory: session.directory, model: session.info.model, permissionMode: session.permissionMode)
                composerFocusToken &+= 1
            }
        case "hub":
            route = .hub
        case "usage":
            showUsage = true
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
