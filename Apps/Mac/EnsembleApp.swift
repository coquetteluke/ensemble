import SwiftUI
import EnsembleKit

/// The one place that chooses the engine. Swap `PreviewEngine()` for the real OpenCode client
/// (WP-A's `OpenCodeClient`) here; nothing else in the app needs to change.
@MainActor
enum EngineFactory {
    static func makeEngine() -> any OpenCodeAPI {
        PreviewEngine()
    }
}

@main
struct EnsembleApp: App {
    @State private var store: SessionStore
    @State private var window = WindowState()
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue

    init() {
        // `--render-snapshots <dir>` writes PNGs of key views and quits before any window opens.
        if let directory = SnapshotRenderer.requestedDirectory() {
            SnapshotRenderer.run(outputDirectory: directory)
            exit(0)
        }
        _store = State(initialValue: SessionStore(engine: EngineFactory.makeEngine()))
    }

    private var colorScheme: ColorScheme? {
        (AppearanceSetting(rawValue: appearance) ?? .dark).colorScheme
    }

    var body: some Scene {
        Window("Ensemble", id: "main") {
            MainView(store: store, window: window)
                .frame(minWidth: 980, minHeight: 620)
                .ensembleTheme()
                .preferredColorScheme(colorScheme)
                .task {
                    let defaults = UserDefaults.standard
                    store.defaultModel = defaults.string(forKey: "defaultModel").flatMap(ModelRef.init(string:))
                    store.defaultPermissionMode = defaults.string(forKey: "defaultPermissionMode").flatMap(PermissionMode.init(rawValue:)) ?? .ask
                    await store.start()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { EnsembleCommands(store: store, window: window) }

        Settings {
            SettingsView(store: store)
                .ensembleTheme()
                .preferredColorScheme(colorScheme)
        }
    }
}

/// Menu bar commands and keyboard shortcuts.
struct EnsembleCommands: Commands {
    let store: SessionStore
    let window: WindowState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { window.beginNewSession() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Session") {
            Button("Send") { window.sendDraft(store: store) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Stop") { Task { await store.stop() } }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!(store.selected?.isWorking ?? false))
            Divider()

            let order = store.sidebarOrder
            ForEach(1...9, id: \.self) { number in
                Button(number <= order.count ? order[number - 1].title : "Session \(number)") {
                    window.openSession(number: number, store: store)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                .disabled(number > order.count)
            }
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
