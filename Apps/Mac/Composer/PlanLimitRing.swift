import SwiftUI
import EnsembleKit

/// The session's plan use in the status line (the Google AI plan in Gemini sessions, the Claude plan otherwise): a small
/// ring (five-hour window outside, weekly inside) and the use of the window closest to its limit (the ring alone when
/// `compact`). Amber from 80%, red when a window is used up. The tooltip gives each window's use and reset time; a click
/// opens the usage popover. Hidden without a meter (no engine for the plan, or nothing it can report);
/// `PlanLimitRefresh` keeps the meter current.
struct PlanLimitStatusItem: View {
    let meter: PlanLimitMeter?
    var plan: SubscriptionPlan = .claude
    /// The Google AI plan's model group the meter shows ("Gemini models").
    var group: String?
    var compact = false
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    static let refreshInterval: Duration = .seconds(180)

    var body: some View {
        if let meter {
            Button(action: onOpen) {
                HStack(spacing: theme.z(6)) {
                    PlanLimitRing(meter: meter)
                    if !compact, let leading = meter.leading {
                        Text("\(leading.shortLabel) \(Text(Format.wholePercent(leading.fraction)).monospacedDigit())")
                            .foregroundStyle(Self.textColor(meter.level, theme: theme))
                            .lineLimit(1)
                    } else if !compact, meter.isLimited {
                        Text("Limit reached")
                            .foregroundStyle(theme.danger)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.tooltip(meter, plan: plan, group: group))
            .accessibilityLabel("\(plan.title) use")
            .accessibilityValue(Self.tooltip(meter, plan: plan, group: group))
        }
    }

    static func textColor(_ level: PlanLimitMeter.Level, theme: Theme) -> Color {
        switch level {
        case .normal: theme.textTertiary
        case .nearLimit: theme.warning
        case .limited: theme.danger
        }
    }

    /// One line per window: "5-hour limit: 60% used, resets 3:40 PM", under the plan (and model group) it belongs to
    /// when that is not the Claude plan.
    static func tooltip(_ meter: PlanLimitMeter, plan: SubscriptionPlan = .claude, group: String? = nil, now: Date = Date()) -> String {
        guard !meter.windows.isEmpty else {
            if meter.isLimited { return "\(plan.title): limit reached" }
            switch plan {
            case .claude: return "Claude plan use appears after the first Claude reply"
            case .googleAI: return "Google AI plan use appears when agy reports it"
            }
        }
        let lines = meter.windows.map { window in
            var line = "\(PlanLimitsView.label(for: window.name)): \(Format.wholePercent(window.fraction)) used"
            if let reset = window.resetsAt { line += ", " + PlanLimitRow.resetText(reset, now: now, prefix: "resets ") }
            return line
        }
        let heading = plan == .claude ? [] : [[plan.title, group].compactMap { $0 }.joined(separator: ", ")]
        return (heading + lines).joined(separator: "\n")
    }
}

/// Reads the engine of the session's plan into `loader` after every turn, when the session or its model changes, and
/// every three minutes. Applied once to the status line, so its width levels share one meter.
struct PlanLimitRefresh: ViewModifier {
    let store: SessionStore
    var session: SessionModel?
    let loader: PlanLimitLoader
    /// False in snapshots and when a fixed meter is shown.
    let enabled: Bool

    private struct Trigger: Hashable {
        var revision: Int
        var sessionID: String?
        var model: ModelRef?
    }

    func body(content: Content) -> some View {
        content
            .task(id: Trigger(revision: store.background.planLimitsRevision, sessionID: session?.id, model: session?.info.model)) {
                guard enabled else { return }
                await loader.refresh(store: store, session: session)
            }
            .task(id: session?.id) {
                guard enabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: PlanLimitStatusItem.refreshInterval)
                    guard !Task.isCancelled else { return }
                    await loader.refresh(store: store, session: session)
                }
            }
    }
}

/// Two arcs on faint tracks: the five-hour window outside, the weekly window inside, each coloured by how close it is to
/// its limit.
struct PlanLimitRing: View {
    let meter: PlanLimitMeter
    @Environment(\.theme) private var theme

    var body: some View {
        let size = theme.z(13)
        ZStack {
            arc(meter.fiveHour, lineWidth: theme.z(1.8))
            arc(meter.weekly, lineWidth: theme.z(1.5))
                .padding(theme.z(3.4))
        }
        .frame(width: size, height: size)
    }

    private func arc(_ window: PlanLimitMeter.Window?, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: lineWidth)
            if let window, window.fraction > 0 {
                Circle()
                    .trim(from: 0, to: max(0.04, window.fraction))
                    .stroke(color(window.level), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    private func color(_ level: PlanLimitMeter.Level) -> Color {
        switch level {
        case .normal: theme.textSecondary
        case .nearLimit: theme.warning
        case .limited: theme.danger
        }
    }
}

/// Reads the engine of the session's plan (`SubscriptionPlan.statusLine`): in a Gemini session agy's `/usage` for the
/// session's model group, never Claude's; in every other session the Claude engine, whether it is signed in with a
/// subscription, and its newest plan use.
@Observable @MainActor
final class PlanLimitLoader {
    private(set) var meter: PlanLimitMeter?
    private(set) var plan: SubscriptionPlan = .claude
    /// The Google AI plan's model group the meter shows.
    private(set) var group: String?

    func refresh(store: SessionStore, session: SessionModel?) async {
        let shown = SubscriptionPlan.statusLine(for: PlanEngines.plan(of: session, store: store))
        // Another plan's meter never stays up while this one loads (agy takes seconds to answer).
        if shown != plan {
            plan = shown
            meter = nil
            group = nil
        }
        if shown == .googleAI {
            let status = await PlanEngines.google(store)?.planStatus()
            guard !Task.isCancelled else { return }
            let modelID = session?.info.model?.id
            group = status?.usage?.group(forModel: modelID)?.label
            // Nothing to draw when agy reports no limits and no turn stopped on one.
            meter = status.flatMap { $0.usage != nil || $0.limitHit != nil ? $0.meter(forModel: modelID) : nil }
            return
        }
        guard let claude = PlanEngines.claude(store) else {
            meter = nil
            return
        }
        let limits = await claude.planLimits()
        let auth = await claude.authState()
        guard !Task.isCancelled else { return }
        let subscription = auth.authMethod == "claude.ai" || auth.subscriptionType != nil
        guard auth.loggedIn, subscription || limits != nil else {
            meter = nil
            return
        }
        meter = limits.map(PlanLimitMeter.init(limits:)) ?? PlanLimitMeter(windows: [])
    }
}
