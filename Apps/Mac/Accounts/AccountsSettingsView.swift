import SwiftUI
import EnsembleKit

/// Settings > Accounts: "Your subscriptions" (Claude, Google AI, browser sign-ins, cloud accounts, coding plans) and
/// "API keys" (every provider OpenCode can take a key for).
struct AccountsSettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case subscriptions
        case apiKeys
        var id: String { rawValue }
        var title: String { self == .subscriptions ? "Your subscriptions" : "API keys" }
    }

    @Environment(\.theme) private var theme
    @State private var model: AccountsModel
    @State private var section: Section
    @State private var search = ""

    init(store: SessionStore, section: Section = .subscriptions) {
        _model = State(initialValue: AccountsModel(store: store))
        _section = State(initialValue: section)
    }

    /// For snapshots and previews.
    init(model: AccountsModel, section: Section = .subscriptions) {
        _model = State(initialValue: model)
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: theme.z(10)) {
                AccountsSectionSwitcher(selection: $section)
                Spacer()
                if model.loading { Spinner(size: theme.z(11)) }
                Button("Check again") { Task { await model.load(refresh: true) } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.loading || !model.hasEngine)
            }
            .padding(.horizontal, theme.z(20))
            .padding(.top, theme.z(16))
            .padding(.bottom, theme.z(10))
            if let error = model.loadError {
                Text(error)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.z(20))
                    .padding(.bottom, theme.z(6))
            }
            switch section {
            case .subscriptions: subscriptions
            case .apiKeys: apiKeys
            }
        }
        .background(theme.background)
        .task { await model.load() }
        .onDisappear { model.stopAll() }
    }

    private var subscriptions: some View {
        AdaptiveScroll(.vertical) {
            VStack(alignment: .leading, spacing: theme.z(10)) {
                AccountsSectionHeader(title: "Official apps")
                ClaudeAccountRow(model: model)
                AntigravityAccountRow(install: model.antigravity, loading: model.loading)

                if !model.browserSignIns.isEmpty {
                    AccountsSectionHeader(title: "Sign in through the browser")
                    ForEach(model.browserSignIns) { integration in
                        BrowserSignInRow(model: model, integration: integration)
                    }
                }
                if !model.cloudAccounts.isEmpty {
                    AccountsSectionHeader(title: "Cloud accounts")
                    ForEach(model.cloudAccounts) { integration in
                        CloudAccountRow(model: model, integration: integration)
                    }
                }
                if !model.codingPlans.isEmpty {
                    AccountsSectionHeader(title: "Coding plans")
                    ForEach(model.codingPlans) { integration in
                        KeyAccountRow(model: model, integration: integration, collapsible: true)
                    }
                }
            }
            .padding(.horizontal, theme.z(20))
            .padding(.bottom, theme.z(20))
        }
    }

    private var apiKeys: some View {
        let providers = model.keyProviders(matching: search)
        return VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(10)) {
                InputField("Search providers", text: $search, icon: "magnifyingglass")
                Text("\(model.connectedKeyCount) connected")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize()
            }
            .padding(.horizontal, theme.z(20))
            AdaptiveScroll(.vertical) {
                LazyVStack(alignment: .leading, spacing: theme.z(8)) {
                    ForEach(providers) { integration in
                        KeyAccountRow(model: model, integration: integration, collapsible: true, compact: true)
                    }
                    if providers.isEmpty, !model.loading {
                        Text(search.isEmpty ? "No providers loaded." : "No provider matches \"\(search)\".")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.top, theme.z(12))
                    }
                }
                .padding(.horizontal, theme.z(20))
                .padding(.bottom, theme.z(20))
            }
        }
    }
}

/// Two-segment switch between "Your subscriptions" and "API keys".
struct AccountsSectionSwitcher: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AccountsSettingsView.Section

    var body: some View {
        HStack(spacing: theme.z(2)) {
            ForEach(AccountsSettingsView.Section.allCases) { section in
                let selected = section == selection
                Button { selection = section } label: {
                    Text(section.title)
                        .font(theme.font(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, theme.z(12))
                        .frame(height: theme.z(26))
                        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                            .fill(selected ? theme.elevatedHover : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(theme.z(2))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border))
        .fixedSize()
    }
}
