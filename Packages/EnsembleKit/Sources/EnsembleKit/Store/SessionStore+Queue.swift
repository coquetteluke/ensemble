import Foundation

/// A message you sent while the agent was working. It waits here, shown above the composer, until the turn ends
/// (or you press Send now, edit it, or cancel it).
public struct QueuedMessage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var files: [URL]
    public let created: Date

    public init(id: UUID = UUID(), text: String, files: [URL] = [], created: Date = Date()) {
        self.id = id
        self.text = text
        self.files = files
        self.created = created
    }

    /// The message on one line: its first non-empty line, or the attached file names.
    public var preview: String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        switch (firstLine, names.isEmpty) {
        case (let line?, true): return line
        case (let line?, false): return "\(line) (\(names))"
        case (nil, false): return names
        case (nil, true): return ""
        }
    }
}

/// What Send now does for a session.
public enum SendNowBehavior: Sendable, Equatable {
    /// The session is idle: the message goes out as a normal message.
    case send
    /// The message joins the running turn; the agent keeps going.
    case steer
    /// The engine cannot add to a running turn: the turn is stopped, then the message is sent.
    case stopAndSend

    /// Tooltip for the Send now button.
    public var help: String {
        switch self {
        case .send: "Send this message now"
        case .steer: "Send to the agent now, without stopping its current turn"
        case .stopAndSend: "Stop the current turn and send this message (this engine cannot take messages mid-turn)"
        }
    }
}

/// Bookkeeping for one session's queue (not shown).
struct QueueRuntime {
    /// The last turn was stopped or failed. Held messages then wait for Send now or for the next turn to finish,
    /// instead of going out at once.
    var held = false
    /// A send from the queue is in flight; no second one starts meanwhile.
    var sending = false
    /// The session was working when its last activity arrived (to notice a new turn starting).
    var wasWorking = false
}

/// Messages sent while an agent works: held in order, shown in the queue strip, sent when the turn ends.
/// The state lives here, not in a view, so the iPhone remote can show it too.
extension SessionStore {
    /// How long a finished turn must stay finished before held messages go out. An engine can end one turn and start
    /// a queued one in the same breath (the Claude CLI does after a mid-turn message); the queue waits that out.
    static let queueSettleDelay: Duration = .milliseconds(250)

    /// Messages waiting for a session, oldest first.
    public func queue(for sessionID: String) -> [QueuedMessage] { queues[sessionID] ?? [] }

    /// True when the last turn was stopped or failed, so held messages wait for Send now.
    public func isQueueHeld(_ sessionID: String) -> Bool { queueRuntime[sessionID]?.held ?? false }

    public var steeringControl: (any EngineSteeringControl)? { engine as? any EngineSteeringControl }

    /// How held messages go out when the session's turn ends.
    public func queuedDelivery(for sessionID: String) -> QueuedDelivery {
        steeringControl?.queuedDelivery(for: sessionID) ?? .inOrder
    }

    /// What Send now would do for this session right now.
    public func sendNowBehavior(for sessionID: String) -> SendNowBehavior {
        guard let session = byID[sessionID], session.isWorking else { return .send }
        return steeringControl?.canSteer(sessionID) == true ? .steer : .stopAndSend
    }

    /// Holds the message when the session is working. Returns true when it was held.
    func enqueueIfBusy(_ text: String, files: [URL], to sessionID: String) -> Bool {
        guard let session = byID[sessionID], session.isWorking else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return true }
        queues[sessionID, default: []].append(QueuedMessage(text: trimmed, files: files))
        return true
    }

    /// Drops a held message.
    public func cancelQueued(_ messageID: UUID, in sessionID: String) {
        _ = takeQueued(messageID, in: sessionID)
    }

    /// Removes a held message and returns it, so the composer can put it back in the box for editing.
    @discardableResult
    public func takeQueued(_ messageID: UUID, in sessionID: String) -> QueuedMessage? {
        guard var list = queues[sessionID], let index = list.firstIndex(where: { $0.id == messageID }) else { return nil }
        let message = list.remove(at: index)
        queues[sessionID] = list.isEmpty ? nil : list
        return message
    }

    /// Sends one held message now. While the agent works it joins the running turn when the engine allows that
    /// (the agent reads it after the tool calls in flight); otherwise the turn is stopped and the message sent.
    public func sendNow(_ messageID: UUID, in sessionID: String) async {
        guard let session = byID[sessionID], let message = takeQueued(messageID, in: sessionID) else { return }
        switch sendNowBehavior(for: sessionID) {
        case .send:
            await deliver(message.text, files: message.files, to: sessionID)

        case .steer:
            guard let control = steeringControl else { return }
            let item = TranscriptItem.user(id: "user-\(UUID().uuidString)", text: Self.shownText(message.text, files: message.files), date: Date())
            session.items.append(item)
            session.info.updated = Date()
            session.touch()
            do {
                try await control.steer(sessionID, text: message.text, files: message.files)
            } catch {
                session.items.removeAll { $0.id == item.id }
                session.touch()
                queues[sessionID, default: []].insert(message, at: 0)
                lastError = "Could not send: \(error.localizedDescription)"
            }

        case .stopAndSend:
            queueRuntime[sessionID, default: QueueRuntime()].sending = true
            defer { queueRuntime[sessionID]?.sending = false }
            do {
                try await engine.interrupt(sessionID)
            } catch {
                queues[sessionID, default: []].insert(message, at: 0)
                lastError = "Could not stop the agent: \(error.localizedDescription)"
                return
            }
            await waitUntilIdle(sessionID, timeout: .seconds(10))
            // Let the stopped turn's last events land first, so they cannot mark the new turn idle.
            try? await Task.sleep(for: Self.queueSettleDelay)
            await deliver(message.text, files: message.files, to: sessionID)
        }
    }

    /// The text shown in the transcript for a message with attachments.
    static func shownText(_ text: String, files: [URL]) -> String {
        guard !files.isEmpty else { return text }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        return text.isEmpty ? "Attached: \(names)" : "\(text)\n\nAttached: \(names)"
    }

    /// Stops held messages from going out on their own (the user stopped the turn). It holds whether or not the
    /// session already shows as working: the turn's first events may not have arrived yet. Only a message that is
    /// actually sent (`deliver`, which Send now uses) releases it.
    func holdQueue(_ sessionID: String) {
        queueRuntime[sessionID, default: QueueRuntime()].held = true
    }

    /// Runs after every live event (`apply`): the queue and side questions follow the turns.
    func afterApply(_ event: EngineEvent) {
        queueDidApply(event)
        sideQuestionDidApply(event)
    }

    /// Follows turns: a stopped or failed turn holds the queue, a finished one sends what is waiting.
    func queueDidApply(_ event: EngineEvent) {
        switch event {
        case .executionEnded(let sessionID, let outcome, let error):
            if outcome == "interrupted" || outcome == "failed" || error?.isEmpty == false {
                queueRuntime[sessionID, default: QueueRuntime()].held = true
            }
        case .activity(let sessionID, let activity):
            var runtime = queueRuntime[sessionID] ?? QueueRuntime()
            let working = activity == .working || activity == .waitingForPermission
            // A hold is never released here: a late event from the stopped turn would look like a new turn starting.
            if activity == .failed { runtime.held = true }
            runtime.wasWorking = working
            queueRuntime[sessionID] = runtime
            if activity == .idle, queues[sessionID]?.isEmpty == false { scheduleDrain(sessionID) }
        default:
            break
        }
    }

    private func scheduleDrain(_ sessionID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.queueSettleDelay)
            await self?.drainQueue(sessionID)
        }
    }

    /// Sends what is waiting once the session is idle: all of it as one message, or the oldest one, per engine.
    func drainQueue(_ sessionID: String) async {
        guard let session = byID[sessionID], session.activity == .idle,
              let list = queues[sessionID], !list.isEmpty else { return }
        let runtime = queueRuntime[sessionID] ?? QueueRuntime()
        guard !runtime.held, !runtime.sending else { return }
        let batch = queuedDelivery(for: sessionID) == .combined ? list : [list[0]]
        let rest = Array(list.dropFirst(batch.count))
        queues[sessionID] = rest.isEmpty ? nil : rest
        let text = batch.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let files = batch.flatMap(\.files)
        queueRuntime[sessionID, default: QueueRuntime()].sending = true
        await deliver(text, files: files, to: sessionID)
        queueRuntime[sessionID]?.sending = false
    }

    /// Waits until the session stops working, or the timeout passes.
    func waitUntilIdle(_ sessionID: String, timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while let session = byID[sessionID], session.isWorking, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
