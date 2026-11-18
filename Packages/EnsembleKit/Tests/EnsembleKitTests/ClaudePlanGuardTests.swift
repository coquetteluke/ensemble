#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The Claude plan guard: which tools plan mode makes ask or refuses, and that a plan turn never runs unless the CLI
/// has accepted the guard.
@Suite("Claude plan guard")
struct ClaudePlanGuardTests {
    @Test func everyCommandFileAndOutsideToolAsks() {
        let asked = Set(ClaudePlanGuard.askedTools)
        #expect(ClaudeFormatting.shellToolNames.isSubset(of: asked))
        #expect(ClaudeFormatting.editToolNames.isSubset(of: asked))
        for tool in ["Bash", "PowerShell", "Monitor", "Write", "Edit", "MultiEdit", "NotebookEdit", "EnterWorktree", "ExitWorktree",
                     "CronCreate", "RemoteTrigger", "SendMessage", "Workflow", "mcp__*"] {
            #expect(asked.contains(tool), "\(tool) should ask in plan")
        }
        for tool in ["Read", "Grep", "Glob", "LSP", "WebSearch", "AskUserQuestion", "ExitPlanMode", "Task"] {
            #expect(!asked.contains(tool), "\(tool) is read-only")
        }
        let settings = ClaudePlanGuard.settings(planOn: true, base: ["ask": ["Bash"], "deny": ["WebFetch"]])
        let ask = settings["permissions"]?["ask"]?.arrayValue ?? []
        #expect(ask.filter { $0 == "Bash" }.count == 1)
        #expect(ask.count == ClaudePlanGuard.askedTools.count)
        #expect(settings["permissions"]?["deny"] == ["WebFetch"])
    }

    @Test func ensembleRefusesFileChangesAndAsksForTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-plans-\(UUID().uuidString.prefix(8))")
        let plans = folder.appendingPathComponent(".claude/plans")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func decide(_ tool: String, _ path: String? = nil) -> ClaudePlanGuard.Decision {
            ClaudePlanGuard.decision(toolName: tool, input: path.map { ["file_path": .string($0)] } ?? [:], plansFolder: plans.path)
        }
        #expect(decide("Write", "/tmp/project/a.swift") == .refuse)
        #expect(decide("Edit", "/tmp/project/a.swift") == .refuse)
        #expect(decide("MultiEdit", plans.appendingPathComponent("x.md").path) == .refuse)
        #expect(decide("NotebookEdit", "/tmp/project/a.ipynb") == .refuse)
        #expect(decide("EnterWorktree") == .refuse)
        #expect(decide("ExitWorktree") == .refuse)
        // The CLI's own plan file, and nothing that only looks like it.
        #expect(decide("Write", plans.appendingPathComponent("usage-ring.md").path) == .allowPlanFile)
        #expect(decide("Write", plans.appendingPathComponent("sub/x.md").path) == .refuse)
        #expect(decide("Write", plans.appendingPathComponent("../settings.md").path) == .refuse)
        #expect(decide("Write", plans.appendingPathComponent("x.sh").path) == .refuse)
        for tool in ["Bash", "PowerShell", "Monitor", "mcp__github__create_issue", "WebFetch", "Read", "CronCreate"] {
            #expect(decide(tool) == .ask, "\(tool) should wait for the user")
        }
        #expect(ClaudePlanGuard.plansFolder(environment: ["HOME": "/Users/me"]) == "/Users/me/.claude/plans")
        #expect(ClaudePlanGuard.plansFolder(environment: ["HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/cfg"]) == "/cfg/plans")
    }

    /// A stand-in for `claude` that speaks the control protocol: it logs every line it reads, answers control requests
    /// (refusing `apply_flag_settings` while `fail-guard` exists in its folder), and ends each user turn at once.
    final class ControlCLI: @unchecked Sendable {
        let folder: URL
        let script: URL
        var log: URL { folder.appendingPathComponent("stdin.log") }
        var failFlag: URL { folder.appendingPathComponent("fail-guard") }

        init(in box: ClaudeCodeEngineOfflineTests.Sandbox) throws {
            folder = box.folder.appendingPathComponent("control-cli")
            script = box.folder.appendingPathComponent("fake-claude-control")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let body = """
            #!/usr/bin/python3 -I
            import json, os, sys
            folder = \(String(reflecting: folder.path))
            log = open(os.path.join(folder, 'stdin.log'), 'a')
            def out(obj):
                sys.stdout.write(json.dumps(obj) + '\\n'); sys.stdout.flush()
            for line in sys.stdin:
                log.write(line); log.flush()
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                if m.get('type') == 'control_request':
                    rid = m.get('request_id'); sub = m.get('request', {}).get('subtype')
                    if sub == 'apply_flag_settings' and os.path.exists(os.path.join(folder, 'fail-guard')):
                        out({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': rid, 'error': 'refused by the test'}})
                    else:
                        out({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': rid, 'response': {}}})
                elif m.get('type') == 'user':
                    out({'type': 'result', 'subtype': 'success', 'is_error': False, 'num_turns': 1, 'result': 'ok', 'session_id': 's',
                         'usage': {'input_tokens': 1, 'output_tokens': 1}})
            """
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        /// Every JSON line the CLI has read so far.
        func lines() -> [JSONValue] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSONValue.parse(data: Data($0.utf8)) }
        }

        func requests(_ subtype: String) -> [JSONValue] {
            lines().filter { $0["type"]?.stringValue == "control_request" && $0["request"]?["subtype"]?.stringValue == subtype }
        }

        var userMessages: Int { lines().filter { $0["type"]?.stringValue == "user" }.count }

        /// Waits until the CLI has read `count` user messages (it logs them as it reads them).
        func waitForUserMessages(_ count: Int) async {
            for _ in 0..<100 where userMessages < count { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    func savedMode(_ box: ClaudeCodeEngineOfflineTests.Sandbox, _ id: String) throws -> String? {
        let json = try #require(JSONValue.parse(data: Data(contentsOf: box.store)))
        return json["sessions"]?.arrayValue?.first { $0["id"]?.stringValue == id }?["permissionMode"]?.stringValue
    }

    @Test func aRefusedGuardRunsNothing() async throws {
        let box = try ClaudeCodeEngineOfflineTests.Sandbox()
        let cli = try ControlCLI(in: box)
        let engine = box.engine(executable: cli.script.path)
        let recorder = ClaudeLiveRecorder()
        let stream = engine.events()
        let listener = Task { for await event in stream { await recorder.append(event) } }
        defer { listener.cancel() }
        let haiku = ModelRef(providerID: "claude-code", id: "haiku")

        // 1. Starting in plan: the guard is refused, so the message is never written and nothing runs.
        try Data().write(to: cli.failFlag)
        let plan = try await engine.createSession(directory: box.project.path, model: haiku, agent: nil, permissionMode: .plan, parentID: nil)
        do {
            try await engine.prompt(plan.id, text: "Make a plan", files: [])
            Issue.record("the turn was sent without the plan guard")
        } catch let error as ClaudeCodeError {
            guard case .planGuardFailed = error else { Issue.record("unexpected error \(error)"); return }
        }
        #expect(cli.requests("apply_flag_settings").count == 1)
        #expect(cli.userMessages == 0)
        #expect(await !recorder.events.contains(.activity(sessionID: plan.id, .working)))

        // Once the CLI accepts the guard, the turn goes out after it.
        try FileManager.default.removeItem(at: cli.failFlag)
        let mark = await recorder.mark()
        try await engine.prompt(plan.id, text: "Make a plan", files: [])
        _ = try await recorder.wait("the plan turn", after: mark, timeout: 20) { $0 == .executionEnded(sessionID: plan.id, outcome: "succeeded", error: nil) }
        #expect(cli.userMessages == 1)
        let order = cli.lines().map { $0["type"]?.stringValue == "user" ? "user" : ($0["request"]?["subtype"]?.stringValue ?? "") }
        let guardIndex = try #require(order.lastIndex(of: "apply_flag_settings"))
        #expect(guardIndex < (order.firstIndex(of: "user") ?? -1))
        let sent = cli.requests("apply_flag_settings").last?["request"]?["settings"]?["permissions"]?["ask"]?.arrayValue ?? []
        #expect(sent.contains("Bash") && sent.contains("mcp__*"))

        // 2. Switching a running session to plan: the guard is refused, so the CLI and the saved mode go back to Ask.
        let ask = try await engine.createSession(directory: box.project.path, model: haiku, agent: nil, permissionMode: .ask, parentID: nil)
        let askMark = await recorder.mark()
        try await engine.prompt(ask.id, text: "hello", files: [])
        _ = try await recorder.wait("the ask turn", after: askMark, timeout: 20) { $0 == .executionEnded(sessionID: ask.id, outcome: "succeeded", error: nil) }
        try Data().write(to: cli.failFlag)
        let modesBefore = cli.requests("set_permission_mode").count
        await #expect(throws: (any Error).self) { try await engine.setPermissionMode(ask.id, mode: .plan) }
        let modes = cli.requests("set_permission_mode").dropFirst(modesBefore).compactMap { $0["request"]?["mode"]?.stringValue }
        #expect(modes == ["plan", "default"])
        #expect(try savedMode(box, ask.id) == "ask")
        // It keeps working in Ask, without the guard.
        let sentBefore = cli.userMessages
        try await engine.prompt(ask.id, text: "again", files: [])
        await cli.waitForUserMessages(sentBefore + 1)
        #expect(cli.userMessages == sentBefore + 1)
        await engine.shutdown()
    }
}
#endif
