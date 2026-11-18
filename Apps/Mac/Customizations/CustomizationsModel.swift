import AppKit
import SwiftUI
import EnsembleKit

/// The folder another screen asked the Customizations tab to show (the selected session's, from the toolbar button).
@Observable @MainActor
final class CustomizationsFocus {
    static let shared = CustomizationsFocus()
    /// Set before opening Settings on the Customizations tab; the tab takes it and clears it.
    var requestedFolder: String?
    /// The value Settings keeps its selected tab in (`@AppStorage(CustomizationsFocus.tabKey)`).
    static let tabKey = "settingsTab"
    static let tabValue = "customizations"

    /// Shows `folder` on the Customizations tab the next time Settings opens (or now, if it is open).
    func show(folder: String?) {
        requestedFolder = folder
        UserDefaults.standard.set(Self.tabValue, forKey: Self.tabKey)
    }
}

/// State behind the Customizations screen: the chosen folder, the discovery report (merged with OpenCode's own
/// answers when its server for the folder is running), and the Trust, Authenticate and Restart actions.
@Observable @MainActor
final class CustomizationsModel {
    enum Section: String, CaseIterable, Identifiable {
        case rules, skills, mcp, hooks, trust
        var id: String { rawValue }

        var label: String {
            switch self {
            case .rules: "Rules and memory"
            case .skills: "Skills"
            case .mcp: "MCP servers"
            case .hooks: "Hooks"
            case .trust: "Trust"
            }
        }
    }

    /// A browser sign-in waiting to finish, per MCP server id.
    struct SignIn: Equatable {
        var url: String
        var instructions: String
    }

    var folder: String?
    var section: Section = .rules
    private(set) var report: CustomizationsReport?
    private(set) var loading = false
    /// Why OpenCode's own lists could not be read, if they could not.
    private(set) var liveNote: String?
    private(set) var trustError: String?
    private(set) var actionErrors: [String: String] = [:]
    private(set) var busy: Set<String> = []
    private(set) var signIns: [String: SignIn] = [:]

    let store: SessionStore?
    let trust: WorkspaceTrust
    let environment: CustomizationsEnvironment
    /// The home folder paths are shown against (`~`, `../`).
    let home: String
    /// Snapshots show a fixed report and never read files.
    let isFixed: Bool
    private var generation = 0

    init(store: SessionStore?, folder: String? = nil) {
        self.store = store
        trust = store?.workspaceTrust ?? .shared
        let environment = CustomizationsEnvironment()
        self.environment = environment
        home = environment.homeDirectory
        isFixed = false
        self.folder = folder
    }

    /// A model that shows `report` as is (snapshots and previews).
    init(fixed report: CustomizationsReport, section: Section, home: String) {
        store = nil
        trust = .shared
        environment = CustomizationsEnvironment(homeDirectory: home, environment: [:])
        self.home = home
        isFixed = true
        folder = report.folder
        self.report = report
        self.section = section
    }

    /// Folders the user works in, newest project first, for the folder menu.
    var recentFolders: [String] {
        var seen = Set<String>()
        return (store?.projects.map(\.directory) ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var isTrusted: Bool {
        guard let folder else { return false }
        return isFixed ? (report?.trusted ?? false) : trust.isTrusted(folder)
    }

    /// The default folder: one another screen asked for, else the selected session's, else the first project's.
    func pickDefaultFolder() {
        if let requested = CustomizationsFocus.shared.requestedFolder {
            folder = requested
            CustomizationsFocus.shared.requestedFolder = nil
        } else if folder == nil {
            folder = store?.selected?.directory ?? recentFolders.first
        }
    }

    // MARK: Loading

    /// Reads the folder again (off the main thread), then asks OpenCode's server for the folder about MCP status,
    /// skills and plugins.
    func load() async {
        guard !isFixed, let folder else { return }
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        let trusted = trust.isTrusted(folder)
        let environment = environment
        let found = await Task.detached(priority: .userInitiated) {
            CustomizationsDiscovery.discover(folder: folder, trusted: trusted, environment: environment)
        }.value
        guard mine == generation else { return }
        report = found
        liveNote = nil
        guard let router = store?.engine as? EngineRouter else { return }
        guard let source = CustomizationsLive.source(for: folder, router: router) else {
            liveNote = trusted ? "OpenCode is not running, so MCP status is not shown."
                : "Ensemble's private OpenCode server is not running, so MCP status is not shown."
            return
        }
        do {
            let live = try await source.engine.customizationsLive(directory: found.folder)
            guard mine == generation else { return }
            report = CustomizationsLive.merge(found, live: live, serverName: source.serverName, environment: environment)
        } catch {
            guard mine == generation else { return }
            liveNote = "Could not read MCP status from OpenCode: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    func trustFolder() {
        guard let folder else { return }
        do {
            try trust.trust(folder)
            trustError = nil
        } catch {
            trustError = error.localizedDescription
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Show"
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
    }

    /// Disconnects and connects an OpenCode MCP server, then reads the folder again.
    func restart(_ server: CustomizationMCPServer) async {
        guard let folder = report?.folder, let router = store?.engine as? EngineRouter,
              let source = CustomizationsLive.source(for: folder, router: router) else { return }
        busy.insert(server.id)
        defer { busy.remove(server.id) }
        do {
            try await source.engine.restartMCPServer(server.name, directory: folder)
            actionErrors[server.id] = nil
        } catch {
            actionErrors[server.id] = error.localizedDescription
        }
        await load()
    }

    /// Starts the server's browser sign-in through OpenCode, opens the page, waits for it to finish (up to ten
    /// minutes), then reconnects the server.
    func authenticate(_ server: CustomizationMCPServer) async {
        guard let folder = report?.folder, let integrationID = server.integrationID, let router = store?.engine as? EngineRouter,
              let source = CustomizationsLive.source(for: folder, router: router) else { return }
        busy.insert(server.id)
        defer {
            busy.remove(server.id)
            signIns[server.id] = nil
        }
        do {
            let attempt = try await source.engine.startMCPSignIn(integrationID: integrationID, directory: folder)
            signIns[server.id] = SignIn(url: attempt.urlString, instructions: attempt.instructions)
            if let url = URL(string: attempt.urlString), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            let deadline = min(attempt.expires ?? .distantFuture, Date().addingTimeInterval(600))
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                switch try await source.engine.mcpSignInStatus(integrationID: integrationID, attemptID: attempt.attemptID,
                                                               directory: folder) {
                case .pending:
                    continue
                case .complete:
                    actionErrors[server.id] = nil
                    try? await source.engine.restartMCPServer(server.name, directory: folder)
                    await load()
                    return
                case .failed(let message):
                    actionErrors[server.id] = message
                    return
                case .expired:
                    actionErrors[server.id] = "The sign-in expired. Try again."
                    return
                }
            }
            actionErrors[server.id] = "The sign-in did not finish in time. Try again."
        } catch is CancellationError {
            return
        } catch {
            actionErrors[server.id] = error.localizedDescription
        }
    }
}
