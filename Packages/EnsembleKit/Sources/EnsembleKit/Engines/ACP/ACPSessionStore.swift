import Foundation
import Synchronization

/// Errors from ACP engines.
public enum ACPEngineError: Error, LocalizedError, Equatable, Sendable {
    /// The tool's executable was not found. Carries the install hint.
    case notInstalled(agent: String, hint: String)
    /// The tool says nobody is signed in. Carries the sign-in hint.
    case notSignedIn(agent: String, hint: String)
    /// The project folder is not in `WorkspaceTrust` and the tool would load the project's own hooks and settings there.
    /// The UI asks "Trust this folder?", calls `WorkspaceTrust.trust`, and tries again.
    case folderNotTrusted(String)
    /// ACP agents run on the Mac only.
    case unsupportedPlatform
    case notSupported(String)
    case unknownSession(String)
    case invalidArgument(String)
    /// The tool's process could not be started or stopped unexpectedly.
    case processFailed(String)
    /// The agent answered a request with an error.
    case agentError(code: Int, message: String)
    /// The agent speaks a protocol version Ensemble does not.
    case unsupportedProtocol(Int)
    /// The agent did not take the permission mode Ensemble asked for, so Ensemble will not send it work.
    case modeNotApplied(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let agent, let hint): "\(agent) is not installed. \(hint)"
        case .notSignedIn(let agent, let hint): "\(agent) is not signed in. \(hint)"
        case .folderNotTrusted(let directory):
            "This agent loads the project's own hooks and settings, so it only runs in folders you trust. Trust \(directory) to continue."
        case .unsupportedPlatform: "ACP agents run on the Mac only."
        case .notSupported(let what): what
        case .unknownSession(let id): "No ACP session with id \(id)."
        case .invalidArgument(let message): message
        case .processFailed(let message): "The agent stopped: \(message)"
        case .agentError(_, let message): message
        case .unsupportedProtocol(let version): "The agent speaks ACP version \(version); Ensemble supports version \(acpProtocolVersion)."
        case .modeNotApplied(let mode): "The agent did not switch to \(mode), so Ensemble did not send the message."
        }
    }
}

/// One ACP session Ensemble created. Saved in `~/Library/Application Support/Ensemble/acp-sessions.json`, shared by
/// every ACP tool (each record names its tool).
struct ACPSessionRecord: Codable, Hashable, Sendable {
    /// Ensemble's session id (a UUID, lowercased).
    var id: String
    /// The registry id of the tool (`antigravity`).
    var agentID: String
    /// The tool's own session id, once `session/new` has run.
    var agentSessionID: String?
    var title: String
    /// True after the user renamed the session; the agent's own titles no longer replace it.
    var titleIsCustom: Bool = false
    var directory: String
    /// `antigravity/gemini-3.8-flash#low`: the model option value, and the effort as the variant.
    var model: ModelRef?
    var permissionMode: PermissionMode
    var created: Date
    var updated: Date
    var archived: Bool = false
    var usage: Usage = .zero
    /// Tokens in the context and the window size from the newest `usage_update`.
    var contextUsed: Int?
    var contextSize: Int?
    /// Texts Ensemble injected (board messages), shown as notices when the agent replays the conversation. Capped.
    var syntheticTexts: [String] = []
    /// Synthetic texts waiting for the next prompt (`injectSynthetic(wake: false)`).
    var queuedSynthetic: [String] = []

    static let syntheticCap = 300
    static let defaultTitle = "New session"

    init(id: String, agentID: String, title: String = "", directory: String, model: ModelRef?, permissionMode: PermissionMode,
         created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.directory = directory
        self.model = model
        self.permissionMode = permissionMode
        self.created = created
        self.updated = updated
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentID, agentSessionID, title, titleIsCustom, directory, model, permissionMode, created, updated, archived
        case usage, contextUsed, contextSize, syntheticTexts, queuedSynthetic
    }

    /// Missing keys fall back to defaults, so an older or newer file never loses the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentID = try c.decode(String.self, forKey: .agentID)
        agentSessionID = try? c.decodeIfPresent(String.self, forKey: .agentSessionID)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        titleIsCustom = (try? c.decodeIfPresent(Bool.self, forKey: .titleIsCustom)) ?? false
        directory = (try? c.decodeIfPresent(String.self, forKey: .directory)) ?? ""
        model = try? c.decodeIfPresent(ModelRef.self, forKey: .model)
        permissionMode = (try? c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)) ?? .ask
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? created
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        usage = (try? c.decodeIfPresent(Usage.self, forKey: .usage)) ?? .zero
        contextUsed = try? c.decodeIfPresent(Int.self, forKey: .contextUsed)
        contextSize = try? c.decodeIfPresent(Int.self, forKey: .contextSize)
        syntheticTexts = (try? c.decodeIfPresent([String].self, forKey: .syntheticTexts)) ?? []
        queuedSynthetic = (try? c.decodeIfPresent([String].self, forKey: .queuedSynthetic)) ?? []
    }

    var engineSession: EngineSession {
        EngineSession(id: id, parentID: nil, title: title.isEmpty ? Self.defaultTitle : title, directory: directory, model: model,
                      agent: nil, usage: usage, created: created, updated: updated, archived: archived)
    }

    mutating func rememberSynthetic(_ text: String) {
        syntheticTexts.append(text)
        if syntheticTexts.count > Self.syntheticCap { syntheticTexts.removeFirst(syntheticTexts.count - Self.syntheticCap) }
    }
}

/// Reads and writes one tool's records in the shared session file. Saving re-reads the file and replaces only this
/// tool's records, under a lock shared by every ACP engine in the process, so engines for different tools never drop
/// each other's sessions. Not thread safe on its own; the engine actor owns it.
struct ACPSessionStore {
    let fileURL: URL
    let agentID: String
    private(set) var records: [String: ACPSessionRecord] = [:]

    private static let fileLock = Mutex(())

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/acp-sessions.json")
    }

    private struct FileBody: Codable {
        var version: Int
        var sessions: [ACPSessionRecord]

        init(version: Int, sessions: [ACPSessionRecord]) {
            self.version = version
            self.sessions = sessions
        }

        /// Skips records that do not decode instead of failing the whole file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 1
            var list = try c.nestedUnkeyedContainer(forKey: .sessions)
            var sessions: [ACPSessionRecord] = []
            while !list.isAtEnd {
                if let record = try? list.decode(ACPSessionRecord.self) {
                    sessions.append(record)
                } else {
                    _ = try? list.decode(JSONValue.self)
                }
            }
            self.sessions = sessions
        }
    }

    init(fileURL: URL, agentID: String) {
        self.fileURL = fileURL
        self.agentID = agentID
        let all = Self.fileLock.withLock { _ in Self.read(fileURL) }
        records = Dictionary(all.filter { $0.agentID == agentID }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static func read(_ url: URL) -> [ACPSessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(FileBody.self, from: data))?.sessions ?? []
    }

    subscript(id: String) -> ACPSessionRecord? {
        get { records[id] }
        set { records[id] = newValue }
    }

    var all: [ACPSessionRecord] { records.values.sorted { $0.updated > $1.updated } }

    mutating func remove(_ id: String) { records[id] = nil }

    func save() throws {
        try Self.fileLock.withLock { _ in
            let others = Self.read(fileURL).filter { $0.agentID != agentID }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let sessions = (others + records.values).sorted { $0.updated > $1.updated }
            let data = try encoder.encode(FileBody(version: 1, sessions: sessions))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
