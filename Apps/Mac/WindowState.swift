import SwiftUI
import EnsembleKit

/// What the centre of the window shows.
enum Route: Hashable {
    case session
    case hub
    case scheduled
}

/// Window-level UI state that is not engine data: panels, drafts, sheets, search.
@Observable @MainActor
final class WindowState {
    var route: Route = .session
    var showSidebar = true
    var showContextPanel: Bool = UserDefaults.standard.object(forKey: "showContextPanel") as? Bool ?? true
    var showNewSession = false
    /// Folder to preselect in the new session sheet.
    var newSessionDirectory: String?
    var drafts: [String: String] = [:]
    var attachments: [String: [URL]] = [:]
    var searchText = ""
    var collapsedProjects: Set<String> = []
    /// Bumped to move keyboard focus into the composer.
    var composerFocusToken = 0

    func toggleContextPanel() {
        withAnimation(.easeOut(duration: 0.18)) { showContextPanel.toggle() }
        UserDefaults.standard.set(showContextPanel, forKey: "showContextPanel")
    }

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) { showSidebar.toggle() }
    }

    func beginNewSession(in directory: String? = nil) {
        newSessionDirectory = directory
        showNewSession = true
    }

    func open(_ sessionID: String, store: SessionStore) {
        route = .session
        store.select(sessionID)
        composerFocusToken &+= 1
    }

    /// Opens the Nth session in sidebar order (Cmd-1 to Cmd-9).
    func openSession(number: Int, store: SessionStore) {
        let order = store.sidebarOrder
        guard number >= 1, number <= order.count else { return }
        open(order[number - 1].id, store: store)
    }

    func draft(for sessionID: String) -> String { drafts[sessionID] ?? "" }

    /// Sends the selected session's draft and attachments.
    func sendDraft(store: SessionStore) {
        guard route == .session, let session = store.selected else { return }
        let text = draft(for: session.id).trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments[session.id] ?? []
        guard !text.isEmpty || !files.isEmpty else { return }
        drafts[session.id] = ""
        attachments[session.id] = []
        Task { await store.send(text, files: files, to: session.id) }
    }
}

/// App appearance setting. Dark is the default.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match system"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}
