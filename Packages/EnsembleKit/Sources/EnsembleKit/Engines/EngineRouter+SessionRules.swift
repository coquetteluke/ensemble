import Foundation

// Forwards `EngineSessionRulesReading` (Store/SessionStore+Permissions.swift) so the store's launch-time permission
// check keeps working for OpenCode sessions behind the router. Kept in its own file because that protocol is new;
// delete this file if the protocol moves or is renamed.
extension EngineRouter: EngineSessionRulesReading {
    public func permissionRules(_ sessionID: String) async throws -> [PermissionRule] {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        guard let reader = registration.engine as? any EngineSessionRulesReading else {
            throw EngineRouterError.notSupported(engine: registration.name, feature: "report their permission rules")
        }
        return try await reader.permissionRules(sessionID)
    }
}
