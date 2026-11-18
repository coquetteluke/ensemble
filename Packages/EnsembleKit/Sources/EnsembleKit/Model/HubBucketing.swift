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
