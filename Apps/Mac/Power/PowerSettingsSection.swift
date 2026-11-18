import SwiftUI
import EnsembleKit

/// Power settings for a grouped `Form`: idle time before release, lid lock setup status, current state.
struct PowerSettingsSection: View {
    @Environment(PowerController.self) private var power: PowerController?
    @Environment(\.theme) private var theme

    var body: some View {
        if let power {
            section(power)
        }
    }

    private func section(_ power: PowerController) -> some View {
        Section {
            Picker("Release after idle for", selection: Binding(
                get: { power.gracePeriod },
                set: { power.setGracePeriod($0) })) {
                ForEach(choices(power), id: \.self) { seconds in
                    Text(PowerFormat.duration(seconds)).tag(seconds)
                }
            }

            if power.hasLid {
                LabeledContent("Lid lock setup") {
                    HStack(spacing: theme.z(8)) {
                        StatusDot(setupColor(power))
                        Text(setupText(power))
                        if power.sudoStatus == .missing {
                            Button(power.setupRunning ? "Waiting for setup" : "Run setup") {
                                PowerSetupPrompt.present(power)
                            }
                            .disabled(power.setupRunning)
                        }
                    }
                }
                if let message = power.setupMessage {
                    Text(message)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.danger)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Now", value: summary(power))
        } header: {
            Text("Power")
        } footer: {
            Text("A session or room stops keeping the Mac awake after it has been idle this long. Its switches stay on for the next time it works.")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func choices(_ power: PowerController) -> [TimeInterval] {
        var values = PowerController.gracePeriodChoices
        if !values.contains(power.gracePeriod) { values.append(power.gracePeriod) }
        return values.sorted()
    }

    private func setupText(_ power: PowerController) -> String {
        switch power.sudoStatus {
        case .ready: "Ready"
        case .missing: "Not set up"
        case .unknown: power.started ? "Checking" : "Not checked"
        }
    }

    private func setupColor(_ power: PowerController) -> Color {
        switch power.sudoStatus {
        case .ready: theme.success
        case .missing: theme.warning
        case .unknown: theme.textTertiary.opacity(0.6)
        }
    }

    private func summary(_ power: PowerController) -> String {
        let count = PowerFormat.holderCount(power.activeHolders.map(\.id))
        let holders = count.isEmpty ? "" : ", \(count)"
        switch power.heldLevel {
        case .off: return "Off"
        case .awake: return "Awake\(holders)"
        case .lidLock: return power.lidLockSource == .external
            ? "Lid lock (already on outside Ensemble)\(holders)"
            : "Lid lock\(holders)"
        }
    }
}

/// `PowerSettingsSection` in its own grouped form, for a Settings tab.
struct PowerSettingsTab: View {
    var body: some View {
        Form {
            PowerSettingsSection()
        }
        .formStyle(.grouped)
    }
}
