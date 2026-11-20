import Foundation

/// Rewind with choices (`RewindModels.swift`): the sheet's plan, the rewind itself, and the notice with Redo.
extension SessionStore {
    public var rewindControl: (any EngineRewindControl)? { engine as? any EngineRewindControl }

    // MARK: Sheet

    /// Opens the rewind sheet for one of your messages and reads what a rewind to before it would change.
    public func beginRewind(_ sessionID: String, messageID: String) {
        guard let session = byID[sessionID] else { return }
        let text = session.items.compactMap { item -> String? in
            if case .user(let id, let text, _) = item, id == messageID { return text }
            return nil
        }.first ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        rewinds.planTask?.cancel()
        let request = RewindRequest(sessionID: sessionID, messageID: messageID, messageText: firstLine)
        rewinds.request = request
        rewinds.planTask = Task { [weak self] in await self?.loadRewindPlan(request.id) }
    }

    /// Opens the sheet for your newest message (`/rewind`). False when there is none.
    @discardableResult
    public func beginRewindOfLastMessage(_ sessionID: String) -> Bool {
        guard let session = byID[sessionID],
              let last = session.items.last(where: { if case .user = $0 { true } else { false } }) else { return false }
        beginRewind(sessionID, messageID: last.id)
        return true
    }

    func loadRewindPlan(_ requestID: String) async {
        guard let request = rewinds.request, request.id == requestID,
              let session = byID[primarySessionID(for: request.sessionID)] else { return }
        if threadLinks.hasLinks(for: session.id) {
            let plan = RewindPlan.unavailable("Rewind is not available after switching engines in a thread.")
            rewinds.request?.phase = .ready(plan)
            rewinds.request?.selected = plan.defaultScope
            return
        }
        let plan: RewindPlan
        do {
            guard let engineID = try await engineMessageID(for: request.messageID, in: session) else {
                throw RewindStoreError.messageNotFound
            }
            if let control = rewindControl {
                plan = try await control.rewindPlan(session.id, toBeforeMessageID: engineID)
            } else if let history = historyControl {
                plan = .basic(restoresFiles: history.rewindRestoresFiles,
                              messagesRemoved: EngineRouter.userMessages(in: session.items, from: request.messageID))
            } else {
                plan = .unavailable("This engine cannot rewind")
            }
        } catch {
            guard !Task.isCancelled, rewinds.request?.id == requestID else { return }
            rewinds.request?.phase = .failed("Could not read what a rewind would change: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled, rewinds.request?.id == requestID else { return }
        rewinds.request?.phase = .ready(plan)
        rewinds.request?.selected = plan.defaultScope
    }

    /// Picks a choice in the open sheet (unavailable ones are ignored).
    public func selectRewindScope(_ scope: RewindScope) {
        guard let plan = rewinds.request?.plan, plan.choice(scope).isAvailable, rewinds.request?.isWorking == false else { return }
        rewinds.request?.selected = scope
        rewinds.request?.error = nil
    }

    /// Closes the sheet without rewinding.
    public func cancelRewind() {
        guard rewinds.request?.isWorking != true else { return }
        rewinds.planTask?.cancel()
        rewinds.planTask = nil
        rewinds.request = nil
    }

    /// Why the sheet's Rewind button is off, or nil when it can rewind.
    public func rewindConfirmUnavailableReason() -> String? {
        guard let request = rewinds.request else { return "Nothing to rewind" }
        let primaryID = primarySessionID(for: request.sessionID)
        if threadLinks.hasLinks(for: primaryID) {
            return "Rewind is not available after switching engines in a thread."
        }
        if let session = byID[primaryID], session.isWorking { return RewindReason.working }
        guard let plan = request.plan else { return nil }
        guard let scope = request.selected else { return "Choose what to rewind" }
        return plan.choice(scope).unavailableReason
    }

    /// Rewinds with the sheet's choice. Closes the sheet when it worked; otherwise the sheet shows why.
    @discardableResult
    public func confirmRewind() async -> Bool {
        guard let request = rewinds.request, case .ready(let plan) = request.phase, let scope = request.selected,
              let session = byID[primarySessionID(for: request.sessionID)] else { return false }
        if let reason = rewindConfirmUnavailableReason() {
            rewinds.request?.error = reason
            if threadLinks.hasLinks(for: session.id) { lastError = reason }
            return false
        }
        rewinds.request?.phase = .working(plan, scope)
        rewinds.request?.error = nil
        do {
            guard let engineID = try await engineMessageID(for: request.messageID, in: session) else {
                throw RewindStoreError.messageNotFound
            }
            let outcome: RewindOutcome
            if let control = rewindControl {
                outcome = try await control.rewind(session.id, toBeforeMessageID: engineID, scope: scope)
            } else if let history = historyControl {
                try await history.rewind(session.id, toBeforeMessageID: engineID)
                outcome = RewindOutcome(scope: scope, messagesRemoved: plan.messagesRemoved, canRedo: false)
            } else {
                throw RewindStoreError.notSupported
            }
            await finishRewind(session, outcome: outcome)
            if rewinds.request?.id == request.id { rewinds.request = nil }
            return true
        } catch {
            if rewinds.request?.id == request.id {
                rewinds.request?.phase = .ready(plan)
                rewinds.request?.error = "Could not rewind: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// Reloads what changed and leaves the notice at the end of the transcript.
    private func finishRewind(_ session: SessionModel, outcome: RewindOutcome) async {
        for (id, notice) in rewinds.notices where notice.sessionID == session.id { rewinds.notices[id]?.superseded = true }
        if outcome.scope.removesMessages {
            if let pending = try? await engine.pendingPermissions() {
                session.pendingPermissions = pending.filter { primarySessionID(for: $0.sessionID) == session.id }
            }
            session.transcriptLoaded = false
            await loadSession(session.id)
        } else {
            await refreshPanels(session.id)
        }
        let notice = RewindNotice(id: RewindNotice.makeID(), sessionID: session.id, outcome: outcome)
        rewinds.notices[notice.id] = notice
        session.items.append(.notice(id: notice.id, text: notice.text))
        session.touch()
    }

    // MARK: Notice and Redo

    /// The rewind notice behind a transcript row, if it is one.
    public func rewindNotice(forItem itemID: String) -> RewindNotice? { rewinds.notices[itemID] }

    /// Why Redo is off for a notice, or nil when it can run. Nil is also returned for engines without Redo; check
    /// `outcome.canRedo` to show the button at all.
    public func redoUnavailableReason(_ notice: RewindNotice) -> String? {
        if notice.superseded { return "A later rewind replaced this one" }
        guard let session = byID[notice.sessionID] else { return "The session is gone" }
        if session.isWorking { return RewindReason.working }
        if let index = session.items.firstIndex(where: { $0.id == notice.id }),
           session.items[(index + 1)...].contains(where: { if case .user = $0 { true } else { false } }) {
            return "The conversation has moved on since"
        }
        return nil
    }

    /// Undoes the rewind behind a notice: the conversation and files go back to how they were before it.
    public func redoRewind(noticeID: String) async {
        guard let notice = rewinds.notices[noticeID], notice.state == .done, notice.outcome.canRedo,
              redoUnavailableReason(notice) == nil, let control = rewindControl,
              let session = byID[notice.sessionID] else { return }
        rewinds.notices[noticeID]?.state = .redoing
        rewinds.notices[noticeID]?.error = nil
        do {
            try await control.redoRewind(notice.sessionID)
            rewinds.notices[noticeID]?.state = .redone
            let text = rewinds.notices[noticeID]?.text ?? notice.text
            if notice.outcome.scope.removesMessages {
                session.transcriptLoaded = false
                await loadSession(session.id)
                session.items.append(.notice(id: noticeID, text: text))
            } else {
                if let index = session.items.firstIndex(where: { $0.id == noticeID }) {
                    session.items[index] = .notice(id: noticeID, text: text)
                }
                await refreshPanels(session.id)
            }
            session.touch()
        } catch {
            rewinds.notices[noticeID]?.state = .done
            rewinds.notices[noticeID]?.error = "Could not undo the rewind: \(error.localizedDescription)"
        }
    }
}

enum RewindStoreError: Error, LocalizedError {
    case messageNotFound
    case notSupported

    var errorDescription: String? {
        switch self {
        case .messageNotFound: "That message is not in the session's history yet."
        case .notSupported: "This engine cannot rewind."
        }
    }
}
