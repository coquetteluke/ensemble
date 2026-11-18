import Foundation

/// One Claude session Ensemble created. Saved in `~/Library/Application Support/Ensemble/claude-sessions.json`.
struct ClaudeSessionRecord: Codable, Hashable, Sendable {
    /// Ensemble's session id (a UUID). Subagent ids are built from it.
    var id: String
    var title: String
    var directory: String
    /// The model as Ensemble names it (`claude-code/sonnet#high`).
    var model: ModelRef?
    var permissionMode: PermissionMode
    var created: Date
    var updated: Date
    var archived: Bool = false
    /// The CLI's session id. Equal to `id`, except after a rewind to before the first message, which starts a new
    /// CLI conversation.
    var cliSessionID: String?
    /// True once the CLI has a conversation on disk for `cliSessionID`, so the next launch uses `--resume`.
    var started: Bool = false
    var usage: Usage = .zero
    var lastContextTokens: Int?
    /// `low` ... `max`; nil keeps the user's default.
    var effort: String?
    /// Claude's fast mode (`--fast-mode`); nil keeps the user's default.
    var fastMode: Bool?
    /// A fork that has not run yet: the CLI session it copies, launched with `--fork-session`.
    var forkFrom: String?
    /// The entry the next launch resumes at (`--resume-session-at`), after a rewind or for a fork at a message.
    var resumeAt: String?
    /// Synthetic texts injected into this session (shown as notices in the transcript). Newest last, capped.
    var syntheticTexts: [String] = []
    /// Synthetic texts waiting for the next prompt (`injectSynthetic(wake: false)`).
    var queuedSynthetic: [String] = []
    /// Where the CLI's transcript file was last found.
    var transcriptPath: String?

    static let syntheticCap = 300

    init(id: String, title: String, directory: String, model: ModelRef?, permissionMode: PermissionMode,
         created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.title = title
        self.directory = directory
        self.model = model
        self.permissionMode = permissionMode
        self.created = created
        self.updated = updated
        if let variant = model?.variant, ClaudeModels.effortLevels.contains(variant) { effort = variant }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, directory, model, permissionMode, created, updated, archived, cliSessionID, started, usage
        case lastContextTokens, effort, fastMode, forkFrom, resumeAt, syntheticTexts, queuedSynthetic, transcriptPath
    }

    /// Missing keys fall back to defaults, so an older or newer file never loses the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
        model = try? c.decodeIfPresent(ModelRef.self, forKey: .model)
        permissionMode = (try? c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)) ?? .ask
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? created
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        cliSessionID = try? c.decodeIfPresent(String.self, forKey: .cliSessionID)
        started = (try? c.decodeIfPresent(Bool.self, forKey: .started)) ?? false
        usage = (try? c.decodeIfPresent(Usage.self, forKey: .usage)) ?? .zero
        lastContextTokens = try? c.decodeIfPresent(Int.self, forKey: .lastContextTokens)
        effort = try? c.decodeIfPresent(String.self, forKey: .effort)
        fastMode = try? c.decodeIfPresent(Bool.self, forKey: .fastMode)
        forkFrom = try? c.decodeIfPresent(String.self, forKey: .forkFrom)
        resumeAt = try? c.decodeIfPresent(String.self, forKey: .resumeAt)
        syntheticTexts = (try? c.decodeIfPresent([String].self, forKey: .syntheticTexts)) ?? []
        queuedSynthetic = (try? c.decodeIfPresent([String].self, forKey: .queuedSynthetic)) ?? []
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
    }

    var cliID: String { cliSessionID ?? id }

    var billing: ClaudeBilling { ClaudeModels.billing(for: model) }

    static let defaultTitle = "New session"

    var engineSession: EngineSession {
        EngineSession(id: id, parentID: nil, title: title.isEmpty ? Self.defaultTitle : title, directory: directory, model: model,
                      agent: nil, usage: usage, created: created, updated: updated, archived: archived)
    }

    mutating func rememberSynthetic(_ text: String) {
        syntheticTexts.append(text)
        if syntheticTexts.count > Self.syntheticCap { syntheticTexts.removeFirst(syntheticTexts.count - Self.syntheticCap) }
    }
}

/// Reads and writes the session list. Not thread safe; the engine actor owns it.
struct ClaudeSessionStore {
    let fileURL: URL
    private(set) var records: [String: ClaudeSessionRecord] = [:]
    /// Trusted folders (resolved) whose API endpoint and credential settings the user agreed to for API-key agents,
    /// with a hash of those settings (`ClaudeProjectSettings.Overrides.fingerprint`), never their values.
    var confirmedAPISettings: [String: String] = [:]

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/claude-sessions.json")
    }

    private struct FileBody: Codable {
        var version: Int
        var sessions: [ClaudeSessionRecord]
        var confirmedAPISettings: [String: String]?
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let body = try? decoder.decode(FileBody.self, from: data) {
                records = Dictionary(body.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                confirmedAPISettings = body.confirmedAPISettings ?? [:]
            }
        }
    }

    subscript(id: String) -> ClaudeSessionRecord? {
        get { records[id] }
        set { records[id] = newValue }
    }

    var all: [ClaudeSessionRecord] { records.values.sorted { $0.updated > $1.updated } }

    mutating func remove(_ id: String) { records[id] = nil }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FileBody(version: 1, sessions: all,
                                               confirmedAPISettings: confirmedAPISettings.isEmpty ? nil : confirmedAPISettings))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
