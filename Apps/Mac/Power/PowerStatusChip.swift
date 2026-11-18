import SwiftUI
import EnsembleKit

/// Small icon and text ("Awake" or "Lid lock") shown while Ensemble holds either, for the status line.
/// Click for a popover listing which sessions and rooms hold it, with a button that turns them all off.
/// Draws nothing while Ensemble holds nothing and nothing needs attention.
struct PowerStatusChip: View {
    /// Title for a holder; nil falls back to "Session" or "Room".
    var name: (PowerHolderID) -> String?
    @Environment(PowerController.self) private var power: PowerController?
    @Environment(\.theme) private var theme
    @State private var showPopover = false

    init(name: @escaping (PowerHolderID) -> String? = { _ in nil }) {
        self.name = name
    }

    /// Looks up session titles in the store.
    init(store: SessionStore) {
        self.name = { holder in
            holder.kind == .session ? store.sessions.first { $0.id == holder.id }?.title : nil
        }
    }

    var body: some View {
        // Problems and notices are all about lid lock, so they show under that name while nothing is held.
        if let power, power.heldLevel != .off || power.lidLockProblem != nil || power.notice != nil {
            let level = power.heldLevel
            let warn = power.showsBatteryWarning || power.lidLockProblem != nil
            let symbol = warn ? "exclamationmark.triangle.fill"
                : (level == .off ? "info.circle" : PowerFormat.symbol(for: level))
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: theme.z(5)) {
                    Image(systemName: symbol)
                        .font(theme.font(size: 10.5))
                        .foregroundStyle(warn ? theme.warning : theme.textTertiary)
                    Text(level == .off ? PowerLevel.lidLock.label : level.label)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(theme.font(size: 11.5))
            .foregroundStyle(theme.textTertiary)
            .help(help(level))
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                PowerStatusPopover(name: name)
                    .environment(power)
                    .ensembleTheme()
            }
        }
    }

    private func help(_ level: PowerLevel) -> String {
        switch level {
        case .lidLock: "Ensemble keeps the Mac running with the lid closed"
        case .awake: "Ensemble keeps the Mac awake"
        case .off: "Lid lock status"
        }
    }
}

/// Which holders keep the Mac up, warnings, and Turn off all.
struct PowerStatusPopover: View {
    let name: (PowerHolderID) -> String?
    @Environment(PowerController.self) private var power: PowerController?
    @Environment(\.theme) private var theme

    var body: some View {
        if let power {
            content(power)
        }
    }

    private func content(_ power: PowerController) -> some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            Text(title(power.heldLevel))
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            let holders = power.activeHolders
            if !holders.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(6)) {
                    ForEach(holders, id: \.id) { entry in
                        HStack(spacing: theme.z(8)) {
                            Image(systemName: entry.id.kind == .room ? "person.3" : "bubble.left")
                                .font(theme.font(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: theme.z(16))
                            Text(name(entry.id) ?? entry.id.noun.capitalized)
                                .font(theme.font(size: 12.5))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: theme.z(8))
                            Text(entry.level.label)
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }

            let lines = statusLines(power)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    ForEach(lines) { line in
                        PowerStatusLineView(line: line, power: power)
                    }
                }
            }

            if let notice = power.notice {
                HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
                    Text(notice)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        power.dismissNotice()
                    } label: {
                        Image(systemName: "xmark")
                            .font(theme.font(size: 9, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }

            HStack {
                Spacer()
                Button("Turn off all") { power.turnOffAll() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!power.anySwitchOn)
            }
        }
        .padding(theme.z(16))
        .frame(width: theme.z(280), alignment: .leading)
        .background(theme.popover)
    }

    private func title(_ level: PowerLevel) -> String {
        switch level {
        case .lidLock: "Keeping the Mac running with the lid closed"
        case .awake: "Keeping the Mac awake"
        case .off: "Lid lock"
        }
    }

    private func statusLines(_ power: PowerController) -> [PowerStatusLine] {
        var lines: [PowerStatusLine] = []
        if let problem = power.lidLockProblem {
            lines.append(.init(id: "problem", kind: .warning, text: problem.message, offersSetup: problem == .needsSetup))
        }
        if power.lidLockSource == .external {
            lines.append(.init(id: "external", kind: .info, text: PowerFormat.externalLidLock))
        }
        if power.showsBatteryWarning {
            lines.append(.init(id: "battery", kind: .warning, text: PowerFormat.batteryWarning))
        }
        if !power.activeHolders.isEmpty {
            lines.append(.init(id: "grace", kind: .info,
                               text: "Each turns off \(PowerFormat.duration(power.gracePeriod)) after it stops working."))
        }
        return lines
    }
}
