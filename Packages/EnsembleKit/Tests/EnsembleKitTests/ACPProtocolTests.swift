import Foundation
import Testing
@testable import EnsembleKit

/// Captured `agy acp` and `opencode acp` traffic (see Fixtures/acp/README.md).
enum ACPFixtures {
    struct Line {
        var incoming: Bool
        var message: JSONValue
    }

    static let directory = "/tmp/ensemble-acp/proj"

    static func lines(_ name: String) throws -> [Line] {
        try Fixtures.text("acp/\(name)").split(separator: "\n").compactMap { raw in
            guard let json = JSONValue.acpParse(line: String(raw)) else { return nil }
            return Line(incoming: json["dir"]?.stringValue == "in", message: json["msg"] ?? .null)
        }
    }

    static func incoming(_ name: String) throws -> [ACPMessage] {
        try lines(name).filter(\.incoming).compactMap { ACPMessage.decode($0.message) }
    }

    /// The result the agent sent for the client request with this method (the n-th one).
    static func result(_ name: String, method: String, occurrence: Int = 0) throws -> JSONValue? {
        let all = try lines(name)
        let ids = all.filter { !$0.incoming && $0.message["method"]?.stringValue == method }.compactMap { ACPRequestID($0.message["id"]) }
        guard occurrence < ids.count else { return nil }
        let wanted = ids[occurrence]
        for line in all where line.incoming {
            if case .response(let id, let result)? = ACPMessage.decode(line.message), id == wanted { return result }
        }
        return nil
    }

    /// Runs a fixture's updates and permission requests through a transcript, the way the engine does.
    static func replay(_ name: String, directory: String = directory) throws -> (state: ACPTranscriptState, events: [EngineEvent], asks: [ACPPermissionAsk]) {
        var state = ACPTranscriptState(sessionID: "s", directory: directory, generation: "g")
        var events: [EngineEvent] = []
        var asks: [ACPPermissionAsk] = []
        for message in try incoming(name) {
            switch message {
            case .notification("session/update", let params):
                if let update = params["update"].flatMap(ACPSessionUpdate.init) { events += state.apply(update) }
            case .request(_, "session/request_permission", let params):
                guard let ask = ACPPermissionAsk(params: params) else { continue }
                asks.append(ask)
                if let call = ask.toolCall { events += state.applyTool(call) }
            case .response(_, let result) where result["stopReason"] != nil:
                events += state.endTurn()
            default:
                break
            }
        }
        return (state, events, asks)
    }

    static func tools(_ items: [TranscriptItem]) -> [ToolCallInfo] {
        items.compactMap { if case .tool(let info) = $0 { info } else { nil } }
    }

    static func texts(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .agentText(_, let text, _, _) = $0 { text } else { nil } }
    }
}

@Suite("ACP JSON-RPC framing and decoding")
struct ACPFramingTests {
    @Test func lineBufferSplitsPartialLinesAndCRLF() {
        let buffer = ACPLineBuffer()
        #expect(buffer.append(Data(#"{"a":1}"#.utf8)).isEmpty)
        #expect(buffer.append(Data("\n{\"b\":".utf8)) == [#"{"a":1}"#])
        #expect(buffer.append(Data("2}\r\n\n{\"c\":3}\n".utf8)) == [#"{"b":2}"#, #"{"c":3}"#])
        #expect(buffer.append(Data(#"{"tail":true}"#.utf8)).isEmpty)
        #expect(buffer.finish() == [#"{"tail":true}"#])
        // Multibyte characters split across reads come out whole.
        let snowman = Array("\"\u{2603}\"\n".utf8)
        #expect(buffer.append(Data(snowman.prefix(2))).isEmpty)
        #expect(buffer.append(Data(snowman.dropFirst(2))) == ["\"\u{2603}\""])
    }

    @Test func lineBufferDropsOverlongLines() {
        let buffer = ACPLineBuffer(maxLineBytes: 16)
        #expect(buffer.append(Data(String(repeating: "x", count: 40).utf8)).isEmpty)
        #expect(buffer.append(Data("yyy\n{\"ok\":1}\n".utf8)) == [#"{"ok":1}"#])
    }

    @Test func decodesEveryKindOfMessage() {
        #expect(ACPMessage.decode(line: #"{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s"}}"#)
                == .request(id: .number(0), method: "session/request_permission", params: ["sessionId": "s"]))
        #expect(ACPMessage.decode(line: #"{"jsonrpc":"2.0","method":"session/update","params":{}}"#) == .notification(method: "session/update", params: [:]))
        #expect(ACPMessage.decode(line: #"{"jsonrpc":"2.0","result":{},"id":"1"}"#) == .response(id: .string("1"), result: [:]))
        #expect(ACPMessage.decode(line: #"{"jsonrpc":"2.0","id":3,"result":null}"#) == .response(id: .number(3), result: .null))
        #expect(ACPMessage.decode(line: #"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"Authentication required"}}"#)
                == .failure(id: .number(4), error: ACPRPCError(code: -32000, message: "Authentication required")))
        #expect(ACPMessage.decode(line: "INFO starting server") == nil)
        #expect(ACPMessage.decode(line: "") == nil)
    }

    @Test func encodesOneLinePerMessage() throws {
        let message = ACPMessage.request(id: .number(7), method: "session/prompt",
                                         params: ["sessionId": "s", "prompt": [ACPContentBlock.text("two\nlines")]])
        let data = message.lineData
        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A))
        #expect(ACPMessage.decode(line: String(decoding: data, as: UTF8.self)) == message)
        let reply = ACPMessage.response(id: .string("1"), result: ACPPermissionAsk.outcome(optionID: "allow"))
        let text = String(decoding: reply.lineData, as: UTF8.self)
        #expect(text.contains(#""id":"1""#))
        #expect(text.contains(#""optionId":"allow""#))
        #expect(String(decoding: ACPMessage.response(id: .number(0), result: ACPPermissionAsk.outcome(optionID: nil)).lineData, as: UTF8.self)
            .contains(#""outcome":"cancelled""#))
    }

    @Test func everyCapturedLineDecodes() throws {
        for name in ["agy-edit.jsonl", "agy-load-cancel.jsonl", "agy-config.jsonl", "agy-ask-under-turbo.jsonl", "opencode-mock.jsonl"] {
            let lines = try ACPFixtures.lines(name)
            #expect(lines.count > 20, "\(name)")
            for line in lines {
                let message = try #require(ACPMessage.decode(line.message), "\(name): \(line.message.jsonText.prefix(120))")
                if case .notification("session/update", let params) = message {
                    #expect(params["update"].flatMap(ACPSessionUpdate.init) != nil, "\(name): \(params.jsonText.prefix(120))")
                }
            }
        }
    }
}

@Suite("ACP protocol types from real agents")
struct ACPRealAgentTests {
    typealias F = ACPFixtures

    @Test func antigravityInitializeAndSessionSetup() throws {
        let info = ACPAgentInfo(result: try #require(try F.result("agy-edit.jsonl", method: "initialize")))
        #expect(info.protocolVersion == 1)
        #expect(info.name == "Antigravity ACP Server")
        #expect(info.version == "1.5.10")
        #expect(info.loadSession && info.resumeSession && info.closeSession && info.listSessions)
        #expect(!info.deleteSession && !info.forkSession)
        #expect(info.promptImage && info.promptEmbeddedContext)
        #expect(info.authMethods.contains("oauth-personal"))

        let setup = ACPSessionSetup(result: try #require(try F.result("agy-edit.jsonl", method: "session/new")))
        #expect(setup.sessionID?.isEmpty == false)
        #expect(setup.currentModeID == "default")
        #expect(setup.modes.map(\.id) == ["default", "accept-edits", "auto", "plan"])
        #expect(setup.models.contains { $0.value == "gemini-3.8-flash-low" })
        let options = try #require(setup.configOptions)
        #expect(options.map(\.category) == ["model", "thought_level", "mode"])
        #expect(options[0].choices.contains { $0.value == "gemini-3.8-flash" && $0.name == "Gemini 3.8 Flash" })
        #expect(options[1].choices.map(\.value) == ["low", "medium", "high"])
        #expect(ACPModes.modeID(for: .ask, definition: ACPAgentRegistry.antigravity, available: options[2].choices.map(\.value)) == "default")
        #expect(ACPModes.modeID(for: .acceptEdits, definition: ACPAgentRegistry.antigravity, available: options[2].choices.map(\.value)) == "accept-edits")
    }

    @Test func openCodeInitializeAndSessionSetup() throws {
        let info = ACPAgentInfo(result: try #require(try F.result("opencode-mock.jsonl", method: "initialize")))
        #expect(info.name == "OpenCode")
        #expect(info.loadSession && info.deleteSession && info.forkSession && info.resumeSession)
        let setup = ACPSessionSetup(result: try #require(try F.result("opencode-mock.jsonl", method: "session/new")))
        #expect(setup.modes.isEmpty)
        #expect(setup.models.isEmpty)
        #expect(setup.configOptions?.first?.currentValue == "mock/mock-1")
        #expect(setup.configOptions?.last?.choices.map(\.value) == ["build", "plan"])
        // OpenCode's modes are agents, not permission levels: nothing is guessed for them.
        #expect(ACPModes.modeID(for: .ask, definition: ACPAgentRegistry.openCode, available: ["build", "plan"]) == nil)
    }

    @Test func antigravityEditTurns() throws {
        let replay = try F.replay("agy-edit.jsonl")
        let items = replay.state.items
        let texts = F.texts(items)
        #expect(texts.first == "hello there")
        #expect(texts.contains { $0.contains("Created [notes.txt]") })
        let tools = F.tools(items)
        #expect(tools.map(\.name) == ["write", "edit"])
        #expect(tools.map(\.title) == ["notes.txt", "notes.txt"])
        #expect(tools.map(\.status) == [.succeeded, .failed])
        #expect(tools[0].diff?.contains("--- /dev/null\n+++ b/notes.txt\n@@ -0,0 +1,1 @@\n+alpha") == true)
        #expect(tools[0].inputJSON.contains("\"Content\""))
        // The rejected edit's diff came with the permission request (Antigravity sends only the replaced fragment).
        #expect(tools[1].diff?.contains("-alpha\n+beta") == true)
        // Text deltas and the end of each text row share ids with the transcript rows.
        let ended = replay.events.compactMap { if case .textEnded(_, let id, let text) = $0 { (id, text) } else { nil } }
        #expect(ended.first?.1 == "hello there")
        #expect(items.contains { $0.id == ended.first?.0 })

        #expect(replay.asks.count == 2)
        let ask = replay.asks[0]
        #expect(ask.options.map(\.kind) == ["allow_once", "reject_once"])
        #expect(!ask.offersAlways)
        #expect(ask.option(for: .once)?.id == "allow")
        #expect(ask.option(for: .always)?.id == "allow")
        #expect(ask.option(for: .reject)?.id == "deny")
        var tool = ACPToolState(id: "t")
        tool.merge(try #require(ask.toolCall))
        let request = ACPPermissionMapping.request(id: "p", sessionID: "s", tool: tool, directory: F.directory)
        #expect(request.kind == "write")
        #expect(request.title == "notes.txt")
        #expect(request.detail?.contains("+alpha") == true)
        // The new file is inside the project and is the only path the call touches.
        #expect(request.alwaysPatterns == ["edits to notes.txt"])
    }

    @Test func antigravityReplayShellAndCancel() throws {
        let replay = try F.replay("agy-load-cancel.jsonl")
        let items = replay.state.items
        let users = items.compactMap { if case .user(_, let text, _) = $0 { text } else { nil } }
        #expect(users.prefix(3) == ["Reply with exactly: hello there", "Create a file named notes.txt containing the single line: alpha",
                                    "In notes.txt replace alpha with beta."])
        let tools = F.tools(items)
        #expect(tools.map(\.name) == ["write", "edit", "bash"])
        #expect(tools[2].title == "echo hi")
        #expect(tools[2].status == .succeeded)
        #expect(tools[2].outputPreview?.contains("Command output:\nhi") == true)
        #expect(items.contains { if case .reasoning(_, let text, false) = $0 { text.contains("thinking through") } else { false } })
        #expect(F.texts(items).last == "still here")

        var tool = ACPToolState(id: "t")
        tool.merge(try #require(replay.asks.first?.toolCall))
        let request = ACPPermissionMapping.request(id: "p", sessionID: "s", tool: tool, directory: F.directory)
        #expect(request.kind == "bash")
        #expect(request.title == "echo hi")
        // The descriptive `toolSummary` is left out; agy's wait time is part of what is remembered.
        #expect(tool.alwaysRule(directory: F.directory) == ACPAlwaysRule(key: #"execute|run_command|{"CommandLine":"echo hi","WaitMsBeforeAsync":5000}"#,
                                                                        summary: #"command: echo hi with {"WaitMsBeforeAsync":5000}"#))
        #expect(request.alwaysPatterns == [#"command: echo hi with {"WaitMsBeforeAsync":5000}"#])

        let stops = try F.incoming("agy-load-cancel.jsonl").compactMap { message -> ACPStopReason? in
            if case .response(_, let result) = message, let stop = result["stopReason"]?.stringValue { return ACPStopReason(stop) }
            return nil
        }
        #expect(stops == [.endTurn, .cancelled, .endTurn])
        #expect(ACPStopReason.cancelled.outcome.outcome == "interrupted")
        let usage = try #require(ACPTurnUsage(try F.result("agy-load-cancel.jsonl", method: "session/prompt", occurrence: 2)?["usage"]))
        #expect(usage.thoughtTokens == 447)
        #expect(usage.usage.reasoningTokens == 447)
    }

    @Test func turboPresetDoesNotSkipPromptsInDefaultMode() throws {
        // Recorded on a Mac whose Antigravity preset is Turbo; Ensemble set mode `default`, then `accept-edits`.
        let replay = try F.replay("agy-ask-under-turbo.jsonl")
        #expect(replay.asks.count == 4)
        var kinds: [String] = []
        var always: [[String]] = []
        for ask in replay.asks {
            var tool = ACPToolState(id: "t")
            tool.merge(try #require(ask.toolCall))
            let request = ACPPermissionMapping.request(id: "p", sessionID: "s", tool: tool, directory: F.directory)
            kinds.append(request.kind)
            always.append(request.alwaysPatterns ?? [])
        }
        #expect(kinds == ["bash", "external_directory", "external_directory", "bash"])
        // Paths outside the project are never remembered.
        #expect(always == [[#"command: touch made-by-shell.txt with {"WaitMsBeforeAsync":5000}"#], [ACPAlwaysRules.thisRequestOnly],
                           [ACPAlwaysRules.thisRequestOnly], [#"command: ls with {"WaitMsBeforeAsync":5000}"#]])
        let modes = try ACPFixtures.lines("agy-ask-under-turbo.jsonl").filter { !$0.incoming && $0.message["params"]?["configId"]?.stringValue == "mode" }
        #expect(modes.compactMap { $0.message["params"]?["value"]?.stringValue } == ["default", "accept-edits", "auto"])
    }

    @Test func openCodeTurns() throws {
        let replay = try F.replay("opencode-mock.jsonl")
        let items = replay.state.items
        #expect(F.texts(items).prefix(2) == ["Hello from the mock model. Nice to meet you.", "Thought about it."])
        #expect(items.contains { if case .reasoning(_, "Let me think about this carefully.", false) = $0 { true } else { false } })
        let tools = F.tools(items)
        #expect(tools.map(\.name) == ["write", "edit", "bash", "todowrite"])
        #expect(tools[0].title == "hello.txt")
        #expect(tools[0].inputJSON.contains("hi from mock"))
        #expect(tools[1].diff?.contains("-hi from mock\n+hello from mock") == true)
        #expect(tools[2].title == "echo ensemble-ok")
        #expect(tools[2].status == .failed)
        #expect(tools[2].outputPreview == "The user declined this tool call")
        #expect(replay.asks.map { $0.options.map(\.kind) }.first == ["allow_once", "allow_always", "reject_once"])
        #expect(replay.asks[1].option(for: .always)?.id == "always")
        let changed = replay.state.changedFiles()
        #expect(changed.map(\.path) == ["hello.txt"])
        #expect(changed.first?.kind == .added)
        #expect(changed.first?.additions == 2)
        #expect(changed.first?.deletions == 1)
        let usage = try F.incoming("opencode-mock.jsonl").compactMap { message -> ACPSessionUpdate? in
            if case .notification(_, let params) = message, let update = params["update"].flatMap(ACPSessionUpdate.init),
               case .usage = update { return update }
            return nil
        }.first
        #expect(usage == .usage(used: 11778, size: 128000, costUSD: 0))
    }
}

@Suite("ACP transcripts, diffs and plans")
struct ACPTranscriptTests {
    @Test func planBecomesATaskList() {
        var state = ACPTranscriptState(sessionID: "s", directory: "/p", generation: "g")
        _ = state.addUser("go", synthetic: false)
        let events = state.apply(.plan([ACPPlanEntry(content: "Read", priority: "high", status: "completed"),
                                        ACPPlanEntry(content: "Write", priority: "medium", status: "in_progress")]))
        #expect(events.count == 1)
        _ = state.apply(.plan([ACPPlanEntry(content: "Read", priority: "high", status: "completed"),
                               ACPPlanEntry(content: "Write", priority: "medium", status: "completed")]))
        let todos = TodoParser.latest(in: state.items)
        #expect(todos?.map(\.status) == [.completed, .completed])
        // One card per turn, updated in place.
        #expect(ACPFixtures.tools(state.items).count == 1)
    }

    @Test func messageIDsSplitRowsAndTurnEndsCloseThem() {
        var state = ACPTranscriptState(sessionID: "s", directory: "/p", generation: "g")
        _ = state.apply(.agentMessage(text: "one ", messageID: "m1"))
        _ = state.apply(.agentMessage(text: "two", messageID: "m1"))
        let split = state.apply(.agentMessage(text: "three", messageID: "m2"))
        #expect(split.contains { if case .textEnded(_, _, "one two") = $0 { true } else { false } })
        _ = state.apply(.toolCall(ACPToolCallUpdate(["toolCallId": "t1", "title": "ls", "kind": "execute", "status": "in_progress"])!))
        let end = state.endTurn()
        #expect(end.contains { if case .toolUpdated(_, let info) = $0 { info.status == .failed } else { false } })
        #expect(ACPFixtures.texts(state.items) == ["one two", "three"])
        #expect(!state.items.contains { if case .agentText(_, _, _, true) = $0 { true } else { false } })
    }

    @Test func syntheticReplaysAreNotices() {
        var state = ACPTranscriptState(sessionID: "s", directory: "/p", syntheticTexts: ["[Room] Ada: hi"], generation: "g")
        _ = state.apply(.userMessage(text: "[Room] Ada: hi", messageID: nil))
        _ = state.apply(.userMessage(text: "hel", messageID: nil))
        _ = state.apply(.userMessage(text: "lo", messageID: nil))
        #expect(state.items.count == 2)
        #expect(state.items.first == .notice(id: state.items[0].id, text: "[Room] Ada: hi"))
        if case .user(_, let text, _) = state.items[1] { #expect(text == "hello") } else { Issue.record("not a user row") }
    }

    @Test func rowIDsDifferBetweenStates() {
        var a = ACPTranscriptState(sessionID: "s", directory: "/p")
        var b = ACPTranscriptState(sessionID: "s", directory: "/p")
        _ = a.apply(.agentMessage(text: "x", messageID: nil))
        _ = b.apply(.agentMessage(text: "x", messageID: nil))
        #expect(a.items.first?.id != b.items.first?.id)
    }

    @Test func unifiedDiffs() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 5\n", with: "line five\n")
        let diff = ACPDiff.unified(path: "a.txt", oldText: old, newText: new)
        #expect(diff == """
        --- a/a.txt
        +++ b/a.txt
        @@ -2,7 +2,7 @@
         line 2
         line 3
         line 4
        -line 5
        +line five
         line 6
         line 7
         line 8
        """)
        #expect(ACPDiff.unified(path: "n.txt", oldText: nil, newText: "a\nb\n") == "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+a\n+b")
        #expect(ACPDiff.unified(path: "s.txt", oldText: "same\n", newText: "same\n") == "--- a/s.txt\n+++ b/s.txt")
        let removed = ACPDiff.unified(path: "r.txt", oldText: "a\nb\n", newText: "")
        #expect(removed.hasSuffix("@@ -1,2 +0,0 @@\n-a\n-b"))
    }

    @Test func toolNamesAndPermissionKinds() {
        func tool(_ json: JSONValue) -> ACPToolState {
            var state = ACPToolState(id: "t")
            state.merge(ACPToolCallUpdate(json)!)
            return state
        }
        #expect(tool(["toolCallId": "t", "kind": "fetch", "name": "web_search", "title": "swift"]).ensembleName == "websearch")
        #expect(tool(["toolCallId": "t", "kind": "search", "title": "TODO"]).ensembleName == "grep")
        #expect(tool(["toolCallId": "t", "kind": "other", "name": "todowrite", "title": "todowrite"]).ensembleName == "todowrite")
        #expect(tool(["toolCallId": "t", "kind": "delete", "title": "rm"]).permissionKind(directory: nil) == "edit")
        let outside = tool(["toolCallId": "t", "kind": "read", "title": "File hosts", "locations": [["path": "/etc/hosts"]]])
        #expect(outside.permissionKind(directory: "/tmp/ensemble-acp/proj") == "external_directory")
        #expect(outside.cardTitle(directory: "/tmp/ensemble-acp/proj") == "/etc/hosts")
        let inside = tool(["toolCallId": "t", "kind": "read", "title": "File a", "locations": [["path": "/private/tmp/x/a.swift"]]])
        #expect(inside.cardTitle(directory: "/tmp/x") == "a.swift")
        #expect(ACPFormatting.command(["CommandLine": "echo hi"]) == "echo hi")
        #expect(ACPFormatting.command(["command": ["git", "status"]]) == "git status")
    }

    @Test func stopReasons() {
        #expect(ACPStopReason("end_turn").outcome.outcome == "succeeded")
        #expect(ACPStopReason(nil) == .endTurn)
        #expect(ACPStopReason("max_tokens").outcome.error != nil)
        #expect(ACPStopReason("refusal").outcome.outcome == "failed")
        #expect(ACPStopReason("weird") == .other("weird"))
    }
}

@Suite("ACP always rules")
struct ACPAlwaysRuleTests {
    static let project = "/tmp/ensemble-acp/proj"

    func tool(_ json: JSONValue) -> ACPToolState {
        var state = ACPToolState(id: "t")
        state.merge(ACPToolCallUpdate(json)!)
        return state
    }

    func request(_ json: JSONValue) -> PermissionRequest {
        ACPPermissionMapping.request(id: "p", sessionID: "s", tool: tool(json), directory: Self.project)
    }

    @Test func commandsAreRememberedByTheParsedCommandNotTheTitle() {
        let echo = tool(["toolCallId": "t", "kind": "execute", "name": "run_command", "title": "harmless", "rawInput": ["CommandLine": "echo hi"]])
        let sameCommand = tool(["toolCallId": "u", "kind": "execute", "name": "run_command", "title": "other words", "rawInput": ["CommandLine": "echo hi"]])
        let sameTitle = tool(["toolCallId": "v", "kind": "execute", "name": "run_command", "title": "harmless", "rawInput": ["CommandLine": "rm -rf ~"]])
        #expect(echo.alwaysRule(directory: Self.project)?.key == sameCommand.alwaysRule(directory: Self.project)?.key)
        #expect(echo.alwaysRule(directory: Self.project)?.key != sameTitle.alwaysRule(directory: Self.project)?.key)
        #expect(echo.alwaysRule(directory: Self.project)?.summary == "command: echo hi")
        // A command Ensemble cannot read from the arguments is allowed once only, whatever the title says.
        let titleOnly = ["toolCallId": "t", "kind": "execute", "title": "echo hi", "rawInput": [:]] as JSONValue
        #expect(tool(titleOnly).alwaysRule(directory: Self.project) == nil)
        #expect(request(titleOnly).alwaysPatterns == [ACPAlwaysRules.thisRequestOnly])
        // A command next to separate arguments could show one and run both: allowed once only.
        let split = ["toolCallId": "t", "kind": "execute", "rawInput": ["command": "git", "args": ["push", "--force"]]] as JSONValue
        #expect(tool(split).alwaysRule(directory: Self.project) == nil)
        #expect(request(split).alwaysPatterns == [ACPAlwaysRules.thisRequestOnly])
        let twoCommands = ["toolCallId": "t", "kind": "execute", "rawInput": ["command": "ls", "cmd": "rm -rf build"]] as JSONValue
        #expect(tool(twoCommands).alwaysRule(directory: Self.project) == nil)
        // The folder a command runs in is part of the rule; a folder outside the project is never remembered.
        let inSub = tool(["toolCallId": "t", "kind": "execute", "rawInput": ["command": "make", "cwd": .string("\(Self.project)/sub")]])
        #expect(inSub.alwaysRule(directory: Self.project)?.summary == "command: make (in sub)")
        #expect(inSub.alwaysRule(directory: Self.project)?.key != tool(["toolCallId": "t", "kind": "execute", "rawInput": ["command": "make"]])
            .alwaysRule(directory: Self.project)?.key)
        #expect(tool(["toolCallId": "t", "kind": "execute", "rawInput": ["command": "make", "cwd": "/etc"]]).alwaysRule(directory: Self.project) == nil)
    }

    @Test func fetchesAreRememberedByTheCanonicalURL() {
        let a = tool(["toolCallId": "t", "kind": "fetch", "title": "docs", "rawInput": ["url": "HTTPS://Example.COM:443/a?b=1#part"]])
        let b = tool(["toolCallId": "u", "kind": "fetch", "title": "something else", "rawInput": ["url": "https://example.com/a?b=1"]])
        let other = tool(["toolCallId": "v", "kind": "fetch", "title": "docs", "rawInput": ["url": "https://example.com/b"]])
        #expect(a.alwaysRule(directory: Self.project)?.key == b.alwaysRule(directory: Self.project)?.key)
        #expect(a.alwaysRule(directory: Self.project)?.key != other.alwaysRule(directory: Self.project)?.key)
        #expect(a.alwaysRule(directory: Self.project)?.summary == "web request: https://example.com/a?b=1")
        #expect(ACPAlwaysRules.canonicalURL(["url": "https://example.com"]) == "https://example.com/")
        #expect(ACPAlwaysRules.canonicalURL(["url": "file:///etc/passwd"]) == nil)
        #expect(ACPAlwaysRules.canonicalURL(["url": "https://user:pw@example.com/"]) == nil)
        #expect(tool(["toolCallId": "t", "kind": "fetch", "title": "https://example.com"]).alwaysRule(directory: Self.project) == nil)
        let search = tool(["toolCallId": "t", "kind": "fetch", "name": "web_search", "rawInput": ["query": "swift"]])
        #expect(search.alwaysRule(directory: Self.project)?.summary == #"websearch({"query":"swift"})"#)
    }

    @Test func onlyOnePathInsideTheProjectIsRemembered() {
        let one = ["toolCallId": "t", "kind": "edit", "name": "edit_file", "title": "File notes.txt",
                   "locations": [["path": "/private/tmp/ensemble-acp/proj/notes.txt"]],
                   "rawInput": ["Path": "/private/tmp/ensemble-acp/proj/notes.txt", "Target": "alpha", "Replacement": "beta"]] as JSONValue
        #expect(tool(one).alwaysRule(directory: Self.project)?.summary == "edits to notes.txt")
        #expect(request(one).alwaysPatterns == ["edits to notes.txt"])
        // A relative argument is the same file.
        let relative = ["toolCallId": "t", "kind": "edit", "name": "edit_file", "title": "x", "rawInput": ["path": "notes.txt"]] as JSONValue
        #expect(tool(relative).alwaysRule(directory: Self.project)?.key == tool(one).alwaysRule(directory: Self.project)?.key)

        // The location says one file, the arguments name another: two paths, asked every time, and the card shows both.
        let mismatch = ["toolCallId": "t", "kind": "edit", "title": "File notes.txt",
                        "locations": [["path": "/private/tmp/ensemble-acp/proj/notes.txt"]],
                        "rawInput": ["path": "/private/tmp/ensemble-acp/proj/notes.txt", "extra": ["file_path": "/private/tmp/ensemble-acp/proj/b.txt"]]] as JSONValue
        #expect(tool(mismatch).alwaysRule(directory: Self.project) == nil)
        #expect(request(mismatch).alwaysPatterns == [ACPAlwaysRules.thisRequestOnly])
        #expect(request(mismatch).title == "notes.txt, b.txt")

        let diffElsewhere = ["toolCallId": "t", "kind": "edit", "title": "File notes.txt",
                             "locations": [["path": "/private/tmp/ensemble-acp/proj/notes.txt"]],
                             "content": [["type": "diff", "path": "/private/tmp/ensemble-acp/proj/other.txt", "newText": "x"]]] as JSONValue
        #expect(tool(diffElsewhere).alwaysRule(directory: Self.project) == nil)

        let move = ["toolCallId": "t", "kind": "move", "title": "Move",
                    "rawInput": ["source": .string("\(Self.project)/a.txt"), "destination": .string("\(Self.project)/b.txt")]] as JSONValue
        #expect(tool(move).alwaysRule(directory: Self.project) == nil)
        #expect(request(move).title == "a.txt, b.txt")
        // A move with only one path visible is still never remembered.
        #expect(tool(["toolCallId": "t", "kind": "move", "rawInput": ["source": .string("\(Self.project)/a.txt")]]).alwaysRule(directory: Self.project) == nil)

        let outside = ["toolCallId": "t", "kind": "read", "title": "File notes.txt", "rawInput": ["Path": "/etc/hosts"]] as JSONValue
        #expect(tool(outside).alwaysRule(directory: Self.project) == nil)
        #expect(request(outside).kind == "external_directory")
        #expect(request(outside).alwaysPatterns == [ACPAlwaysRules.thisRequestOnly])
        let escape = ["toolCallId": "t", "kind": "edit", "title": "x", "rawInput": ["path": "../../outside.txt"]] as JSONValue
        #expect(tool(escape).alwaysRule(directory: Self.project) == nil)
        // A path the agent hides in a nested list of files counts too.
        let nested = ["toolCallId": "t", "kind": "edit", "title": "x", "locations": [["path": .string("\(Self.project)/a.txt")]],
                      "rawInput": ["edits": [["files": [.string("\(Self.project)/a.txt"), "/etc/passwd"]]]]] as JSONValue
        #expect(tool(nested).alwaysRule(directory: Self.project) == nil)
        // A shell command that names an outside folder in its location is not remembered either.
        let shellOutside = ["toolCallId": "t", "kind": "execute", "locations": [["path": "/etc"]], "rawInput": ["command": "ls"]] as JSONValue
        #expect(tool(shellOutside).alwaysRule(directory: Self.project) == nil)
    }

    @Test func commandsAreRememberedByEveryArgumentThatChangesWhatRuns() {
        func key(_ input: JSONValue) -> String? {
            tool(["toolCallId": "t", "kind": "execute", "name": "shell", "title": "x", "rawInput": input]).alwaysRule(directory: Self.project)?.key
        }
        let plain = key(["command": "make test"])
        #expect(plain != nil)
        // Only descriptive text differs: the same rule.
        #expect(key(["command": "make test", "description": "Run the tests", "title": "tests"]) == plain)
        // The environment, a shell option or a timeout differs: a different rule, so the call asks again.
        #expect(key(["command": "make test", "env": ["CC": "/tmp/evil-cc"]]) != plain)
        #expect(key(["command": "make test", "shell": "/bin/zsh"]) != plain)
        #expect(key(["command": "make test", "timeout": 600]) != plain)
        // argv stays an array: splitting the same words differently is a different command, shown differently.
        let together = tool(["toolCallId": "t", "kind": "execute", "rawInput": ["command": ["rm", "a b"]]])
        let apart = tool(["toolCallId": "t", "kind": "execute", "rawInput": ["command": ["rm", "a", "b"]]])
        #expect(together.alwaysRule(directory: Self.project)?.key != apart.alwaysRule(directory: Self.project)?.key)
        #expect(together.alwaysRule(directory: Self.project)?.summary == "command: rm 'a b'")
        #expect(apart.alwaysRule(directory: Self.project)?.summary == "command: rm a b")
        #expect(together.cardTitle(directory: Self.project) == "rm 'a b'")
        // An argument Ensemble does not know: this request only.
        let unknown = ["toolCallId": "t", "kind": "execute", "rawInput": ["command": "make test", "runAs": "root"]] as JSONValue
        #expect(tool(unknown).alwaysRule(directory: Self.project) == nil)
        #expect(request(unknown).alwaysPatterns == [ACPAlwaysRules.thisRequestOnly])
        // What the card shows names every remembered argument.
        #expect(tool(["toolCallId": "t", "kind": "execute", "rawInput": ["command": "make", "env": ["A": "1"]]]).alwaysRule(directory: Self.project)?.summary
                == #"command: make with {"env":{"A":"1"}}"#)
    }

    @Test func fetchesAreRememberedWithEveryOtherArgument() {
        func rule(_ input: JSONValue) -> ACPAlwaysRule? {
            tool(["toolCallId": "t", "kind": "fetch", "name": "fetch", "title": "x", "rawInput": input]).alwaysRule(directory: Self.project)
        }
        let get = rule(["url": "https://example.com/api"])
        #expect(get?.summary == "web request: https://example.com/api")
        #expect(rule(["url": "https://example.com/api", "description": "Read the API"])?.key == get?.key)
        // Method, headers or body differ: a different rule.
        let post = rule(["url": "https://example.com/api", "method": "POST"])
        #expect(post?.key != get?.key)
        #expect(post?.summary == #"web request: https://example.com/api with {"method":"POST"}"#)
        #expect(rule(["url": "https://example.com/api", "headers": ["Authorization": "Bearer x"]])?.key != get?.key)
        #expect(rule(["url": "https://example.com/api", "method": "POST", "body": "a=1"])?.key != post?.key)
        // Two URL arguments: nothing is remembered.
        #expect(rule(["url": "https://example.com/a", "Uri": "https://evil.example/b"]) == nil)
    }

    @Test func fileRulesFailClosedOnArgumentsTheyDoNotKnow() {
        let path = "/private/tmp/ensemble-acp/proj/notes.txt"
        func rule(_ input: JSONValue, kind: String = "edit") -> ACPAlwaysRule? {
            tool(["toolCallId": "t", "kind": .string(kind), "name": "edit_file", "title": "File notes.txt", "rawInput": input])
                .alwaysRule(directory: Self.project)
        }
        let edit = rule(["path": .string(path), "oldString": "alpha", "newString": "beta"])
        #expect(edit?.summary == "edits to notes.txt")
        // The content may differ next time; the file may not.
        #expect(rule(["path": .string(path), "oldString": "beta", "newString": "gamma\n/ comment"])?.key == edit?.key)
        #expect(rule(["path": "/private/tmp/ensemble-acp/proj/other.txt", "oldString": "a", "newString": "b"])?.key != edit?.key)
        // An argument that is not a known path, content or option argument for edits: this request only.
        #expect(rule(["path": .string(path), "oldString": "a", "newString": "b", "mode": "append"]) == nil)
        #expect(rule(["path": .string(path), "backupTo": "/etc/passwd"]) == nil)
        // A path hidden in any string counts, whatever the argument is called.
        #expect(rule(["path": .string(path), "description": "/etc/passwd"]) == nil)
        #expect(rule(["path": .string(path), "description": "fix the read/write bug"])?.key == edit?.key)
        #expect(rule(["path": .string(path), "Target": "/etc/passwd", "Replacement": "x"]) == nil)
        #expect(rule(["path": "~/notes.txt", "content": "x"]) == nil)
        // Reads take read options; deletes take nothing but the path.
        #expect(rule(["path": .string(path), "offset": 10, "limit": 20], kind: "read")?.summary == "reading notes.txt")
        #expect(rule(["path": .string(path), "content": "x"], kind: "read") == nil)
        #expect(rule(["path": .string(path)], kind: "delete")?.summary == "deleting notes.txt")
        #expect(rule(["path": .string(path), "recursive": true], kind: "delete") == nil)
    }

    @Test func otherCallsAreRememberedByTheirExactArguments() {
        let a = tool(["toolCallId": "t", "kind": "other", "name": "lookup", "title": "Look it up", "rawInput": ["b": 2, "a": "x"]])
        #expect(a.alwaysRule(directory: Self.project)?.summary == #"lookup({"a":"x","b":2})"#)
        let differentArgs = tool(["toolCallId": "u", "kind": "other", "name": "lookup", "title": "Look it up", "rawInput": ["a": "y"]])
        #expect(a.alwaysRule(directory: Self.project)?.key != differentArgs.alwaysRule(directory: Self.project)?.key)
        #expect(tool(["toolCallId": "t", "kind": "other", "name": "lookup", "title": "Look it up"]).alwaysRule(directory: Self.project) == nil)
        #expect(tool(["toolCallId": "t", "kind": "think", "title": "Think", "rawInput": [:]]).alwaysRule(directory: Self.project) == nil)
    }
}

@Suite("ACP registry and settings")
struct ACPRegistryTests {
    @Test func registryEntries() {
        let ids = ACPAgentRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ACPAgentRegistry.verified.map(\.id) == ["antigravity", "opencode-acp"])
        let agy = ACPAgentRegistry.antigravity
        #expect(agy.arguments == ["acp"])
        #expect(agy.bypassArguments == ["--dangerously-skip-permissions"])
        #expect(agy.maxConcurrentTurns == 3)
        #expect(agy.requiresTrustedFolder)
        #expect(agy.modeIDs[.ask] == "default")
        #expect(ACPAgentRegistry.definition(id: "goose")?.status == .unverified)
        #expect(ACPAgentRegistry.definition(id: "codex-acp")?.executableNames == ["codex-acp"])
        // The OpenCode ACP entry must not claim OpenCode's own provider ids.
        #expect(ACPAgentRegistry.openCode.id != "opencode")
    }

    @Test func detectionUsesTheSearchFoldersAndPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-acp-reg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("goose")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let env = ["HOME": "/nonexistent-home", "PATH": folder.path]
        #expect(ACPAgentRegistry.locate(ACPAgentRegistry.goose, environment: env)?.path == tool.path)
        #expect(ACPAgentRegistry.installation(ACPAgentRegistry.goose, environment: env).installed)
        // Unverified tools are never offered, even when installed.
        #expect(!ACPAgentRegistry.available(environment: env).contains { $0.definition.id == "goose" })
        #expect(ACPAgentRegistry.locate(ACPAgentRegistry.goose, override: "/nonexistent/goose") == nil)
    }

    @Test func environmentDropsKeysAndKeepsSignInBasics() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin", "GEMINI_API_KEY": "k", "GOOGLE_API_KEY": "k", "OPENAI_API_KEY": "k",
                    "ANTHROPIC_API_KEY": "k", "GOOGLE_APPLICATION_CREDENTIALS": "/x.json", "LANG": "de_DE.UTF-8", "XDG_CONFIG_HOME": "/c"]
        let agy = ACPEnvironment.environment(base: base, definition: ACPAgentRegistry.antigravity)
        #expect(agy["GEMINI_API_KEY"] == nil && agy["GOOGLE_API_KEY"] == nil && agy["OPENAI_API_KEY"] == nil)
        #expect(agy["GOOGLE_APPLICATION_CREDENTIALS"] == nil)
        #expect(agy["HOME"] == "/Users/me")
        #expect(agy["LANG"] == "de_DE.UTF-8")
        #expect(agy["PATH"]?.hasPrefix("/usr/bin:") == true)
        #expect(agy["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(agy["XDG_CONFIG_HOME"] == nil)
        #expect(ACPEnvironment.environment(base: base, definition: ACPAgentRegistry.openCode)["XDG_CONFIG_HOME"] == "/c")
    }

    @Test func modeGuessesForUnknownAgents() {
        let unknown = ACPAgentRegistry.goose
        #expect(ACPModes.modeID(for: .ask, definition: unknown, available: ["Default", "yolo"]) == "Default")
        #expect(ACPModes.modeID(for: .bypass, definition: unknown, available: ["Default", "yolo"]) == "yolo")
        #expect(ACPModes.modeID(for: .acceptEdits, definition: unknown, available: ["Default", "yolo"]) == nil)
        #expect(ACPModes.modeID(for: .ask, definition: unknown, available: []) == nil)
        #expect(ACPModes.modeID(for: .ask, definition: ACPAgentRegistry.antigravity, available: ["plan"]) == nil)
    }

    @Test func sessionStoreKeepsOtherAgentsRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-acp-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("acp-sessions.json")
        var agy = ACPSessionStore(fileURL: url, agentID: "antigravity")
        var record = ACPSessionRecord(id: "a", agentID: "antigravity", title: "T", directory: "/p",
                                      model: ModelRef(providerID: "antigravity", id: "gemini-3.8-flash", variant: "low"), permissionMode: .acceptEdits)
        record.agentSessionID = "agy-1"
        record.usage = Usage(inputTokens: 3)
        record.rememberSynthetic("hi")
        agy["a"] = record
        try agy.save()
        var other = ACPSessionStore(fileURL: url, agentID: "opencode-acp")
        #expect(other.all.isEmpty)
        other["b"] = ACPSessionRecord(id: "b", agentID: "opencode-acp", directory: "/q", model: nil, permissionMode: .ask)
        try other.save()
        // Saving the first store again (which never saw "b") keeps "b".
        try agy.save()
        let reloaded = ACPSessionStore(fileURL: url, agentID: "antigravity")
        #expect(reloaded["a"]?.agentSessionID == "agy-1")
        #expect(reloaded["a"]?.model?.variant == "low")
        #expect(reloaded["a"]?.syntheticTexts == ["hi"])
        #expect(ACPSessionStore(fileURL: url, agentID: "opencode-acp")["b"] != nil)

        try Data(#"{"version":1,"sessions":[{"id":"c","agentID":"antigravity","title":"Old"},{"broken":true}]}"#.utf8).write(to: url)
        let tolerant = ACPSessionStore(fileURL: url, agentID: "antigravity")
        #expect(tolerant["c"]?.title == "Old")
        #expect(tolerant["c"]?.permissionMode == .ask)
    }
}
