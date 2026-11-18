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
    /// How long making a copy takes, so a test can act while it is still in progress.
    let forkDelay: Duration
    private let log = Mutex<[String]>([])

    init(delivery: QueuedDelivery = .inOrder, steerable: Bool = true, forkable: Bool = true, delayScale: Double = 0.1,
         forkDelay: Duration = .zero) {
        base = PreviewEngine(seed: PreviewData.seed(), delayScale: delayScale)
        self.delivery = delivery
        self.steerable = steerable
        self.forkable = forkable
        self.forkDelay = forkDelay
    }

    var calls: [String] { log.withLock { $0 } }

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
        if forkDelay > .zero { try await Task.sleep(for: forkDelay) }
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
    /// Polls until `condition` holds; fails the test after `timeout`.
    func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

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

        await until("both held messages to go out") { userTexts(session).count == 3 && !session.isWorking }
        #expect(userTexts(session) == ["First task", "Second", "Third\n\nAttached: notes.md"])
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
        await until("the combined message") { userTexts(session).count == 2 && !session.isWorking }
        #expect(engine.calls == ["prompt:Build the panel", "prompt:Also add tests\n\nAnd update the README"])
        #expect(store.queue(for: session.id).isEmpty)
    }

    @Test func idleSessionsSendStraightAway() async throws {
        let (store, session) = try await started(SteeringTestEngine())
        await store.send("Hello", to: session.id)
        #expect(store.queue(for: session.id).isEmpty)
        #expect(userTexts(session) == ["Hello"])
        #expect(store.sendNowBehavior(for: session.id) == .steer)
        await until("the turn to end") { !session.isWorking }
        #expect(store.sendNowBehavior(for: session.id) == .send)
    }

    @Test func stoppingTheTurnHoldsTheQueue() async throws {
        let engine = SteeringTestEngine(delayScale: 1)
        let (store, session) = try await started(engine)
        await store.send("Long task", to: session.id)
        await store.send("Follow up", to: session.id)
        await store.stop()
        await until("the interrupt") { !session.isWorking }
        try await Task.sleep(for: .milliseconds(600))
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

    @Test func sendNowSteersTheRunningTurn() async throws {
        let engine = SteeringTestEngine(delayScale: 1)
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
        let engine = SteeringTestEngine(steerable: false, delayScale: 1)
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
        let engine = SteeringTestEngine(delayScale: 1)
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
        await until("the first turn") { !session.isWorking }
        let itemsBefore = session.items
        let sessionsBefore = store.sidebarOrder.map(\.id)

        #expect(store.canAskSideQuestion(session.id))
        await store.askSideQuestion("What did you change?", about: session.id)
        let question = try #require(store.sideQuestions[session.id])
        let forkID = try #require(question.forkSessionID)
        #expect(store.isSideQuestionSession(forkID))
        #expect(store.sidebarOrder.map(\.id) == sessionsBefore, "the copy is not in the sidebar")
        #expect(store.session(forkID)?.permissionMode == .ask, "the copy never runs in the source's mode")

        await until("the answer") { store.sideQuestions[session.id]?.phase == .answered }
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
        await until("the answer") { store.sideQuestions[session.id]?.phase == .answered }

        let kept = await store.continueSideQuestion(for: session.id)
        #expect(kept?.id == forkID)
        #expect(store.sideQuestions[session.id] == nil)
        #expect(!store.isSideQuestionSession(forkID))
        #expect(store.sidebarOrder.contains { $0.id == forkID })
        #expect(store.selectedSessionID == forkID)
        #expect(kept?.permissionMode == .bypass, "kept like a fork, with the source's mode")
        #expect(kept?.title == "Summarise the plan")
        await until("the kept session's transcript") { kept?.transcriptLoaded == true }
    }

    @Test func closingWhileTheCopyIsMadeThrowsTheCopyAway() async throws {
        // The copy takes half a second, so the close below always lands while it is being made.
        let engine = SteeringTestEngine(forkDelay: .milliseconds(500))
        let (store, session) = try await started(engine)
        let ask = Task { await store.askSideQuestion("Quick one", about: session.id) }
        while store.sideQuestions[session.id] == nil { await Task.yield() }
        #expect(store.sideQuestions[session.id]?.forkSessionID == nil, "closed while the copy is still being made")
        await store.closeSideQuestion(for: session.id)
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
