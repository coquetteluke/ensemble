import SwiftUI
import EnsembleKit

/// Permission mode menu: Ask permissions, Accept edits, Plan mode, Auto mode, Bypass permissions (in red). Plan is
/// greyed out, with the reason, where the session's engine has no plan mode.
struct ModeMenuContent: View {
    let current: PermissionMode
    /// Whether the session can use Plan mode; nil while unknown (Plan is offered and checked when chosen).
    var planSupport: PlanModeSupport? = nil
    let onSelect: (PermissionMode) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                let unavailable = mode == .plan ? planSupport?.reason : nil
                Button {
                    onSelect(mode)
                } label: {
                    HStack(alignment: .top, spacing: theme.z(10)) {
                        Image(systemName: mode.symbolName)
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(mode.isDangerous ? theme.danger : theme.textSecondary)
                            .frame(width: theme.z(18), height: theme.z(18))
                        VStack(alignment: .leading, spacing: theme.z(2)) {
                            Text(mode.label)
                                .font(theme.font(size: 13, weight: .medium))
                                .foregroundStyle(mode.isDangerous ? theme.danger : theme.textPrimary)
                            Text(unavailable ?? mode.summary)
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: theme.z(8))
                        if mode == current {
                            Image(systemName: "checkmark")
                                .font(theme.font(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .frame(height: theme.z(18))
                        }
                    }
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(7))
                }
                .buttonStyle(RowButtonStyle(selected: false, cornerRadius: theme.z(7)))
                .disabled(unavailable != nil)
                .opacity(unavailable != nil ? 0.55 : 1)
            }
            HLine()
                .padding(.vertical, theme.z(4))
                .padding(.horizontal, theme.z(6))
            Text("Shift-Tab switches modes")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, theme.z(10))
                .padding(.bottom, theme.z(4))
        }
        .padding(theme.z(6))
        .frame(width: theme.z(300))
        .background(theme.popover)
    }
}

/// Model picker without a session (the schedule editor): the same folders by maker as the composer's picker
/// (`ModelPickerView`), where a pick only sets the model.
struct ModelMenuContent: View {
    let models: [ModelInfo]
    let current: ModelRef?
    /// From `EngineModelBilling`; nil treats Claude and Google plans as subscriptions and everything else as keys.
    let billing: [String: ModelBilling]?
    let onSelect: (ModelRef) -> Void

    init(models: [ModelInfo], current: ModelRef?, billing: [String: ModelBilling]? = nil, onSelect: @escaping (ModelRef) -> Void) {
        self.models = models
        self.current = current
        self.billing = billing
        self.onSelect = onSelect
    }

    var body: some View {
        ModelPickerView(models: models, billing: billing, current: current, context: nil, onPick: onSelect)
    }
}

/// Effort levels the model accepts, with a check on the current one.
struct EffortMenuContent: View {
    let levels: [EffortLevel]
    let current: EffortLevel?
    let onSelect: (EffortLevel) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            Text("Effort")
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, theme.z(10))
                .padding(.top, theme.z(6))
                .padding(.bottom, theme.z(2))
            ForEach(levels, id: \.self) { level in
                Button {
                    onSelect(level)
                } label: {
                    HStack {
                        Text(level.label)
                            .font(theme.font(size: 13))
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: theme.z(16))
                        if level == current {
                            Image(systemName: "checkmark")
                                .font(theme.font(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(6))
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .padding(theme.z(6))
        .frame(width: theme.z(180))
        .background(theme.popover)
    }
}

/// The `/` menu above the composer: Ensemble's commands, the engine's commands, then skills.
/// Arrow keys move, Return picks, Tab completes, Esc closes (handled by the composer).
struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    let selection: Int
    let onHover: (Int) -> Void
    let onPick: (SlashCommand) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        if index == 0 || commands[index - 1].source != command.source {
                            Text(title(command.source))
                                .font(theme.font(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, theme.z(12))
                                .padding(.top, theme.z(index == 0 ? 8 : 12))
                                .padding(.bottom, theme.z(4))
                        }
                        row(command, selected: index == selection)
                            .id(command.id)
                            .onHover { if $0 { onHover(index) } }
                            .onTapGesture { onPick(command) }
                            .help(command.disabledReason ?? "")
                    }
                }
                .padding(.bottom, theme.z(6))
            }
            // Ten 30 pt rows and the bottom padding, so the list never ends through the middle of a row.
            .frame(maxHeight: theme.z(306))
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .onChange(of: selection) {
                if commands.indices.contains(selection) { proxy.scrollTo(commands[selection].id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.popover))
        .overlay(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).strokeBorder(theme.border))
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: theme.z(14), y: theme.z(4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private func row(_ command: SlashCommand, selected: Bool) -> some View {
        HStack(spacing: theme.z(10)) {
            Image(systemName: command.symbol)
                .font(theme.font(size: 12))
                .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                .frame(width: theme.z(18))
            Text("/\(command.name)")
                .font(theme.font(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
            if let hint = command.argumentHint {
                Text(hint)
                    .font(theme.font(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: theme.z(12))
            Text(command.summary)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, theme.z(12))
        .frame(height: theme.z(30))
        .background(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .fill(selected ? theme.selection : .clear)
                .padding(.horizontal, theme.z(4))
        )
        .opacity(command.disabledReason == nil ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(command.disabledReason ?? "")
    }

    private func title(_ source: SlashCommand.Source) -> String {
        switch source {
        case .ensemble: "Ensemble"
        case .engineCommand: "Commands"
        case .engineSkill: "Skills"
        }
    }
}

/// What the composer's More menu holds: the controls the row moved out to fit a narrow pane.
struct ComposerMoreItems: Equatable {
    var effort = false
    var fast = false
    var workInCopy = false
    var attach = false
    var keepAwake = false

    var isEmpty: Bool { !(effort || fast || workInCopy || attach || keepAwake) }

    /// "Effort, Fast mode, Attach files": the tooltip says what is inside.
    var summary: String {
        [effort ? "Effort" : nil, fast ? "Fast mode" : nil, workInCopy ? "Work in a copy" : nil,
         attach ? "Attach files" : nil, keepAwake ? "Keep Mac awake" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// The "..." button in a narrow composer's row: a menu with the effort levels, fast mode, the "Work in a copy" switch,
/// Attach Files and the Keep awake switches, whichever the row moved out. Its icon turns accent while fast mode is on
/// inside it.
struct ComposerMoreMenu: View {
    let store: SessionStore
    let session: SessionModel
    let window: WindowState
    let items: ComposerMoreItems
    let options: ModelOptions?
    let onAttach: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    private var fastOn: Bool { items.fast && session.fastMode }

    var body: some View {
        Group {
            if isSnapshot {
                label
            } else {
                Menu {
                    menuItems
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .onHover { hovering = $0 }
        .help("More: \(items.summary)" + (fastOn ? ". Fast mode is on" : ""))
        .accessibilityLabel("More")
        .accessibilityValue(items.summary)
    }

    private var label: some View {
        Image(systemName: "ellipsis")
            .font(theme.font(size: 13.5, weight: .medium))
            .foregroundStyle(fastOn ? theme.accent : theme.textSecondary)
            .frame(width: theme.z(30), height: theme.z(30))
            .background(Circle().fill(fastOn ? theme.accent.opacity(0.14) : (hovering ? theme.hover : .clear)))
            .contentShape(Circle())
    }

    @ViewBuilder private var menuItems: some View {
        if items.effort, let options {
            Picker("Effort", selection: Binding(
                get: { session.effort ?? options.defaultEffort },
                set: { level in if let level { Task { await store.setEffort(level, for: session.id) } } })) {
                ForEach(options.effortLevels, id: \.self) { level in
                    Text(level.label).tag(Optional(level))
                }
            }
        }
        if items.fast {
            Toggle("Fast Mode", isOn: Binding(get: { session.fastMode },
                                              set: { on in Task { await store.setFastMode(on, for: session.id) } }))
        }
        if items.workInCopy {
            Toggle("Work in a Copy (Git Worktree)", isOn: Binding(
                get: { store.isInWorktree(session.id) },
                set: { on in WorktreeStatusControls.setWorkInCopy(on, session: session, store: store, window: window) }))
                .disabled(store.worktreeSwitchUnavailableReason(session.id) != nil || store.worktrees.busy.contains(session.id))
        }
        if (items.effort || items.fast || items.workInCopy) && (items.attach || items.keepAwake) {
            Divider()
        }
        if items.attach {
            Button("Attach Files\u{2026}", action: onAttach)
        }
        if items.keepAwake {
            PowerMenuItems(holder: .session(session.id))
        }
    }
}
