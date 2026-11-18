import Foundation

/// What a top-level session looks like to the attention system: its subagents are folded in, so a
/// prompt from a subagent counts for the session the user sees in the sidebar.
public struct SessionAttentionSnapshot: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var directory: String
    /// Open permission prompts in the session and its subagents, oldest first.
    public var prompts: [PermissionRequest]
    /// The session or one of its subagents has a turn in progress (working or blocked on a prompt).
    public var active: Bool
    /// The session or one of its subagents is working right now (not blocked on a prompt).
    public var working: Bool
    /// The session's own last turn failed.
    public var failed: Bool

    public init(id: String, title: String, directory: String, prompts: [PermissionRequest] = [],
                active: Bool = false, working: Bool = false, failed: Bool = false) {
        self.id = id
        self.title = title
        self.directory = directory
        self.prompts = prompts
        self.active = active
        self.working = working
        self.failed = failed
    }

    public var needsYou: Bool { !prompts.isEmpty }
}

/// Something that happened to a session that the user may want to hear about.
public enum SessionAttentionEvent: Equatable, Sendable {
    /// A new permission prompt (or question) is waiting. Sent once per request id.
    case needsYou(sessionID: String, request: PermissionRequest)
    /// A prompt that was waiting has been answered, here or elsewhere.
    case promptClosed(sessionID: String, requestID: String)
    /// A turn started.
    case started(sessionID: String)
    /// A turn ended without an error, stayed ended for the settle delay, and left no prompt open.
    case finished(sessionID: String)
    /// A turn ended with an error and stayed ended for the settle delay.
    case failed(sessionID: String)

    public var sessionID: String {
        switch self {
        case .needsYou(let id, _), .promptClosed(let id, _), .started(let id), .finished(let id), .failed(let id): id
        }
    }
}

/// Turns successive snapshots of the sessions into attention events, without duplicates.
///
/// - The first update is the baseline: prompts already open and turns already running produce no event,
///   so launching the app does not replay old alerts.
/// - A prompt is announced once per request id, even if it disappears and comes back (a reconnect reloads them).
/// - A turn that ends is announced only after `settleDelay` without a new turn starting, so an engine that
///   briefly reports idle between steps does not cause a "finished" alert. Call `flush(now:)` at `nextDeadline`.
public struct SessionAttentionTracker: Sendable {
    public var settleDelay: TimeInterval
    public private(set) var hasBaseline = false

    private var previous: [String: SessionAttentionSnapshot] = [:]
    private var announcedPrompts: Set<String> = []
    private var announcedOrder: [String] = []
    private var pendingEnds: [String: Date] = [:]
    /// Most prompt ids remembered for duplicate checks.
    static let promptMemory = 2_000

    public init(settleDelay: TimeInterval = 1.5) {
        self.settleDelay = settleDelay
    }

    /// When the next delayed event is due, if any.
    public var nextDeadline: Date? { pendingEnds.values.min() }

    /// The last snapshot of a session.
    public func snapshot(_ sessionID: String) -> SessionAttentionSnapshot? { previous[sessionID] }

    /// Compares `snapshots` with the previous call and returns what changed, plus any delayed events now due.
    public mutating func update(_ snapshots: [SessionAttentionSnapshot], now: Date = Date()) -> [SessionAttentionEvent] {
        let current = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard hasBaseline else {
            hasBaseline = true
            previous = current
            for snapshot in snapshots { for prompt in snapshot.prompts { remember(prompt.id) } }
            return []
        }

        var events: [SessionAttentionEvent] = []
        for snapshot in snapshots {
            let old = previous[snapshot.id]
            for prompt in snapshot.prompts where !announcedPrompts.contains(prompt.id) {
                remember(prompt.id)
                events.append(.needsYou(sessionID: snapshot.id, request: prompt))
            }
            if let old {
                let open = Set(snapshot.prompts.map(\.id))
                for prompt in old.prompts where !open.contains(prompt.id) {
                    events.append(.promptClosed(sessionID: snapshot.id, requestID: prompt.id))
                }
            }

            let wasActive = old?.active ?? false
            if snapshot.active && !wasActive {
                // A turn that resumes within the settle delay is the same turn: no second "started".
                if pendingEnds.removeValue(forKey: snapshot.id) == nil {
                    events.append(.started(sessionID: snapshot.id))
                }
            } else if !snapshot.active && wasActive {
                pendingEnds[snapshot.id] = now.addingTimeInterval(settleDelay)
            } else if !snapshot.active, snapshot.failed, let old, !old.failed {
                // Failed without being seen as working first (a send that failed at once).
                pendingEnds[snapshot.id] = now.addingTimeInterval(settleDelay)
            }
        }

        // Sessions that went away (deleted, archived): close their prompts, forget pending ends.
        for (id, old) in previous where current[id] == nil {
            pendingEnds[id] = nil
            for prompt in old.prompts { events.append(.promptClosed(sessionID: id, requestID: prompt.id)) }
        }

        previous = current
        events += flush(now: now)
        return events
    }

    /// Delayed "finished" and "failed" events that are due at `now`.
    public mutating func flush(now: Date = Date()) -> [SessionAttentionEvent] {
        let due = pendingEnds.filter { $0.value <= now }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        var events: [SessionAttentionEvent] = []
        for (id, _) in due {
            pendingEnds[id] = nil
            guard let snapshot = previous[id], !snapshot.active else { continue }
            if snapshot.failed {
                events.append(.failed(sessionID: id))
            } else if !snapshot.needsYou {
                // Still waiting on a prompt: the needs-you alert already covers it, "finished" would mislead.
                events.append(.finished(sessionID: id))
            }
        }
        return events
    }

    private mutating func remember(_ promptID: String) {
        guard announcedPrompts.insert(promptID).inserted else { return }
        announcedOrder.append(promptID)
        if announcedOrder.count > Self.promptMemory {
            let drop = announcedOrder.count - Self.promptMemory
            for id in announcedOrder.prefix(drop) { announcedPrompts.remove(id) }
            announcedOrder.removeFirst(drop)
        }
    }
}

/// Totals for the Dock badge and the menu bar.
public struct SessionAttentionTotals: Equatable, Sendable {
    /// Sessions with at least one open prompt, plus whatever the extra source adds (rooms).
    public var needsYou: Int
    /// Sessions working right now.
    public var running: Int

    public init(needsYou: Int = 0, running: Int = 0) {
        self.needsYou = needsYou
        self.running = running
    }

    public static func count(_ snapshots: [SessionAttentionSnapshot], extraNeedsYou: Int = 0) -> SessionAttentionTotals {
        SessionAttentionTotals(needsYou: snapshots.filter(\.needsYou).count + max(0, extraNeedsYou),
                               running: snapshots.filter(\.working).count)
    }

    /// Text for the Dock badge ("" hides it). Large counts are capped so the badge stays small.
    public var badgeLabel: String {
        switch needsYou {
        case ..<1: ""
        case 1...99: "\(needsYou)"
        default: "99+"
        }
    }
}

/// One line for an alert about a session: the newest agent text or error, cleaned of Markdown and cut short.
public enum SessionAttentionText {
    public static func excerpt(_ text: String, limit: Int = 160) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            var cleaned = line
            while let first = cleaned.first, "#>-*+".contains(first) {
                cleaned.removeFirst()
                cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            }
            cleaned = cleaned.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            if !cleaned.isEmpty { lines.append(cleaned) }
        }
        let joined = lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:")) + "..."
    }

    /// "Allow this command? swift test" for a permission prompt.
    public static func ask(_ request: PermissionRequest) -> String {
        let question = switch request.kind {
        case "bash", "shell", "command": "Allow this command?"
        case "edit", "write", "patch", "multiedit": "Allow this edit?"
        case "webfetch", "fetch", "websearch": "Allow this web request?"
        case "external_directory": "Allow access outside the project?"
        case "read": "Allow reading this file?"
        case "question": "Asked a question:"
        case "plan": "Plan ready for review:"
        default: "Allow \(request.kind)?"
        }
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? question : "\(question) \(excerpt(title, limit: 120))"
    }
}
