import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// The preview engine with every call forwarded, so a test engine can add or leave out optional abilities.
protocol PreviewForwarding: OpenCodeAPI {
    var base: PreviewEngine { get }
}

extension PreviewForwarding {
    func serverInfo() async throws -> (version: String, url: URL) { try await base.serverInfo() }
    func listSessions() async throws -> [EngineSession] { try await base.listSessions() }
    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession {
        try await base.createSession(directory: directory, model: model, agent: agent, permissionMode: permissionMode, parentID: parentID)
    }
    func deleteSession(_ sessionID: String) async throws { try await base.deleteSession(sessionID) }
    func renameSession(_ sessionID: String, title: String) async throws { try await base.renameSession(sessionID, title: title) }
    func setArchived(_ sessionID: String, archived: Bool) async throws { try await base.setArchived(sessionID, archived: archived) }
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { try await base.setPermissionMode(sessionID, mode: mode) }
    func switchModel(_ sessionID: String, model: ModelRef) async throws { try await base.switchModel(sessionID, model: model) }
    func transcript(_ sessionID: String) async throws -> [TranscriptItem] { try await base.transcript(sessionID) }
    func children(_ sessionID: String) async throws -> [EngineSession] { try await base.children(sessionID) }
    func prompt(_ sessionID: String, text: String, files: [URL]) async throws { try await base.prompt(sessionID, text: text, files: files) }
    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws { try await base.injectSynthetic(sessionID, text: text, wake: wake) }
    func interrupt(_ sessionID: String) async throws { try await base.interrupt(sessionID) }
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await base.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision, message: message)
    }
    func pendingPermissions() async throws -> [PermissionRequest] { try await base.pendingPermissions() }
    func context(_ sessionID: String) async throws -> ContextBreakdown { try await base.context(sessionID) }
    func changedFiles(_ sessionID: String) async throws -> [FileChange] { try await base.changedFiles(sessionID) }
    func connectors() async throws -> [ConnectorInfo] { try await base.connectors() }
    func models() async throws -> [ModelInfo] { try await base.models() }
    func providers() async throws -> [ProviderInfo] { try await base.providers() }
    func setAPIKey(providerID: String, key: String) async throws { try await base.setAPIKey(providerID: providerID, key: key) }
    func removeAPIKey(providerID: String) async throws { try await base.removeAPIKey(providerID: providerID) }
    func schedules() async throws -> [ScheduleInfo] { try await base.schedules() }
    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        try await base.createSchedule(title: title, prompt: prompt, directory: directory, schedule: schedule, model: model)
    }
    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { try await base.setSchedulePaused(scheduleID, paused: paused) }
    func deleteSchedule(_ scheduleID: String) async throws { try await base.deleteSchedule(scheduleID) }
    func events() -> AsyncStream<EngineEvent> { base.events() }
}

/// An engine that can steer (or not), with a chosen queue delivery, and that records what it was asked to send.
final class SteeringTestEngine: PreviewForwarding, EngineSteeringControl, EngineHistoryControl, EngineForkAvailability, Sendable {
    let base: PreviewEngine
    let delivery: QueuedDelivery
    let steerable: Bool
    let forkable: Bool
    /// Making a copy waits until this opens, so a test can act while it is still in progress.
    let forkGate: TestGate
    private let log = Mutex<[String]>([])

    init(delivery: QueuedDelivery = .inOrder, steerable: Bool = true, forkable: Bool = true, delayScale: Double = 0.1,
         holdForks: Bool = false) {
        base = PreviewEngine(seed: PreviewData.seed(), delayScale: delayScale)
        self.delivery = delivery
        self.steerable = steerable
        self.forkable = forkable
        forkGate = TestGate(open: !holdForks)
    }

    var calls: [String] { log.withLock { $0 } }
    /// When true, deleting a session fails (an engine that is down).
    let failDeletes = Mutex(false)

    func deleteSession(_ sessionID: String) async throws {
        log.withLock { $0.append("delete:\(sessionID)") }
        if failDeletes.withLock({ $0 }) { throw PreviewEngine.PreviewError.unknownSession(sessionID) }
        try await base.deleteSession(sessionID)
    }

    func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        log.withLock { $0.append("prompt:\(text)") }
        try await base.prompt(sessionID, text: text, files: files)
    }

    func interrupt(_ sessionID: String) async throws {
        log.withLock { $0.append("interrupt") }
        try await base.interrupt(sessionID)
    }

    func steer(_ sessionID: String, text: String, files: [URL]) async throws {
        log.withLock { $0.append("steer:\(text)") }
    }

    func canSteer(_ sessionID: String) -> Bool { steerable }
    func queuedDelivery(for sessionID: String) -> QueuedDelivery { delivery }
    func canFork(_ sessionID: String) -> Bool { forkable }

    var rewindRestoresFiles: Bool { false }
    func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        await forkGate.wait()
        return try await base.fork(sessionID, atMessageID: messageID)
    }
    func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws {
        try await base.rewind(sessionID, toBeforeMessageID: messageID)
    }
}

/// An engine with no optional abilities at all (no steering, no fork).
final class PlainTestEngine: PreviewForwarding, Sendable {
    let base = PreviewEngine(seed: PreviewData.seed(), delayScale: 0.1)
}

@MainActor
@Suite("Composer queue and side questions", .serialized)
struct ComposerQueueTests {
    func started(_ engine: any OpenCodeAPI) async throws -> (SessionStore, SessionModel) {
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/queue-demo", model: nil, permissionMode: .bypass)
        return (store, session)
    }

    func userTexts(_ session: SessionModel) -> [String] {
        session.items.compactMap { if case .user(_, let text, _) = $0 { text } else { nil } }
    }

    // MARK: Queue

    @Test func messagesSentWhileWorkingWaitAndGoOutInOrder() async throws {
        let engine = SteeringTestEngine(delivery: .inOrder)
        let (store, session) = try await started(engine)
        await store.send("First task", to: session.id)
        #expect(session.isWorking)
        await store.send("Second", to: session.id)
        await store.send("  Third\n", files: [URL(fileURLWithPath: "/tmp/notes.md")], to: session.id)

        #expect(store.queue(for: session.id).map(\.text) == ["Second", "Third"])
        #expect(store.queue(for: session.id).last?.preview == "Third (notes.md)")
        #expect(userTexts(session) == ["First task"], "held messages are not in the transcript yet")
        #expect(engine.calls == ["prompt:First task"])

        try await waitUntil("both held messages to go out") { userTexts(session).count == 3 && !session.isWorking }
        #expect(userTexts(session) == ["First task", "Second", "Third"], "the row shows what was typed")
        let thirdRow = session.items.compactMap { item -> String? in
            if case .user(let id, "Third", _) = item { return id }
            return nil
        }.first
        #expect(thirdRow.flatMap { session.attachments[$0] }?.map(\.name) == ["notes.md"], "the file hangs on its row")
        #expect(engine.calls == ["prompt:First task", "prompt:Second", "prompt:Third"], "one prompt per turn, oldest first")
        #expect(store.queue(for: session.id).isEmpty)
    }

    @Test func combinedDeliverySendsOneMessage() async throws {
        let engine = SteeringTestEngine(delivery: .combined)
        let (store, session) = try await started(engine)
        await store.send("Build the panel", to: session.id)
        await store.send("Also add tests", to: session.id)
        await store.send("And update the README", to: session.id)
        #expect(store.queuedDelivery(for: session.id) == .combined)
        try await waitUntil("the combined message") { userTexts(session).count == 2 && !session.isWorking }
        #expect(engine.calls == ["prompt:Build the panel", "prompt:Also add tests\n\nAnd update the README"])
        #expect(store.queue(for: session.id).isEmpty)
    }

    @Test func idleSessionsSendStraightAway() async throws {
        let (store, session) = try await started(SteeringTestEngine())
        await store.send("Hello", to: session.id)
        #expect(store.queue(for: session.id).isEmpty)
        #expect(userTexts(session) == ["Hello"])
        #expect(store.sendNowBehavior(for: session.id) == .steer)
        try await waitUntil("the turn to end") { !session.isWorking }
        #expect(store.sendNowBehavior(for: session.id) == .send)
    }

    @Test func stoppingTheTurnHoldsTheQueue() async throws {
        let engine = SteeringTestEngine(delayScale: TestWait.longTurnScale)
        let (store, session) = try await started(engine)
        await store.send("Long task", to: session.id)
        await store.send("Follow up", to: session.id)
        await store.stop()
        try await waitUntil("the interrupt") { !session.isWorking }
        // Nothing announces that the store chose not to send, so give a wrong send well past the store's settle delay
        // to show up.
        try await Task.sleep(for: SessionStore.queueSettleDelay * 2 + .milliseconds(100))
        #expect(store.queue(for: session.id).map(\.text) == ["Follow up"], "a stopped turn does not send what is waiting")
        #expect(store.isQueueHeld(session.id))
        #expect(!engine.calls.contains("prompt:Follow up"))

        // Send now on an idle session is a plain send, and the hold is released.
        let held = try #require(store.queue(for: session.id).first)
        await store.sendNow(held.id, in: session.id)
        #expect(engine.calls.last == "prompt:Follow up")
        #expect(!store.isQueueHeld(session.id))
        #expect(store.queue(for: session.id).isEmpty)
    }

    @Test func aLateWorkingEventAfterStopKeepsTheHold() async throws {
        let engine = SteeringTestEngine(delayScale: TestWait.longTurnScale)
        let (store, session) = try await started(engine)
        await store.send("Long task", to: session.id)
        await store.send("Follow up", to: session.id)
        #expect(store.queue(for: session.id).map(\.text) == ["Follow up"])
        await store.stop()
        try await waitUntil("the interrupt") { !session.isWorking }
        // A late event from the stopped turn looks like a new turn starting and ending; it must not release the hold.
        store.apply(.activity(sessionID: session.id, .working))
        store.apply(.activity(sessionID: session.id, .idle))
        try await Task.sleep(for: SessionStore.queueSettleDelay * 2 + .milliseconds(100))
        #expect(store.isQueueHeld(session.id))
        #expect(store.queue(for: session.id).map(\.text) == ["Follow up"])
        #expect(!engine.calls.contains("prompt:Follow up"))
    }

    @Test func sendNowSteersTheRunningTurn() async throws {
        let engine = SteeringTestEngine(delayScale: TestWait.longTurnScale)
        let (store, session) = try await started(engine)
        await store.send("Long task", to: session.id)
        await store.send("Use the new API instead", to: session.id)
        await store.send("Keep this one queued", to: session.id)
        #expect(store.sendNowBehavior(for: session.id) == .steer)
        let message = try #require(store.queue(for: session.id).first)
        await store.sendNow(message.id, in: session.id)
        #expect(engine.calls == ["prompt:Long task", "steer:Use the new API instead"], "the turn keeps going")
        #expect(session.isWorking)
        #expect(userTexts(session) == ["Long task", "Use the new API instead"])
        #expect(store.queue(for: session.id).map(\.text) == ["Keep this one queued"])
        await store.stop()
    }

    @Test func sendNowStopsAndSendsWhenTheEngineCannotSteer() async throws {
        let engine = SteeringTestEngine(steerable: false, delayScale: TestWait.longTurnScale)
        let (store, session) = try await started(engine)
        await store.send("Long task", to: session.id)
        await store.send("Change of plan", to: session.id)
        #expect(store.sendNowBehavior(for: session.id) == .stopAndSend)
        #expect(SendNowBehavior.stopAndSend.help.contains("Stop the current turn"))
        let message = try #require(store.queue(for: session.id).first)
        await store.sendNow(message.id, in: session.id)
        #expect(engine.calls == ["prompt:Long task", "interrupt", "prompt:Change of plan"])
        #expect(userTexts(session) == ["Long task", "Change of plan"])
        #expect(session.items.contains { if case .notice(_, "Interrupted") = $0 { true } else { false } })
        #expect(session.isWorking, "the new message runs as its own turn")
        await store.stop()
    }

    @Test func enginesWithoutSteeringStopAndSendByDefault() async throws {
        let (store, session) = try await started(PlainTestEngine())
        await store.send("Long task", to: session.id)
        #expect(store.sendNowBehavior(for: session.id) == .stopAndSend)
        #expect(store.queuedDelivery(for: session.id) == .inOrder)
        await store.stop()
    }

    @Test func editAndCancelTakeMessagesOut() async throws {
        let engine = SteeringTestEngine(delayScale: TestWait.longTurnScale)
        let (store, session) = try await started(engine)
        await store.send("Long task", to: session.id)
        await store.send("One", to: session.id)
        await store.send("Two", to: session.id)
        await store.send("   ", to: session.id)
        let queue = store.queue(for: session.id)
        #expect(queue.map(\.text) == ["One", "Two"], "blank messages are dropped")
        store.cancelQueued(queue[0].id, in: session.id)
        let edited = store.takeQueued(queue[1].id, in: session.id)
        #expect(edited?.text == "Two")
        #expect(store.queue(for: session.id).isEmpty)
        #expect(store.takeQueued(queue[1].id, in: session.id) == nil)
        await store.stop()
    }

    // MARK: Side questions

    @Test func sideQuestionAsksInAHiddenCopyAndLeavesTheSessionAlone() async throws {
        let engine = SteeringTestEngine()
        let (store, session) = try await started(engine)
        await store.send("Build the panel", to: session.id)
        try await waitUntil("the first turn") { !session.isWorking }
        let itemsBefore = session.items
        let sessionsBefore = store.sidebarOrder.map(\.id)

        #expect(store.canAskSideQuestion(session.id))
        await store.askSideQuestion("What did you change?", about: session.id)
        let question = try #require(store.sideQuestions[session.id])
        let forkID = try #require(question.forkSessionID)
        #expect(store.isSideQuestionSession(forkID))
        #expect(store.sidebarOrder.map(\.id) == sessionsBefore, "the copy is not in the sidebar")
        #expect(store.session(forkID)?.permissionMode == .ask, "the copy never runs in the source's mode")

        try await waitUntil("the answer") { store.sideQuestions[session.id]?.phase == .answered }
        let answer = try #require(store.sideQuestions[session.id].map { store.sideQuestionAnswer($0) })
        #expect(!answer.text.isEmpty)
        #expect(!answer.streaming)
        // The preview agent asks to run a build in Ask mode; a side question rejects it.
        let fork = try #require(store.session(forkID))
        #expect(fork.resolutions.values.contains(.rejected))
        #expect(fork.pendingPermissions.isEmpty)
        #expect(session.items == itemsBefore, "nothing was added to the session asked about")
        let forkTranscript = try await engine.transcript(forkID)
        #expect(forkTranscript.contains { if case .notice(_, let text) = $0 { text == SessionStore.sideQuestionInstruction } else { false } })
        #expect(forkTranscript.contains { if case .user(_, "What did you change?", _) = $0 { true } else { false } })

        await store.closeSideQuestion(for: session.id)
        #expect(store.sideQuestions[session.id] == nil)
        #expect(store.session(forkID) == nil)
        #expect(!store.isSideQuestionSession(forkID))
        #expect(try await !engine.listSessions().contains { $0.id == forkID }, "Close deletes the copy")
    }

    @Test func continueKeepsTheCopyAsANormalSession() async throws {
        let engine = SteeringTestEngine()
        let (store, session) = try await started(engine)
        await store.askSideQuestion("Summarise the plan", about: session.id)
        let forkID = try #require(store.sideQuestions[session.id]?.forkSessionID)
        try await waitUntil("the answer") { store.sideQuestions[session.id]?.phase == .answered }

        let kept = await store.continueSideQuestion(for: session.id)
        #expect(kept?.id == forkID)
        #expect(store.sideQuestions[session.id] == nil)
        #expect(!store.isSideQuestionSession(forkID))
        #expect(store.sidebarOrder.contains { $0.id == forkID })
        #expect(store.selectedSessionID == forkID)
        #expect(kept?.permissionMode == .bypass, "kept like a fork, with the source's mode")
        #expect(kept?.title == "Summarise the plan")
        try await waitUntil("the kept session's transcript") { kept?.transcriptLoaded == true }
    }

    @Test func closingWhileTheCopyIsMadeThrowsTheCopyAway() async throws {
        // The copy is held until the close below has happened, so the close always lands while it is being made.
        let engine = SteeringTestEngine(holdForks: true)
        let (store, session) = try await started(engine)
        let ask = Task { await store.askSideQuestion("Quick one", about: session.id) }
        try await waitUntil("the side question to start") { store.sideQuestions[session.id] != nil }
        #expect(store.sideQuestions[session.id]?.forkSessionID == nil, "closed while the copy is still being made")
        await store.closeSideQuestion(for: session.id)
        engine.forkGate.open()
        await ask.value
        #expect(store.sideQuestions[session.id] == nil)
        #expect(store.hiddenSessionIDs.isEmpty, "no hidden copy is left behind")
        #expect(try await !engine.listSessions().contains { $0.id.hasPrefix("ses_fork_") })
    }

    @Test func sideQuestionsNeedAnEngineThatCanFork() async throws {
        let (plain, plainSession) = try await started(PlainTestEngine())
        #expect(plain.sideQuestionUnavailableReason(plainSession.id)?.contains("cannot copy a session") == true)
        #expect(!plain.canAskSideQuestion(plainSession.id))
        plain.openSideQuestion(for: plainSession.id)
        #expect(plain.sideQuestions.isEmpty)

        let (gated, gatedSession) = try await started(SteeringTestEngine(forkable: false))
        #expect(gated.sideQuestionUnavailableReason(gatedSession.id) != nil)
        await gated.askSideQuestion("Anything", about: gatedSession.id)
        if case .failed(let message) = gated.sideQuestions[gatedSession.id]?.phase {
            #expect(message.contains("cannot copy"))
        } else {
            Issue.record("expected a failed side question")
        }
        #expect(gated.hiddenSessionIDs.isEmpty)
    }

    // MARK: Copies left by a quit app

    func recordURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ens-side-\(UUID().uuidString)/side-question-copies.json")
    }

    /// A second app launch on the same engine and the same list of copies.
    func relaunch(_ engine: any OpenCodeAPI, record: URL) async -> SessionStore {
        let store = SessionStore(engine: engine)
        store.sideQuestionRecordURL = record
        await store.start()
        return store
    }

    @Test func leftoverCopiesAreDeletedAtTheNextStartAndNothingElseIs() async throws {
        let engine = SteeringTestEngine()
        let record = recordURL()
        let first = SessionStore(engine: engine)
        first.sideQuestionRecordURL = record
        await first.start()
        let a = try await first.newSession(directory: "/tmp/side-a", model: nil, permissionMode: .bypass)
        let b = try await first.newSession(directory: "/tmp/side-b", model: nil, permissionMode: .bypass)
        // A normal session whose title looks like a copy's: a title is never enough to delete anything.
        let lookalike = try await first.newSession(directory: "/tmp/side-c", model: nil, permissionMode: .bypass)
        await first.rename(lookalike.id, to: "Side question: not a copy")

        await first.askSideQuestion("Left open when the app quit", about: a.id)
        let leftover = try #require(first.sideQuestions[a.id]?.forkSessionID)
        await first.askSideQuestion("Kept as a session", about: b.id)
        let kept = try #require(first.sideQuestions[b.id]?.forkSessionID)
        try await waitUntil("both answers") { first.sideQuestions.values.allSatisfy { $0.phase != .asking } }
        await first.continueSideQuestion(for: b.id)
        #expect(first.sideQuestionCopyRecords().map(\.id) == [leftover], "a kept copy is off the list at once")
        first.stopListening()

        let second = await relaunch(engine, record: record)
        #expect(!second.sidebarOrder.contains { $0.id == leftover }, "the leftover never shows")
        await second.sideQuestionCleanupTask?.value
        let listed = try await engine.listSessions().map(\.id)
        #expect(!listed.contains(leftover))
        #expect(second.session(leftover) == nil)
        #expect(second.sideQuestionCopyRecords().isEmpty)
        #expect(!second.isSideQuestionSession(leftover))
        for id in [a.id, b.id, lookalike.id, kept] {
            #expect(listed.contains(id), "\(id) is untouched")
            #expect(second.sidebarOrder.contains { $0.id == id })
        }
        #expect(engine.calls.filter { $0.hasPrefix("delete:") } == ["delete:\(leftover)"], "only the leftover copy was deleted")
        try? FileManager.default.removeItem(at: record.deletingLastPathComponent())
    }

    @Test func aFailedDeleteIsTriedAgainNextTime() async throws {
        let engine = SteeringTestEngine()
        let record = recordURL()
        let first = await relaunch(engine, record: record)
        let session = try await first.newSession(directory: "/tmp/side-retry", model: nil, permissionMode: .bypass)
        await first.askSideQuestion("Anything", about: session.id)
        let leftover = try #require(first.sideQuestions[session.id]?.forkSessionID)
        try await waitUntil("the answer") { first.sideQuestions[session.id]?.phase != .asking }
        first.stopListening()

        engine.failDeletes.withLock { $0 = true }
        let second = await relaunch(engine, record: record)
        await second.sideQuestionCleanupTask?.value
        #expect(try await engine.listSessions().contains { $0.id == leftover })
        #expect(second.isSideQuestionSession(leftover), "still hidden while it cannot be deleted")
        #expect(!second.sidebarOrder.contains { $0.id == leftover })
        #expect(second.sideQuestionCopyRecords().map(\.id) == [leftover])
        second.stopListening()

        engine.failDeletes.withLock { $0 = false }
        let third = await relaunch(engine, record: record)
        await third.sideQuestionCleanupTask?.value
        #expect(try await !engine.listSessions().contains { $0.id == leftover })
        #expect(third.sideQuestionCopyRecords().isEmpty)
        try? FileManager.default.removeItem(at: record.deletingLastPathComponent())
    }

    @Test func copiesNoEngineListsAreKeptUntilTheyAreOld() async throws {
        let engine = SteeringTestEngine()
        let record = recordURL()
        let recent = SideQuestionCopyRecord(id: "ses_offline_engine", sourceSessionID: "s1", created: Date().addingTimeInterval(-3600))
        let old = SideQuestionCopyRecord(id: "ses_long_gone", sourceSessionID: "s2", created: Date().addingTimeInterval(-40 * 24 * 3600))
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([recent, old]).write(to: record)
        let sessionsBefore = try await engine.listSessions().map(\.id).sorted()

        let store = await relaunch(engine, record: record)
        await store.sideQuestionCleanupTask?.value
        #expect(store.sideQuestionCopyRecords().map(\.id) == ["ses_offline_engine"])
        #expect(store.isSideQuestionSession("ses_offline_engine"))
        #expect(!store.isSideQuestionSession("ses_long_gone"))
        #expect(!engine.calls.contains { $0.hasPrefix("delete:") }, "nothing the engines do not list is deleted")
        #expect(try await engine.listSessions().map(\.id).sorted() == sessionsBefore)
        try? FileManager.default.removeItem(at: record.deletingLastPathComponent())
    }

    @Test func closingForgetsTheCopyAndPreviewsRememberNothing() async throws {
        let engine = SteeringTestEngine()
        let record = recordURL()
        let store = await relaunch(engine, record: record)
        let session = try await store.newSession(directory: "/tmp/side-close", model: nil, permissionMode: .bypass)
        await store.askSideQuestion("Close me", about: session.id)
        let copy = try #require(store.sideQuestions[session.id]?.forkSessionID)
        #expect(store.sideQuestionCopyRecords().map(\.id) == [copy])
        await store.closeSideQuestion(for: session.id)
        #expect(store.sideQuestionCopyRecords().isEmpty)
        try? FileManager.default.removeItem(at: record.deletingLastPathComponent())

        #expect(SessionStore.defaultSideQuestionRecordURL(isPreview: true) == nil)
        #expect(SessionStore(engine: PreviewEngine()).sideQuestionRecordURL == nil)
        #expect(SessionStore.defaultSideQuestionRecordURL(isPreview: false) == nil, "test runners are not an app bundle")
        let app = Bundle(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        if let app {
            #expect(SessionStore.defaultSideQuestionRecordURL(isPreview: false, bundle: app)?.path
                .hasSuffix("Application Support/Ensemble/side-question-copies.json") == true)
        }
    }

    @Test func btwIsInTheSlashMenu() {
        let btw = SlashCommands.builtIn.first { $0.name == "btw" }
        #expect(btw?.argumentHint == "<question>")
        let parsed = SlashCommands.parse("/btw what is agent B doing?")
        #expect(parsed?.name == "btw")
        #expect(parsed?.arguments == "what is agent B doing?")
        let catalog = SlashCommands.catalog(engine: [EngineCommand(name: "btw", summary: "engine's own", kind: .command)])
        #expect(catalog.filter { $0.name == "btw" }.count == 1, "Ensemble's /btw replaces an engine command of the same name")
        #expect(catalog.first { $0.name == "btw" }?.source == .ensemble)
    }
}

/// The stream-json line the Claude engine writes for Send now.
@Suite struct ClaudeSteeringFrameTests {
    @Test func steeringLineCarriesPriorityNext() throws {
        let blocks = try ClaudeCLI.contentBlocks(synthetic: [], text: "Use the new API", files: [])
        let line = ClaudeCLI.userMessage(blocks: blocks, priority: "next")
        #expect(line["type"]?.stringValue == "user")
        #expect(line["priority"]?.stringValue == "next")
        #expect(line["message"]?["role"]?.stringValue == "user")
        #expect(line["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "Use the new API")
        #expect(line["parent_tool_use_id"] == .null)
    }

    @Test func ordinaryLinesHaveNoPriority() throws {
        let line = ClaudeCLI.userMessage(blocks: try ClaudeCLI.contentBlocks(synthetic: [], text: "hi", files: []))
        #expect(line["priority"] == nil)
        let data = try JSONEncoder().encode(line)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["type", "session_id", "message", "parent_tool_use_id"])
    }

    @Test func claudeCombinesQueuedMessagesAndSteersRootSessions() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-steer-\(UUID().uuidString)")
        let engine = ClaudeCodeEngine(configuration: .init(storeURL: folder.appendingPathComponent("sessions.json"),
                                                           trust: WorkspaceTrust(fileURL: folder.appendingPathComponent("trust.json"))))
        #expect(engine.queuedDelivery(for: "abc") == .combined)
        #if os(macOS)
        #expect(engine.canSteer("abc"))
        #expect(!engine.canSteer(ClaudeSessionIDs.child(root: "abc", toolUseID: "toolu_1")))
        #endif
    }
}
