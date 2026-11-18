import Foundation

/// A question about a session that is answered from its context without adding anything to it (`/btw`).
/// The session is forked into a hidden temporary session and the question is asked there.
public struct SideQuestion: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// The panel is open and waiting for a question.
        case composing
        /// Copying the session and asking.
        case asking
        case answered
        case failed(String)
    }

    public let id: UUID
    /// The session the question is about.
    public let sourceSessionID: String
    public internal(set) var question: String
    public internal(set) var phase: Phase
    /// The hidden copy the question is asked in, once made.
    public internal(set) var forkSessionID: String?

    public init(id: UUID = UUID(), sourceSessionID: String, question: String = "", phase: Phase = .composing,
                forkSessionID: String? = nil) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.question = question
        self.phase = phase
        self.forkSessionID = forkSessionID
    }

    public var isWorking: Bool { phase == .asking }
}

extension SessionStore {
    /// Sent with the question, ahead of it, so the copy answers from what it knows instead of acting.
    static let sideQuestionInstruction = "The next message is a side question about this conversation. Answer it briefly "
        + "from what you already know. Do not use tools, edit files or run commands."

    // MARK: Availability

    /// Why `/btw` cannot be used in this session, or nil when it can.
    public func sideQuestionUnavailableReason(_ sessionID: String) -> String? {
        guard let session = byID[sessionID] else { return "No session is open" }
        if hiddenSessionIDs.contains(sessionID) { return "This is already a side question" }
        if session.isSubagent { return "Side questions work in top-level sessions, not subagents" }
        guard historyControl != nil else { return "This engine cannot copy a session, which side questions need" }
        if let availability = engine as? any EngineForkAvailability, !availability.canFork(sessionID) {
            return "This session's engine cannot copy a session, which side questions need"
        }
        return nil
    }

    public func canAskSideQuestion(_ sessionID: String) -> Bool { sideQuestionUnavailableReason(sessionID) == nil }

    /// True for the temporary sessions behind side questions (hidden from lists until kept).
    public func isSideQuestionSession(_ sessionID: String) -> Bool { hiddenSessionIDs.contains(sessionID) }

    // MARK: Asking

    /// Opens the side question panel for a session, empty, unless one is already open.
    public func openSideQuestion(for sessionID: String) {
        guard canAskSideQuestion(sessionID), sideQuestions[sessionID] == nil else { return }
        sideQuestions[sessionID] = SideQuestion(sourceSessionID: sessionID)
    }

    /// Asks `question` about the session in a hidden copy of it. The copy runs in Ask mode and any permission prompt
    /// it raises is rejected, so a side question can read the conversation but not act. An earlier side question on
    /// the same session is closed first.
    public func askSideQuestion(_ question: String, about sessionID: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            openSideQuestion(for: sessionID)
            return
        }
        guard byID[sessionID] != nil else { return }
        if let reason = sideQuestionUnavailableReason(sessionID) {
            sideQuestions[sessionID] = SideQuestion(sourceSessionID: sessionID, question: trimmed, phase: .failed(reason))
            return
        }
        guard let history = historyControl else { return }
        if let old = sideQuestions[sessionID], old.forkSessionID != nil { await discardSideSession(old) }
        let entry = SideQuestion(sourceSessionID: sessionID, question: trimmed, phase: .asking)
        sideQuestions[sessionID] = entry

        let info: EngineSession
        do {
            info = try await history.fork(sessionID, atMessageID: nil)
        } catch {
            failSideQuestion(entry.id, on: sessionID, "Could not copy the session: \(error.localizedDescription)")
            return
        }
        rememberSideQuestionCopy(info.id, source: sessionID)
        hiddenSessionIDs.insert(info.id)
        let fork = upsertSession(info)
        fork.permissionMode = .ask
        permissionRulesChecked.insert(fork.id)
        // Closed while the copy was being made: throw the copy away.
        guard sideQuestions[sessionID]?.id == entry.id else {
            await deleteSideSession(info.id)
            return
        }
        sideQuestions[sessionID]?.forkSessionID = info.id
        do {
            // A fork keeps the source's permission mode (Bypass included); the question must not run in it.
            try await engine.setPermissionMode(info.id, mode: .ask)
        } catch {
            failSideQuestion(entry.id, on: sessionID, "Could not set the copy to Ask: \(error.localizedDescription)")
            await deleteSideSession(info.id)
            sideQuestions[sessionID]?.forkSessionID = nil
            return
        }
        try? await engine.renameSession(info.id, title: Self.sideQuestionTitle(trimmed))
        guard sideQuestions[sessionID]?.id == entry.id else {
            await deleteSideSession(info.id)
            return
        }
        var text = trimmed
        do {
            try await engine.injectSynthetic(info.id, text: Self.sideQuestionInstruction, wake: false)
        } catch {
            text = Self.sideQuestionInstruction + "\n\n" + trimmed
        }
        await deliver(text, to: info.id)
        if fork.activity == .failed, sideQuestions[sessionID]?.id == entry.id {
            failSideQuestion(entry.id, on: sessionID, "Could not ask the question")
        }
    }

    /// The answer so far: the copy's replies after the question. `streaming` is true while it is still writing.
    public func sideQuestionAnswer(_ question: SideQuestion) -> (text: String, streaming: Bool) {
        guard let forkID = question.forkSessionID, let fork = byID[forkID] else { return ("", question.isWorking) }
        let afterQuestion = fork.items.lastIndex { if case .user = $0 { true } else { false } }.map { fork.items.index(after: $0) } ?? fork.items.endIndex
        var parts: [String] = []
        var streaming = false
        for item in fork.items[afterQuestion...] {
            if case .agentText(_, let text, _, let isStreaming) = item, !text.isEmpty {
                parts.append(text)
                streaming = streaming || isStreaming
            }
        }
        return (parts.joined(separator: "\n\n"), streaming || fork.isWorking)
    }

    // MARK: Closing and keeping

    /// Closes the panel and deletes the temporary session.
    public func closeSideQuestion(for sessionID: String) async {
        guard let entry = sideQuestions.removeValue(forKey: sessionID) else { return }
        await discardSideSession(entry)
    }

    /// Keeps the temporary session as a normal session (with the source's permission mode, like a fork), closes the
    /// panel and selects the session. Returns it, or nil when there is nothing to keep yet.
    @discardableResult
    public func continueSideQuestion(for sessionID: String) async -> SessionModel? {
        guard let entry = sideQuestions[sessionID], let forkID = entry.forkSessionID, let fork = byID[forkID] else { return nil }
        sideQuestions[sessionID] = nil
        // Forgotten first: a kept session must never be taken for a leftover copy.
        forgetSideQuestionCopy(forkID)
        hiddenSessionIDs.remove(forkID)
        let mode = byID[sessionID]?.permissionMode ?? defaultPermissionMode
        await setPermissionMode(mode, for: forkID)
        await rename(forkID, to: Self.sessionTitle(entry.question))
        select(forkID)
        return fork
    }

    // MARK: Internals

    static func sideQuestionTitle(_ question: String) -> String { "Side question: " + sessionTitle(question) }

    static func sessionTitle(_ question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        return line.count > 60 ? String(line.prefix(57)) + "..." : line
    }

    private func failSideQuestion(_ id: UUID, on sessionID: String, _ message: String) {
        guard sideQuestions[sessionID]?.id == id else { return }
        sideQuestions[sessionID]?.phase = .failed(message)
    }

    private func discardSideSession(_ entry: SideQuestion) async {
        guard let forkID = entry.forkSessionID, hiddenSessionIDs.contains(forkID) else { return }
        await deleteSideSession(forkID)
    }

    private func deleteSideSession(_ forkID: String) async {
        if byID[forkID]?.isWorking == true { try? await engine.interrupt(forkID) }
        do {
            try await engine.deleteSession(forkID)
            removeHiddenSession(forkID)
        } catch {
            // Still hidden; it stays out of the sidebar for this run.
            lastError = "Could not delete the side question's session: \(error.localizedDescription)"
        }
    }

    private func removeHiddenSession(_ forkID: String) {
        forgetSideQuestionCopy(forkID)
        apply(.sessionDeleted(sessionID: forkID))
        hiddenSessionIDs.remove(forkID)
    }

    /// The side question for a temporary session, if it is one.
    private func sideQuestionKey(forFork forkID: String) -> String? {
        sideQuestions.first { $0.value.forkSessionID == forkID }?.key
    }

    /// Follows the temporary sessions: rejects their permission prompts and marks the answer done when the turn ends.
    func sideQuestionDidApply(_ event: EngineEvent) {
        switch event {
        case .permissionAsked(let request):
            let owner = byID[request.sessionID]
            let forkID = hiddenSessionIDs.contains(request.sessionID) ? request.sessionID : owner?.info.parentID
            guard let forkID, hiddenSessionIDs.contains(forkID) else { return }
            Task { [weak self] in await self?.reply(to: request, decision: .reject) }
        case .executionEnded(let sessionID, let outcome, let error):
            guard hiddenSessionIDs.contains(sessionID), let key = sideQuestionKey(forFork: sessionID),
                  sideQuestions[key]?.phase == .asking else { return }
            if let error, !error.isEmpty {
                sideQuestions[key]?.phase = .failed(error)
            } else if outcome == "failed" {
                sideQuestions[key]?.phase = .failed("The answer failed")
            } else {
                sideQuestions[key]?.phase = .answered
            }
        default:
            break
        }
    }
}

// MARK: Copies left by an earlier run

/// One side question's hidden copy, remembered on disk from the moment it is made until it is deleted or kept.
struct SideQuestionCopyRecord: Codable, Hashable, Sendable {
    var id: String
    var sourceSessionID: String
    var created: Date
}

extension SessionStore {
    /// A copy that cannot be found for this long is forgotten (its engine was gone each time the app started).
    static let sideQuestionRecordLifetime: TimeInterval = 30 * 24 * 3600

    /// `~/Library/Application Support/Ensemble/side-question-copies.json` in the app; nothing for the preview engine or
    /// outside an app bundle (test runners), so those never write the app's list.
    nonisolated static func defaultSideQuestionRecordURL(isPreview: Bool, bundle: Bundle = .main) -> URL? {
        guard !isPreview, bundle.bundleURL.pathExtension == "app" else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/side-question-copies.json")
    }

    /// The copies remembered on disk.
    func sideQuestionCopyRecords() -> [SideQuestionCopyRecord] {
        guard let url = sideQuestionRecordURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SideQuestionCopyRecord].self, from: data)) ?? []
    }

    private func writeSideQuestionCopyRecords(_ records: [SideQuestionCopyRecord]) {
        guard let url = sideQuestionRecordURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch {
            lastError = "Could not save the list of side question copies: \(error.localizedDescription)"
        }
    }

    func rememberSideQuestionCopy(_ id: String, source: String) {
        var records = sideQuestionCopyRecords().filter { $0.id != id }
        records.append(SideQuestionCopyRecord(id: id, sourceSessionID: source, created: Date()))
        writeSideQuestionCopyRecords(records)
    }

    func forgetSideQuestionCopy(_ id: String) {
        let records = sideQuestionCopyRecords()
        guard records.contains(where: { $0.id == id }) else { return }
        writeSideQuestionCopyRecords(records.filter { $0.id != id })
    }

    /// Before the first session list: keeps copies left by an earlier run out of the sidebar.
    func hideLeftoverSideQuestionCopies() {
        hiddenSessionIDs.formUnion(sideQuestionCopyRecords().map(\.id))
    }

    /// After the first session list: deletes the copies left by an earlier run. Only sessions whose id is on the list
    /// of copies Ensemble made itself are touched, and a kept copy is taken off that list before it becomes a normal
    /// session. A copy the engines do not list stays on the list (its engine may be offline) until it is too old.
    func deleteLeftoverSideQuestionCopies() async {
        let inUse = Set(sideQuestions.values.compactMap(\.forkSessionID))
        let now = Date()
        for record in sideQuestionCopyRecords() where !inUse.contains(record.id) {
            if let session = byID[record.id], session.info.parentID == nil {
                do {
                    try await engine.deleteSession(record.id)
                    removeHiddenSession(record.id)
                } catch {
                    // Stays hidden and listed; the next start tries again.
                }
            } else if now.timeIntervalSince(record.created) > Self.sideQuestionRecordLifetime {
                forgetSideQuestionCopy(record.id)
                hiddenSessionIDs.remove(record.id)
            }
        }
    }
}
