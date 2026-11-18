import AppKit
import SwiftUI
import EnsembleKit

/// Settings window: General, Accounts (subscriptions, sign-ins and API keys), Models, Engine, Power.
struct SettingsView: View {
    let store: SessionStore
    @AppStorage(Zoom.storageKey) private var zoom = 1.0

    var body: some View {
        SettingsTabs(store: store)
            .ensembleTheme()
            .environment(\.zoom, CGFloat(Zoom.clamped(zoom)))
    }
}

private struct SettingsTabs: View {
    let store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(store: store)
            }
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsSettingsView(store: store)
            }
            Tab("Alerts", systemImage: "bell.badge") {
                AttentionSettingsTab()
            }
            Tab("Models", systemImage: "cpu") {
                ModelsSettingsView(store: store)
            }
            Tab("Engine", systemImage: "server.rack") {
                EngineSettingsView(store: store)
            }
            Tab("Power", systemImage: "cup.and.saucer") {
                PowerSettingsTab()
            }
            Tab("GitHub", systemImage: "arrow.triangle.pull") {
                GitHubSettingsTab()
            }
        }
        .frame(width: theme.z(640), height: theme.z(560))
        .background(theme.background)
    }
}

/// Default model for new sessions.
struct ModelsSettingsView: View {
    let store: SessionStore
    @Environment(\.theme) private var theme
    @AppStorage("defaultModel") private var defaultModel = ""

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: $defaultModel) {
                    Text("First available").tag("")
                    ForEach(store.models) { model in
                        Text("\(model.name)  (\(model.providerName))").tag(model.ref.description)
                            .disabled(!model.available)
                    }
                }
            } footer: {
                Text("Used for new sessions. Models without an account are disabled until you add one under Accounts.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            Section("Available models") {
                ForEach(store.models) { model in
                    HStack {
                        Text(model.name)
                        Spacer()
                        Text(model.ref.description)
                            .font(theme.font(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                        StatusDot(model.available ? theme.success : theme.textTertiary.opacity(0.5))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .zoomedForm()
        .onChange(of: defaultModel) {
            store.defaultModel = ModelRef(string: defaultModel)
        }
    }
}

/// Appearance and default permission mode.
/// Folders whose own agent settings, hooks and MCP servers may load (see `WorkspaceTrust`).
struct TrustedFoldersSection: View {
    private let trust = WorkspaceTrust.shared
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(trust.folders, id: \.self) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(Self.display(folder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder)
                    Spacer(minLength: 0)
                    Button("Remove") { run { try trust.revoke(folder) } }
                }
            }
            Button("Add Folder\u{2026}", action: addFolder)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Trusted folders")
        } footer: {
            Text("Agents load a trusted folder's own settings, hooks and MCP servers. Elsewhere they run with your settings only, and Gemini does not start.")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Trust"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try trust.trust(url.path) }
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The path with the home folder shown as ~.
    static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct GeneralSettingsView: View {
    let store: SessionStore
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue
    @AppStorage("defaultPermissionMode") private var defaultMode = PermissionMode.auto.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceSetting.allCases) { setting in
                    Text(setting.label).tag(setting.rawValue)
                }
            }
            Picker("Permission mode for new sessions", selection: $defaultMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            TrustedFoldersSection()
        }
        .formStyle(.grouped)
        .zoomedForm()
        .onChange(of: defaultMode) {
            store.defaultPermissionMode = PermissionMode(rawValue: defaultMode) ?? .auto
        }
    }
}

/// Engine status. Fills in once the engine manager is wired in.
struct EngineSettingsView: View {
    let store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: theme.z(6)) {
                        StatusDot(store.isPreview ? theme.warning : (store.engineVersion == nil ? theme.danger : theme.success))
                        Text(store.isPreview ? "Preview data (no engine connected)" : (store.engineVersion == nil ? "Not reachable" : "Running"))
                    }
                }
                LabeledContent("Version", value: store.engineVersion ?? "Unknown")
                LabeledContent("URL", value: store.engineURL?.absoluteString ?? "Unknown")
                LabeledContent("Minimum version", value: EnsembleKit.minimumEngineVersion)
            } footer: {
                Text("Ensemble runs on the OpenCode service, installed with Homebrew.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .zoomedForm()
    }
}

extension View {
    /// Native form controls follow the window zoom through the font and control size.
    func zoomedForm() -> some View { modifier(ZoomedForm()) }
}

private struct ZoomedForm: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(theme.font(size: 13))
            .controlSize(controlSize)
    }

    private var controlSize: ControlSize {
        switch theme.scale {
        case ..<0.9: .small
        case ..<1.2: .regular
        case ..<1.6: .large
        default: .extraLarge
        }
    }
}
