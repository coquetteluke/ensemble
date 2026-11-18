import SwiftUI
import EnsembleKit

/// Under the composer: session cost and tokens (opens the usage popover) and a small context meter.
struct StatusLine: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme
    @State private var showUsage = false

    var body: some View {
        let usage = session.usage
        let context = store.contextBreakdown(for: session)
        HStack(spacing: theme.z(12)) {
            Button {
                showUsage.toggle()
            } label: {
                HStack(spacing: theme.z(5)) {
                    Image(systemName: "chart.bar")
                        .font(theme.font(size: 10.5))
                    Text("\(Format.usd(usage.costUSD))  \(Format.tokens(usage.inputTokens + usage.outputTokens)) tokens")
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Usage for this session")
            .onChange(of: window.showUsage) {
                if window.showUsage {
                    window.showUsage = false
                    showUsage = true
                }
            }
            .popover(isPresented: $showUsage, arrowEdge: .top) {
                UsagePopover(usage: usage, title: session.title)
                    .ensembleTheme()
            }

            PowerStatusChip(store: store)

            Spacer(minLength: theme.z(8))

            Button {
                if !window.showContextPanel { window.toggleContextPanel() }
            } label: {
                HStack(spacing: theme.z(6)) {
                    ContextRing(fraction: context.fractionUsed)
                    Text("\(Format.wholePercent(context.fractionUsed)) context")
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(Format.tokens(context.usedTokens)) of \(Format.tokens(context.limitTokens)) tokens used")
        }
        .font(theme.font(size: 11.5))
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(30))
    }
}

/// Ring that fills with context use; amber above 70%, red above 90%.
struct ContextRing: View {
    let fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: theme.z(11), height: theme.z(11))
    }

    private var color: Color {
        fraction > 0.9 ? theme.danger : (fraction > 0.7 ? theme.warning : theme.textSecondary)
    }
}

/// Session usage numbers. The full usage screen (per agent and provider) comes with the Usage work package.
struct UsagePopover: View {
    let usage: Usage
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            Text("This session")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(Format.usd(usage.costUSD))
                .font(theme.font(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: theme.z(24), verticalSpacing: theme.z(6)) {
                row("Input", usage.inputTokens)
                row("Output", usage.outputTokens)
                row("Reasoning", usage.reasoningTokens)
                row("Cache read", usage.cacheReadTokens)
                row("Cache write", usage.cacheWriteTokens)
            }
        }
        .padding(theme.z(16))
        .frame(width: theme.z(240), alignment: .leading)
        .background(theme.popover)
    }

    private func row(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.textSecondary)
            Text(Format.tokens(value))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .gridColumnAlignment(.trailing)
        }
        .font(theme.font(size: 12.5))
    }
}
