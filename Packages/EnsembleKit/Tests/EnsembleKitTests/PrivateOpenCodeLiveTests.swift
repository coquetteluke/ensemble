#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The private OpenCode server for untrusted folders, against the real `opencode` binary and the mock model. Runs only
/// with `ENSEMBLE_LIVE_TESTS=1`. The shared service is only used for the trusted half (a session in a temporary
/// folder, deleted afterwards); it is never stopped or restarted. The trust list is a temporary file.
///
/// The project's `opencode.json` names a formatter that touches a marker file after any `.txt` edit. In the untrusted
/// folder the session runs on the private server and the marker never appears; once the folder is trusted, a new
/// session runs on the shared service, which loads the config, and the formatter runs.
@Suite("Private OpenCode live", .serialized, .enabled(if: LiveConfig.enabled))
struct PrivateOpenCodeLiveTests {
    @MainActor
    @Test func untrustedFolderSkipsProjectConfigUntilTrusted() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: WorkspaceTrust.resolvedPath(fm.temporaryDirectory.path) ?? fm.temporaryDirectory.path)
        let root = base.appendingPathComponent("ens-private-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let project = root.appendingPathComponent("widgets", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let marker = project.appendingPathComponent("formatter-ran")

        // The mock model on a free port.
        let script = LiveConfig.repoRoot.appendingPathComponent("tools/mock-llm/mock_llm.py")
        let scriptCopy = root.appendingPathComponent("mock-script.json")
        try String(contentsOf: LiveConfig.repoRoot.appendingPathComponent("tools/mock-llm/test-script.json"), encoding: .utf8)
            .replacingOccurrences(of: "__PROJECT_DIR__", with: project.path)
            .write(to: scriptCopy, atomically: true, encoding: .utf8)
        let portFile = root.appendingPathComponent("mock-port")
        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        mock.arguments = [script.path, "--port", "0", "--port-file", portFile.path, "--script", scriptCopy.path]
        mock.standardOutput = FileHandle.nullDevice
        mock.standardError = FileHandle.nullDevice
        try mock.run()
        defer { mock.terminate() }
        var port: String?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), !text.isEmpty { port = text; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let mockPort = try #require(port)

        // The project's own config: the mock provider (and a provider only it names), plus the probe formatter.
        func provider(_ id: String) -> JSONValue {
            [id: ["name": "Mock LLM", "package": "@opencode/ai/providers/openai-compatible",
                  "settings": ["baseURL": .string("http://127.0.0.1:\(mockPort)/v1"), "apiKey": "mock"],
                  "models": ["mock-1": ["name": "Mock 1", "limit": ["context": 128000, "output": 4096], "capabilities": ["tools": true]]]]]
        }
        var projectProviders = provider("mock").objectValue ?? [:]
        projectProviders.merge(provider("mockproject").objectValue ?? [:]) { a, _ in a }
        let projectConfig: JSONValue = [
            "$schema": "https://opencode.ai/config.json", "model": "mock/mock-1", "providers": .object(projectProviders),
            "formatter": ["ensemble-probe": ["command": ["touch", .string(marker.path)], "extensions": [".txt"]]],
        ]
        try projectConfig.prettyJSONText.write(to: project.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        // The user's own config for the private server: the mock provider only (as if set up in ~/.config/opencode).
        let userConfig = root.appendingPathComponent("user-opencode.json")
        let user: JSONValue = ["$schema": "https://opencode.ai/config.json", "providers": provider("mock")]
        try user.prettyJSONText.write(to: userConfig, atomically: true, encoding: .utf8)

        // The private server, with its own data folder.
        let executable = try #require(EngineManager.locate(in: EngineManager.defaultSearchPaths()))
        let server = PrivateOpenCodeServer(configuration: .init(dataDirectory: root.appendingPathComponent("private"),
                                                                extraEnvironment: ["OPENCODE_CONFIG": userConfig.path]))
        server.start(executable: executable)
        defer { server.stop() }
        var waited = 0
        while server.client == nil, waited < 600 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let privateClient = try #require(server.client, "the private server did not start: \(server.status)")
        let privateURL = privateClient.baseURL

        let shared = try OpenCodeClient.fromServiceFile()
        let trust = WorkspaceTrust(fileURL: root.appendingPathComponent("trusted-folders.json"))
        let router = EngineRouter(fallback: shared, trust: trust)
        router.registerForUntrustedFolders(privateClient)
        let recorder = EventRecorder()
        let listener = Task { for await event in router.events() { await recorder.append(event) } }
        defer { listener.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        // The private server reads the user's config but not the project's.
        let privateModels = try await privateClient.models(directory: project.path).map(\.ref.providerID)
        #expect(privateModels.contains("mock"))
        #expect(!privateModels.contains("mockproject"))

        let mockModel = ModelRef(providerID: "mock", id: "mock-1")
        var created: [String] = []
        defer {
            let ids = created
            Task { for id in ids { try? await router.deleteSession(id) } }
        }
        func runTurn(_ sessionID: String) async throws {
            let mark = await recorder.mark()
            try await router.prompt(sessionID, text: "please write text after config", files: [])
            let ended = try await recorder.waitFor("turn end", after: mark, timeout: 90) {
                if case .executionEnded(sessionID, _, _) = $0 { true } else { false }
            }
            #expect(ended == .executionEnded(sessionID: sessionID, outcome: "succeeded", error: nil))
        }

        // Untrusted: the session runs on the private server, the edit happens, the formatter never runs.
        let untrusted = try await router.createSession(directory: project.path, model: mockModel, agent: nil,
                                                       permissionMode: .acceptEdits, parentID: nil)
        created.append(untrusted.id)
        #expect(router.ownerID(ofSession: untrusted.id) == EngineRouter.untrustedOpenCodeID)
        try await runTurn(untrusted.id)
        #expect(fm.fileExists(atPath: project.appendingPathComponent("after-config.txt").path))
        try await Task.sleep(for: .seconds(4))
        #expect(!fm.fileExists(atPath: marker.path), "the project's formatter ran on the private server")
        let sharedLoaded = try await shared.loadedDirectories()
        #expect(!sharedLoaded.contains(project.path), "the shared service loaded the untrusted folder")
        print("private live: untrusted session \(untrusted.id) on \(privateURL), no marker; shared never loaded the folder")

        // Trusted: a new session goes to the shared service, which loads the config, and the formatter runs.
        try trust.trust(project.path)
        let trusted = try await router.createSession(directory: project.path, model: mockModel, agent: nil,
                                                     permissionMode: .acceptEdits, parentID: nil)
        created.append(trusted.id)
        #expect(router.ownerID(ofSession: trusted.id) == "opencode")
        #expect(router.ownerID(ofSession: untrusted.id) == EngineRouter.untrustedOpenCodeID)
        try await runTurn(trusted.id)
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(fm.fileExists(atPath: marker.path), "the formatter did not run in the trusted session")
        print("private live: trusted session \(trusted.id) on the shared service ran the formatter")

        // Both servers' sessions are listed; the earlier one is still answered by the private server.
        let listed = Set(try await router.listSessions().map(\.id))
        #expect(listed.isSuperset(of: [untrusted.id, trusted.id]))
        #expect(try await router.transcript(untrusted.id).contains { if case .agentText = $0 { true } else { false } })

        for id in created { try? await router.deleteSession(id) }
        created.removeAll()

        // Stopping the server ends it: its address refuses connections (a live server would answer 401).
        server.stop()
        try await Task.sleep(for: .seconds(2))
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(from: privateURL.appendingPathComponent("api/info"))
        }
    }
}
#endif
