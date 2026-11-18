import EnsembleKit
import SwiftUI

/// Spending today and this week, subscription plan limits (Claude plan, Google AI plan), per provider and per agent.
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
                    if let plans = usage.plans, !plans.isEmpty {
                        header("Plans")
                        ForEach(plans) { plan in planCard(plan) }
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
                    switch client.state {
                    case .macOffline, .limitReached, .rejected:
                        Text(client.state.statusText)
                            .font(.headline)
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
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

    /// A subscription's limits: one bar per window with "% used" and when it resets, grouped by model group.
    private func planCard(_ plan: RemotePlanUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RemoteTheme.primaryText)
            if plan.limitReached {
                Text(plan.resetsAt.map { "Limit reached. Resets \(Self.resetText($0))" } ?? "Limit reached.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RemoteTheme.danger)
            }
            ForEach(Array(plan.windows.enumerated()), id: \.element.id) { index, window in
                VStack(alignment: .leading, spacing: 5) {
                    if let group = window.group, index == 0 || plan.windows[index - 1].group != group {
                        Text(group)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                            .padding(.top, index == 0 ? 0 : 4)
                    }
                    HStack {
                        Text(window.label)
                            .font(.footnote)
                            .foregroundStyle(RemoteTheme.primaryText)
                        Spacer()
                        Text("\(Int((window.usedFraction * 100).rounded()))% used")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(RemoteTheme.secondaryText)
                    }
                    ProgressView(value: min(max(window.usedFraction, 0), 1))
                        .tint(window.usedFraction >= 1 ? RemoteTheme.danger : (window.usedFraction >= 0.8 ? .orange : Color.accentColor))
                    if let reset = window.resetsAt {
                        Text("Resets \(Self.resetText(reset))")
                            .font(.caption)
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                }
            }
            if let note = plan.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteCard(padding: 12)
    }

    /// "3:40 PM" today, "Thu 9:00 AM" within a week, "Nov 25" later.
    private static func resetText(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.month(.abbreviated).day())
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
