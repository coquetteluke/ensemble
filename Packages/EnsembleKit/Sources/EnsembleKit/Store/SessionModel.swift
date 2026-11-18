import Foundation
import Observation

/// Live state of one session. Each session is its own observable object so a streaming transcript
/// only redraws the views that show that session.
@Observable @MainActor
public final class SessionModel: Identifiable {
    public let id: String
    public internal(set) var info: EngineSession
    public internal(set) var items: [TranscriptItem] = []
    public internal(set) var activity: SessionActivity = .idle
    public internal(set) var pendingPermissions: [PermissionRequest] = []
    /// How answered permission prompts were resolved, by request id.
    public internal(set) var resolutions: [String: PermissionResolution] = [:]
    public internal(set) var usage: Usage
    public internal(set) var context: ContextBreakdown?
    public internal(set) var changedFiles: [FileChange] = []
    /// The engine session type has no permission mode yet, so the store keeps it here.
    public internal(set) var permissionMode: PermissionMode
    public internal(set) var transcriptLoaded = false
    /// When the current turn started (nil while idle).
    public internal(set) var workingSince: Date?
    /// Bumped on every transcript change; views use it to keep the newest text in view.
    public internal(set) var revision = 0
    /// Set for room sessions: new agent text is tagged with this agent so the UI can show its name and colour.
    public var agentID: UUID?
    /// Effort for the next turn, when the engine and model support it (nil = the model's default).
    public internal(set) var effort: EffortLevel?
    public internal(set) var fastMode = false

    public init(info: EngineSession, permissionMode: PermissionMode = .auto) {
        self.id = info.id
        self.info = info
        self.usage = info.usage
        self.permissionMode = permissionMode
    }

    public var title: String { info.title }
    public var directory: String { info.directory }
    public var isSubagent: Bool { info.parentID != nil }
    public var isWorking: Bool { activity == .working || activity == .waitingForPermission }

    func touch() { revision &+= 1 }

    func setActivity(_ new: SessionActivity) {
        if new == .working || new == .waitingForPermission {
            if workingSince == nil { workingSince = Date() }
        } else {
            workingSince = nil
        }
        activity = new
    }
}

/// Sessions in one project folder, for the sidebar.
public struct ProjectGroup: Identifiable {
    public let id: String
    public let directory: String
    public let name: String
    public let sessions: [SessionModel]

    public init(id: String, directory: String, name: String, sessions: [SessionModel]) {
        self.id = id
        self.directory = directory
        self.name = name
        self.sessions = sessions
    }
}

/// Everything the store needs to show a full window without waiting on the engine.
/// Used by previews and snapshot rendering, and as the preview engine's starting data.
public struct StoreSeed: Sendable {
    public var sessions: [EngineSession]
    public var transcripts: [String: [TranscriptItem]]
    public var activities: [String: SessionActivity]
    public var permissions: [PermissionRequest]
    public var contexts: [String: ContextBreakdown]
    public var changes: [String: [FileChange]]
    public var modes: [String: PermissionMode]
    public var connectors: [ConnectorInfo]
    public var models: [ModelInfo]
    public var providers: [ProviderInfo]
    public var schedules: [ScheduleInfo]
    /// Room agents (name and colour) and which session belongs to which agent.
    public var agents: [AgentSpec]
    public var sessionAgentIDs: [String: [UUID]]
    public var extraFolders: [String: [String]]
    public var selectedSessionID: String?

    public init(sessions: [EngineSession] = [], transcripts: [String: [TranscriptItem]] = [:],
                activities: [String: SessionActivity] = [:], permissions: [PermissionRequest] = [],
                contexts: [String: ContextBreakdown] = [:], changes: [String: [FileChange]] = [:],
                modes: [String: PermissionMode] = [:], connectors: [ConnectorInfo] = [], models: [ModelInfo] = [],
                providers: [ProviderInfo] = [], schedules: [ScheduleInfo] = [], agents: [AgentSpec] = [],
                sessionAgentIDs: [String: [UUID]] = [:], extraFolders: [String: [String]] = [:],
                selectedSessionID: String? = nil) {
        self.sessions = sessions
        self.transcripts = transcripts
        self.activities = activities
        self.permissions = permissions
        self.contexts = contexts
        self.changes = changes
        self.modes = modes
        self.connectors = connectors
        self.models = models
        self.providers = providers
        self.schedules = schedules
        self.agents = agents
        self.sessionAgentIDs = sessionAgentIDs
        self.extraFolders = extraFolders
        self.selectedSessionID = selectedSessionID
    }
}
