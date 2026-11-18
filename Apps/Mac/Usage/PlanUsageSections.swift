import SwiftUI
import EnsembleKit

/// The engines that report subscription plan use, found behind the store.
@MainActor
enum PlanEngines {
    static func claude(_ store: SessionStore) -> ClaudeCodeEngine? {
        (store.engine as? EngineRouter)?.engine(ClaudeCodeEngine.self) ?? (store.engine as? ClaudeCodeEngine)
    }

    /// The agy engine, when it can report the Google AI plan.
    static func google(_ store: SessionStore) -> ACPEngine? {
        let engine = ((store.engine as? EngineRouter)?.registration(id: SubscriptionPlan.googleAI.engineID)?.engine as? ACPEngine)
            ?? (store.engine as? ACPEngine)
        return engine?.reportsPlanUsage == true ? engine : nil
    }

    /// Every plan the app has an engine for.
    static func available(_ store: SessionStore) -> [SubscriptionPlan] {
        var plans: [SubscriptionPlan] = []
        if claude(store) != nil { plans.append(.claude) }
        if google(store) != nil { plans.append(.googleAI) }
        return plans
    }

    /// The plan a session's turns count against (nil for API keys and local models).
    static func plan(of session: SessionModel?, store: SessionStore) -> SubscriptionPlan? {
        guard let session else { return nil }
        let owner = (store.engine as? EngineRouter)?.ownerID(ofSession: session.id)
        return SubscriptionPlan.forSession(engineID: owner, providerID: session.info.model?.providerID)
    }

    /// Today's Gemini tokens across sessions, from agy's per-turn usage in the usage ledger.
    static func googleTokensToday(_ store: SessionStore) -> Int? {
        guard let tracker = store.usageTracker ?? UsageCenter.shared.tracker else { return nil }
        return tracker.report(.today).providers.first { $0.id == SubscriptionPlan.googleAI.engineID }?.tokens ?? 0
    }
}

/// Fixed plan data for snapshots: which plans to list and what each reports.
struct PlanUsageSnapshot {
    var plans: [SubscriptionPlan]
    var claude: ClaudePlanLimits?
    var google: AntigravityPlanStatus?
    var googleTokensToday: Int?
    var now = Date()
}

/// The usage popover's plan sections: every plan the app has ("Claude plan", "Google AI plan"), the current session's
/// first.
struct PlanUsageSections: View {
    let store: SessionStore
    var session: SessionModel?
    var snapshot: PlanUsageSnapshot?
    @Environment(\.theme) private var theme

    var body: some View {
        let current = PlanEngines.plan(of: session, store: store)
        let plans = SubscriptionPlan.ordered(snapshot?.plans ?? PlanEngines.available(store), current: current)
        ForEach(Array(plans.enumerated()), id: \.element) { index, plan in
            VStack(alignment: .leading, spacing: theme.z(10)) {
                // A rule between plans, so each one's "Updated" line stays with its own bars.
                if index > 0 { HLine(color: theme.border) }
                switch plan {
                case .claude:
                    if let snapshot {
                        PlanSectionHeader(plan: .claude) { PlanLimitsView(limits: snapshot.claude, now: snapshot.now) }
                    } else {
                        ClaudePlanLimitsSection(store: store)
                    }
                case .googleAI:
                    GooglePlanLimitsSection(store: store, modelID: current == .googleAI ? session?.info.model?.id : nil, snapshot: snapshot)
                }
            }
            .padding(.top, theme.z(index == 0 ? 2 : 0))
        }
    }
}

/// A plan's heading above its limits.
struct PlanSectionHeader<Content: View>: View {
    let plan: SubscriptionPlan
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            Text(plan.title)
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            content
        }
    }
}

/// The Google AI plan: agy's `/usage` read every minute while shown.
struct GooglePlanLimitsSection: View {
    let store: SessionStore
    /// The current Gemini session's model: its group comes first.
    var modelID: String?
    var snapshot: PlanUsageSnapshot?
    @State private var status: AntigravityPlanStatus?
    @State private var loaded = false

    var body: some View {
        if let snapshot {
            PlanSectionHeader(plan: .googleAI) {
                GooglePlanLimitsView(status: snapshot.google, loaded: true, modelID: modelID, tokensToday: snapshot.googleTokensToday,
                                     now: snapshot.now)
            }
        } else if let google = PlanEngines.google(store) {
            PlanSectionHeader(plan: .googleAI) {
                GooglePlanLimitsView(status: status, loaded: loaded, modelID: modelID, tokensToday: PlanEngines.googleTokensToday(store))
            }
            .task {
                while !Task.isCancelled {
                    status = await google.planStatus()
                    loaded = true
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }
}

/// agy's report of the Google AI plan: per model group, a bar for the five-hour and the weekly limit with "% used" and
/// when it resets (like Claude's). When agy reports no limits: today's Gemini tokens in Ensemble, and either "Limit
/// reached" (a turn stopped on one) or the line saying agy does not report what is left. No estimated percentages.
struct GooglePlanLimitsView: View {
    let status: AntigravityPlanStatus?
    /// False until the first reading came back.
    var loaded = true
    var modelID: String?
    var tokensToday: Int?
    var now = Date()
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            if let text = limitText {
                Text(text)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage = status?.usage {
                ForEach(Self.groups(usage, modelID: modelID)) { group in
                    VStack(alignment: .leading, spacing: theme.z(7)) {
                        if usage.groups.count > 1 {
                            Text(group.label)
                                .font(theme.font(size: 11.5, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                        }
                        ForEach(group.buckets) { bucket in
                            if bucket.disabled || bucket.remainingFraction == nil {
                                disabledRow(bucket)
                            } else {
                                PlanLimitRow(row: Self.row(bucket), now: now)
                            }
                        }
                    }
                }
                Text("Updated \(usage.updated.formatted(date: .omitted, time: .shortened))")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            } else if !loaded {
                note("Plan limits appear when agy answers.")
            } else {
                if let tokensToday {
                    Text("Today: \(Text(Format.tokens(tokensToday)).monospacedDigit()) tokens in Gemini sessions")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                if status?.limitHit == nil {
                    note(status?.problem == .noAnswer ? "agy did not answer. Plan limits show once it does."
                                                      : "agy does not report how much of the plan is left.")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12))
            .foregroundStyle(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func disabledRow(_ bucket: AntigravityPlanUsage.Bucket) -> some View {
        HStack {
            Text(PlanLimitsView.label(for: bucket.windowName))
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Text("Disabled")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
    }

    /// "Limit reached. Resets Thu 9:00 AM" when a limit is used up or a turn stopped on one; nil otherwise.
    private var limitText: String? {
        guard let status, status.isLimited else { return nil }
        let reset = status.usage?.groups.compactMap(\.limitedUntil).max() ?? status.limitHit?.resetsAt
        guard let reset else { return "Limit reached." }
        return PlanLimitRow.resetText(reset, now: now, prefix: "Limit reached. Resets ")
    }

    /// The groups, the one for the current session's model first.
    static func groups(_ usage: AntigravityPlanUsage, modelID: String?) -> [AntigravityPlanUsage.Group] {
        guard let modelID, let first = usage.group(forModel: modelID) else { return usage.groups }
        return [first] + usage.groups.filter { $0.id != first.id }
    }

    /// A bucket as one of Claude's bar rows. The reset time shows once some of the limit is used (agy sends now plus
    /// the window for an untouched one).
    static func row(_ bucket: AntigravityPlanUsage.Bucket) -> PlanLimitsView.Row {
        PlanLimitsView.Row(name: bucket.windowName, utilization: bucket.usedFraction ?? 0,
                           resetsAt: bucket.showsReset ? bucket.resetsAt : nil, status: bucket.isUsedUp ? "rejected" : nil)
    }
}

/// Sample Google AI plan readings for snapshots, in agy's own shape.
enum GooglePlanSamples {
    static func usage(now: Date, geminiFiveHour: Double = 0.38, geminiWeekly: Double = 0.81) -> AntigravityPlanUsage {
        AntigravityPlanUsage(groups: [
            .init(name: "Gemini Models", models: ["Gemini 4 Carbon", "Gemini 4 Argon", "Gemini 4 Hydrogen", "Gemini 3.8 Flash"], buckets: [
                .init(id: "gemini-weekly", name: "Weekly Limit Remaining", window: "weekly", remainingFraction: geminiWeekly,
                      resetsAt: now.addingTimeInterval(4 * 86_400 + 3 * 3600)),
                .init(id: "gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remainingFraction: geminiFiveHour,
                      resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
            ]),
            .init(name: "Claude and GPT models", models: ["Claude Sonnet 4.6", "Claude Opus 4.6", "GPT-OSS 120B"], buckets: [
                .init(id: "3p-weekly", name: "Weekly Limit Remaining", window: "weekly", remainingFraction: 1,
                      resetsAt: now.addingTimeInterval(7 * 86_400)),
                .init(id: "3p-5h", name: "Five Hour Limit Remaining", window: "5h", remainingFraction: 1,
                      resetsAt: now.addingTimeInterval(5 * 3600)),
            ]),
        ], updated: now.addingTimeInterval(-40))
    }

    static func status(now: Date) -> AntigravityPlanStatus {
        AntigravityPlanStatus(usage: usage(now: now))
    }

    /// The Gemini five-hour limit used up.
    static func limited(now: Date) -> AntigravityPlanStatus {
        AntigravityPlanStatus(usage: usage(now: now, geminiFiveHour: 0, geminiWeekly: 0.52))
    }

    /// An agy without `/usage`: no bars, today's tokens and the honest line.
    static func notReported() -> AntigravityPlanStatus {
        AntigravityPlanStatus(problem: .notReported)
    }
}

/// Both plans for the iPhone's Usage screen (`RemoteUsageSummary.plans`), the selected session's first.
@MainActor
enum RemotePlanSummaries {
    static func plans(store: SessionStore) async -> [RemotePlanUsage] {
        var result: [RemotePlanUsage] = []
        for plan in SubscriptionPlan.ordered(PlanEngines.available(store), current: PlanEngines.plan(of: store.selected, store: store)) {
            switch plan {
            case .claude:
                guard let claude = PlanEngines.claude(store) else { continue }
                result.append(claudePlan(await claude.planLimits()))
            case .googleAI:
                guard let google = PlanEngines.google(store) else { continue }
                result.append(googlePlan(await google.planStatus(), tokensToday: PlanEngines.googleTokensToday(store)))
            }
        }
        return result
    }

    static func claudePlan(_ limits: ClaudePlanLimits?) -> RemotePlanUsage {
        let plan = SubscriptionPlan.claude
        guard let limits else { return RemotePlanUsage(id: plan.id, title: plan.title, note: "Plan limits appear after the first Claude reply.") }
        let windows = PlanLimitsView.rows(for: limits).map { row in
            RemotePlanUsage.Window(id: row.name, label: PlanLimitsView.label(for: row.name), usedFraction: min(max(row.utilization, 0), 1),
                                   resetsAt: row.resetsAt)
        }
        return RemotePlanUsage(id: plan.id, title: plan.title, windows: windows, limitReached: limits.isLimited,
                               resetsAt: limits.isLimited ? limits.resetsAt : nil)
    }

    static func googlePlan(_ status: AntigravityPlanStatus?, tokensToday: Int?) -> RemotePlanUsage {
        let plan = SubscriptionPlan.googleAI
        guard let status else { return RemotePlanUsage(id: plan.id, title: plan.title, note: "Plan limits appear when agy answers.") }
        let reset = status.usage?.groups.compactMap(\.limitedUntil).max() ?? status.limitHit?.resetsAt
        guard let usage = status.usage else {
            var lines: [String] = []
            if let tokensToday { lines.append("Today: \(Format.tokens(tokensToday)) tokens in Gemini sessions.") }
            if status.limitHit == nil {
                lines.append(status.problem == .noAnswer ? "agy did not answer." : "agy does not report how much of the plan is left.")
            }
            return RemotePlanUsage(id: plan.id, title: plan.title, limitReached: status.isLimited, resetsAt: reset,
                                   note: lines.isEmpty ? nil : lines.joined(separator: " "))
        }
        let windows = usage.groups.flatMap { group in
            group.buckets.filter { !$0.disabled && $0.remainingFraction != nil }.map { bucket in
                RemotePlanUsage.Window(id: group.id + "/" + bucket.id, group: usage.groups.count > 1 ? group.label : nil,
                                       label: PlanLimitsView.label(for: bucket.windowName), usedFraction: bucket.usedFraction ?? 0,
                                       resetsAt: bucket.showsReset ? bucket.resetsAt : nil)
            }
        }
        return RemotePlanUsage(id: plan.id, title: plan.title, windows: windows, limitReached: status.isLimited, resetsAt: reset)
    }
}
