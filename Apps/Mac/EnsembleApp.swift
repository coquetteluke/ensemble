import SwiftUI
import EnsembleKit

/// Owns the engine for the whole app: the real OpenCode service (through `EngineManager`), or the
/// preview engine when launched with `--preview` (or `ENSEMBLE_PREVIEW=1`). The session store is
/// created once the engine is ready.
@MainActor
@Observable
final class AppEngine {
    static var usePreview: Bool {
        CommandLine.arguments.contains("--preview") || ProcessInfo.processInfo.environment["ENSEMBLE_PREVIEW"] == "1"
    }

    let manager = EngineManager(defaultDirectory: NSHomeDirectory())
    private(set) var store: SessionStore?
    /// The iPhone remote, available once the store exists.
    private(set) var remote: RemoteControlController?
    /// Rooms (agents working together), available once the store exists. They use the store's engine, so a room can
    /// mix Claude, Gemini and OpenCode agents.
    private(set) var rooms: RoomsController?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    /// Sends each session to OpenCode or to the Claude engine (Claude models on the user's own subscription).
    @ObservationIgnored private(set) var router: EngineRouter?
    /// Ensemble's own OpenCode server for folders the user has not trusted: started without project config, so new
    /// OpenCode sessions there never load the folder's opencode.json, plugins, MCP servers or AGENTS.md.
    let privateOpenCode = PrivateOpenCodeServer(configuration: .init(defaultDirectory: NSHomeDirectory()))

    var status: EngineStatus {
        if Self.usePreview, let url = URL(string: "preview://local") { return .running(version: "preview", url: url) }
        return manager.status
    }

    func start() {
        guard store == nil, watchTask == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAgentProcesses() }
        }
        if Self.usePreview {
            open(SessionStore(engine: PreviewEngine()))
            return
        }
        manager.start()
        watchTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.manager.statusUpdates() {
                guard case .running = status, let client = self.manager.client else { continue }
                if let router = self.router {
                    // OpenCode came back with a new address or password: swap the client in place.
                    if (router.registration(id: "opencode")?.engine as? OpenCodeClient) !== client {
                        router.register(client, providers: [], id: "opencode")
                        self.privateOpenCode.credentialSource = client
                    }
                    continue
                }
                guard self.store == nil else { continue }
                let router = EngineRouter.standard(openCode: client, claude: ClaudeCodeEngine())
                // Gemini through Google's official `agy acp`, on the user's own Google AI plan.
                let antigravity = ACPAgentRegistry.antigravity
                if ACPAgentRegistry.installation(antigravity).installed {
                    router.register(ACPEngine(agent: antigravity), providers: [antigravity.id], billing: .subscription,
                                    id: "antigravity", name: "Google Antigravity")
                }
                self.startPrivateOpenCode(router: router, sharedClient: client)
                self.router = router
                self.open(SessionStore(engine: router))
            }
        }
    }

    private func open(_ newStore: SessionStore) {
        let defaults = UserDefaults.standard
        newStore.defaultModel = defaults.string(forKey: "defaultModel").flatMap(ModelRef.init(string:))
        newStore.defaultPermissionMode = defaults.string(forKey: "defaultPermissionMode").flatMap(PermissionMode.init(rawValue:)) ?? .auto
        store = newStore
        // Ensemble's tools for agents (propose_session, the browser tools); never in previews.
        if !Self.usePreview { AgentToolsCenter.shared.start(store: newStore) }
        let remoteHost = MacRemoteHost(store: newStore)
        let remoteControl = RemoteControlController(
            host: remoteHost,
            tokenStore: Self.usePreview ? InMemoryRemoteTokenStore() : KeychainRemoteTokenStore(),
            identityStore: Self.usePreview ? InMemoryRelayIdentityStore() : KeychainRelayIdentityStore())
        remote = remoteControl
        // Sample data keeps its rooms in memory and never runs git, so it never touches saved rooms or real folders.
        let roomsController = RoomsController(api: newStore.engine,
                                              store: Self.usePreview ? InMemoryRoomStore() : FileRoomStore.standard,
                                              git: Self.usePreview ? nil : ProcessGitOps())
        rooms = roomsController
        // Rooms on the iPhone.
        remoteHost.rooms = roomsController
        // The Dock badge and the menu bar count rooms waiting on a decision (room agents' prompts count as sessions).
        AttentionCenter.shared.extraNeedsYou = { [weak roomsController] in roomsController?.decisionsWaiting ?? 0 }
        Task {
            await newStore.start()
            // Scheduled tasks and usage totals run inside Ensemble, for every engine.
            ScheduleCenter.shared.start(store: newStore, preview: Self.usePreview)
            UsageCenter.shared.start(store: newStore, preview: Self.usePreview)
            await roomsController.start()
            roomsController.syncAgents(into: newStore)
            // Preview builds (often ad-hoc signed) never touch the real pairing in the keychain.
            if !Self.usePreview { await remoteControl.restore() }
        }
    }

    func retry() {
        Task { await manager.checkNow() }
    }

    /// Untrusted folders get their own OpenCode server. Until it answers, its slot in the router refuses new sessions
    /// (never falling back to the shared service); each time it (re)starts its client takes the slot and the session
    /// list is reloaded so its sessions appear.
    private func startPrivateOpenCode(router: EngineRouter, sharedClient: OpenCodeClient) {
        router.registerForUntrustedFolders(OpenCodeStandIn(reason: "starting"))
        privateOpenCode.credentialSource = sharedClient
        // Browser sign-ins are not copied to the private server; the router refuses those models in untrusted folders.
        privateOpenCode.onSignInOnlyProvidersChanged = { providers in
            router.setProvidersNeedingTrustedFolders(providers)
        }
        privateOpenCode.onReady = { [weak self] client in
            router.registerForUntrustedFolders(client)
            Task { await self?.store?.reloadSessions() }
        }
        if let executable = manager.executableURL {
            privateOpenCode.start(executable: executable)
        }
    }

    /// Stops the `claude` and `agy` processes Ensemble started, waiting at most two seconds so quitting
    /// never hangs, and the private OpenCode server. (They also exit by themselves once their input closes.)
    private func stopAgentProcesses() {
        privateOpenCode.stop(wait: 0)
        guard let router else { return }
        let claude = router.registration(id: "claude")?.engine as? ClaudeCodeEngine
        let antigravity = router.registration(id: "antigravity")?.engine as? ACPEngine
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await claude?.shutdown()
            await antigravity?.shutdown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}

@main
struct EnsembleApp: App {
    /// Asks before quitting with programs running in terminal tabs, and ends the terminal shells on quit.
    @NSApplicationDelegateAdaptor(EnsembleAppDelegate.self) private var appDelegate
    @State private var app = AppEngine()
    @State private var window = WindowState()
    @State private var search = SearchCenter()
    @State private var power = PowerController.makeForMac()
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue
    @AppStorage(Zoom.storageKey) private var zoom = 1.0

    init() {
        // `--render-snapshots <dir>` writes PNGs of key views and quits before any window opens.
        if let directory = SnapshotRenderer.requestedDirectory() {
            SnapshotRenderer.run(outputDirectory: directory)
            exit(0)
        }
        // A notification clicked while Ensemble was closed opens its session once sessions load.
        AttentionCenter.shared.installNotificationHandler()
    }

    private var colorScheme: ColorScheme? {
        (AppearanceSetting(rawValue: appearance) ?? .dark).colorScheme
    }

    var body: some Scene {
        Window("Ensemble", id: "main") {
            Group {
                if let store = app.store {
                    MainView(store: store, window: window, rooms: app.rooms, search: search, remote: app.remote)
                } else {
                    EngineStatusView(status: app.status, retry: app.retry)
                }
            }
            .frame(minWidth: 980, minHeight: 620)
            // In full screen the toolbar would be its own empty strip over the title row; MainView draws the buttons.
            .windowToolbarFullScreenVisibility(.onHover)
            .ensembleTheme()
            .preferredColorScheme(colorScheme)
            .environment(power)
            .task { app.start() }
            .task { await power.start() }
            .task { ScheduleCenter.shared.power = power }
            .task { MenuShortcuts.install() }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            EnsembleCommands(app: app, window: window)
            FindingCommands(search: search, hasStore: app.store != nil)
        }

        Window("Pair iPhone", id: "pair-iphone") {
            Group {
                if let remote = app.remote {
                    RemoteControlSettingsView(controller: remote)
                } else {
                    EngineStatusView(status: app.status, retry: app.retry)
                }
            }
            .frame(minWidth: 520, minHeight: 580)
            .ensembleTheme()
            .environment(\.zoom, CGFloat(Zoom.clamped(zoom)))
            .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 560, height: 640)

        Settings {
            Group {
                if let store = app.store {
                    SettingsView(store: store, remote: app.remote)
                } else {
                    EngineStatusView(status: app.status, retry: app.retry)
                        .frame(width: 520, height: 320)
                }
            }
            .ensembleTheme()
            .preferredColorScheme(colorScheme)
            .environment(power)
        }
    }
}

/// Shown until the engine is ready, or when it cannot start.
struct EngineStatusView: View {
    let status: EngineStatus
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch status {
            case .starting, .running:
                ProgressView().controlSize(.large)
                Text("Starting the engine").font(.title3)
            case .notInstalled:
                Text("Ensemble needs OpenCode").font(.title3.weight(.semibold))
                Text("Install it with Homebrew, then press Try again.").foregroundStyle(.secondary)
                Text("brew install opencode").font(.body.monospaced()).textSelection(.enabled)
                Button("Try again", action: retry).keyboardShortcut(.defaultAction)
            case .tooOld(let found, let required):
                Text("OpenCode \(found) is too old").font(.title3.weight(.semibold))
                Text("Ensemble needs \(required) or newer. Update it, then press Try again.").foregroundStyle(.secondary)
                Text("brew upgrade opencode").font(.body.monospaced()).textSelection(.enabled)
                Button("Try again", action: retry).keyboardShortcut(.defaultAction)
            case .failed(let message):
                Text("The engine did not start").font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Button("Try again", action: retry).keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Menu bar commands and keyboard shortcuts.
struct EnsembleCommands: Commands {
    let app: AppEngine
    let window: WindowState

    /// A session or a room is on screen, so there are changes to review.
    private var reviewAvailable: Bool {
        window.route == .room ? app.rooms?.selectedEngine != nil : app.store?.selected != nil
    }

    var body: some Commands {
        // Nothing to print; this also frees Shift-Command-P (Page Setup) for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .newItem) {
            Button("New Session") { window.beginNewSession() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(app.store == nil)
            Button("New Room") { app.rooms?.beginNewRoom() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app.rooms == nil)
            Divider()
            Button("Import Claude Sessions...") { if let store = app.store { ClaudeImportCenter.shared.show(store: store) } }
                .disabled(!ClaudeImportCenter.canImport(app.store))
        }

        CommandMenu("Session") {
            Button("Send") { if let store = app.store { window.sendDraft(store: store) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(app.store == nil)
            Button("Stop") { if let store = app.store { Task { await store.stop() } } }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(window.route != .session || !(app.store?.selected?.isWorking ?? false))
            Divider()
            Button("Next Session") { if let store = app.store { window.openNeighbourSession(1, store: store) } }
                .appShortcut(.nextSession)
                .disabled((app.store?.sessions.count ?? 0) < 2)
            Button("Previous Session") { if let store = app.store { window.openNeighbourSession(-1, store: store) } }
                .appShortcut(.previousSession)
                .disabled((app.store?.sessions.count ?? 0) < 2)
            Divider()

            let order = app.store.map { AttentionCenter.shared.sidebarOrder(store: $0) } ?? []
            ForEach(1...9, id: \.self) { number in
                Button(number <= order.count ? order[number - 1].title : "Session \(number)") {
                    if let store = app.store { window.openSession(number: number, store: store) }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                .disabled(number > order.count)
            }
        }

        CommandGroup(after: .windowArrangement) {
            PairIPhoneButton()
        }

        CommandGroup(after: .sidebar) {
            Button(window.showSidebar ? "Hide Sidebar" : "Show Sidebar") { window.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(window.contextPanelVisible ? "Hide Context Panel" : "Show Context Panel") { window.toggleContextPanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            ReviewMenuCommand(isOpen: window.reviewOpen, isAvailable: reviewAvailable) { window.toggleReview() }
            BrowserMenuCommand(isOpen: window.browserOpen) { window.toggleBrowser() }
            TerminalMenuCommand(isOpen: window.terminalOpen, isAvailable: app.store != nil) { window.toggleTerminal() }
            Button("Close Side Pane Tab") { window.closeSidePane() }
                .appShortcut(.closeSidePaneTab)
                .disabled(!(window.showContextPanel && window.sidePane != .context))
            Button(window.sidePaneMaximized ? "Put Side Pane Back" : "Fill Window with Side Pane") { window.toggleSidePaneMaximized() }
                .disabled(!(window.showContextPanel && window.sidePane != .context))
            Divider()
            // Command-= also zooms in (handled by WindowState.installZoomShortcut).
            Button("Zoom In") { window.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { window.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { window.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}

/// Menu bar key equivalents SwiftUI does not let the app change.
@MainActor
enum MenuShortcuts {
    private static var observer: (any NSObjectProtocol)?

    /// Command-semicolon asks a side question (the composer), but AppKit's Edit > Spelling and Grammar > Check
    /// Document Now has the same key equivalent, and the menu bar would take it while the composer's text view has
    /// focus. That item loses its key equivalent (it stays in the menu); done again whenever a menu gains items,
    /// because SwiftUI rebuilds menus.
    static func install() {
        freeSideQuestionKey()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { freeSideQuestionKey() }
        }
    }

    static func freeSideQuestionKey() {
        guard let menu = NSApp.mainMenu else { return }
        clear(in: menu)
    }

    private static func clear(in menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(NSText.checkSpelling(_:)), item.keyEquivalent == ";",
               item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command {
                item.keyEquivalent = ""
            }
            if let submenu = item.submenu { clear(in: submenu) }
        }
    }
}
