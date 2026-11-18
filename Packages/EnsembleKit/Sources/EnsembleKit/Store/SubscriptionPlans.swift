import Foundation

/// The subscriptions whose plan limits Ensemble shows: the Claude plan (the `claude` CLI's rate-limit events) and the
/// Google AI plan (agy's `/usage` command, `AntigravityPlanUsage`). The usage popover lists every plan the app has, the
/// current session's first; the status line's ring shows the current session's plan.
public enum SubscriptionPlan: String, CaseIterable, Hashable, Sendable, Identifiable {
    case claude
    case googleAI

    public var id: String { rawValue }

    /// The heading: "Claude plan", "Google AI plan".
    public var title: String {
        switch self {
        case .claude: "Claude plan"
        case .googleAI: "Google AI plan"
        }
    }

    /// The router id of the engine that reports the plan.
    public var engineID: String {
        switch self {
        case .claude: "claude"
        case .googleAI: "antigravity"
        }
    }

    /// The plan a session's turns count against: by the engine that owns it, else by its model's provider. nil for
    /// sessions on API keys or local models.
    public static func forSession(engineID: String?, providerID: String?) -> SubscriptionPlan? {
        switch engineID {
        case "antigravity": return .googleAI
        case "claude": return providerID == "claude-code-api" ? nil : .claude
        default: break
        }
        switch providerID {
        case "antigravity": return .googleAI
        case "claude-code": return .claude
        default: return nil
        }
    }

    /// The plans to list, the current session's first, then the others in their usual order.
    public static func ordered(_ available: some Sequence<SubscriptionPlan>, current: SubscriptionPlan?) -> [SubscriptionPlan] {
        let present = Set(available)
        var list = allCases.filter { present.contains($0) }
        if let current, let index = list.firstIndex(of: current) {
            list.remove(at: index)
            list.insert(current, at: 0)
        }
        return list
    }

    /// The plan whose ring the status line shows: Gemini sessions show the Google AI plan (never Claude's), every other
    /// session the Claude plan, as before.
    public static func statusLine(for current: SubscriptionPlan?) -> SubscriptionPlan {
        current == .googleAI ? .googleAI : .claude
    }
}
