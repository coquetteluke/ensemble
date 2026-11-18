import SwiftUI
import EnsembleKit

// Goal mode views (`GoalModels.swift`): the Active goal bar in a room's header, the editor behind the Goal button, and
// the compact pill a session's header can show (`SessionGoalPill`).

// MARK: - Room

/// Under the room's title row while the room has a goal: the goal, its progress and spend, and Stop (or Clear once it
/// ended).
struct RoomGoalBar: View {
    let engine: RoomEngine
    let goal: GoalRun
    /// A permission prompt or decision of the room waits on the user.
    var waitingOnYou = false
    @Environment(\.theme) private var theme

    var body: some View {
        GoalBarContent(goal: goal, waitingOnYou: waitingOnYou, statusText: statusText,
                       stop: { engine.stopGoal() }, clear: { engine.clearGoal() })
    }

    private var statusText: String {
        if goal.isActive, waitingOnYou { return "Waiting on you" }
        if goal.status == .working, engine.state.isPaused { return "Paused" }
        return goal.statusLine
    }
}

/// The room header's Goal button: opens the editor; the goal starts a run when none is going.
struct GoalButton: View {
    let engine: RoomEngine
    var compact = false
    @State private var editing = false

    var body: some View {
        let reason = engine.goalUnavailableReason
        RoomHeaderButton(title: "Goal", symbol: "target", compact: compact,
                         tooltip: reason ?? "Keep the room working until a condition is met") { editing = true }
            .disabled(reason != nil)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                GoalEditor(start: { condition, budget in
                    editing = false
                    Task { await engine.setGoal(condition, budget: budget) }
                }, cancel: { editing = false })
                .ensembleTheme()
            }
    }
}

/// The bar's content, shared by rooms and snapshots.
struct GoalBarContent: View {
    let goal: GoalRun
    var waitingOnYou = false
    var statusText: String
    let stop: () -> Void
    let clear: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        // Narrow windows (or a large zoom) drop the progress bar, then the spend, before the goal itself gets short.
        ViewThatFits(in: .horizontal) {
            row(progress: true, cost: true, conditionWidth: theme.z(300))
            row(progress: false, cost: true, conditionWidth: theme.z(200))
            row(progress: false, cost: false, conditionWidth: nil)
        }
        .padding(.horizontal, theme.z(12))
        .frame(height: theme.z(34))
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(background))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(goal.condition). \(statusText)")
    }

    private func row(progress: Bool, cost showsCost: Bool, conditionWidth: CGFloat?) -> some View {
        HStack(spacing: theme.z(10)) {
            GoalMark(goal: goal)
            Text(title)
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(titleColor)
                .fixedSize()
            Text(goal.condition)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: conditionWidth, alignment: .leading)
                .help(goal.condition)
                .layoutPriority(-1)
            Spacer(minLength: theme.z(8))
            HStack(spacing: theme.z(8)) {
                Text(statusText)
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(waitingOnYou && goal.isActive ? theme.warning : theme.textSecondary)
                    .lineLimit(1)
                if goal.isActive, progress {
                    GoalProgress(fraction: goal.turnFraction)
                        .frame(width: theme.z(54))
                        .help(goal.progressLabel)
                }
                if showsCost {
                    Text(cost)
                        .font(theme.font(size: 12).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .help("Spent since the goal was set")
                }
            }
            .fixedSize()
            if goal.isActive {
                Button(action: stop) {
                    HStack(spacing: theme.z(4)) {
                        Image(systemName: "stop.fill").font(theme.font(size: 9.5))
                        Text("Stop").font(theme.font(size: 12, weight: .medium))
                    }
                    .foregroundStyle(theme.danger)
                    .padding(.horizontal, theme.z(8))
                    .frame(height: theme.z(22))
                    .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(theme.danger.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop the goal. The current turn finishes; nothing more starts.")
                .fixedSize()
            } else {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(theme.font(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(22), height: theme.z(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide the goal")
                .accessibilityLabel("Hide the goal")
            }
        }
    }

    private var title: String {
        switch goal.status {
        case .working, .checking, .waiting: "Active goal"
        case .met: "Goal met"
        case .budgetReached, .stopped, .blocked: "Goal stopped"
        }
    }

    private var titleColor: Color {
        switch goal.status {
        case .met: theme.success
        case .budgetReached, .stopped, .blocked: theme.textSecondary
        default: theme.accent
        }
    }

    private var background: Color {
        goal.isActive ? theme.accent.opacity(theme.isDark ? 0.09 : 0.06) : theme.elevated.opacity(0.7)
    }

    private var border: Color {
        goal.isActive ? theme.accent.opacity(0.28) : theme.border
    }

    private var cost: String {
        if let cap = goal.budget.maxCostUSD { return "\(Format.usd(goal.costSpent)) of \(Format.usd(cap))" }
        return Format.usd(goal.costSpent)
    }
}

/// The goal's icon: a target while active, a check when met, a stop mark when it stopped.
struct GoalMark: View {
    let goal: GoalRun
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch goal.status {
            case .checking: Spinner(size: 11, color: theme.accent)
            case .working, .waiting: Image(systemName: "target").foregroundStyle(theme.accent)
            case .met: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
            case .budgetReached, .stopped, .blocked: Image(systemName: "stop.circle").foregroundStyle(theme.textTertiary)
            }
        }
        .font(theme.font(size: 12.5, weight: .medium))
        .frame(width: theme.z(14))
    }
}

/// Turns used.
struct GoalProgress: View {
    let fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule().fill(fraction >= 0.8 ? theme.warning : theme.accent)
                    .frame(width: max(theme.z(3), min(1, fraction) * proxy.size.width))
            }
        }
        .frame(height: theme.z(4))
    }
}

/// Behind the room header's Goal button: the condition, the run budget and an optional cost budget.
struct GoalEditor: View {
    var title = "Keep the room working until"
    var unit = "runs"
    var initialCondition = ""
    let start: (String, GoalBudget) -> Void
    let cancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var condition = ""
    @State private var turns = GoalBudget.defaultTurns
    @State private var costText = ""
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(12)) {
            Text(title)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            InputField("all tests pass", text: $condition, icon: "target", height: 30)
                .frame(width: theme.z(320))
                .onSubmit(submit)
            HStack(spacing: theme.z(10)) {
                Text("Up to")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                CountStepper(value: $turns, range: 1...50)
                Text(unit)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: theme.z(8))
                InputField("No cost limit", text: $costText, icon: "dollarsign", height: 28)
                    .frame(width: theme.z(130))
                    .help("Stop once the goal has cost this much")
            }
            Text("After each \(unit.dropLast()), an agent checks the goal with evidence and answers GOAL MET or GOAL NOT MET.")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: theme.z(320), alignment: .leading)
            HStack(spacing: theme.z(8)) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Start goal", action: submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canStart)
            }
        }
        .padding(theme.z(16))
        .onAppear {
            guard !seeded else { return }
            seeded = true
            condition = initialCondition
        }
    }

    private var cost: Double? {
        let cleaned = costText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    private var canStart: Bool {
        let costOK = costText.trimmingCharacters(in: .whitespaces).isEmpty || (cost ?? 0) > 0
        return !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && costOK
    }

    private func submit() {
        guard canStart else { return }
        start(condition.trimmingCharacters(in: .whitespacesAndNewlines), GoalBudget(maxTurns: turns, maxCostUSD: cost))
    }
}

/// Minus, the number, plus. Drawn with plain views so it renders in snapshots.
struct CountStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(0)) {
            button("minus", enabled: value > range.lowerBound) { value -= 1 }
            Text("\(value)")
                .font(theme.font(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: theme.z(26))
            button("plus", enabled: value < range.upperBound) { value += 1 }
        }
        .frame(height: theme.z(26))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
        .accessibilityElement()
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { value += 1 }
            case .decrement: if value > range.lowerBound { value -= 1 }
            @unknown default: break
            }
        }
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 9.5, weight: .bold))
                .foregroundStyle(enabled ? theme.textSecondary : theme.textTertiary.opacity(0.5))
                .frame(width: theme.z(24), height: theme.z(26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Sessions

/// For a session's header: the goal in a pill with its progress and Stop. Shows nothing without a goal.
/// Insertion point: `CenterHeader` in `MainView.swift`, after the folder path of the selected session.
struct SessionGoalPill: View {
    let store: SessionStore
    let sessionID: String

    var body: some View {
        if let goal = store.goal(for: sessionID) {
            GoalPill(goal: goal, waitingOnYou: !(store.session(sessionID)?.pendingPermissions.isEmpty ?? true),
                     stop: { store.stopGoal(for: sessionID) }, clear: { store.clearGoal(for: sessionID) })
        }
    }
}

/// A compact goal indicator: mark, condition, progress, Stop (or hide once ended).
struct GoalPill: View {
    let goal: GoalRun
    var waitingOnYou = false
    let stop: () -> Void
    let clear: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(7)) {
            GoalMark(goal: goal)
            Text(goal.condition)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: theme.z(220), alignment: .leading)
            Text(goal.isActive && waitingOnYou ? "Waiting on you" : goal.statusLine)
                .font(theme.font(size: 11.5).monospacedDigit())
                .foregroundStyle(goal.isActive && waitingOnYou ? theme.warning : theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Button(action: goal.isActive ? stop : clear) {
                Image(systemName: goal.isActive ? "stop.fill" : "xmark")
                    .font(theme.font(size: goal.isActive ? 8.5 : 9, weight: .semibold))
                    .foregroundStyle(goal.isActive ? theme.danger : theme.textTertiary)
                    .frame(width: theme.z(18), height: theme.z(18))
                    .background(Circle().fill(goal.isActive ? theme.danger.opacity(0.12) : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(goal.isActive ? "Stop the goal" : "Hide the goal")
            .accessibilityLabel(goal.isActive ? "Stop the goal" : "Hide the goal")
        }
        .padding(.leading, theme.z(9))
        .padding(.trailing, theme.z(4))
        .frame(height: theme.z(26))
        .background(Capsule().fill(goal.isActive ? theme.accent.opacity(theme.isDark ? 0.1 : 0.07) : theme.elevated))
        .overlay(Capsule().strokeBorder(goal.isActive ? theme.accent.opacity(0.3) : theme.border))
        .help("Goal: \(goal.condition)")
    }
}
