import Foundation

/// Sorts sessions into Session Hub buckets. Same rules as Luke's ~/Session Hub control room:
/// when unsure between Needs you and Finished, choose Needs you (a false alarm costs a glance,
/// a miss is the failure the hub exists to prevent).
public enum HubBoard {
    public static let needsYouWindow: TimeInterval = 7 * 24 * 3600
    public static let finishedWindow: TimeInterval = 3 * 24 * 3600

    /// The bucket for one session, or `nil` when it should not be on the board at all
    /// (archived, or marked done with no activity since).
    public static func bucket(for s: SessionSummary, now: Date = Date()) -> HubBucket? {
        if s.archived { return nil }
        if let done = s.markedDoneAt, s.lastActivity <= done { return nil }

        let age = now.timeIntervalSince(s.lastActivity)
        let waitingOnUser = s.pendingPermissions > 0
            || s.activity == .waitingForPermission
            || s.activity == .failed
            || s.endedWithQuestion
            || s.pendingAsk != nil

        // A permission prompt blocks the agent even while the session counts as busy.
        if s.pendingPermissions > 0 || s.activity == .waitingForPermission { return .needsYou }
        if s.activity == .working { return .running }
        if waitingOnUser && age <= needsYouWindow { return .needsYou }
        if age <= finishedWindow { return .finished }
        return .old
    }

    /// All sessions grouped by bucket, newest activity first inside each bucket.
    public static func group(_ sessions: [SessionSummary], now: Date = Date()) -> [HubBucket: [SessionSummary]] {
        var out: [HubBucket: [SessionSummary]] = [:]
        for s in sessions {
            guard let b = bucket(for: s, now: now) else { continue }
            out[b, default: []].append(s)
        }
        for key in out.keys {
            out[key]?.sort { $0.lastActivity > $1.lastActivity }
        }
        return out
    }
}

// MARK: - Mac Session Hub

/// What the Mac Session Hub knows about one session or room when it sorts it (`HubSorter`). Built from the attention
/// snapshots, the user's marks (unread, completed) and the rooms, never from streaming text.
public struct HubCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case session
        case room
    }

    /// The session id, or the room's UUID string.
    public var id: String
    public var kind: Kind
    public var lastActivity: Date
    /// Open permission prompts, plans and questions (the session's and its subagents', or the room agents'), oldest first.
    public var requests: [PermissionRequest]
    /// What the room waits on the user for (rooms only).
    public var roomDecision: RoomDecision?
    /// The room paused itself and waits on the user (an agent hit its spending cap).
    public var roomPausedForUser: Bool
    /// The session, a subagent or a room agent is working.
    public var running: Bool
    /// The last turn failed.
    public var failed: Bool
    /// The agent's last message asks the user something.
    public var endedWithQuestion: Bool
    /// A turn finished while the user was not looking.
    public var unread: Bool
    /// The user marked it completed (and nothing happened since).
    public var completed: Bool
    public var archived: Bool

    public init(id: String, kind: Kind = .session, lastActivity: Date, requests: [PermissionRequest] = [],
                roomDecision: RoomDecision? = nil, roomPausedForUser: Bool = false, running: Bool = false,
                failed: Bool = false, endedWithQuestion: Bool = false, unread: Bool = false, completed: Bool = false,
                archived: Bool = false) {
        self.id = id
        self.kind = kind
        self.lastActivity = lastActivity
        self.requests = requests
        self.roomDecision = roomDecision
        self.roomPausedForUser = roomPausedForUser
        self.running = running
        self.failed = failed
        self.endedWithQuestion = endedWithQuestion
        self.unread = unread
        self.completed = completed
        self.archived = archived
    }

    /// The room waits on a decision or a pause it made.
    public var roomNeedsUser: Bool { roomDecision != nil || roomPausedForUser }
}

/// Why a card is where it is, most pressing first. The card's one-line summary and quick actions follow from it.
public enum HubReason: Hashable, Sendable {
    /// A permission prompt (the oldest open request is one).
    case permission(PermissionRequest)
    /// A plan waiting for Proceed or Keep planning.
    case plan(PermissionRequest)
    /// Multiple-choice questions waiting for answers.
    case question(PermissionRequest)
    /// A room waits on a decision.
    case roomDecision(RoomDecision)
    /// A room paused itself (spending cap) and waits on the user.
    case roomPaused
    case failed
    /// The agent's last message asks something.
    case askedQuestion
    case running
    case unread
    case finished
    case completed
    case archived
    /// Quiet for longer than the Finished window.
    case quiet
}

/// One bucket of the board with its cards in order.
public struct HubSection: Identifiable, Hashable, Sendable {
    public var bucket: HubBucket
    public var items: [HubCandidate]
    public var id: HubBucket { bucket }

    public init(bucket: HubBucket, items: [HubCandidate]) {
        self.bucket = bucket
        self.items = items
    }
}

/// The Mac Session Hub's rules.
///
/// - **Needs you:** an open permission prompt, plan or question, or a room waiting on a decision (these block the
///   agent, so they never age out); a failed turn or a last message that asks something, within the past 7 days.
/// - **Running:** an agent is working (its own turn, a subagent, or a room agent).
/// - **Finished:** done recently (3 days) and not marked completed, or finished while you were not looking (unread).
/// - **Old:** everything else: older, marked completed, or archived (only listed when asked for).
public enum HubSorter {
    public static let needsYouWindow = HubBoard.needsYouWindow
    public static let finishedWindow = HubBoard.finishedWindow

    /// The bucket for one card, or nil when it is not on the board (archived, unless `showArchived`).
    public static func bucket(for c: HubCandidate, now: Date = Date(), showArchived: Bool = false) -> HubBucket? {
        if c.archived { return showArchived ? .old : nil }
        switch reason(for: c, now: now) {
        case .permission, .plan, .question, .roomDecision, .roomPaused, .failed, .askedQuestion: return .needsYou
        case .running: return .running
        case .unread, .finished: return .finished
        case .completed, .archived, .quiet: return .old
        }
    }

    /// Why the card is where it is.
    public static func reason(for c: HubCandidate, now: Date = Date()) -> HubReason {
        if c.archived { return .archived }
        // An open request blocks the agent even while it counts as busy, whatever its age or marks.
        if let first = c.requests.first {
            if first.isPlan { return .plan(first) }
            if first.isQuestion { return .question(first) }
            return .permission(first)
        }
        if let decision = c.roomDecision { return .roomDecision(decision) }
        if c.roomPausedForUser { return .roomPaused }
        if c.running { return .running }
        // The user dealt with it.
        if c.completed { return .completed }
        let age = now.timeIntervalSince(c.lastActivity)
        if c.failed && age <= needsYouWindow { return .failed }
        if c.endedWithQuestion && age <= needsYouWindow { return .askedQuestion }
        if c.unread { return .unread }
        if age <= finishedWindow { return .finished }
        return .quiet
    }

    /// The board: non-empty buckets in order (Needs you, Running, Finished, Old), newest activity first inside each.
    public static func arrange(_ candidates: [HubCandidate], now: Date = Date(), showArchived: Bool = false) -> [HubSection] {
        var byBucket: [HubBucket: [HubCandidate]] = [:]
        for candidate in candidates {
            guard let bucket = bucket(for: candidate, now: now, showArchived: showArchived) else { continue }
            byBucket[bucket, default: []].append(candidate)
        }
        return HubBucket.allCases.compactMap { bucket in
            guard let items = byBucket[bucket], !items.isEmpty else { return nil }
            return HubSection(bucket: bucket, items: items.sorted { a, b in
                a.lastActivity != b.lastActivity ? a.lastActivity > b.lastActivity : a.id < b.id
            })
        }
    }

    /// True when a prompt may be allowed or rejected from the Hub with one click: a permission prompt (never a plan or
    /// question) whose whole command is short and on one line, so the card shows everything being approved.
    public static func allowsQuickApproval(_ request: PermissionRequest) -> Bool {
        !request.isInteraction && PermissionDisplay.fitsQuickApproval(request)
    }

    /// True when the last agent text asks the user something (its last line ends with a question mark).
    public static func asksSomething(_ text: String?) -> Bool {
        guard let text else { return false }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var last = lines.last else { return false }
        // "Should I go ahead?**" or "... (yes or no)?" still count.
        while let end = last.last, "*_`)\"\u{201D}".contains(end) { last.removeLast() }
        return last.hasSuffix("?")
    }

    /// One line for what a room waits on. `agentName` names the agent a decision is about.
    public static func decisionText(_ decision: RoomDecision, agentName: (UUID) -> String?) -> String {
        switch decision {
        case .approvePlan: "Approve the lead's plan"
        case .writePlan: "Write the plan"
        case .reviewStalemate(let id): "Review stuck on \(agentName(id) ?? "an agent")'s piece"
        case .takeover(let id): "\(agentName(id) ?? "An agent") offers to take over"
        case .judge: "Write the verdict"
        case .mergeConflict(let id, let files):
            "Merge conflict in \(agentName(id) ?? "an agent")'s piece, \(files.count) \(files.count == 1 ? "file" : "files")"
        }
    }
}
