import SwiftUI
import EnsembleKit

/// One card on the Session Hub: the sorted candidate, its bucket and why it is there.
struct HubCardItem: Identifiable, Hashable {
    let candidate: HubCandidate
    let bucket: HubBucket
    let reason: HubReason

    var id: String { candidate.id }
    var isRoom: Bool { candidate.kind == .room }
    var roomID: UUID? { isRoom ? UUID(uuidString: candidate.id) : nil }
}

/// One bucket of cards, in board order.
struct HubBoardSection: Identifiable {
    let bucket: HubBucket
    let items: [HubCardItem]
    var id: HubBucket { bucket }
}

/// Builds the Session Hub's cards from the live session store, the user's marks and the rooms. Reads only what the
/// attention system reads (sessions, activity, prompts, titles) plus the last agent text of idle sessions, so streaming
/// text does not redraw the board; each card observes its own session.
@MainActor
struct HubBoardSource {
    let store: SessionStore
    let marks: SessionAttentionMarks
    var rooms: RoomsController?
    var showArchived = false

    /// The key a room's completed mark is saved under (marks are keyed by text; rooms by UUID).
    static func markID(room id: UUID) -> String { "room:" + id.uuidString }

    /// Room agents' sessions show inside their room's card, not on their own.
    private var roomSessionIDs: Set<String> {
        guard let rooms, rooms.isLoaded else { return [] }
        return rooms.roomSessionIDs
    }

    func candidates() -> [HubCandidate] {
        let hidden = roomSessionIDs
        var out: [HubCandidate] = []
        for snapshot in store.attentionSnapshots() where !hidden.contains(snapshot.id) {
            guard let session = store.session(snapshot.id) else { continue }
            let idle = !snapshot.active && snapshot.prompts.isEmpty && !snapshot.failed
            out.append(HubCandidate(
                id: snapshot.id, kind: .session, lastActivity: session.info.updated, requests: snapshot.prompts,
                running: snapshot.active, failed: snapshot.failed,
                // Only idle sessions are read for a closing question, so streaming text never wakes the board.
                endedWithQuestion: idle && HubSorter.asksSomething(store.lastAgentText(snapshot.id)),
                unread: marks.isUnread(snapshot.id), completed: marks.isCompleted(snapshot.id)))
        }
        if showArchived {
            for session in store.sessions where session.info.parentID == nil && session.info.archived
                && !store.isSideQuestionSession(session.id) && !hidden.contains(session.id) {
                out.append(HubCandidate(id: session.id, kind: .session, lastActivity: session.info.updated, archived: true))
            }
        }
        if let rooms, rooms.isLoaded {
            for room in rooms.rooms {
                let lastActivity = room.board.last?.date ?? room.spec.created
                let requests = room.sessions.values.flatMap { rooms.permissions[$0] ?? [] }
                    .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
                // A room's completed mark holds until something new happens in it.
                let completedAt = marks.completed[Self.markID(room: room.id)]
                out.append(HubCandidate(
                    id: room.id.uuidString, kind: .room, lastActivity: lastActivity, requests: requests,
                    roomDecision: room.pendingDecision, roomPausedForUser: room.isPaused && !room.cappedAgents.isEmpty,
                    running: rooms.isRunning(room.id),
                    completed: completedAt.map { lastActivity <= $0 } ?? false))
            }
        }
        return out
    }

    /// How many cards the Needs you section has (the sidebar's Session Hub badge).
    func needsYouCount(now: Date = Date()) -> Int {
        candidates().filter { HubSorter.bucket(for: $0, now: now) == .needsYou }.count
    }

    /// The board's sections with every card's reason.
    func sections(now: Date) -> [HubBoardSection] {
        HubSorter.arrange(candidates(), now: now, showArchived: showArchived).map { section in
            HubBoardSection(bucket: section.bucket, items: section.items.map {
                HubCardItem(candidate: $0, bucket: section.bucket, reason: HubSorter.reason(for: $0, now: now))
            })
        }
    }
}

/// Text for Hub cards.
@MainActor
enum HubText {
    /// What a permission prompt asks, without the command (the card shows the command in full under it).
    static func question(for request: PermissionRequest) -> String {
        switch request.kind {
        case "bash", "shell", "command": "Allow this command?"
        case "edit", "write", "patch", "multiedit": "Allow this edit?"
        case "webfetch", "fetch", "websearch": "Allow this web request?"
        case "external_directory": "Allow access outside the project?"
        case "read": "Allow reading this file?"
        default: "Allow \(request.kind)?"
        }
    }

    /// What the agent is doing now: the running tool, else the newest text it is writing.
    static func activity(of session: SessionModel, store: SessionStore) -> String {
        // Back to the newest message from the user: the current turn.
        turn: for item in session.items.reversed() {
            switch item {
            case .tool(let tool) where tool.status == .running || tool.status == .pending:
                let title = tool.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = tool.name == "bash" || tool.name == "shell" ? title : Format.relativePath(title, base: session.directory)
                return shown.isEmpty ? "Running \(tool.name)" : "Running \(shown)"
            case .agentText(_, let text, _, true):
                let excerpt = SessionAttentionText.excerpt(text, limit: 140)
                if !excerpt.isEmpty { return excerpt }
            case .user:
                break turn
            default:
                continue
            }
        }
        if session.activity != .working, store.isRunning(session.id) { return "Waiting on its subagents" }
        return "Working"
    }

    /// The newest thing the agent said, in a line.
    static func lastWords(of sessionID: String, store: SessionStore) -> String? {
        store.lastAgentText(sessionID).map { SessionAttentionText.excerpt($0, limit: 160) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The newest error, in a line.
    static func failure(of sessionID: String, store: SessionStore) -> String {
        if let error = store.lastErrorText(sessionID) { return "Failed: " + SessionAttentionText.excerpt(error, limit: 150) }
        return "The last turn failed"
    }

    /// The plan's text under its title, in a line or two.
    static func planPreview(_ plan: PlanProposal) -> String {
        let lines = plan.markdown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") }
        return SessionAttentionText.excerpt(lines.prefix(4).joined(separator: "\n"), limit: 200)
    }
}
