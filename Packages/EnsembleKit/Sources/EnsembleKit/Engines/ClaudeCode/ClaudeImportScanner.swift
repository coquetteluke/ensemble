#if os(macOS)
import Foundation

/// Finds the claude CLI's sessions for an import, read-only: every top-level `<projects>/<folder>/<uuid>.jsonl` is a
/// session (subagent transcripts live in subfolders and belong to their session). Each session's folder is the `cwd`
/// recorded inside its transcript, never decoded from the folder name. Titles, archived and starred state come from
/// the desktop app's session list when it has the session, else from the transcript.
struct ClaudeImportScanner: Sendable {
    var sources: ClaudeImportSources
    /// Session ids Ensemble already has (record ids and their CLI conversations).
    var knownSessionIDs: Set<String>
    var trust: WorkspaceTrust
    var now = Date()
    /// A transcript written this recently may still be open in another app.
    var recentWindow: TimeInterval = 300

    struct TranscriptFile: Sendable {
        var folderName: String
        var url: URL
        var sessionID: String
    }

    /// The transcripts on disk (cheap: directory listings only).
    static func transcriptFiles(in projectsDirectory: URL) -> [TranscriptFile] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var result: [TranscriptFile] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(".jsonl".count))
                guard UUID(uuidString: id) != nil else { continue }
                let url = folder.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                result.append(TranscriptFile(folderName: folder.lastPathComponent, url: url, sessionID: id.lowercased()))
            }
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    func scan() -> ClaudeImportScan {
        let desktop = ClaudeDesktopSessions.load(desktopDirectory: sources.desktopDirectory)
        let environments = ClaudeDesktopEnvironments.load(desktopDirectory: sources.desktopDirectory)
        let cliTrusted = ClaudeCLITrust.load(configFile: sources.cliConfigFile)
        let files = Self.transcriptFiles(in: sources.projectsDirectory)

        var skipped = ClaudeImportScan.Skipped()
        var wanted: [TranscriptFile] = []
        for file in files {
            if desktop.isDeleted(cliSessionID: file.sessionID) {
                skipped.deletedInDesktopApp += 1
            } else if desktop.replacedCLISessions.contains(file.sessionID) {
                skipped.replacedByNewerConversation += 1
            } else {
                wanted.append(file)
            }
        }

        let wantedFiles = wanted
        let probes = ProbeResults(count: wantedFiles.count)
        DispatchQueue.concurrentPerform(iterations: wantedFiles.count) { slot in
            let file = wantedFiles[slot]
            let hasDesktopTitle = !(desktop.byCLISession[file.sessionID]?.title?.isEmpty ?? true)
            probes.set(slot, ClaudeImportProbe.read(file.url, searchTitle: !hasDesktopTitle))
        }

        var byFolder: [String: [ClaudeImportSession]] = [:]
        for (slot, file) in wantedFiles.enumerated() {
            guard let probe = probes.get(slot) else {
                skipped.unreadable += 1
                continue
            }
            guard probe.conversationLines > 0 else {
                if probe.sidechainLines > 0 { skipped.subagentOnly += 1 } else { skipped.noConversation += 1 }
                continue
            }
            let entry = desktop.byCLISession[file.sessionID]
            guard let directory = probe.directory(projectFolderName: file.folderName) ?? entry?.cwd else {
                skipped.unreadable += 1
                continue
            }
            byFolder[directory, default: []].append(session(file: file, probe: probe, entry: entry, directory: directory))
        }

        let fm = FileManager.default
        let folders = byFolder.map { path, sessions -> ClaudeImportFolder in
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            return ClaudeImportFolder(path: path, exists: exists, trustedInCLI: ClaudeCLITrust.covers(cliTrusted, path: path),
                                      trustedInEnsemble: exists && trust.isTrusted(path), sessions: sessions)
        }
        .sorted { ($0.latest ?? .distantPast, $1.path) > ($1.latest ?? .distantPast, $0.path) }

        let existingTrusted = cliTrusted.filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return ClaudeImportScan(folders: folders, environments: environments, cliTrustedFolders: existingTrusted,
                                desktopAppFound: desktop.found, skipped: skipped)
    }

    private func session(file: TranscriptFile, probe: ClaudeImportProbe, entry: ClaudeDesktopSessions.Entry?,
                         directory: String) -> ClaudeImportSession {
        let title: String
        let source: ClaudeImportSession.TitleSource
        if let desktopTitle = entry?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !desktopTitle.isEmpty {
            (title, source) = (desktopTitle, .desktopApp)
        } else if let best = probe.bestTitle {
            (title, source) = (best.text, best.source)
        } else {
            (title, source) = ("Session \(file.sessionID.prefix(8))", .firstPrompt)
        }
        let modified = probe.modified ?? now
        let created = entry?.created ?? probe.firstTimestamp ?? probe.created ?? modified
        let updated = [entry?.lastActivity, probe.lastTimestamp].compactMap { $0 }.max() ?? modified
        return ClaudeImportSession(
            id: file.sessionID, directory: directory, title: title, titleSource: source,
            created: min(created, updated), updated: updated,
            archived: entry?.archived ?? false, starred: entry?.starred ?? false,
            model: Self.modelRef(entry?.model ?? probe.model, effort: entry?.effort),
            transcriptPath: file.url.path,
            alreadyImported: knownSessionIDs.contains(file.sessionID),
            recentlyWritten: now.timeIntervalSince(modified) < recentWindow,
            inDesktopApp: entry != nil)
    }

    /// A model id the CLI or the desktop app recorded (`claude-opus-5-5`, `claude-sonnet-5-5[1m]`) as the Claude
    /// model of the picker on the user's subscription (the catalog entry for that exact model, else the alias of its
    /// family), with the effort as the variant. Unknown ids give nil (the CLI's default model).
    static func modelRef(_ raw: String?, effort: String?) -> ModelRef? {
        guard var raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasSuffix("[1m]") { raw = String(raw.dropLast(4)) }
        guard let family = ["opus", "sonnet", "haiku", "fable"].first(where: { raw.contains($0) }) else { return nil }
        let id = ClaudeModels.catalog.first(where: { $0.resolves == raw })?.id ?? family
        let variant = effort.flatMap { ClaudeModels.effortLevels.contains($0) ? $0 : nil }
        return ModelRef(providerID: ClaudeModels.subscriptionProviderID, id: id, variant: variant)
    }
}

/// Probe results filled in from `concurrentPerform`.
private final class ProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClaudeImportProbe?]

    init(count: Int) { items = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ probe: ClaudeImportProbe?) {
        lock.lock()
        items[index] = probe
        lock.unlock()
    }

    func get(_ index: Int) -> ClaudeImportProbe? {
        lock.lock()
        defer { lock.unlock() }
        return items[index]
    }
}
#endif
