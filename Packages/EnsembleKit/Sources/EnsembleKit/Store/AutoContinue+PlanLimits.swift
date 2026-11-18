import Foundation

/// The subscription's plan use for the small ring by the composer: the five-hour window on the outer arc, the weekly
/// window on the inner one. It turns amber at 80% of any window and red when a window is used up (or the plan says the
/// limit is reached). The per-window "allowed_warning" status (the CLI's pace warning, which can come at 58%) does not
/// colour the ring: the ring says how close a limit is, the usage popover's bars say the rest.
public struct PlanLimitMeter: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case normal
        case nearLimit
        case limited

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Window: Equatable, Sendable, Identifiable {
        /// `five_hour`, `seven_day`, `seven_day_opus`, ...
        public var name: String
        /// 0...1.
        public var utilization: Double
        public var resetsAt: Date?
        public var status: String?

        public init(name: String, utilization: Double, resetsAt: Date? = nil, status: String? = nil) {
            self.name = name
            self.utilization = utilization
            self.resetsAt = resetsAt
            self.status = status
        }

        public var id: String { name }

        /// Use clamped to 0...1.
        public var fraction: Double { min(max(utilization, 0), 1) }

        public var level: Level { PlanLimitMeter.level(utilization: utilization, status: status) }

        public var isWeekly: Bool { name.hasPrefix("seven_day") }

        /// "5-hour", "Weekly", "Weekly Opus".
        public var shortLabel: String {
            switch name {
            case "five_hour": "5-hour"
            case "seven_day": "Weekly"
            case "seven_day_opus": "Weekly Opus"
            case "seven_day_sonnet": "Weekly Sonnet"
            default: name.split(separator: "_").joined(separator: " ").capitalized(with: nil)
            }
        }
    }

    /// Amber from here on.
    public static let nearLimitThreshold = 0.8

    /// Every reported window, five-hour first, then weekly.
    public var windows: [Window]
    /// True when the plan refuses work until a reset.
    public var isLimited: Bool

    public init(windows: [Window], isLimited: Bool = false) {
        self.windows = windows.sorted { Self.order($0.name) < Self.order($1.name) }
        self.isLimited = isLimited
    }

    /// From the Claude engine's newest report. The headline window counts when it is not among the windows.
    public init(limits: ClaudePlanLimits) {
        var windows = limits.windows.map { Window(name: $0.name, utilization: $0.utilization, resetsAt: $0.resetsAt, status: $0.status) }
        if let type = limits.limitType, !windows.contains(where: { $0.name == type }), let utilization = limits.utilization {
            windows.append(Window(name: type, utilization: utilization, resetsAt: limits.resetsAt, status: limits.status))
        }
        if limits.isLimited, let type = limits.limitType, let index = windows.firstIndex(where: { $0.name == type }) {
            windows[index].status = "rejected"
        }
        self.init(windows: windows, isLimited: limits.isLimited)
    }

    public var fiveHour: Window? { windows.first { $0.name == "five_hour" } }
    /// The general weekly window, else the first per-model weekly one.
    public var weekly: Window? { windows.first { $0.name == "seven_day" } ?? windows.first(where: \.isWeekly) }

    /// The window closest to its limit (the label shows it).
    public var leading: Window? {
        windows.max { a, b in (a.level, a.fraction) < (b.level, b.fraction) }
    }

    /// The ring's colour.
    public var level: Level {
        let worst = windows.map(\.level).max() ?? .normal
        return isLimited ? .limited : worst
    }

    public static func level(utilization: Double, status: String?) -> Level {
        if status == "rejected" || utilization >= 1 { return .limited }
        if utilization >= nearLimitThreshold { return .nearLimit }
        return .normal
    }

    private static func order(_ name: String) -> Int {
        ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].firstIndex(of: name) ?? 99
    }
}
