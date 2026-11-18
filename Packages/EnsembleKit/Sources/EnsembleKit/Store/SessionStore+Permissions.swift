import Foundation

/// Engines that can say which permission rules a session runs under (OpenCode keeps them on the session).
/// Could move to `OpenCode/EngineCapabilities.swift` with the other optional abilities.
public protocol EngineSessionRulesReading: Sendable {
    /// The session's own rules; empty when it has none (the agent's rules apply).
    func permissionRules(_ sessionID: String) async throws -> [PermissionRule]
}

extension OpenCodeClient: EngineSessionRulesReading {}

extension SessionStore {
    /// Checks every top-level session once per launch (see `syncPermissionRules`).
    func syncAllPermissionRules() async {
        for session in sessions where session.info.parentID == nil && !session.info.archived {
            await syncPermissionRules(session.id)
        }
    }

    /// Brings a session onto today's permission rules, once per launch: the mode is read from the rules the
    /// engine holds (so the composer shows the real mode), and rules an earlier Ensemble version wrote, which
    /// the engine keeps until the mode is set again, are rewritten for the same mode. Rules Ensemble did not
    /// write are left alone. Engines that cannot report rules are skipped: the store would only be guessing
    /// their mode. A mode the user picks meanwhile wins.
    func syncPermissionRules(_ sessionID: String) async {
        guard eventTask != nil, let reader = engine as? any EngineSessionRulesReading,
              let session = byID[sessionID], session.info.parentID == nil,
              permissionRulesChecked.insert(sessionID).inserted else { return }
        let before = session.permissionMode
        let rules: [PermissionRule]
        do {
            rules = try await reader.permissionRules(sessionID)
        } catch {
            permissionRulesChecked.remove(sessionID)
            return
        }
        guard byID[sessionID] === session, session.permissionMode == before else { return }
        if let mode = PermissionRules.mode(for: rules) {
            session.permissionMode = mode
        } else if let mode = PermissionRules.outdatedMode(for: rules) {
            session.permissionMode = mode
            do {
                try await engine.setPermissionMode(sessionID, mode: mode)
            } catch {
                permissionRulesChecked.remove(sessionID)
                lastError = "Could not update the permission rules of \(session.title): \(error.localizedDescription)"
            }
        }
    }
}
