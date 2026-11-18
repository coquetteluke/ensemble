import Foundation
import Testing
@testable import EnsembleKit

/// Recorded `claude -p` stream-json runs (claude 2.1.319, haiku, anonymised). See Fixtures/claude-code/README.md.
enum ClaudeFixtures {
    static let root = "00000000-0000-4000-8000-000000000001"
    static let directory = "/tmp/ensemble-claude/proj"

    static func lines(_ name: String) throws -> [String] {
        try Fixtures.text("claude-code/\(name)").split(separator: "\n").map(String.init)
    }

    static func decode(_ name: String, prepare: (inout ClaudeStreamDecoder, String) -> Void = { _, _ in })
        throws -> (outputs: [ClaudeStreamDecoder.Output], decoder: ClaudeStreamDecoder) {
        var decoder = ClaudeStreamDecoder(rootID: root, directory: directory)
        var outputs: [ClaudeStreamDecoder.Output] = []
        for line in try lines(name) {
            prepare(&decoder, line)
            outputs += decoder.decode(line: line)
        }
        return (outputs, decoder)
    }

    static func events(_ outputs: [ClaudeStreamDecoder.Output]) -> [EngineEvent] {
        outputs.compactMap { if case .event(let event) = $0 { event } else { nil } }
    }

    static func transcript(_ name: String) throws -> ClaudeTranscriptData {
        ClaudeTranscriptFiles.parse(try Fixtures.data("claude-code/\(name)"))
    }
}

@Suite("Claude Code stream decoding")
struct ClaudeCodeDecoderTests {
    typealias F = ClaudeFixtures

    @Test func plainReplyStreamsTextAndEndsTurns() throws {
        let (outputs, decoder) = try F.decode("stream-plain.jsonl")
        let events = F.events(outputs)
        let deltas = events.compactMap { event -> String? in
            if case .textDelta(F.root, "msg_011Ch9jSiHsxNu3XpaEPAs3E:0", let delta) = event { delta } else { nil }
        }
        #expect(deltas.joined() == "hello there")
        let ended = events.compactMap { event -> String? in
            if case .textEnded(F.root, _, let text) = event { text } else { nil }
        }
        #expect(ended == ["hello there", "bye"])
        let outcomes = events.compactMap { event -> String? in
            if case .executionEnded(F.root, let outcome, nil) = event { outcome } else { nil }
        }
        #expect(outcomes == ["succeeded", "succeeded"])
        // Usage is cumulative over the session, summed from each turn's model_usage_since_last_result.
        #expect(abs(decoder.usage.costUSD - 0.01048777) < 1e-9)
        #expect(decoder.usage.inputTokens == 4)
        #expect(decoder.usage.cacheReadTokens > 0)
        #expect(decoder.contextWindows["claude-haiku-5-5"] == 1_000_000)
        #expect(decoder.lastContextTokens ?? 0 > 30_000)
        let inits = outputs.compactMap { if case .initialized(let info) = $0 { info } else { nil } }
        #expect(inits.count == 2)
        #expect(inits.first?.model == "claude-haiku-5-5")
        #expect(inits.first?.permissionMode == "default")
        #expect(inits.first?.connectors.first?.state == .connected)
        let limits = outputs.compactMap { if case .rateLimit(let limits) = $0 { limits } else { nil } }
        #expect(limits.first?.status == "allowed_warning")
        #expect(limits.first?.windows.first?.name == "seven_day")
        #expect(limits.first?.resetsAt != nil)
        #expect(events.contains(.activity(sessionID: F.root, .idle)))
    }

    @Test func thinkingStreamsOnceAndKeepsTheBlockIndex() throws {
        let (outputs, _) = try F.decode("stream-thinking.jsonl")
        let events = F.events(outputs)
        let reasoning = events.compactMap { event -> (String, String)? in
            if case .reasoningDelta(_, let id, let delta) = event { (id, delta) } else { nil }
        }
        #expect(!reasoning.isEmpty)
        #expect(Set(reasoning.map(\.0)) == ["msg_011Ch9kFzG7kBjUh83SezUb8:0"])
        // One event per streamed delta: the full thinking block in the assistant message is not sent again.
        let streamed = try F.lines("stream-thinking.jsonl").filter { line in
            guard let json = JSONValue.parse(line: line), let delta = json["event"]?["delta"] else { return false }
            return delta["type"]?.stringValue == "thinking_delta" && !(delta["thinking"]?.stringValue ?? "").isEmpty
        }
        #expect(reasoning.count == streamed.count)
        #expect(events.contains(.textEnded(sessionID: F.root, itemID: "msg_011Ch9kFzG7kBjUh83SezUb8:1", text: "391")))
    }

    @Test func readAndEditWithAnAllowedPrompt() throws {
        let (outputs, decoder) = try F.decode("stream-edit-allowed.jsonl")
        let events = F.events(outputs)
        let read = events.compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(F.root, let info) = event, info.name == "Read" { info } else { nil }
        }
        #expect(read.map(\.status) == [.pending, .running, .succeeded])
        #expect(read.last?.title == "notes.txt")
        #expect(read.last?.outputPreview?.contains("alpha") == true)

        let prompts = outputs.compactMap { if case .permission(let prompt) = $0 { prompt } else { nil } }
        #expect(prompts.count == 1)
        let prompt = try #require(prompts.first)
        #expect(prompt.toolName == "Edit")
        #expect(prompt.request.kind == "edit")
        #expect(prompt.request.title == "notes.txt")
        #expect(prompt.request.sessionID == F.root)
        #expect(prompt.request.detail?.contains("-alpha\n+beta") == true)
        #expect(prompt.suggestions.first?["type"]?.stringValue == "setMode")

        let edit = events.compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(F.root, let info) = event, info.name == "Edit" { info } else { nil }
        }
        #expect(edit.last?.status == .succeeded)
        let diff = try #require(edit.last?.diff)
        #expect(diff.hasPrefix("--- a/notes.txt\n+++ b/notes.txt\n@@ -1,2 +1,2 @@"))
        #expect(diff.contains("-alpha\n+beta\n second line"))
        #expect(decoder.openToolIDs.isEmpty)
        #expect(events.contains(.textEnded(sessionID: F.root, itemID: "msg_011Ch9jd8SxT7RjJThXGhzbE:0", text: "done")))
    }

    @Test func rejectedEditFailsTheToolCard() throws {
        let (outputs, _) = try F.decode("stream-edit-rejected.jsonl")
        #expect(outputs.contains { if case .permission = $0 { true } else { false } })
        let edit = F.events(outputs).compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(_, let info) = event, info.name == "Edit" { info } else { nil }
        }
        #expect(edit.last?.status == .failed)
        #expect(edit.last?.outputPreview == "The user rejected this action.")
        #expect(edit.last?.diff == nil)
    }

    @Test func subagentBecomesAChildSession() throws {
        let (outputs, decoder) = try F.decode("stream-subagent.jsonl")
        let events = F.events(outputs)
        let toolID = "toolu_01WJd3ydmJdPAFjh93jKrT5Y"
        let child = ClaudeSessionIDs.child(root: F.root, toolUseID: toolID)
        #expect(child == "\(F.root).\(toolID)")
        #expect(ClaudeSessionIDs.root(of: child) == F.root)
        #expect(ClaudeSessionIDs.toolUseID(of: child) == toolID)

        let created = events.compactMap { if case .sessionCreated(let session) = $0 { session } else { nil } }
        #expect(created.count == 1)
        #expect(created.first?.id == child)
        #expect(created.first?.parentID == F.root)
        #expect(created.first?.title == "Read notes.txt first word")
        #expect(created.first?.agent == "general-purpose")
        #expect(decoder.children[child] != nil)

        let agentCards = events.compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(F.root, let info) = event, info.name == "Agent" { info } else { nil }
        }
        #expect(agentCards.allSatisfy { $0.childSessionID == child })
        #expect(agentCards.last?.status == .succeeded)
        #expect(agentCards.last?.title == "Read notes.txt first word")

        // The subagent's own tool call, thinking and text go to the child session.
        #expect(events.contains { if case .toolUpdated(child, let info) = $0 { info.name == "Read" && info.status == .succeeded } else { false } })
        #expect(events.contains { if case .reasoningDelta(child, _, _) = $0 { true } else { false } })
        #expect(events.contains { if case .textEnded(child, _, "alpha") = $0 { true } else { false } })
        #expect(events.contains(.activity(sessionID: child, .working)))
        #expect(events.contains(.executionEnded(sessionID: child, outcome: "succeeded", error: nil)))
        #expect(events.contains(.executionEnded(sessionID: F.root, outcome: "succeeded", error: nil)))
    }

    @Test func interruptedTurnEndsAsInterrupted() throws {
        var requested = false
        let (outputs, _) = try F.decode("stream-interrupt.jsonl") { decoder, line in
            if !requested, line.contains("\"text_delta\"") {
                decoder.interruptRequested = true
                requested = true
            }
        }
        let events = F.events(outputs)
        let outcomes = events.compactMap { event -> String? in
            if case .executionEnded(F.root, let outcome, _) = event { outcome } else { nil }
        }
        #expect(outcomes == ["interrupted", "succeeded"])
        #expect(!events.contains { if case .executionEnded(_, "interrupted", let error) = $0 { error != nil } else { false } })
        // The interrupt control request's answer is passed on for the waiting caller.
        #expect(outputs.contains { if case .controlResponse(_, true, _) = $0 { true } else { false } })
        let summaries = outputs.compactMap { if case .turnEnded(let summary) = $0 { summary } else { nil } }
        #expect(summaries.first?.terminalReason == "aborted_streaming")
    }

    @Test func interruptIsRecognisedWithoutTheFlag() throws {
        let (outputs, _) = try F.decode("stream-interrupt.jsonl")
        #expect(F.events(outputs).contains(.executionEnded(sessionID: F.root, outcome: "interrupted", error: nil)))
    }

    @Test func controlLinesAndErrors() {
        var decoder = ClaudeStreamDecoder(rootID: "s", directory: "/p")
        let error = decoder.decode(line: #"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"nope"}}"#)
        #expect(error == [.controlResponse(requestID: "r1", success: false, payload: "nope")])
        let cancel = decoder.decode(line: #"{"type":"control_cancel_request","request_id":"r2"}"#)
        #expect(cancel == [.controlCancel(requestID: "r2")])
        let other = decoder.decode(line: #"{"type":"control_request","request_id":"r3","request":{"subtype":"hook_callback"}}"#)
        #expect(other == [.unsupportedControl(requestID: "r3", subtype: "hook_callback")])
        #expect(decoder.decode(line: "not json").isEmpty)
        #expect(decoder.decode(line: #"{"type":"keep_alive"}"#).isEmpty)
        let failed = decoder.decode(line: #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","model_usage_since_last_result":{}}"#)
        let ended = failed.compactMap { if case .event(.executionEnded(_, let outcome, let message)) = $0 { (outcome, message) } else { nil } }
        #expect(ended.first?.0 == "failed")
        #expect(ended.first?.1?.contains("claude auth login") == true)
    }
}

@Suite("Claude Code plan usage")
struct ClaudeCodePlanUsageTests {
    @Test func planAgentsReportTokensNotDollars() throws {
        let (_, api) = try ClaudeFixtures.decode("stream-plain.jsonl")
        let (outputs, plan) = try ClaudeFixtures.decode("stream-plain.jsonl") { decoder, _ in decoder.reportsCost = false }
        #expect(api.usage.costUSD > 0)
        #expect(plan.usage.costUSD == 0)
        #expect(plan.usage.inputTokens == api.usage.inputTokens)
        #expect(plan.usage.outputTokens == api.usage.outputTokens)
        let updates = ClaudeFixtures.events(outputs).compactMap { if case .usageUpdated(_, let usage) = $0 { usage } else { nil } }
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { $0.costUSD == 0 })
    }
}

@Suite("Claude Code permissions")
struct ClaudeCodePermissionTests {
    func prompt(tool: String, input: JSONValue, suggestions: [JSONValue] = [], extra: [String: JSONValue] = [:],
                directory: String = "/p") -> ClaudePermissionPrompt {
        var body: [String: JSONValue] = ["tool_name": .string(tool), "input": input, "permission_suggestions": .array(suggestions)]
        body.merge(extra) { _, new in new }
        return ClaudePermissionPrompt(requestID: "req", sessionID: "s", body: .object(body), directory: directory)
    }

    func rules(_ list: [ClaudePermissionRules.Rule]) -> ClaudePermissionRules {
        var rules = ClaudePermissionRules()
        rules.add(list)
        return rules
    }

    func bash(_ rules: ClaudePermissionRules, _ command: String) -> Bool {
        rules.matches(toolName: "Bash", input: .object(["command": .string(command)]), directory: "/p")
    }

    /// The recorded prompts, keyed by tool input command or path.
    func recorded() throws -> [ClaudePermissionPrompt] {
        try ClaudeFixtures.lines("control-permission-prompts.jsonl").compactMap { line in
            guard let json = JSONValue.parse(line: line), let id = json["request_id"]?.stringValue, let body = json["request"] else { return nil }
            return ClaudePermissionPrompt(requestID: id, sessionID: "s", body: body, directory: ClaudeFixtures.directory)
        }
    }

    @Test func responsesMatchTheControlProtocol() {
        let bash = prompt(tool: "Bash", input: ["command": "npm test"],
                          suggestions: [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]],
                                         "behavior": "allow", "destination": "localSettings"],
                                        ["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
        #expect(bash.request.kind == "bash")
        #expect(bash.request.title == "npm test")
        let once = bash.response(decision: .once, message: nil)
        #expect(once["type"]?.stringValue == "control_response")
        #expect(once["response"]?["request_id"]?.stringValue == "req")
        #expect(once["response"]?["response"]?["behavior"]?.stringValue == "allow")
        #expect(once["response"]?["response"]?["updatedInput"]?["command"]?.stringValue == "npm test")
        #expect(once["response"]?["response"]?["updatedPermissions"] == nil)

        // "Always" is remembered by Ensemble only: no rules or mode switch are handed to the CLI.
        let always = bash.response(decision: .always, message: nil)
        #expect(always["response"]?["response"]?["behavior"]?.stringValue == "allow")
        #expect(always["response"]?["response"]?["updatedPermissions"] == nil)
        #expect(bash.alwaysRules == [.init(tool: "Bash", content: "npm test"), .init(tool: "Bash", content: "npm test:*")])

        let reject = bash.response(decision: .reject, message: nil)
        #expect(reject["response"]?["response"]?["behavior"]?.stringValue == "deny")
        #expect(reject["response"]?["response"]?["message"]?.stringValue == "The user rejected this action.")
        #expect(bash.response(decision: .reject, message: "Use pnpm")["response"]?["response"]?["message"]?.stringValue == "Use pnpm")
    }

    @Test func outsideTheProjectIsAnExternalDirectoryPrompt() {
        let read = prompt(tool: "Read", input: ["file_path": "/etc/hosts"], extra: ["blocked_path": "/etc/hosts"])
        #expect(read.isExternal)
        #expect(read.request.kind == "external_directory")
        #expect(read.request.title == "/etc/hosts")
    }

    @Test func recordedPromptsAreClassifiedAndScoped() throws {
        let prompts = try recorded()
        #expect(prompts.count == 3)

        // `touch made.txt`: the blocked path is inside the project, so it is a command prompt, not an outside one.
        let touch = prompts[0]
        #expect(!touch.isExternal)
        #expect(touch.request.kind == "bash")
        #expect(touch.request.title == "touch made.txt")
        #expect(touch.request.detail?.contains("Touches: made.txt") == true)
        #expect(touch.alwaysRules == [.init(tool: "Bash", content: "touch made.txt")])

        // A compound command: the exact command plus the CLI's per-subcommand rules (new `words *` form).
        let compound = prompts[1]
        #expect(compound.alwaysRules == [.init(tool: "Bash", content: "mkdir d1 && touch d1/x"),
                                         .init(tool: "Bash", content: "mkdir d1 *"), .init(tool: "Bash", content: "touch d1/x")])
        var remembered = rules(compound.alwaysRules)
        #expect(bash(remembered, "mkdir d1 && touch d1/x"))
        #expect(bash(remembered, "mkdir d1 -p"))
        #expect(bash(remembered, "touch d1/x"))
        #expect(!bash(remembered, "mkdir d1 && touch d1/y"))
        #expect(!bash(remembered, "mkdir d1 ; rm -rf ~"))
        #expect(!bash(remembered, "touch d1/x2"))

        // A Read outside the project: kind external_directory, rule limited to the CLI's suggested folder.
        let read = prompts[2]
        #expect(read.isExternal)
        #expect(read.request.kind == "external_directory")
        #expect(read.alwaysRules == [.init(tool: "Read", content: "//private/tmp/ensemble-claude/outside/**")])
        remembered = rules(read.alwaysRules)
        #expect(remembered.allows(read))
        #expect(remembered.matches(toolName: "Read", input: ["file_path": "/private/tmp/ensemble-claude/outside/sub/c.txt"],
                                   directory: ClaudeFixtures.directory, isExternal: true))
        #expect(!remembered.matches(toolName: "Read", input: ["file_path": "/private/tmp/ensemble-claude/outside/../secret"],
                                    directory: ClaudeFixtures.directory, isExternal: true))
        #expect(!remembered.matches(toolName: "Read", input: ["file_path": "/private/tmp/ensemble-claude/outsider/c.txt"],
                                    directory: ClaudeFixtures.directory, isExternal: true))
        #expect(!remembered.matches(toolName: "Grep", input: ["path": "/private/tmp/ensemble-claude/outside"],
                                    directory: ClaudeFixtures.directory, isExternal: true))
    }

    @Test func editRulesStayInsideTheProject() {
        let edit = prompt(tool: "Edit", input: ["file_path": "/p/a"])
        #expect(edit.alwaysRules == [.init(tool: "edit", content: nil)])
        let remembered = rules(edit.alwaysRules)
        #expect(remembered.matches(toolName: "Write", input: ["file_path": "/p/b"], directory: "/p"))
        #expect(remembered.matches(toolName: "MultiEdit", input: ["file_path": "/p/sub/c"], directory: "/p"))
        #expect(remembered.matches(toolName: "NotebookEdit", input: ["notebook_path": "/p/n.ipynb"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/Users/me/.zshrc"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/../etc/x"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/pother/x"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/b"], directory: "/p", isExternal: true))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/b"], directory: nil))
        #expect(!remembered.matches(toolName: "Bash", input: ["command": "ls"], directory: "/p"))
        // Files that can run code or change permissions always ask.
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/.git/hooks/pre-commit"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Edit", input: ["file_path": "/p/.git/config"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/.claude/settings.local.json"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/.mcp.json"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/sub/.envrc"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/.GiT/hooks/pre-commit"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/\u{200C}.git/config"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/\u{200C}x"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/package.json"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/sub/PaCkAgE.JSON"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/Makefile"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/rules.MK"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/build.gradle.kts"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p/App.xcodeproj/project.pbxproj"], directory: "/p"))
        #expect(remembered.matches(toolName: "Write", input: ["file_path": "/p/src/package.ts"], directory: "/p"))
        #expect(remembered.matches(toolName: "Write", input: ["file_path": "/p/README.md"], directory: "/p"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/p"], directory: "/p"))
        // A project inside a dot folder: only dot segments below the project count.
        #expect(remembered.matches(toolName: "Write", input: ["file_path": "/Users/me/.dotfiles/zsh/aliases"], directory: "/Users/me/.dotfiles"))
        #expect(!remembered.matches(toolName: "Write", input: ["file_path": "/Users/me/.dotfiles/.git/config"], directory: "/Users/me/.dotfiles"))
        // /tmp and its /private form are the same folder on macOS.
        #expect(remembered.matches(toolName: "Write", input: ["file_path": "/private/tmp/x/a"], directory: "/tmp/x"))

        // An edit outside the project with no suggestion: only that file again.
        let outside = prompt(tool: "Write", input: ["file_path": "/Users/me/.zshrc"], extra: ["blocked_path": "/Users/me/.zshrc"])
        #expect(outside.alwaysRules == [.init(tool: "Write", content: "//Users/me/.zshrc")])
        let once = rules(outside.alwaysRules)
        #expect(once.allows(outside))
        #expect(!once.matches(toolName: "Write", input: ["file_path": "/Users/me/.bashrc"], directory: "/p", isExternal: true))
    }

    @Test func commandAndWebRules() {
        let prefix = rules([.init(tool: "Bash", content: "git status:*")])
        #expect(bash(prefix, "git status"))
        #expect(bash(prefix, "git status --short"))
        #expect(bash(prefix, "git  status   -s"))
        #expect(bash(prefix, "git status 'two words'"))
        #expect(!bash(prefix, "git statusx"))
        #expect(!bash(prefix, "git"))
        #expect(!prefix.matches(toolName: "Read", input: ["command": "git status"], directory: "/p"))
        #expect(!prefix.matches(toolName: "PowerShell", input: ["command": "git status"], directory: "/p"))

        // A command the CLI flagged as reaching outside the project is never approved by a prefix rule.
        #expect(!prefix.matches(toolName: "Bash", input: ["command": "git status"], directory: "/p", isExternal: true))

        let spaced = rules([.init(tool: "Bash", content: "npm run test *")])
        #expect(bash(spaced, "npm run test"))
        #expect(bash(spaced, "npm run test -- --watch"))
        #expect(!bash(spaced, "npm run testing"))

        // PowerShell quoting differs from sh, so its prefix rules are never honoured; exact rules are.
        let pwsh = rules([.init(tool: "PowerShell", content: "Get-Item:*"), .init(tool: "PowerShell", content: "Get-Date")])
        #expect(!pwsh.matches(toolName: "PowerShell", input: ["command": "Get-Item x"], directory: "/p"))
        #expect(pwsh.matches(toolName: "PowerShell", input: ["command": "Get-Date"], directory: "/p"))

        let exact = rules(prompt(tool: "Bash", input: ["command": "make test"]).alwaysRules)
        #expect(bash(exact, "make test"))
        #expect(!bash(exact, "make test && rm -rf ~"))
        #expect(!bash(exact, "make test "))

        // A Bash rule with no content (every command) is never made, and never matches if it exists.
        let suggestedAll = prompt(tool: "Bash", input: ["command": "ls"],
                                  suggestions: [["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow"]])
        #expect(suggestedAll.alwaysRules == [.init(tool: "Bash", content: "ls")])
        #expect(!bash(rules([.init(tool: "Bash", content: nil)]), "ls"))
        // Suggestions for another tool or a deny rule are ignored.
        let mixed = prompt(tool: "Bash", input: ["command": "ls"],
                           suggestions: [["type": "addRules", "rules": [["toolName": "Read", "ruleContent": "//etc/**"]], "behavior": "allow"],
                                         ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm:*"]], "behavior": "deny"]])
        #expect(mixed.alwaysRules == [.init(tool: "Bash", content: "ls")])

        let web = rules([.init(tool: "WebFetch", content: "domain:example.com")])
        #expect(web.matches(toolName: "WebFetch", input: ["url": "https://docs.example.com/a"], directory: "/p"))
        #expect(web.matches(toolName: "WebFetch", input: ["url": "https://EXAMPLE.com/a"], directory: "/p"))
        #expect(!web.matches(toolName: "WebFetch", input: ["url": "https://example.com.evil.net/"], directory: "/p"))
        #expect(!web.matches(toolName: "WebFetch", input: ["url": "https://notexample.com/"], directory: "/p"))

        let mcp = rules(prompt(tool: "mcp__docs__search", input: ["q": "x"]).alwaysRules)
        #expect(mcp.matches(toolName: "mcp__docs__search", input: ["q": "y"], directory: "/p"))
        #expect(!mcp.matches(toolName: "mcp__docs__search", input: ["q": "y"], directory: "/p", isExternal: true))
        #expect(!mcp.matches(toolName: "mcp__docs__delete", input: ["q": "y"], directory: "/p"))
    }

    /// A prefix rule only ever approves one simple command; every shell trick below must ask again.
    @Test(arguments: [
        "git status > /etc/x",
        "git status & rm -rf ~",
        "git status $(rm x)",
        "git \"status;rm\" x",
        "git status\r\nrm x",
        "git status\nrm x",
        "git status\rrm x",
        "git status ${IFS}rm",
        "git status; rm x",
        "git status && rm x",
        "git status || rm x",
        "git status | sh",
        "git status `rm x`",
        "git status < /etc/passwd",
        "git status 2>&1",
        "git status >> out",
        "git status <<< x",
        "git status <(rm x)",
        "(git status)",
        "{ git status; }",
        "git status *",
        "git status ?",
        "git status [ab]",
        "git status ~",
        "git status ~/x",
        "git status HEAD^",
        "git status \\; rm x",
        "git status 'unterminated",
        "git status \"unterminated",
        "git status $HOME",
        "git status \"$HOME\"",
        "git status '$(rm x)'",
        "git status !!",
        "git status # comment",
        "PATH=/tmp git status",
        "GIT_DIR=/x git status",
        "git status =rm",
        "g\"it\" status",
        "git \"stat\"us",
        "git 'status'x",
        "git status --message=\"a b\"",
        "git status 'a''b'",
        "git status \u{0}rm",
        "git status \u{7F}",
        "git status\u{2028}rm x",
        "git status\u{2029}rm x",
        "git status\u{85}rm x",
        "git status\u{A0}rm",
        "git status\u{3000}rm",
        "git status \u{202E}x",
        "git status \u{200B}x",
        "git status\u{FEFF}",
        "git\u{0B}status",
        "git\u{0C}status",
    ])
    func prefixRulesRefuseShellTricks(_ command: String) {
        let prefix = rules([.init(tool: "Bash", content: "git status:*")])
        #expect(!bash(prefix, command))
        #expect(ClaudeShellWords.simpleCommandWords(command) == nil)
    }

    @Test func shellWordsGroupQuotesOnly() {
        #expect(ClaudeShellWords.simpleCommandWords("git commit -m 'two words'") == ["git", "commit", "-m", "two words"])
        #expect(ClaudeShellWords.simpleCommandWords("echo \"a b\" c") == ["echo", "a b", "c"])
        #expect(ClaudeShellWords.simpleCommandWords("echo '' c") == ["echo", "", "c"])
        #expect(ClaudeShellWords.simpleCommandWords("ls\t-la") == ["ls", "-la"])
        #expect(ClaudeShellWords.simpleCommandWords("  ls  ") == ["ls"])
        #expect(ClaudeShellWords.simpleCommandWords("git log --format=%h") == ["git", "log", "--format=%h"])
        #expect(ClaudeShellWords.simpleCommandWords("echo café") == ["echo", "café"])
        #expect(ClaudeShellWords.simpleCommandWords("") == [])
        #expect(ClaudeShellWords.simpleCommandWords("git \"status;rm\"") == nil)
        #expect(ClaudeShellWords.simpleCommandWords("echo 'a") == nil)
    }
}
