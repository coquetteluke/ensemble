import Foundation
import Observation

// MARK: Project files

/// A folder's own agent files that each engine only loads once the folder is trusted (`WorkspaceTrust`).
public struct ProjectTrustFiles: Equatable, Sendable {
    /// Claude: settings, MCP servers, commands, skills and agents in the folder (the files
    /// `ClaudeProjectSettings.hasOwnSettings` looks for).
    public var claude: [String] = []
    /// OpenCode: `opencode.json` or `opencode.jsonc` (in any case), `.opencode/` and `AGENTS.md`, in the folder and each
    /// folder above it inside the home folder. Files above the folder start with `../`.
    public var openCode: [String] = []
    /// Gemini (agy): `.agents/`, `GEMINI.md` and `AGENTS.md` in the folder.
    public var gemini: [String] = []

    public init(claude: [String] = [], openCode: [String] = [], gemini: [String] = []) {
        self.claude = claude
        self.openCode = openCode
        self.gemini = gemini
    }

    public static let claudePaths = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json",
                                     ".claude/commands", ".claude/skills", ".claude/agents"]

    /// Instruction files: they only add text to the prompt. Everything else can change settings or run programs.
    public static func isInstructions(_ path: String) -> Bool {
        ["AGENTS.md", "GEMINI.md"].contains((path as NSString).lastPathComponent)
    }

    public var isEmpty: Bool { claude.isEmpty && openCode.isEmpty && gemini.isEmpty }

    /// Reads the folder (resolved with `realpath`). The home folder and folders above it have no project files: what
    /// is there is the user's own config.
    public static func scan(_ directory: String, homeDirectory: String = NSHomeDirectory()) -> ProjectTrustFiles {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard let root = WorkspaceTrust.resolvedPath(directory), fm.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue, let rootParts = WorkspaceTrust.components(root) else { return ProjectTrustFiles() }
        let home = WorkspaceTrust.resolvedPath(homeDirectory) ?? homeDirectory
        let homeParts = WorkspaceTrust.components(home) ?? []
        let underHome = rootParts.count > homeParts.count && Array(rootParts.prefix(homeParts.count)) == homeParts
        if !underHome, homeParts.count >= rootParts.count, Array(homeParts.prefix(rootParts.count)) == rootParts {
            return ProjectTrustFiles()
        }
        func exists(_ relative: String, in folder: String) -> Bool {
            fm.fileExists(atPath: (folder as NSString).appendingPathComponent(relative))
        }
        var files = ProjectTrustFiles()
        files.claude = claudePaths.filter { exists($0, in: root) }
        files.gemini = [".agents", "GEMINI.md", "AGENTS.md"].filter { exists($0, in: root) }
            .map { $0 == ".agents" ? ".agents/" : $0 }

        // OpenCode walks up from the folder; stop at the home folder (or below the root for folders outside it).
        let lowest = underHome ? homeParts.count + 1 : 1
        var depth = rootParts.count
        var prefix = ""
        while depth >= lowest {
            let folder = "/" + rootParts.prefix(depth).joined(separator: "/")
            let entries = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
            for entry in entries.sorted() where ["opencode.json", "opencode.jsonc"].contains(entry.lowercased()) {
                files.openCode.append(prefix + entry)
            }
            if exists(".opencode", in: folder) { files.openCode.append(prefix + ".opencode/") }
            if entries.contains("AGENTS.md") { files.openCode.append(prefix + "AGENTS.md") }
            depth -= 1
            prefix += "../"
        }
        return files
    }

    /// "a, b and c", or "a, b and 3 more" for long lists.
    public static func list(_ files: [String], limit: Int = 3) -> String {
        guard files.count > 1 else { return files.first ?? "" }
        if files.count > limit {
            return files.prefix(limit - 1).joined(separator: ", ") + " and \(files.count - limit + 1) more"
        }
        return files.dropLast().joined(separator: ", ") + " and " + (files.last ?? "")
    }
}

// MARK: State

/// A message an engine would not run because its folder is not trusted. Kept so it can be sent again after trusting.
public struct TrustRefusal: Equatable, Sendable {
    public var text: String
    public var files: [URL]
    public var folder: String
    /// The engine's own explanation.
    public var message: String

    public init(text: String, files: [URL], folder: String, message: String) {
        self.text = text
        self.files = files
        self.folder = folder
        self.message = message
    }
}

/// What the trust cards remember while the app runs (nothing is saved).
@Observable @MainActor
public final class SessionTrustNotes {
    /// Folders whose card was put away with Not now, resolved. Cleared for a folder when an engine refuses it again.
    public internal(set) var dismissed: Set<String> = []
    /// The newest refused message per session.
    public internal(set) var refusals: [String: TrustRefusal] = [:]
    /// Why trusting a folder failed (too broad, not a folder), by resolved folder.
    public internal(set) var errors: [String: String] = [:]
    @ObservationIgnored var scans: [String: (date: Date, files: ProjectTrustFiles)] = [:]

    nonisolated public init() {}
}

// MARK: Card and sheet models

/// The "Trust this folder?" card for one session: what is happening and what trusting changes.
public struct TrustPrompt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The engine runs, but without the folder's own files.
        case skipped
        /// The engine will not run in the folder (Gemini, or a Claude API-key agent whose folder redirects requests).
        case refused
        /// The folder is trusted now and the refused message can be sent again.
        case retry
        /// The folder is trusted now, but this OpenCode session stays on the server without project config.
        case keepsSkipping
        /// An older OpenCode session on the shared service loads the files although the folder is not trusted.
        case loadsUntrusted
    }

    public var kind: Kind
    /// The session's folder (the one Trust this folder trusts).
    public var folder: String
    public var engineName: String
    public var files: [String]
    public var title: String
    public var message: String

    public init(kind: Kind, folder: String, engineName: String, files: [String], title: String, message: String) {
        self.kind = kind
        self.folder = folder
        self.engineName = engineName
        self.files = files
        self.title = title
        self.message = message
    }

    /// Trust this folder is offered.
    public var offersTrust: Bool { kind == .skipped || kind == .refused || kind == .loadsUntrusted }
}

/// The new-session sheet's line about the chosen folder.
public struct NewSessionTrustLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case trusted, untrusted, blocked }
    public var text: String
    public var tone: Tone
    /// The folder has settings, hooks or MCP servers the agent would skip, or the agent does not start untrusted.
    public var offersTrust: Bool

    public init(text: String, tone: Tone, offersTrust: Bool) {
        self.text = text
        self.tone = tone
        self.offersTrust = offersTrust
    }
}

/// Which engine a session runs on, as far as trust goes.
enum TrustEngineKind: Equatable {
    case claude
    /// An agent that refuses untrusted folders (Gemini through agy).
    case refusing(String)
    /// The user's shared OpenCode service.
    case openCodeShared
    /// Ensemble's private OpenCode server for untrusted folders.
    case openCodePrivate
    case other
}

/// A session that did not start because its engine only runs in trusted folders.
public struct PendingFolderTrust: Identifiable, Equatable, Sendable {
    /// What to do again once the folder is trusted.
    public enum Retry: Equatable, Sendable {
        /// Pick the model for this session again (`changeModel`).
        case changeModel(sessionID: String, model: ModelRef)
        /// Start a new session like this one with the model (`startSession(like:model:)`).
        case startLike(sessionID: String, model: ModelRef)
    }

    public var id: String { folder }
    /// The folder, resolved.
    public var folder: String
    public var modelName: String
    /// True for the home folder: only the folder itself is trusted, not the folders inside it.
    public var onlyThisFolder: Bool
    public var retry: Retry

    public init(folder: String, modelName: String, onlyThisFolder: Bool, retry: Retry) {
        self.folder = folder
        self.modelName = modelName
        self.onlyThisFolder = onlyThisFolder
        self.retry = retry
    }
}

// MARK: Store

extension SessionStore {
    /// The folder an engine refused to start in because it is not trusted, or nil for any other error.
    nonisolated public static func untrustedFolder(in error: any Error) -> String? {
        if let acp = error as? ACPEngineError, case .folderNotTrusted(let folder) = acp { return folder }
        if let claude = error as? ClaudeCodeError, case .folderNotTrusted(let folder) = claude { return folder }
        return nil
    }

    /// Records a start that failed because the folder is not trusted, so the app can ask. Returns false for any other
    /// error, which the caller reports as usual.
    func askToTrust(after error: any Error, model: ModelRef, retry: PendingFolderTrust.Retry) -> Bool {
        guard let folder = Self.untrustedFolder(in: error) else { return false }
        let resolved = WorkspaceTrust.resolvedPath(folder) ?? folder
        pendingFolderTrust = PendingFolderTrust(folder: resolved, modelName: modelName(model),
                                                onlyThisFolder: resolved == workspaceTrust.homeFolder, retry: retry)
        return true
    }

    /// The trust list behind the router (the app-wide one otherwise).
    public var workspaceTrust: WorkspaceTrust { (engine as? EngineRouter)?.trust ?? .shared }

    /// The trust card for a session, or nil when there is nothing to say. Subagents never get one; their parent does.
    public func trustPrompt(for session: SessionModel) -> TrustPrompt? {
        guard !isPreview, session.info.parentID == nil else { return nil }
        let folder = session.directory
        let key = WorkspaceTrust.resolvedPath(folder) ?? folder
        let trusted = workspaceTrust.isTrusted(folder)
        let refusal = trustNotes.refusals[session.id]
        if refusal == nil, trustNotes.dismissed.contains(key) { return nil }
        let kind = trustEngineKind(sessionID: session.id, model: session.info.model, directory: folder)
        let files = projectFiles(folder)

        switch kind {
        case .refusing(let name):
            if trusted { return refusal.map { retryPrompt($0, name: name, folder: folder) } }
            var message = "\(name) loads a folder's own hooks, rules and plugins and cannot be told to skip them, "
                + "so Ensemble does not start it in a folder you have not trusted."
            if !files.gemini.isEmpty { message += " This folder has \(ProjectTrustFiles.list(files.gemini))." }
            return TrustPrompt(kind: .refused, folder: folder, engineName: name, files: files.gemini,
                               title: "\(name) only runs in folders you trust", message: message)
        case .claude:
            if trusted { return refusal.map { retryPrompt($0, name: "Claude", folder: folder) } }
            if let refusal {
                return TrustPrompt(kind: .refused, folder: folder, engineName: "Claude", files: files.claude,
                                   title: "Claude needs this folder trusted", message: refusal.message)
            }
            guard claudeIgnoresProjectSettings(folder, files: files) else { return nil }
            return TrustPrompt(kind: .skipped, folder: folder, engineName: "Claude", files: files.claude,
                               title: "Claude is running without this folder's settings",
                               message: "You have not trusted this folder, so Claude uses your own settings only and skips "
                                   + "\(ProjectTrustFiles.list(files.claude)). Trust it to load \(Self.them(files.claude)) "
                                   + "from your next message.")
        case .openCodePrivate:
            if let provider = session.info.model?.providerID, providersNeedingTrustedFolders.contains(provider) {
                return signInPrompt(folder: folder, trusted: trusted)
            }
            guard !files.openCode.isEmpty else { return nil }
            let list = ProjectTrustFiles.list(files.openCode)
            if trusted {
                return TrustPrompt(kind: .keepsSkipping, folder: folder, engineName: "OpenCode", files: files.openCode,
                                   title: "This session still runs without the folder's config",
                                   message: "It started before you trusted this folder, so it keeps skipping \(list). "
                                       + "New sessions here load \(Self.them(files.openCode)).")
            }
            return TrustPrompt(kind: .skipped, folder: folder, engineName: "OpenCode", files: files.openCode,
                               title: "OpenCode is running without this folder's config",
                               message: "You have not trusted this folder, so this session skips \(list). Trusting it "
                                   + "loads \(Self.them(files.openCode)) in new sessions here. This session keeps running without "
                                   + "\(Self.them(files.openCode)).")
        case .openCodeShared:
            guard !trusted, (engine as? EngineRouter)?.untrustedFolderRegistration != nil, !files.openCode.isEmpty else { return nil }
            return TrustPrompt(kind: .loadsUntrusted, folder: folder, engineName: "OpenCode", files: files.openCode,
                               title: "This session loads the folder's config",
                               message: "It started on the shared OpenCode service, which loads "
                                   + "\(ProjectTrustFiles.list(files.openCode)) although you have not trusted this folder. "
                                   + "Trust the folder, or start a new session here to run without \(Self.them(files.openCode)).")
        case .other:
            return nil
        }
    }

    /// "it" for one file, "them" for several.
    static func them(_ files: [String]) -> String { files.count == 1 ? "it" : "them" }

    /// The sentence for a model whose provider is signed in with a browser sign-in the private server does not have.
    nonisolated public static let signInNeedsTrustText = "This provider's sign-in works only in trusted folders. Trust this folder to use it."

    /// Providers whose browser sign-in only the shared OpenCode service has (empty without a router).
    var providersNeedingTrustedFolders: Set<String> { (engine as? EngineRouter)?.providersNeedingTrustedFolders ?? [] }

    /// An OpenCode session on the private server whose model's provider needs a sign-in it does not have. Trusting
    /// helps new sessions only; this one stays on the private server.
    private func signInPrompt(folder: String, trusted: Bool) -> TrustPrompt {
        if trusted {
            return TrustPrompt(kind: .keepsSkipping, folder: folder, engineName: "OpenCode", files: [],
                               title: "This session cannot use its model's sign-in",
                               message: "It started before you trusted this folder, and this provider's sign-in works only "
                                   + "in trusted folders. Start a new session here to use it.")
        }
        return TrustPrompt(kind: .refused, folder: folder, engineName: "OpenCode", files: [],
                           title: "This session cannot use its model's sign-in",
                           message: "This provider's sign-in works only in trusted folders. Trust this folder, then start a "
                               + "new session here to use it.")
    }

    private func retryPrompt(_ refusal: TrustRefusal, name: String, folder: String) -> TrustPrompt {
        TrustPrompt(kind: .retry, folder: folder, engineName: name, files: [], title: "Folder trusted",
                    message: "\(name) can start here now. Send the message it refused again.")
    }

    /// Trusts the session's folder. A folder that cannot be trusted (the home folder, a folder above it) leaves its
    /// reason in `trustNotes.errors`. Returns true when the folder is trusted.
    @discardableResult
    public func trustFolder(of session: SessionModel) -> Bool {
        trustFolder(session.directory)
    }

    /// Trusts a folder (the new-session sheet uses it before a session exists). The home folder is trusted on its own,
    /// not the folders inside it.
    @discardableResult
    public func trustFolder(_ folder: String) -> Bool {
        let key = WorkspaceTrust.resolvedPath(folder) ?? folder
        do {
            try workspaceTrust.trust(folder, includingSubfolders: key != workspaceTrust.homeFolder)
            trustNotes.errors[key] = nil
            return true
        } catch {
            trustNotes.errors[key] = error.localizedDescription
            return false
        }
    }

    /// Why trusting the folder failed last time, if it did.
    public func trustError(for folder: String) -> String? {
        trustNotes.errors[WorkspaceTrust.resolvedPath(folder) ?? folder]
    }

    /// Not now: hides the card for the session's folder until the app quits or an engine refuses the folder again.
    public func dismissTrustPrompt(for session: SessionModel) {
        let key = WorkspaceTrust.resolvedPath(session.directory) ?? session.directory
        trustNotes.dismissed.insert(key)
        trustNotes.refusals[session.id] = nil
        trustNotes.errors[key] = nil
    }

    /// Sends the message the engine refused again (after the folder was trusted).
    public func sendRefusedMessageAgain(for session: SessionModel) async {
        guard let refusal = trustNotes.refusals.removeValue(forKey: session.id) else { return }
        await send(refusal.text, files: refusal.files, to: session.id)
    }

    /// Called when a message could not be sent: remembers it when the engine refused an untrusted folder.
    func noteSendFailure(_ error: any Error, text: String, files: [URL], sessionID: String) {
        guard let session = byID[sessionID], Self.isTrustRefusal(error) else { return }
        let key = WorkspaceTrust.resolvedPath(session.directory) ?? session.directory
        trustNotes.refusals[sessionID] = TrustRefusal(text: text, files: files, folder: session.directory,
                                                      message: error.localizedDescription)
        trustNotes.dismissed.remove(key)
    }

    /// True for the engines' "this folder is not trusted" errors.
    static func isTrustRefusal(_ error: any Error) -> Bool {
        if case .folderNotTrusted? = error as? ACPEngineError { return true }
        if case .folderNotTrusted? = error as? ClaudeCodeError { return true }
        return false
    }

    /// The new-session sheet's line for the chosen folder and model.
    public func newSessionTrustLine(directory: String, model: ModelRef?) -> NewSessionTrustLine? {
        guard !directory.isEmpty else { return nil }
        if workspaceTrust.isTrusted(directory) {
            return NewSessionTrustLine(text: "Trusted. Agents load this folder's own settings.", tone: .trusted, offersTrust: false)
        }
        let files = projectFiles(directory)
        let kind = trustEngineKind(sessionID: nil, model: model ?? defaultModel, directory: directory)
        if case .refusing(let name) = kind {
            return NewSessionTrustLine(text: "Not trusted. \(name) only starts in folders you trust.", tone: .blocked, offersTrust: true)
        }
        if kind == .openCodePrivate, let provider = (model ?? defaultModel)?.providerID,
           providersNeedingTrustedFolders.contains(provider) {
            return NewSessionTrustLine(text: Self.signInNeedsTrustText, tone: .blocked, offersTrust: true)
        }
        let skipped: [String]
        switch kind {
        case .claude: skipped = files.claude
        case .openCodePrivate, .openCodeShared: skipped = files.openCode
        default: skipped = Array(Set(files.claude + files.openCode + files.gemini)).sorted()
        }
        guard !skipped.isEmpty else {
            return NewSessionTrustLine(text: "Not trusted. This folder has no agent settings of its own.", tone: .untrusted,
                                       offersTrust: false)
        }
        let settings = skipped.contains { !ProjectTrustFiles.isInstructions($0) }
        return NewSessionTrustLine(text: "Not trusted. The agent skips \(ProjectTrustFiles.list(skipped)).", tone: .untrusted,
                                   offersTrust: settings)
    }

    // MARK: Internals

    /// The folder's project files, read at most every few seconds per folder (card bodies run often).
    func projectFiles(_ folder: String) -> ProjectTrustFiles {
        let key = WorkspaceTrust.resolvedPath(folder) ?? folder
        if let cached = trustNotes.scans[key], Date().timeIntervalSince(cached.date) < 5 { return cached.files }
        let files = ProjectTrustFiles.scan(folder)
        trustNotes.scans[key] = (Date(), files)
        return files
    }

    func claudeIgnoresProjectSettings(_ folder: String, files: ProjectTrustFiles) -> Bool {
        #if os(macOS)
        if let claude = (engine as? EngineRouter)?.engine(ClaudeCodeEngine.self) {
            // The engine's own check, limited to folders that can have project settings at all (not the home folder).
            return !files.claude.isEmpty && claude.ignoresProjectSettings(directory: folder)
        }
        #endif
        return !files.claude.isEmpty
    }

    /// The engine that runs (or would run) a session: its known owner, else the engine a new session would go to.
    func trustEngineKind(sessionID: String?, model: ModelRef?, directory: String) -> TrustEngineKind {
        guard let router = engine as? EngineRouter else {
            switch model?.providerID {
            case ClaudeModels.subscriptionProviderID?, ClaudeModels.apiKeyProviderID?: return .claude
            case ACPAgentRegistry.antigravity.id?: return .refusing("Gemini")
            default: return .openCodePrivate
            }
        }
        let registration: EngineRouter.Registration
        if let sessionID, let ownerID = router.ownerID(ofSession: sessionID), let owner = router.registration(id: ownerID) {
            registration = owner
        } else if sessionID == nil {
            registration = router.registration(forNewSessionIn: directory, model: model)
        } else if let model {
            registration = router.registration(forProvider: model.providerID)
        } else {
            return .other
        }
        if registration.engine is ClaudeCodeEngine { return .claude }
        if let acp = registration.engine as? ACPEngine {
            guard acp.agent.requiresTrustedFolder else { return .other }
            return .refusing(acp.agent.id == ACPAgentRegistry.antigravity.id ? "Gemini" : acp.agent.displayName)
        }
        if registration.id == router.untrustedFolderRegistration?.id { return .openCodePrivate }
        if registration.isFallback { return .openCodeShared }
        return .other
    }
}
