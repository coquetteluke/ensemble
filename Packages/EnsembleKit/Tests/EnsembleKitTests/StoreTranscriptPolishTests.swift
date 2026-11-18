import Foundation
import Testing
import WebKit
@testable import EnsembleKit

/// Activity groups, the working row, task lists, slash commands and widget pages.
@Suite struct StoreTranscriptPolishTests {
    private func tool(_ id: String, _ name: String, _ title: String = "x", status: ToolStatus = .succeeded,
                      input: String = "{}") -> TranscriptItem {
        .tool(ToolCallInfo(id: id, name: name, title: title, inputJSON: input, status: status))
    }

    // MARK: Activity groups

    @Test func consecutiveStepsCollapseIntoOneGroup() {
        let items: [TranscriptItem] = [
            .user(id: "u", text: "Go", date: Date()),
            .reasoning(id: "r", text: "Plan", streaming: false),
            tool("t1", "bash", "swift build"),
            tool("t2", "read", "/a.swift"),
            .agentText(id: "a", text: "Done", agentID: nil, streaming: false),
            tool("t3", "read", "/b.swift"),
        ]
        let blocks = TranscriptGrouping.blocks(items)
        #expect(blocks.map(\.id) == ["u", "group-r", "a", "t3"], "a lone step stays a single row")
        guard case .activity(_, let steps) = blocks[1] else {
            Issue.record("expected a group")
            return
        }
        #expect(steps.count == 3)
    }

    @Test func openPermissionPromptsBreakAGroupAnsweredOnesJoinIt() {
        let request = PermissionRequest(id: "p", sessionID: "s", kind: "bash", title: "rm -rf build")
        let items: [TranscriptItem] = [tool("t1", "bash"), .permission(request), tool("t2", "bash")]
        #expect(TranscriptGrouping.blocks(items).count == 3)
        let answered = TranscriptGrouping.blocks(items, resolutions: ["p": .allowedOnce])
        #expect(answered.count == 1)
    }

    @Test func summariesCountByKind() {
        let items: [TranscriptItem] = [
            tool("t1", "bash"), tool("t2", "read", "/a"), tool("t3", "read", "/b"), tool("t4", "read", "/a"),
            tool("t5", "task", status: .succeeded), tool("t6", "task", status: .running),
        ]
        #expect(TranscriptGrouping.summary(items)
            == "Ran a command, read 2 files, finished a background task, started a background task")
        #expect(TranscriptGrouping.summary([tool("e", "edit", status: .failed)]) == "Edited a file, 1 failed")
        #expect(TranscriptGrouping.summary([.reasoning(id: "r", text: "", streaming: false)]) == "Thought")
        #expect(TranscriptGrouping.isRunning(items))
        #expect(!TranscriptGrouping.isRunning(Array(items.prefix(4))))
    }

    // MARK: Working row

    @MainActor @Test func workingRowDescribesTheCurrentStep() {
        let running = tool("t", "bash", "swift test", status: .running)
        #expect(WorkingRow.currentStep([running], waiting: false) == "Running swift test")
        #expect(WorkingRow.currentStep([running], waiting: true) == "Waiting for you")
        #expect(WorkingRow.currentStep([.agentText(id: "a", text: "Hi", agentID: nil, streaming: true)], waiting: false) == "Writing")
        #expect(WorkingRow.currentStep([tool("t", "bash")], waiting: false) == "Thinking")
    }

    @MainActor @Test func workingRowShowsTheNewestStepsOfThisTurnOnly() {
        let items: [TranscriptItem] = [tool("old", "bash"), .user(id: "u", text: "Again", date: Date())]
            + (1...6).map { tool("n\($0)", "read") }
        #expect(WorkingRow.currentTurnSteps(items).map(\.id) == ["n3", "n4", "n5", "n6"])
    }

    @MainActor @Test func elapsedTime() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(WorkingRow.elapsed(from: start, to: start.addingTimeInterval(9)) == "9s")
        #expect(WorkingRow.elapsed(from: start, to: start.addingTimeInterval(69)) == "1m 9s")
        #expect(WorkingRow.elapsed(from: start, to: start.addingTimeInterval(3720)) == "1h 2m")
        #expect(WorkingRow.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0s")
    }

    // MARK: Task lists

    @Test func theNewestTodoCallIsTheList() {
        let first = #"{"todos": [{"content": "Old", "status": "pending"}]}"#
        let second = #"{"todos": [{"content": "Read", "status": "completed"}, {"content": "Test", "status": "in-progress", "activeForm": "Testing"}, {"content": "Ship", "status": "pending"}, {"content": "Drop", "status": "cancelled"}]}"#
        let items: [TranscriptItem] = [tool("a", "todowrite", input: first), tool("b", "bash"), tool("c", "TodoWrite", input: second)]
        let todos = TodoParser.latest(in: items)
        #expect(todos?.map(\.content) == ["Read", "Test", "Ship", "Drop"])
        #expect(todos?.map(\.status) == [.completed, .inProgress, .pending, .cancelled])
        #expect(todos?[1].activeForm == "Testing")
        #expect(TodoParser.latest(in: [tool("b", "bash")]) == nil)
        #expect(TodoParser.parse("not json") == nil)
    }

    // MARK: Slash commands

    @Test func slashQueryOnlyWhileTypingTheName() {
        #expect(SlashCommands.query(in: "/") == "")
        #expect(SlashCommands.query(in: "/mo") == "mo")
        #expect(SlashCommands.query(in: "/model gpt") == nil)
        #expect(SlashCommands.query(in: "hello /mo") == nil)
    }

    @Test func slashMatchesPrefixFirstThenContains() {
        let catalog = SlashCommands.catalog(engine: [])
        let names = SlashCommands.matches("re", in: catalog).map(\.name)
        #expect(names.first == "rewind")
        #expect(names.contains("compact"), "matches in the summary come after name prefixes")
        #expect(SlashCommands.matches("", in: catalog).count == catalog.count)

        let mixed = SlashCommands.catalog(engine: [
            EngineCommand(name: "review", summary: "Review changes", kind: .command),
            EngineCommand(name: "test-plan", summary: "Draft a test plan for the current change", kind: .command),
            EngineCommand(name: "pdf", summary: "Read PDFs", kind: .skill),
        ])
        let found = SlashCommands.matches("re", in: mixed)
        let rank: [SlashCommand.Source: Int] = [.ensemble: 0, .engineCommand: 1, .engineSkill: 2]
        let ranks = found.map { rank[$0.source] ?? 3 }
        #expect(ranks == ranks.sorted(), "each section appears once")
        #expect(found.filter { $0.source == .engineCommand }.map(\.name) == ["review", "test-plan"], "name prefix first within a section")
    }

    @Test func engineCommandsFollowEnsemblesWithoutDuplicates() {
        let engine = [
            EngineCommand(name: "pdf", summary: "Read PDFs", kind: .skill),
            EngineCommand(name: "compact", summary: "Engine compact", kind: .command),
            EngineCommand(name: "review", summary: "Review changes", kind: .command, argumentHint: "[path]"),
        ]
        let catalog = SlashCommands.catalog(engine: engine)
        #expect(catalog.prefix(SlashCommands.builtIn.count).allSatisfy { $0.source == .ensemble })
        #expect(catalog.suffix(2).map(\.name) == ["review", "pdf"], "commands before skills")
        #expect(catalog.filter { $0.name == "compact" }.count == 1)
        for name in ["new", "model", "effort", "fast", "mode", "compact", "fork", "rewind", "clear", "hub", "usage", "help"] {
            #expect(SlashCommands.builtIn.contains { $0.name == name }, "/\(name)")
        }
    }

    @Test func parsingCommandText() {
        #expect(SlashCommands.parse("/model gpt-5")?.name == "model")
        #expect(SlashCommands.parse("/model gpt-5")?.arguments == "gpt-5")
        #expect(SlashCommands.parse("  /help  ")?.arguments == "")
        #expect(SlashCommands.parse("/") == nil)
        #expect(SlashCommands.parse("/ not a command") == nil)
        #expect(SlashCommands.parse("/usr/bin/env") != nil, "a path still parses; the app sends it when no command matches")
    }

    // MARK: Permission card

    @Test func alwaysAllowPatternsAreSplitFromTheDetail() {
        let both = PermissionCardView.splitDetail("Runs the tests.\nAlways allows: swift test *, swift build *")
        #expect(both.detail == "Runs the tests.")
        #expect(both.patterns == "swift test *, swift build *")
        #expect(PermissionCardView.splitDetail("Always allows: echo *") == (nil, "echo *"))
        #expect(PermissionCardView.splitDetail("Just a note") == ("Just a note", nil))
        #expect(PermissionCardView.splitDetail(nil) == (nil, nil))
    }

    // MARK: Widgets

    private static let hostile = #"<script>alert("x & y")</script><head><meta http-equiv="refresh" content="0;url=https://example.com"><base href="https://example.com/"></head><!-- <head> --></iframe><img src=x onerror='go()'>"#

    @Test func thePolicyIsTheWrappersFirstElement() {
        for kind in [WidgetDocument.Kind.html, .svg] {
            let html = WidgetDocument.html(for: Self.hostile, kind: kind, theme: .dark)
            #expect(html.hasPrefix(#"<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; "#))
        }
        let policy = WidgetDocument.contentSecurityPolicy(scripts: true)
        for directive in ["default-src 'none'", "script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "img-src data: blob:",
                          "connect-src 'none'", "frame-src 'none'", "form-action 'none'", "base-uri 'none'"] {
            #expect(policy.contains(directive), "\(directive)")
        }
        #expect(!policy.contains("http"))
        #expect(WidgetDocument.contentSecurityPolicy(scripts: false).contains("script-src 'none'"))
    }

    @Test func agentMarkupOnlyAppearsEscapedInTheSandboxedFrame() throws {
        let html = WidgetDocument.html(for: Self.hostile, kind: .html, theme: .dark)
        // Nothing of the agent's markup is live in the wrapper.
        for raw in ["<script", "alert(\"", "http-equiv=\"refresh\"", "<base", "<!--", "</iframe><img", "onerror='"] {
            #expect(!html.contains(raw), "\(raw)")
        }
        #expect(html.components(separatedBy: "<iframe").count == 2, "exactly one frame")
        #expect(html.contains(#"<iframe sandbox="allow-scripts" title="Visual" srcdoc=""#))
        #expect(!html.contains("allow-same-origin"))
        #expect(!html.contains("allow-top-navigation"))
        #expect(!html.contains("allow-popups"))
        #expect(WidgetDocument.html(for: "<svg/>", kind: .svg, theme: .dark).contains(#"<iframe sandbox="" "#))

        // The srcdoc value holds no quote, so it cannot end early, and unescapes to the frame document.
        let start = try #require(html.range(of: #"srcdoc=""#)).upperBound
        let end = try #require(html[start...].firstIndex(of: "\""))
        let value = String(html[start..<end])
        #expect(html[html.index(after: end)...] == "></iframe></body></html>")
        let unescaped = value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let frame = WidgetDocument.frameDocument(for: Self.hostile, scripts: true, theme: .dark, scrolls: false)
        #expect(unescaped == frame)
        #expect(frame.hasPrefix(#"<!doctype html><html><head><meta http-equiv="Content-Security-Policy""#), "the frame repeats the policy first")
        #expect(frame.contains("<body>" + Self.hostile + "</body>"), "the agent's markup is left untouched inside the frame")
        #expect(frame.contains("--accent: #8B7CF6"))
    }

    @Test func attributeEscaping() {
        #expect(WidgetDocument.escapeAttribute(#"a&b"c'd<e>f"#) == "a&amp;b&quot;c&#39;d&lt;e&gt;f")
        #expect(WidgetDocument.escapeAttribute("&amp;") == "&amp;amp;", "existing entities are escaped again")
        #expect(WidgetDocument.escapeAttribute("plain é 漢字") == "plain é 漢字")
    }

    @Test func inlineVisualsSizeToContentWindowedOnesScroll() {
        #expect(WidgetDocument.frameDocument(for: "x", scripts: true, theme: .dark, scrolls: false).contains("overflow-y: hidden"))
        #expect(WidgetDocument.frameDocument(for: "x", scripts: true, theme: .dark, scrolls: true).contains("overflow-y: auto"))
    }

    @Test func onlyTheWrapperAndItsFrameMayLoad() {
        #expect(WidgetDocument.allowsNavigation(to: URL(string: "about:blank")))
        #expect(WidgetDocument.allowsNavigation(to: URL(string: "about:srcdoc")))
        for url in ["https://example.com", "http://127.0.0.1:4096/api", "file:///etc/passwd", "data:text/html,hi", "about:srcdoc#x", "javascript:alert(1)"] {
            #expect(!WidgetDocument.allowsNavigation(to: URL(string: url)), "\(url)")
        }
        #expect(!WidgetDocument.allowsNavigation(to: nil))
    }

    @MainActor @Test func theNetworkBlockerCompiles() async throws {
        let data = try #require(WidgetDocument.blockerRules.data(using: .utf8))
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rules.count == 4)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ensemble-widget-blocker-test", encodedContentRuleList: WidgetDocument.blockerRules)
        #expect(list != nil)
        try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "ensemble-widget-blocker-test")
    }
}
