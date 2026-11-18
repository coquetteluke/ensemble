import SwiftUI
import EnsembleKit

/// Owns the review models (one per session or room, so comments survive closing the pane) and starts the
/// turn snapshots that "Whole session" and "Last turn" compare against.
@MainActor
final class ReviewCenter {
    static let shared = ReviewCenter()

    let snapshots: GitTurnSnapshots
    private var models: [String: ReviewModel] = [:]

    init(snapshots: GitTurnSnapshots = .shared) {
        self.snapshots = snapshots
    }

    // MARK: Models

    /// The review of one session.
    func model(for session: SessionModel, store: SessionStore) -> ReviewModel {
        let id = session.id
        if let model = models[id] { return model }
        let model = ReviewModel(target: Self.target(for: session), environment: Self.environment(sessionID: id, store: store),
                                snapshots: snapshots)
        models[id] = model
        return model
    }

    /// The review of a room: the shared folder plus each agent's worktree.
    func model(for room: RoomEngine, store: SessionStore) -> ReviewModel {
        let id = "room:\(room.state.id.uuidString)"
        if let model = models[id] { return model }
        let model = ReviewModel(target: Self.target(for: room), environment: Self.environment(room: room, store: store),
                                snapshots: snapshots)
        models[id] = model
        return model
    }

    static func target(for session: SessionModel) -> ReviewTarget {
        .session(id: session.id, title: session.title, directory: session.directory, created: session.info.created)
    }

    static func target(for room: RoomEngine) -> ReviewTarget {
        let state = room.state
        let agents = state.spec.agents.map { agent in
            let assignment = state.assignments.first { $0.agentID == agent.id }
            return ReviewAgentSource(id: agent.id, name: agent.name, colorHex: agent.colorHex, sessionID: state.sessions[agent.id],
                                     worktree: assignment?.worktreePath, baseBranch: state.git?.baseBranch)
        }
        return ReviewTarget(id: "room:\(state.id.uuidString)", title: state.spec.title, directory: state.spec.directory,
                            created: state.spec.created, sessionIDs: agents.compactMap(\.sessionID), agents: agents)
    }

    static func environment(sessionID: String, store: SessionStore) -> ReviewEnvironment {
        ReviewEnvironment(
            currentTarget: { [weak store] in
                guard let session = store?.session(sessionID) else {
                    return .session(id: sessionID, title: "", directory: "", created: Date())
                }
                return target(for: session)
            },
            engineData: { [weak store] _ in
                guard let store else { return ReviewEngineData() }
                await store.refreshPanels(sessionID)
                let session = store.session(sessionID)
                return ReviewEngineData(changes: [sessionID: session?.changedFiles ?? []], transcripts: [sessionID: session?.items ?? []])
            },
            send: { [weak store] text, _ in await store?.send(text, to: sessionID) },
            draftMessage: { [weak store] files, _ in
                guard let store else { throw CommitMessageError("The session is closed") }
                let directory = store.session(sessionID)?.directory ?? ""
                return try await store.draftCommitMessage(sessionID: sessionID, directory: directory, files: files)
            },
            isAgentWorking: { [weak store] _ in store?.session(sessionID)?.isWorking ?? false }
        )
    }

    static func environment(room: RoomEngine, store: SessionStore) -> ReviewEnvironment {
        /// Comments without an agent, and the commit message, go to the lead (or the first agent).
        func agentFor(_ id: UUID?) -> UUID? { id ?? room.leadID ?? room.agents.first?.id }
        return ReviewEnvironment(
            currentTarget: { [weak room] in
                guard let room else { return ReviewTarget(id: "", title: "", directory: "", created: Date(), sessionIDs: []) }
                return target(for: room)
            },
            engineData: { [weak store] target in
                guard let store else { return ReviewEngineData() }
                var data = ReviewEngineData()
                for sessionID in target.sessionIDs {
                    data.changes[sessionID] = (try? await store.engine.changedFiles(sessionID)) ?? []
                    if let session = store.session(sessionID), session.transcriptLoaded {
                        data.transcripts[sessionID] = session.items
                    } else {
                        data.transcripts[sessionID] = (try? await store.engine.transcript(sessionID)) ?? []
                    }
                }
                return data
            },
            send: { [weak room] text, agentID in
                guard let room else { return }
                let targets = agentFor(agentID).map { [$0] } ?? room.agents.map(\.id)
                await room.send(text, to: targets)
            },
            draftMessage: { [weak room, weak store] files, agentID in
                guard let room, let store else { throw CommitMessageError("The room is closed") }
                let sessionID = agentFor(agentID).flatMap { room.sessionID(for: $0) }
                return try await store.draftCommitMessage(sessionID: sessionID, directory: room.state.spec.directory, files: files)
            },
            isAgentWorking: { [weak room] agentID in
                guard let room, let id = agentFor(agentID) else { return false }
                return room.activity[id] == .working || room.activity[id] == .waitingForPermission
            }
        )
    }

    // MARK: Turn snapshots

    /// Snapshots a session's folder each time one of its turns starts (see `GitTurnSnapshots.follow`).
    /// Call once when the store is ready.
    func follow(_ store: SessionStore) {
        snapshots.follow(store)
    }
}
