import SwiftUI
import EnsembleKit

/// Under the composer: session cost and tokens (opens the usage popover), "Work in a copy" and the branch chip
/// (`WorktreeControls.swift`), the Claude plan limit ring and a small context meter. Shows the widest level that fits
/// (`StatusLineLevel`): labels shorten, then items keep their icons only (the tooltips keep the full text), then the
/// "Work in a copy" switch moves into the composer's More menu (`onWorktreeSwitchHidden`).
struct StatusLine: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    /// Snapshots pass a fixed plan meter; the app reads the Claude engine.
    var planMeter: PlanLimitMeter?
    /// Told whether the level on screen leaves out the "Work in a copy" switch.
    var onWorktreeSwitchHidden: ((Bool) -> Void)?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showUsage = false
    @State private var showBranches = false
    @State private var pendingSwitch: WorktreeStatusControls.PendingSwitch?
    @State private var planLoader = PlanLimitLoader()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(.full)
            line(.short)
            line(.icons)
            line(.minimal)
        }
        .font(theme.font(size: 11.5))
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(30))
        .onChange(of: window.showUsage) {
            if window.showUsage {
                window.showUsage = false
                showUsage = true
            }
        }
        .modifier(WorktreeStatusTasks(store: store, session: session, showBranches: $showBranches, pendingSwitch: $pendingSwitch))
        .modifier(PlanLimitRefresh(store: store, loader: planLoader, enabled: planMeter == nil && !isSnapshot))
    }

    private func line(_ level: StatusLineLevel) -> some View {
        HStack(spacing: theme.z(level.spacing)) {
            usageButton(level)
            PowerStatusChip(store: store)
            WorktreeStatusControls(store: store, session: session, window: window, level: level, showBranches: $showBranches) { branch in
                WorktreeStatusControls.pick(branch, session: session, store: store) { pendingSwitch = $0 }
            }
            Spacer(minLength: theme.z(8))
            PlanLimitStatusItem(meter: planMeter ?? planLoader.meter, compact: level >= .icons) { showUsage = true }
            contextButton(level)
        }
        .onAppear { onWorktreeSwitchHidden?(level == .minimal) }
    }

    private func usageButton(_ level: StatusLineLevel) -> some View {
        let usage = session.usage
        let cost = Format.usd(usage.costUSD)
        let tokens = Format.tokens(usage.inputTokens + usage.outputTokens)
        return Button {
            showUsage.toggle()
        } label: {
            HStack(spacing: theme.z(5)) {
                Image(systemName: "chart.bar")
                    .font(theme.font(size: 10.5))
                switch level {
                case .full: Text("\(cost)  \(tokens) tokens").monospacedDigit()
                case .short, .icons: Text(cost).monospacedDigit()
                case .minimal: EmptyView()
                }
            }
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(level == .full ? "Usage for this session" : "Usage for this session: \(cost), \(tokens) tokens")
        .accessibilityLabel("Usage for this session")
        .accessibilityValue("\(cost), \(tokens) tokens")
        .popover(isPresented: $showUsage, arrowEdge: .top) {
            UsagePopover(usage: usage, title: session.title, store: store) {
                showUsage = false
                window.route = .usage
            }
            .ensembleTheme()
        }
    }

    private func contextButton(_ level: StatusLineLevel) -> some View {
        let context = store.contextBreakdown(for: session)
        let percent = Format.wholePercent(context.fractionUsed)
        return Button {
            if !window.showContextPanel { window.toggleContextPanel() }
        } label: {
            HStack(spacing: theme.z(6)) {
                ContextRing(fraction: context.fractionUsed)
                switch level {
                case .full: Text("\(percent) context").monospacedDigit()
                case .short, .icons: Text(percent).monospacedDigit()
                case .minimal: EmptyView()
                }
            }
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(percent) context: \(Format.tokens(context.usedTokens)) of \(Format.tokens(context.limitTokens)) tokens used")
        .accessibilityLabel("Context")
        .accessibilityValue("\(percent) used")
    }
}

/// How much of the status line fits, widest first.
enum StatusLineLevel: Int, Comparable {
    /// "$0.42  45.6k tokens", "Work in a copy (git worktree)", the branch name, "5h 60%", "8% context".
    case full
    /// "$0.42", "Work in a copy", a shorter branch name, "8%".
    case short
    /// "$0.42", the switch and the branch chip with icons only, the plan ring without its text.
    case icons
    /// Icons and rings only; the "Work in a copy" switch is in the composer's More menu.
    case minimal

    static func < (lhs: StatusLineLevel, rhs: StatusLineLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var spacing: CGFloat {
        switch self {
        case .full: 12
        case .short: 10
        case .icons: 8
        case .minimal: 7
        }
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

/// Session usage numbers, the Claude plan limits, and "Show all usage" (the Usage screen: per agent and provider).
struct UsagePopover: View {
    let usage: Usage
    let title: String
    let store: SessionStore
    /// Opens the Usage screen; nil hides the button.
    var onShowAll: (() -> Void)?
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
            ClaudePlanLimitsSection(store: store)
            if let onShowAll {
                Button(action: onShowAll) {
                    HStack(spacing: theme.z(5)) {
                        Text("Show all usage")
                        Image(systemName: "arrow.right")
                            .font(theme.font(size: 10, weight: .semibold))
                    }
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, theme.z(2))
                .help("Usage per agent and provider, with daily spending caps")
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
