#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Ensemble's agent tools end to end through the real `ensemble-agent-tools` helper (path in
/// `ENSEMBLE_AGENT_TOOLS_HELPER`, from an Ensemble build): OpenCode with the scripted mock model calls
/// `ensemble_propose_session` and drives the browser tools against a page from a temporary `python3 -m http.server`;
/// a short Claude turn on haiku calls `propose_session`. OpenCode runs with `ENSEMBLE_LIVE_TESTS=1`, Claude with
/// `ENSEMBLE_LIVE_CLAUDE=1`. Every server, page server and session these tests start is stopped or deleted.
enum AgentToolsLive {
    static var helper: String? {
        ProcessInfo.processInfo.environment["ENSEMBLE_AGENT_TOOLS_HELPER"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }
    }
    static var openCode: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_TESTS"] == "1" && helper != nil }
    static var claude: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_CLAUDE"] == "1" && helper != nil }
    static var agy: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_AGY"] == "1" && helper != nil }

    static let page = """
    <!doctype html><html><head><title>Live check</title></head><body>
    <h1>Checkout</h1>
    <form onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'Saved ' + document.getElementById('name').value;">
      <label for="name">Name</label><input id="name">
      <label for="card">Card number</label><input id="card" autocomplete="cc-number">
      <button>Save</button>
    </form>
    <p id="out"></p>
    </body></html>
    """

    /// Starts a process and returns it with its first stdout line that matches.
    static func start(_ executable: String, _ arguments: [String], directory: URL? = nil,
                      until match: @escaping @Sendable (String) -> Bool) async throws -> (Process, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        let lines = AsyncStream<String> { continuation in
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) { continuation.yield(String(line)) }
                }
            }
        }
        try process.run()
        for await line in lines where match(line) { return (process, line) }
        throw AgentToolsWaitTimeout(what: "\(executable) to start")
    }
}

@MainActor
@Suite(.serialized) struct AgentToolsLiveTests {
    @Test(.enabled(if: AgentToolsLive.openCode))
    func openCodeMockProposesAndDrivesTheBrowser() async throws {
        let helper = try #require(AgentToolsLive.helper)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ens-agent-tools-live-\(UUID().uuidString.prefix(8))")
        let project = base.appendingPathComponent("proj")
        let site = base.appendingPathComponent("site")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        try AgentToolsLive.page.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: base) }

        // The page server.
        let (pages, served) = try await AgentToolsLive.start("/usr/bin/python3", ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1",
                                                                                  "--directory", site.path]) { $0.contains("Serving HTTP") }
        defer { pages.terminate() }
        let pagePort = try #require(served.split(separator: " ").firstIndex(of: "port").map { served.split(separator: " ")[$0 + 1] })
        let pageURL = "http://127.0.0.1:\(pagePort)/"

        // The mock model: proposes, then opens the page, reads it, types into the card field (refused) and the name.
        let script: JSONValue = [
            "default": ["text": "Mock reply.", "title": "Agent tools live"],
            "rules": [
                ["match": ["propose"], "tool": ["name": "ensemble_propose_session",
                                                "arguments": ["title": "Fix the footer year", "brief": "The footer says 2024. Use the current year."]],
                 "then": "Proposed."],
                ["match": ["browse"], "steps": [
                    ["tool": ["name": "ensemble_browser_navigate", "arguments": ["url": .string(pageURL)]]],
                    ["tool": ["name": "ensemble_browser_snapshot", "arguments": [:]]],
                    ["tool": ["name": "ensemble_browser_type", "arguments": ["ref": "e2", "text": "4242424242424242"]]],
                    ["tool": ["name": "ensemble_browser_type", "arguments": ["ref": "e1", "text": "Ada", "submit": true]]],
                    ["text": "Done browsing."],
                ]],
            ],
        ]
        try script.lineData.write(to: base.appendingPathComponent("script.json"))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let log = base.appendingPathComponent("mock.jsonl")
        let (mock, listening) = try await AgentToolsLive.start("/usr/bin/python3", [
            repo.appendingPathComponent("tools/mock-llm/mock_llm.py").path, "--port", "0",
            "--script", base.appendingPathComponent("script.json").path, "--log", log.path,
        ]) { $0.contains("listening on") }
        defer { mock.terminate() }
        let mockPort = try #require(listening.split(separator: ":").last?.split(separator: "/").first)
        let config = try String(contentsOf: repo.appendingPathComponent("tools/mock-llm/opencode.json.example"), encoding: .utf8)
            .replacingOccurrences(of: "PORT", with: String(mockPort))
        try config.write(to: project.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)

        // Ensemble's side: the server, a coordinator with a real web view, and the shared OpenCode service.
        let app = AgentToolsTestApp()
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        let coordinator = app.coordinator()
        let server = AgentToolsServer()
        try server.start(host: coordinator, executable: helper)
        defer { server.stop() }
        let client = try OpenCodeClient.fromServiceFile()
        client.setAgentTools(server)
        let directory = WorkspaceTrust.resolvedPath(project.path) ?? project.path
        let session = try await client.createSession(directory: directory, model: ModelRef(providerID: "mock", id: "mock-1"),
                                                     agent: nil, permissionMode: .auto, parentID: nil)
        app.add(session.id, folder: session.directory)
        var failure: (any Error)?
        do {
            try await openCodeTurns(client: client, session: session, coordinator: coordinator, app: app, surface: surface,
                                    pagePort: String(pagePort), log: log)
        } catch {
            failure = error
        }
        try? await client.deleteSession(session.id)
        try? await client.sendIgnoringBody("DELETE", "/api/experimental/mcp/ensemble", query: OpenCodeClient.location(directory))
        if let failure { throw failure }
    }

    private func openCodeTurns(client: OpenCodeClient, session: EngineSession, coordinator: AgentToolsCoordinator,
                               app: AgentToolsTestApp, surface: AgentToolsTestSurface, pagePort: String, log: URL) async throws {
        try await client.prompt(session.id, text: "please propose a side task", files: [])
        // OpenCode's own rules ask before any MCP tool in Ensemble's modes (`PermissionRules`); the test allows them.
        let allowOpenCode = {
            for pending in (try? await client.pendingPermissions()) ?? [] where pending.sessionID == session.id {
                try? await client.replyPermission(sessionID: session.id, requestID: pending.id, decision: .once, message: nil)
            }
        }
        try await agentToolsWait("the proposal card", timeout: 120, { coordinator.proposals(for: session.id).count == 1 },
                                 whilePolling: allowOpenCode)
        let card = try #require(coordinator.proposals(for: session.id).first)
        #expect(card.title == "Fix the footer year")
        #expect(card.state == .pending)
        #expect(app.started.isEmpty)
        #expect(app.logs.contains { $0.0 == session.id && $0.1.contains("propose_session") })

        // The browser: the test answers the first card with Always for this site.
        try await client.prompt(session.id, text: "now browse the page", files: [])
        try await agentToolsWait("the browser card", timeout: 120, { coordinator.permissionRequest(for: session.id) != nil },
                                 whilePolling: allowOpenCode)
        let request = try #require(coordinator.permissionRequest(for: session.id))
        #expect(request.tool == .browserNavigate)
        #expect(request.site == "127.0.0.1:\(pagePort)")
        coordinator.answer(request.id, .always)
        try await agentToolsWait("the form to be submitted", timeout: 180, {
            app.logs.contains { $0.1.contains("browser_type") && $0.1.contains("e1") }
        }, whilePolling: allowOpenCode)
        let out = try await surface.agentWebView.evaluateJavaScript("document.getElementById('out').textContent + '|' + document.getElementById('card').value") as? String
        #expect(out == "Saved Ada|")
        let typed = app.logs.filter { $0.1.contains("browser_type") }.map(\.1)
        #expect(typed.first?.contains("Refused") == true && typed.first?.contains("payment") == true)
        // What the model saw: page text fenced and labelled, and the refusal.
        let sent = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(sent.contains("ensemble_propose_session"))
        #expect(sent.contains("untrusted data"))
        #expect(sent.contains("does not type into or click password"))
    }

    @Test(.enabled(if: AgentToolsLive.claude))
    func claudeHaikuProposesASession() async throws {
        let helper = try #require(AgentToolsLive.helper)
        let harness = try ClaudeLiveHarness()
        defer { harness.finish() }
        let app = AgentToolsTestApp()
        let coordinator = app.coordinator()
        let server = AgentToolsServer()
        try server.start(host: coordinator, executable: helper)
        defer { server.stop() }
        var configuration = ClaudeCodeEngine.Configuration(storeURL: harness.store, trust: harness.trust)
        configuration.agentTools = server
        let engine = ClaudeCodeEngine(configuration: configuration)
        let session = try await engine.createSession(directory: harness.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        app.add(session.id, folder: session.directory)
        var failure: (any Error)?
        do {
            try await claudeTurn(engine: engine, session: session, coordinator: coordinator, app: app)
        } catch {
            failure = error
        }
        try? await engine.deleteSession(session.id)
        await engine.shutdown()
        if let failure { throw failure }
    }

    private func claudeTurn(engine: ClaudeCodeEngine, session: EngineSession, coordinator: AgentToolsCoordinator,
                            app: AgentToolsTestApp) async throws {
        try await engine.prompt(session.id, text: """
        Call the propose_session tool (from the ensemble MCP server) exactly once, with title "Check the notes file" and \
        brief "Read notes.txt and fix any typos." Then reply with the single word done.
        """, files: [])
        // The CLI asks before an MCP tool in Ask mode; allow it.
        try await agentToolsWait("the proposal card", timeout: 180) {
            coordinator.proposals(for: session.id).count == 1
        } whilePolling: {
            for pending in (try? await engine.pendingPermissions()) ?? [] where pending.sessionID == session.id {
                try? await engine.replyPermission(sessionID: session.id, requestID: pending.id, decision: .once, message: nil)
            }
        }
        #expect(coordinator.proposals(for: session.id).first?.title == "Check the notes file")
        #expect(app.started.isEmpty)
    }
}

/// agy's ACP server starts the helper from `mcpServers` in `session/new` and lists the tools (no model turn). Runs
/// with `ENSEMBLE_LIVE_AGY=1` in an empty temporary folder.
@MainActor
@Suite(.serialized) struct AgentToolsAgyLiveTests {
    @Test(.enabled(if: AgentToolsLive.agy))
    func agyStartsTheBridgeForItsSession() async throws {
        let helper = try #require(AgentToolsLive.helper)
        let agy = try #require(ACPAgentRegistry.installation(ACPAgentRegistry.antigravity).executable)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-agent-tools-agy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cwd = WorkspaceTrust.resolvedPath(folder.path) ?? folder.path
        let server = AgentToolsServer()
        try server.start(host: AgentToolsTestApp().coordinator(), executable: helper)
        defer { server.stop() }
        let attachment = try #require(server.attachment(for: .session("agy-session")))

        let process = Process()
        process.executableURL = agy
        process.arguments = ["acp"]
        process.currentDirectoryURL = folder
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.terminate()
        }
        func send(_ message: JSONValue) { input.fileHandleForWriting.write(message.lineData) }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]]])
        send(["jsonrpc": "2.0", "id": 2, "method": "session/new", "params": ["cwd": .string(cwd), "mcpServers": [attachment.acpServer]]])
        try await agentToolsWait("agy to start the bridge", timeout: 90) { server.openBridges(for: .session("agy-session"), listed: true) == 1 }
    }
}

/// Waits like `agentToolsWait`, running `work` between checks.
@MainActor
func agentToolsWait(_ what: String, timeout: Double, _ condition: () -> Bool, whilePolling work: () async -> Void) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw AgentToolsWaitTimeout(what: what) }
        await work()
        try await Task.sleep(for: .milliseconds(300))
    }
}
#endif
