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

    var status: EngineStatus {
        if Self.usePreview, let url = URL(string: "preview://local") { return .running(version: "preview", url: url) }
        return manager.status
    }

    func start() {
        guard store == nil, watchTask == nil else { return }
        if Self.usePreview {
            open(SessionStore(engine: PreviewEngine()))
            return
        }
        manager.start()
        watchTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.manager.statusUpdates() {
                guard case .running = status, self.store == nil, let client = self.manager.client else { continue }
                self.open(SessionStore(engine: client))
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
            await remoteControl.restore()
        }
    }

    func retry() {
        Task { await manager.checkNow() }
    }
}

@main
struct EnsembleApp: App {
    @State private var app = AppEngine()
    @State private var window = WindowState()
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue

    init() {
        // `--render-snapshots <dir>` writes PNGs of key views and quits before any window opens.
        if let directory = SnapshotRenderer.requestedDirectory() {
            SnapshotRenderer.run(outputDirectory: directory)
            exit(0)
        }
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
            .task { app.start() }
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

            let order = app.store?.sidebarOrder ?? []
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
        }
    }
}
