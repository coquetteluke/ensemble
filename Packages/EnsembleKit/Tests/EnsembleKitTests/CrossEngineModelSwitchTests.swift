import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// Mock engine that captures full prompt texts and scripted transcripts for cross-engine switch tests.
private final class ThreadTestFakeEngine: RouterFakeEngine, EngineHistoryControl, EngineModelOptionsControl, EngineCommandsControl,
    EngineModelBilling, @unchecked Sendable {
    var rewindRestoresFiles: Bool { true }
    func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        log("fork:\(sessionID)")
        let session = EngineSession(id: "\(name)-fork-\(UUID().uuidString.prefix(6))", title: "fork", directory: "/tmp")
        state.withLock { $0.sessions.append(session) }
        return session
    }
    func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws { log("rewind:\(sessionID)") }
    func modelOptions(for model: ModelRef) async throws -> ModelOptions { ModelOptions(effortLevels: [.low, .high], supportsFastMode: true) }
    func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { log("effort:\(sessionID)") }
    func setFastMode(_ sessionID: String, enabled: Bool) async throws { log("fast:\(sessionID)") }
    func commands(directory: String?) async throws -> [EngineCommand] { [] }
    func runCommand(_ sessionID: String, name: String, arguments: String) async throws { log("command:\(sessionID):\(name)") }
    func modelBilling() async throws -> [String: ModelBilling] { [:] }
    struct TranscriptState {
        var prompts: [(sessionID: String, text: String)] = []
        var transcripts: [String: [TranscriptItem]] = [:]
    }

    let extra = Mutex(TranscriptState())

    func recordedPrompts(for sessionID: String) -> [String] {
        extra.withLock { $0.prompts.filter { $0.sessionID == sessionID }.map(\.text) }
    }

    func setTranscript(_ items: [TranscriptItem], for sessionID: String) {
        extra.withLock { $0.transcripts[sessionID] = items }
    }

    override func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        extra.withLock {
            $0.prompts.append((sessionID, text))
            $0.transcripts[sessionID, default: []].append(.user(id: "u-\(UUID().uuidString.prefix(6))", text: text, date: Date()))
        }
        try await super.prompt(sessionID, text: text, files: files)
    }

    override func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        log("transcript:\(sessionID)")
        return extra.withLock { $0.transcripts[sessionID] ?? [] }
    }
}

@MainActor
@Suite struct CrossEngineModelSwitchTests {
    private let gpt = ModelRef(providerID: "openai", id: "gpt-6")
    private let grok = ModelRef(providerID: "xai", id: "grok-5")
    private let haiku = ModelRef(providerID: "claude-code", id: "haiku")

    private func makeRouter() -> (EngineRouter, ThreadTestFakeEngine, ThreadTestFakeEngine) {
        let openCode = ThreadTestFakeEngine(name: "opencode")
        let claude = ThreadTestFakeEngine(name: "claude")
        openCode.state.withLock {
            $0.models = [
                ModelInfo(ref: gpt, name: "GPT-6", providerName: "OpenAI"),
                ModelInfo(ref: grok, name: "Grok 5", providerName: "xAI"),
            ]
        }
        claude.state.withLock {
            $0.models = [
                ModelInfo(ref: haiku, name: "Haiku 5.5", providerName: "Claude"),
            ]
        }
        let router = EngineRouter(fallback: openCode)
        router.register(claude, providers: ["claude-code": .subscription, "claude-code-api": .apiKey], id: "claude", name: "Claude")
        return (router, openCode, claude)
    }

    @Test func sameEngineIdleSwitchAppliesImmediately() async throws {
        let (router, openCode, _) = makeRouter()
        let store = SessionStore(engine: router, threadLinksURL: nil)
        await store.start()
        defer { store.stopListening() }

        let session = try await store.newSession(directory: "/tmp/proj", model: gpt, permissionMode: .auto)
        let result = await store.changeModel(grok, for: session.id)

        #expect(result == .switched)
        #expect(store.pendingNextModel[session.id] == nil)
        #expect(store.stagedModel(for: session.id) == nil)
        #expect(store.effectiveModel(for: session) == grok)
        #expect(session.info.model == grok)
        #expect(openCode.calls.contains("switch:\(session.id):xai/grok-5"))
    }

    @Test func sameEngineMidTurnStagesAndAppliesOnNextSend() async throws {
        let (router, openCode, _) = makeRouter()
        let store = SessionStore(engine: router, threadLinksURL: nil)
        await store.start()
        defer { store.stopListening() }

        let session = try await store.newSession(directory: "/tmp/proj", model: gpt, permissionMode: .auto)
        await store.send("First message", to: session.id)
        #expect(session.isWorking)

        // Stage grok mid-turn without interrupting or switching immediately.
        let stagedResult = await store.changeModel(grok, for: session.id)
        #expect(stagedResult == .stagedForNextMessage(grok))
        #expect(store.stagedModel(for: session.id) == grok)
        #expect(store.effectiveModel(for: session) == grok)
        #expect(session.info.model == gpt)
        #expect(!openCode.calls.contains("switch:\(session.id):xai/grok-5"))

        // Picking the currently active model clears the staged switch.
        let cancelResult = await store.changeModel(gpt, for: session.id)
        #expect(cancelResult == .switched)
        #expect(store.stagedModel(for: session.id) == nil)
        #expect(store.effectiveModel(for: session) == gpt)

        // Stage grok again, finish the running turn, then send the next message.
        #expect(await store.changeModel(grok, for: session.id) == .stagedForNextMessage(grok))
        openCode.send(.executionEnded(sessionID: session.id, outcome: "completed", error: nil))
        openCode.send(.activity(sessionID: session.id, .idle))
        try await waitUntil("session returns to idle") { !session.isWorking }

        await store.send("Second message", to: session.id)

        #expect(store.stagedModel(for: session.id) == nil)
        #expect(session.info.model == grok)
        #expect(openCode.calls.contains("switch:\(session.id):xai/grok-5"))
        #expect(session.items.contains {
            if case .notice(_, let text) = $0 { return text == "Switched to Grok 5" }
            return false
        })
        let switchIdx = try #require(openCode.calls.firstIndex(of: "switch:\(session.id):xai/grok-5"))
        let secondPromptIdx = try #require(openCode.calls.lastIndex(of: "prompt:\(session.id)"))
        #expect(switchIdx < secondPromptIdx)
    }

    @Test func crossEngineRoundTripSwitchesRoutesEventsAndReusesSessionWithDelta() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-links-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (router, openCode, claude) = makeRouter()
        let store = SessionStore(engine: router, threadLinksURL: tempURL)
        await store.start()
        defer { store.stopListening() }

        // 1. Start on Engine A (OpenCode) and run Turn 1.
        let primary = try await store.newSession(directory: "/tmp/proj", model: gpt, permissionMode: .ask)
        await store.send("Check Package.swift", to: primary.id)
        openCode.send(.textDelta(sessionID: primary.id, itemID: "a1", delta: "Looked at Package.swift."))
        openCode.send(.toolUpdated(sessionID: primary.id, ToolCallInfo(id: "t1", name: "edit", title: "Package.swift", status: .succeeded)))
        openCode.send(.usageUpdated(sessionID: primary.id, Usage(inputTokens: 100, outputTokens: 50, costUSD: 0.12)))
        openCode.send(.executionEnded(sessionID: primary.id, outcome: "completed", error: nil))
        openCode.send(.activity(sessionID: primary.id, .idle))
        try await waitUntil("turn 1 finished") {
            !primary.isWorking && primary.items.contains { if case .agentText = $0 { true } else { false } }
        }

        // 2. Stage Engine B (Claude) without leaving or creating a session yet.
        let stageB = await store.changeModel(haiku, for: primary.id)
        #expect(stageB == .stagedForNextMessage(haiku))
        #expect(store.stagedModel(for: primary.id) == haiku)
        #expect(store.effectiveModel(for: primary) == haiku)
        #expect(primary.info.model == gpt)
        #expect(claude.calls.isEmpty)
        #expect(store.selectedSessionID == primary.id)

        // 3. Send message -> creates backing session on Claude, hides duplicate, sends compact handoff.
        await store.send("Fix the failing test", to: primary.id)

        let backingB = store.backingSessionID(for: primary.id)
        #expect(backingB != primary.id)
        #expect(store.sessions.map(\.id) == [primary.id])
        #expect(store.hiddenLinkedSessionIDs.contains(backingB))
        #expect(store.session(backingB) == nil)
        #expect(store.stagedModel(for: primary.id) == nil)
        #expect(primary.info.model == haiku)

        // UI shows divider + clean user message (never raw handoff preamble).
        #expect(primary.items.contains {
            if case .notice(_, let text) = $0 { return text == "Switched to Haiku 5.5 for this message" }
            return false
        })
        let userBubbles = primary.items.compactMap { item -> String? in
            if case .user(_, let text, _) = item { return text }
            return nil
        }
        #expect(userBubbles == ["Check Package.swift", "Fix the failing test"])

        let sentToB = try #require(claude.recordedPrompts(for: backingB).first)
        #expect(sentToB.contains(CrossEngineHandoff.preambleHeader))
        #expect(sentToB.contains("Check Package.swift"))
        #expect(sentToB.contains("Looked at Package.swift."))
        #expect(sentToB.contains("Edited files: Package.swift"))
        #expect(sentToB.hasSuffix(CrossEngineHandoff.promptSeparator + "Fix the failing test"))

        // 4. Route Engine B streaming, tools, permissions, usage, and stop() back into primary.
        claude.send(.textDelta(sessionID: backingB, itemID: "b1", delta: "Fixed test case."))
        claude.send(.toolUpdated(sessionID: backingB, ToolCallInfo(id: "t2", name: "edit", title: "Tests.swift", status: .succeeded)))
        claude.send(.permissionAsked(PermissionRequest(id: "perm-b1", sessionID: backingB, kind: "bash", title: "swift test")))
        try await waitUntil("permission routed into primary") {
            primary.pendingPermissions.contains { $0.id == "perm-b1" } && primary.activity == .waitingForPermission
        }
        let perm = try #require(primary.pendingPermissions.first { $0.id == "perm-b1" })
        await store.reply(to: perm, decision: .once)
        #expect(claude.calls.contains("reply:\(backingB):perm-b1"))
        #expect(primary.pendingPermissions.isEmpty)

        await store.stop()
        #expect(claude.calls.contains("interrupt:\(backingB)"))

        claude.send(.usageUpdated(sessionID: backingB, Usage(inputTokens: 80, outputTokens: 40, costUSD: 0.08)))
        claude.send(.executionEnded(sessionID: backingB, outcome: "completed", error: nil))
        claude.send(.activity(sessionID: backingB, .idle))
        try await waitUntil("turn 2 finished") {
            !primary.isWorking && primary.items.contains { if case .agentText(let id, _, _, _) = $0 { id == "b1" } else { false } }
        }
        #expect(abs(primary.usage.costUSD - 0.20) < 0.0001)

        // 5. Switch back to Engine A (Grok 5 on OpenCode) -> reuses primary session with delta handoff.
        let stageA = await store.changeModel(grok, for: primary.id)
        #expect(stageA == .stagedForNextMessage(grok))

        let openCodeCreatesBefore = openCode.calls.filter { $0.hasPrefix("create:") }.count
        await store.send("Summarize both edits", to: primary.id)
        let openCodeCreatesAfter = openCode.calls.filter { $0.hasPrefix("create:") }.count

        #expect(openCodeCreatesAfter == openCodeCreatesBefore)
        #expect(store.backingSessionID(for: primary.id) == primary.id)
        #expect(primary.info.model == grok)
        #expect(openCode.calls.contains("switch:\(primary.id):xai/grok-5"))

        let deltaSentToA = try #require(openCode.recordedPrompts(for: primary.id).last)
        #expect(deltaSentToA.contains("New turns since the last message on this engine:"))
        #expect(deltaSentToA.contains("Fix the failing test"))
        #expect(deltaSentToA.contains("Fixed test case."))
        #expect(!deltaSentToA.contains("Check Package.swift"))
        #expect(deltaSentToA.hasSuffix(CrossEngineHandoff.promptSeparator + "Summarize both edits"))
    }

    @Test func threadLinksPersistAndReloadMergedTranscript() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (router1, openCode1, claude1) = makeRouter()
        let store1 = SessionStore(engine: router1, threadLinksURL: tempURL)
        await store1.start()

        let primary = try await store1.newSession(directory: "/tmp/proj", model: gpt, permissionMode: .auto)
        await store1.send("Start task", to: primary.id)
        let t1Date = Date(timeIntervalSince1970: 1_000)
        let t2Date = Date(timeIntervalSince1970: 2_000)
        openCode1.setTranscript([
            .user(id: "u1", text: "Start task", date: t1Date),
            .agentText(id: "a1", text: "Done part 1", agentID: nil, streaming: false),
        ], for: primary.id)
        openCode1.send(.executionEnded(sessionID: primary.id, outcome: "completed", error: nil))
        openCode1.send(.activity(sessionID: primary.id, .idle))
        try await waitUntil("store1 turn 1 idle") { !primary.isWorking }

        #expect(await store1.changeModel(haiku, for: primary.id) == .stagedForNextMessage(haiku))
        await store1.send("Continue on Claude", to: primary.id)
        let backingB = store1.backingSessionID(for: primary.id)
        let sentB = try #require(claude1.recordedPrompts(for: backingB).first)
        claude1.setTranscript([
            .user(id: "u2", text: sentB, date: t2Date),
            .agentText(id: "b1", text: "Done part 2", agentID: nil, streaming: false),
        ], for: backingB)
        store1.stopListening()
        #expect(FileManager.default.fileExists(atPath: tempURL.path))

        // Reload in a fresh store backed by the same persisted session-threads.json.
        let (router2, openCode2, claude2) = makeRouter()
        openCode2.setSessions([EngineSession(id: primary.id, title: "Start task", directory: "/tmp/proj", model: gpt)])
        openCode2.setTranscript(try await openCode1.transcript(primary.id), for: primary.id)
        claude2.setSessions([EngineSession(id: backingB, title: "", directory: "/tmp/proj", model: haiku)])
        claude2.setTranscript(try await claude1.transcript(backingB), for: backingB)

        let store2 = SessionStore(engine: router2, threadLinksURL: tempURL)
        await store2.start()
        defer { store2.stopListening() }

        #expect(store2.sessions.map(\.id) == [primary.id])
        #expect(store2.hiddenLinkedSessionIDs.contains(backingB))
        #expect(store2.backingSessionID(for: primary.id) == backingB)
        #expect(store2.session(primary.id)?.info.model == haiku)

        await store2.loadSession(primary.id)
        let reloaded = try #require(store2.session(primary.id))
        let userTexts = reloaded.items.compactMap { item -> String? in
            if case .user(_, let text, _) = item { return text }
            return nil
        }
        #expect(userTexts == ["Start task", "Continue on Claude"])
        #expect(!userTexts.joined().contains(CrossEngineHandoff.preambleHeader))
        #expect(reloaded.items.contains {
            if case .notice(_, let text) = $0 { return text.contains("Haiku 5.5") }
            return false
        })

        // Next message in reloaded store routes straight to Claude backing session.
        await store2.send("Follow up after restart", to: primary.id)
        #expect(claude2.recordedPrompts(for: backingB).contains("Follow up after restart"))
    }

    @Test func handoffRedactsSecretsAndEnforcesMaxChars() {
        let items: [TranscriptItem] = [
            .user(id: "u1", text: String(repeating: "Old prompt context. ", count: 25), date: Date(timeIntervalSince1970: 100)),
            .agentText(id: "a1", text: "Use sk-ant-secret1234567890abcdef and Bearer my_secret_token_999 at https://user:pw@example.com/api?key=abc", agentID: nil, streaming: false),
            .tool(ToolCallInfo(id: "t1", name: "edit", title: "Sources/App.swift", status: .succeeded)),
            .user(id: "u2", text: "Latest prompt API_KEY=\"top_secret_val\" -----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----", date: Date(timeIntervalSince1970: 200)),
            .agentText(id: "a2", text: "Latest conclusion ready.", agentID: nil, streaming: false),
        ]

        let handoff = CrossEngineHandoff.build(items: items, maxChars: 420)
        #expect(!handoff.isEmpty)
        #expect(handoff.count <= 420)
        #expect(!handoff.contains("sk-ant-secret1234567890abcdef"))
        #expect(!handoff.contains("my_secret_token_999"))
        #expect(!handoff.contains("top_secret_val"))
        #expect(!handoff.contains("BEGIN RSA PRIVATE KEY"))
        #expect(!handoff.contains("user:pw"))
        #expect(handoff.contains("Latest conclusion ready."))
    }
}
