import SwiftUI
import AppKit
import EnsembleKit

// Every app command in one place. The menu bar takes its titles and shortcuts from here (`.appShortcut(_:)`),
// the command palette (Command-Shift-P) runs them, and the shortcut overlay (Command-slash) lists them.

/// Where a command or shortcut is listed in the overlay.
enum CommandArea: String, CaseIterable, Identifiable {
    case general = "General"
    case sessions = "Sessions"
    case composer = "Composer"
    case permissions = "Permission prompts"
    case transcript = "Transcript"
    case view = "View"
    case split = "Split view"
    case terminal = "Terminal"
    case search = "Search"

    var id: String { rawValue }
}

/// A key combination. `caps` are the key caps in macOS order (Control, Option, Shift, Command, then the key).
struct AppShortcut: Hashable {
    enum Key: Hashable {
        case character(Character)
        case `return`, escape, tab, upArrow, downArrow, leftArrow, rightArrow
    }

    let key: Key
    let modifiers: EventModifiers

    init(_ character: Character, _ modifiers: EventModifiers = .command) {
        key = .character(character)
        self.modifiers = modifiers
    }

    init(_ key: Key, _ modifiers: EventModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .return: .return
        case .escape: .escape
        case .tab: .tab
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        }
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: modifiers) }

    var caps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("\u{2303}") }
        if modifiers.contains(.option) { caps.append("\u{2325}") }
        if modifiers.contains(.shift) { caps.append("\u{21E7}") }
        if modifiers.contains(.command) { caps.append("\u{2318}") }
        switch key {
        case .character(let character): caps.append(String(character).uppercased())
        case .return: caps.append("\u{21A9}")
        case .escape: caps.append("esc")
        case .tab: caps.append("\u{21E5}")
        case .upArrow: caps.append("\u{2191}")
        case .downArrow: caps.append("\u{2193}")
        case .leftArrow: caps.append("\u{2190}")
        case .rightArrow: caps.append("\u{2192}")
        }
        return caps
    }

    static func == (a: AppShortcut, b: AppShortcut) -> Bool {
        a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

/// Every command the app has. The order is the palette's order when nothing is typed.
enum AppCommandID: String, CaseIterable, Identifiable {
    case newSession, newRoom, searchTranscripts, keyboardShortcuts, commandPalette, settings, customizations, pairIPhone
    case sendMessage, stopAgent, openHub, openScheduled, archiveSession, forkSession, compactConversation, revealFolder
    case switchModel, switchMode, modeAsk, modeAcceptEdits, modeAuto, modePlan, modeBypass, changeEffort, toggleFastMode, sideQuestion, focusComposer
    case allowOnce, alwaysAllow, reject
    case nextTranscriptView, viewNormal, viewThinking, viewVerbose
    case toggleSidebar, toggleContextPanel, toggleBrowser, closeFileViewer, zoomIn, zoomOut, actualSize
    case openInSplit, closePane, nextPane, previousPane, equalizePanes, closeSplit
    case toggleTerminal, newTerminalTab
    case appearanceDark, appearanceLight, appearanceSystem

    var id: String { rawValue }

    /// Title in the palette and the overlay (menus may say "Hide" or "Show" for toggles).
    var title: String {
        switch self {
        case .newSession: "New session"
        case .newRoom: "New room"
        case .searchTranscripts: "Search sessions"
        case .keyboardShortcuts: "Show keyboard shortcuts"
        case .commandPalette: "Command palette"
        case .settings: "Open Settings"
        case .customizations: "Open Customizations"
        case .pairIPhone: "Pair iPhone"
        case .sendMessage: "Send message"
        case .stopAgent: "Stop the agent"
        case .openHub: "Open Session Hub"
        case .openScheduled: "Open Scheduled"
        case .archiveSession: "Archive session"
        case .forkSession: "Fork session"
        case .compactConversation: "Compact conversation"
        case .revealFolder: "Reveal session folder in Finder"
        case .switchModel: "Switch model"
        case .switchMode: "Switch permission mode"
        case .modeAsk: "Permission mode: \(PermissionMode.ask.label)"
        case .modeAcceptEdits: "Permission mode: \(PermissionMode.acceptEdits.label)"
        case .modeAuto: "Permission mode: \(PermissionMode.auto.label)"
        case .modePlan: "Permission mode: \(PermissionMode.plan.label)"
        case .modeBypass: "Permission mode: \(PermissionMode.bypass.label)"
        case .changeEffort: "Change effort"
        case .toggleFastMode: "Turn fast mode on or off"
        case .sideQuestion: "Ask a side question"
        case .focusComposer: "Focus the message field"
        case .allowOnce: "Allow once"
        case .alwaysAllow: "Always allow"
        case .reject: "Reject"
        case .nextTranscriptView: "Next transcript view"
        case .viewNormal: "Transcript view: Normal"
        case .viewThinking: "Transcript view: Thinking"
        case .viewVerbose: "Transcript view: Verbose"
        case .toggleSidebar: "Show or hide the sidebar"
        case .toggleContextPanel: "Show or hide the context panel"
        case .toggleBrowser: "Show or hide the browser"
        case .closeFileViewer: "Close the file viewer"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .actualSize: "Actual size"
        case .openInSplit: "Open in Split"
        case .closePane: "Close split pane"
        case .nextPane: "Next split pane"
        case .previousPane: "Previous split pane"
        case .equalizePanes: "Make split panes equal"
        case .closeSplit: "Close split view"
        case .toggleTerminal: "Show or hide the terminal"
        case .newTerminalTab: "New terminal tab"
        case .appearanceDark: "Appearance: Dark"
        case .appearanceLight: "Appearance: Light"
        case .appearanceSystem: "Appearance: Match system"
        }
    }

    var area: CommandArea {
        switch self {
        case .newSession, .newRoom, .settings, .customizations, .pairIPhone: .general
        case .searchTranscripts, .keyboardShortcuts, .commandPalette: .search
        case .sendMessage, .stopAgent, .openHub, .openScheduled, .archiveSession, .forkSession, .compactConversation, .revealFolder: .sessions
        case .switchModel, .switchMode, .modeAsk, .modeAcceptEdits, .modeAuto, .modePlan, .modeBypass, .changeEffort, .toggleFastMode, .sideQuestion,
             .focusComposer: .composer
        case .allowOnce, .alwaysAllow, .reject: .permissions
        case .nextTranscriptView, .viewNormal, .viewThinking, .viewVerbose: .transcript
        case .toggleSidebar, .toggleContextPanel, .toggleBrowser, .closeFileViewer, .zoomIn, .zoomOut, .actualSize,
             .appearanceDark, .appearanceLight, .appearanceSystem: .view
        case .openInSplit, .closePane, .nextPane, .previousPane, .equalizePanes, .closeSplit: .split
        case .toggleTerminal, .newTerminalTab: .terminal
        }
    }

    var symbol: String {
        switch self {
        case .newSession: "square.and.pencil"
        case .newRoom: "person.3"
        case .searchTranscripts: "magnifyingglass"
        case .keyboardShortcuts: "keyboard"
        case .commandPalette: "command"
        case .settings: "gearshape"
        case .customizations: "puzzlepiece.extension"
        case .pairIPhone: "iphone"
        case .sendMessage: "arrow.up"
        case .stopAgent: "stop.circle"
        case .openHub: "tray.2"
        case .openScheduled: "clock"
        case .archiveSession: "archivebox"
        case .forkSession: "arrow.triangle.branch"
        case .compactConversation: "arrow.down.right.and.arrow.up.left"
        case .revealFolder: "folder"
        case .switchModel: "cpu"
        case .switchMode: "shield.lefthalf.filled"
        case .modeAsk: PermissionMode.ask.symbolName
        case .modeAcceptEdits: PermissionMode.acceptEdits.symbolName
        case .modeAuto: PermissionMode.auto.symbolName
        case .modePlan: PermissionMode.plan.symbolName
        case .modeBypass: PermissionMode.bypass.symbolName
        case .changeEffort: "gauge.with.dots.needle.50percent"
        case .toggleFastMode: "hare"
        case .sideQuestion: "questionmark.bubble"
        case .focusComposer: "text.cursor"
        case .allowOnce: "checkmark"
        case .alwaysAllow: "checkmark.seal"
        case .reject: "xmark"
        case .nextTranscriptView: "rectangle.stack"
        case .viewNormal: TranscriptViewMode.normal.symbol
        case .viewThinking: TranscriptViewMode.thinking.symbol
        case .viewVerbose: TranscriptViewMode.verbose.symbol
        case .toggleSidebar: "sidebar.left"
        case .toggleContextPanel: "sidebar.right"
        case .toggleBrowser: "globe"
        case .closeFileViewer: "xmark.rectangle"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .actualSize: "1.magnifyingglass"
        case .openInSplit: "rectangle.split.2x1"
        case .closePane: "xmark.square"
        case .nextPane: "arrow.right.square"
        case .previousPane: "arrow.left.square"
        case .equalizePanes: "equal.square"
        case .closeSplit: "rectangle"
        case .toggleTerminal: "terminal"
        case .newTerminalTab: "plus.rectangle.on.rectangle"
        case .appearanceDark: "moon"
        case .appearanceLight: "sun.max"
        case .appearanceSystem: "circle.lefthalf.filled"
        }
    }

    /// The menu bar shortcut, when the command has one.
    var shortcut: AppShortcut? {
        switch self {
        case .newSession: AppShortcut("n")
        case .newRoom: AppShortcut("n", [.command, .shift])
        case .searchTranscripts: AppShortcut("k")
        case .keyboardShortcuts: AppShortcut("/")
        case .commandPalette: AppShortcut("p", [.command, .shift])
        case .settings: AppShortcut(",")
        case .pairIPhone: AppShortcut("p", [.command, .shift, .option])
        case .sendMessage: AppShortcut(.return, .command)
        case .stopAgent: AppShortcut(.escape)
        case .sideQuestion: AppShortcut(";")
        case .allowOnce: AppShortcut("y")
        case .alwaysAllow: AppShortcut("y", [.command, .option])
        case .reject: AppShortcut(".")
        case .nextTranscriptView: AppShortcut("o", .control)
        case .toggleSidebar: AppShortcut("s", [.command, .control])
        case .toggleContextPanel: AppShortcut("i", [.command, .option])
        case .toggleBrowser: AppShortcut("b", [.command, .option])
        case .zoomIn: AppShortcut("+")
        case .zoomOut: AppShortcut("-")
        case .actualSize: AppShortcut("0")
        case .closePane: AppShortcut("w", [.command, .control])
        case .nextPane: AppShortcut(.rightArrow, [.command, .option])
        case .previousPane: AppShortcut(.leftArrow, [.command, .option])
        case .toggleTerminal: AppShortcut("`", .control)
        default: nil
        }
    }

    /// Other words the palette matches.
    var keywords: [String] {
        switch self {
        case .newSession: ["chat", "start", "create"]
        case .newRoom: ["team", "debate", "round table", "agents", "together"]
        case .searchTranscripts: ["find", "transcripts", "messages", "history"]
        case .keyboardShortcuts: ["keys", "help", "hotkeys"]
        case .settings: ["preferences", "options", "api keys", "accounts"]
        case .customizations: ["rules", "memory", "skills", "mcp", "hooks", "plugins", "agents", "claude.md"]
        case .pairIPhone: ["phone", "remote", "qr"]
        case .stopAgent: ["interrupt", "cancel"]
        case .openHub: ["needs you", "inbox"]
        case .openScheduled: ["schedules", "cron"]
        case .switchMode, .modeAsk, .modeAcceptEdits, .modeAuto, .modePlan, .modeBypass: ["permissions", "mode"]
        case .switchModel: ["model", "provider"]
        case .changeEffort: ["thinking", "reasoning"]
        case .sideQuestion: ["btw", "aside"]
        case .nextTranscriptView, .viewNormal, .viewThinking, .viewVerbose: ["detail", "tools", "thinking", "verbose"]
        case .toggleSidebar: ["sessions list"]
        case .toggleContextPanel: ["context", "usage", "connectors"]
        case .toggleBrowser: ["web", "page", "preview", "dev server", "localhost", "launch.json", "console"]
        case .zoomIn, .zoomOut, .actualSize: ["text size", "font size", "scale"]
        case .appearanceDark, .appearanceLight, .appearanceSystem: ["theme", "dark mode", "light mode"]
        case .openInSplit: ["split view", "side by side", "beside", "pane"]
        case .closePane, .nextPane, .previousPane, .equalizePanes, .closeSplit: ["split view", "pane", "side by side"]
        case .toggleTerminal, .newTerminalTab: ["shell", "console", "command line", "zsh", "bash"]
        default: []
        }
    }

    /// Shorter title for the shortcut overlay's narrow columns.
    var shortTitle: String {
        switch self {
        case .toggleSidebar: "Sidebar"
        case .toggleContextPanel: "Context panel"
        case .toggleBrowser: "Browser"
        case .keyboardShortcuts: "Keyboard shortcuts"
        case .toggleTerminal: "Terminal"
        default: title
        }
    }

    /// The palette lists every command except the one that opened it.
    var inPalette: Bool { self != .commandPalette }
}

/// A shortcut that is not a menu command (keys inside the composer, the search overlay and so on).
struct ShortcutNote: Identifiable, Hashable {
    let title: String
    let area: CommandArea
    let caps: [String]
    var id: String { area.rawValue + title }
}

/// One area of the shortcut overlay.
struct ShortcutGroup: Identifiable {
    let area: CommandArea
    let rows: [ShortcutNote]
    var id: String { area.rawValue }
}

/// What commands act on.
@MainActor
struct CommandContext {
    let store: SessionStore?
    let window: WindowState
    let search: SearchCenter
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?
}

/// A command ready to run, as the palette lists it.
struct AppCommand: Identifiable {
    let id: AppCommandID
    let title: String
    let isEnabled: Bool
    let run: @MainActor () -> Void
}

@MainActor
enum CommandRegistry {
    /// Shortcuts that live outside the menus, listed in the overlay with the menu ones.
    static let notes: [ShortcutNote] = [
        ShortcutNote(title: "Switch to session 1 to 9", area: .sessions, caps: ["\u{2318}", "1\u{2026}9"]),
        ShortcutNote(title: "Open beside (split view)", area: .split, caps: ["\u{2325}", "Click"]),
        ShortcutNote(title: "Move between Session Hub cards", area: .sessions, caps: ["\u{2191}", "\u{2193}"]),
        ShortcutNote(title: "Send a Session Hub reply", area: .sessions, caps: ["\u{2318}", "\u{21A9}"]),
        ShortcutNote(title: "Send", area: .composer, caps: ["\u{21A9}"]),
        ShortcutNote(title: "New line", area: .composer, caps: ["\u{21E7}", "\u{21A9}"]),
        ShortcutNote(title: "Next permission mode", area: .composer, caps: ["\u{21E7}", "\u{21E5}"]),
        ShortcutNote(title: "Commands and skills", area: .composer, caps: ["/"]),
        ShortcutNote(title: "Move through results", area: .search, caps: ["\u{2191}", "\u{2193}"]),
        ShortcutNote(title: "Open the result", area: .search, caps: ["\u{21A9}"]),
        ShortcutNote(title: "Next search filter", area: .search, caps: ["\u{21E5}"]),
        ShortcutNote(title: "Close", area: .search, caps: ["esc"]),
        ShortcutNote(title: "New tab", area: .terminal, caps: ["\u{2318}", "T"]),
        ShortcutNote(title: "Close tab", area: .terminal, caps: ["\u{2318}", "W"]),
        ShortcutNote(title: "Select while a program uses the mouse", area: .terminal, caps: ["\u{2325}", "Drag"]),
    ]

    /// Every shortcut, grouped by area, in area order.
    static var shortcutGroups: [ShortcutGroup] {
        let fromCommands = AppCommandID.allCases.compactMap { id in
            id.shortcut.map { ShortcutNote(title: id.shortTitle, area: id.area, caps: $0.caps) }
        }
        let all = fromCommands + notes
        return CommandArea.allCases.compactMap { area in
            let rows = all.filter { $0.area == area }
            return rows.isEmpty ? nil : ShortcutGroup(area: area, rows: rows)
        }
    }

    /// Commands for the palette, with what they do in `context` right now.
    static func commands(_ context: CommandContext) -> [AppCommand] {
        AppCommandID.allCases.filter(\.inPalette).map { id in
            AppCommand(id: id, title: title(id, context), isEnabled: isEnabled(id, context), run: { run(id, context) })
        }
    }

    static func title(_ id: AppCommandID, _ context: CommandContext) -> String {
        switch id {
        case .toggleSidebar: context.window.showSidebar ? "Hide sidebar" : "Show sidebar"
        case .toggleContextPanel: context.window.contextPanelVisible ? "Hide context panel" : "Show context panel"
        case .toggleBrowser: context.window.browserOpen ? "Hide browser" : "Show browser"
        case .toggleTerminal: context.window.terminalOpen ? "Hide terminal" : "Show terminal"
        case .toggleFastMode: (context.store?.selected?.fastMode ?? false) ? "Turn fast mode off" : "Turn fast mode on"
        default: id.title
        }
    }

    static func isEnabled(_ id: AppCommandID, _ context: CommandContext) -> Bool {
        let store = context.store
        let session = context.window.route == .session ? store?.selected : nil
        switch id {
        case .newSession, .searchTranscripts: return store != nil
        case .newRoom: return context.search.rooms != nil
        case .sendMessage, .switchModel, .switchMode, .modeAsk, .modeAcceptEdits, .modeAuto, .modePlan, .modeBypass, .focusComposer,
             .archiveSession, .revealFolder, .compactConversation, .sideQuestion:
            return session != nil
        case .stopAgent: return session?.isWorking ?? false
        case .forkSession: return session != nil && (store?.supportsHistory ?? false)
        case .changeEffort: return !(store?.options(for: session?.info.model)?.effortLevels.isEmpty ?? true)
        case .toggleFastMode: return store?.options(for: session?.info.model)?.supportsFastMode ?? false
        // Only the one prompt on screen, never a prompt the user can't see. Always allow saves a rule, so it
        // runs only from the card itself, where the rule is shown.
        case .allowOnce, .reject: return Self.visiblePrompt(context) != nil
        case .alwaysAllow: return false
        case .closeFileViewer: return context.search.filePreview != nil
        case .openHub, .openScheduled: return store != nil
        case .openInSplit:
            guard let store, store.selected != nil else { return false }
            return context.window.split.isActive ? !context.window.split.isFull : store.sessions.contains { !$0.isSubagent && !$0.info.archived && $0.id != store.selectedSessionID }
        case .closePane, .nextPane, .previousPane, .equalizePanes, .closeSplit: return context.window.split.isActive
        case .settings, .customizations: return context.openSettings != nil
        case .toggleTerminal: return store != nil
        case .newTerminalTab: return TerminalOwner.current(store: store, rooms: context.search.rooms, route: context.window.route) != nil
        case .pairIPhone: return context.openWindow != nil
        default: return true
        }
    }

    static func run(_ id: AppCommandID, _ context: CommandContext) {
        let window = context.window
        let search = context.search
        let store = context.store
        let session = window.route == .session ? store?.selected : nil
        switch id {
        case .newSession: window.beginNewSession()
        case .newRoom: search.rooms?.beginNewRoom()
        case .searchTranscripts: search.show(.search)
        case .keyboardShortcuts: search.show(.shortcuts)
        case .commandPalette: search.show(.palette)
        case .settings: context.openSettings?()
        case .customizations:
            // The folder on screen: the room's in a room, else the selected (focused) session's.
            let folder = window.route == .room ? search.rooms?.selectedEngine?.state.spec.directory : store?.selected?.directory
            CustomizationsFocus.shared.show(folder: folder)
            context.openSettings?()
        case .pairIPhone: context.openWindow?(id: "pair-iphone")
        case .sendMessage: if let store { window.sendDraft(store: store) }
        case .stopAgent: if let store { Task { await store.stop() } }
        case .openHub: window.route = .hub
        case .openScheduled: window.route = .scheduled
        case .archiveSession: if let store, let session { Task { await store.archive(session.id) } }
        case .forkSession:
            if let store, let session {
                Task { if await store.fork(session.id, atMessageID: nil) != nil { window.composerFocusToken &+= 1 } }
            }
        case .compactConversation:
            if let store, let session { window.runSlashCommand("compact", arguments: "", store: store, session: session) }
        case .revealFolder:
            if let session { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory)]) }
        case .switchModel: window.requestedMenu = .model
        case .switchMode: window.requestedMenu = .mode
        case .modeAsk: setMode(.ask, context)
        case .modeAcceptEdits: setMode(.acceptEdits, context)
        case .modeAuto: setMode(.auto, context)
        case .modePlan: setMode(.plan, context)
        case .modeBypass: setMode(.bypass, context)
        case .changeEffort: window.requestedMenu = .effort
        case .toggleFastMode:
            if let store, let session { Task { await store.setFastMode(!session.fastMode, for: session.id) } }
        case .sideQuestion:
            if let store, let session {
                if let reason = store.sideQuestionUnavailableReason(session.id) {
                    store.addNotice(reason, to: session.id)
                } else {
                    store.openSideQuestion(for: session.id)
                }
            }
        case .focusComposer: window.composerFocusToken &+= 1
        case .allowOnce: reply(.once, context)
        case .alwaysAllow: break
        case .reject: reply(.reject, context)
        case .nextTranscriptView: TranscriptViewMode.cycle()
        case .viewNormal: UserDefaults.standard.set(TranscriptViewMode.normal.rawValue, forKey: TranscriptViewMode.storageKey)
        case .viewThinking: UserDefaults.standard.set(TranscriptViewMode.thinking.rawValue, forKey: TranscriptViewMode.storageKey)
        case .viewVerbose: UserDefaults.standard.set(TranscriptViewMode.verbose.rawValue, forKey: TranscriptViewMode.storageKey)
        case .toggleSidebar: window.toggleSidebar()
        case .toggleContextPanel: window.toggleContextPanel()
        case .toggleBrowser: window.toggleBrowser()
        case .closeFileViewer: search.closeFile()
        case .zoomIn: window.zoomIn()
        case .zoomOut: window.zoomOut()
        case .actualSize: window.resetZoom()
        case .openInSplit: if let store { window.openNextBeside(store: store) }
        case .closePane: if let store, let focused = window.split.focusedID { window.closePane(focused, store: store) }
        case .nextPane: if let store { window.focusNeighbourPane(1, store: store) }
        case .previousPane: if let store { window.focusNeighbourPane(-1, store: store) }
        case .equalizePanes: window.equalizePanes()
        case .closeSplit: if let store { window.closeSplit(store: store) }
        case .toggleTerminal: window.toggleTerminal()
        case .newTerminalTab:
            guard let owner = TerminalOwner.current(store: store, rooms: search.rooms, route: window.route) else { return }
            let list = TerminalCenter.shared.list(for: owner.key)
            // Opening the pane on a session without tabs starts one by itself.
            if window.terminalOpen || !list.tabs.isEmpty { list.newTab(directory: owner.directory) }
            if !window.terminalOpen { window.openSidePane(.terminal) }
        case .appearanceDark: UserDefaults.standard.set(AppearanceSetting.dark.rawValue, forKey: "appearance")
        case .appearanceLight: UserDefaults.standard.set(AppearanceSetting.light.rawValue, forKey: "appearance")
        case .appearanceSystem: UserDefaults.standard.set(AppearanceSetting.system.rawValue, forKey: "appearance")
        }
    }

    private static func setMode(_ mode: PermissionMode, _ context: CommandContext) {
        guard let store = context.store, let session = store.selected else { return }
        Task { await store.setPermissionMode(mode, for: session.id) }
    }

    /// The prompt a palette command may answer: the session on screen has exactly one open prompt.
    private static func visiblePrompt(_ context: CommandContext) -> PermissionRequest? {
        guard context.window.route == .session, let session = context.store?.selected,
              session.pendingPermissions.count == 1 else { return nil }
        return session.pendingPermissions.first
    }

    private static func reply(_ decision: PermissionDecision, _ context: CommandContext) {
        guard decision != .always, let store = context.store, let request = visiblePrompt(context) else { return }
        Task { await store.reply(to: request, decision: decision) }
    }
}

extension View {
    /// The command's shortcut from the registry, for menu bar items: `Button(...) { }.appShortcut(.searchTranscripts)`.
    @ViewBuilder func appShortcut(_ id: AppCommandID) -> some View {
        if let shortcut = id.shortcut {
            keyboardShortcut(shortcut.keyboardShortcut)
        } else {
            self
        }
    }
}
