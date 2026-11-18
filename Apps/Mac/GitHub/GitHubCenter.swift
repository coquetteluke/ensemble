import SwiftUI
import EnsembleKit

/// Owns one pull request controller per session (so the bar keeps its state when you switch sessions) and
/// ties it to the session store.
@MainActor
final class GitHubCenter {
    static let shared = GitHubCenter()

    private var controllers: [String: GitHubPullRequestController] = [:]

    func controller(for session: SessionModel, store: SessionStore) -> GitHubPullRequestController {
        let id = session.id
        if let controller = controllers[id] { return controller }
        let controller = GitHubPullRequestController(sessionID: id, hooks: Self.hooks(sessionID: id, store: store))
        controllers[id] = controller
        return controller
    }

    static func hooks(sessionID: String, store: SessionStore) -> GitHubSessionHooks {
        GitHubSessionHooks(
            directory: { [weak store] in store?.session(sessionID)?.directory ?? "" },
            sessionTitle: { [weak store] in store?.session(sessionID)?.title ?? "" },
            send: { [weak store] text in await store?.send(text, to: sessionID) },
            isAgentWorking: { [weak store] in store?.session(sessionID)?.isWorking ?? false },
            archive: { [weak store] in await store?.archive(sessionID) },
            draftDescription: { [weak store] context in
                guard let store else { throw GitHubError("The session is closed") }
                let directory = store.session(sessionID)?.directory ?? ""
                return try await store.draftPullRequest(sessionID: sessionID, directory: directory, context: context)
            })
    }
}

/// The bar for one session, as placed above the composer. Top-level sessions only (a subagent shares its
/// parent's folder and branch), and never for preview data: its sample sessions point at real folders, and
/// snapshots and `--preview` must not run gh against them.
struct PullRequestBarHost: View {
    let store: SessionStore
    let session: SessionModel

    var body: some View {
        if session.info.parentID == nil, !store.isPreview {
            PullRequestBarContainer(controller: GitHubCenter.shared.controller(for: session, store: store),
                                    isAgentWorking: session.isWorking)
                .id(session.id)
        }
    }
}

/// Keeps the controller refreshing while the bar is on screen and re-reads the folder when the agent's turn
/// ends. Takes no space while there is nothing to show.
struct PullRequestBarContainer: View {
    let controller: GitHubPullRequestController
    let isAgentWorking: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if controller.isVisible {
                PullRequestBar(controller: controller)
                    .padding(.bottom, theme.z(8))
            }
        }
        .task {
            guard !isSnapshot else { return }
            await controller.run()
        }
        .onChange(of: isAgentWorking) { _, working in
            guard !working, !isSnapshot else { return }
            Task { await controller.refresh(network: false) }
        }
    }
}
