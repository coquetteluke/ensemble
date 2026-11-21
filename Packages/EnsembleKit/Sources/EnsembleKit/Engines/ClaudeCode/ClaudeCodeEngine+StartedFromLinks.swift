import Foundation

// MARK: Linked sessions from the Claude desktop app

extension ClaudeCodeEngine: EngineStartedFromLinks {
    #if os(macOS)
    /// Sessions the Claude desktop app started from another session (`spawnedFrom` in its session files), as links
    /// between this engine's session ids. Nothing is read when the engine has no sessions.
    public func startedFromLinks() async -> [String: String] {
        let storeURL = configuration.storeURL
        let desktopDirectory = importSources.desktopDirectory
        return await Task.detached(priority: .utility) {
            let sessions = ClaudeSessionStore(fileURL: storeURL).all.map { (id: $0.id, cliID: $0.cliID) }
            guard !sessions.isEmpty else { return [:] }
            let desktop = ClaudeDesktopSessions.load(desktopDirectory: desktopDirectory)
            return ClaudeDesktopLinks.links(desktop: desktop, sessions: sessions)
        }.value
    }
    #else
    public func startedFromLinks() async -> [String: String] { [:] }
    #endif
}

#if os(macOS)
/// Turns the desktop app's started-from links (desktop ids) into links between Ensemble session ids. A desktop session
/// is matched to an Ensemble session by its CLI session id or one of its earlier CLI session ids.
enum ClaudeDesktopLinks {
    static func links(desktop: ClaudeDesktopSessions, sessions: [(id: String, cliID: String)]) -> [String: String] {
        var ensembleID: [String: String] = [:]
        for session in sessions {
            if ensembleID[session.id] == nil { ensembleID[session.id] = session.id }
            if ensembleID[session.cliID] == nil { ensembleID[session.cliID] = session.id }
        }
        let entries = desktop.byCLISession.values.sorted { $0.cliSessionID < $1.cliSessionID }
        var byDesktopID: [String: ClaudeDesktopSessions.Entry] = [:]
        for entry in entries where byDesktopID[entry.sessionID] == nil { byDesktopID[entry.sessionID] = entry }

        func resolve(_ entry: ClaudeDesktopSessions.Entry) -> String? {
            ([entry.cliSessionID] + entry.priorCLISessionIDs).lazy.compactMap { ensembleID[$0] }.first
        }

        var result: [String: String] = [:]
        for entry in entries where !entry.lineageDetached {
            guard let parentDesktopID = entry.spawnedFromSessionID, parentDesktopID != entry.sessionID,
                  let parent = byDesktopID[parentDesktopID],
                  let child = resolve(entry), let parentID = resolve(parent), child != parentID else { continue }
            result[child] = parentID
        }
        return result
    }
}
#endif
