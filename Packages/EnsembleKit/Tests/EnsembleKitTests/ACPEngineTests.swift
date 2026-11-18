#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

struct ACPTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Collects an engine's events for assertions.
actor ACPRecorder {
    private(set) var events: [EngineEvent] = []
    func append(_ event: EngineEvent) { events.append(event) }
    func mark() -> Int { events.count }

    func wait(_ what: String, after mark: Int = 0, timeout: Double = 20,
              _ predicate: @escaping @Sendable (EngineEvent) -> Bool) async throws -> EngineEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = events.dropFirst(mark).first(where: predicate) { return match }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ACPTimeout(what: what)
    }

    func all(after mark: Int, _ predicate: (EngineEvent) -> Bool) -> [EngineEvent] {
        events.dropFirst(mark).filter(predicate)
    }

    func texts(after mark: Int, session: String) -> [String] {
        events.dropFirst(mark).compactMap { if case .textEnded(session, _, let text) = $0 { text } else { nil } }
    }

    func ended(_ session: String, after mark: Int, timeout: Double = 20) async throws -> (outcome: String, error: String?) {
        let event = try await wait("turn end", after: mark, timeout: timeout) {
            if case .executionEnded(session, _, _) = $0 { true } else { false }
        }
        guard case .executionEnded(_, let outcome, let error) = event else { return ("", nil) }
        return (outcome, error)
    }

    func permission(_ session: String, after mark: Int) async throws -> PermissionRequest {
        let event = try await wait("permission prompt", after: mark) {
            if case .permissionAsked(let request) = $0 { request.sessionID == session } else { false }
        }
        guard case .permissionAsked(let request) = event else { throw ACPTimeout(what: "permission prompt") }
        return request
    }
}

/// A temporary folder with a trusted project, a session file, and the scripted fake agent (`fake_acp_agent.py`).
final class FakeACPHarness: @unchecked Sendable {
    let folder: URL
    let project: URL
    let store: URL
    let state: URL
    let log: URL
    let trust: WorkspaceTrust
    let recorder = ACPRecorder()
    private var engines: [ACPEngine] = []
    private var tasks: [Task<Void, Never>] = []

    static var pythonAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    init(trusted: Bool = true) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-acp-\(UUID().uuidString.prefix(8))")
        project = folder.appendingPathComponent("proj")
        store = folder.appendingPathComponent("acp-sessions.json")
        state = folder.appendingPathComponent("fake-state.json")
        log = folder.appendingPathComponent("fake-log.jsonl")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "alpha\n".write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        trust = WorkspaceTrust(fileURL: folder.appendingPathComponent("trusted-folders.json"), homeDirectory: "/nonexistent-home")
        if trusted { try trust.trust(project.path) }
    }

    static func definition(script: String) -> ACPAgentDefinition {
        ACPAgentDefinition(id: "fake", displayName: "Fake Agent", providerName: "Fake provider", executableNames: ["python3"],
                           arguments: [script], bypassArguments: ["--bypass"],
                           modeIDs: [.ask: "default", .acceptEdits: "accept-edits", .auto: "auto", .bypass: "auto"],
                           installHint: "Install the fake agent.", signInHint: "Run fake login.", signInCheck: .acpSession,
                           status: .verified, workspaceSettings: .alwaysLoaded,
                           environmentPassThrough: ["FAKE_ACP_LOG", "FAKE_ACP_STATE", "FAKE_ACP_INITIAL_MODE", "FAKE_ACP_NO_ALWAYS",
                                                    "FAKE_ACP_SIGNED_OUT", "FAKE_ACP_IGNORE_MODE", "FAKE_ACP_NO_MODES"])
    }

    func engine(env extra: [String: String] = [:], maxTurns: Int? = nil, executable: String = "/usr/bin/python3") -> ACPEngine {
        var env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "FAKE_ACP_LOG": log.path, "FAKE_ACP_STATE": state.path,
                   "GEMINI_API_KEY": "must-not-pass"]
        env.merge(extra) { _, new in new }
        let script = Fixtures.url("acp/fake_acp_agent.py").path
        let engine = ACPEngine(configuration: .init(agent: Self.definition(script: script), executablePath: executable, storeURL: store,
                                                    workDirectory: folder.appendingPathComponent("work"), maxConcurrentTurns: maxTurns,
                                                    baseEnvironment: env, trust: trust, requestTimeout: .seconds(20),
                                                    interruptGrace: .seconds(5)))
        let stream = engine.events()
        let recorder = recorder
        tasks.append(Task { for await event in stream { await recorder.append(event) } })
        engines.append(engine)
        return engine
    }

    /// Everything the fake agent logged: `{"received": message}` and `{"event": ...}` lines.
    var logEntries: [JSONValue] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSONValue.acpParse(line: String($0)) }
    }

    /// Params of every client message with this method, in order.
    func received(_ method: String) -> [JSONValue] {
        logEntries.compactMap { entry in
            guard let message = entry["received"], message["method"]?.stringValue == method else { return nil }
            return message["params"] ?? .null
        }
    }

    func events(_ name: String) -> [JSONValue] { logEntries.filter { $0["event"]?.stringValue == name } }

    func waitForLog(_ what: String, timeout: Double = 10, _ predicate: @escaping ([JSONValue]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(logEntries) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ACPTimeout(what: what)
    }

    func session(_ engine: ACPEngine, mode: PermissionMode = .ask, model: ModelRef? = nil) async throws -> EngineSession {
        try await engine.createSession(directory: project.path, model: model, agent: nil, permissionMode: mode, parentID: nil)
    }

    func finish() async {
        for engine in engines { await engine.shutdown() }
        for task in tasks { task.cancel() }
        try? FileManager.default.removeItem(at: folder)
    }
}

@Suite("ACP engine with a scripted agent", .serialized, .enabled(if: FakeACPHarness.pythonAvailable))
struct ACPEngineTests {
    @Test func promptStreamsAndEnds() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)
        #expect(session.title == "New session")
        let mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello world", files: [])
        let end = try await h.recorder.ended(session.id, after: mark)
        #expect(end.outcome == "succeeded")
        #expect(end.error == nil)
        #expect(await h.recorder.texts(after: mark, session: session.id) == ["Echo: hello world"])
        let items = try await engine.transcript(session.id)
        guard case .user(_, "hello world", _)? = items.first else { Issue.record("first row is not the prompt"); await h.finish(); return }
        #expect(ACPFixtures.texts(items) == ["Echo: hello world"])
        // The agent's title replaces the one Ensemble made from the prompt.
        #expect(try await engine.listSessions().first?.title == "Fake: hello world")
        let usage = await h.recorder.all(after: mark) { if case .usageUpdated(session.id, _) = $0 { true } else { false } }.last
        #expect(usage == .usageUpdated(sessionID: session.id, Usage(inputTokens: 10, outputTokens: 5, reasoningTokens: 1, cacheReadTokens: 2)))
        let context = try await engine.context(session.id)
        #expect(context.usedTokens == 100)
        #expect(context.limitTokens == 1000)

        let initialize = try #require(h.received("initialize").first)
        #expect(initialize["protocolVersion"]?.acpInt == 1)
        #expect(initialize["clientCapabilities"]?["terminal"]?.acpBool == false)
        #expect(initialize["clientCapabilities"]?["fs"]?["writeTextFile"]?.acpBool == false)
        // The mode is set explicitly when the session opens, even though the agent already reported `default`.
        #expect(h.received("session/set_config_option").contains { $0["configId"] == "mode" && $0["value"] == "default" })
        // The agent gets the folder with links resolved (the temporary folder is under /var, a link to /private/var).
        #expect(h.received("session/new").first?["cwd"]?.stringValue == WorkspaceTrust.resolvedPath(h.project.path))
        #expect(h.received("session/new").first?["cwd"]?.stringValue?.hasPrefix("/private/") == true)
        let prompt = try #require(h.received("session/prompt").first)
        #expect(prompt["prompt"]?.arrayValue?.first?["text"]?.stringValue == "hello world")
        await h.finish()
    }

    @Test func permissionOnceAlwaysAndReject() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)

        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "edit the notes", files: [])
        let request = try await h.recorder.permission(session.id, after: mark)
        #expect(request.kind == "edit")
        #expect(request.title == "notes.txt")
        #expect(request.detail?.contains("-alpha\n+beta") == true)
        #expect(request.alwaysPatterns == ["edits to notes.txt"])
        #expect(try await engine.pendingPermissions().map(\.id) == [request.id])
        _ = try await h.recorder.wait("waiting", after: mark) { $0 == .activity(sessionID: session.id, .waitingForPermission) }
        try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
        #expect(try await engine.pendingPermissions().isEmpty)
        let edited = ACPFixtures.tools(try await engine.transcript(session.id))
        #expect(edited.last?.status == .succeeded)
        #expect(edited.last?.diff?.contains("+beta") == true)
        #expect(try await engine.changedFiles(session.id).first?.path == "notes.txt")

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "edit again", files: [])
        let second = try await h.recorder.permission(session.id, after: mark)
        try await engine.replyPermission(sessionID: session.id, requestID: second.id, decision: .always, message: nil)
        _ = try await h.recorder.ended(session.id, after: mark)

        // "Always" was for that edit only; a command still asks.
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the shell", files: [])
        let third = try await h.recorder.permission(session.id, after: mark)
        #expect(third.kind == "bash")
        try await engine.replyPermission(sessionID: session.id, requestID: third.id, decision: .reject, message: "no")
        _ = try await h.recorder.ended(session.id, after: mark)
        #expect(ACPFixtures.tools(try await engine.transcript(session.id)).last?.status == .failed)

        // "Always" reaches the agent as a one-time allow; the agent's own "always" option is never sent.
        let answers = h.events("permission_answer").compactMap { $0["outcome"]?["optionId"]?.stringValue }
        #expect(answers == ["allow", "allow", "deny"])
        await engine.shutdown()
        await h.finish()
    }

    @Test func alwaysIsRememberedWhenTheAgentOffersOnlyOnce() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine(env: ["FAKE_ACP_NO_ALWAYS": "1"])
        let session = try await h.session(engine)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "edit the notes", files: [])
        let request = try await h.recorder.permission(session.id, after: mark)
        try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .always, message: nil)
        _ = try await h.recorder.ended(session.id, after: mark)

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "edit the notes", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
        #expect(await h.recorder.all(after: mark) { if case .permissionAsked = $0 { true } else { false } }.isEmpty)
        #expect(h.events("permission_answer").compactMap { $0["outcome"]?["optionId"]?.stringValue } == ["allow", "allow"])
        await h.finish()
    }

    @Test func alwaysWithoutAConcreteSubjectAllowsOnceOnly() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)
        for text in ["mystery job", "outside change"] {
            var mark = await h.recorder.mark()
            try await engine.prompt(session.id, text: text, files: [])
            let first = try await h.recorder.permission(session.id, after: mark)
            #expect(first.alwaysPatterns == [ACPAlwaysRules.thisRequestOnly])
            try await engine.replyPermission(sessionID: session.id, requestID: first.id, decision: .always, message: nil)
            #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
            // The same call again asks again.
            mark = await h.recorder.mark()
            try await engine.prompt(session.id, text: text, files: [])
            let second = try await h.recorder.permission(session.id, after: mark)
            try await engine.replyPermission(sessionID: session.id, requestID: second.id, decision: .reject, message: nil)
            _ = try await h.recorder.ended(session.id, after: mark)
        }
        let outside = h.events("permission_answer").compactMap { $0["outcome"]?["optionId"]?.stringValue }
        #expect(outside == ["allow", "deny", "allow", "deny"])
        await h.finish()
    }

    @Test func interruptCancelsTheTurnAndOpenPrompts() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)

        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "go slow", files: [])
        _ = try await h.recorder.wait("first delta", after: mark) { if case .textDelta(session.id, _, _) = $0 { true } else { false } }
        try await engine.interrupt(session.id)
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "interrupted")
        #expect(h.received("session/cancel").count == 1)
        #expect(h.events("prompt_end").last?["stop"] == "cancelled")

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "edit the notes", files: [])
        let request = try await h.recorder.permission(session.id, after: mark)
        try await engine.interrupt(session.id)
        _ = try await h.recorder.wait("prompt withdrawn", after: mark) { $0 == .permissionReplied(sessionID: session.id, requestID: request.id) }
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "interrupted")
        #expect(h.events("permission_answer").last?["outcome"]?["outcome"] == "cancelled")
        #expect(try await engine.pendingPermissions().isEmpty)
        await #expect(throws: ACPEngineError.self) {
            try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
        }

        // The session still works afterwards.
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "still there?", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
        await h.finish()
    }

    /// A user preset that runs commands without asking (Antigravity's Turbo) must not reach an Ask session: Ensemble
    /// sets the mode on every session open, including after a restart (`session/load` starts in the preset again).
    @Test func turboPresetDoesNotLeakIntoAnAskSession() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine(env: ["FAKE_ACP_INITIAL_MODE": "turbo"])
        let session = try await h.session(engine, mode: .ask)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the shell", files: [])
        let request = try await h.recorder.permission(session.id, after: mark)
        #expect(request.kind == "bash")
        #expect(request.title == "echo hi")
        try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .reject, message: nil)
        _ = try await h.recorder.ended(session.id, after: mark)
        await engine.shutdown()

        let restarted = h.engine(env: ["FAKE_ACP_INITIAL_MODE": "turbo"])
        mark = await h.recorder.mark()
        try await restarted.prompt(session.id, text: "run the shell again", files: [])
        let again = try await h.recorder.permission(session.id, after: mark)
        try await restarted.replyPermission(sessionID: session.id, requestID: again.id, decision: .once, message: nil)
        _ = try await h.recorder.ended(session.id, after: mark)

        #expect(h.received("session/load").count == 1)
        let modes = h.received("session/set_config_option").filter { $0["configId"] == "mode" }.compactMap { $0["value"]?.stringValue }
        #expect(modes == ["default", "default"])
        #expect(h.events("shell").map { $0["asked"]?.acpBool } == [true, true])
        await h.finish()
    }

    @Test func agentThatKeepsItsOwnModeGetsNoWork() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine(env: ["FAKE_ACP_INITIAL_MODE": "turbo", "FAKE_ACP_IGNORE_MODE": "1"])
        let session = try await h.session(engine, mode: .ask)
        let mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the shell", files: [])
        let end = try await h.recorder.ended(session.id, after: mark)
        #expect(end.outcome == "failed")
        #expect(end.error?.contains("did not switch to default") == true)
        #expect(h.received("session/prompt").isEmpty)
        await h.finish()
    }

    @Test func agentWithNoMatchingModeGetsNoWorkUnlessBypass() async throws {
        // An agent that reports no modes at all keeps whatever its own config says (Turbo, say), so
        // Ensemble refuses to send work in every mode but Bypass.
        let h = try FakeACPHarness()
        let engine = h.engine(env: ["FAKE_ACP_INITIAL_MODE": "turbo", "FAKE_ACP_NO_MODES": "1"])
        let session = try await h.session(engine, mode: .ask)
        let mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the shell", files: [])
        let end = try await h.recorder.ended(session.id, after: mark, timeout: 5)
        #expect(end.outcome == "failed")
        #expect(end.error?.contains("did not switch to Ask permissions") == true)
        #expect(await h.recorder.all(after: mark) { $0 == .activity(sessionID: session.id, .failed) }.count == 1)
        #expect(h.received("session/prompt").isEmpty)
        #expect(h.received("session/set_config_option").isEmpty)

        // Bypass is the one mode that may run without a matching agent mode.
        try await engine.setPermissionMode(session.id, mode: .bypass)
        let bypassMark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the shell", files: [])
        #expect(try await h.recorder.ended(session.id, after: bypassMark).outcome == "succeeded")
        #expect(h.received("session/prompt").count == 1)
        await h.finish()
    }

    @Test func historyComesBackAfterARestart() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)
        try await engine.injectSynthetic(session.id, text: "[Room] Ada: hi there", wake: false)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        let sent = try #require(h.received("session/prompt").last?["prompt"]?.arrayValue)
        #expect(sent.compactMap { $0["text"]?.stringValue } == ["[Room] Ada: hi there", "hello"])
        let live = try await engine.transcript(session.id)
        #expect(live.contains { if case .notice(_, "[Room] Ada: hi there") = $0 { true } else { false } })
        await engine.shutdown()

        let restarted = h.engine()
        #expect(try await restarted.listSessions().contains { $0.id == session.id })
        let items = try await restarted.transcript(session.id)
        #expect(items.contains { if case .user(_, let text, _) = $0 { text.contains("hello") } else { false } })
        #expect(ACPFixtures.texts(items).last?.hasPrefix("Echo:") == true)
        #expect(h.received("session/load").count == 1)

        mark = await h.recorder.mark()
        try await restarted.prompt(session.id, text: "and again", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
        #expect(await h.recorder.texts(after: mark, session: session.id) == ["Echo: and again"])
        #expect(h.received("session/load").count == 1)
        await h.finish()
    }

    @Test func modelsEffortAndCommands() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let models = try await engine.models()
        #expect(models.map(\.ref.description) == ["fake/fake-fast", "fake/fake-smart"])
        #expect(models.first?.variants == ["low", "medium", "high"])
        #expect(models.first?.providerName == "Fake provider")
        #expect(try await engine.modelOptions(for: ModelRef(providerID: "fake", id: "fake-smart")).effortLevels == [.low, .medium, .high])
        #expect(try await engine.providers() == [ProviderInfo(id: "fake", name: "Fake provider", connected: true)])
        let probeCommands = try await engine.commands(directory: nil)
        #expect(probeCommands.map(\.name) == ["compact", "review"])
        #expect(probeCommands.last?.argumentHint == "<target>")

        let session = try await h.session(engine, model: ModelRef(providerID: "fake", id: "fake-smart", variant: "high"))
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        var options = h.received("session/set_config_option").map { "\($0["configId"]?.stringValue ?? "")=\($0["value"]?.stringValue ?? "")" }
        #expect(options == ["model=fake-smart", "thought_level=high", "mode=default"])

        try await engine.switchModel(session.id, model: ModelRef(providerID: "fake", id: "fake-fast", variant: "low"))
        try await engine.setEffort(session.id, effort: .medium)
        options = h.received("session/set_config_option").map { "\($0["configId"]?.stringValue ?? "")=\($0["value"]?.stringValue ?? "")" }
        #expect(options.suffix(3) == ["model=fake-fast", "thought_level=low", "thought_level=medium"])
        #expect(try await engine.listSessions().first?.model == ModelRef(providerID: "fake", id: "fake-fast", variant: "medium"))
        await #expect(throws: ACPEngineError.self) { try await engine.setEffort(session.id, effort: .max) }
        await #expect(throws: ACPEngineError.self) { try await engine.switchModel(session.id, model: ModelRef(providerID: "other", id: "x")) }
        await #expect(throws: ACPEngineError.self) { try await engine.setFastMode(session.id, enabled: true) }

        #expect(try await engine.commands(directory: h.project.path).map(\.name) == ["compact", "review"])
        mark = await h.recorder.mark()
        try await engine.runCommand(session.id, name: "/review", arguments: "main")
        _ = try await h.recorder.ended(session.id, after: mark)
        #expect(h.received("session/prompt").last?["prompt"]?.arrayValue?.first?["text"]?.stringValue == "/review main")
        // The probe session in Ensemble's own folder was closed again.
        #expect(h.received("session/close").count == 1)
        await h.finish()
    }

    @Test func turnLimitQueuesTurnsAcrossSessions() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine(maxTurns: 1)
        let first = try await h.session(engine)
        let second = try await h.session(engine)
        let mark = await h.recorder.mark()
        try await engine.prompt(first.id, text: "go slow", files: [])
        _ = try await h.recorder.wait("first delta", after: mark) { if case .textDelta(first.id, _, _) = $0 { true } else { false } }
        try await engine.prompt(second.id, text: "hello", files: [])
        try await Task.sleep(for: .milliseconds(400))
        #expect(h.events("prompt_start").count == 1)
        try await engine.interrupt(first.id)
        #expect(try await h.recorder.ended(second.id, after: mark).outcome == "succeeded")
        #expect(h.events("prompt_start").compactMap { $0["active"]?.acpInt }.max() == 1)
        await h.finish()
    }

    @Test func plansThoughtsAndNewFiles() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine, mode: .acceptEdits)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "make a plan", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        let todos = TodoParser.latest(in: try await engine.transcript(session.id))
        #expect(todos?.map(\.content) == ["Read the notes", "Write the summary", "Review"])
        #expect(todos?.map(\.status) == [.completed, .inProgress, .pending])

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "think first", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        #expect(!(await h.recorder.all(after: mark) { if case .reasoningDelta(session.id, _, "Thinking about it.") = $0 { true } else { false } }).isEmpty)

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "write a file", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        #expect(await h.recorder.all(after: mark) { if case .permissionAsked = $0 { true } else { false } }.isEmpty)
        let tool = ACPFixtures.tools(try await engine.transcript(session.id)).last
        #expect(tool?.name == "write")
        #expect(tool?.title == "hello.txt")
        #expect(tool?.diff?.hasPrefix("--- /dev/null\n+++ b/hello.txt") == true)
        let changes = try await engine.changedFiles(session.id)
        #expect(changes.first { $0.path == "hello.txt" }?.kind == .added)
        #expect(h.received("session/set_config_option").contains { $0["configId"] == "mode" && $0["value"] == "accept-edits" })
        await h.finish()
    }

    @Test func bypassRunsInItsOwnProcessWithTheSwitch() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        try await engine.setPermissionMode(session.id, mode: .bypass)
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the shell", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
        #expect(await h.recorder.all(after: mark) { if case .permissionAsked = $0 { true } else { false } }.isEmpty)
        let starts = h.events("start").map { $0["argv"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        #expect(starts.count == 2)
        #expect(starts.filter { $0.contains("--bypass") }.count == 1)
        // The session moved: closed in the first process, loaded in the second.
        #expect(h.received("session/close").count == 1)
        #expect(h.received("session/load").count == 1)
        // Extra arguments can never add the skip-permissions switch to the normal process.
        let script = Fixtures.url("acp/fake_acp_agent.py").path
        let extra = ACPEngine(configuration: .init(agent: FakeACPHarness.definition(script: script), executablePath: "/usr/bin/python3",
                                                   storeURL: h.store, workDirectory: h.folder.appendingPathComponent("work"),
                                                   extraArguments: ["--bypass"], baseEnvironment: ["HOME": NSHomeDirectory(), "FAKE_ACP_LOG": h.log.path],
                                                   trust: h.trust))
        _ = try await extra.models()
        #expect(h.events("start").last?["argv"]?.arrayValue?.compactMap(\.stringValue).contains("--bypass") == false)
        await extra.shutdown()
        await h.finish()
    }

    @Test func untrustedFoldersAreRefused() async throws {
        let h = try FakeACPHarness(trusted: false)
        let engine = h.engine()
        await #expect(throws: ACPEngineError.folderNotTrusted(h.project.path)) {
            try await engine.createSession(directory: h.project.path, model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        }
        try h.trust.trust(h.project.path)
        let session = try await h.session(engine)
        try h.trust.revoke(h.project.path)
        await #expect(throws: ACPEngineError.folderNotTrusted(h.project.path)) { try await engine.prompt(session.id, text: "hi", files: []) }
        // Viewing an untrusted session never starts the agent.
        #expect(try await engine.transcript(session.id).isEmpty)
        #expect(h.events("start").isEmpty)
        await h.finish()
    }

    @Test func signedOutAndNotInstalled() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine(env: ["FAKE_ACP_SIGNED_OUT": "1"])
        let state = await engine.authState(refresh: true)
        #expect(state.installed)
        #expect(state.signedIn == false)
        #expect(try await engine.providers().first?.connected == false)
        let session = try await h.session(engine)
        let mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hi", files: [])
        let end = try await h.recorder.ended(session.id, after: mark)
        #expect(end.outcome == "failed")
        #expect(end.error?.contains("Run fake login.") == true)

        let missing = h.engine(executable: "/nonexistent/python3")
        let other = try await h.session(missing)
        await #expect(throws: ACPEngineError.notInstalled(agent: "Fake Agent", hint: "Install the fake agent.")) {
            try await missing.prompt(other.id, text: "hi", files: [])
        }
        #expect(try await missing.models().isEmpty)
        #expect(await missing.authState(refresh: true).installed == false)
        await #expect(throws: ACPEngineError.self) { try await missing.serverInfo() }
        await h.finish()
    }

    @Test func sessionBookkeeping() async throws {
        let h = try FakeACPHarness()
        let engine = h.engine()
        let session = try await h.session(engine)
        await #expect(throws: ACPEngineError.self) {
            try await engine.createSession(directory: h.project.path, model: ModelRef(providerID: "openai", id: "gpt"), agent: nil,
                                           permissionMode: .ask, parentID: nil)
        }
        await #expect(throws: ACPEngineError.self) {
            try await engine.createSession(directory: "/no/such/folder", model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        }
        try await engine.renameSession(session.id, title: "Mine")
        try await engine.setArchived(session.id, archived: true)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello", files: [])
        _ = try await h.recorder.ended(session.id, after: mark)
        // A custom title is kept when the agent sends its own.
        #expect(try await engine.listSessions().first?.title == "Mine")
        #expect(try await engine.listSessions().first?.archived == true)
        #expect(try await engine.schedules().isEmpty)
        await #expect(throws: ACPEngineError.self) { try await engine.setAPIKey(providerID: "fake", key: "k") }

        let version = try await engine.serverInfo()
        #expect(version.version == "0.1")
        mark = await h.recorder.mark()
        try await engine.deleteSession(session.id)
        #expect(try await engine.listSessions().isEmpty)
        _ = try await h.recorder.wait("deleted", after: mark) { $0 == .sessionDeleted(sessionID: session.id) }
        #expect(h.received("session/close").count == 1)
        // API keys from Ensemble's environment never reach the agent.
        let env = h.events("start").first?["env"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(env.contains("HOME"))
        #expect(!env.contains("GEMINI_API_KEY"))
        await h.finish()
    }
}
#endif
