#if os(macOS)
import Foundation

/// Import of the user's existing Claude sessions (from the claude CLI and the Claude desktop app) into this engine.
///
/// - Read-only: transcripts are linked, never copied, moved or changed. An imported session keeps its CLI session id,
///   so it resumes with `claude --resume <id>` in its folder, and its transcript is read from the original file.
/// - Idempotent: sessions Ensemble already has (imported before or started in Ensemble) are skipped.
/// - Trust is never copied from the CLI: folders are only trusted when the caller passes them (the sheet's
///   "Trust these folders" checkbox), through `WorkspaceTrust`.
/// - Imported sessions get the caller's permission mode (Ensemble's default), not the mode they last ran in.
extension ClaudeCodeEngine {
    /// Where an import reads from for this engine (its projects folder, `~/.claude.json`, the desktop app's folder).
    public var importSources: ClaudeImportSources {
        .standard(projectsDirectory: configuration.projectsDirectory, environment: configuration.baseEnvironment)
    }

    /// Lists the sessions an import would find. Reads only; takes a few seconds for thousands of transcripts.
    public func scanForImport(sources: ClaudeImportSources? = nil, now: Date = Date()) async -> ClaudeImportScan {
        let scanner = ClaudeImportScanner(sources: sources ?? importSources, knownSessionIDs: savedSessionIDs(),
                                          trust: configuration.trust, now: now)
        return await Task.detached(priority: .userInitiated) { scanner.scan() }.value
    }

    /// True when the CLI has at least one transcript Ensemble does not have. Lists folders only (no file is opened),
    /// so it is cheap enough to call at launch; a scan then tells which of them can be imported.
    public func hasTranscriptsToImport(sources: ClaudeImportSources? = nil) async -> Bool {
        let directory = (sources ?? importSources).projectsDirectory
        let known = savedSessionIDs()
        return await Task.detached(priority: .utility) {
            ClaudeImportScanner.transcriptFiles(in: directory).contains { !known.contains($0.sessionID) }
        }.value
    }

    /// Adds sessions as normal Claude sessions and trusts `trustedFolders` (only those the user chose to trust).
    public func importSessions(_ sessions: [ClaudeImportSession], permissionMode: PermissionMode,
                               trusting trustedFolders: [String] = []) async -> ClaudeImportResult {
        let records = sessions.map { Self.record(for: $0, permissionMode: permissionMode) }
        let added = await core.adopt(records)
        var result = ClaudeImportResult(imported: added.count, alreadyThere: sessions.count - added.count,
                                        folders: Set(added.map(\.directory)).count, addedSessionIDs: added.map(\.id))
        for folder in Set(trustedFolders).sorted() {
            if configuration.trust.isTrusted(folder) { continue }
            do {
                try configuration.trust.trust(folder)
                result.trusted.append(folder)
            } catch {
                result.notTrusted[folder] = error.localizedDescription
            }
        }
        return result
    }

    static func record(for session: ClaudeImportSession, permissionMode: PermissionMode) -> ClaudeSessionRecord {
        var record = ClaudeSessionRecord(id: session.id, title: session.title, directory: session.directory, model: session.model,
                                         permissionMode: permissionMode, created: session.created, updated: session.updated)
        record.archived = session.archived
        // The CLI has the conversation on disk, so the first prompt resumes it (`--resume <id>`).
        record.started = true
        record.transcriptPath = session.transcriptPath
        return record
    }

    /// Session ids in the saved session list (the engine saves after every change), with their CLI conversations.
    func savedSessionIDs() -> Set<String> {
        Set(ClaudeSessionStore(fileURL: configuration.storeURL).all.flatMap { [$0.id, $0.cliID] })
    }
}
#endif
