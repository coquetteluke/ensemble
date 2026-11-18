import SwiftUI
import EnsembleKit

/// Settings window: General, Providers (API keys), Models, Engine.
struct SettingsView: View {
    let store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(store: store)
            }
            Tab("Providers", systemImage: "key") {
                ProvidersSettingsView(store: store)
            }
            Tab("Models", systemImage: "cpu") {
                ModelsSettingsView(store: store)
            }
            Tab("Engine", systemImage: "server.rack") {
                EngineSettingsView(store: store)
            }
        }
        .frame(width: 640, height: 560)
        .background(theme.background)
    }
}

/// A provider Ensemble can add a key for.
struct ProviderEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let keyHint: String
    /// The custom provider also needs a base URL.
    var needsBaseURL = false

    static let all: [ProviderEntry] = [
        ProviderEntry(id: "anthropic", name: "Anthropic", keyHint: "sk-ant-..."),
        ProviderEntry(id: "openai", name: "OpenAI", keyHint: "sk-..."),
        ProviderEntry(id: "xai", name: "xAI", keyHint: "xai-..."),
        ProviderEntry(id: "google", name: "Google", keyHint: "AIza..."),
        ProviderEntry(id: "openrouter", name: "OpenRouter", keyHint: "sk-or-..."),
        ProviderEntry(id: "custom", name: "Custom (OpenAI-compatible)", keyHint: "API key", needsBaseURL: true),
    ]
}

/// One card per provider with a secure key field, Save and Remove.
struct ProvidersSettingsView: View {
    let store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        AdaptiveScroll(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("API keys are handed to the engine, which stores them. Ensemble never writes them to disk or logs.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                ForEach(ProviderEntry.all) { entry in
                    ProviderRow(store: store, entry: entry)
                }
            }
            .padding(20)
        }
        .background(theme.background)
    }
}

struct ProviderRow: View {
    let store: SessionStore
    let entry: ProviderEntry
    @Environment(\.theme) private var theme
    @State private var key = ""
    @State private var working = false
    @State private var message: String?
    @State private var failed = false
    @AppStorage("customProviderBaseURL") private var baseURL = ""

    private var connected: Bool {
        store.providers.first { $0.id == entry.id }?.connected ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LetterAvatar(entry.name, size: 22)
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(connected ? theme.success : theme.textTertiary.opacity(0.6))
                    Text(connected ? "Connected" : "No key")
                        .font(.system(size: 12))
                        .foregroundStyle(connected ? theme.textSecondary : theme.textTertiary)
                }
            }
            if entry.needsBaseURL {
                InputField("Base URL, e.g. http://localhost:11434/v1", text: $baseURL, monospaced: true)
            }
            HStack(spacing: 8) {
                InputField(connected ? "Replace key (\(entry.keyHint))" : entry.keyHint, text: $key, secure: true, monospaced: true)
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || working || (entry.needsBaseURL && baseURL.isEmpty))
                if connected {
                    Button("Remove", action: remove)
                        .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                        .disabled(working)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(failed ? theme.danger : theme.textTertiary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border))
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        working = true
        message = nil
        Task {
            do {
                try await store.setAPIKey(providerID: entry.id, key: trimmed)
                key = ""
                failed = false
                message = "Saved"
            } catch {
                failed = true
                message = "Could not save the key: \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func remove() {
        working = true
        message = nil
        Task {
            do {
                try await store.removeAPIKey(providerID: entry.id)
                failed = false
                message = "Removed"
            } catch {
                failed = true
                message = "Could not remove the key: \(error.localizedDescription)"
            }
            working = false
        }
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
                Text("Used for new sessions. Models without a key are disabled until you add one under Providers.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            Section("Available models") {
                ForEach(store.models) { model in
                    HStack {
                        Text(model.name)
                        Spacer()
                        Text(model.ref.description)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                        StatusDot(model.available ? theme.success : theme.textTertiary.opacity(0.5))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: defaultModel) {
            store.defaultModel = ModelRef(string: defaultModel)
        }
    }
}

/// Appearance and default permission mode.
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
        }
        .formStyle(.grouped)
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
                    HStack(spacing: 6) {
                        StatusDot(store.isPreview ? theme.warning : (store.engineVersion == nil ? theme.danger : theme.success))
                        Text(store.isPreview ? "Preview data (no engine connected)" : (store.engineVersion == nil ? "Not reachable" : "Running"))
                    }
                }
                LabeledContent("Version", value: store.engineVersion ?? "Unknown")
                LabeledContent("URL", value: store.engineURL?.absoluteString ?? "Unknown")
                LabeledContent("Minimum version", value: EnsembleKit.minimumEngineVersion)
            } footer: {
                Text("Ensemble runs on the OpenCode service, installed with Homebrew.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .formStyle(.grouped)
    }
}
