import Foundation
import Testing
@testable import EnsembleKit

@Suite("Claude Code transcripts and history")
struct ClaudeCodeTranscriptTests {
    typealias F = ClaudeFixtures

    func builder(sidechains: Bool = false) -> ClaudeTranscriptBuilder {
        ClaudeTranscriptBuilder(rootID: F.root, directory: F.directory, finished: true, includeSidechains: sidechains)
    }

    @Test func transcriptFileRebuildsTheSameRowsAsTheLiveStream() throws {
        let chain = try F.transcript("transcript-edit.jsonl").activeChain()
        let items = builder().items(from: chain)
        guard case .user(_, let text, _) = items.first else { Issue.record("first row is not the prompt"); return }
        #expect(text.hasPrefix("Read notes.txt"))
        #expect(items.contains { if case .reasoning("msg_011Ch9jcR542wbfKHnoEKU1K:0", _, false) = $0 { true } else { false } })
        let tools = items.compactMap { if case .tool(let info) = $0 { info } else { nil } }
        #expect(tools.map(\.name) == ["Read", "Edit"])
        #expect(tools.allSatisfy { $0.status == .succeeded })
        #expect(tools.last?.diff?.contains("-alpha\n+beta") == true)
        // Same id as the live textEnded event from the stream of the same session.
        #expect(items.last == .agentText(id: "msg_011Ch9jd8SxT7RjJThXGhzbE:0", text: "done", agentID: nil, streaming: false))
    }

    @Test func interruptedTurnShowsANotice() throws {
        let items = builder().items(from: try F.transcript("transcript-interrupt.jsonl").activeChain())
        #expect(items.contains { if case .notice(_, "Interrupted") = $0 { true } else { false } })
        #expect(items.contains { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })
        #expect(items.last == .agentText(id: "msg_011Ch9jmwNi4kJvCYXGACUf6:0", text: "still here", agentID: nil, streaming: false))
    }

    @Test func syntheticMessagesAreNotices() throws {
        var b = builder()
        b.syntheticTexts = ["Reply with exactly: still here"]
        let items = b.items(from: try F.transcript("transcript-interrupt.jsonl").activeChain())
        #expect(items.contains { if case .notice(_, "Reply with exactly: still here") = $0 { true } else { false } })
        #expect(!items.contains { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })
    }

    @Test func subagentTranscripts() throws {
        let items = builder().items(from: try F.transcript("transcript-subagent.jsonl").activeChain())
        let agent = items.compactMap { if case .tool(let info) = $0, info.name == "Agent" { info } else { nil } }.first
        #expect(agent?.childSessionID == "\(F.root).toolu_01WJd3ydmJdPAFjh93jKrT5Y")
        #expect(agent?.status == .succeeded)

        let data = try F.transcript("transcript-subagent-agent.jsonl")
        #expect(builder().items(from: data.activeChain()).isEmpty)
        let child = builder(sidechains: true).items(from: data.activeChain(includeSidechains: true))
        #expect(child.first == .user(id: child.first?.id ?? "", text: "Read notes.txt and reply with its first word only.",
                                     date: { if case .user(_, _, let date) = child.first { date } else { Date() } }()))
        #expect(child.contains { if case .tool(let info) = $0 { info.name == "Read" && info.status == .succeeded } else { false } })
        #expect(child.contains { if case .agentText(_, "alpha", _, _) = $0 { true } else { false } })
    }

    @Test func changedFilesFromEdits() throws {
        let changes = builder().changedFiles(from: try F.transcript("transcript-edit.jsonl").activeChain())
        #expect(changes.count == 1)
        #expect(changes.first?.path == "notes.txt")
        #expect(changes.first?.kind == .modified)
        #expect(changes.first?.additions == 1)
        #expect(changes.first?.deletions == 1)
        #expect(changes.first?.diff?.contains("+beta") == true)
    }

    @Test func runningToolsFailWhenTheTurnIsOver() {
        let lines: [JSONValue] = [
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "go"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "u1",
             "message": ["id": "m1", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "sleep 100"]]]]],
        ]
        let finished = ClaudeTranscriptBuilder(rootID: "r", directory: "/p", finished: true).items(from: lines)
        #expect(finished.contains { if case .tool(let info) = $0 { info.status == .failed } else { false } })
        let running = ClaudeTranscriptBuilder(rootID: "r", directory: "/p", finished: false).items(from: lines)
        #expect(running.contains { if case .tool(let info) = $0 { info.status == .running && info.title == "sleep 100" } else { false } })
    }

    /// A rewind continues from an earlier entry; the old branch stays in the file but leaves the active chain.
    @Test func activeChainFollowsTheNewestBranch() {
        let text = """
        {"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"one"}}
        {"type":"attachment","uuid":"x1","parentUuid":"u1","attachment":{}}
        {"type":"assistant","uuid":"a1","parentUuid":"x1","message":{"id":"m1","content":[{"type":"text","text":"first"}]}}
        {"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"two"}}
        {"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","content":[{"type":"text","text":"second"}]}}
        {"type":"api-request-blob","hash":"h","message":{"type":"user","content":"ignored"}}
        {"type":"user","uuid":"u3","parentUuid":"a1","message":{"role":"user","content":"three"}}
        {"type":"assistant","uuid":"a3","parentUuid":"u3","message":{"id":"m3","content":[{"type":"text","text":"third"}]}}
        """
        let data = ClaudeTranscriptFiles.parse(Data(text.utf8))
        #expect(data.entries.count == 6)
        #expect(data.parents["x1"] == "u1")
        let uuids = data.activeChain().compactMap { $0["uuid"]?.stringValue }
        #expect(uuids == ["u1", "a1", "u3", "a3"])
        // A pending rewind keeps only the history up to its entry.
        #expect(data.activeChain(leafOverride: "a1").compactMap { $0["uuid"]?.stringValue } == ["u1", "a1"])
        #expect(data.activeChain(leafOverride: "a2").compactMap { $0["uuid"]?.stringValue } == ["u1", "a1", "u2", "a2"])
        // An entry the file does not have (a fork copies entries under new ids) falls back to the newest leaf.
        #expect(data.activeChain(leafOverride: "zz").compactMap { $0["uuid"]?.stringValue } == ["u1", "a1", "u3", "a3"])
    }

    @Test func forkPointsIncludeWholeMessagesAndToolResults() throws {
        let chain = try F.transcript("transcript-edit.jsonl").activeChain()
        // Forking at the thinking row keeps the rest of that message and the Read result.
        #expect(ClaudeHistory.forkPoint(at: "msg_011Ch9jcR542wbfKHnoEKU1K:0", in: chain) == "e5a08afa-fe32-436e-b1e2-1a3a7ad3adcd")
        #expect(ClaudeHistory.forkPoint(at: "toolu_01PwUNGGdP1Y8bPcjtPN1Bj1", in: chain) == "e5a08afa-fe32-436e-b1e2-1a3a7ad3adcd")
        #expect(ClaudeHistory.forkPoint(at: "msg_011Ch9jd8SxT7RjJThXGhzbE:0", in: chain) == "3b0641b5-aa27-4a83-b2e6-d1271463bf80")
        #expect(ClaudeHistory.forkPoint(at: "nope", in: chain) == nil)
    }

    @Test func rewindCuts() throws {
        let chain = try F.transcript("transcript-interrupt.jsonl").activeChain()
        let second = ClaudeHistory.cut(before: "0e93b25c-d8cb-47ba-a768-dd61977d8592", in: chain)
        #expect(second == ClaudeHistory.Cut(keep: "87a97da1-85bc-4380-baf8-c040c9f5c1aa", restorePrompt: "0e93b25c-d8cb-47ba-a768-dd61977d8592"))
        let first = ClaudeHistory.cut(before: "85a68e53-8624-492f-83cf-215695575043", in: chain)
        #expect(first == ClaudeHistory.Cut(keep: nil, restorePrompt: "85a68e53-8624-492f-83cf-215695575043"))
        // A cut at an agent row moves back to the start of that model message.
        let reply = ClaudeHistory.cut(before: "msg_011Ch9jmJYQ3mSiTSFAjaspo:1", in: chain)
        #expect(reply?.keep == "85a68e53-8624-492f-83cf-215695575043")
        let edits = try F.transcript("transcript-edit.jsonl").activeChain()
        let tool = ClaudeHistory.cut(before: "toolu_018qT9G4UnxQv594A9WPBvz9", in: edits)
        #expect(tool?.keep == "e5a08afa-fe32-436e-b1e2-1a3a7ad3adcd")
        #expect(tool?.restorePrompt == nil)
    }
}

@Suite("Claude Code launch and configuration")
struct ClaudeCodeLaunchTests {
    func options(_ start: ClaudeLaunchOptions.Start = .new, mode: PermissionMode = .ask) -> ClaudeLaunchOptions {
        ClaudeLaunchOptions(sessionID: "sid", start: start, resumeAt: nil, model: "haiku", effort: "high", permissionMode: mode,
                            settingSources: .all, thinkingDisplay: "summarized", fastMode: nil)
    }

    @Test func argumentsUseTheDocumentedHeadlessFlags() {
        let args = ClaudeCLI.arguments(options())
        #expect(Array(args.prefix(8)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                          "--include-partial-messages", "--forward-subagent-text"])
        #expect(args.contains("--permission-prompt-tool"))
        #expect(args.split(separator: "--permission-mode").count == 2)
        #expect(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] } == "default")
        #expect(args.suffix(2) == ["--session-id", "sid"])
        #expect(args.firstIndex(of: "--model").map { args[$0 + 1] } == "haiku")
        #expect(args.firstIndex(of: "--effort").map { args[$0 + 1] } == "high")
        #expect(!args.contains("--bare"))
        #expect(!args.contains("--setting-sources"))
        #expect(!args.contains("--allow-dangerously-skip-permissions"))
        #expect(!args.contains("--fast-mode"))

        // Extra arguments can never turn on bare mode or skip permissions.
        var extra = options()
        extra.extraArguments = ["--bare", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--debug"]
        let extraArgs = ClaudeCLI.arguments(extra)
        #expect(!extraArgs.contains("--bare"))
        #expect(!extraArgs.contains("--dangerously-skip-permissions"))
        #expect(!extraArgs.contains("--allow-dangerously-skip-permissions"))
        #expect(extraArgs.last == "--debug")
    }

    @Test func settingSourcesFollowWorkspaceTrust() {
        #expect(ClaudeSettingSources.all.effective(trusted: true) == .all)
        #expect(ClaudeSettingSources.all.effective(trusted: false) == .userOnly)
        #expect(ClaudeSettingSources.projectOnly.effective(trusted: false) == ClaudeSettingSources.none)
        #expect(ClaudeSettingSources.none.effective(trusted: false) == ClaudeSettingSources.none)
        var untrusted = options()
        untrusted.settingSources = ClaudeSettingSources.all.effective(trusted: false)
        let args = ClaudeCLI.arguments(untrusted)
        #expect(args.firstIndex(of: "--setting-sources").map { args[$0 + 1] } == "user")
    }

    @Test func resumeForkAndModes() {
        var resume = options(.resume)
        resume.resumeAt = "entry"
        #expect(ClaudeCLI.arguments(resume).suffix(4) == ["--resume", "sid", "--resume-session-at", "entry"])
        let fork = ClaudeCLI.arguments(options(.fork(from: "old")))
        #expect(fork.suffix(5) == ["--resume", "old", "--fork-session", "--session-id", "sid"])
        #expect(ClaudeCLI.arguments(options(mode: .bypass)).contains("--allow-dangerously-skip-permissions"))
        #expect(ClaudePermissionModes.cliMode(.acceptEdits) == "acceptEdits")
        #expect(ClaudePermissionModes.cliMode(.auto) == "auto")
        #expect(ClaudePermissionModes.cliMode(.bypass) == "bypassPermissions")
        var limited = options()
        limited.settingSources = .projectOnly
        limited.fastMode = true
        let args = ClaudeCLI.arguments(limited)
        #expect(args.firstIndex(of: "--setting-sources").map { args[$0 + 1] } == "project,local")
        #expect(args.firstIndex(of: "--fast-mode").map { args[$0 + 1] } == "on")
        var none = options()
        none.settingSources = .none
        let noneArgs = ClaudeCLI.arguments(none)
        #expect(noneArgs.firstIndex(of: "--setting-sources").map { noneArgs[$0 + 1] } == "")
    }

    @Test func environmentDropsKeysAndSessionVariables() {
        let base = ["HOME": "/Users/me", "USER": "me", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-secret",
                    "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "CLAUDE_CODE_OAUTH_TOKEN": "o",
                    "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-alt", "RANDOM_VAR": "y"]
        let env = ClaudeCLI.environment(base: base, billing: .subscription, apiKey: "sk-ensemble")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(env["RANDOM_VAR"] == nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-alt")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["PATH"]?.hasPrefix("/usr/bin:/bin:") == true)
        #expect(env["PATH"]?.contains("/Users/me/.local/bin") == true)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("ANTHROPIC_") })

        let api = ClaudeCLI.environment(base: base, billing: .apiKey, apiKey: "sk-ensemble", fileCheckpointing: true)
        #expect(api["ANTHROPIC_API_KEY"] == "sk-ensemble")
        #expect(api["ANTHROPIC_BASE_URL"] == nil)
        #expect(api["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1")
        #expect(api["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1")
    }

    @Test func promptContentBlocks() throws {
        let blocks = try ClaudeCLI.contentBlocks(synthetic: ["[Room] Ada: hi"], text: "hello", files: [URL(fileURLWithPath: "/tmp/notes.md")])
        #expect(blocks.count == 3)
        #expect(blocks[0]["text"]?.stringValue == "[Room] Ada: hi")
        #expect(blocks[1]["text"]?.stringValue == "hello")
        #expect(blocks[2]["text"]?.stringValue?.contains("/tmp/notes.md") == true)
        let message = ClaudeCLI.userMessage(blocks: blocks)
        #expect(message["type"]?.stringValue == "user")
        #expect(message["message"]?["role"]?.stringValue == "user")
        #expect(throws: ClaudeCodeError.self) { try ClaudeCLI.contentBlocks(synthetic: [], text: "", files: []) }
    }

    @Test func authStatusKeepsOnlyTheSignInFields() {
        let text = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"someone@example.com","orgId":"o","subscriptionType":"max"}"#
        let state = ClaudeAuthState.parse(text, installed: true, version: "2.1.319")
        #expect(state == ClaudeAuthState(installed: true, version: "2.1.319", loggedIn: true, authMethod: "claude.ai", subscriptionType: "max"))
        #expect(!String(describing: state).contains("example.com"))
        #expect(ClaudeAuthState.parse("Not logged in", installed: true, version: nil).loggedIn == false)
    }

    @Test func contextFromTheCLIsOwnBreakdown() throws {
        let line = try #require(JSONValue.parse(data: try Fixtures.data("claude-code/control-context-usage.json")))
        let breakdown = try #require(ClaudeContext.breakdown(from: line["response"]?["response"] ?? .null))
        #expect(breakdown.usedTokens == 21144)
        #expect(breakdown.limitTokens == 500_000)
        let tokens = Dictionary(uniqueKeysWithValues: breakdown.categories.map { ($0.key, $0.tokens) })
        #expect(tokens["systemPrompt"] == 2530)
        #expect(tokens["tools"] == 2244)
        #expect(tokens["mcp"] == 679 + 1181)
        #expect(tokens["skills"] == 9961)
        #expect(tokens["messages"] == 3729)
        #expect(tokens["buffer"] == 33000)
        #expect(tokens["free"] == 445_856)
        // Deferred tools are not loaded into the context.
        #expect(!breakdown.categories.contains { $0.tokens == 157_889 })

        let estimate = ClaudeContext.estimate(usedTokens: 50_000, limit: 200_000)
        #expect(estimate.usedTokens == 50_000)
        #expect(estimate.categories.map(\.key) == ["messages", "buffer", "free"])
        #expect(estimate.categories.last?.tokens == 117_000)
    }

    @Test func initializeAnswerGivesModelsAndCommandsButNotTheAccount() {
        let response: JSONValue = [
            "account": ["email": "someone@example.com", "organization": "Org"],
            "fast_mode_state": "off", "fast_mode_disabled_reason": "sdk_opt_in_required",
            "models": [
                ["value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus 5.5", "supportsEffort": true,
                 "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"], "supportsFastMode": true],
                ["value": "claude-haiku-4-5-20251001", "displayName": "Haiku 4.5", "supportsEffort": nil],
            ],
            "commands": [
                ["name": "compact", "description": "Free up context", "argumentHint": "<instructions>", "builtin": true],
                ["name": "clear", "description": "Start a new session", "builtin": true],
                ["name": "model", "description": "Set the model", "builtin": true],
                ["name": "doctor", "description": "Check", "builtin": true],
                ["name": "commit", "description": "Commit changes (user)", "argumentHint": ""],
                ["name": "deploy", "description": "Deploy (project)"],
            ],
        ]
        let info = ClaudeInitializeInfo(response: response)
        #expect(info.models.count == 2)
        #expect(info.models[0].effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(info.models[0].supportsFastMode)
        #expect(info.models[1].effortLevels.isEmpty)
        #expect(info.fastModeDisabledReason == "sdk_opt_in_required")
        #expect(!String(describing: info).contains("example.com"))
        let commands = info.engineCommands(skills: ["commit"], terminalOnly: ["doctor"])
        #expect(commands.map(\.name) == ["compact", "commit", "deploy"])
        #expect(commands[0].kind == .command)
        #expect(commands[0].argumentHint == "<instructions>")
        #expect(commands[1].kind == .skill)
        #expect(commands[1].summary == "Commit changes")
        #expect(commands[1].argumentHint == nil)
        #expect(commands[2].kind == .command)
        #expect(commands[2].summary == "Deploy")
    }

    @Test func modelCatalogAndIDs() {
        #expect(ClaudeModels.billing(for: ModelRef(providerID: "claude-code-api", id: "sonnet")) == .apiKey)
        #expect(ClaudeModels.billing(for: ModelRef(providerID: "claude-code", id: "sonnet")) == .subscription)
        #expect(ClaudeModels.contextLimit(for: "haiku", observed: [:]) == 1_000_000)
        #expect(ClaudeModels.contextLimit(for: "sonnet", observed: ["claude-sonnet-5-5": 400_000]) == 400_000)
        #expect(ClaudeModels.contextLimit(for: "opus[1m]", observed: ["claude-opus-5-5": 200_000]) == 1_000_000)
        // Every current model has a 1M window with its plain id; the older 4.6 models and Haiku 4.5 have 200k.
        for id in ["opus", "sonnet", "haiku", "fable", "claude-fable-5-2", "claude-opus-5-5"] {
            #expect(ClaudeModels.contextLimit(for: id, observed: [:]) == 1_000_000)
        }
        #expect(ClaudeModels.contextLimit(for: "claude-sonnet-4-6", observed: [:]) == 200_000)
        #expect(ClaudeModels.contextLimit(for: "claude-sonnet-4-6[1m]", observed: [:]) == 1_000_000)
        #expect(ClaudeModels.contextLimit(for: "claude-haiku-4-5-20251001", observed: [:]) == 200_000)
        #expect(ClaudeModels.contextLimit(for: "claude-unknown-9", observed: [:]) == nil)
        // One entry per current model: no separate 200k and 1M entries.
        #expect(ClaudeModels.catalog.map(\.id) == ["opus", "claude-fable-5-2", "sonnet", "haiku", "fable"])
        #expect(!ClaudeModels.catalog.contains { $0.id.hasSuffix("[1m]") })
        #expect(!ClaudeSessionIDs.isChild("0b9c2f1e-0000-4000-8000-000000000000"))
        #expect(ClaudeSessionIDs.toolUseID(of: "root.toolu_1") == "toolu_1")
    }

    @Test func sessionStoreRoundTripAndTolerantDecoding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-claude-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("claude-sessions.json")
        var store = ClaudeSessionStore(fileURL: url)
        var record = ClaudeSessionRecord(id: "a", title: "T", directory: "/p", model: ModelRef(providerID: "claude-code", id: "sonnet", variant: "high"),
                                         permissionMode: .acceptEdits)
        #expect(record.effort == "high")
        record.usage = Usage(inputTokens: 3, costUSD: 0.5)
        record.rememberSynthetic("hi")
        store["a"] = record
        try store.save()
        let loaded = ClaudeSessionStore(fileURL: url)
        #expect(loaded["a"]?.title == "T")
        #expect(loaded["a"]?.usage.costUSD == 0.5)
        #expect(loaded["a"]?.syntheticTexts == ["hi"])
        #expect(loaded["a"]?.permissionMode == .acceptEdits)

        try Data(#"{"version":1,"sessions":[{"id":"b","title":"Old","directory":"/q"}]}"#.utf8).write(to: url)
        let old = ClaudeSessionStore(fileURL: url)
        #expect(old["b"]?.title == "Old")
        #expect(old["b"]?.started == false)
        #expect(old["b"]?.permissionMode == .ask)
    }
}

#if os(macOS)
/// The engine without a `claude` binary: sessions, transcripts from planted CLI files, fork and rewind bookkeeping.
@Suite("Claude Code engine offline")
struct ClaudeCodeEngineOfflineTests {
    typealias F = ClaudeFixtures

    final class Sandbox: @unchecked Sendable {
        let folder: URL
        let project: URL
        let projects: URL
        let store: URL
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-claude-\(UUID().uuidString)")
            project = folder.appendingPathComponent("proj")
            projects = folder.appendingPathComponent("projects")
            store = folder.appendingPathComponent("claude-sessions.json")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projects.appendingPathComponent("-tmp-ensemble-claude-proj"), withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }

        lazy var trust = WorkspaceTrust(fileURL: folder.appendingPathComponent("trusted-folders.json"))

        func engine(executable: String = "/nonexistent/claude") -> ClaudeCodeEngine {
            ClaudeCodeEngine(configuration: .init(executablePath: executable, storeURL: store, projectsDirectory: projects,
                                                  fileCheckpointing: false, keychainService: "Ensemble test \(UUID().uuidString)",
                                                  baseEnvironment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], trust: trust))
        }

        /// Plants a CLI transcript (and optional subagent files) and a saved record that says the session started.
        func plant(_ fixture: String, subagent: String? = nil) throws {
            let folder = projects.appendingPathComponent("-tmp-ensemble-claude-proj")
            try Fixtures.data("claude-code/\(fixture)").write(to: folder.appendingPathComponent("\(F.root).jsonl"))
            if let subagent {
                let sub = folder.appendingPathComponent(F.root).appendingPathComponent("subagents")
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try Fixtures.data("claude-code/\(subagent).jsonl").write(to: sub.appendingPathComponent("agent-a1.jsonl"))
                try Fixtures.data("claude-code/\(subagent).meta.json").write(to: sub.appendingPathComponent("agent-a1.meta.json"))
            }
            let body = """
            {"version":1,"sessions":[{"id":"\(F.root)","title":"Fixture","directory":"\(F.directory)","permissionMode":"ask",
            "created":"2026-11-18T04:00:00Z","updated":"2026-11-18T04:10:00Z","started":true,
            "model":{"providerID":"claude-code","id":"haiku"}}]}
            """
            try Data(body.utf8).write(to: store)
        }
    }

    @Test func sessionsWithoutTheCLI() async throws {
        let box = try Sandbox()
        let engine = box.engine()
        let events = engine.events()
        let session = try await engine.createSession(directory: box.project.path, model: ModelRef(providerID: "claude-code", id: "haiku"),
                                                     agent: nil, permissionMode: .ask, parentID: nil)
        #expect(session.title == "New session")
        #expect(UUID(uuidString: session.id) != nil)
        #expect(try await engine.listSessions().map(\.id) == [session.id])
        await #expect(throws: ClaudeCodeError.notInstalled) { try await engine.prompt(session.id, text: "hi", files: []) }
        await #expect(throws: ClaudeCodeError.self) {
            try await engine.createSession(directory: box.project.path, model: ModelRef(providerID: "openai", id: "gpt"), agent: nil,
                                           permissionMode: .ask, parentID: nil)
        }
        await #expect(throws: ClaudeCodeError.self) {
            try await engine.createSession(directory: "/no/such/folder", model: nil, agent: nil, permissionMode: .ask, parentID: nil)
        }
        try await engine.renameSession(session.id, title: "Renamed")
        try await engine.setPermissionMode(session.id, mode: .acceptEdits)
        try await engine.setEffort(session.id, effort: .max)
        #expect(try await engine.schedules().isEmpty)
        await #expect(throws: ClaudeCodeError.self) {
            try await engine.createSchedule(title: "t", prompt: "p", directory: box.project.path, schedule: "every 5 minutes", model: nil)
        }
        await #expect(throws: ClaudeCodeError.self) { try await engine.fork(session.id, atMessageID: nil) }
        #expect(try await engine.transcript(session.id).isEmpty)
        #expect(try await engine.pendingPermissions().isEmpty)
        let context = try await engine.context(session.id)
        #expect(context.limitTokens == 1_000_000)
        try await engine.injectSynthetic(session.id, text: "[Room] Ada: plan", wake: false)

        // A second engine on the same file sees the saved state.
        let again = box.engine()
        let listed = try await again.listSessions()
        #expect(listed.first?.title == "Renamed")
        #expect(listed.first?.model?.variant == "max")
        try await engine.deleteSession(session.id)
        #expect(try await engine.listSessions().isEmpty)

        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .sessionCreated(session))
    }

    @Test func transcriptChildrenAndOutputsFromCLIFiles() async throws {
        let box = try Sandbox()
        try box.plant("transcript-subagent.jsonl", subagent: "transcript-subagent-agent")
        let engine = box.engine()
        let items = try await engine.transcript(F.root)
        #expect(items.contains { if case .agentText(_, "alpha", _, _) = $0 { true } else { false } })
        let kids = try await engine.children(F.root)
        let child = try #require(kids.first)
        #expect(child.id == "\(F.root).toolu_01WJd3ydmJdPAFjh93jKrT5Y")
        #expect(child.parentID == F.root)
        #expect(child.title == "Read notes.txt first word")
        let childItems = try await engine.transcript(child.id)
        #expect(childItems.contains { if case .tool(let info) = $0 { info.name == "Read" } else { false } })
        await #expect(throws: ClaudeCodeError.self) { try await engine.prompt(child.id, text: "hi", files: []) }
    }

    @Test func forkAndRewindRewriteWhatTheTranscriptShows() async throws {
        let box = try Sandbox()
        try box.plant("transcript-interrupt.jsonl")
        let engine = box.engine()
        #expect(try await engine.changedFiles(F.root).isEmpty)

        // Fork at the first reply: the fork shows the history up to there until its first turn runs.
        let fork = try await engine.fork(F.root, atMessageID: "msg_011Ch9jmJYQ3mSiTSFAjaspo:1")
        #expect(fork.id != F.root)
        #expect(fork.title == "Fixture (fork)")
        let forkItems = try await engine.transcript(fork.id)
        #expect(!forkItems.contains { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })
        #expect(forkItems.contains { if case .agentText(_, let text, _, _) = $0 { text.hasPrefix("one\ntwo") } else { false } })

        // Rewind to before the second prompt: it leaves the transcript.
        try await engine.rewind(F.root, toBeforeMessageID: "0e93b25c-d8cb-47ba-a768-dd61977d8592")
        let rewound = try await engine.transcript(F.root)
        #expect(!rewound.contains { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })
        #expect(rewound.contains { if case .notice(_, "Interrupted") = $0 { true } else { false } })

        // Rewind to before the first prompt: an empty conversation under a new CLI id.
        try await engine.rewind(F.root, toBeforeMessageID: "85a68e53-8624-492f-83cf-215695575043")
        #expect(try await engine.transcript(F.root).isEmpty)
        await #expect(throws: ClaudeCodeError.self) { try await engine.rewind(F.root, toBeforeMessageID: "nope") }
    }

    @Test func commandsAndOptionsWithoutTheCLI() async throws {
        let box = try Sandbox()
        let engine = box.engine()
        await #expect(throws: ClaudeCodeError.notInstalled) { try await engine.commands(directory: box.project.path) }
        let options = try await engine.modelOptions(for: ModelRef(providerID: "claude-code", id: "opus"))
        #expect(options.effortLevels == EffortLevel.allCases)
        #expect(options.supportsFastMode)
        #expect(engine.rewindRestoresFiles == false)
        let providers = try await engine.providers()
        #expect(providers.map(\.id) == ["claude-code", "claude-code-api"])
        #expect(providers.allSatisfy { !$0.connected })
        await #expect(throws: ClaudeCodeError.self) { try await engine.runCommand("x", name: "clear", arguments: "") }
        await #expect(throws: ClaudeCodeError.self) { try await engine.runCommand("x", name: "two words", arguments: "") }
    }
}
#endif

@Suite("Claude Code workspace trust")
struct ClaudeCodeTrustTests {
    typealias Snapshot = ClaudeProjectSettings.Snapshot

    func write(_ json: String, to folder: URL, name: String = "settings.json") throws {
        let dir = folder.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent(name))
    }

    func snapshot(_ settings: [String: JSONValue], mcp: [String: JSONValue] = [:]) -> Snapshot {
        Snapshot(directory: "/p", settings: settings, mcpServers: mcp, unreadable: [:])
    }

    @Test func safeListAndConfirmationScopes() {
        let safe = snapshot(["env": ["DISABLE_TELEMETRY": "1", "BASH_DEFAULT_TIMEOUT_MS": 120000, "MCP_TIMEOUT": "true",
                                     "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"],
                             "permissions": ["deny": ["Read(/secret/**)"], "ask": ["Bash(git push:*)"]], "model": "sonnet",
                             "$schema": "https://json.schemastore.org/claude-code-settings.json"])
        #expect(safe.needsConfirmation(for: .apiKey).isEmpty)
        #expect(safe.needsConfirmation(for: .subscription).isEmpty)

        // A safe key with a value that is not a plain number or yes/no asks.
        let odd = snapshot(["env": ["BASH_DEFAULT_TIMEOUT_MS": "/tmp/x", "MCP_TIMEOUT": "10000000000", "DISABLE_TELEMETRY": ["a"]]])
        #expect(odd.needsConfirmation(for: .apiKey) == ["BASH_DEFAULT_TIMEOUT_MS", "DISABLE_TELEMETRY", "MCP_TIMEOUT"])

        let risky = snapshot([
            "env": ["NODE_OPTIONS": "--require ./x.js", "NODE_EXTRA_CA_CERTS": "./ca.pem", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "0",
                    "EDITOR": "vim", "PATH": "./bin:/usr/bin", "HtTpS_PrOxY": "http://127.0.0.1:9", "ANTHROPIC_BASE_URL": "https://x",
                    "SSL_CERT_FILE": "./c", "DYLD_INSERT_LIBRARIES": "./l.dylib"],
            "hooks": ["PreToolUse": []], "statusLine": ["type": "command", "command": "./s.sh"], "enabledPlugins": ["p@m": true],
            "apiKeyHelper": "./key.sh", "someFutureSetting": true, "permissions": ["allow": ["Bash(*)"]],
        ], mcp: ["docs": ["command": "./server"]])
        #expect(risky.needsConfirmation(for: .apiKey) == [
            "ANTHROPIC_BASE_URL", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DYLD_INSERT_LIBRARIES", "EDITOR", "HtTpS_PrOxY", "MCP server docs",
            "NODE_EXTRA_CA_CERTS", "NODE_OPTIONS", "PATH", "SSL_CERT_FILE", "apiKeyHelper", "enabledPlugins", "hooks",
            "permissions.allow", "someFutureSetting", "statusLine",
        ])
        // A subscription agent only asks about what can redirect requests or the login: never EDITOR, hooks, MCP
        // servers, status lines or allow rules, which a trusted folder may use as in Claude Code itself.
        #expect(risky.needsConfirmation(for: .subscription) == [
            "ANTHROPIC_BASE_URL", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DYLD_INSERT_LIBRARIES", "HtTpS_PrOxY", "NODE_EXTRA_CA_CERTS",
            "NODE_OPTIONS", "PATH", "SSL_CERT_FILE", "apiKeyHelper",
        ])
        let unreadable = Snapshot(directory: "/p", settings: [:], mcpServers: [:], unreadable: [".claude/settings.json": "abc"])
        #expect(unreadable.needsConfirmation(for: .subscription) == ["unreadable .claude/settings.json"])
    }

    @Test func numbersFromUntrustedJSONNeverTrap() {
        for value in [1e300, -1e300, Double.infinity, -Double.infinity, Double.nan, Double.greatestFiniteMagnitude, 1.5, -1,
                      1_000_000_000, 9.3e18] {
            #expect(!ClaudeProjectSettings.isSafeEnv("BASH_DEFAULT_TIMEOUT_MS", .number(value)), "\(value) should ask")
        }
        #expect(ClaudeProjectSettings.isSafeEnv("BASH_DEFAULT_TIMEOUT_MS", .number(120_000)))
        #expect(ClaudeProjectSettings.isSafeEnv("BASH_MAX_OUTPUT_LENGTH", .number(999_999_999)))
        #expect(ClaudeProjectSettings.isSafeEnv("MCP_TIMEOUT", .number(0)))
        // A whole snapshot with such values still decides, and one that cannot be written as JSON can never be confirmed.
        let odd = snapshot(["env": ["BASH_DEFAULT_TIMEOUT_MS": .number(1e300), "MCP_TIMEOUT": .number(.nan)]])
        #expect(odd.needsConfirmation(for: .apiKey) == ["BASH_DEFAULT_TIMEOUT_MS", "MCP_TIMEOUT"])
        #expect(odd.fingerprint != odd.fingerprint)
        #expect(throws: ClaudeCodeError.self) {
            try ClaudeSettingsPlan.decide(billing: .apiKey, trusted: true, directory: "/p", snapshot: odd, confirmed: odd.fingerprint)
        }
        // Real files: a number too big for a Double makes the file unreadable rather than crashing anything.
        #expect(JSONValue.parse(line: #"{"env":{"BASH_DEFAULT_TIMEOUT_MS":1e400}}"#) == nil)
        let huge = JSONValue.parse(line: #"{"BASH_DEFAULT_TIMEOUT_MS":1e300}"#)
        #expect(huge?["BASH_DEFAULT_TIMEOUT_MS"].map { ClaudeProjectSettings.isSafeEnv("BASH_DEFAULT_TIMEOUT_MS", $0) } == false)
    }

    @Test func permissionsAreAnAllowlistOfKeys() {
        let restrictive = snapshot(["permissions": ["deny": ["Read(/secret/**)"], "ask": ["Bash(git push:*)"],
                                                    "disableBypassPermissionsMode": "disable"]])
        #expect(restrictive.needsConfirmation(for: .apiKey).isEmpty)
        let loosening = snapshot(["permissions": ["deny": [], "allow": [], "additionalDirectories": ["../shared"],
                                                  "defaultMode": "bypassPermissions", "somethingNew": true]])
        #expect(loosening.needsConfirmation(for: .apiKey) == ["permissions.additionalDirectories", "permissions.allow",
                                                              "permissions.defaultMode", "permissions.somethingNew"])
        #expect(snapshot(["permissions": "allow everything"]).needsConfirmation(for: .apiKey) == ["permissions"])
        // A subscription agent in a trusted folder follows the project's permissions as Claude Code does; the engine
        // always passes --permission-mode, which outranks a project defaultMode.
        #expect(loosening.needsConfirmation(for: .subscription).isEmpty)
    }

    @Test func loginPinsKeepTheUsersOwnValuesAndNeverCopySecrets() throws {
        let box = try ClaudeCodeEngineOfflineTests.Sandbox()
        let user = box.folder.appendingPathComponent("user-settings.json")
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example","ANTHROPIC_API_KEY":"sk-user","NODE_EXTRA_CA_CERTS":"/etc/corp.pem","EDITOR":"vim"}}"#.utf8)
            .write(to: user)
        let pins = ClaudeProjectSettings.loginPins(environment: ["HTTPS_PROXY": "http://proxy.corp:8080", "HOME": "/Users/me"],
                                                   userSettings: user)
        #expect(Set(pins.keys) == ClaudeProjectSettings.pinnedEnvKeys)
        #expect(pins["HTTPS_PROXY"] == "http://proxy.corp:8080")
        #expect(pins["ANTHROPIC_BASE_URL"] == "https://gateway.example")
        // Never pinned empty: an empty config folder moves the CLI's config into the session folder, and an empty CA
        // file can break TLS for the agent's tools. Those stop the process through the watcher instead.
        #expect(pins["CLAUDE_CONFIG_DIR"] == nil)
        #expect(pins["NODE_EXTRA_CA_CERTS"] == nil)
        #expect(pins["SSL_CERT_FILE"] == nil)
        #expect(ClaudeProjectSettings.loginPins(environment: ["CLAUDE_CONFIG_DIR": "/x/cfg"], userSettings: nil)["CLAUDE_CONFIG_DIR"] == "/x/cfg")
        #expect(snapshot(["env": ["CLAUDE_CONFIG_DIR": "/evil", "SSL_CERT_FILE": "./ca.pem"]]).unpinnedRedirects == ["CLAUDE_CONFIG_DIR", "SSL_CERT_FILE"])
        #expect(pins["ANTHROPIC_API_KEY"] == "")
        #expect(pins["CLAUDE_CODE_OAUTH_TOKEN"] == "")
        #expect(pins["NODE_OPTIONS"] == "")
        #expect(pins["EDITOR"] == nil)
        #expect(ClaudeProjectSettings.loginPins(environment: [:], userSettings: nil)["ANTHROPIC_BASE_URL"] == "")
        #expect(ClaudeProjectSettings.userSettingsFile(environment: ["HOME": "/Users/me"])?.path == "/Users/me/.claude/settings.json")
        #expect(ClaudeProjectSettings.userSettingsFile(environment: ["HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/x/cfg"])?.path == "/x/cfg/settings.json")

        // Only what the pins do not cover stops a running process.
        #expect(snapshot(["env": ["ANTHROPIC_BASE_URL": "https://x", "HTTPS_PROXY": "http://y", "NODE_OPTIONS": "--inspect"]]).unpinnedRedirects.isEmpty)
        #expect(snapshot(["apiKeyHelper": "./k.sh", "env": ["ANTHROPIC_SOMETHING_NEW": "1", "PATH": "./bin"]]).unpinnedRedirects
                == ["ANTHROPIC_SOMETHING_NEW", "PATH", "apiKeyHelper"])
        #expect(Snapshot(directory: "/p", settings: [:], mcpServers: [:], unreadable: [".claude/settings.json": "x"]).unpinnedRedirects
                == ["unreadable .claude/settings.json"])
    }

    @Test func snapshotReadsOnlyTheFolderAndMergesLikeTheCLI() throws {
        let box = try ClaudeCodeEngineOfflineTests.Sandbox()
        let repo = box.folder.appendingPathComponent("repo")
        let project = repo.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Settings in a folder above are not read by the CLI, so they are not part of the snapshot either.
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"https://parent.example"}}"#, to: repo)
        let empty = try #require(ClaudeProjectSettings.snapshot(directory: project.path))
        #expect(empty.isEmpty)
        #expect(!ClaudeProjectSettings.hasOwnSettings(directory: project.path))

        try write(#"""
        {"env":{"A":"project","B":"project"},"permissions":{"allow":["Bash(npm test:*)"],"deny":["Read(/secret/**)","Read(//etc/**)","Read(./x)","Bash(rm:*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"./a.sh"}]}]}}
        """#, to: project)
        try write(#"{"env":{"B":"local"},"permissions":{"allow":["Bash(make:*)"]},"disabledMcpjsonServers":["off"]}"#,
                  to: project, name: "settings.local.json")
        try Data(#"{"mcpServers":{"docs":{"command":"./docs"},"off":{"command":"./off"}}}"#.utf8)
            .write(to: project.appendingPathComponent(".mcp.json"))
        let found = try #require(ClaudeProjectSettings.snapshot(directory: project.path))
        let root = try #require(WorkspaceTrust.resolvedPath(project.path))
        #expect(found.directory == root)
        #expect(found.settings["env"] == ["A": "project", "B": "local"])
        #expect(found.settings["permissions"]?["allow"] == ["Bash(npm test:*)", "Bash(make:*)"])
        // `/path` rules mean "in this project"; in the private copy they become absolute and keep that meaning.
        #expect(found.settings["permissions"]?["deny"] == .array([.string("Read(/\(root)/secret/**)"), "Read(//etc/**)", "Read(./x)", "Bash(rm:*)"]))
        #expect(found.settings["hooks"] != nil)
        #expect(Array(found.mcpServers.keys) == ["docs"])
        #expect(ClaudeProjectSettings.hasOwnSettings(directory: project.path))
        // The private files hold exactly the snapshot.
        #expect(JSONValue.parse(data: found.settingsData) == .object(found.settings))
        #expect(JSONValue.parse(data: try #require(found.mcpData))?["mcpServers"]?["docs"] == ["command": "./docs"])

        // Same files, same fingerprint; any change, a new one.
        #expect(ClaudeProjectSettings.snapshot(directory: project.path)?.fingerprint == found.fingerprint)
        try Data(#"{"mcpServers":{"docs":{"command":"./docs2"}}}"#.utf8).write(to: project.appendingPathComponent(".mcp.json"))
        #expect(ClaudeProjectSettings.snapshot(directory: project.path)?.fingerprint != found.fingerprint)
        try write("{ not json", to: project, name: "settings.local.json")
        let broken = try #require(ClaudeProjectSettings.snapshot(directory: project.path))
        #expect(broken.unreadable.keys.sorted() == [".claude/settings.local.json"])
        try write("{ not json either", to: project, name: "settings.local.json")
        #expect(ClaudeProjectSettings.snapshot(directory: project.path)?.fingerprint != broken.fingerprint)

        // Commands, skills or agents alone are also the folder's own settings.
        let commands = box.folder.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands.appendingPathComponent(".claude/commands"), withIntermediateDirectories: true)
        #expect(ClaudeProjectSettings.hasOwnSettings(directory: commands.path))
    }

    @Test func plansFollowBillingTrustAndConfirmation() throws {
        let hooks = snapshot(["hooks": ["Stop": []]])
        let redirect = snapshot(["env": ["ANTHROPIC_BASE_URL": "https://x.example"]])
        let empty = snapshot([:])
        func plan(_ billing: ClaudeBilling, trusted: Bool, _ found: Snapshot, confirmed: String? = nil) throws -> ClaudeSettingsPlan {
            try ClaudeSettingsPlan.decide(billing: billing, trusted: trusted, directory: "/p", snapshot: found, confirmed: confirmed)
        }
        // Untrusted: the project's settings are left out; an API-key agent still refuses a folder that redirects.
        #expect(try plan(.subscription, trusted: false, redirect) == .userOnly)
        #expect(try plan(.apiKey, trusted: false, hooks) == .userOnly)
        #expect(throws: ClaudeCodeError.folderNotTrusted("/p")) { try plan(.apiKey, trusted: false, redirect) }

        // Trusted subscription agent: the CLI reads the files (and the engine watches them) unless they redirect.
        #expect(try plan(.subscription, trusted: true, hooks) == .project)
        #expect(try plan(.subscription, trusted: true, empty) == .project)
        #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: "/p", keys: ["ANTHROPIC_BASE_URL"])) {
            try plan(.subscription, trusted: true, redirect)
        }
        #expect(try plan(.subscription, trusted: true, redirect, confirmed: redirect.fingerprint) == .snapshot(redirect))
        #expect(throws: ClaudeCodeError.self) { try plan(.subscription, trusted: true, redirect, confirmed: hooks.fingerprint) }

        // Trusted API-key agent: always a private copy, so nothing added to the files later can take effect.
        #expect(try plan(.apiKey, trusted: true, empty) == .snapshot(empty))
        #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: "/p", keys: ["hooks"])) {
            try plan(.apiKey, trusted: true, hooks)
        }
        #expect(try plan(.apiKey, trusted: true, hooks, confirmed: hooks.fingerprint) == .snapshot(hooks))
    }

    @Test func apiKeyAgentsNeedTrustAndConfirmation() async throws {
        let box = try ClaudeCodeEngineOfflineTests.Sandbox()
        let noKey = ClaudeCodeError.invalidArgument("No Anthropic API key is saved for Claude API billing. Add one in Settings.")
        // `/usr/bin/true` only gets past the "is claude installed" check; every case below stops before a launch.
        let engine = box.engine(executable: "/usr/bin/true")
        let api = try await engine.createSession(directory: box.project.path, model: ModelRef(providerID: "claude-code-api", id: "haiku"),
                                                 agent: nil, permissionMode: .ask, parentID: nil)
        // Hooks in an untrusted folder are left out, so they do not stop an API-key agent.
        try write(#"{"hooks":{"Stop":[]}}"#, to: box.project)
        #expect(engine.ignoresProjectSettings(directory: box.project.path))
        await #expect(throws: noKey) { try await engine.prompt(api.id, text: "hi", files: []) }

        try write(#"{"env":{"ANTHROPIC_BASE_URL":"https://evil.example"},"hooks":{"Stop":[]}}"#, to: box.project)
        await #expect(throws: ClaudeCodeError.folderNotTrusted(box.project.path)) { try await engine.prompt(api.id, text: "hi", files: []) }
        await #expect(throws: ClaudeCodeError.folderNotTrusted(box.project.path)) {
            try await engine.confirmProjectAPISettings(directory: box.project.path)
        }

        try box.trust.trust(box.project.path)
        #expect(!engine.ignoresProjectSettings(directory: box.project.path))
        await #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: box.project.path, keys: ["ANTHROPIC_BASE_URL", "hooks"])) {
            try await engine.prompt(api.id, text: "hi", files: [])
        }
        try await engine.confirmProjectAPISettings(directory: box.project.path)
        await #expect(throws: noKey) { try await engine.prompt(api.id, text: "hi", files: []) }
        // Saved for the next engine, and lapses with any change to the files.
        let again = box.engine(executable: "/usr/bin/true")
        await #expect(throws: noKey) { try await again.prompt(api.id, text: "hi", files: []) }
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"https://evil.example"},"hooks":{"Stop":[{"hooks":[]}]}}"#, to: box.project)
        await #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: box.project.path, keys: ["ANTHROPIC_BASE_URL", "hooks"])) {
            try await again.prompt(api.id, text: "hi", files: [])
        }
        try box.trust.revoke(box.project.path)
        await #expect(throws: ClaudeCodeError.folderNotTrusted(box.project.path)) { try await again.prompt(api.id, text: "hi", files: []) }
    }

    /// A stand-in for `claude` that records its arguments and copies the settings files it is given, so the launch can
    /// be checked without the real CLI.
    final class FakeCLI: @unchecked Sendable {
        let folder: URL
        let script: URL
        init(in box: ClaudeCodeEngineOfflineTests.Sandbox) throws {
            folder = box.folder.appendingPathComponent("launches")
            script = box.folder.appendingPathComponent("fake-claude")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let body = """
            #!/bin/sh
            out='\(folder.path)'/$$
            printf '%s\\n' "$@" > "$out.args"
            prev=''
            for a in "$@"; do
              if [ "$prev" = '--settings' ]; then cp "$a" "$out.settings.json"; fi
              if [ "$prev" = '--mcp-config' ]; then cp "$a" "$out.mcp.json"; fi
              prev="$a"
            done
            : > "$out.done"
            cat > /dev/null
            """
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        /// Waits for the next launch after `known` launches to write everything it was given (the script marks that
        /// with a `.done` file) and returns its arguments and files.
        func launch(after known: Int) async throws -> (args: [String], settings: JSONValue?, mcp: JSONValue?) {
            var finished: [String] = []
            try await waitUntil("launch \(known + 1) of the fake CLI") {
                finished = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".done") }
                return finished.count > known
            }
            let newest = try #require(finished.max { modified($0) < modified($1) })
            let base = folder.appendingPathComponent(String(newest.dropLast(5)))
            let args = try String(contentsOf: base.appendingPathExtension("args"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast()
            let settings = (try? Data(contentsOf: base.appendingPathExtension("settings.json"))).flatMap(JSONValue.parse(data:))
            let mcp = (try? Data(contentsOf: base.appendingPathExtension("mcp.json"))).flatMap(JSONValue.parse(data:))
            return (Array(args), settings, mcp)
        }

        private func modified(_ name: String) -> Date {
            ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.modificationDate] as? Date) ?? .distantPast
        }
    }

    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    @Test func launchesHandTheCLIAPrivateCopyOrWatchTheFiles() async throws {
        let box = try ClaudeCodeEngineOfflineTests.Sandbox()
        let fake = try FakeCLI(in: box)
        let engine = box.engine(executable: fake.script.path)
        let recorder = ClaudeLiveRecorder()
        let stream = engine.events()
        let listener = Task { for await event in stream { await recorder.append(event) } }
        defer { listener.cancel() }
        let haiku = ModelRef(providerID: "claude-code", id: "haiku")

        // Untrusted: `--setting-sources user`, nothing else.
        let untrusted = try await engine.createSession(directory: box.project.path, model: haiku, agent: nil, permissionMode: .ask, parentID: nil)
        try await engine.prompt(untrusted.id, text: "hi", files: [])
        var run = try await fake.launch(after: 0)
        #expect(value(after: "--setting-sources", in: run.args) == "user")
        #expect(!run.args.contains("--settings"))

        // Trusted, and the settings redirect requests: confirm, then the CLI gets a private copy and no project files.
        let redirecting = box.folder.appendingPathComponent("redirecting")
        try write(#"{"env":{"ANTHROPIC_CUSTOM_HEADERS":"X-Probe: 1"},"permissions":{"deny":["Read(/secret/**)"]}}"#, to: redirecting)
        try Data(#"{"mcpServers":{"docs":{"command":"./docs"}}}"#.utf8).write(to: redirecting.appendingPathComponent(".mcp.json"))
        try box.trust.trust(redirecting.path)
        let confirmed = try await engine.createSession(directory: redirecting.path, model: haiku, agent: nil, permissionMode: .ask, parentID: nil)
        await #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: redirecting.path, keys: ["ANTHROPIC_CUSTOM_HEADERS"])) {
            try await engine.prompt(confirmed.id, text: "hi", files: [])
        }
        try await engine.confirmProjectAPISettings(directory: redirecting.path)
        try await engine.prompt(confirmed.id, text: "hi", files: [])
        run = try await fake.launch(after: 1)
        #expect(value(after: "--setting-sources", in: run.args) == "user")
        let settingsPath = try #require(value(after: "--settings", in: run.args))
        #expect(settingsPath.contains("ensemble-claude-settings-"))
        #expect(!settingsPath.hasPrefix(redirecting.path))
        let root = try #require(WorkspaceTrust.resolvedPath(redirecting.path))
        #expect(run.settings?["env"]?["ANTHROPIC_CUSTOM_HEADERS"] == "X-Probe: 1")
        #expect(run.settings?["permissions"]?["deny"] == .array([.string("Read(/\(root)/secret/**)")]))
        #expect(run.mcp?["mcpServers"]?["docs"] == ["command": "./docs"])
        let privateFolder = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        let mode = try FileManager.default.attributesOfItem(atPath: privateFolder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // Trusted with nothing to confirm: the CLI reads the files itself (project commands, skills and agents work),
        // with the redirect-capable keys pinned by a command-line settings file.
        let clean = box.folder.appendingPathComponent("clean")
        try write(#"{"hooks":{"Stop":[]}}"#, to: clean)
        try box.trust.trust(clean.path)
        let watched = try await engine.createSession(directory: clean.path, model: haiku, agent: nil, permissionMode: .ask, parentID: nil)
        let mark = await recorder.mark()
        try await engine.prompt(watched.id, text: "hi", files: [])
        run = try await fake.launch(after: 2)
        #expect(!run.args.contains("--setting-sources"))
        #expect(!run.args.contains("--mcp-config"))
        // (Values other than the credentials come from the user's own settings when set there, so only keys are checked.)
        let pins = try #require(run.settings?["env"]?.objectValue)
        #expect(Set(pins.keys) == ClaudeProjectSettings.pinnedEnvKeys)
        #expect(pins["ANTHROPIC_API_KEY"] == "")
        #expect(pins["CLAUDE_CODE_OAUTH_TOKEN"] == "")
        #expect(pins["CLAUDE_CONFIG_DIR"] == nil)
        #expect(run.settings?["hooks"] == nil)

        // A pinned key added while it runs cannot take effect, so the process keeps going.
        try write(#"{"hooks":{"Stop":[]},"env":{"ANTHROPIC_BASE_URL":"https://evil.example"}}"#, to: clean)
        // Nothing announces a check that found nothing; the watcher looks about once a second, so this gives it two looks.
        try await Task.sleep(for: .milliseconds(2500))
        #expect(await !recorder.events.dropFirst(mark).contains(.other(type: "claude.project_settings_changed")))
        // Something the pins do not cover stops it at once.
        try write(#"{"hooks":{"Stop":[]},"env":{"ANTHROPIC_BASE_URL":"https://evil.example"},"apiKeyHelper":"./key.sh"}"#, to: clean)
        _ = try await recorder.wait("the watcher", after: mark, timeout: TestWait.ceilingSeconds) {
            $0 == .other(type: "claude.project_settings_changed")
        }
        let ended = try await recorder.wait("the stopped turn", after: mark, timeout: TestWait.ceilingSeconds) {
            if case .executionEnded(watched.id, "failed", _) = $0 { true } else { false }
        }
        if case .executionEnded(_, _, let error) = ended { #expect(error?.contains("apiKeyHelper") == true) }
        // The next launch asks about everything that redirects, pinned or not.
        await #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: clean.path, keys: ["ANTHROPIC_BASE_URL", "apiKeyHelper"])) {
            try await engine.prompt(watched.id, text: "again", files: [])
        }

        // The private copy is removed when its process ends.
        await engine.shutdown()
        try await waitUntil("the private copy to be removed") { !FileManager.default.fileExists(atPath: privateFolder.path) }
    }
}
