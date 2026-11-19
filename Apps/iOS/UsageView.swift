import EnsembleKit
import SwiftUI

/// Spending summary, subscription plan limit meters, and provider/agent breakdowns.
struct UsageView: View {
    let client: RemoteClient
    var showStatusInToolbar = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let usage = client.usage {
                    HStack(spacing: 12) {
                        UsageTotalTile(title: "Today", usage: usage.today)
                        UsageTotalTile(title: "This week", usage: usage.week)
                    }

                    if let plans = usage.plans, !plans.isEmpty {
                        UsageSectionBlock(title: "Plans") {
                            VStack(spacing: 12) {
                                ForEach(plans) { plan in
                                    UsagePlanCard(plan: plan)
                                }
                            }
                        }
                    }

                    if !usage.providers.isEmpty {
                        UsageSectionBlock(title: "By provider") {
                            UsageBreakdownCard(rows: usage.providers)
                        }
                    }

                    if !usage.agents.isEmpty {
                        UsageSectionBlock(title: "By agent") {
                            UsageBreakdownCard(rows: usage.agents)
                        }
                    }

                    Text("Updated \(usage.updated.formatted(date: .omitted, time: .shortened))")
                        .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                } else {
                    UsageEmptyState(client: client)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, RemoteTheme.screenHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .remoteScreen()
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showStatusInToolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(client: client, inToolbar: true)
                }
            }
        }
        .refreshable { try? await client.refreshUsage() }
        .task { try? await client.refreshUsage() }
    }
}

private struct UsageEmptyState: View {
    let client: RemoteClient

    var body: some View {
        switch client.state {
        case .macOffline, .limitReached, .rejected:
            VStack(spacing: 12) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(RemoteTheme.tertiaryText)
                Text(client.state.statusText)
                    .font(RemoteTheme.font(size: 16, weight: .medium, relativeTo: .headline))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 72)
        default:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        }
    }
}

private struct UsageSectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.secondaryText)
                .padding(.leading, 2)
            content
        }
    }
}

private struct UsageTotalTile: View {
    let title: String
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.secondaryText)
            Text(RemoteFormat.cost(usage.costUSD))
                .font(RemoteTheme.font(size: 24, weight: .semibold, relativeTo: .title2).monospacedDigit())
                .foregroundStyle(RemoteTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(RemoteFormat.tokens(usage.inputTokens)) in · \(RemoteFormat.tokens(usage.outputTokens)) out")
                .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(RemoteTheme.tertiaryText)
                .lineLimit(1)
        }
        .remoteCard()
    }
}

private struct UsagePlanCard: View {
    let plan: RemotePlanUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(plan.title)
                    .font(RemoteTheme.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(RemoteTheme.primaryText)
                Spacer()
                if plan.limitReached {
                    Chip(text: "Limit reached", color: RemoteTheme.danger)
                }
            }

            if plan.limitReached {
                Text(plan.resetsAt.map { "Resets \(Self.resetText($0))" } ?? "Limit reached.")
                    .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.danger)
            }

            ForEach(Array(plan.windows.enumerated()), id: \.element.id) { index, window in
                VStack(alignment: .leading, spacing: 6) {
                    if let group = window.group, index == 0 || plan.windows[index - 1].group != group {
                        Text(group)
                            .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                            .padding(.top, index == 0 ? 0 : 4)
                    }

                    HStack {
                        Text(window.label)
                            .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.primaryText)
                        Spacer()
                        Text("\(Int((min(max(window.usedFraction, 0), 1) * 100).rounded()))% used")
                            .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote).monospacedDigit())
                            .foregroundStyle(RemoteTheme.secondaryText)
                    }

                    RemoteMeterBar(fraction: window.usedFraction, tint: meterColor(window.usedFraction), height: 6)

                    if let reset = window.resetsAt {
                        Text("Resets \(Self.resetText(reset))")
                            .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                }
            }

            if let note = plan.note {
                Text(note)
                    .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .remoteCard()
    }

    private func meterColor(_ fraction: Double) -> Color {
        if fraction >= 1 { return RemoteTheme.danger }
        if fraction >= 0.8 { return RemoteTheme.warning }
        return RemoteTheme.accent
    }

    private static func resetText(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct UsageBreakdownCard: View {
    let rows: [RemoteUsageSummary.Row]

    private var totalCost: Double {
        let sum = rows.reduce(0) { $0 + $1.usage.costUSD }
        return max(sum, 0.0001)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let barColor = row.colorHex.map { Color(remoteHex: $0) } ?? RemoteTheme.accent
                let share = row.usage.costUSD / totalCost

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        if let hex = row.colorHex {
                            Circle().fill(Color(remoteHex: hex)).frame(width: 9, height: 9)
                        }
                        Text(row.label)
                            .font(RemoteTheme.font(size: 14.5, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(RemoteTheme.primaryText)
                        Spacer()
                        Text(RemoteFormat.cost(row.usage.costUSD))
                            .font(RemoteTheme.font(size: 14.5, weight: .semibold, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(RemoteTheme.primaryText)
                    }

                    if let cap = row.capUSD, cap > 0 {
                        RemoteMeterBar(
                            fraction: row.usage.costUSD / cap,
                            tint: row.usage.costUSD >= cap ? RemoteTheme.danger : barColor,
                            height: 6
                        )
                        HStack {
                            Text("\(RemoteFormat.tokens(row.usage.inputTokens)) in · \(RemoteFormat.tokens(row.usage.outputTokens)) out")
                            Spacer()
                            Text("\(RemoteFormat.cost(row.usage.costUSD)) of \(RemoteFormat.cost(cap)) cap")
                        }
                        .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(RemoteTheme.tertiaryText)
                    } else {
                        RemoteMeterBar(fraction: share, tint: barColor, height: 5)
                        HStack {
                            Text("\(RemoteFormat.tokens(row.usage.inputTokens)) in · \(RemoteFormat.tokens(row.usage.outputTokens)) out")
                            Spacer()
                            Text("\(Int((share * 100).rounded()))%")
                        }
                        .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                }
                .padding(.vertical, 11)

                if index < rows.count - 1 {
                    Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                }
            }
        }
        .remoteCard()
    }
}
