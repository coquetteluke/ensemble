#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// A store on a router with the scripted ACP agent (`fake_acp_agent.py`) set up like Antigravity: Auto runs in the
/// agent's ask-everything `default` mode and Ensemble answers each prompt. The fallback engine is the safety check's
/// fake OpenCode (`SafetyCheckFakeEngine`), which answers the classifier.
@MainActor
final class ACPAutoHarness {
    let h: FakeACPHarness
    let engine: ACPEngine
    let openCode = SafetyCheckFakeEngine()
    let router: EngineRouter
    let store: SessionStore
    let session: EngineSession
    private var pump: Task<Void, Never>?
    /// The agent's answers before the latest `ask`.
    private var answersBefore = 0

    init(mode: PermissionMode = .auto, settings: SafetyCheckSettings = SafetyCheckSettings()) async throws {
        h = try FakeACPHarness()
        engine = h.engine { agent in
            agent.modeIDs[.auto] = "default"
            agent.ensembleDecidesAuto = true
        }
        router = EngineRouter(fallback: openCode, trust: h.trust)
        router.register(engine, providers: ["fake"], id: "fake", name: "Fake Agent")
        store = SessionStore(engine: router)
        store.safetyCheck.settings = settings
        store.safetyCheck.badges = SafetyCheckBadges()
        store.safetyCheck.makeNonce = { "n0nce" }
        store.safetyCheck.setModels([SafetyCheckFakeEngine.cheapModel])
        session = try await router.createSession(directory: h.project.path, model: ModelRef(providerID: "fake", id: "fake-fast"),
                                                 agent: nil, permissionMode: mode, parentID: nil)
        store.apply(.sessionCreated(session))
        store.session(session.id)?.permissionMode = mode
        let stream = router.events()
        let store = store
        pump = Task { @MainActor in
            for await event in stream { store.apply(event) }
        }
    }

    var model: SessionModel { store.session(session.id)! }
    var decisions: [SafetyCheckDecision] { store.safetyCheckDecisions(for: session.id) }
    /// The fake agent's answers to its permission requests, oldest first (`allow`, `deny` or nil for cancelled).
    var answers: [String?] { h.events("permission_answer").map { $0["outcome"]?["optionId"]?.stringValue } }

    /// Sends a `tool:` prompt: the agent makes exactly this tool call and asks permission for it.
    func ask(_ toolJSON: String) async throws -> Int {
        let mark = await h.recorder.mark()
        answersBefore = answers.count
        try await router.prompt(session.id, text: "tool: " + toolJSON, files: [])
        return mark
    }

    /// Waits for Ensemble's decision on the next prompt.
    func decision(count: Int = 1) async throws -> SafetyCheckDecision {
        try await waitUntil("a safety check decision", details: { "\(self.decisions)" }) { decisions.count >= count }
        return decisions[0]
    }

    /// Waits for the turn to end and returns the agent's answer to its one prompt.
    func ended(after mark: Int) async throws -> String? {
        _ = try await h.recorder.ended(session.id, after: mark)
        return answers.last ?? nil
    }

    /// Waits for the prompt to be shown, then rejects it so the turn ends.
    func shownThenRejected(after mark: Int) async throws -> PermissionRequest {
        try await waitUntil("the prompt to be shown") { !model.pendingPermissions.isEmpty }
        let request = model.pendingPermissions[0]
        #expect(answers.count == answersBefore, "the agent got an answer before the user gave one")
        await store.reply(to: request, decision: .reject)
        #expect(try await ended(after: mark) == "deny")
        return request
    }

    func finish() async {
        pump?.cancel()
        await h.finish()
    }
}

@MainActor
@Suite("Auto decided by Ensemble for an ACP agent", .serialized, .enabled(if: FakeACPHarness.pythonAvailable))
struct ACPAutoSafetyCheckTests {
    @Test func editsInsideTheFolderAreAnsweredOnce() async throws {
        let a = try await ACPAutoHarness()
        // agy's write_file, with its `args` copy of the arguments.
        var mark = try await a.ask(#"""
        {"kind": "edit", "name": "write_file", "title": "File src/app.txt", "locations": [{"path": "{project}/src/app.txt"}],
         "rawInput": {"Path": "{project}/src/app.txt", "Content": "hi"}, "args": {"Path": "{project}/src/app.txt", "Content": "hi"},
         "content": [{"type": "diff", "path": "{project}/src/app.txt", "newText": "hi"}]}
        """#.replacingOccurrences(of: "\n", with: " "))
        #expect(try await a.ended(after: mark) == "allow")
        var decision = try await a.decision()
        #expect(decision.verdict == .allow)
        #expect(decision.basis == .rule)
        #expect(decision.action == "edit")
        #expect(decision.subject == "src/app.txt")
        #expect(decision.toolCallID == "call_1")
        #expect(a.store.safetyCheck.badges.decision(forToolCall: "call_1")?.reason == "Edit inside the project folder")
        #expect(a.model.pendingPermissions.isEmpty)
        #expect(!a.model.items.contains { if case .permission = $0 { true } else { false } })

        // agy's edit_file.
        mark = try await a.ask(#"{"kind": "edit", "name": "edit_file", "locations": [{"path": "{project}/notes.txt"}], "rawInput": {"Path": "{project}/notes.txt", "Target": "alpha", "Replacement": "beta"}}"#)
        #expect(try await a.ended(after: mark) == "allow")
        decision = try await a.decision(count: 2)
        #expect(decision.verdict == .allow && decision.subject == "notes.txt")
        #expect(a.openCode.classifierPrompts.isEmpty)
        // Auto runs in the agent's ask-everything mode, never in its own auto mode.
        let modes = a.h.received("session/set_config_option").filter { $0["configId"] == "mode" }.compactMap { $0["value"]?.stringValue }
        #expect(modes.contains("default"))
        #expect(!modes.contains("auto"))
        await a.finish()
    }

    @Test func protectedFileEditsAsk() async throws {
        let a = try await ACPAutoHarness()
        for (index, path) in ["GEMINI.md", ".github/workflows/ci.yml", "package.json"].enumerated() {
            let mark = try await a.ask(#"{"kind": "edit", "name": "write_file", "locations": [{"path": "{project}/PATH"}], "rawInput": {"Path": "{project}/PATH", "Content": "x"}}"#
                .replacingOccurrences(of: "PATH", with: path))
            let decision = try await a.decision(count: index + 1)
            #expect(decision.verdict == .ask)
            #expect(decision.basis == .rule)
            #expect(decision.subject == path)
            let shown = try await a.shownThenRejected(after: mark)
            #expect(shown.kind == "write" || shown.kind == "edit")
        }
        #expect(a.decisions.map(\.reason) == ["Protected build or config file", "Hidden files and folders always ask",
                                             "Protected build or config file"])
        #expect(a.store.safetyCheck.badges.allowed.isEmpty)
        await a.finish()
    }

    @Test func removingAFolderAsks() async throws {
        let a = try await ACPAutoHarness(settings: SafetyCheckSettings(enabled: true, model: SafetyCheckFakeEngine.cheapModel.ref))
        let mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "title": "rm -rf build", "rawInput": {"CommandLine": "rm -rf build", "WaitMsBeforeAsync": 5000, "toolSummary": "Remove build"}}"#)
        let decision = try await a.decision()
        #expect(decision.verdict == .ask)
        #expect(decision.basis == .rule)
        #expect(decision.action == "shell")
        #expect(decision.subject == "rm -rf build")
        #expect(decision.reason == "Deletes folders")
        let shown = try await a.shownThenRejected(after: mark)
        #expect(shown.title == "rm -rf build")
        // The fixed rules decide before any model call.
        #expect(a.openCode.classifierPrompts.isEmpty)
        await a.finish()
    }

    @Test func leavingTheSandboxAsks() async throws {
        let a = try await ACPAutoHarness(settings: SafetyCheckSettings(enabled: true, model: SafetyCheckFakeEngine.cheapModel.ref))
        // Even a read-only command asks when it asks to leave the sandbox, and the model is never asked.
        let mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "ls", "BypassSandbox": true, "SafeToAutoRun": true}}"#)
        let decision = try await a.decision()
        #expect(decision.verdict == .ask)
        #expect(decision.reason == "Asks to run outside the sandbox")
        _ = try await a.shownThenRejected(after: mark)
        #expect(a.openCode.classifierPrompts.isEmpty)
        await a.finish()
    }

    @Test func readOnlyCommandsRun() async throws {
        let a = try await ACPAutoHarness()
        let mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "ls -la", "WaitMsBeforeAsync": 5000, "toolSummary": "List files", "BypassSandbox": false}, "args": {"CommandLine": "ls -la", "WaitMsBeforeAsync": 5000, "toolSummary": "List files", "BypassSandbox": false}}"#)
        #expect(try await a.ended(after: mark) == "allow")
        let decision = try await a.decision()
        #expect(decision.verdict == .allow)
        #expect(decision.basis == .rule)
        #expect(decision.reason == "Read-only command")
        #expect(a.store.safetyCheck.badges.decision(forToolCall: "call_1") != nil)
        #expect(a.openCode.classifierPrompts.isEmpty)
        await a.finish()
    }

    @Test func requestsThatCannotBeReadExactlyAsk() async throws {
        let a = try await ACPAutoHarness(settings: SafetyCheckSettings(enabled: true, model: SafetyCheckFakeEngine.cheapModel.ref))
        let requests = [
            // No command at all, only a title.
            #"{"kind": "execute", "name": "helper", "title": "echo hi", "rawInput": {}}"#,
            // An argument the check does not know (input fed to the command).
            #"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "ls", "Stdin": "rm -rf ~"}}"#,
            // The non-standard `args` copy says something else than `rawInput`.
            #"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "ls"}, "args": {"CommandLine": "rm -rf src"}}"#,
            // An edit with an argument edits are not known to take.
            #"{"kind": "edit", "name": "write_file", "locations": [{"path": "{project}/a.txt"}], "rawInput": {"Path": "{project}/a.txt", "Content": "x", "Mode": "0777"}}"#,
            // No kind.
            #"{"name": "mystery_tool", "rawInput": {"x": 1}}"#,
        ]
        for (index, request) in requests.enumerated() {
            let mark = try await a.ask(request)
            let decision = try await a.decision(count: index + 1)
            #expect(decision.verdict == .ask, "request \(index)")
            _ = try await a.shownThenRejected(after: mark)
        }
        #expect(a.decisions.reversed().map(\.reason) == [
            "Could not identify the exact command", "The request has arguments the check does not know",
            "The request's arguments do not match", "The request has arguments the check does not know",
            "Only edits and commands are checked",
        ])
        #expect(a.openCode.classifierPrompts.isEmpty)
        await a.finish()
    }

    @Test func otherCommandsGoToTheChosenModelOrAsk() async throws {
        // No model chosen in Settings: the agent's own provider is not one the check may use, so the command asks.
        var a = try await ACPAutoHarness()
        var mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "swift build"}}"#)
        var decision = try await a.decision()
        #expect(decision.verdict == .ask)
        #expect(decision.basis == .failed)
        #expect(decision.reason == "No safety check model is chosen in Settings")
        _ = try await a.shownThenRejected(after: mark)
        #expect(a.openCode.classifierPrompts.isEmpty)
        await a.finish()

        // A model chosen in Settings: it answers through OpenCode, and ALLOW answers the prompt once.
        a = try await ACPAutoHarness(settings: SafetyCheckSettings(model: SafetyCheckFakeEngine.cheapModel.ref))
        a.store.session(a.session.id)?.items.append(.user(id: "u1", text: "Build the project", date: Date()))
        mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "swift build"}}"#)
        #expect(try await a.ended(after: mark) == "allow")
        decision = try await a.decision()
        #expect(decision.verdict == .allow)
        #expect(decision.basis == .model)
        #expect(decision.model == SafetyCheckFakeEngine.cheapModel.ref)
        let prompt = try #require(a.openCode.classifierPrompts.first)
        #expect(prompt.contains("BEGIN-n0nce\nswift build\nEND-n0nce"))
        #expect(prompt.contains("Build the project"))
        #expect(a.openCode.state.withLock { $0.classifierModels } == [SafetyCheckFakeEngine.cheapModel.ref])
        #expect(a.store.safetyCheckUsage(for: a.session.id).checks == 1)
        await a.finish()

        // The model says ASK: the prompt is shown.
        a = try await ACPAutoHarness(settings: SafetyCheckSettings(model: SafetyCheckFakeEngine.cheapModel.ref))
        a.openCode.state.withLock { $0.answer = "ASK: not clearly needed" }
        mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "swift build"}}"#)
        decision = try await a.decision()
        #expect(decision.verdict == .ask && decision.basis == .model)
        _ = try await a.shownThenRejected(after: mark)
        await a.finish()
    }

    @Test func otherModesAreNotDecided() async throws {
        for mode in [PermissionMode.ask, .acceptEdits] {
            let a = try await ACPAutoHarness(mode: mode, settings: SafetyCheckSettings(enabled: true, model: SafetyCheckFakeEngine.cheapModel.ref,
                                                                                         checkAcceptEdits: true))
            let mark = try await a.ask(#"{"kind": "execute", "name": "run_command", "rawInput": {"CommandLine": "ls"}}"#)
            let shown = try await a.shownThenRejected(after: mark)
            #expect(shown.title == "ls")
            #expect(a.decisions.isEmpty)
            #expect(a.openCode.classifierPrompts.isEmpty)
            await a.finish()
        }
    }
}

/// The rules and the request reader on their own.
@Suite struct ACPAutoRulesTests {
    @Test func editRules() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-auto-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("docs").path, withDestinationPath: "/etc")
        let directory = folder.path
        for path in ["src/app.swift", "README.md", "notes/today.txt", "tsconfig.json", "Sources/Main.swift"] {
            #expect(SafetyCheckAgentRules.editReason(paths: [path], directory: directory) == nil, "\(path)")
        }
        let asks: [String: String] = [
            "GEMINI.md": "Protected build or config file", "sub/AGENTS.md": "Protected build or config file",
            "claude.MD": "Protected build or config file", "Package.swift": "Protected build or config file",
            "opencode.json": "Protected build or config file", "OpenCode.jsonc": "Protected build or config file",
            "firebase.json": "Protected build or config file", "keys/server.pem": "Protected build or config file",
            ".env": "Hidden files and folders always ask", "a/.git/hooks/pre-commit": "Hidden files and folders always ask",
            "../outside.txt": "Outside the project folder", "/etc/hosts": "Outside the project folder",
            "a/../b.txt": "Outside the project folder", "docs/hosts": "Outside the project folder",
            "a\u{200B}b.txt": "Contains hidden characters",
        ]
        for (path, reason) in asks {
            #expect(SafetyCheckAgentRules.editReason(paths: [path], directory: directory) == reason, "\(path)")
        }
        #expect(SafetyCheckAgentRules.editReason(paths: ["src/a.swift", "Makefile"], directory: directory) != nil)
        #expect(SafetyCheckAgentRules.editReason(paths: [], directory: directory) != nil)
    }

    @Test func readOnlyCommands() {
        for command in ["ls", "ls -la src", "cat notes.txt | grep alpha", "pwd && ls", "find . -name notes.txt", "wc -l notes.txt",
                        "head -5 notes.txt", "which swift", "echo done"] {
            #expect(SafetyCheckAgentRules.isReadOnly(command), "\(command)")
        }
        for command in ["echo hi > out.txt", "echo $TOKEN", "cat < notes.txt", "find . -delete", "find . -name x -exec rm",
                        "npm test", "rm notes.txt", "ls; rm notes.txt", "rg --pre cat foo", "FOO=1 ls", "cd src && ls", ""] {
            #expect(!SafetyCheckAgentRules.isReadOnly(command), "\(command)")
        }
    }

    /// The real agy requests in the fixtures.
    @Test func readsAntigravityRequests() throws {
        let directory = ACPFixtures.directory
        func subjects(_ name: String) throws -> [AgentPermissionSubject] {
            try ACPFixtures.incoming(name).compactMap { message in
                guard case .request(_, "session/request_permission", let params) = message else { return nil }
                return ACPAutoPrompts.subject(params: params, directory: directory)
            }
        }
        let project = try #require(WorkspaceTrust.resolvedPath(directory))
        let shell = try #require(try subjects("agy-load-cancel.jsonl").first)
        #expect(shell.action == .command("echo hi", folder: project))
        #expect(shell.askReason == nil)
        #expect(shell.toolCallID == "call_2231004144718394006")

        let edits = try subjects("agy-edit.jsonl")
        #expect(edits.map(\.action) == [.edit(paths: ["notes.txt"]), .edit(paths: ["notes.txt"])])
        #expect(edits.allSatisfy { $0.askReason == nil })

        let turbo = try subjects("agy-ask-under-turbo.jsonl")
        #expect(turbo.map(\.action) == [.command("touch made-by-shell.txt", folder: project),
                                        .other(reason: "Outside the project folder"), .other(reason: "Outside the project folder"),
                                        .command("ls", folder: project)])
    }

    @Test func readsCommandArguments() throws {
        let directory = ACPFixtures.directory
        func subject(_ rawInput: String) throws -> AgentPermissionSubject {
            let input = try #require(JSONValue.acpParse(line: rawInput))
            let params: JSONValue = ["sessionId": "s", "toolCall": ["toolCallId": "c", "kind": "execute", "rawInput": input]]
            return ACPAutoPrompts.subject(params: params, directory: directory)
        }
        #expect(try subject(#"{"CommandLine": "ls", "BypassSandbox": false, "toolAction": "List", "explanation": "x"}"#).askReason == nil)
        #expect(try subject(#"{"CommandLine": "ls", "BypassSandbox": true}"#).askReason == "Asks to run outside the sandbox")
        #expect(try subject(#"{"CommandLine": "ls", "BypassSandbox": "true"}"#).askReason == "Asks to run outside the sandbox")
        #expect(try subject(#"{"CommandLine": "ls", "Sandbox": false}"#).askReason == "Asks to run outside the sandbox")
        #expect(try subject(#"{"CommandLine": "ls", "SandboxProfile": "open"}"#).askReason == "Asks to run outside the sandbox")
        #expect(try subject(#"{"CommandLine": "ls", "Cwd": "/etc"}"#).askReason == "Outside the project folder")
        #expect(try subject(#"{"CommandLine": "ls", "Cwd": "../"}"#).askReason == "Outside the project folder")
        #expect(try subject(#"{"CommandLine": "ls", "env": {"PATH": "/tmp"}}"#).askReason == "The request has arguments the check does not know")
        #expect(try subject(#"{"CommandLine": "ls", "command": "rm -rf src"}"#).askReason == "Could not identify the exact command")
        #expect(try subject(#"{"CommandLine": "ls", "RunPersistent": false}"#).askReason == nil)
        #expect(try subject(#"{"CommandLine": "ls", "RunPersistent": true}"#).askReason == "The request has arguments the check does not know")
        #expect(try subject(#"{"toolSummary": "ls"}"#).action == .other(reason: "Could not identify the exact command"))
    }
}
#endif
