import Foundation

// The transcript with each message's files beside it (`EngineMessageAttachments`): the same request as `transcript`,
// mapped so a file is an attachment instead of an "Attached: name" line.
extension OpenCodeClient: EngineMessageAttachments {
    public func attachedTranscript(_ sessionID: String) async throws -> AttachedTranscript {
        async let boundary = try? stagedRevertMessageID(sessionID)
        let all = try await messages(sessionID)
        return TranscriptMapper.attached(from: Self.hidingStagedRevert(all, boundary: await boundary ?? nil))
    }
}
