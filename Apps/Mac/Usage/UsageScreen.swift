import SwiftUI
import EnsembleKit

/// The Usage view (from the usage popover's Show all, or /usage): today, the last 7 days or the last 30 days, with totals
/// per provider, per agent and per session. Costs are shown for models billed to API keys; every model shows tokens;
/// subscriptions show their plan limits. Below, the daily spending caps for API-key providers.
struct UsageScreen: View {
    let store: SessionStore
    /// Snapshots pass their own tracker; the app uses the one attached to the store.
    var tracker: UsageTracker?
    /// Snapshots pass Claude plan limits; the app reads the Claude engine.
    var planLimits: ClaudePlanLimits?
    /// Snapshots pass the Google AI plan; the app reads agy's `/usage`.
    var googlePlan: AntigravityPlanStatus?
    var initialRange: UsageRange = .today
    /// Snapshots open the full session list.
    var showAllSessions = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var range: UsageRange?
    @State private var allSessions = false

    static let sessionPreview = 8

    var body: some View {
        if let tracker = tracker ?? store.usageTracker ?? UsageCenter.shared.tracker {
            content(tracker)
                .task {
                    guard !isSnapshot else { return }
                    tracker.sample()
                }
        } else {
            VStack(spacing: theme.z(10)) {
                Spinner(size: 14)
                Text("Loading usage")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var currentRange: UsageRange { range ?? initialRange }

    private func content(_ tracker: UsageTracker) -> some View {
        let report = tracker.report(currentRange)
        return AdaptiveScroll(.vertical) {
            VStack(alignment: .leading, spacing: theme.z(18)) {
                ScheduleSegmented(options: UsageRange.allCases.map { ($0, $0.label) },
                                  selection: Binding(get: { currentRange }, set: { range = $0 }))
                    .frame(maxWidth: theme.z(380))
                tiles(report)
                ForEach(plans) { plan in
                    switch plan {
                    case .claude: planCard
                    case .googleAI: googlePlanCard
                    }
                }
                if report.total.usage == .zero {
                    Text("No usage \(currentRange == .today ? "today" : "in the \(currentRange.label.lowercased())").")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.vertical, theme.z(8))
                } else {
                    UsageTable(title: "By provider", lines: report.providers)
                    UsageTable(title: "By agent", lines: report.agents)
                    let sessions = (allSessions || showAllSessions) ? report.sessions : Array(report.sessions.prefix(Self.sessionPreview))
                    UsageTable(title: "By session", lines: sessions,
                               more: (allSessions || showAllSessions || report.sessions.count <= Self.sessionPreview)
                                   ? nil : ("Show all \(report.sessions.count)", { allSessions = true }))
                }
                UsageCapsSection(tracker: tracker)
                Text("Engines report running totals without dates, so use from before Ensemble opened counts on each session's "
                     + "last active day.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: theme.z(820), alignment: .leading)
            .padding(.horizontal, theme.z(28))
            .padding(.top, theme.z(16))
            .padding(.bottom, theme.z(28))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Totals

    private func tiles(_ report: UsageReport) -> some View {
        let total = report.total
        return HStack(spacing: theme.z(10)) {
            UsageTile(title: "API cost", value: Format.usd(total.apiCostUSD), detail: "Billed to API keys")
            UsageTile(title: "Tokens", value: Format.tokens(total.tokens),
                      detail: "In \(Format.tokens(total.usage.inputTokens)), out \(Format.tokens(total.usage.outputTokens + total.usage.reasoningTokens))")
            UsageTile(title: "Sessions", value: "\(report.sessionCount)",
                      detail: report.agents.count == 1 ? "1 agent" : "\(report.agents.count) agents")
        }
    }

    // MARK: Plan limits

    /// Every plan the app has (or the snapshot passes), the selected session's first.
    private var plans: [SubscriptionPlan] {
        var available = PlanEngines.available(store)
        if planLimits != nil, !available.contains(.claude) { available.append(.claude) }
        if googlePlan != nil, !available.contains(.googleAI) { available.append(.googleAI) }
        return SubscriptionPlan.ordered(available, current: PlanEngines.plan(of: store.selected, store: store))
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if let planLimits {
                Text("Claude plan")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                PlanLimitsView(limits: planLimits)
            } else {
                ClaudePlanLimitsSection(store: store)
            }
        }
        .modifier(PlanCardStyle())
    }

    private var googlePlanCard: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if let googlePlan {
                GooglePlanLimitsSection(store: store, snapshot: PlanUsageSnapshot(plans: [.googleAI], google: googlePlan,
                                                                                    googleTokensToday: PlanEngines.googleTokensToday(store)))
            } else {
                GooglePlanLimitsSection(store: store)
            }
        }
        .modifier(PlanCardStyle())
    }
}

/// The card around a plan on the Usage screen.
private struct PlanCardStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(theme.z(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
    }
}

/// A headline number with a label above and a line below.
struct UsageTile: View {
    let title: String
    let value: String
    let detail: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            Text(title)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(theme.font(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
        .padding(theme.z(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
    }
}

/// Rows of usage under a heading: name and detail, input, output, and cost (or "Plan", "Free", "This Mac" when nothing in
/// the row is billed to an API key).
struct UsageTable: View {
    let title: String
    let lines: [UsageLine]
    var more: (label: String, action: () -> Void)?
    @Environment(\.theme) private var theme

    static let numberWidth: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(10)) {
                Text(title)
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                header("Input")
                header("Output")
                header("Cost")
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(36))
            HLine(color: theme.border)
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { HLine(color: theme.border.opacity(0.6)).padding(.leading, theme.z(14)) }
                row(line)
            }
            if let more {
                HLine(color: theme.border)
                Button(more.label, action: more.action)
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, theme.z(14))
                    .frame(height: theme.z(34))
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .frame(width: theme.z(Self.numberWidth), alignment: .trailing)
    }

    private func row(_ line: UsageLine) -> some View {
        HStack(spacing: theme.z(10)) {
            VStack(alignment: .leading, spacing: theme.z(2)) {
                Text(line.name)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let detail = line.detail, !detail.isEmpty {
                    Text(detail)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: theme.z(8))
            number(Format.tokens(line.usage.inputTokens))
            number(Format.tokens(line.usage.outputTokens + line.usage.reasoningTokens))
            Group {
                if line.hasAPICost {
                    Text(Format.usd(line.apiCostUSD)).foregroundStyle(theme.textPrimary)
                } else {
                    Text(line.billingLabel).foregroundStyle(theme.textTertiary)
                }
            }
            .font(theme.font(size: 12.5).monospacedDigit())
            .frame(width: theme.z(Self.numberWidth), alignment: .trailing)
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(8))
    }

    private func number(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12.5).monospacedDigit())
            .foregroundStyle(theme.textSecondary)
            .frame(width: theme.z(Self.numberWidth), alignment: .trailing)
    }
}

/// Daily spending caps, one row per provider billed to an API key: spent today, the cap, and a bar.
struct UsageCapsSection: View {
    let tracker: UsageTracker
    @Environment(\.theme) private var theme

    var body: some View {
        let providers = tracker.cappableProviders
        VStack(alignment: .leading, spacing: theme.z(8)) {
            VStack(alignment: .leading, spacing: theme.z(3)) {
                Text("Daily spending caps")
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("When a provider's spend today reaches its cap, new turns on it wait until midnight. A turn already running "
                     + "finishes. Caps apply to API keys only, never to subscriptions.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                if providers.isEmpty {
                    Text("No API-key providers in use.")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.z(14))
                }
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, status in
                    if index > 0 { HLine(color: theme.border.opacity(0.6)).padding(.leading, theme.z(14)) }
                    UsageCapRow(status: status) { tracker.setCap($0, for: status.providerID) }
                }
            }
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
        }
    }
}

/// One provider's cap: name, spent today against the cap, and a field to set or remove it.
struct UsageCapRow: View {
    let status: UsageCapStatus
    let onSet: (Double?) -> Void
    @Environment(\.theme) private var theme
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(10)) {
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    Text(status.providerName)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(spentText)
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(status.isReached ? theme.danger : theme.textTertiary)
                }
                Spacer(minLength: theme.z(8))
                HStack(spacing: theme.z(4)) {
                    Text("$")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                    InputField("No cap", text: textBinding, height: 28)
                        .frame(width: theme.z(84))
                        .onSubmit(apply)
                }
                Button("Set", action: apply)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(parsed == status.capUSD || (parsed == nil && !currentText.isEmpty))
                // The slot stays on rows without a cap, so the "$", field and Set line up from row to row.
                IconButton("xmark", help: "Remove the cap", size: 26) {
                    text = ""
                    onSet(nil)
                }
                .opacity(status.capUSD == nil ? 0 : 1)
                .allowsHitTesting(status.capUSD != nil)
                .accessibilityHidden(status.capUSD == nil)
            }
            if let cap = status.capUSD {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.track)
                        Capsule().fill(barColor).frame(width: proxy.size.width * status.fraction)
                    }
                }
                .frame(height: theme.z(5))
                .accessibilityLabel("\(Format.usd(status.spentUSD)) of \(Format.usd(cap)) spent today")
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(10))
    }

    private var spentText: String {
        guard let cap = status.capUSD else { return "\(Format.usd(status.spentUSD)) today" }
        if status.isReached { return "\(Format.usd(status.spentUSD)) of \(Format.usd(cap)) today. Cap reached: new turns wait until midnight." }
        return "\(Format.usd(status.spentUSD)) of \(Format.usd(cap)) today"
    }

    private var barColor: Color {
        if status.isReached { return theme.danger }
        if status.fraction >= 0.8 { return theme.warning }
        return theme.accent
    }

    private var currentText: String { text ?? status.capUSD.map(Self.amount) ?? "" }

    private var textBinding: Binding<String> {
        Binding(get: { currentText }, set: { text = $0 })
    }

    /// The typed amount, or nil when the field is empty or not a positive number.
    private var parsed: Double? {
        let cleaned = currentText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private func apply() {
        if currentText.trimmingCharacters(in: .whitespaces).isEmpty {
            onSet(nil)
        } else if let parsed {
            onSet(parsed)
            text = Self.amount(parsed)
        }
    }

    static func amount(_ value: Double) -> String { String(format: "%.2f", value) }
}
