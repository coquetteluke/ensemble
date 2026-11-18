import Foundation

/// Basic facts about a session from the engine.
public struct EngineSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var parentID: String?
    public var title: String
    public var directory: String
    public var model: ModelRef?
    public var agent: String?
    public var usage: Usage
    public var created: Date
    public var updated: Date
    public var archived: Bool

    public init(id: String, parentID: String? = nil, title: String, directory: String, model: ModelRef? = nil, agent: String? = nil,
                usage: Usage = .zero, created: Date = Date(), updated: Date = Date(), archived: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.directory = directory
        self.model = model
        self.agent = agent
        self.usage = usage
        self.created = created
        self.updated = updated
        self.archived = archived
    }
}

/// A scheduled prompt (engine schedules API).
public struct ScheduleInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var prompt: String
    public var directory: String
    /// Cron expression or the engine's own schedule text.
    public var schedule: String
    public var paused: Bool
    public var nextRun: Date?

    public init(id: String, title: String, prompt: String, directory: String, schedule: String, paused: Bool = false, nextRun: Date? = nil) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.directory = directory
        self.schedule = schedule
        self.paused = paused
        self.nextRun = nextRun
    }
}

/// Typed events from the engine's live stream (`GET /api/event`). Unknown types arrive as `.other`.
public enum EngineEvent: Sendable, Equatable {
    case sessionCreated(EngineSession)
    case sessionUpdated(EngineSession)
    case sessionDeleted(sessionID: String)
    case activity(sessionID: String, SessionActivity)
    case textDelta(sessionID: String, itemID: String, delta: String)
    case textEnded(sessionID: String, itemID: String, text: String)
    case reasoningDelta(sessionID: String, itemID: String, delta: String)
    case toolUpdated(sessionID: String, ToolCallInfo)
    case permissionAsked(PermissionRequest)
    case permissionReplied(sessionID: String, requestID: String)
    case usageUpdated(sessionID: String, Usage)
    case executionEnded(sessionID: String, outcome: String, error: String?)
    case filesChanged(paths: [String])
    case connectorsChanged
    case other(type: String)
}

/// Everything the apps need from the engine. `OpenCodeClient` is the real implementation;
/// the UI also has a preview implementation so it can be built and tested without a running engine.
public protocol OpenCodeAPI: Sendable {
    func serverInfo() async throws -> (version: String, url: URL)

    // Sessions
    func listSessions() async throws -> [EngineSession]
    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession
    func deleteSession(_ sessionID: String) async throws
    func renameSession(_ sessionID: String, title: String) async throws
    func setArchived(_ sessionID: String, archived: Bool) async throws
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws
    func switchModel(_ sessionID: String, model: ModelRef) async throws
    func transcript(_ sessionID: String) async throws -> [TranscriptItem]
    func children(_ sessionID: String) async throws -> [EngineSession]

    // Talking
    func prompt(_ sessionID: String, text: String, files: [URL]) async throws
    /// Injects text into the session as if from the system, without the user speaking. Used to relay
    /// other agents' board messages. `wake` asks the agent to respond to it.
    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws
    func interrupt(_ sessionID: String) async throws
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws
    func pendingPermissions() async throws -> [PermissionRequest]

    // Panels
    func context(_ sessionID: String) async throws -> ContextBreakdown
    func changedFiles(_ sessionID: String) async throws -> [FileChange]
    func connectors() async throws -> [ConnectorInfo]

    // Models and keys
    func models() async throws -> [ModelInfo]
    func providers() async throws -> [ProviderInfo]
    func setAPIKey(providerID: String, key: String) async throws
    func removeAPIKey(providerID: String) async throws

    // Schedules
    func schedules() async throws -> [ScheduleInfo]
    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo
    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws
    func deleteSchedule(_ scheduleID: String) async throws

    /// Live events. The stream reconnects by itself; it ends only when the task is cancelled.
    func events() -> AsyncStream<EngineEvent>
}
