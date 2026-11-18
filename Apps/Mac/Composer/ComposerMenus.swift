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

/// Model picker grouped by who pays ("Your subscriptions", "API keys", "Free", "On this Mac") when the engine knows,
/// otherwise by provider. Models without a key are listed but disabled.
struct ModelMenuContent: View {
    let models: [ModelInfo]
    let current: ModelRef?
    /// From `EngineModelBilling`; nil groups by provider.
    let billing: [String: ModelBilling]?
    let onSelect: (ModelRef) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var query = ""

    init(models: [ModelInfo], current: ModelRef?, billing: [String: ModelBilling]? = nil, onSelect: @escaping (ModelRef) -> Void) {
        self.models = models
        self.current = current
        self.billing = billing
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if models.count > 8 {
                InputField("Search models", text: $query, icon: "magnifyingglass", height: theme.z(28))
                    .padding(theme.z(8))
            }
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    ForEach(groups, id: \.name) { group in
                        Text(group.name)
                            .font(theme.font(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, theme.z(10))
                            .padding(.top, theme.z(8))
                            .padding(.bottom, theme.z(2))
                        ForEach(group.models) { model in
                            row(model)
                        }
                    }
                    if groups.isEmpty {
                        Text(models.isEmpty ? "No models. Add an API key in Settings." : "No matches")
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                            .padding(theme.z(10))
                    }
                }
                .padding(theme.z(6))
            }
            .frame(maxHeight: theme.z(380))
        }
        .frame(width: theme.z(290))
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.popover)
    }

    private struct Group {
        let name: String
        let models: [ModelInfo]
    }

    private var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? models : models.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.ref.description.localizedCaseInsensitiveContains(q)
        }
        if let billing {
            return ModelGroup.groups(filtered, billing: billing).map { Group(name: $0.title, models: $0.models) }
        }
        var order: [String] = []
        var byProvider: [String: [ModelInfo]] = [:]
        for model in filtered {
            if byProvider[model.providerName] == nil { order.append(model.providerName) }
            byProvider[model.providerName, default: []].append(model)
        }
        return order.map { Group(name: $0, models: byProvider[$0] ?? []) }
    }

    /// Under the name: the provider when the groups are by billing, and the context size.
    private func detail(_ model: ModelInfo) -> String? {
        var parts: [String] = []
        if billing != nil, !model.providerName.isEmpty { parts.append(model.providerName) }
        if let limit = model.contextLimit { parts.append("\(Format.tokens(limit)) context") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func row(_ model: ModelInfo) -> some View {
        let selected = current.map { $0.providerID == model.ref.providerID && $0.id == model.ref.id } ?? false
        return Button {
            onSelect(model.ref)
        } label: {
            HStack(spacing: theme.z(8)) {
                VStack(alignment: .leading, spacing: theme.z(1)) {
                    Text(model.name)
                        .font(theme.font(size: 13))
                        .foregroundStyle(model.available ? theme.textPrimary : theme.textTertiary)
                    if let detail = detail(model) {
                        Text(detail)
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: theme.z(8))
                if !model.available {
                    Text("No key")
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.textTertiary)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(6))
        }
        .buttonStyle(RowButtonStyle(selected: false))
        .disabled(!model.available)
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
            .frame(maxHeight: theme.z(320))
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
