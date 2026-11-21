import Foundation

// Forwards `EngineMessageAttachments` (`Engines/MessagePictureCache.swift`) to the engine that owns the session. An
// engine without it answers with its plain transcript and no attachments.
extension EngineRouter: EngineMessageAttachments {
    public func attachedTranscript(_ sessionID: String) async throws -> AttachedTranscript {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        if let source = registration.engine as? any EngineMessageAttachments {
            return try await source.attachedTranscript(sessionID)
        }
        return AttachedTranscript(items: try await registration.engine.transcript(sessionID))
    }
}
