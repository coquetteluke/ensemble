#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// End-to-end tests against the real local OpenCode service and the scripted mock model (`tools/mock-llm`).
/// They run only with `ENSEMBLE_LIVE_TESTS=1` (see `scripts/test-live.sh`). Each test works in a fresh temporary
/// project folder with its own `opencode.json`, and deletes the sessions it creates. The shared service is left running.
enum LiveConfig {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_TESTS"] == "1" }

    static var repoRoot: URL {
        if let root = ProcessInfo.processInfo.environment["ENSEMBLE_REPO_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent() // EnsembleKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // EnsembleKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo
    }
}

struct LiveTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Collects events from `client.events()` so tests can wait for them.
actor EventRecorder {
    private(set) var events: [EngineEvent] = []

    func append(_ event: EngineEvent) { events.append(event) }

    func all() -> [EngineEvent] { events }

    func first(where predicate: @Sendable (EngineEvent) -> Bool) -> EngineEvent? { events.first(where: predicate) }

    /// Position to wait from, so a wait only sees events that arrive after it.
    func mark() -> Int { events.count }

    func waitFor(_ what: String, after mark: Int = 0, timeout: Double = 30,
                 _ predicate: @escaping @Sendable (EngineEvent) -> Bool) async throws -> EngineEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = events.dropFirst(mark).first(where: predicate) { return match }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LiveTimeout(what: what)
    }
}

final class LiveHarness: @unchecked Sendable {
    let directory: URL
    let client: OpenCodeClient
    let recorder = EventRecorder()
    private let mock: Process
    private var eventTask: Task<Void, Never>?
    private let lock = NSLock()
    private var createdSessions: [String] = []

    var path: String { directory.path }

    private init(directory: URL, client: OpenCodeClient, mock: Process) {
        self.directory = directory
        self.client = client
        self.mock = mock
    }

    static func start() async throws -> LiveHarness {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("ensemble-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Mock model on a free port.
        let script = LiveConfig.repoRoot.appendingPathComponent("tools/mock-llm/mock_llm.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw LiveTimeout(what: "tools/mock-llm/mock_llm.py (set ENSEMBLE_REPO_ROOT)")
        }
        let portFile = directory.appendingPathComponent(".mock-port")
        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        mock.arguments = [
            script.path,
            "--port", "0", "--port-file", portFile.path,
            "--script", LiveConfig.repoRoot.appendingPathComponent("tools/mock-llm/test-script.json").path,
            "--log", directory.appendingPathComponent(".mock-requests.jsonl").path,
        ]
        mock.standardOutput = FileHandle.nullDevice
        mock.standardError = FileHandle.nullDevice
        try mock.run()
        var port: String?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), !text.isEmpty { port = text; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let port else {
            mock.terminate()
            throw LiveTimeout(what: "mock model to start")
        }

        // Project config: the mock provider, mock as default model, schedules on.
        let template = try String(contentsOf: LiveConfig.repoRoot.appendingPathComponent("tools/mock-llm/opencode.json.example"), encoding: .utf8)
        try template.replacingOccurrences(of: "PORT", with: port)
            .write(to: directory.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        try ".mock-port\n.mock-requests.jsonl\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", directory.path]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try? git.run()
        git.waitUntilExit()

        let client = try OpenCodeClient.fromServiceFile(defaultDirectory: directory.path)
        let harness = LiveHarness(directory: directory, client: client, mock: mock)
        try await harness.startEvents()
        return harness
    }

    private func startEvents() async throws {
        let recorder = self.recorder
        let stream = client.events()
        eventTask = Task {
            for await event in stream { await recorder.append(event) }
        }
        _ = try await recorder.waitFor("event stream to connect", timeout: 10) { $0 == .other(type: "server.connected") }
    }

    func createSession(_ mode: PermissionMode, model: ModelRef? = ModelRef(providerID: "mock", id: "mock-1"),
                       parentID: String? = nil) async throws -> EngineSession {
        let session = try await client.createSession(directory: path, model: model, agent: nil, permissionMode: mode, parentID: parentID)
        lock.withLock { createdSessions.append(session.id) }
        return session
    }

    func track(_ sessionID: String) {
        lock.withLock { createdSessions.append(sessionID) }
    }

    /// Sends a prompt and waits for that run to end. Returns the outcome.
    func run(_ sessionID: String, _ text: String) async throws -> String {
        let mark = await recorder.mark()
        try await client.prompt(sessionID, text: text, files: [])
        return try await waitForEnd(of: sessionID, after: mark)
    }

    func waitForEnd(of sessionID: String, after mark: Int = 0, timeout: Double = 30) async throws -> String {
        let event = try await recorder.waitFor("execution of \(sessionID) to end", after: mark, timeout: timeout) { event in
            if case .executionEnded(let id, _, _) = event { return id == sessionID }
            return false
        }
        guard case .executionEnded(_, let outcome, _) = event else { return "" }
        return outcome
    }

    func cleanup() async {
        eventTask?.cancel()
        let sessions = lock.withLock { createdSessions }
        for id in sessions.reversed() {
            try? await client.deleteSession(id)
        }
        mock.terminate()
        mock.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}

func withHarness(_ body: (LiveHarness) async throws -> Void) async throws {
    let harness = try await LiveHarness.start()
    do {
        try await body(harness)
    } catch {
        await harness.cleanup()
        throw error
    }
    await harness.cleanup()
}

@Suite(.serialized, .enabled(if: LiveConfig.enabled))
struct LiveEngineTests {
    @Test func streamsTextAndUsage() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.ask)
            #expect(session.directory == h.path)
            #expect(session.model == ModelRef(providerID: "mock", id: "mock-1"))
            #expect(try await h.run(session.id, "hello there") == "succeeded")

            let events = await h.recorder.all()
            let deltas = events.compactMap { event -> String? in
                if case .textDelta(let id, _, let delta) = event, id == session.id { return delta }
                return nil
            }
            #expect(deltas.joined() == "Hello from the mock model. Nice to meet you.")
            let ended = try #require(events.compactMap { event -> (String, String)? in
                if case .textEnded(let id, let item, let text) = event, id == session.id { return (item, text) }
                return nil
            }.first)
            #expect(ended.1 == "Hello from the mock model. Nice to meet you.")
            #expect(events.contains(.activity(sessionID: session.id, .working)))
            let usage = try #require(events.compactMap { event -> Usage? in
                if case .usageUpdated(let id, let usage) = event, id == session.id { return usage }
                return nil
            }.last)
            #expect(usage.inputTokens > 0)
            #expect(usage.outputTokens > 0)

            // The transcript row has the same id as the streamed text.
            let transcript = try await h.client.transcript(session.id)
            #expect(transcript.first.map { if case .user(_, let text, _) = $0 { text } else { "" } } == "hello there")
            #expect(transcript.contains(.agentText(id: ended.0, text: ended.1, agentID: nil, streaming: false)))
        }
    }

    @Test func permissionAskAndReplyOnce() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.ask)
            try await h.client.prompt(session.id, text: "please run the echo command", files: [])
            let asked = try await h.recorder.waitFor("permission prompt") { event in
                if case .permissionAsked(let request) = event { return request.sessionID == session.id }
                return false
            }
            guard case .permissionAsked(let request) = asked else { return }
            #expect(request.kind == "shell")
            #expect(request.title == "echo ensemble-ok")
            #expect(await h.recorder.first { $0 == .activity(sessionID: session.id, .waitingForPermission) } != nil)

            let pending = try await h.client.pendingPermissions()
            #expect(pending.contains { $0.id == request.id })
            #expect(try await h.client.pendingPermissions(sessionID: session.id).map(\.id) == [request.id])

            let beforeReply = await h.recorder.mark()
            try await h.client.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
            #expect(try await h.waitForEnd(of: session.id, after: beforeReply) == "succeeded")

            let events = await h.recorder.all()
            #expect(events.contains(.permissionReplied(sessionID: session.id, requestID: request.id)))
            let tool = try #require(events.compactMap { event -> ToolCallInfo? in
                if case .toolUpdated(let id, let info) = event, id == session.id, info.status == .succeeded { return info }
                return nil
            }.last)
            #expect(tool.name == "shell")
            #expect(tool.outputPreview == "ensemble-ok\n")

            let transcript = try await h.client.transcript(session.id)
            #expect(transcript.contains { if case .tool(let info) = $0 { info.id == tool.id && info.status == .succeeded } else { false } })
            #expect(try await h.client.pendingPermissions(sessionID: session.id).isEmpty)
        }
    }

    @Test func autoModeRunsSafeCommandsAndAsksForOthers() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.auto)
            #expect(try await h.run(session.id, "auto safe please") == "succeeded")
            let safeAsk = await h.recorder.first { if case .permissionAsked(let r) = $0 { r.sessionID == session.id } else { false } }
            #expect(safeAsk == nil, "git status should run without asking in Auto")

            let beforeRisky = await h.recorder.mark()
            try await h.client.prompt(session.id, text: "auto risky please", files: [])
            let asked = try await h.recorder.waitFor("permission prompt for rm", after: beforeRisky) { event in
                if case .permissionAsked(let request) = event { return request.sessionID == session.id }
                return false
            }
            guard case .permissionAsked(let request) = asked else { return }
            #expect(request.title.contains("rm -r -f nothing-here-ensemble"))
            try await h.client.replyPermission(sessionID: session.id, requestID: request.id, decision: .reject, message: "Not now")
            let failed = try await h.recorder.waitFor("rejected tool to fail") { event in
                if case .toolUpdated(let id, let info) = event { return id == session.id && info.status == .failed }
                return false
            }
            guard case .toolUpdated(_, let info) = failed else { return }
            #expect(info.name == "shell")
        }
    }

    @Test func subagentCreatesChildSession() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.bypass)
            try await h.client.prompt(session.id, text: "please start a helper", files: [])
            let created = try await h.recorder.waitFor("child session") { event in
                if case .sessionCreated(let child) = event { return child.parentID == session.id }
                return false
            }
            guard case .sessionCreated(let child) = created else { return }
            #expect(child.title == "Mock helper task")
            #expect(child.directory == h.path)
            _ = try await h.recorder.waitFor("subagent report reply") { event in
                if case .textEnded(let id, _, let text) = event { return id == session.id && text == "The helper reported back." }
                return false
            }
            let tool = await h.recorder.all().compactMap { event -> ToolCallInfo? in
                if case .toolUpdated(let id, let info) = event, id == session.id, info.name == "subagent", info.status == .succeeded { return info }
                return nil
            }.last
            #expect(tool?.childSessionID == child.id)
            #expect(try await h.client.children(session.id).map(\.id) == [child.id])
            let childTranscript = try await h.client.transcript(child.id)
            #expect(childTranscript.contains { if case .agentText(_, let text, _, _) = $0 { text == "Child finished the task." } else { false } })
        }
    }

    @Test func syntheticMessagesAndInterrupt() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.ask)
            let beforeSynthetic = await h.recorder.mark()
            try await h.client.injectSynthetic(session.id, text: "[Board] Alice: board relay marker", wake: true)
            #expect(try await h.waitForEnd(of: session.id, after: beforeSynthetic) == "succeeded")
            var transcript = try await h.client.transcript(session.id)
            #expect(transcript.contains { if case .notice(_, let text) = $0 { text == "[Board] Alice: board relay marker" } else { false } })
            #expect(transcript.contains { if case .agentText(_, let text, _, _) = $0 { text == "Got the board message." } else { false } })

            try await h.client.injectSynthetic(session.id, text: "[Board] Bob: queued note", wake: false)
            transcript = try await h.client.transcript(session.id)
            #expect(!transcript.contains { if case .notice(_, let text) = $0 { text.contains("queued note") } else { false } })

            let beforeSlow = await h.recorder.mark()
            try await h.client.prompt(session.id, text: "go slow now", files: [])
            _ = try await h.recorder.waitFor("slow text to start", after: beforeSlow) { event in
                if case .textDelta(let id, _, _) = event { return id == session.id }
                return false
            }
            try await h.client.interrupt(session.id)
            let outcome = try await h.recorder.waitFor("interrupted outcome") { event in
                if case .executionEnded(let id, let outcome, _) = event { return id == session.id && outcome == "interrupted" }
                return false
            }
            #expect(outcome == .executionEnded(sessionID: session.id, outcome: "interrupted", error: nil))
            transcript = try await h.client.transcript(session.id)
            #expect(transcript.contains { if case .notice(_, let text) = $0 { text == "Interrupted" } else { false } })
            // The queued note was delivered with the prompt.
            #expect(transcript.contains { if case .notice(_, let text) = $0 { text.contains("queued note") } else { false } })
        }
    }

    @Test func contextModelsAndChangedFiles() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.acceptEdits)
            #expect(try await h.run(session.id, "now write a file") == "succeeded")
            #expect(try await h.run(session.id, "edit the file please") == "succeeded")

            let files = try await h.client.changedFiles(session.id)
            let hello = try #require(files.first { $0.path == "hello.txt" })
            #expect(hello.kind == .added)
            #expect(hello.diff?.contains("+hello from mock") == true)

            let transcript = try await h.client.transcript(session.id)
            let edit = transcript.compactMap { if case .tool(let info) = $0, info.name == "edit" { info } else { nil } }.first
            #expect(edit?.diff?.contains("-hi from mock") == true)
            #expect(transcript.contains { if case .reasoning(_, let text, false) = $0 { text == "I should change the greeting." } else { false } })

            let context = try await h.client.context(session.id)
            #expect(context.limitTokens == 128_000)
            #expect(context.usedTokens > 0)
            #expect(context.categories.map(\.key).contains("free"))
            #expect(context.categories.first { $0.key == "tools" }!.tokens > 0)

            let models = try await h.client.models(directory: h.path)
            #expect(models.first?.id == "mock/mock-1")
            #expect(models.first?.providerName == "Mock LLM")
            #expect(try await h.client.defaultModel(directory: h.path) == ModelRef(providerID: "mock", id: "mock-1"))
            #expect(try await h.client.connectors(directory: h.path).isEmpty)
        }
    }

    @Test func sessionManagement() async throws {
        try await withHarness { h in
            let session = try await h.createSession(.ask)
            try await h.client.renameSession(session.id, title: "Renamed by Ensemble")
            _ = try await h.recorder.waitFor("session update") { event in
                if case .sessionUpdated(let updated) = event { return updated.id == session.id && updated.title == "Renamed by Ensemble" }
                return false
            }
            try await h.client.setPermissionMode(session.id, mode: .bypass)
            try await h.client.switchModel(session.id, model: ModelRef(providerID: "mock", id: "mock-1", variant: "high"))
            try await h.client.setArchived(session.id, archived: true)
            var fetched = try await h.client.session(session.id)
            #expect(fetched.title == "Renamed by Ensemble")
            #expect(fetched.archived)
            #expect(fetched.model == ModelRef(providerID: "mock", id: "mock-1", variant: "high"))
            try await h.client.setArchived(session.id, archived: false)
            fetched = try await h.client.session(session.id)
            #expect(!fetched.archived)

            let listed = try await h.client.sessions(directory: h.path)
            #expect(listed.contains { $0.id == session.id })
            #expect(try await h.client.listSessions().contains { $0.id == session.id })

            try await h.client.deleteSession(session.id)
            _ = try await h.recorder.waitFor("delete event") { $0 == .sessionDeleted(sessionID: session.id) }
        }
    }

    @Test func schedulesLifecycle() async throws {
        try await withHarness { h in
            let schedule = try await h.client.createSchedule(title: "Ensemble nightly", prompt: "hello nightly", directory: h.path,
                                                             schedule: "0 3 * * *", model: ModelRef(providerID: "mock", id: "mock-1"))
            #expect(schedule.title == "Ensemble nightly")
            #expect(schedule.schedule == "0 3 * * *")
            #expect(schedule.directory == h.path)
            #expect(!schedule.paused)
            #expect(schedule.nextRun != nil)
            let owner = try await h.client.sessions(directory: h.path).first { $0.title == "Ensemble nightly" }
            if let owner { h.track(owner.id) }

            let all = try await h.client.schedules()
            #expect(all.contains { $0.id == schedule.id })
            try await h.client.setSchedulePaused(schedule.id, paused: true)
            #expect(try await h.client.schedules().first { $0.id == schedule.id }?.paused == true)
            try await h.client.setSchedulePaused(schedule.id, paused: false)
            try await h.client.deleteSchedule(schedule.id)
            #expect(try await h.client.schedules().contains { $0.id == schedule.id } == false)

            let every = try await h.client.createSchedule(title: "Every few", prompt: "hello", directory: h.path, schedule: "every 30 minutes", model: nil)
            #expect(every.schedule == "every 30 minutes")
            if let owner = try await h.client.sessions(directory: h.path).first(where: { $0.title == "Every few" }) { h.track(owner.id) }
            try await h.client.deleteSchedule(every.id)
        }
    }

    @Test func providersAndKeys() async throws {
        try await withHarness { h in
            let providers = try await h.client.providers()
            #expect(Array(providers.prefix(5).map(\.id)) == ["anthropic", "openai", "xai", "google", "openrouter"])
            // A fake key on an obscure provider, removed straight away.
            let provider = "fiftyx"
            #expect(providers.first { $0.id == provider }?.connected == false)
            do {
                try await h.client.setAPIKey(providerID: provider, key: "fake-ensemble-test-key-not-real")
                #expect(try await h.client.providers().first { $0.id == provider }?.connected == true)
            } catch {
                try? await h.client.removeAPIKey(providerID: provider)
                throw error
            }
            try await h.client.removeAPIKey(providerID: provider)
            #expect(try await h.client.providers().first { $0.id == provider }?.connected == false)
        }
    }

    @Test @MainActor func engineManagerFindsTheRunningService() async throws {
        let manager = EngineManager()
        let healthy = await manager.checkNow()
        #expect(healthy)
        guard case .running(let version, let url) = manager.status else {
            Issue.record("status is \(manager.status)")
            return
        }
        #expect(EngineVersion(version)! >= .minimum)
        #expect(url == (try ServiceFile.read()).url)
        #expect(manager.installedVersion != nil)
        #expect(try await manager.client?.serverInfo().version == version)
    }
}
#endif
