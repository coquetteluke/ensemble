#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// A fake claude CLI and desktop app on disk: `projects/` transcripts (long folder names, a missing folder, a relocated
/// session, deleted, replaced, empty and subagent-only transcripts), the desktop app's session list, environments,
/// SSH hosts and the CLI's trust flags. All names and texts are made up.
final class ClaudeImportSandbox: @unchecked Sendable {
    let root: URL
    let projects: URL
    let desktop: URL
    let cliConfig: URL
    let store: URL
    let projectA: String
    let projectB: String
    let longProject: String
    let missingProject: String
    lazy var trust = WorkspaceTrust(fileURL: root.appendingPathComponent("trusted-folders.json"), homeDirectory: root.path)

    enum ID {
        static let desktopKnown = "0a000000-0000-4000-8000-000000000001"
        static let renamed = "0a000000-0000-4000-8000-000000000002"
        static let long = "0a000000-0000-4000-8000-000000000003"
        static let missing = "0a000000-0000-4000-8000-000000000004"
        static let deleted = "0a000000-0000-4000-8000-000000000005"
        static let replaced = "0a000000-0000-4000-8000-000000000006"
        static let empty = "0a000000-0000-4000-8000-000000000007"
        static let subagentOnly = "0a000000-0000-4000-8000-000000000008"
        static let relocated = "0a000000-0000-4000-8000-000000000009"
        static let summary = "0a000000-0000-4000-8000-00000000000a"
    }

    init() throws {
        let fm = FileManager.default
        // Resolved, so paths match what WorkspaceTrust stores (the temporary folder is behind a symlink).
        let base = URL(fileURLWithPath: WorkspaceTrust.resolvedPath(fm.temporaryDirectory.path) ?? fm.temporaryDirectory.path)
        root = base.appendingPathComponent("ens-import-\(UUID().uuidString)")
        projects = root.appendingPathComponent("claude/projects")
        desktop = root.appendingPathComponent("desktop")
        cliConfig = root.appendingPathComponent("claude.json")
        store = root.appendingPathComponent("ensemble/claude-sessions.json")
        projectA = root.appendingPathComponent("code/weather app").path
        projectB = root.appendingPathComponent("code/notes").path
        longProject = root.appendingPathComponent("code/" + String(repeating: "a-rather-long-folder-name-", count: 9) + "end").path
        missingProject = root.appendingPathComponent("code/gone").path
        for folder in [projectA, projectB, longProject] {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try plantTranscripts()
        try plantDesktopApp()
        try Data("""
        {"numStartups": 3, "oauthAccount": {"emailAddress": "someone@example.com"},
         "projects": {"\(projectA)": {"hasTrustDialogAccepted": true, "allowedTools": []},
                      "\(missingProject)": {"hasTrustDialogAccepted": true},
                      "\(projectB)": {"hasTrustDialogAccepted": false}}}
        """.utf8).write(to: cliConfig)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var sources: ClaudeImportSources {
        ClaudeImportSources(projectsDirectory: projects, cliConfigFile: cliConfig, desktopDirectory: desktop)
    }

    func engine() -> ClaudeCodeEngine {
        ClaudeCodeEngine(configuration: .init(executablePath: "/nonexistent/claude", storeURL: store, projectsDirectory: projects,
                                              fileCheckpointing: false, keychainService: "Ensemble test \(UUID().uuidString)",
                                              baseEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], trust: trust))
    }

    /// The CLI's folder name for a working folder (long ones cut to 200 characters plus a hash).
    static func folderName(_ path: String) -> String {
        let encoded = ClaudeImportProbe.encodedFolderName(path)
        return encoded.count > 200 ? String(encoded.prefix(200)) + "-k3x9q1" : encoded
    }

    /// Every file under the fake CLI and desktop folders with its size and modification date.
    func snapshotOfSources() -> [String: String] {
        var result: [String: String] = [:]
        for folder in [projects, desktop] {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                result[url.path] = "\(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
        }
        return result
    }

    // MARK: Lines

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func user(_ text: Any, cwd: String, at time: String, uuid: String, parent: String?, sessionID: String,
                     sidechain: Bool = false, meta: Bool = false) -> String {
        var object: [String: Any] = ["type": "user", "cwd": cwd, "timestamp": time, "uuid": uuid, "sessionId": sessionID,
                                     "isSidechain": sidechain, "message": ["role": "user", "content": text] as [String: Any]]
        object["parentUuid"] = parent ?? NSNull()
        if meta { object["isMeta"] = true }
        return json(object)
    }

    static func assistant(_ text: String, cwd: String, at time: String, uuid: String, parent: String, sessionID: String,
                          model: String = "claude-sonnet-5-5", sidechain: Bool = false) -> String {
        json(["type": "assistant", "cwd": cwd, "timestamp": time, "uuid": uuid, "parentUuid": parent, "sessionId": sessionID,
              "isSidechain": sidechain,
              "message": ["id": "msg_\(uuid)", "role": "assistant", "model": model,
                          "content": [["type": "text", "text": text]]] as [String: Any]])
    }

    static func conversation(_ id: String, cwd: String, prompt: Any, reply: String, day: Int, model: String = "claude-sonnet-5-5") -> [String] {
        [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-0\#(day)T09:59:00.000Z","sessionId":"\#(id)"}"#,
            user(prompt, cwd: cwd, at: "2026-10-0\(day)T10:00:00.000Z", uuid: "\(id)-u1", parent: nil, sessionID: id),
            assistant(reply, cwd: cwd, at: "2026-10-0\(day)T10:00:05.000Z", uuid: "\(id)-a1", parent: "\(id)-u1", sessionID: id, model: model),
        ]
    }

    func write(_ lines: [String], session id: String, cwd: String) throws {
        let folder = projects.appendingPathComponent(Self.folderName(cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("\(id).jsonl"))
    }

    private func plantTranscripts() throws {
        // Known to the desktop app, which has its own (newer) title.
        try write(Self.conversation(ID.desktopKnown, cwd: projectA, prompt: "Add a five day forecast", reply: "Done.", day: 1)
                  + [#"{"type":"custom-title","customTitle":"Forecast work","sessionId":"\#(ID.desktopKnown)"}"#],
                  session: ID.desktopKnown, cwd: projectA)

        // Renamed with /rename early on, then a long conversation, so the title is neither in the first nor the last lines.
        var renamed = Self.conversation(ID.renamed, cwd: projectA, prompt: [["type": "text", "text": "<command-name>/model</command-name>"]],
                                        reply: "Set model.", day: 2)
        renamed.append(Self.user("Fix the flaky radar test", cwd: projectA, at: "2026-10-02T10:01:00.000Z", uuid: "r-u2",
                                 parent: "\(ID.renamed)-a1", sessionID: ID.renamed))
        renamed.append(#"{"type":"custom-title","customTitle":"Radar test fix","sessionId":"\#(ID.renamed)"}"#)
        var parent = "r-u2"
        let filler = String(repeating: "x", count: 2000)
        for index in 0..<300 {
            renamed.append(Self.assistant("step \(index) \(filler)", cwd: projectA, at: "2026-10-02T11:00:00.000Z", uuid: "r-a\(index)",
                                          parent: parent, sessionID: ID.renamed))
            parent = "r-a\(index)"
        }
        renamed.append(Self.assistant("All green.", cwd: projectA, at: "2026-10-03T08:30:00.000Z", uuid: "r-last", parent: parent,
                                      sessionID: ID.renamed, model: "claude-opus-5-5"))
        try write(renamed, session: ID.renamed, cwd: projectA)

        // A folder whose CLI name is longer than 200 characters; titled from its first prompt (meta lines skipped).
        let longPrompt = "Please go through every view in this project and make the spacing consistent with the design notes"
        var long = Self.conversation(ID.long, cwd: longProject, prompt: longPrompt, reply: "On it.", day: 4)
        long.insert(Self.user("<system-reminder>context</system-reminder>", cwd: longProject, at: "2026-10-04T09:59:30.000Z",
                              uuid: "meta", parent: nil, sessionID: ID.long, meta: true), at: 1)
        try write(long, session: ID.long, cwd: longProject)

        // The folder no longer exists.
        try write(Self.conversation(ID.missing, cwd: missingProject, prompt: "Old experiment", reply: "Ok.", day: 5),
                  session: ID.missing, cwd: missingProject)

        // Deleted in the desktop app, and an older conversation of the desktop session.
        try write(Self.conversation(ID.deleted, cwd: projectA, prompt: "Deleted one", reply: "Ok.", day: 6), session: ID.deleted, cwd: projectA)
        try write(Self.conversation(ID.replaced, cwd: projectA, prompt: "Before the rewind", reply: "Ok.", day: 1),
                  session: ID.replaced, cwd: projectA)

        // Started and closed without a prompt; only subagent lines.
        try write([#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-07T10:00:00.000Z","sessionId":"\#(ID.empty)"}"#],
                  session: ID.empty, cwd: projectB)
        try write([Self.user("sub task", cwd: projectB, at: "2026-10-07T10:00:00.000Z", uuid: "s1", parent: nil, sessionID: ID.subagentOnly,
                             sidechain: true)],
                  session: ID.subagentOnly, cwd: projectB)

        // Started in another folder and relocated to project B: filed under B, so it resumes from B.
        let oldFolder = root.appendingPathComponent("code/old-notes").path
        var relocated = Self.conversation(ID.relocated, cwd: oldFolder, prompt: "Sort the notes by date", reply: "Sorted.", day: 8)
        relocated.append(#"{"type":"relocated","relocatedCwd":"\#(projectB)","sessionId":"\#(ID.relocated)"}"#)
        relocated.append(Self.user("Thanks", cwd: projectB, at: "2026-10-08T12:00:00.000Z", uuid: "rl-u2", parent: "\(ID.relocated)-a1",
                                   sessionID: ID.relocated))
        try write(relocated, session: ID.relocated, cwd: projectB)

        // Older CLI versions: a summary line at the top.
        try write([#"{"type":"summary","summary":"Notes sync design","leafUuid":"x"}"#]
                  + Self.conversation(ID.summary, cwd: projectB, prompt: "How should sync work?", reply: "Like this.", day: 9),
                  session: ID.summary, cwd: projectB)

        // Not sessions: a file that is not named by a session id, and a subagent transcript in its session's folder.
        let folderA = projects.appendingPathComponent(Self.folderName(projectA))
        try Data("{}\n".utf8).write(to: folderA.appendingPathComponent("notes.jsonl"))
        let subagents = folderA.appendingPathComponent(ID.desktopKnown).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent-1.jsonl"))
    }

    private func plantDesktopApp() throws {
        let org = desktop.appendingPathComponent("claude-code-sessions/acct/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let session: [String: Any] = [
            "sessionId": "local_d1", "cliSessionId": ID.desktopKnown, "cwd": projectA, "originCwd": projectA,
            "title": "Five day forecast", "isArchived": false, "isStarred": true,
            "createdAt": 1_790_000_000_000, "lastActivityAt": 1_790_500_000_000,
            "model": "claude-opus-5-5", "effort": "high", "permissionMode": "bypassPermissions",
            "priorCliSessionIds": [ID.replaced], "spawnSeed": ["nested": [1, 2, 3]], "completedTurns": "not a number",
        ]
        try Data(Self.json(session).utf8).write(to: org.appendingPathComponent("local_d1.json"))
        let archived: [String: Any] = [
            "sessionId": "local_d2", "cliSessionId": ID.summary, "cwd": projectB, "title": "Sync design", "isArchived": false,
            "createdAt": 1_789_000_000_000, "lastActivityAt": 1_789_100_000_000,
        ]
        try Data(Self.json(archived).utf8).write(to: org.appendingPathComponent("local_d2.json"))
        try Data(#"{"v":1,"archived":["local_d2"]}"#.utf8).write(to: org.appendingPathComponent("archived-sessions.idx"))
        try Data("1790000000000".utf8).write(to: org.appendingPathComponent("deleted_\(ID.deleted)"))

        let presetList: [[String: Any]] = [
            ["id": "env-1", "name": "Weather", "target": ["kind": "local", "cwd": projectA], "settings": ["effort": "high"]],
            ["id": "env-2", "name": "Build box", "target": ["kind": "ssh", "host": "build.example.test", "user": "dev"]],
            ["id": "env-3", "name": "Web sandbox", "target": ["kind": "cloud", "environmentId": "env_x"]],
        ]
        let account: [String: Any] = ["builtIns": ["local": ["settings": ["modelId": "claude-opus-5-5"]]], "presets": presetList]
        let presets: [String: Any] = ["byAccount": ["acct": account]]
        try Data(Self.json(presets).utf8).write(to: desktop.appendingPathComponent("ccd-session-presets.json"))
        try Data(#"{"configs":[{"id":"ssh-1","name":"Pi","host":"pi.example.test","user":"pi","identityFile":"~/.ssh/id"}],"trustedHosts":["x"]}"#.utf8)
            .write(to: desktop.appendingPathComponent("ssh_configs.json"))
    }
}

@Suite("Claude session import")
struct ClaudeImportTests {
    typealias Box = ClaudeImportSandbox
    typealias ID = ClaudeImportSandbox.ID

    func scan(_ box: Box, known: Set<String> = []) -> ClaudeImportScan {
        ClaudeImportScanner(sources: box.sources, knownSessionIDs: known, trust: box.trust,
                            now: Date(timeIntervalSince1970: 1_800_000_000)).scan()
    }

    @Test func scanFindsSessionsUnderTheFoldersRecordedInTheirTranscripts() throws {
        let box = try Box()
        let result = scan(box)
        let byID = Dictionary(uniqueKeysWithValues: result.folders.flatMap(\.sessions).map { ($0.id, $0) })

        #expect(Set(result.folders.map(\.path)) == [box.projectA, box.projectB, box.longProject, box.missingProject])
        #expect(Set(byID.keys) == [ID.desktopKnown, ID.renamed, ID.long, ID.missing, ID.relocated, ID.summary])
        #expect(result.sessionCount == 6)
        #expect(result.skipped.deletedInDesktopApp == 1)
        #expect(result.skipped.replacedByNewerConversation == 1)
        #expect(result.skipped.noConversation == 1)
        #expect(result.skipped.subagentOnly == 1)
        #expect(result.skipped.unreadable == 0)
        #expect(result.desktopAppFound)

        // Desktop app data wins for its sessions.
        let known = try #require(byID[ID.desktopKnown])
        #expect(known.title == "Five day forecast")
        #expect(known.titleSource == .desktopApp)
        #expect(known.starred)
        #expect(!known.archived)
        #expect(known.model == ModelRef(providerID: "claude-code", id: "opus", variant: "high"))
        #expect(known.created == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(known.inDesktopApp)
        #expect(byID[ID.summary]?.inDesktopApp == true)
        #expect(byID[ID.renamed]?.inDesktopApp == false)
        #expect(byID[ID.long]?.inDesktopApp == false)
        #expect(byID[ID.summary]?.archived == true)
        #expect(byID[ID.summary]?.title == "Sync design")

        // Transcript-only sessions: a /rename deep in the file, the first real prompt, the old summary line.
        #expect(byID[ID.renamed]?.title == "Radar test fix")
        #expect(byID[ID.renamed]?.titleSource == .renamed)
        #expect(byID[ID.renamed]?.model?.id == "opus")
        #expect(byID[ID.renamed]?.updated == ClaudeDates.parse("2026-10-03T08:30:00.000Z"))
        #expect(byID[ID.renamed]?.created == ClaudeDates.parse("2026-10-02T10:00:00.000Z"))
        #expect(byID[ID.long]?.title == "Please go through every view in this project and make the...")
        #expect(byID[ID.long]?.titleSource == .firstPrompt)
        #expect(byID[ID.long]?.directory == box.longProject)
        #expect(byID[ID.relocated]?.directory == box.projectB)

        // Missing folders are listed, not selected; trust flags come from the CLI's config, not applied.
        let missing = try #require(result.folders.first { $0.path == box.missingProject })
        #expect(!missing.exists)
        #expect(!missing.selectedByDefault)
        #expect(result.missingFolders.map(\.path) == [box.missingProject])
        let folderA = try #require(result.folders.first { $0.path == box.projectA })
        #expect(folderA.exists && folderA.selectedByDefault && folderA.trustedInCLI && !folderA.trustedInEnsemble)
        #expect(result.folders.first { $0.path == box.projectB }?.trustedInCLI == false)
        #expect(result.cliTrustedFolders == [box.projectA])
        #expect(result.folders.first?.path == box.missingProject || result.folders.first?.latest != nil)

        // Environments: local folders map, SSH and cloud are listed as unsupported.
        let environments = Dictionary(uniqueKeysWithValues: result.environments.map { ($0.id, $0) })
        #expect(environments["env-1"]?.kind == .local)
        #expect(environments["env-1"]?.folder == box.projectA)
        #expect(environments["env-1"]?.isSupported == true)
        #expect(environments["env-2"]?.kind == .ssh)
        #expect(environments["env-2"]?.host == "dev@build.example.test")
        #expect(environments["env-3"]?.kind == .cloud)
        #expect(environments["ssh-1"]?.host == "pi@pi.example.test")
        #expect(result.environments.filter(\.isSupported).count == 1)
    }

    @Test func importAdoptsSessionsReadsTheOriginalFilesAndRunsOnce() async throws {
        let box = try Box()
        let before = box.snapshotOfSources()
        let engine = box.engine()
        let first = await engine.scanForImport(sources: box.sources)
        let chosen = first.folders.filter(\.selectedByDefault).flatMap(\.newSessions)
        #expect(chosen.count == 5)

        let result = await engine.importSessions(chosen, permissionMode: .auto)
        #expect(result.imported == 5)
        #expect(result.alreadyThere == 0)
        #expect(result.folders == 3)
        #expect(result.trusted.isEmpty)

        let listed = try await engine.listSessions()
        #expect(Set(listed.map(\.id)) == Set(chosen.map(\.id)))
        let known = try #require(listed.first { $0.id == ID.desktopKnown })
        #expect(known.title == "Five day forecast")
        #expect(known.directory == box.projectA)
        #expect(listed.first { $0.id == ID.summary }?.archived == true)

        // The transcript comes from the CLI's own file, and the session is set to resume it.
        let items = try await engine.transcript(ID.desktopKnown)
        #expect(items.contains { if case .user(_, "Add a five day forecast", _) = $0 { true } else { false } })
        #expect(items.contains { if case .agentText(_, "Done.", _, _) = $0 { true } else { false } })
        let saved = ClaudeSessionStore(fileURL: box.store)
        let record = try #require(saved[ID.desktopKnown])
        #expect(record.started)
        #expect(record.cliID == ID.desktopKnown)
        #expect(record.permissionMode == .auto)
        #expect(record.effort == "high")
        #expect(record.transcriptPath?.hasSuffix("\(ID.desktopKnown).jsonl") == true)

        // Running it again adds nothing; only a new transcript is new.
        let second = await engine.scanForImport(sources: box.sources)
        #expect(second.newSessionCount == 1)
        #expect(second.folders.first { $0.path == box.missingProject }?.newSessions.count == 1)
        #expect(await engine.importSessions(second.folders.flatMap(\.sessions).filter(\.alreadyImported), permissionMode: .auto).imported == 0)
        let fresh = "0a000000-0000-4000-8000-0000000000ff"
        try box.write(Box.conversation(fresh, cwd: box.projectA, prompt: "A new idea", reply: "Ok.", day: 9), session: fresh, cwd: box.projectA)
        let third = await engine.scanForImport(sources: box.sources)
        let newOnes = third.folders.filter(\.exists).flatMap(\.newSessions)
        #expect(newOnes.map(\.id) == [fresh])
        #expect(await engine.importSessions(newOnes + chosen, permissionMode: .auto).imported == 1)
        #expect(try await engine.listSessions().count == 6)

        // A second engine on the same store sees the imported sessions.
        #expect(try await box.engine().listSessions().count == 6)

        // The CLI's and the desktop app's files are untouched (apart from the transcript this test added).
        var after = box.snapshotOfSources()
        after = after.filter { !$0.key.contains(fresh) }
        #expect(after == before)
    }

    @Test func sessionsStartedOutsideTheDesktopAppCanComeInArchived() async throws {
        let box = try Box()
        let engine = box.engine()
        let scan = await engine.scanForImport(sources: box.sources)
        let chosen = scan.folders.filter(\.selectedByDefault).flatMap(\.newSessions)
        #expect(chosen.map { $0.prepared(archiveOutsideDesktopApp: false) } == chosen)
        let prepared = chosen.map { $0.prepared(archiveOutsideDesktopApp: true) }
        #expect(prepared.filter { $0.archived && !$0.inDesktopApp }.count == 3)

        let result = await engine.importSessions(prepared, permissionMode: .auto)
        #expect(Set(result.addedSessionIDs) == Set(chosen.map(\.id)))
        let listed = Dictionary(uniqueKeysWithValues: try await engine.listSessions().map { ($0.id, $0) })
        // Desktop sessions keep their own state; the rest come in archived and can still be opened.
        #expect(listed[ID.desktopKnown]?.archived == false)
        #expect(listed[ID.summary]?.archived == true)
        for id in [ID.renamed, ID.long, ID.relocated] { #expect(listed[id]?.archived == true) }
        #expect(!(try await engine.transcript(ID.renamed)).isEmpty)
    }

    @Test func foldersAreTrustedOnlyWhenAsked() async throws {
        let box = try Box()
        let engine = box.engine()
        let scan = await engine.scanForImport(sources: box.sources)
        let sessions = scan.folders.filter(\.exists).flatMap(\.newSessions)
        _ = await engine.importSessions(sessions, permissionMode: .auto)
        #expect(!box.trust.isTrusted(box.projectA))

        let result = await engine.importSessions([], permissionMode: .auto, trusting: [box.projectA, box.missingProject, box.root.path])
        #expect(result.trusted == [box.projectA])
        #expect(box.trust.isTrusted(box.projectA))
        #expect(!box.trust.isTrusted(box.projectB))
        #expect(result.notTrusted.keys.sorted() == [box.root.path, box.missingProject].sorted())
    }

    @Test func cheapCheckSeesTranscriptsEnsembleDoesNotHave() async throws {
        let box = try Box()
        let engine = box.engine()
        #expect(await engine.hasTranscriptsToImport(sources: box.sources))
        let empty = box.root.appendingPathComponent("empty-projects")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!(await engine.hasTranscriptsToImport(sources: ClaudeImportSources(projectsDirectory: empty, cliConfigFile: nil, desktopDirectory: nil))))
    }

    @Test func withoutTheDesktopAppTitlesComeFromTranscripts() throws {
        let box = try Box()
        let sources = ClaudeImportSources(projectsDirectory: box.projects, cliConfigFile: nil, desktopDirectory: nil)
        let result = ClaudeImportScanner(sources: sources, knownSessionIDs: [], trust: box.trust).scan()
        let byID = Dictionary(uniqueKeysWithValues: result.folders.flatMap(\.sessions).map { ($0.id, $0) })
        #expect(!result.desktopAppFound)
        #expect(byID[ID.desktopKnown]?.title == "Forecast work")
        #expect(byID[ID.summary]?.title == "Notes sync design")
        #expect(byID[ID.summary]?.archived == false)
        // Nothing marks these as deleted or replaced without the desktop app.
        #expect(byID[ID.deleted] != nil && byID[ID.replaced] != nil)
        #expect(result.environments.isEmpty)
        #expect(result.cliTrustedFolders.isEmpty)
    }

    @Test func folderNamesFollowTheCLIScheme() {
        #expect(ClaudeImportProbe.encodedFolderName("/Users/sam/My App.v2") == "-Users-sam-My-App-v2")
        #expect(ClaudeImportProbe.encodedFolderName("/tmp/caf\u{E9}/\u{1F600}") == "-tmp-caf----")
        let long = "/Users/sam/" + String(repeating: "deep/", count: 60)
        let name = String(ClaudeImportProbe.encodedFolderName(long).prefix(200)) + "-1a2b3c"
        #expect(ClaudeImportProbe.matches(cwd: long, folderName: name))
        #expect(!ClaudeImportProbe.matches(cwd: long + "x/", folderName: "-Users-sam"))
        #expect(ClaudeImportProbe.matches(cwd: "/Users/sam/app", folderName: "-Users-sam-app"))
        #expect(!ClaudeImportProbe.matches(cwd: "/Users/sam/app", folderName: "-Users-sam-app2"))
    }

    @Test func probeSkipsCommandsAndBookkeeping() {
        let id = "s"
        let lines = [
            #"{"type":"api-request","base":"{\"cwd\":\"/wrong\"}","timestamp":"2026-01-01T00:00:00Z"}"#,
            Box.user("<command-name>/clear</command-name>", cwd: "/p", at: "2026-10-01T10:00:00Z", uuid: "u0", parent: nil, sessionID: id),
            Box.user([["type": "image", "source": [String: String]()] as [String: Any], ["type": "text", "text": "  What is in\nthis picture?  "]],
                     cwd: "/p",
                     at: "2026-10-01T10:01:00Z", uuid: "u1", parent: "u0", sessionID: id),
            Box.assistant("A cat.", cwd: "/p", at: "2026-10-01T10:02:00Z", uuid: "a1", parent: "u1", sessionID: id, model: "<synthetic>"),
            #"{"type":"last-prompt","lastPrompt":"What is in this picture?","sessionId":"s"}"#,
        ]
        let probe = ClaudeImportProbe.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(probe.firstPrompt == "What is in\nthis picture?")
        #expect(probe.bestTitle?.text == "What is in")
        #expect(probe.cwds == ["/p"])
        #expect(probe.model == nil)
        #expect(probe.conversationLines == 3)
        #expect(probe.firstTimestamp == ClaudeDates.parse("2026-10-01T10:00:00Z"))
        #expect(probe.lastTimestamp == ClaudeDates.parse("2026-10-01T10:02:00Z"))
    }

    @Test func modelsMapToAliasesOnTheSubscription() {
        #expect(ClaudeImportScanner.modelRef("claude-opus-5-5", effort: "xhigh") == ModelRef(providerID: "claude-code", id: "opus", variant: "xhigh"))
        #expect(ClaudeImportScanner.modelRef("claude-sonnet-5-5[1m]", effort: nil) == ModelRef(providerID: "claude-code", id: "sonnet[1m]"))
        #expect(ClaudeImportScanner.modelRef("claude-fable-5-2", effort: "turbo")?.variant == nil)
        #expect(ClaudeImportScanner.modelRef("gpt-9", effort: "high") == nil)
        #expect(ClaudeImportScanner.modelRef(nil, effort: "high") == nil)
    }
}
#endif
