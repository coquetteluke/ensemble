#if os(macOS)
import Foundation

/// Where an import of Claude sessions reads from. Every file is only read: the import never writes, moves or copies
/// the claude CLI's files or the Claude desktop app's files.
public struct ClaudeImportSources: Sendable, Equatable {
    /// The claude CLI's transcripts: `~/.claude/projects/<folder>/<session id>.jsonl` (or `$CLAUDE_CONFIG_DIR/projects`).
    public var projectsDirectory: URL
    /// The CLI's own settings file (`~/.claude.json`). Only `projects.<folder>.hasTrustDialogAccepted` is used.
    public var cliConfigFile: URL?
    /// The Claude desktop app's data folder (`~/Library/Application Support/Claude`). Only these are opened: the
    /// session list (`claude-code-sessions/*/*/local_*.json` and `archived-sessions.idx`), the names of its
    /// `deleted_*` markers, `ccd-session-presets.json` (environments) and `ssh_configs.json` (SSH hosts, its
    /// `configs` list). Cookies, Local Storage, IndexedDB and token files are never opened.
    public var desktopDirectory: URL?

    public init(projectsDirectory: URL, cliConfigFile: URL?, desktopDirectory: URL?) {
        self.projectsDirectory = projectsDirectory
        self.cliConfigFile = cliConfigFile
        self.desktopDirectory = desktopDirectory
    }

    /// The usual places for this user, following `CLAUDE_CONFIG_DIR` like the CLI does.
    public static func standard(projectsDirectory: URL? = nil,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeImportSources {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let configFile: URL
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            configFile = URL(fileURLWithPath: (config as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        } else {
            configFile = home.appendingPathComponent(".claude.json")
        }
        return ClaudeImportSources(
            projectsDirectory: projectsDirectory ?? ClaudeTranscriptFiles.defaultProjectsDirectory(environment: environment),
            cliConfigFile: configFile,
            desktopDirectory: home.appendingPathComponent("Library/Application Support/Claude"))
    }
}

/// One Claude session found in the claude CLI's transcripts.
public struct ClaudeImportSession: Identifiable, Hashable, Sendable {
    public enum TitleSource: String, Hashable, Sendable {
        /// The title the Claude desktop app shows.
        case desktopApp
        /// A `/rename` title the CLI wrote into the transcript.
        case renamed
        /// The summary line older CLI versions wrote.
        case summary
        /// The first thing the user typed.
        case firstPrompt
        /// The last thing the user typed (when the first prompt could not be read).
        case lastPrompt
    }

    /// The CLI's session id. The imported Ensemble session keeps it, so it resumes with `claude --resume <id>`.
    public var id: String
    /// The folder the session ran in, from the `cwd` the CLI recorded in the transcript.
    public var directory: String
    public var title: String
    public var titleSource: TitleSource
    public var created: Date
    public var updated: Date
    public var archived: Bool
    /// Starred (pinned) in the desktop app. Ensemble has no pins, so this is reported only.
    public var starred: Bool
    /// The model the session last used, as a Claude alias (`claude-code/opus#high`), or nil for the CLI's default.
    public var model: ModelRef?
    public var transcriptPath: String
    /// Ensemble already has this session (imported before, or started in Ensemble).
    public var alreadyImported: Bool
    /// The transcript changed a few minutes ago, so the session may still be open in another app.
    public var recentlyWritten: Bool

    public init(id: String, directory: String, title: String, titleSource: TitleSource, created: Date, updated: Date,
                archived: Bool = false, starred: Bool = false, model: ModelRef? = nil, transcriptPath: String,
                alreadyImported: Bool = false, recentlyWritten: Bool = false) {
        self.id = id
        self.directory = directory
        self.title = title
        self.titleSource = titleSource
        self.created = created
        self.updated = updated
        self.archived = archived
        self.starred = starred
        self.model = model
        self.transcriptPath = transcriptPath
        self.alreadyImported = alreadyImported
        self.recentlyWritten = recentlyWritten
    }
}

/// The sessions of one folder.
public struct ClaudeImportFolder: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    /// False when the folder no longer exists: its sessions can be read but not resumed.
    public var exists: Bool
    /// Trusted in the claude CLI (`hasTrustDialogAccepted` for this folder or a folder above it).
    public var trustedInCLI: Bool
    /// Already trusted in Ensemble (`WorkspaceTrust`).
    public var trustedInEnsemble: Bool
    /// Newest first.
    public var sessions: [ClaudeImportSession]

    public init(path: String, exists: Bool, trustedInCLI: Bool = false, trustedInEnsemble: Bool = false,
                sessions: [ClaudeImportSession]) {
        self.path = path
        self.exists = exists
        self.trustedInCLI = trustedInCLI
        self.trustedInEnsemble = trustedInEnsemble
        self.sessions = sessions.sorted { $0.updated > $1.updated }
    }

    /// Sessions Ensemble does not have yet.
    public var newSessions: [ClaudeImportSession] { sessions.filter { !$0.alreadyImported } }
    public var earliest: Date? { sessions.map(\.created).min() }
    public var latest: Date? { sessions.map(\.updated).max() }
    /// Selected when the sheet opens: the folder exists and has sessions Ensemble does not have yet.
    public var selectedByDefault: Bool { exists && !newSessions.isEmpty }
}

/// Something the desktop app calls an environment: a named starting point for new sessions.
public struct ClaudeImportEnvironment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A folder on this Mac (with a model and effort for new sessions).
        case local
        /// A remote machine reached over SSH.
        case ssh
        /// A cloud environment (sessions run on a remote server, not on this Mac).
        case cloud
        /// A kind this version of Ensemble does not know.
        case other
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// The raw kind the desktop app recorded (for `.other`).
    public var rawKind: String
    /// The folder of a local environment.
    public var folder: String?
    /// The host of an SSH environment.
    public var host: String?

    public init(id: String, name: String, kind: Kind, rawKind: String? = nil, folder: String? = nil, host: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rawKind = rawKind ?? kind.rawValue
        self.folder = folder
        self.host = host
    }

    /// Ensemble runs agents in folders on this Mac only, so only local environments map to something.
    public var isSupported: Bool { kind == .local }
}

/// What a scan found.
public struct ClaudeImportScan: Hashable, Sendable {
    /// Sessions the scan leaves out, by reason.
    public struct Skipped: Hashable, Sendable {
        /// Deleted in the desktop app (its transcript is still on disk).
        public var deletedInDesktopApp = 0
        /// An earlier conversation of a desktop session that moved on to a new one (after a rewind to the start).
        public var replacedByNewerConversation = 0
        /// No message in the transcript (started and closed without a prompt), so nothing to resume.
        public var noConversation = 0
        /// Only subagent lines.
        public var subagentOnly = 0
        /// The file could not be read, or no folder was recorded in it.
        public var unreadable = 0

        public init() {}
        public var total: Int { deletedInDesktopApp + replacedByNewerConversation + noConversation + subagentOnly + unreadable }
    }

    /// Most recent activity first.
    public var folders: [ClaudeImportFolder]
    public var environments: [ClaudeImportEnvironment]
    /// Folders trusted in the claude CLI that exist, resolved.
    public var cliTrustedFolders: [String]
    /// The desktop app's session list was found (titles and archived state come from it).
    public var desktopAppFound: Bool
    public var skipped: Skipped

    public init(folders: [ClaudeImportFolder], environments: [ClaudeImportEnvironment] = [], cliTrustedFolders: [String] = [],
                desktopAppFound: Bool = false, skipped: Skipped = Skipped()) {
        self.folders = folders
        self.environments = environments
        self.cliTrustedFolders = cliTrustedFolders
        self.desktopAppFound = desktopAppFound
        self.skipped = skipped
    }

    public var sessionCount: Int { folders.reduce(0) { $0 + $1.sessions.count } }
    public var newSessionCount: Int { folders.reduce(0) { $0 + $1.newSessions.count } }
    public var missingFolders: [ClaudeImportFolder] { folders.filter { !$0.exists } }
    public var hasNewSessions: Bool { folders.contains { !$0.newSessions.isEmpty } }
}

/// What an import did.
public struct ClaudeImportResult: Hashable, Sendable {
    /// Sessions added to Ensemble.
    public var imported: Int
    /// Sessions Ensemble already had (left as they were).
    public var alreadyThere: Int
    /// Folders the added sessions are in.
    public var folders: Int
    /// Folders trusted because the user ticked "Trust these folders".
    public var trusted: [String]
    /// Folders that could not be trusted, with the reason.
    public var notTrusted: [String: String]

    public init(imported: Int = 0, alreadyThere: Int = 0, folders: Int = 0, trusted: [String] = [], notTrusted: [String: String] = [:]) {
        self.imported = imported
        self.alreadyThere = alreadyThere
        self.folders = folders
        self.trusted = trusted
        self.notTrusted = notTrusted
    }
}
#endif
