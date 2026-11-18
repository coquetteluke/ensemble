import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// A scripted engine that records which calls reached it.
class RouterFakeEngine: OpenCodeAPI, @unchecked Sendable {
    struct State {
        var sessions: [EngineSession] = []
        var models: [ModelInfo] = []
        var providers: [ProviderInfo] = []
        var connectors: [ConnectorInfo] = []
        var permissions: [PermissionRequest] = []
        var schedules: [ScheduleInfo] = []
        var calls: [String] = []
        var failListing = false
        var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    }

    let name: String
    let state = Mutex(State())

    init(name: String) { self.name = name }

    var calls: [String] { state.withLock { $0.calls } }
    func log(_ call: String) { state.withLock { $0.calls.append(call) } }
    func setSessions(_ sessions: [EngineSession]) { state.withLock { $0.sessions = sessions } }
    func setFailListing(_ fail: Bool) { state.withLock { $0.failListing = fail } }
    var streamCount: Int { state.withLock { $0.continuations.count } }

    func send(_ event: EngineEvent) {
        for continuation in state.withLock({ Array($0.continuations.values) }) { continuation.yield(event) }
    }

    func endStreams() {
        for continuation in state.withLock({ Array($0.continuations.values) }) { continuation.finish() }
    }

    func serverInfo() async throws -> (version: String, url: URL) { (name, URL(string: "fake://\(name)")!) }

    func listSessions() async throws -> [EngineSession] {
        try state.withLock { state in
            if state.failListing { throw OpenCodeError.invalidResponse("\(name) is down") }
            return state.sessions
        }
    }

    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode, parentID: String?) async throws -> EngineSession {
        let session = EngineSession(id: "\(name)-\(UUID().uuidString.prefix(8))", parentID: parentID, title: "", directory: directory, model: model)
        state.withLock { state in
            state.sessions.append(session)
            state.calls.append("create:\(model?.description ?? "nil"):\(parentID ?? "nil")")
        }
        return session
    }

    func deleteSession(_ sessionID: String) async throws { log("delete:\(sessionID)") }
    func renameSession(_ sessionID: String, title: String) async throws { log("rename:\(sessionID)") }
    func setArchived(_ sessionID: String, archived: Bool) async throws { log("archive:\(sessionID)") }
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { log("mode:\(sessionID)") }
    func switchModel(_ sessionID: String, model: ModelRef) async throws { log("switch:\(sessionID):\(model)") }
    func transcript(_ sessionID: String) async throws -> [TranscriptItem] { log("transcript:\(sessionID)"); return [] }

    func children(_ sessionID: String) async throws -> [EngineSession] {
        log("children:\(sessionID)")
        return state.withLock { $0.sessions.filter { $0.parentID == sessionID } }
    }

    func prompt(_ sessionID: String, text: String, files: [URL]) async throws { log("prompt:\(sessionID)") }
    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws { log("synthetic:\(sessionID)") }
    func interrupt(_ sessionID: String) async throws { log("interrupt:\(sessionID)") }
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        log("reply:\(sessionID):\(requestID)")
    }
    func pendingPermissions() async throws -> [PermissionRequest] { state.withLock { $0.permissions } }
    func context(_ sessionID: String) async throws -> ContextBreakdown {
        log("context:\(sessionID)")
        return ContextBreakdown(usedTokens: 1, limitTokens: 10, categories: [])
    }
    func changedFiles(_ sessionID: String) async throws -> [FileChange] { log("files:\(sessionID)"); return [] }
    func connectors() async throws -> [ConnectorInfo] { state.withLock { $0.connectors } }
    func models() async throws -> [ModelInfo] { state.withLock { $0.models } }
    func providers() async throws -> [ProviderInfo] { state.withLock { $0.providers } }
    func setAPIKey(providerID: String, key: String) async throws { log("setKey:\(providerID)") }
    func removeAPIKey(providerID: String) async throws { log("removeKey:\(providerID)") }
    func schedules() async throws -> [ScheduleInfo] { state.withLock { $0.schedules } }
    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        let info = ScheduleInfo(id: "\(name)-schedule", title: title, prompt: prompt, directory: directory, schedule: schedule)
        state.withLock { state in
            state.schedules.append(info)
            state.calls.append("createSchedule")
        }
        return info
    }
    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { log("pause:\(scheduleID)") }
    func deleteSchedule(_ scheduleID: String) async throws { log("deleteSchedule:\(scheduleID)") }

    func events() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        let id = UUID()
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) } }
        return stream
    }
}

/// A fake engine with every optional ability.
final class RouterCapableFakeEngine: RouterFakeEngine, EngineHistoryControl, EngineModelOptionsControl, EngineCommandsControl,
    EngineModelBilling, @unchecked Sendable {
    var rewindRestoresFiles: Bool { true }

    func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        log("fork:\(sessionID)")
        let session = EngineSession(id: "\(name)-fork-\(UUID().uuidString.prefix(6))", title: "fork", directory: "/tmp")
        state.withLock { $0.sessions.append(session) }
        return session
    }

    func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws { log("rewind:\(sessionID)") }

    func modelOptions(for model: ModelRef) async throws -> ModelOptions {
        log("options:\(model)")
        return ModelOptions(effortLevels: [.low, .high], supportsFastMode: true)
    }

    func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { log("effort:\(sessionID)") }
    func setFastMode(_ sessionID: String, enabled: Bool) async throws { log("fast:\(sessionID)") }

    func commands(directory: String?) async throws -> [EngineCommand] {
        [EngineCommand(name: "review", summary: "\(name) review", kind: .command),
         EngineCommand(name: "\(name)-only", summary: "", kind: .skill)]
    }

    func runCommand(_ sessionID: String, name: String, arguments: String) async throws { log("command:\(sessionID):\(name)") }

    func modelBilling() async throws -> [String: ModelBilling] {
        ["\(name)-free/free-model": .free]
    }
}

@Suite struct RouterTests {
    private let haiku = ModelRef(providerID: "claude-code", id: "haiku")
    private let gpt = ModelRef(providerID: "openai", id: "gpt-6")

    /// OpenCode stand-in (no optional abilities) as the fallback, Claude stand-in with all of them.
    private func makeRouter() -> (EngineRouter, RouterFakeEngine, RouterCapableFakeEngine) {
        let openCode = RouterFakeEngine(name: "opencode")
        let claude = RouterCapableFakeEngine(name: "claude")
        let router = EngineRouter(fallback: openCode)
        router.register(claude, providers: ["claude-code": .subscription, "claude-code-api": .apiKey], id: "claude", name: "Claude")
        return (router, openCode, claude)
    }

    @Test func createRoutesByProviderAndParent() async throws {
        let (router, openCode, claude) = makeRouter()
        let claudeSession = try await router.createSession(directory: "/tmp", model: haiku, agent: nil, permissionMode: .auto, parentID: nil)
        let openSession = try await router.createSession(directory: "/tmp", model: gpt, agent: nil, permissionMode: .auto, parentID: nil)
        _ = try await router.createSession(directory: "/tmp", model: nil, agent: nil, permissionMode: .auto, parentID: nil)
        _ = try await router.createSession(directory: "/tmp", model: nil, agent: nil, permissionMode: .auto, parentID: claudeSession.id)
        #expect(claude.calls == ["create:claude-code/haiku:nil", "create:nil:\(claudeSession.id)"])
        #expect(openCode.calls == ["create:openai/gpt-6:nil", "create:nil:nil"])

        try await router.prompt(claudeSession.id, text: "hi", files: [])
        try await router.prompt(openSession.id, text: "hi", files: [])
        try await router.interrupt(claudeSession.id)
        _ = try await router.context(openSession.id)
        #expect(claude.calls.suffix(2) == ["prompt:\(claudeSession.id)", "interrupt:\(claudeSession.id)"])
        #expect(openCode.calls.suffix(2) == ["prompt:\(openSession.id)", "context:\(openSession.id)"])
    }

    @Test func listsAndLearnsOwnersLazily() async throws {
        let (router, openCode, claude) = makeRouter()
        openCode.setSessions([EngineSession(id: "ses_a", title: "A", directory: "/tmp")])
        claude.setSessions([EngineSession(id: "c-1", title: "B", directory: "/tmp")])
        // No listing yet: the first call for an unknown id lists every engine once.
        try await router.prompt("c-1", text: "hi", files: [])
        #expect(claude.calls == ["prompt:c-1"])
        let all = try await router.listSessions()
        #expect(all.map(\.id) == ["ses_a", "c-1"])
        try await router.renameSession("ses_a", title: "x")
        #expect(openCode.calls == ["rename:ses_a"])
    }

    @Test func unknownSessionThrows() async throws {
        let (router, openCode, claude) = makeRouter()
        await #expect(throws: EngineRouterError.unknownSession("nope")) {
            try await router.prompt("nope", text: "hi", files: [])
        }
        await #expect(throws: EngineRouterError.unknownSession("nope")) {
            _ = try await router.fork("nope", atMessageID: nil)
        }
        #expect(openCode.calls.isEmpty && claude.calls.isEmpty)
        #expect(EngineRouterError.unknownSession("nope").errorDescription == "No engine has a session with id nope.")
    }

    @Test func claudeSubagentIDsFollowTheirRoot() async throws {
        let (router, _, claude) = makeRouter()
        let root = try await router.createSession(directory: "/tmp", model: haiku, agent: nil, permissionMode: .auto, parentID: nil)
        let child = "\(root.id).toolu_123"
        _ = try await router.transcript(child)
        #expect(claude.calls.last == "transcript:\(child)")
    }

    @Test func switchingModelStaysOnTheSessionsEngine() async throws {
        let (router, openCode, _) = makeRouter()
        let session = try await router.createSession(directory: "/tmp", model: gpt, agent: nil, permissionMode: .auto, parentID: nil)
        try await router.switchModel(session.id, model: ModelRef(providerID: "xai", id: "grok-5"))
        #expect(openCode.calls.last == "switch:\(session.id):xai/grok-5")
        await #expect(throws: EngineRouterError.engineMismatch(sessionEngine: "OpenCode", modelEngine: "Claude", model: "claude-code/haiku")) {
            try await router.switchModel(session.id, model: haiku)
        }
    }

    @Test func mergesEventsAndLearnsFromThem() async throws {
        let (router, openCode, claude) = makeRouter()
        let stream = router.events()
        #expect(openCode.streamCount == 1 && claude.streamCount == 1)
        var iterator = stream.makeAsyncIterator()
        let live = EngineSession(id: "c-live", title: "", directory: "/tmp")
        claude.send(.sessionCreated(live))
        let first = await iterator.next()
        openCode.send(.other(type: "server.connected"))
        let second = await iterator.next()
        #expect(first == .sessionCreated(live))
        #expect(second == .other(type: "server.connected"))
        // Ownership came from the event, so no listing is needed.
        try await router.prompt("c-live", text: "hi", files: [])
        #expect(claude.calls == ["prompt:c-live"])
    }

    @Test func eventStreamEndsWhenEveryEngineEnds() async throws {
        let (router, openCode, claude) = makeRouter()
        let stream = router.events()
        openCode.endStreams()
        claude.endStreams()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
        #expect(router.subscriberCount == 0)
    }

    @Test func cancellingTheMergedStreamStopsEngineStreams() async throws {
        let (router, openCode, claude) = makeRouter()
        let task = Task {
            for await _ in router.events() {}
        }
        try await waitUntil("both engines to be subscribed") { openCode.streamCount == 1 && claude.streamCount == 1 }
        task.cancel()
        try await waitUntil("every subscription to end") { openCode.streamCount == 0 && claude.streamCount == 0 && router.subscriberCount == 0 }
    }

    @Test func laterEnginesJoinOpenStreams() async throws {
        let (router, _, _) = makeRouter()
        let stream = router.events()
        let acp = RouterFakeEngine(name: "acp")
        router.register(acp, providers: ["antigravity"], id: "antigravity", name: "Antigravity")
        #expect(acp.streamCount == 1)
        var iterator = stream.makeAsyncIterator()
        acp.send(.connectorsChanged)
        #expect(await iterator.next() == .connectorsChanged)
        let session = try await router.createSession(directory: "/tmp", model: ModelRef(providerID: "antigravity", id: "gemini"),
                                                     agent: nil, permissionMode: .ask, parentID: nil)
        #expect(acp.calls == ["create:antigravity/gemini:nil"])
        #expect(session.id.hasPrefix("acp-"))

        // Registering the same id again replaces the engine and its live events.
        let replacement = RouterFakeEngine(name: "acp2")
        router.register(replacement, providers: ["antigravity"], id: "antigravity", name: "Antigravity")
        try await waitUntil("the replacement engine to be subscribed") { acp.streamCount == 0 && replacement.streamCount == 1 }
        replacement.send(.connectorsChanged)
        #expect(await iterator.next() == .connectorsChanged)
    }

    @Test func forwardsCapabilitiesOrExplains() async throws {
        let (router, openCode, claude) = makeRouter()
        let claudeSession = try await router.createSession(directory: "/tmp", model: haiku, agent: nil, permissionMode: .auto, parentID: nil)
        let openSession = try await router.createSession(directory: "/tmp", model: gpt, agent: nil, permissionMode: .auto, parentID: nil)

        let fork = try await router.fork(claudeSession.id, atMessageID: nil)
        try await router.prompt(fork.id, text: "hi", files: [])
        try await router.rewind(claudeSession.id, toBeforeMessageID: "m1")
        try await router.setEffort(claudeSession.id, effort: .high)
        try await router.setFastMode(claudeSession.id, enabled: true)
        try await router.runCommand(claudeSession.id, name: "review", arguments: "")
        let options = try await router.modelOptions(for: haiku)
        #expect(options.effortLevels == [.low, .high])
        #expect(claude.calls.contains("fork:\(claudeSession.id)"))
        #expect(claude.calls.contains("prompt:\(fork.id)"))
        #expect(claude.calls.contains("rewind:\(claudeSession.id)"))
        #expect(claude.calls.contains("command:\(claudeSession.id):review"))

        await #expect(throws: EngineRouterError.notSupported(engine: "OpenCode", feature: "be forked")) {
            _ = try await router.fork(openSession.id, atMessageID: nil)
        }
        await #expect(throws: EngineRouterError.notSupported(engine: "OpenCode", feature: "change effort")) {
            try await router.setEffort(openSession.id, effort: .low)
        }
        await #expect(throws: EngineRouterError.notSupported(engine: "OpenCode", feature: "run slash commands")) {
            try await router.runCommand(openSession.id, name: "review", arguments: "")
        }
        await #expect(throws: EngineRouterError.notSupported(engine: "OpenCode", feature: "change effort or fast mode")) {
            _ = try await router.modelOptions(for: gpt)
        }
        #expect(EngineRouterError.notSupported(engine: "OpenCode", feature: "be forked").errorDescription
                == "OpenCode sessions cannot be forked.")
        #expect(!openCode.calls.contains { $0.hasPrefix("fork") })

        let merged = try await router.commands(directory: "/tmp")
        #expect(merged.map(\.name) == ["review", "claude-only"])
        let own = try await router.commands(directory: "/tmp", forSession: claudeSession.id)
        #expect(own.count == 2)
        #expect(router.rewindRestoresFiles)
        #expect(await router.rewindRestoresFiles(for: claudeSession.id))
        #expect(!(await router.rewindRestoresFiles(for: openSession.id)))
    }

    @Test func mergesListsAndGroupsModels() async throws {
        let (router, openCode, claude) = makeRouter()
        openCode.state.withLock { state in
            state.models = [ModelInfo(ref: gpt, name: "GPT", providerName: "OpenAI"),
                            ModelInfo(ref: ModelRef(providerID: "claude-free", id: "free-model"), name: "Free", providerName: "X")]
            state.providers = [ProviderInfo(id: "openai", name: "OpenAI", connected: true)]
            state.connectors = [ConnectorInfo(id: "github", name: "GitHub", state: .failed)]
            state.permissions = [PermissionRequest(id: "p1", sessionID: "ses_a", kind: "shell", title: "ls", created: Date(timeIntervalSince1970: 2))]
        }
        claude.state.withLock { state in
            state.models = [ModelInfo(ref: haiku, name: "Haiku", providerName: "Claude"),
                            ModelInfo(ref: ModelRef(providerID: "claude-code-api", id: "opus"), name: "Opus", providerName: "Claude API")]
            state.providers = [ProviderInfo(id: "claude-code", name: "Claude", connected: true),
                               ProviderInfo(id: "openai", name: "dup", connected: false)]
            state.connectors = [ConnectorInfo(id: "github", name: "GitHub", state: .connected),
                                ConnectorInfo(id: "linear", name: "Linear", state: .connected)]
            state.permissions = [PermissionRequest(id: "p2", sessionID: "c-9", kind: "edit", title: "a.swift", created: Date(timeIntervalSince1970: 1))]
        }
        let models = try await router.models()
        #expect(models.map(\.id) == ["openai/gpt-6", "claude-free/free-model", "claude-code/haiku", "claude-code-api/opus"])
        #expect(try await router.providers().map(\.name) == ["OpenAI", "Claude"])
        let connectors = try await router.connectors()
        #expect(connectors.map(\.id) == ["github", "linear"])
        #expect(connectors.first?.state == .connected)

        let pending = try await router.pendingPermissions()
        #expect(pending.map(\.id) == ["p2", "p1"])
        try await router.replyPermission(sessionID: "c-9", requestID: "p2", decision: .once, message: nil)
        #expect(claude.calls == ["reply:c-9:p2"])

        let groups = try await router.modelGroups()
        #expect(groups.map(\.billing) == [.subscription, .apiKey, .free])
        #expect(groups.map(\.title) == ["Your subscriptions", "API keys", "Free"])
        #expect(groups[0].models.map(\.id) == ["claude-code/haiku"])
        #expect(groups[1].models.map(\.id) == ["openai/gpt-6", "claude-code-api/opus"])
        #expect(groups[2].models.map(\.id) == ["claude-free/free-model"])
    }

    @Test func keysAndSchedulesGoToTheRightEngine() async throws {
        let (router, openCode, claude) = makeRouter()
        try await router.setAPIKey(providerID: "claude-code-api", key: "k")
        try await router.setAPIKey(providerID: "anthropic", key: "k")
        try await router.removeAPIKey(providerID: "openai")
        #expect(claude.calls == ["setKey:claude-code-api"])
        #expect(openCode.calls == ["setKey:anthropic", "removeKey:openai"])

        openCode.state.withLock { $0.schedules = [ScheduleInfo(id: "sch_1", title: "t", prompt: "p", directory: "/tmp", schedule: "every 1 hour")] }
        try await router.deleteSchedule("sch_1")
        #expect(openCode.calls.last == "deleteSchedule:sch_1")
        let created = try await router.createSchedule(title: "t", prompt: "p", directory: "/tmp", schedule: "every 1 hour", model: haiku)
        try await router.setSchedulePaused(created.id, paused: true)
        #expect(claude.calls.suffix(2) == ["createSchedule", "pause:claude-schedule"])
        await #expect(throws: EngineRouterError.unknownSchedule("missing")) {
            try await router.deleteSchedule("missing")
        }
    }

    @Test func aFailingEngineKeepsItsLastSessions() async throws {
        let (router, openCode, claude) = makeRouter()
        openCode.setSessions([EngineSession(id: "ses_a", title: "A", directory: "/tmp")])
        claude.setSessions([EngineSession(id: "c-1", title: "B", directory: "/tmp")])
        _ = try await router.listSessions()
        openCode.setFailListing(true)
        #expect(try await router.listSessions().map(\.id) == ["ses_a", "c-1"])

        // A new router has nothing cached: the failing engine is left out, and only a total failure throws.
        let (fresh, freshOpen, freshClaude) = makeRouter()
        freshOpen.setFailListing(true)
        freshClaude.setSessions([EngineSession(id: "c-2", title: "", directory: "/tmp")])
        #expect(try await fresh.listSessions().map(\.id) == ["c-2"])
        freshClaude.setFailListing(true)
        #expect(try await fresh.listSessions().map(\.id) == ["c-2"])

        let (down, downOpen, downClaude) = makeRouter()
        downOpen.setFailListing(true)
        downClaude.setFailListing(true)
        await #expect(throws: OpenCodeError.invalidResponse("opencode is down")) {
            _ = try await down.listSessions()
        }
    }

    @Test func standardSetupRoutesClaudeProviders() async throws {
        let openCode = RouterFakeEngine(name: "opencode")
        let claude = ClaudeCodeEngine(configuration: .init(executablePath: "/nonexistent/claude",
                                                           storeURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("router-\(UUID().uuidString).json")))
        let router = EngineRouter.standard(openCode: openCode, claude: claude)
        #expect(router.registrations.map(\.id) == ["opencode", "claude"])
        #expect(router.registration(forProvider: "claude-code").id == "claude")
        #expect(router.registration(forProvider: "claude-code-api").id == "claude")
        #expect(router.registration(forProvider: "anthropic").id == "opencode")
        #expect(router.engine(ClaudeCodeEngine.self) === claude)
        #expect(router.engine(RouterFakeEngine.self) === openCode)
        let billing = try await router.modelBilling()
        #expect(billing["claude-code"] == .subscription)
        #expect(billing["claude-code-api"] == .apiKey)
    }
}
