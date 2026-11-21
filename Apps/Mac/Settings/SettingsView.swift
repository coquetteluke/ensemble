import AppKit
import SwiftUI
import EnsembleKit

/// Settings window: General, Accounts (subscriptions, sign-ins and API keys), Alerts, Models, Engine, Power, Remote,
/// GitHub, Customizations.
struct SettingsView: View {
    let store: SessionStore
    var remote: RemoteControlController? = nil
    @AppStorage(Zoom.storageKey) private var zoom = 1.0

    var body: some View {
        SettingsTabs(store: store, remote: remote)
            .ensembleTheme()
            .environment(\.zoom, CGFloat(Zoom.clamped(zoom)))
    }
}

private struct SettingsTabs: View {
    let store: SessionStore
    let remote: RemoteControlController?
    @Environment(\.theme) private var theme
    /// The selected tab, kept so other screens can open Settings on a tab (`CustomizationsFocus.show`).
    @AppStorage(CustomizationsFocus.tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettingsView(store: store)
            }
            Tab("Accounts", systemImage: "person.crop.circle", value: "accounts") {
                AccountsSettingsView(store: store)
            }
            Tab("Alerts", systemImage: "bell.badge", value: "alerts") {
                AttentionSettingsTab()
            }
            Tab("Models", systemImage: "cpu", value: "models") {
                ModelsSettingsView(store: store)
            }
            Tab("Engine", systemImage: "server.rack", value: "engine") {
                EngineSettingsView(store: store)
            }
            Tab("Power", systemImage: "cup.and.saucer", value: "power") {
                PowerSettingsTab()
            }
            if let remote {
                Tab("Remote", systemImage: "iphone", value: "remote") {
                    RemoteControlSettingsView(controller: remote)
                }
            }
            Tab("GitHub", systemImage: "arrow.triangle.pull", value: "github") {
                GitHubSettingsTab()
            }
            Tab("Customizations", systemImage: "puzzlepiece.extension", value: CustomizationsFocus.tabValue) {
                CustomizationsSettingsTab(store: store)
            }
        }
        // The Customizations tab compares three engines side by side, so it gets a wider window.
        .frame(width: theme.z(isWide ? 960 : 640), height: theme.z(isWide ? 660 : 560))
        .background(theme.background)
    }

    private var isWide: Bool { tab == CustomizationsFocus.tabValue }
}

/// Default model for new sessions.
struct ModelsSettingsView: View {
    let store: SessionStore
    @Environment(\.theme) private var theme
    @AppStorage("defaultModel") private var defaultModel = ""
    @State private var modelBilling: [String: ModelBilling]?

    var body: some View {
        let folders = ModelCatalog.folders(store.models, billing: modelBilling)
        let selectedRef = ModelRef(string: defaultModel)
        let selection = Binding<String>(
            get: {
                guard !defaultModel.isEmpty else { return "" }
                return ModelCatalog.resolvedRef(for: selectedRef, in: folders)?.description ?? defaultModel
            },
            set: { defaultModel = $0 }
        )
        Form {
            Section {
                Picker("Default model", selection: selection) {
                    Text("First available").tag("")
                    ForEach(folders) { folder in
                        Section(folder.maker.name) {
                            ForEach(folder.all) { choice in
                                if let route = ModelCatalog.pickerRoute(for: choice, selected: selectedRef) {
                                    Text("\(choice.name)  (\(route.providerName))").tag(route.ref.description)
                                        .disabled(!choice.available)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Used for new sessions. Models without an account are disabled until you add one under Accounts.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            Section("Available models") {
                ForEach(folders.flatMap(\.all)) { choice in
                    if let route = ModelCatalog.pickerRoute(for: choice, selected: selectedRef) {
                        HStack {
                            Text(choice.name)
                            Spacer()
                            Text(route.ref.description)
                                .font(theme.font(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.textTertiary)
                            StatusDot(choice.available ? theme.success : theme.textTertiary.opacity(0.5))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .zoomedForm()
        .task(id: store.models.count) {
            guard let billing = store.engine as? any EngineModelBilling else { return }
            modelBilling = try? await billing.modelBilling()
        }
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
            ForEach(trust.folders + trust.onlyThisFolder, id: \.self) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(Self.display(folder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder)
                    if trust.onlyThisFolder.contains(folder) {
                        Text("Only this folder")
                            .foregroundStyle(.secondary)
                    }
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
            Text("Agents load a trusted folder's own settings, hooks and MCP servers. Elsewhere they run with your settings only, and Gemini does not start. Trusting a folder trusts the folders inside it, except your home folder, which is trusted on its own.")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Trust"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The home folder is trusted on its own: trusting what is inside it would trust every project.
        let isHome = WorkspaceTrust.resolvedPath(url.path) == trust.homeFolder
        run { try trust.trust(url.path, includingSubfolders: !isHome) }
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
            FontSettingsSection()
            SafetyCheckSettingsSection(store: store)
            TrustedFoldersSection()
            WorktreesSettingsSection(store: store)
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
