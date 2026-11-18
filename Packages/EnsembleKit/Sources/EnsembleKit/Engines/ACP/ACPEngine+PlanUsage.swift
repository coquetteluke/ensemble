import Foundation

// Plan use and plan limit stops for ACP tools that report them (agy's `/usage`, `ACPEngineCore+PlanUsage.swift`).
extension ACPEngine: EngineUsageLimitReporting {
    #if os(macOS)

    /// The Google AI plan's limits from agy's own `/usage` command (no turn, no quota spent), read at most once a minute
    /// unless `refresh`, and the newest turn that stopped on a plan limit. nil when the tool reports no plan use.
    public func planStatus(refresh: Bool = false) async -> AntigravityPlanStatus? { await core.planStatus(refresh: refresh) }

    public func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? { await core.usageLimitStop(sessionID) }

    #else

    public func planStatus(refresh: Bool = false) async -> AntigravityPlanStatus? { nil }
    public func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? { nil }

    #endif

    /// True when the tool can report plan use (agy).
    public var reportsPlanUsage: Bool { agent.planUsageArguments != nil }
}
