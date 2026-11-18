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

    public init(id: String, title: String, directory: String, roomID: UUID? = nil, agentNames: [String] = [],
                activity: SessionActivity, lastActivity: Date, pendingAsk: String? = nil, pendingPermissions: Int = 0,
                endedWithQuestion: Bool = false, archived: Bool = false, markedDoneAt: Date? = nil, usage: Usage = .zero) {
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
    }
}
