#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// End to end through `ACPEngine` with the real tools. Runs only with `ENSEMBLE_LIVE_ACP=1`.
/// - Antigravity: the official `agy acp`, signed in as the Mac's user, on the cheapest model (Gemini 3.8 Flash, low
///   effort), three short turns per run. Also checks that the user's own Antigravity preset (Turbo on the test Mac)
///   does not reach an Ask session: the shell command must ask.
/// - OpenCode: `opencode acp` with the scripted mock model from `tools/mock-llm` (no keys, no cost).
enum ACPLive {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_ACP"] == "1" }

    static var repoRoot: URL {
        if let root = ProcessInfo.processInfo.environment["ENSEMBLE_REPO_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}

final class ACPLiveHarness: @unchecked Sendable {
    let folder: URL
    let project: URL
    let trust: WorkspaceTrust
    let recorder = ACPRecorder()
    private var engines: [ACPEngine] = []
    private var tasks: [Task<Void, Never>] = []
    var mock: Process?

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-acp-live-\(UUID().uuidString.prefix(8))")
        project = folder.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "alpha\n".write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        trust = WorkspaceTrust(fileURL: folder.appendingPathComponent("trusted-folders.json"))
        try trust.trust(project.path)
    }

    func engine(_ agent: ACPAgentDefinition) -> ACPEngine {
        let engine = ACPEngine(configuration: .init(agent: agent, storeURL: folder.appendingPathComponent("acp-sessions.json"),
                                                    workDirectory: folder.appendingPathComponent("work-\(agent.id)"), trust: trust,
                                                    requestTimeout: .seconds(90)))
        let stream = engine.events()
        let recorder = recorder
        tasks.append(Task { for await event in stream { await recorder.append(event) } })
        engines.append(engine)
        return engine
    }

    /// Starts the mock model and writes the project's `opencode.json` (shell commands ask).
    func startMock() async throws {
        let script = ACPLive.repoRoot.appendingPathComponent("tools/mock-llm/mock_llm.py")
        let portFile = folder.appendingPathComponent("mock-port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--port", "0", "--port-file", portFile.path,
                             "--script", ACPLive.repoRoot.appendingPathComponent("tools/mock-llm/test-script.json").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        mock = process
        var port: String?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), !text.isEmpty { port = text; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let port else { throw ACPTimeout(what: "the mock model") }
        let template = try String(contentsOf: ACPLive.repoRoot.appendingPathComponent("tools/mock-llm/opencode.json.example"), encoding: .utf8)
        guard var config = JSONValue.acpParse(line: template.replacingOccurrences(of: "PORT", with: port).replacingOccurrences(of: "\n", with: " ")),
              case .object(var object) = config else { throw ACPTimeout(what: "the opencode.json template") }
        object["permission"] = ["shell": "ask", "edit": "ask"]
        config = .object(object)
        try config.prettyJSONText.write(to: project.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
    }

    func finish() async {
        for engine in engines { await engine.shutdown() }
        for task in tasks { task.cancel() }
        mock?.terminate()
        try? FileManager.default.removeItem(at: folder)
    }
}

@Suite("ACP live", .serialized, .enabled(if: ACPLive.enabled))
struct ACPLiveTests {
    @Test func antigravityPromptPermissionAndCancel() async throws {
        let h = try ACPLiveHarness()
        let engine = h.engine(ACPAgentRegistry.antigravity)
        let auth = await engine.authState(refresh: true)
        #expect(auth.installed)
        #expect(auth.signedIn == true)
        let models = try await engine.models()
        let flash = try #require(models.first { $0.ref.id == "gemini-3.8-flash" })
        #expect(flash.variants.contains("low"))

        let session = try await engine.createSession(directory: h.project.path,
                                                     model: ModelRef(providerID: "antigravity", id: "gemini-3.8-flash", variant: "low"),
                                                     agent: nil, permissionMode: .ask, parentID: nil)
        // 1. A plain reply, streamed.
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "Reply with exactly: hello there", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark, timeout: 120).outcome == "succeeded")
        #expect(await h.recorder.texts(after: mark, session: session.id).joined().lowercased().contains("hello there"))
        #expect(!(await h.recorder.all(after: mark) { if case .textDelta(session.id, _, _) = $0 { true } else { false } }).isEmpty)
        #expect(try await engine.context(session.id).limitTokens > 0)
        #expect((try await engine.listSessions().first?.usage.inputTokens ?? 0) > 0)

        // 2. A shell command in Ask mode asks (the Mac's Antigravity preset is Turbo), and runs once allowed.
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "Run this exact shell command and nothing else: touch made-by-ensemble.txt", files: [])
        let request = try await h.recorder.permission(session.id, after: mark)
        #expect(request.kind == "bash")
        #expect(request.title.contains("touch made-by-ensemble.txt"))
        try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
        #expect(try await h.recorder.ended(session.id, after: mark, timeout: 120).outcome == "succeeded")
        #expect(FileManager.default.fileExists(atPath: h.project.appendingPathComponent("made-by-ensemble.txt").path))

        // 3. A long reply stopped midway.
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "Write a numbered list of the first 80 prime numbers, one per line, each with a one-sentence fun fact. Do not use any tools.", files: [])
        _ = try await h.recorder.wait("first delta", after: mark, timeout: 120) {
            switch $0 {
            case .textDelta(session.id, _, _), .reasoningDelta(session.id, _, _): true
            default: false
            }
        }
        try await engine.interrupt(session.id)
        #expect(try await h.recorder.ended(session.id, after: mark, timeout: 30).outcome == "interrupted")
        await h.finish()
    }

    @Test func openCodePromptAndPermission() async throws {
        let h = try ACPLiveHarness()
        try await h.startMock()
        let engine = h.engine(ACPAgentRegistry.openCode)
        let session = try await engine.createSession(directory: h.project.path, model: ModelRef(providerID: "opencode-acp", id: "mock/mock-1"),
                                                     agent: nil, permissionMode: .ask, parentID: nil)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark, timeout: 60).outcome == "succeeded")
        #expect(await h.recorder.texts(after: mark, session: session.id) == ["Hello from the mock model. Nice to meet you."])
        // OpenCode's models depend on the folder (the mock comes from the project's opencode.json); the list follows the
        // newest session.
        #expect(try await engine.models().contains { $0.ref.id == "mock/mock-1" })

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "run the echo", files: [])
        let request = try await h.recorder.permission(session.id, after: mark)
        #expect(request.kind == "bash")
        #expect(request.title == "echo ensemble-ok")
        try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
        #expect(try await h.recorder.ended(session.id, after: mark, timeout: 60).outcome == "succeeded")
        let tool = ACPFixtures.tools(try await engine.transcript(session.id)).last
        #expect(tool?.status == .succeeded)
        #expect(tool?.outputPreview?.contains("ensemble-ok") == true)
        try await engine.deleteSession(session.id)
        await h.finish()
    }
}
#endif
