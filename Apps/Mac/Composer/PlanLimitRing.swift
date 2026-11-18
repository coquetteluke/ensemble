import SwiftUI
import EnsembleKit

/// Claude plan use in the status line: a small ring (five-hour window outside, weekly inside) and the use of the window
/// closest to its limit. Amber from 80%, red when a window is used up. The tooltip gives each window's use and reset
/// time; a click opens the usage popover. Hidden when no Claude engine is signed in with a subscription. Reads the
/// engine after every turn and every three minutes while shown.
struct PlanLimitStatusItem: View {
    let store: SessionStore
    /// Snapshots pass a fixed meter instead of reading the engine.
    var fixedMeter: PlanLimitMeter?
    let onOpen: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var loader = PlanLimitLoader()

    static let refreshInterval: Duration = .seconds(180)

    private var meter: PlanLimitMeter? { fixedMeter ?? loader.meter }

    var body: some View {
        HStack(spacing: 0) {
            if let meter {
                Button(action: onOpen) {
                    HStack(spacing: theme.z(6)) {
                        PlanLimitRing(meter: meter)
                        if let leading = meter.leading {
                            Text("\(leading.shortLabel) \(Text(Format.wholePercent(leading.fraction)).monospacedDigit())")
                                .foregroundStyle(Self.textColor(meter.level, theme: theme))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.tooltip(meter))
                .accessibilityLabel("Claude plan use")
                .accessibilityValue(Self.tooltip(meter))
            }
            Color.clear.frame(width: 0, height: 0)
                .task(id: store.background.planLimitsRevision) {
                    guard fixedMeter == nil, !isSnapshot else { return }
                    await loader.refresh(store: store)
                }
                .task {
                    guard fixedMeter == nil, !isSnapshot else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.refreshInterval)
                        guard !Task.isCancelled else { return }
                        await loader.refresh(store: store)
                    }
                }
        }
    }

    static func textColor(_ level: PlanLimitMeter.Level, theme: Theme) -> Color {
        switch level {
        case .normal: theme.textTertiary
        case .nearLimit: theme.warning
        case .limited: theme.danger
        }
    }

    /// One line per window: "5-hour limit: 60% used, resets 3:40 PM".
    static func tooltip(_ meter: PlanLimitMeter, now: Date = Date()) -> String {
        guard !meter.windows.isEmpty else { return "Claude plan use appears after the first Claude reply" }
        return meter.windows.map { window in
            var line = "\(PlanLimitsView.label(for: window.name)): \(Format.wholePercent(window.fraction)) used"
            if let reset = window.resetsAt { line += ", " + PlanLimitRow.resetText(reset, now: now, prefix: "resets ") }
            return line
        }
        .joined(separator: "\n")
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

/// Reads the Claude engine behind the store: whether it is signed in with a subscription, and its newest plan use.
@Observable @MainActor
final class PlanLimitLoader {
    private(set) var meter: PlanLimitMeter?

    func refresh(store: SessionStore) async {
        guard let claude = (store.engine as? EngineRouter)?.engine(ClaudeCodeEngine.self) ?? (store.engine as? ClaudeCodeEngine) else {
            meter = nil
            return
        }
        let limits = await claude.planLimits()
        let auth = await claude.authState()
        let subscription = auth.authMethod == "claude.ai" || auth.subscriptionType != nil
        guard auth.loggedIn, subscription || limits != nil else {
            meter = nil
            return
        }
        meter = limits.map(PlanLimitMeter.init(limits:)) ?? PlanLimitMeter(windows: [])
    }
}
