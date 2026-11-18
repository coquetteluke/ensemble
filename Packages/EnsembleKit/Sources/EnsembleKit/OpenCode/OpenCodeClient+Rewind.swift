import Foundation

// MARK: Rewind with choices

/// OpenCode's revert API, as checked against the running 2.3.0 service:
/// - `POST /api/session/{id}/revert/stage` with `messageID` and `files` puts a reversible boundary at that message.
///   With `files: true` the files go back to how they were before it, and the answer's `files` lists each change as
///   the revert makes it (a file the agent created comes back `deleted`). With `files: false` only the conversation
///   goes back. Staging again moves the boundary.
/// - While staged, `GET .../message` still lists every message; `Session.revert.messageID` says where the boundary is,
///   so the transcript hides that message and every later one (`OpenCodeClient.transcript`).
/// - `DELETE /api/session/{id}/revert` clears the boundary and puts the files back as they were (Redo).
/// - The next prompt commits a staged revert: the hidden messages are removed for good and the files stay.
/// - `GET .../diff?from=&to=` lists the files a range of turns changed, as the agent changed them; the plan reverses it.
/// - There is no way to put files back and keep the conversation, and compaction always covers the whole session.
extension OpenCodeClient: EngineRewindControl {
    static let codeOnlyReason = "OpenCode puts files back only together with the conversation"
    static let summaryReason = "OpenCode can summarize only the whole conversation (/compact)"

    public func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan {
        let users = try await visibleUserMessageIDs(sessionID)
        guard let index = users.firstIndex(of: messageID) else {
            throw OpenCodeError.invalidArgument("Message \(messageID) is not in session \(sessionID).")
        }
        var query = [URLQueryItem(name: "from", value: messageID), URLQueryItem(name: "context", value: "3")]
        if let last = users.last, last != messageID { query.insert(URLQueryItem(name: "to", value: last), at: 1) }
        let diff: Wire.DataEnvelope<[Wire.Lossy<Wire.FileDiff>]> = try await get("/api/session/\(sessionID)/diff", query: query)
        let files = diff.data.compactMap(\.value).map { FileChange(wire: $0).reversed }
        return RewindPlan(choices: [
            RewindChoice(.codeAndConversation),
            RewindChoice(.conversationOnly),
            RewindChoice(.codeOnly, unavailableReason: Self.codeOnlyReason),
            RewindChoice(.summarizeFromHere, unavailableReason: Self.summaryReason),
        ], files: files, filesKnown: true, messagesRemoved: users.count - index, canRedo: true)
    }

    /// Stages the revert and leaves it staged, so `redoRewind` can clear it until the next prompt commits it.
    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome {
        switch scope {
        case .codeAndConversation, .conversationOnly:
            let users = try await visibleUserMessageIDs(sessionID)
            guard let index = users.firstIndex(of: messageID) else {
                throw OpenCodeError.invalidArgument("Message \(messageID) is not in session \(sessionID).")
            }
            let restore = scope == .codeAndConversation
            let response: Wire.DataEnvelope<RevertWire> = try await send(
                "POST", "/api/session/\(sessionID)/revert/stage",
                body: ["messageID": .string(messageID), "files": .bool(restore)])
            // The answer lists each change as the revert made it; the patches are not kept.
            let files = restore ? (response.data.files ?? []).compactMap(\.value).map { wire -> FileChange in
                var change = FileChange(wire: wire)
                change.diff = nil
                return change
            } : []
            return RewindOutcome(scope: scope, files: files, messagesRemoved: users.count - index, canRedo: true)
        case .codeOnly:
            throw OpenCodeError.invalidArgument(Self.codeOnlyReason)
        case .summarizeFromHere:
            throw OpenCodeError.invalidArgument(Self.summaryReason)
        }
    }

    public func redoRewind(_ sessionID: String) async throws {
        guard try await stagedRevertMessageID(sessionID) != nil else {
            throw OpenCodeError.invalidArgument("There is no rewind to undo in this session.")
        }
        try await sendIgnoringBody("DELETE", "/api/session/\(sessionID)/revert")
    }

    // MARK: Helpers

    struct RevertWire: Decodable {
        let messageID: String?
        let files: [Wire.Lossy<Wire.FileDiff>]?
    }

    private struct SessionRevertWire: Decodable {
        let revert: RevertWire?
    }

    /// The message a staged revert hides from, or nil when none is staged.
    func stagedRevertMessageID(_ sessionID: String) async throws -> String? {
        let response: Wire.DataEnvelope<SessionRevertWire> = try await get("/api/session/\(sessionID)")
        return response.data.revert?.messageID
    }

    /// Your messages before any staged revert, oldest first.
    func visibleUserMessageIDs(_ sessionID: String) async throws -> [String] {
        async let boundary = stagedRevertMessageID(sessionID)
        let ids = try await messages(sessionID, type: "user").map(\.id)
        guard let staged = try await boundary, let cut = ids.firstIndex(of: staged) else { return ids }
        return Array(ids[..<cut])
    }

    /// Messages with a staged revert's hidden part left out (the boundary message and everything after it).
    static func hidingStagedRevert(_ messages: [Wire.Message], boundary: String?) -> [Wire.Message] {
        guard let boundary, let cut = messages.firstIndex(where: { $0.id == boundary }) else { return messages }
        return Array(messages[..<cut])
    }
}
