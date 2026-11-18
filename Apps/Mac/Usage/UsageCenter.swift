import SwiftUI
import AppKit
import EnsembleKit

/// The app's usage tracker: follows the store's sessions into the usage ledger, holds the daily spending caps, and saves
/// both on quit. Sample data never touches the saved file.
@MainActor @Observable
final class UsageCenter {
    static let shared = UsageCenter()

    private(set) var tracker: UsageTracker?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?

    /// Starts once the store has loaded its sessions, so the first look sees them all.
    func start(store: SessionStore, preview: Bool) {
        guard tracker == nil else { return }
        let tracker = UsageTracker(storage: preview ? InMemoryUsageStorage() : UsageFileStorage.standard)
        tracker.attach(to: store)
        self.tracker = tracker
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated { tracker.saveNow() }
        }
    }
}

/// Sample usage for snapshots: a month of API-key, subscription and local use across the preview sessions.
enum UsageSamples {
    static func ledger(now: Date, calendar: Calendar = .current) -> UsageLedger {
        var ledger = UsageLedger()
        func day(_ back: Int) -> String {
            UsageLedger.dayKey(calendar.date(byAdding: .day, value: -back, to: now) ?? now, calendar: calendar)
        }
        func add(_ back: Int, _ id: String, root: String? = nil, title: String, folder: String, provider: String, model: String,
                 agent: String, input: Int, output: Int, reasoning: Int = 0, cost: Double) {
            ledger.entries.append(UsageEntry(day: day(back), sessionID: id, rootSessionID: root ?? id, title: title,
                                             directory: NSHomeDirectory() + "/" + folder, providerID: provider, modelID: model,
                                             agentName: agent, usage: Usage(inputTokens: input, outputTokens: output,
                                                                            reasoningTokens: reasoning, costUSD: cost)))
        }
        // Today.
        add(0, "ses_context_panel", title: "Build the context panel", folder: "Ensemble", provider: "anthropic",
            model: "claude-opus-5-5", agent: "Claude Opus 5.5", input: 412_000, output: 18_400, reasoning: 6_100, cost: 2.84)
        add(0, "ses_colour_check", root: "ses_context_panel", title: "Build the context panel", folder: "Ensemble",
            provider: "anthropic", model: "claude-sonnet-5", agent: "Claude Sonnet 5", input: 38_000, output: 1_900, cost: 0.14)
        add(0, "ses_sse_reconnect", title: "Fix SSE reconnect after sleep", folder: "Ensemble", provider: "openai", model: "gpt-5.5",
            agent: "GPT-5.5", input: 96_000, output: 4_200, cost: 5.12)
        add(0, "ses_design_room", title: "Design review, Opus", folder: "Ensemble", provider: "claude-code", model: "claude-opus-5-5",
            agent: "Opus", input: 640_000, output: 31_000, cost: 9.40)
        add(0, "ses_design_room_gemini", title: "Design review, Gemini", folder: "Ensemble", provider: "antigravity", model: "gemini-3-pro",
            agent: "Gemini", input: 220_000, output: 12_500, cost: 0)
        // Earlier this week.
        add(2, "ses_astro", title: "Migrate to Astro 5", folder: "Developer/portfolio-site", provider: "openai", model: "gpt-5.5",
            agent: "GPT-5.5", input: 210_000, output: 12_000, cost: 1.47)
        add(3, "ses_db_debate", title: "SQLite or Postgres for sync", folder: "Ensemble", provider: "claude-code",
            model: "claude-opus-5-5", agent: "Opus", input: 380_000, output: 22_000, cost: 6.10)
        add(4, "ses_rate_limit", title: "Rate limiter tests", folder: "Developer/api-server", provider: "xai",
            model: "grok-5", agent: "Grok 5", input: 150_000, output: 9_000, cost: 0.38)
        // Earlier this month.
        add(12, "ses_readme", title: "Write the README", folder: "Ensemble", provider: "anthropic", model: "claude-sonnet-5",
            agent: "Claude Sonnet 5", input: 41_000, output: 3_100, cost: 0.22)
        add(20, "ses_onboarding", title: "Onboarding flow", folder: "Developer/portfolio-site", provider: "openrouter",
            model: "deepseek/deepseek-v4", agent: "DeepSeek V4", input: 520_000, output: 40_000, cost: 0.86)
        return ledger
    }

    static let billing: [String: ModelBilling] = [
        "anthropic": .apiKey, "openai": .apiKey, "openrouter": .apiKey, "xai": .apiKey,
        "claude-code": .subscription, "antigravity": .subscription,
    ]

    static let caps: [String: Double] = ["openai": 5, "anthropic": 20]

    /// Five-hour window at 46%, weekly at 71% (decoded, since the window type has no public initialiser).
    static func planLimits(now: Date) -> ClaudePlanLimits? {
        let fiveHour = now.addingTimeInterval(2 * 3600 + 17 * 60).timeIntervalSinceReferenceDate
        let weekly = now.addingTimeInterval(3 * 86_400 + 5 * 3600).timeIntervalSinceReferenceDate
        let object: [String: Any] = [
            "status": "allowed", "limitType": "five_hour", "utilization": 0.46, "resetsAt": fiveHour,
            "updated": now.addingTimeInterval(-90).timeIntervalSinceReferenceDate,
            "windows": [
                ["name": "five_hour", "utilization": 0.46, "resetsAt": fiveHour, "status": "allowed"],
                ["name": "seven_day", "utilization": 0.71, "resetsAt": weekly, "status": "allowed"],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ClaudePlanLimits.self, from: data)
    }
}
