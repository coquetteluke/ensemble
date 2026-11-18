import EnsembleKit
import SwiftUI

/// Spending today and this week, per provider and per agent.
struct UsageView: View {
    let client: RemoteClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let usage = client.usage {
                    HStack(spacing: 10) {
                        total("Today", usage.today)
                        total("This week", usage.week)
                    }
                    if !usage.providers.isEmpty {
                        header("By provider")
                        rows(usage.providers)
                    }
                    if !usage.agents.isEmpty {
                        header("By agent")
                        rows(usage.agents)
                    }
                    Text("Updated \(usage.updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(16)
        }
        .remoteScreen()
        .navigationTitle("Usage")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(client: client) } }
        .refreshable { try? await client.refreshUsage() }
        .task { try? await client.refreshUsage() }
    }

    private func total(_ title: String, _ usage: Usage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(RemoteTheme.secondaryText)
            Text(RemoteFormat.cost(usage.costUSD))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(RemoteTheme.primaryText)
            Text("\(RemoteFormat.tokens(usage.inputTokens)) in · \(RemoteFormat.tokens(usage.outputTokens)) out")
                .font(.caption)
                .foregroundStyle(RemoteTheme.tertiaryText)
        }
        .remoteCard()
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RemoteTheme.secondaryText)
            .padding(.top, 10)
            .padding(.leading, 4)
    }

    private func rows(_ rows: [RemoteUsageSummary.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let hex = row.colorHex {
                            Circle().fill(Color(remoteHex: hex)).frame(width: 8, height: 8)
                        }
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(RemoteTheme.primaryText)
                        Spacer()
                        Text(RemoteFormat.cost(row.usage.costUSD))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(RemoteTheme.primaryText)
                    }
                    if let cap = row.capUSD, cap > 0 {
                        ProgressView(value: min(1, row.usage.costUSD / cap))
                            .tint(row.usage.costUSD >= cap ? RemoteTheme.danger : Color.accentColor)
                        Text("\(RemoteFormat.cost(row.usage.costUSD)) of \(RemoteFormat.cost(cap)) cap")
                            .font(.caption)
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                }
                .padding(.vertical, 10)
                if index < rows.count - 1 {
                    Divider().overlay(RemoteTheme.stroke)
                }
            }
        }
        .remoteCard(padding: 12)
    }
}
