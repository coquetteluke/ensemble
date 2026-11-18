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
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    /// Sends each session to OpenCode or to the Claude engine (Claude models on the user's own subscription).
    @ObservationIgnored private(set) var router: EngineRouter?

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
        let remoteControl = RemoteControlController(host: MacRemoteHost(store: newStore))
        remote = remoteControl
        Task {
            await newStore.start()
            // Preview builds (often ad-hoc signed) never touch the real pairing in the keychain.
            if !Self.usePreview { await remoteControl.restore() }
        }
    }

    func retry() {
        Task { await manager.checkNow() }
    }

    /// Stops the `claude` and `agy` processes Ensemble started, waiting at most two seconds so quitting
    /// never hangs. (They also exit by themselves once their input closes.)
    private func stopAgentProcesses() {
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
    @State private var app = AppEngine()
    @State private var window = WindowState()
    @State private var power = PowerController.makeForMac()
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue

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
                    MainView(store: store, window: window)
                } else {
                    EngineStatusView(status: app.status, retry: app.retry)
                }
            }
            .frame(minWidth: 980, minHeight: 620)
            .ensembleTheme()
            .preferredColorScheme(colorScheme)
            .environment(power)
            .task { app.start() }
            .task { await power.start() }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { EnsembleCommands(app: app, window: window) }

        Window("Pair iPhone", id: "pair-iphone") {
            Group {
                if let remote = app.remote {
                    RemoteControlSettingsView(controller: remote)
                } else {
                    EngineStatusView(status: app.status, retry: app.retry)
                }
            }
            .frame(minWidth: 480, minHeight: 520)
            .ensembleTheme()
            .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 520, height: 600)

        Settings {
            Group {
                if let store = app.store {
                    SettingsView(store: store)
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { window.beginNewSession() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(app.store == nil)
        }

        CommandMenu("Session") {
            Button("Send") { if let store = app.store { window.sendDraft(store: store) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(app.store == nil)
            Button("Stop") { if let store = app.store { Task { await store.stop() } } }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!(app.store?.selected?.isWorking ?? false))
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
            Button(window.showContextPanel ? "Hide Context Panel" : "Show Context Panel") { window.toggleContextPanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
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
