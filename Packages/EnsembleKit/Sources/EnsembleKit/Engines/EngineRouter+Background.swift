import Foundation

// Forwards background work (`Store/SessionStore+BackgroundModels.swift`) and plan limit stops (`Store/AutoContinue.swift`)
// to the engine that owns each session. Kept in its own file because both protocols are new; delete this file if they
// move or are renamed.
extension EngineRouter: EngineBackgroundTasks, EngineUsageLimitReporting {
    /// Every engine's background shells and tasks. An engine that fails leaves its own out.
    public func backgroundTasks() async throws -> [BackgroundTask] {
        let controls = registrations.compactMap { $0.engine as? any EngineBackgroundTasks }
        return await withTaskGroup(of: (Int, [BackgroundTask]).self) { group in
            for (index, control) in controls.enumerated() {
                group.addTask { (index, (try? await control.backgroundTasks()) ?? []) }
            }
            var collected: [(Int, [BackgroundTask])] = []
            for await answer in group { collected.append(answer) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    public func stopBackgroundTask(_ task: BackgroundTask) async throws {
        guard let registration = await registration(forSession: task.sessionID) else {
            throw EngineRouterError.unknownSession(task.sessionID)
        }
        guard let control = registration.engine as? any EngineBackgroundTasks else {
            throw EngineRouterError.notSupported(engine: registration.name, feature: "stop background tasks")
        }
        try await control.stopBackgroundTask(task)
    }

    /// The owning engine stops only the subagent when it can; otherwise the subagent's session is interrupted.
    public func stopSubagent(_ sessionID: String) async throws {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        if let control = registration.engine as? any EngineBackgroundTasks {
            try await control.stopSubagent(sessionID)
        } else {
            try await registration.engine.interrupt(sessionID)
        }
    }

    public func usageLimitStop(_ sessionID: String) async -> UsageLimitInfo? {
        guard let reporter = await registration(forSession: sessionID)?.engine as? any EngineUsageLimitReporting else { return nil }
        return await reporter.usageLimitStop(sessionID)
    }
}
