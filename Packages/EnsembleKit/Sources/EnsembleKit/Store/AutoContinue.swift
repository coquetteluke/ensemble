import Foundation

// Auto-continue when a plan limit resets. When a turn fails because the subscription's usage limit is reached, the
// transcript shows a limit card (when it resets, and a "Continue automatically" switch, on by default). A minute after
// the reset the store sends "Continue" to the session, if the switch is still on and the session is idle. The timer is
// re-checked at least once a minute and when the Mac wakes (`SessionStore.autoContinueAfterWake()`), so sleeping
// through the reset still continues on wake. Stops live in memory only: they do not survive quitting the app.
//
// What the Claude CLI reports at a limit (claude 2.1.319, read from the SDK message schema and the message builder in
// the CLI itself; no real limit was spent to see it, and `ClaudeCodeDecoderTests` replays a synthetic stream built
// from that schema):
// - `{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":<unix seconds>,"rateLimitType":
//   "five_hour"|"seven_day"|"seven_day_opus"|...}}` first, from the API's 429 headers;
// - then an assistant message with `"error":"rate_limit"` (and `api_error: "usage_limit_reached"` on some plans) whose
//   text is "You've hit your 5-hour limit · resets 3pm (Europe/London)" ("weekly limit", "Opus limit", "usage limit");
// - then `{"type":"result","subtype":"success","is_error":true,"result":"<the same text>","api_error_status":429}`.
// Older CLIs wrote "Claude AI usage limit reached|<unix seconds>". `result` subtypes other than `success`
// (`error_during_execution`, `error_max_turns`, `error_max_budget_usd`, `error_max_structured_output_retries`) are not
// limit errors.

/// The plan limit that ended a session's last turn, as the engine reports it.
public struct UsageLimitInfo: Hashable, Sendable {
    /// When the limit resets, when reported.
    public var resetsAt: Date?
    /// The window that ran out: `five_hour`, `seven_day`, `seven_day_opus`, ...
    public var window: String?
    /// The engine's own message.
    public var message: String?

    public init(resetsAt: Date? = nil, window: String? = nil, message: String? = nil) {
        self.resetsAt = resetsAt
        self.window = window
        self.message = message
    }
}

/// Engines that can tell a plan limit from other failures adopt this; the store checks with `as?`. Without it the
/// store recognises limit errors by their text alone (`UsageLimitText`).
public protocol EngineUsageLimitReporting: Sendable {
    /// The plan limit that ended the session's last turn, or nil when that turn did not stop on a limit.
    func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo?
}

/// A turn that stopped on a plan limit, shown as the limit card in place of its error row.
public struct UsageLimitStop: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// Waiting for the reset.
        case waiting
        /// "Continue" was sent after the reset.
        case sent
        /// A newer turn started (you sent something, or another limit stop replaced this one); nothing is sent.
        case superseded
    }

    /// How long after the reset "Continue" goes out, so the limit has surely lifted.
    public static let delayAfterReset: TimeInterval = 60

    /// The id of the transcript error row the card replaces.
    public var id: String
    public var sessionID: String
    public var resetsAt: Date?
    public var window: String?
    public var message: String
    /// The card's switch (on by default).
    public var autoContinue: Bool
    public var state: State
    public var sentAt: Date?

    public init(id: String, sessionID: String, resetsAt: Date?, window: String? = nil, message: String,
                autoContinue: Bool = true, state: State = .waiting, sentAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.resetsAt = resetsAt
        self.window = window
        self.message = message
        self.autoContinue = autoContinue
        self.state = state
        self.sentAt = sentAt
    }

    /// When "Continue" goes out: a minute after the reset. Nil when the reset time is unknown.
    public var continueAt: Date? { resetsAt?.addingTimeInterval(Self.delayAfterReset) }

    /// True while the switch can still do something.
    public var isPending: Bool { state == .waiting && continueAt != nil }

    /// Due at `now`: waiting, switched on and past its time.
    public func isDue(at now: Date) -> Bool {
        guard state == .waiting, autoContinue, let continueAt else { return false }
        return now >= continueAt
    }

    /// The window's name for the card ("5-hour limit", "Weekly limit").
    public var windowLabel: String {
        switch window {
        case "five_hour": "5-hour limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        case "seven_day_sonnet": "Weekly Sonnet limit"
        case nil: "Usage limit"
        case let other?: other.split(separator: "_").joined(separator: " ").capitalized(with: nil)
        }
    }
}

/// Recognises plan limit errors by their text.
public enum UsageLimitText {
    /// True when an error message says the subscription's usage limit is reached ("You've hit your 5-hour limit",
    /// "Claude AI usage limit reached", Ensemble's own "usage limit is reached"). Spend caps, shared budgets and
    /// usage credits are not plan windows and do not count.
    public static func isUsageLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        for excluded in ["spend limit", "shared budget", "usage credit", "credit balance", "context limit", "context window"]
            where lower.contains(excluded) { return false }
        if lower.contains("usage limit") { return true }
        if let hit = lower.range(of: "hit your "), lower[hit.upperBound...].contains("limit") { return true }
        if lower.contains("limit reached"), lower.contains("resets") { return true }
        return false
    }

    /// The reset time in the older CLI form "Claude AI usage limit reached|1795525200" (unix seconds after a bar).
    public static func legacyResetDate(_ text: String) -> Date? {
        guard let bar = text.lastIndex(of: "|") else { return nil }
        let digits = text[text.index(after: bar)...].prefix { $0.isNumber }
        guard digits.count >= 9, let seconds = TimeInterval(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
