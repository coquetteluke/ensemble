import SwiftUI
import AppKit
import EnsembleKit

/// Ensemble's tools for agents in the Mac app: the MCP server every engine attaches (`AgentToolsServer.shared`, through
/// the `ensemble-agent-tools` helper in Contents/MacOS) and the coordinator that answers it with proposal cards, browser
/// permission cards and the browser pane.
///
/// Wiring (see the report for exact lines): `AgentToolsCenter.shared.start(store:)` once the store exists,
/// `onShowBrowser` from the window, `close(sessions:)` when sessions are archived or deleted.
@Observable @MainActor
final class AgentToolsCenter {
    static let shared = AgentToolsCenter()

    let server: AgentToolsServer
    /// Answers tool calls; nil until `start(store:)` (or a snapshot seeds one).
    private(set) var coordinator: AgentToolsCoordinator?
    /// Why the server is not running, if it is not.
    private(set) var problem: String?
    /// Shows a session's browser pane. Set by the main window; without it the card still shows in the conversation.
    @ObservationIgnored var onShowBrowser: ((String) -> Void)?
    @ObservationIgnored private weak var store: SessionStore?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?

    init(server: AgentToolsServer = .shared) {
        self.server = server
    }

    /// Starts the server and the coordinator for the app's sessions. Does nothing in snapshots or a second time.
    func start(store: SessionStore) {
        guard coordinator == nil else { return }
        self.store = store
        let coordinator = AgentToolsCoordinator(environment: Self.environment(store: store, center: self))
        self.coordinator = coordinator
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: AgentToolsBridge.executableName) else {
            problem = "The \(AgentToolsBridge.executableName) helper is missing from the app."
            return
        }
        do {
            try server.start(host: coordinator, executable: helper.path)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.stop() }
        }
    }

    /// Snapshots: a coordinator with sample cards and no server.
    func installForSnapshot(_ coordinator: AgentToolsCoordinator) {
        self.coordinator = coordinator
    }

    /// Sessions that were archived or deleted: their keys stop working and their cards go.
    func close(sessions: [String]) {
        for id in sessions {
            coordinator?.forget(id)
            server.revoke(.session(id))
        }
    }

    /// Opens the session in the window (a started proposal's Open button).
    func open(_ sessionID: String) {
        store?.select(sessionID)
    }

    // MARK: The app's side

    static func environment(store: SessionStore, center: AgentToolsCenter) -> AgentToolsEnvironment {
        AgentToolsEnvironment(
            session: { [weak store] id in
                guard let store, let model = store.session(id) else { return nil }
                return info(model, store: store)
            },
            browser: { [weak store] id in
                guard let session = store?.session(id) else { return nil }
                return BrowserCenter.shared.page(for: session)
            },
            isTrusted: { WorkspaceTrust.shared.isTrusted($0) },
            knownFolders: { [weak store] in Array(Set(store?.sessions.map(\.directory) ?? [])) },
            resolveModel: { [weak store] asked, session in
                guard let store else { return (session.model, "Default model", false) }
                return resolveModel(asked, session: session, store: store)
            },
            showBrowser: { [weak center] id in center?.onShowBrowser?(id) },
            log: { [weak store] id, text in store?.addNotice(text, to: id) },
            startSession: { [weak store] proposal, session in
                guard let store else { throw AgentToolsCenterError.noStore }
                // The user stays where they are; the card's Open button goes to the new session. The folder (resolved,
                // checked again by the coordinator just now) and the mode (Ask, never the proposer's) come from the card.
                let previous = store.selectedSessionID
                let created = try await store.newSession(directory: proposal.folder, model: proposal.model ?? session.model,
                                                         permissionMode: proposal.permissionMode)
                if let previous { store.select(previous) }
                await store.send(proposal.brief, to: created.id)
                return created.id
            },
            send: { [weak store] id, text in await store?.send(text, to: id) },
            // Ensemble has no per-folder default mode yet, so proposed sessions start in Ask (`ProposalMode`).
            folderMode: { _ in nil }
        )
    }

    /// The coordinator's view of a session. A subagent's root is its top-level parent; the turn is the number of user
    /// messages, so a new message from the user starts a new turn.
    static func info(_ model: SessionModel, store: SessionStore) -> AgentToolsEnvironment.Session {
        var root = model
        var hops = 0
        while let parentID = root.info.parentID, let parent = store.session(parentID), hops < 16 {
            root = parent
            hops += 1
        }
        let turns = model.items.reduce(0) { count, item in
            if case .user = item { return count + 1 }
            return count
        }
        return AgentToolsEnvironment.Session(id: model.id, rootID: root.id, directory: model.directory, model: model.info.model,
                                             permissionMode: model.permissionMode, archived: model.info.archived, turn: String(turns))
    }

    /// The agent's suggestion matched against the app's models (id, `provider/id` or name, ignoring case), else the
    /// session's own model.
    static func resolveModel(_ asked: String?, session: AgentToolsEnvironment.Session, store: SessionStore)
        -> (model: ModelRef?, name: String, matched: Bool) {
        if let asked = asked?.trimmingCharacters(in: .whitespaces).lowercased(), !asked.isEmpty {
            let available = store.models.filter(\.available)
            let match = available.first { $0.ref.id.lowercased() == asked || $0.ref.description.lowercased() == asked }
                ?? available.first { $0.name.lowercased() == asked }
                ?? available.first { $0.name.lowercased().contains(asked) }
            if let match { return (match.ref, match.name, true) }
        }
        return (session.model, store.modelName(session.model), asked == nil)
    }
}

enum AgentToolsCenterError: Error, LocalizedError {
    case noStore

    var errorDescription: String? { "The app is not ready." }
}

/// Opens the browser pane when an agent in the session on screen uses the browser (its permission card shows there
/// and above the composer). Attached to the main window.
struct AgentToolsWindowSync: ViewModifier {
    let store: SessionStore
    let window: WindowState
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        content.onAppear {
            guard !isSnapshot else { return }
            AgentToolsCenter.shared.onShowBrowser = { [weak store, weak window] sessionID in
                guard let store, let window, store.selectedSessionID == sessionID, window.route != .room, !window.browserOpen else { return }
                window.openSidePane(.browser)
            }
        }
    }
}
