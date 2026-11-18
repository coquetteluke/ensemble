#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The safety check against the real `opencode` binary and the mock model, through the router and the store. Runs only
/// with `ENSEMBLE_LIVE_TESTS=1`. Uses a private `opencode serve` (never the shared service) whose agent commands see a
/// throwaway home folder, so even a wrong answer could not touch the real one.
///
/// In Auto, `npm test` asks in OpenCode; the mock classifier answers ALLOW (the mock answers every request without
/// tools with `default.title`), the store answers the prompt once, and the test script runs. `rm -rf ~` is decided by
/// the fixed rules: the prompt is shown, the classifier is never called for it, and the test rejects it.
@Suite("Safety check live", .serialized, .enabled(if: LiveConfig.enabled))
struct SafetyCheckLiveTests {
    @MainActor
    @Test func npmTestIsAllowedAndRmRfHomeAsks() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: WorkspaceTrust.resolvedPath(fm.temporaryDirectory.path) ?? fm.temporaryDirectory.path)
        let root = base.appendingPathComponent("ens-safety-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let project = root.appendingPathComponent("widgets", isDirectory: true)
        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        let homeMarker = fakeHome.appendingPathComponent("still-here")
        try "x".write(to: homeMarker, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }
        try #"{"name": "widgets", "version": "1.0.0", "scripts": {"test": "echo tests-ok"}}"#
            .write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        // The mock model: tool calls for the two prompts; every request without tools gets the classifier's answer.
        let script: JSONValue = [
            "default": ["text": "Done.", "title": "ALLOW: runs the project's own test script"],
            "rules": [
                ["match": ["run the tests"], "tool": ["name": "shell", "arguments": ["command": "npm test"]], "then": "Tests ran."],
                ["match": ["wipe the home folder"], "tool": ["name": "shell", "arguments": ["command": "rm -rf ~"]], "then": "Done."],
            ],
        ]
        let scriptFile = root.appendingPathComponent("mock-script.json")
        try script.prettyJSONText.write(to: scriptFile, atomically: true, encoding: .utf8)
        let portFile = root.appendingPathComponent("mock-port")
        let logFile = root.appendingPathComponent("mock-log.jsonl")
        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        mock.arguments = [LiveConfig.repoRoot.appendingPathComponent("tools/mock-llm/mock_llm.py").path, "--port", "0",
                          "--port-file", portFile.path, "--script", scriptFile.path, "--log", logFile.path]
        mock.standardOutput = FileHandle.nullDevice
        mock.standardError = FileHandle.nullDevice
        try mock.run()
        defer { mock.terminate() }
        var port: String?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), !text.isEmpty { port = text; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let mockPort = try #require(port)

        // The user's config for the private server: the mock provider, priced so it counts as a cheap model.
        let userConfig = root.appendingPathComponent("user-opencode.json")
        let user: JSONValue = [
            "$schema": "https://opencode.ai/config.json",
            "providers": ["mock": ["name": "Mock LLM", "package": "@opencode/ai/providers/openai-compatible",
                                   "settings": ["baseURL": .string("http://127.0.0.1:\(mockPort)/v1"), "apiKey": "mock"],
                                   "models": ["mock-1": ["name": "Mock 1", "limit": ["context": 128000, "output": 4096],
                                                         "capabilities": ["tools": true],
                                                         "cost": [["input": 0.1, "output": 0.4, "cache": ["read": 0, "write": 0]]]]]]],
        ]
        try user.prettyJSONText.write(to: userConfig, atomically: true, encoding: .utf8)
        let realHome = NSHomeDirectory()
        let executable = try #require(EngineManager.locate(in: EngineManager.defaultSearchPaths()))
        let server = PrivateOpenCodeServer(configuration: .init(
            dataDirectory: root.appendingPathComponent("server"),
            extraEnvironment: ["OPENCODE_CONFIG": userConfig.path, "HOME": fakeHome.path,
                               "XDG_CACHE_HOME": realHome + "/.cache", "XDG_CONFIG_HOME": fakeHome.path + "/.config"]))
        server.start(executable: executable)
        defer { server.stop() }
        var waited = 0
        while server.client == nil, waited < 600 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let client = try #require(server.client, "the private server did not start: \(server.status)")

        let trust = WorkspaceTrust(fileURL: root.appendingPathComponent("trusted-folders.json"))
        let router = EngineRouter(fallback: client, trust: trust)
        let store = SessionStore(engine: router)
        let mockModel = ModelRef(providerID: "mock", id: "mock-1")
        // Nothing chosen: the check must use the session's own provider (the mock), not OpenCode's free models, which
        // the same server also lists at no cost.
        store.safetyCheck.settings = SafetyCheckSettings()
        await store.start()
        defer { store.stopListening() }

        // The model list comes from the engine, with the mock's price.
        await store.loadSafetyCheckModels()
        let listed = try #require(store.safetyCheck.models.first { $0.ref == mockModel })
        #expect(listed.inputCostPerMillion == 0.1)
        #expect(store.safetyCheck.models.contains { $0.ref.providerID != "mock" })
        #expect(store.safetyCheck.classifierModel(forSession: mockModel)?.ref == mockModel)

        let session = try await store.newSession(directory: project.path, model: mockModel, permissionMode: .auto)
        defer { Task { try? await router.deleteSession(session.id) } }
        #expect(store.safetyCheckApplies(to: session.id))

        // npm test: asked by OpenCode, allowed by the classifier, run.
        await store.send("Please run the tests", to: session.id)
        try await waitUntil("npm test to run", timeout: .seconds(120), details: { "\(session.items)" }) {
            session.items.contains { item in
                if case .tool(let tool) = item { return tool.status == .succeeded && (tool.outputPreview ?? "").contains("tests-ok") }
                return false
            }
        }
        #expect(session.pendingPermissions.isEmpty)
        let allowed = try #require(store.safetyCheckDecisions(for: session.id).first)
        #expect(allowed.verdict == .allow)
        #expect(allowed.basis == .model)
        #expect(allowed.subject == "npm test")
        #expect(allowed.reason == "Runs the project's own test script")
        #expect(allowed.model == mockModel)
        let toolID = try #require(allowed.toolCallID)
        #expect(session.items.contains { if case .tool(let tool) = $0 { return tool.id == toolID } else { return false } })
        #expect(store.safetyCheck.badges.decision(forToolCall: toolID) != nil)
        #expect(store.safetyCheckUsage(for: session.id).checks == 1)
        try await waitUntil("the turn to end", timeout: .seconds(120)) { !session.isWorking }

        let classifierRequests = { () -> [String] in
            let lines = (try? String(contentsOf: logFile, encoding: .utf8))?.split(separator: "\n") ?? []
            return lines.compactMap { line -> String? in
                guard let data = line.data(using: .utf8), let entry = try? JSONDecoder().decode(JSONValue.self, from: data),
                      entry["body"]?["tools"] == nil,
                      let content = entry["body"]?["messages"]?.arrayValue?.last?["content"]?.stringValue,
                      content.contains("You are the safety check") else { return nil }
                return content
            }
        }
        #expect(classifierRequests().count == 1)
        #expect(classifierRequests().first?.contains("npm test") == true)

        // rm -rf ~: the fixed rules ask; the classifier is never called; the test rejects it.
        await store.send("Now wipe the home folder", to: session.id)
        try await waitUntil("the rm prompt", timeout: .seconds(120), details: { "\(session.items)" }) {
            session.pendingPermissions.contains { $0.title.contains("rm -rf") }
        }
        let prompt = try #require(session.pendingPermissions.first { $0.title.contains("rm -rf") })
        let asked = try #require(store.safetyCheckDecisions(for: session.id).first)
        #expect(asked.verdict == .ask)
        #expect(asked.basis == .rule)
        #expect(asked.reason == "Deletes folders")
        #expect(classifierRequests().count == 1)
        await store.reply(to: prompt, decision: .reject)
        try await waitUntil("the turn to end after the rejection", timeout: .seconds(120)) { !session.isWorking }
        #expect(fm.fileExists(atPath: homeMarker.path))
    }
}
#endif
