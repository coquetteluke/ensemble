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
        HStack(spacing: 12) {
            Button {
                showUsage.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 10.5))
                    Text("\(Format.usd(usage.costUSD))  \(Format.tokens(usage.inputTokens + usage.outputTokens)) tokens")
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Usage for this session")
            .popover(isPresented: $showUsage, arrowEdge: .top) {
                UsagePopover(usage: usage, title: session.title)
                    .ensembleTheme()
            }

            Spacer(minLength: 8)

            Button {
                if !window.showContextPanel { window.toggleContextPanel() }
            } label: {
                HStack(spacing: 6) {
                    ContextRing(fraction: context.fractionUsed)
                    Text("\(Format.wholePercent(context.fractionUsed)) context")
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(Format.tokens(context.usedTokens)) of \(Format.tokens(context.limitTokens)) tokens used")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 30)
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
        .frame(width: 11, height: 11)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("This session")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(Format.usd(usage.costUSD))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Input", usage.inputTokens)
                row("Output", usage.outputTokens)
                row("Reasoning", usage.reasoningTokens)
                row("Cache read", usage.cacheReadTokens)
                row("Cache write", usage.cacheWriteTokens)
            }
        }
        .padding(16)
        .frame(width: 240, alignment: .leading)
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
        .font(.system(size: 12.5))
    }
}
