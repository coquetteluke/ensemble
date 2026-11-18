import SwiftUI
import EnsembleKit

/// Permission mode menu: Ask permissions, Accept edits, Auto mode, Bypass permissions (in red).
struct ModeMenuContent: View {
    let current: PermissionMode
    let onSelect: (PermissionMode) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 12.5))
                            .foregroundStyle(mode.isDangerous ? theme.danger : theme.textSecondary)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(mode.isDangerous ? theme.danger : theme.textPrimary)
                            Text(mode.summary)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer(minLength: 8)
                        if mode == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .frame(height: 18)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .buttonStyle(RowButtonStyle(selected: false, cornerRadius: 7))
            }
            HLine()
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            Text("Shift-Tab switches modes")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: 300)
        .background(theme.popover)
    }
}

/// Model picker grouped by provider. Models without a key are listed but disabled.
struct ModelMenuContent: View {
    let models: [ModelInfo]
    let current: ModelRef?
    let onSelect: (ModelRef) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if models.count > 8 {
                InputField("Search models", text: $query, icon: "magnifyingglass", height: 28)
                    .padding(8)
            }
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.name) { group in
                        Text(group.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.models) { model in
                            row(model)
                        }
                    }
                    if groups.isEmpty {
                        Text(models.isEmpty ? "No models. Add an API key in Settings." : "No matches")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                            .padding(10)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 290)
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
        var order: [String] = []
        var byProvider: [String: [ModelInfo]] = [:]
        for model in filtered {
            if byProvider[model.providerName] == nil { order.append(model.providerName) }
            byProvider[model.providerName, default: []].append(model)
        }
        return order.map { Group(name: $0, models: byProvider[$0] ?? []) }
    }

    private func row(_ model: ModelInfo) -> some View {
        let selected = current.map { $0.providerID == model.ref.providerID && $0.id == model.ref.id } ?? false
        return Button {
            onSelect(model.ref)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 13))
                        .foregroundStyle(model.available ? theme.textPrimary : theme.textTertiary)
                    if let limit = model.contextLimit {
                        Text("\(Format.tokens(limit)) context")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                if !model.available {
                    Text("No key")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(RowButtonStyle(selected: false))
        .disabled(!model.available)
    }
}
