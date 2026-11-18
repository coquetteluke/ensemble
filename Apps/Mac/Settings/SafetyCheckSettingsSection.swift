import SwiftUI
import EnsembleKit

/// Settings > General > Safety check for Auto: the switch, the model, Accept edits, and what it does and does not
/// protect against. Saved in `UserDefaults` (`SafetyCheckSettings.Key`) and applied to the store at once; a new store
/// reads them at start.
struct SafetyCheckSettingsSection: View {
    let store: SessionStore
    /// Snapshots pass their own defaults and a model list instead of asking the engine.
    var loadsModels = true
    @AppStorage private var enabledSetting: String
    @AppStorage private var modelSetting: String
    @AppStorage private var checkAcceptEdits: Bool
    @Environment(\.theme) private var theme

    init(store: SessionStore, defaults: UserDefaults = .standard, loadsModels: Bool = true) {
        self.store = store
        self.loadsModels = loadsModels
        _enabledSetting = AppStorage(wrappedValue: "", SafetyCheckSettings.Key.enabled, store: defaults)
        _modelSetting = AppStorage(wrappedValue: "", SafetyCheckSettings.Key.model, store: defaults)
        _checkAcceptEdits = AppStorage(wrappedValue: false, SafetyCheckSettings.Key.checkAcceptEdits, store: defaults)
    }

    var body: some View {
        let check = store.safetyCheck
        Section {
            Toggle("Let a model approve routine commands", isOn: Binding(
                get: { check.isOn },
                set: { enabledSetting = $0 ? "on" : "off" }
            ))
            Picker("Model", selection: $modelSetting) {
                Text("Same provider as each session").tag("")
                ForEach(check.models) { model in
                    Text(Self.label(model)).tag(model.ref.description)
                }
                if !modelSetting.isEmpty, !check.models.contains(where: { $0.ref.description == modelSetting }) {
                    Text("\(modelSetting) (not available, each session's provider is used)").tag(modelSetting)
                }
            }
            .disabled(!check.isOn)
            Toggle("Also check commands in Accept edits", isOn: $checkAcceptEdits)
                .disabled(!check.isOn)
        } header: {
            Text("Safety check for Auto")
        } footer: {
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Text("OpenCode agents in Auto ask before any command outside a short read-only list. With this on, a model reads each such command with your latest message and may approve it only if it is a build, a test, a linter or a read-only command such as ls or grep. Everything else asks as before, and so does every command when the model is unsure, answers in any other way, fails or takes longer than 5 seconds. Approved tool cards show Checked, and each session lists the decisions in its side panel.")
                Text(dataLine)
                Text("Always asks, whatever the model says: git, network access, files outside the project, hidden and protected files, commands such as rm -r, sudo, installs and publishing packages, and shell syntax the check cannot read, such as wildcards or $(...).")
                Text("Not a sandbox: an approved command runs with your permissions, and project scripts it starts, such as npm test or make, can do anything. Claude and Gemini agents use their own auto modes.")
            }
            .font(theme.font(size: 11.5))
            .foregroundStyle(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            apply()
            if loadsModels { await store.loadSafetyCheckModels() }
        }
        .onChange(of: enabledSetting) { apply() }
        .onChange(of: modelSetting) { apply() }
        .onChange(of: checkAcceptEdits) { apply() }
    }

    /// Copies the saved choices into the store.
    private func apply() {
        var settings = store.safetyCheck.settings
        settings.enabled = enabledSetting == "on" ? true : (enabledSetting == "off" ? false : nil)
        settings.model = ModelRef(string: modelSetting)
        settings.checkAcceptEdits = checkAcceptEdits
        store.safetyCheck.settings = settings
    }

    /// Where the check's data goes, for the model chosen now.
    private var dataLine: String {
        let chosen = store.safetyCheck.models.first { $0.ref.description == modelSetting }
        if let chosen {
            let provider = chosen.providerName ?? chosen.ref.providerID
            return "Where the data goes: the command, the project folder and your latest message go to \(provider) for every session, whichever provider the session uses."
        }
        return "Where the data goes: the command, the project folder and your latest message go only to the provider the session already uses, to a small model it offers or else the session's own model. Choosing a model above sends them to that model's provider instead."
    }

    /// "Mini, OpenAI, $0.25 / $2 per million tokens" or "Big Pickle, OpenCode, free".
    static func label(_ model: SafetyCheckModel) -> String {
        var parts = [model.name]
        if let provider = model.providerName, !provider.isEmpty { parts.append(provider) }
        if model.inputCostPerMillion == 0, model.outputCostPerMillion == 0 {
            parts.append("free")
        } else {
            parts.append("\(price(model.inputCostPerMillion)) / \(price(model.outputCostPerMillion)) per million tokens")
        }
        return parts.joined(separator: ", ")
    }

    private static func price(_ value: Double) -> String {
        value.rounded() == value ? "$\(Int(value))" : String(format: "$%.2f", value)
    }
}
