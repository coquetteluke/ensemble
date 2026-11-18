#if os(macOS)
import Foundation

/// The Claude desktop app's own session list, read-only: `claude-code-sessions/<account>/<org>/local_<id>.json` (one
/// file per session: title, folder, archived, starred, model, the CLI session it runs), `archived-sessions.idx` and the
/// `deleted_<id>` markers it leaves for deleted sessions (only their names are read). Only the fields below are
/// decoded; the rest of each file is never kept.
struct ClaudeDesktopSessions: Sendable {
    struct Entry: Sendable, Equatable {
        var sessionID: String
        var cliSessionID: String
        var cwd: String?
        var title: String?
        var archived: Bool
        var starred: Bool
        var created: Date?
        var lastActivity: Date?
        var model: String?
        var effort: String?
        var priorCLISessionIDs: [String]
    }

    /// By CLI session id.
    var byCLISession: [String: Entry] = [:]
    /// CLI conversations a desktop session left behind when it moved to a new one.
    var replacedCLISessions: Set<String> = []
    /// Ids from `deleted_<id>` markers.
    var deleted: Set<String> = []
    /// The session list folder exists.
    var found = false

    static func load(desktopDirectory: URL?) -> ClaudeDesktopSessions {
        var result = ClaudeDesktopSessions()
        guard let desktopDirectory else { return result }
        let fm = FileManager.default
        let root = desktopDirectory.appendingPathComponent("claude-code-sessions")
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return result }
        result.found = true
        let decoder = JSONDecoder()
        for account in accounts {
            guard let orgs = try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil) else { continue }
            for org in orgs {
                guard let names = try? fm.contentsOfDirectory(atPath: org.path) else { continue }
                var archivedIndex: Set<String> = []
                if names.contains("archived-sessions.idx"),
                   let data = try? Data(contentsOf: org.appendingPathComponent("archived-sessions.idx")),
                   let index = try? decoder.decode(ArchivedIndex.self, from: data) {
                    archivedIndex = Set(index.archived ?? [])
                }
                for name in names {
                    if name.hasPrefix("deleted_") {
                        result.deleted.insert(String(name.dropFirst("deleted_".count)))
                        continue
                    }
                    guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                          let data = try? Data(contentsOf: org.appendingPathComponent(name)),
                          let file = try? decoder.decode(SessionFile.self, from: data),
                          let cli = file.cliSessionId, !cli.isEmpty else { continue }
                    let sessionID = file.sessionId ?? String(name.dropLast(".json".count))
                    let entry = Entry(sessionID: sessionID, cliSessionID: cli, cwd: file.cwd, title: file.title,
                                      archived: (file.isArchived ?? false) || archivedIndex.contains(sessionID),
                                      starred: file.isStarred ?? false,
                                      created: file.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                                      lastActivity: file.lastActivityAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                                      model: file.model, effort: file.effort, priorCLISessionIDs: file.priorCliSessionIds ?? [])
                    if let existing = result.byCLISession[cli], (existing.lastActivity ?? .distantPast) > (entry.lastActivity ?? .distantPast) {
                        continue
                    }
                    result.byCLISession[cli] = entry
                }
            }
        }
        for entry in result.byCLISession.values {
            result.replacedCLISessions.formUnion(entry.priorCLISessionIDs.filter { result.byCLISession[$0] == nil })
        }
        return result
    }

    /// True when the transcript belongs to a session deleted in the desktop app. Desktop session ids are often not the
    /// CLI id, so only markers that name the CLI session (or a desktop id equal to it) count.
    func isDeleted(cliSessionID: String) -> Bool {
        byCLISession[cliSessionID] == nil && (deleted.contains(cliSessionID) || deleted.contains("local_" + cliSessionID))
    }

    private struct ArchivedIndex: Decodable {
        var archived: [String]?
        private enum CodingKeys: String, CodingKey { case archived }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            archived = try? c.decodeIfPresent([String].self, forKey: .archived)
        }
    }

    private struct SessionFile: Decodable {
        var sessionId: String?
        var cliSessionId: String?
        var cwd: String?
        var title: String?
        var isArchived: Bool?
        var isStarred: Bool?
        var createdAt: Double?
        var lastActivityAt: Double?
        var model: String?
        var effort: String?
        var priorCliSessionIds: [String]?

        private enum CodingKeys: String, CodingKey {
            case sessionId, cliSessionId, cwd, title, isArchived, isStarred, createdAt, lastActivityAt, model, effort, priorCliSessionIds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
            cliSessionId = try? c.decodeIfPresent(String.self, forKey: .cliSessionId)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            isArchived = try? c.decodeIfPresent(Bool.self, forKey: .isArchived)
            isStarred = try? c.decodeIfPresent(Bool.self, forKey: .isStarred)
            createdAt = try? c.decodeIfPresent(Double.self, forKey: .createdAt)
            lastActivityAt = try? c.decodeIfPresent(Double.self, forKey: .lastActivityAt)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            effort = try? c.decodeIfPresent(String.self, forKey: .effort)
            priorCliSessionIds = try? c.decodeIfPresent([String].self, forKey: .priorCliSessionIds)
        }
    }
}

/// What the desktop app calls environments: named presets for new sessions (`ccd-session-presets.json`, each with a
/// target such as `{"kind": "local", "cwd": ...}` plus model and effort) and SSH hosts (`ssh_configs.json`). Cloud
/// environments are kept on the server, not on this Mac, so they only appear here if a preset names one.
enum ClaudeDesktopEnvironments {
    static func load(desktopDirectory: URL?) -> [ClaudeImportEnvironment] {
        guard let desktopDirectory else { return [] }
        var result: [ClaudeImportEnvironment] = []
        var seen: Set<String> = []
        func add(_ environment: ClaudeImportEnvironment) {
            guard seen.insert(environment.id).inserted else { return }
            result.append(environment)
        }

        if let data = try? Data(contentsOf: desktopDirectory.appendingPathComponent("ccd-session-presets.json")),
           let json = JSONValue.parse(data: data) {
            for (_, account) in (json["byAccount"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                for preset in account["presets"]?.arrayValue ?? [] {
                    guard let id = preset["id"]?.stringValue else { continue }
                    let target = preset["target"]
                    let rawKind = target?["kind"]?.stringValue ?? "local"
                    let name = preset["name"]?.stringValue ?? "Unnamed environment"
                    add(ClaudeImportEnvironment(id: id, name: name, kind: kind(rawKind), rawKind: rawKind,
                                                folder: target?["cwd"]?.stringValue,
                                                host: hostName(target)))
                }
            }
        }

        if let data = try? Data(contentsOf: desktopDirectory.appendingPathComponent("ssh_configs.json")),
           let json = JSONValue.parse(data: data) {
            for (offset, config) in (json["configs"]?.arrayValue ?? []).enumerated() {
                let host = hostName(config)
                let id = config["id"]?.stringValue ?? "ssh-\(host ?? String(offset))"
                let name = config["name"]?.stringValue ?? config["label"]?.stringValue ?? host ?? "SSH host"
                add(ClaudeImportEnvironment(id: id, name: name, kind: .ssh, rawKind: "ssh", host: host))
            }
        }
        return result
    }

    static func kind(_ raw: String) -> ClaudeImportEnvironment.Kind {
        switch raw.lowercased() {
        case "local": .local
        case "ssh", "remote-ssh", "ssh-remote": .ssh
        case "cloud", "remote", "web": .cloud
        default: .other
        }
    }

    /// `user@host` from the usual field names, without ports, keys or passwords.
    private static func hostName(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        guard let host = value["host"]?.stringValue ?? value["hostname"]?.stringValue ?? value["hostName"]?.stringValue,
              !host.isEmpty else { return nil }
        if let user = value["user"]?.stringValue ?? value["username"]?.stringValue, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }
}

/// Folders the user trusted in the claude CLI: `projects.<folder>.hasTrustDialogAccepted` in `~/.claude.json`. Only
/// that flag is decoded; the rest of the file (accounts, MCP servers, their settings) is never kept.
enum ClaudeCLITrust {
    static func load(configFile: URL?) -> [String] {
        guard let configFile, let data = try? Data(contentsOf: configFile),
              let body = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return [] }
        return (body.projects ?? [:]).compactMap { path, project in project.trusted == true ? path : nil }.sorted()
    }

    /// True when the folder or a folder above it is in `trusted` (the CLI's trust covers subfolders).
    static func covers(_ trusted: [String], path: String) -> Bool {
        let wanted = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trusted.contains { folder in
            let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            return wanted == base || (!base.isEmpty && wanted.hasPrefix(base + "/"))
        }
    }

    private struct ConfigFile: Decodable {
        var projects: [String: Project]?
        private enum CodingKeys: String, CodingKey { case projects }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projects = try? c.decodeIfPresent([String: Project].self, forKey: .projects)
        }
    }

    private struct Project: Decodable {
        var trusted: Bool?
        private enum CodingKeys: String, CodingKey { case hasTrustDialogAccepted }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trusted = try? c.decodeIfPresent(Bool.self, forKey: .hasTrustDialogAccepted)
        }
    }
}
#endif
