import SwiftUI
import EnsembleKit

/// "Keep Mac awake" and "Keep running with the lid closed" for one session or room, as popover content.
/// Lid lock turns Keep awake on; Keep awake off turns lid lock off. The lid row is hidden on Macs
/// without a lid. Reads the controller from the environment (`.environment(power)`).
struct PowerMenu: View {
    let holder: PowerHolderID
    @Environment(PowerController.self) private var power: PowerController?
    @Environment(\.theme) private var theme

    var body: some View {
        if let power {
            content(power)
        }
    }

    private func content(_ power: PowerController) -> some View {
        let level = power.level(for: holder)
        let lines = statusLines(power, level: level)
        return VStack(alignment: .leading, spacing: theme.z(2)) {
            switchRow(symbol: "cup.and.saucer", title: "Keep Mac awake", isOn: Binding(
                get: { power.level(for: holder).keepAwake },
                set: { power.setKeepAwake($0, for: holder) }))
            if power.hasLid {
                switchRow(symbol: "laptopcomputer", title: "Keep running with the lid closed", isOn: Binding(
                    get: { power.level(for: holder).lidLock },
                    set: { power.setLidLock($0, for: holder) }))
            }
            if !lines.isEmpty {
                HLine()
                    .padding(.vertical, theme.z(4))
                    .padding(.horizontal, theme.z(6))
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    ForEach(lines) { line in
                        PowerStatusLineView(line: line, power: power)
                    }
                }
                .padding(.horizontal, theme.z(10))
                .padding(.bottom, theme.z(6))
            }
        }
        .padding(theme.z(6))
        .frame(width: theme.z(300))
        .background(theme.popover)
    }

    private func switchRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: theme.z(10)) {
                Image(systemName: symbol)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: theme.z(18), height: theme.z(18))
                Text(title)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .toggleStyle(CompactSwitchStyle())
        .accessibilityLabel(title)
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(7))
    }

    private func statusLines(_ power: PowerController, level: PowerLevel) -> [PowerStatusLine] {
        guard level > .off else { return [] }
        var lines: [PowerStatusLine] = []
        let noun = holder.noun
        let grace = PowerFormat.duration(power.gracePeriod)
        if power.isHolding(holder) {
            lines.append(.init(id: "state", kind: .active, text: "On while this \(noun) works and for \(grace) after."))
        } else {
            lines.append(.init(id: "state", kind: .info, text: "Paused until this \(noun) works again."))
        }
        guard level.lidLock, power.hasLid else { return lines }
        if let problem = power.lidLockProblem {
            lines.append(.init(id: "problem", kind: .warning, text: problem.message, offersSetup: problem == .needsSetup))
        } else if power.sudoStatus == .missing {
            lines.append(.init(id: "problem", kind: .warning, text: LidLockProblem.needsSetup.message, offersSetup: true))
        }
        if power.isHolding(holder) && power.lidLockSource == .external {
            lines.append(.init(id: "external", kind: .info, text: PowerFormat.externalLidLock))
        }
        if power.showsBatteryWarning {
            lines.append(.init(id: "battery", kind: .warning, text: PowerFormat.batteryWarning))
        }
        return lines
    }
}

/// One line of state under the switches.
struct PowerStatusLine: Identifiable, Equatable {
    enum Kind { case active, info, warning }
    let id: String
    let kind: Kind
    let text: String
    var offersSetup = false
}

struct PowerStatusLineView: View {
    let line: PowerStatusLine
    let power: PowerController
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(7)) {
            switch line.kind {
            case .active:
                StatusDot(theme.success, size: 6)
            case .info:
                StatusDot(theme.textTertiary.opacity(0.6), size: 6)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.warning)
            }
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Text(line.text)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(line.kind == .warning ? theme.textPrimary : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if line.offersSetup {
                    Button(power.setupRunning ? "Waiting for setup" : "Set up") {
                        PowerSetupPrompt.present(power)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(power.setupRunning)
                }
            }
        }
    }
}

/// Round icon button for the composer row that opens `PowerMenu`. Filled and tinted while the switch is on.
struct PowerMenuButton: View {
    let holder: PowerHolderID
    @Environment(PowerController.self) private var power: PowerController?
    @Environment(\.theme) private var theme
    @State private var showMenu = false
    @State private var hovering = false

    var body: some View {
        if let power {
            let level = power.hasLid ? power.level(for: holder) : min(power.level(for: holder), .awake)
            let holding = power.isHolding(holder)
            Button {
                showMenu.toggle()
            } label: {
                Image(systemName: PowerFormat.symbol(for: level))
                    .font(theme.font(size: 13.5))
                    .foregroundStyle(level > .off && holding ? theme.accent : theme.textSecondary)
                    .frame(width: theme.z(30), height: theme.z(30))
                    .background(Circle().fill(hovering ? theme.hover : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(level == .off ? "Keep Mac awake" : "Keep Mac awake: \(level.label)")
            .accessibilityLabel("Keep Mac awake")
            .accessibilityValue(level.label)
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                PowerMenu(holder: holder)
                    .environment(power)
                    .ensembleTheme()
            }
        }
    }
}

/// The two switches as native menu items, for a sidebar row's context menu or a "..." menu.
struct PowerMenuItems: View {
    let holder: PowerHolderID
    @Environment(PowerController.self) private var power: PowerController?

    var body: some View {
        if let power {
            Toggle("Keep Mac Awake", isOn: Binding(
                get: { power.level(for: holder).keepAwake },
                set: { power.setKeepAwake($0, for: holder) }))
            if power.hasLid {
                Toggle("Keep Running with the Lid Closed", isOn: Binding(
                    get: { power.level(for: holder).lidLock },
                    set: { power.setLidLock($0, for: holder) }))
            }
        }
    }
}
