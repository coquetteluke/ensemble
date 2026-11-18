import Foundation

/// Plan limit stops and auto-continue (`AutoContinue.swift`).
extension SessionStore {
    /// The text auto-continue sends.
    public static let autoContinueText = "Continue"

    /// The limit stop shown in place of a transcript error row, if that row is one.
    public func usageLimitStop(forItem itemID: String) -> UsageLimitStop? { background.limitStops[itemID] }

    /// The card's switch.
    public func setAutoContinue(_ on: Bool, forItem itemID: String) {
        guard background.limitStops[itemID]?.state == .waiting else { return }
        background.limitStops[itemID]?.autoContinue = on
        rescheduleAutoContinueTimer()
    }

    /// Sends "Continue" to every session whose limit has reset (a minute ago or more), whose switch is on and which is
    /// idle. Each stop sends at most once. Returns the sessions it sent to.
    @discardableResult
    public func checkAutoContinue() async -> [String] {
        let now = background.now()
        var sent: [String] = []
        for stop in background.limitStops.values.sorted(by: { $0.id < $1.id }) where stop.isDue(at: now) {
            guard let session = byID[stop.sessionID], !session.isWorking else { continue }
            background.limitStops[stop.id]?.state = .sent
            background.limitStops[stop.id]?.sentAt = now
            sent.append(stop.sessionID)
            await send(Self.autoContinueText, to: stop.sessionID)
        }
        rescheduleAutoContinueTimer()
        return sent
    }

    /// Call when the Mac wakes: a reset that passed during sleep continues now.
    @discardableResult
    public func autoContinueAfterWake() async -> [String] {
        await checkAutoContinue()
    }

    /// Adds a limit stop without an engine (previews and snapshots). Nothing is scheduled.
    public func seedUsageLimitStop(_ stop: UsageLimitStop) {
        background.limitStops[stop.id] = stop
    }

    // MARK: Following turns

    func autoContinueDidApply(_ event: EngineEvent) {
        switch event {
        case .executionEnded(let sessionID, let outcome, let error):
            guard let session = byID[sessionID], !session.isSubagent else { return }
            guard outcome == "failed" || error?.isEmpty == false else { return }
            let message = error ?? ""
            // The store has just added the error row for this failure.
            let itemID = session.items.last { if case .error = $0 { true } else { false } }?.id
            guard let itemID else { return }
            if UsageLimitText.isUsageLimit(message) {
                registerLimitStop(itemID: itemID, sessionID: sessionID,
                                  info: UsageLimitInfo(resetsAt: UsageLimitText.legacyResetDate(message), message: message))
            }
            if let reporter = engine as? any EngineUsageLimitReporting {
                Task { [weak self] in
                    guard let info = await reporter.usageLimitStop(sessionID) else { return }
                    self?.registerLimitStop(itemID: itemID, sessionID: sessionID, info: info)
                }
            }
        case .activity(let sessionID, let activity) where activity == .working || activity == .waitingForPermission:
            supersedeLimitStops(for: sessionID)
        default:
            break
        }
    }

    /// Adds a limit stop for an error row, or fills in what the engine knows about one added from its text.
    func registerLimitStop(itemID: String, sessionID: String, info: UsageLimitInfo) {
        if var existing = background.limitStops[itemID] {
            guard existing.state == .waiting else { return }
            if let resetsAt = info.resetsAt { existing.resetsAt = resetsAt }
            if let window = info.window { existing.window = window }
            background.limitStops[itemID] = existing
        } else {
            // A newer stop replaces older ones that still wait.
            supersedeLimitStops(for: sessionID)
            let message = info.message ?? byID[sessionID]?.items.first { $0.id == itemID }.flatMap { item -> String? in
                if case .error(_, let text) = item { text } else { nil }
            } ?? ""
            // An engine answer that arrives after a new turn started only draws the card; it sends nothing.
            let state: UsageLimitStop.State = byID[sessionID]?.isWorking == true ? .superseded : .waiting
            background.limitStops[itemID] = UsageLimitStop(id: itemID, sessionID: sessionID, resetsAt: info.resetsAt,
                                                           window: info.window, message: message, state: state)
        }
        rescheduleAutoContinueTimer()
    }

    /// Marks a session's waiting stops as replaced by a newer turn.
    func supersedeLimitStops(for sessionID: String) {
        for (id, stop) in background.limitStops where stop.sessionID == sessionID && stop.state == .waiting {
            background.limitStops[id]?.state = .superseded
        }
    }

    // MARK: Timer

    /// The next time a stop is due.
    var nextAutoContinueDate: Date? {
        background.limitStops.values.filter { $0.state == .waiting && $0.autoContinue }.compactMap(\.continueAt).min()
    }

    /// Sleeps until the next stop is due, but never more than a minute, so a changed clock or a sleep that swallowed the
    /// timer is caught within a minute even without the wake notification.
    func rescheduleAutoContinueTimer() {
        background.timer?.cancel()
        background.timer = nil
        guard background.timerEnabled, let next = nextAutoContinueDate else { return }
        let delay = min(max(next.timeIntervalSince(background.now()), 0.5), 60)
        background.timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // Cleared first, so the reschedule inside the check does not cancel this task while it sends.
            self.background.timer = nil
            await self.checkAutoContinue()
        }
    }
}
