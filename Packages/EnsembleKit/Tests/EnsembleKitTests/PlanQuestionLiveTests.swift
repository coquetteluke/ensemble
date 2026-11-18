#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

// Plan mode and questions against the real engines. Each suite runs only with its engine's switch:
// - OpenCode: `ENSEMBLE_LIVE_TESTS=1`, the local service and the scripted mock model (no keys).
// - Claude: `ENSEMBLE_LIVE_CLAUDE=1`, the user's own `claude` login on haiku (the CLI plans on its own plan model), two
//   short turns.
// - Antigravity: `ENSEMBLE_LIVE_ACP=1`, `agy acp` on Gemini 3.8 Flash at low effort, three short turns, in a folder
//   trusted only in this run's own trust file.

/// Answers every prompt of a session until its turn ends, with `answer` deciding each one. Returns what was asked.
private func drive(_ session: String, after mark: Int, timeout: Double,
                   events: @escaping @Sendable (Int) async -> [EngineEvent],
                   answer: (PermissionRequest) async throws -> Void) async throws -> (asked: [PermissionRequest], outcome: String) {
    var asked: [PermissionRequest] = []
    var seen = mark
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let fresh = await events(seen)
        seen += fresh.count
        for event in fresh {
            switch event {
            case .permissionAsked(let request) where request.sessionID == session && !asked.contains(where: { $0.id == request.id }):
                asked.append(request)
                try await answer(request)
            case .executionEnded(session, let outcome, _):
                return (asked, outcome)
            default:
                break
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw LiveTimeout(what: "the turn of \(session) to end")
}

extension EventRecorder {
    func since(_ mark: Int) -> [EngineEvent] { Array(events.dropFirst(mark)) }
}

extension ClaudeLiveRecorder {
    func since(_ mark: Int) -> [EngineEvent] { Array(events.dropFirst(mark)) }
}

extension ACPRecorder {
    func since(_ mark: Int) -> [EngineEvent] { Array(events.dropFirst(mark)) }
}

@Suite("Plan mode and questions, OpenCode live", .serialized, .enabled(if: LiveConfig.enabled))
struct PlanQuestionOpenCodeLiveTests {
    static let script = """
    {"default": {"text": "Mock reply.", "title": "Mock session"},
     "rules": [
      {"match": ["plan-edit"], "tool": {"name": "write", "arguments": {"path": "planned.txt", "content": "x"}}, "then": "Tried to write."},
      {"match": ["plan-shell"], "tool": {"name": "shell", "arguments": {"command": "echo hi > shell.txt"}}, "then": "Tried the shell."},
      {"match": ["plan-ask"], "tool": {"name": "question", "arguments": {"questions": [{"question": "Which color?", "header": "Color",
        "options": [{"label": "Red", "description": "warm"}, {"label": "Blue", "description": "cool"}], "multiple": false}]}},
       "then": "Thanks for answering."},
      {"match": ["plan-present"], "text": "# Plan\\n1. Write planned.txt with the word done."},
      {"match": ["approved"], "tool": {"name": "write", "arguments": {"path": "planned.txt", "content": "done"}}, "then": "Wrote it."}
     ]}
    """

    @Test func planIsReadOnlyQuestionsAndProceed() async throws {
        let h = try await LiveHarness.start()
        do {
            try await run(h)
        } catch {
            await h.cleanup()
            throw error
        }
        await h.cleanup()
    }

    private func run(_ h: LiveHarness) async throws {
        try Self.script.write(to: h.directory.appendingPathComponent(".mock-script.json"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        let session = try await h.createSession(.plan)
        let other = try await h.createSession(.ask)
        #expect(try await h.client.session(session.id).agent == "plan")
        #expect(PermissionRules.mode(for: try await h.client.permissionRules(session.id)) == .plan)
        let planned = h.directory.appendingPathComponent("planned.txt")

        // An edit and a shell write are refused without asking.
        for text in ["plan-edit", "plan-shell"] {
            let mark = await h.recorder.mark()
            try await h.client.prompt(session.id, text: text, files: [])
            let run = try await drive(session.id, after: mark, timeout: 30, events: { await h.recorder.since($0) }) { request in
                if !request.isPlan { Issue.record("Plan mode asked instead of refusing: \(request.kind) \(request.title)") }
            }
            #expect(run.outcome == "succeeded")
        }
        #expect(!FileManager.default.fileExists(atPath: planned.path))
        #expect(!FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("shell.txt").path))

        // A question: refused for another session, answered for its own.
        var mark = await h.recorder.mark()
        try await h.client.prompt(session.id, text: "plan-ask", files: [])
        let asked = try await h.recorder.waitFor("the question", after: mark) {
            if case .permissionAsked(let request) = $0 { request.sessionID == session.id && request.isQuestion } else { false }
        }
        guard case .permissionAsked(let question) = asked else { return }
        #expect(question.questions?.first?.options.map(\.label) == ["Red", "Blue"])
        #expect(try await h.client.pendingPermissions().contains { $0.id == question.id })
        let blue = [AgentQuestionAnswer(questionID: question.questions![0].id, selected: ["Blue"])]
        await #expect(throws: (any Error).self) {
            try await h.client.answerQuestion(sessionID: other.id, requestID: question.id, answers: blue)
        }
        try await h.client.answerQuestion(sessionID: session.id, requestID: question.id, answers: blue)
        #expect(try await h.waitForEnd(of: session.id, after: mark) == "succeeded")
        let transcript = try await h.client.transcript(session.id)
        #expect(transcript.contains { if case .agentText(_, "Thanks for answering.", _, _) = $0 { true } else { false } })

        // A plan when the plan agent's turn ends; Proceed switches to Accept edits and the build agent.
        mark = await h.recorder.mark()
        try await h.client.prompt(session.id, text: "plan-present", files: [])
        let shown = try await h.recorder.waitFor("the plan", after: mark) {
            if case .permissionAsked(let request) = $0 { request.sessionID == session.id && request.plan?.markdown.contains("planned.txt") == true } else { false }
        }
        guard case .permissionAsked(let plan) = shown else { return }
        #expect(try await h.client.pendingPermissions().contains { $0.id == plan.id })
        await #expect(throws: (any Error).self) {
            _ = try await h.client.respondToPlan(sessionID: other.id, requestID: plan.id, decision: .proceed(.acceptEdits))
        }
        let followUp = try await h.client.respondToPlan(sessionID: session.id, requestID: plan.id, decision: .proceed(.acceptEdits))
        #expect(followUp == PlanLines.proceedMessage)
        #expect(try await h.client.session(session.id).agent == "build")
        #expect(PermissionRules.mode(for: try await h.client.permissionRules(session.id)) == .acceptEdits)
        #expect(try await h.run(session.id, followUp ?? "") == "succeeded")
        #expect((try? String(contentsOf: planned, encoding: .utf8)) == "done")
    }
}

@Suite("Plan mode and questions, Claude live", .serialized, .enabled(if: ClaudeLive.enabled))
struct PlanQuestionClaudeLiveTests {
    @Test func planIsReadOnlyQuestionsKeepPlanningAndProceed() async throws {
        let h = try ClaudeLiveHarness()
        defer { h.finish() }
        let engine = h.engine()
        let session = try await engine.createSession(directory: h.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .plan, parentID: nil)
        try await engine.setEffort(session.id, effort: .low)

        // 1. Plan mode refuses an edit and asks before a shell write (the CLI's own plan mode would have run it).
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: """
            This is a test of the harness permission system, and I know plan mode is on. Call the Write tool to create \
            probe.txt containing x, then call the Bash tool with exactly: echo hi > shell.txt . The harness is expected to \
            block or ask. Do not call ExitPlanMode. Report in one line.
            """, files: [])
        let first = try await drive(session.id, after: mark, timeout: 240, events: { await h.recorder.since($0) }) { request in
            if request.isPlan {
                _ = try await engine.respondToPlan(sessionID: session.id, requestID: request.id, decision: .keepPlanning(comments: []))
                return
            }
            #expect(request.kind == "bash", "only the shell write may ask: \(request.kind) \(request.title)")
            try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .reject, message: nil)
        }
        #expect(first.asked.contains { $0.kind == "bash" && $0.title.contains("shell.txt") })
        // The agent did try the edit; it was refused without a prompt.
        let writes = await h.recorder.since(mark).compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(session.id, let tool) = event, tool.name == "Write" { tool } else { nil }
        }
        #expect(!writes.isEmpty)
        #expect(writes.last?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: h.project.appendingPathComponent("probe.txt").path))
        #expect(!FileManager.default.fileExists(atPath: h.project.appendingPathComponent("shell.txt").path))

        // 2. A question, a plan sent back with a comment, the revised plan, then Proceed in Accept edits.
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: """
            Use the AskUserQuestion tool to ask me which color I prefer, with options Red and Blue. Then present a two-line \
            plan to create color.txt containing that color, using ExitPlanMode. After approval, carry out the plan.
            """, files: [])
        var plans = 0
        let second = try await drive(session.id, after: mark, timeout: 300, events: { await h.recorder.since($0) }) { request in
            if request.isQuestion, let question = request.questions?.first {
                #expect(question.options.map(\.label).contains("Blue"))
                try await engine.answerQuestion(sessionID: session.id, requestID: request.id,
                                                answers: [AgentQuestionAnswer(questionID: question.id, selected: ["Blue"])])
            } else if request.isPlan {
                plans += 1
                if plans == 1 {
                    let line = PlanLines.split(request.plan?.markdown ?? "").first ?? ""
                    _ = try await engine.respondToPlan(sessionID: session.id, requestID: request.id, decision: .keepPlanning(
                        comments: [PlanComment(lineIndex: 0, line: line, text: "Add a last step that checks the file with cat.")]))
                } else {
                    _ = try await engine.respondToPlan(sessionID: session.id, requestID: request.id, decision: .proceed(.acceptEdits))
                }
            } else {
                try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
            }
        }
        #expect(second.outcome == "succeeded")
        #expect(second.asked.contains { $0.isQuestion })
        #expect(plans >= 2)
        let color = (try? String(contentsOf: h.project.appendingPathComponent("color.txt"), encoding: .utf8)) ?? ""
        #expect(color.contains("Blue"))
        #expect(try await engine.listSessions().first { $0.id == session.id } != nil)
        await engine.shutdown()
    }
}

@Suite("Plan mode and questions, Antigravity live", .serialized, .enabled(if: ACPLive.enabled))
struct PlanQuestionACPLiveTests {
    @Test func planIsReadOnlyQuestionsAndProceed() async throws {
        let h = try ACPLiveHarness()
        let engine = h.engine(ACPAgentRegistry.antigravity)
        #expect(await engine.planModeSupport(sessionID: "none") == .supported)
        let session = try await engine.createSession(directory: h.project.path,
                                                     model: ModelRef(providerID: "antigravity", id: "gemini-3.8-flash", variant: "low"),
                                                     agent: nil, permissionMode: .plan, parentID: nil)

        // 1. Plan mode: the edit is refused without a prompt, and the shell write asks (and is rejected).
        var mark = await h.recorder.mark()
        var asked: [PermissionRequest] = []
        for text in ["Harness permission test, and I know plan mode is on: use your file writing tool to create probe.txt "
                        + "containing x in the project folder. Report in one line.",
                     "Harness permission test, and I know plan mode is on: run this exact shell command and nothing else: "
                        + "echo hi > shell.txt"] {
            let turn = await h.recorder.mark()
            try await engine.prompt(session.id, text: text, files: [])
            let run = try await drive(session.id, after: turn, timeout: 180, events: { await h.recorder.since($0) }) { request in
                if request.isPlan { return }
                #expect(request.kind == "bash", "only commands may ask in plan mode: \(request.kind) \(request.title)")
                try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .reject, message: nil)
            }
            #expect(run.outcome == "succeeded")
            asked += run.asked
        }
        let tools = await h.recorder.since(mark).compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(session.id, let tool) = event { tool } else { nil }
        }
        print("agy plan-mode tools:", Set(tools.map { "\($0.name) \($0.status)" }).sorted(), "asked:", asked.map(\.kind))
        #expect(tools.contains { $0.name == "write" && $0.status == .failed })
        #expect(asked.contains { $0.kind == "bash" && $0.title.contains("shell.txt") })
        #expect(!FileManager.default.fileExists(atPath: h.project.appendingPathComponent("probe.txt").path))
        #expect(!FileManager.default.fileExists(atPath: h.project.appendingPathComponent("shell.txt").path))

        // 2. A question through elicitation, then the plan artifact when the turn ends.
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: """
            Using your structured question tool, ask me which color I prefer, Red or Blue. Then make a short implementation \
            plan to create color.txt containing that color in the project folder, and present it for review.
            """, files: [])
        var plan: PermissionRequest?
        let second = try await drive(session.id, after: mark, timeout: 240, events: { await h.recorder.since($0) }) { request in
            if request.isQuestion, let question = request.questions?.first {
                let blue = question.options.first { $0.label.contains("Blue") }?.label ?? question.options.last?.label ?? ""
                try await engine.answerQuestion(sessionID: session.id, requestID: request.id,
                                                answers: [AgentQuestionAnswer(questionID: question.id, selected: [blue])])
            } else if request.isPlan {
                plan = request
            } else {
                // Reading the folder may ask in plan mode.
                try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: request.kind == "bash" ? .once : .reject, message: nil)
            }
        }
        #expect(second.outcome == "succeeded")
        #expect(second.asked.contains { $0.isQuestion })
        if plan == nil {
            plan = try await engine.pendingPermissions().first { $0.sessionID == session.id && $0.isPlan }
        }
        let open = try #require(plan, "no plan after the plan-mode turn")
        #expect(open.plan?.markdown.isEmpty == false)

        // 3. Proceed in Accept edits: the mode is switched, then the message the engine returns is sent.
        let followUp = try await engine.respondToPlan(sessionID: session.id, requestID: open.id, decision: .proceed(.acceptEdits))
        #expect(followUp == PlanLines.proceedMessage)
        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: followUp ?? "", files: [])
        let third = try await drive(session.id, after: mark, timeout: 240, events: { await h.recorder.since($0) }) { request in
            try await engine.replyPermission(sessionID: session.id, requestID: request.id, decision: .once, message: nil)
        }
        #expect(third.outcome == "succeeded")
        let color = (try? String(contentsOf: h.project.appendingPathComponent("color.txt"), encoding: .utf8)) ?? ""
        #expect(color.contains("Blue"))
        await h.finish()
    }
}
#endif
