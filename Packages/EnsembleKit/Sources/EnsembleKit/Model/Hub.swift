import Foundation

/// Session Hub buckets, in the order they are shown.
public enum HubBucket: String, Codable, CaseIterable, Sendable {
    case needsYou
    case running
    case finished
    case old

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .finished: "Finished"
        case .old: "Old"
        }
    }
}

/// One session or room as the sidebar and Session Hub see it.
public struct SessionSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var directory: String
    public var roomID: UUID?
    public var agentNames: [String]
    public var activity: SessionActivity
    public var lastActivity: Date
    /// What it is waiting on, in a few words ("Approve: rm -rf build", "Asked which API to use").
    public var pendingAsk: String?
    /// Open permission prompts.
    public var pendingPermissions: Int
    /// True if the last thing it said asks something of the user.
    public var endedWithQuestion: Bool
    public var archived: Bool
    /// Set when the user marked it done; it leaves the board until there is newer activity.
    public var markedDoneAt: Date?
    public var usage: Usage
    /// Active model provider id (added after protocol 4 shipped).
    public var modelProviderID: String?
    /// Active model id (added after protocol 4 shipped).
    public var modelID: String?
    /// Staged next-message model display name when a switch is pending (added after protocol 4 shipped).
    public var pendingModelName: String?

    public init(id: String, title: String, directory: String, roomID: UUID? = nil, agentNames: [String] = [],
                activity: SessionActivity, lastActivity: Date, pendingAsk: String? = nil, pendingPermissions: Int = 0,
                endedWithQuestion: Bool = false, archived: Bool = false, markedDoneAt: Date? = nil, usage: Usage = .zero,
                modelProviderID: String? = nil, modelID: String? = nil, pendingModelName: String? = nil) {
        self.id = id
        self.title = title
        self.directory = directory
        self.roomID = roomID
        self.agentNames = agentNames
        self.activity = activity
        self.lastActivity = lastActivity
        self.pendingAsk = pendingAsk
        self.pendingPermissions = pendingPermissions
        self.endedWithQuestion = endedWithQuestion
        self.archived = archived
        self.markedDoneAt = markedDoneAt
        self.usage = usage
        self.modelProviderID = modelProviderID
        self.modelID = modelID
        self.pendingModelName = pendingModelName
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, directory, roomID, agentNames, activity, lastActivity
        case pendingAsk, pendingPermissions, endedWithQuestion, archived, markedDoneAt, usage
        case modelProviderID, modelID, pendingModelName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        directory = try c.decode(String.self, forKey: .directory)
        roomID = try c.decodeIfPresent(UUID.self, forKey: .roomID)
        agentNames = try c.decodeIfPresent([String].self, forKey: .agentNames) ?? []
        activity = try c.decode(SessionActivity.self, forKey: .activity)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        pendingAsk = try c.decodeIfPresent(String.self, forKey: .pendingAsk)
        pendingPermissions = try c.decodeIfPresent(Int.self, forKey: .pendingPermissions) ?? 0
        endedWithQuestion = try c.decodeIfPresent(Bool.self, forKey: .endedWithQuestion) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        markedDoneAt = try c.decodeIfPresent(Date.self, forKey: .markedDoneAt)
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage) ?? .zero
        modelProviderID = try c.decodeIfPresent(String.self, forKey: .modelProviderID)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        pendingModelName = try c.decodeIfPresent(String.self, forKey: .pendingModelName)
    }
}
