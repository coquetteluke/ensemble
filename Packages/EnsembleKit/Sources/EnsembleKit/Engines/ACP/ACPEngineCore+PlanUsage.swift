#if os(macOS)
import Foundation

/// Plan use for tools that report it (`ACPAgentDefinition.planUsageArguments`, agy's `/usage`), and the plan limits
/// turns stopped on. Held by `ACPEngineCore.planUsage`.
struct ACPPlanUsageState: Sendable {
    var cached: CachedStatus?
    var running: Task<AntigravityPlanStatus, Never>?
    /// The tool answered the usage command with a turn (or something that is not a usage answer): it is not asked again
    /// until Ensemble restarts, so an agy without `/usage` never spends quota on it more than once.
    var unsupported = false
    var lastHit: AntigravityLimitHit?
    /// The limit each session's last turn stopped on, for the transcript's limit card (`EngineUsageLimitReporting`).
    var stops: [String: AntigravityLimitHit] = [:]
    var stopModels: [String: String] = [:]

    struct CachedStatus: Sendable {
        var date: Date
        var status: AntigravityPlanStatus
    }
}

extension ACPEngineCore {
    /// A reading this young is answered from memory (agy takes about six seconds to answer `/usage`).
    static let planUsageMaxAge: TimeInterval = 60

    /// The tool's plan use: agy's `/usage` answer (read at most once a minute unless `refresh`), plus the newest limit
    /// hit. nil when the tool reports no plan use or is not installed. Runs only when the tool is signed in, in
    /// Ensemble's own empty folder, so it never opens a sign-in page and never loads a project's settings.
    func planStatus(refresh: Bool) async -> AntigravityPlanStatus? {
        guard let arguments = definition.planUsageArguments, executableURL() != nil else { return nil }
        if !refresh, let cached = planUsage.cached, Date().timeIntervalSince(cached.date) < Self.planUsageMaxAge {
            return withLimitHit(cached.status)
        }
        if let running = planUsage.running { return withLimitHit(await running.value) }
        if planUsage.unsupported { return withLimitHit(AntigravityPlanStatus(problem: .notReported)) }
        let task = Task { await self.readPlanUsage(arguments: arguments) }
        planUsage.running = task
        let status = await task.value
        planUsage.running = nil
        planUsage.cached = ACPPlanUsageState.CachedStatus(date: Date(), status: status)
        return withLimitHit(status)
    }

    private func readPlanUsage(arguments: [String]) async -> AntigravityPlanStatus {
        guard await authState(refresh: false).signedIn == true, let executable = executableURL() else {
            return AntigravityPlanStatus(problem: .noAnswer)
        }
        let folder = configuration.workDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let environment = ACPEnvironment.environment(base: configuration.baseEnvironment, definition: definition)
        let output = await ACPCommandRunner.run(executable, arguments, environment: environment, timeout: .seconds(30), directory: folder)
        switch AntigravityPlanUsage.decode(output ?? "") {
        case .usage(let usage):
            return AntigravityPlanStatus(usage: usage)
        case .notACommand:
            planUsage.unsupported = true
            return AntigravityPlanStatus(problem: .notReported)
        case .unreadable:
            return AntigravityPlanStatus(problem: .noAnswer)
        }
    }

    private func withLimitHit(_ status: AntigravityPlanStatus) -> AntigravityPlanStatus {
        var status = status
        status.limitHit = planUsage.lastHit
        let settled = status.settled()
        if settled.limitHit == nil { planUsage.lastHit = nil }
        return settled
    }

    /// Called as each turn ends: a failure with agy's plan limit wording is remembered (and the next reading is fresh);
    /// a turn that succeeds clears its session's limit.
    func notePlanLimit(sessionID: String, outcome: String, message: String?, modelID: String?) {
        guard definition.planUsageArguments != nil else { return }
        if outcome == "failed", let message, let hit = AntigravityLimitText.hit(in: message, sessionID: sessionID) {
            planUsage.lastHit = hit
            planUsage.stops[sessionID] = hit
            planUsage.stopModels[sessionID] = modelID
            planUsage.cached = nil
        } else if outcome == "succeeded" {
            planUsage.stops[sessionID] = nil
            planUsage.stopModels[sessionID] = nil
            if planUsage.lastHit?.sessionID == sessionID { planUsage.lastHit = nil }
        }
    }

    /// The limit a session's last turn stopped on, for the limit card. Without a reset time in agy's message, a fresh
    /// `/usage` reading gives the used-up limit of the session's model group and when it resets.
    func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? {
        guard let hit = planUsage.stops[sessionID] else { return nil }
        let model = planUsage.stopModels[sessionID]
        var info = UsageLimitInfo(resetsAt: hit.resetsAt, message: hit.message)
        if let group = await planStatus(refresh: true)?.usage?.group(forModel: model) {
            let usedUp = group.buckets.filter(\.isUsedUp).sorted { ($0.resetsAt ?? .distantPast) > ($1.resetsAt ?? .distantPast) }
            if let bucket = usedUp.first {
                info.window = bucket.windowName
                if info.resetsAt == nil { info.resetsAt = bucket.resetsAt }
            }
        }
        return info
    }
}
#endif
