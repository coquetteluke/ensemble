import SwiftUI
import EnsembleKit

/// Claude plan use: one bar per limit window (five-hour, weekly) with the time it resets.
struct PlanLimitsView: View {
    @Environment(\.theme) private var theme
    let limits: ClaudePlanLimits?
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            if let limits {
                if limits.isLimited {
                    Text(limitedText(limits))
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Self.rows(for: limits), id: \.name) { row in
                    PlanLimitRow(row: row, now: now)
                }
                Text("Updated \(limits.updated.formatted(date: .omitted, time: .shortened))")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text("Plan limits appear after the first Claude reply.")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func limitedText(_ limits: ClaudePlanLimits) -> String {
        guard let reset = limits.resetsAt, !Self.rows(for: limits).contains(where: { $0.resetsAt != nil }) else { return "Limit reached." }
        return PlanLimitRow.resetText(reset, now: now, prefix: "Limit reached. Resets ")
    }

    struct Row: Hashable {
        var name: String
        var utilization: Double
        var resetsAt: Date?
        var status: String?
    }

    /// The reported windows, five-hour first; the headline window alone when no windows were sent.
    static func rows(for limits: ClaudePlanLimits) -> [Row] {
        var rows = limits.windows.map { Row(name: $0.name, utilization: $0.utilization, resetsAt: $0.resetsAt, status: $0.status) }
        if let type = limits.limitType, !rows.contains(where: { $0.name == type }), let utilization = limits.utilization {
            rows.append(Row(name: type, utilization: utilization, resetsAt: limits.resetsAt, status: limits.status))
        }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return rows.sorted { (order.firstIndex(of: $0.name) ?? Int.max, $0.name) < (order.firstIndex(of: $1.name) ?? Int.max, $1.name) }
    }

    static func label(for window: String) -> String {
        switch window {
        case "five_hour": "Five-hour limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        case "seven_day_sonnet": "Weekly Sonnet limit"
        default:
            window.split(separator: "_").joined(separator: " ").capitalized(with: nil)
        }
    }
}

struct PlanLimitRow: View {
    @Environment(\.theme) private var theme
    let row: PlanLimitsView.Row
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            HStack {
                Text(PlanLimitsView.label(for: row.name))
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(Int((min(max(row.utilization, 0), 1) * 100).rounded()))% used")
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    Capsule().fill(color).frame(width: proxy.size.width * min(max(row.utilization, 0), 1))
                }
            }
            .frame(height: theme.z(5))
            if let reset = row.resetsAt {
                Text(Self.resetText(reset, now: now, prefix: "Resets "))
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var color: Color {
        if row.status == "rejected" || row.utilization >= 1 { return theme.danger }
        if row.status == "allowed_warning" || row.utilization >= 0.8 { return theme.warning }
        return theme.accent
    }

    /// "Resets 3:40 PM" today, "Resets Thu 9:00 AM" within a week, "Resets Nov 25" later.
    static func resetText(_ date: Date, now: Date, prefix: String) -> String {
        let calendar = Calendar.current
        let text: String
        if calendar.isDate(date, inSameDayAs: now) {
            text = date.formatted(date: .omitted, time: .shortened)
        } else if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            text = date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } else {
            text = date.formatted(.dateTime.month(.abbreviated).day())
        }
        return prefix + text
    }
}

/// Plan limits for the usage popover: reads the Claude engine behind the store every 30 seconds while shown.
/// Shows nothing when the app has no Claude engine.
struct ClaudePlanLimitsSection: View {
    @Environment(\.theme) private var theme
    let store: SessionStore
    @State private var limits: ClaudePlanLimits?

    private var claude: ClaudeCodeEngine? {
        (store.engine as? EngineRouter)?.engine(ClaudeCodeEngine.self) ?? (store.engine as? ClaudeCodeEngine)
    }

    var body: some View {
        if let claude {
            VStack(alignment: .leading, spacing: theme.z(8)) {
                Text("Claude plan")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                PlanLimitsView(limits: limits)
            }
            .task {
                while !Task.isCancelled {
                    limits = await claude.planLimits()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
}
