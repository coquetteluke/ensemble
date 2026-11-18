import SwiftUI
import AppKit
import EnsembleKit

/// The app's browsers (one per session, made when its pane first opens) and the dev servers they started. Servers
/// stop when their session is archived or deleted (`BrowserWindowSync`) and when the app quits.
@Observable @MainActor
final class BrowserCenter {
    static let shared = BrowserCenter()

    let servers: DevServers
    /// Not observed: a page is added while its pane draws, and `BrowserWindowSync` reads the list again whenever the
    /// sessions change.
    @ObservationIgnored private(set) var pages: [String: BrowserPage] = [:]
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?

    init(servers: DevServers = DevServers()) {
        self.servers = servers
        servers.onOutput = { [weak self] key, line in
            self?.pages[key.owner]?.append(level: Self.level(of: line.text), text: line.text, source: .server(key.name))
        }
        servers.onReady = { [weak self] key, url in
            guard let page = self?.pages[key.owner] else { return }
            page.note("\(key.name) answers at \(url.absoluteString)")
            page.load(url)
        }
        servers.onEnded = { [weak self] key, status in
            if case .ended(let reason) = status {
                self?.pages[key.owner]?.note("\(key.name): \(reason)", level: .error)
            }
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.servers.stopAllNow() }
        }
    }

    /// The session's browser, made on first use. A session whose folder changed (its own worktree) follows it.
    func page(for session: SessionModel) -> BrowserPage {
        if let page = pages[session.id] {
            if page.folder != session.directory { page.folder = session.directory }
            return page
        }
        let page = BrowserPage(owner: session.id, folder: session.directory)
        pages[session.id] = page
        return page
    }

    /// Snapshots: puts a prepared browser in place for a session.
    func install(_ page: BrowserPage) { pages[page.owner] = page }

    /// Sessions with a browser or a server.
    var owners: [String] { Array(Set(pages.keys).union(servers.activeOwners)).sorted() }

    /// Stops the servers of sessions that were archived or deleted, and lets their browsers go.
    func close(owners closed: [String]) {
        for owner in closed {
            pages[owner]?.cancelPicking()
            pages[owner] = nil
            Task { await servers.stopAll(owner: owner) }
        }
    }

    /// Server lines that name an error or a warning get that level, so "Console errors" can send them.
    static func level(of text: String) -> BrowserConsoleLine.Level {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") { return .error }
        if lower.contains("warn") { return .warn }
        return .log
    }
}

/// Stops dev servers whose session was archived or deleted. Attached to the main window.
struct BrowserWindowSync: ViewModifier {
    let store: SessionStore
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        content.onChange(of: closedOwners) { _, closed in
            guard store.isLoaded, !isSnapshot, !closed.isEmpty else { return }
            BrowserCenter.shared.close(owners: closed)
        }
        // The agent tools' keys and cards of sessions that were archived or deleted.
        .onChange(of: closedAgentSessions) { _, closed in
            guard store.isLoaded, !isSnapshot, !closed.isEmpty else { return }
            AgentToolsCenter.shared.close(sessions: closed)
        }
    }

    /// Sessions with agent tools state whose session is gone or archived.
    private var closedAgentSessions: [String] {
        let center = AgentToolsCenter.shared
        var ids = Set(center.server.sessionsWithKeys)
        if let coordinator = center.coordinator {
            ids.formUnion(coordinator.proposals.map(\.sessionID))
            ids.formUnion(coordinator.browserStates.keys)
        }
        guard !ids.isEmpty else { return [] }
        let sessions = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.filter { sessions[$0].map { $0.info.archived } ?? true }.sorted()
    }

    /// Browser owners whose session is gone or archived.
    private var closedOwners: [String] {
        let owners = BrowserCenter.shared.owners
        guard !owners.isEmpty else { return [] }
        let sessions = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return owners.filter { sessions[$0].map { $0.info.archived } ?? true }
    }
}
