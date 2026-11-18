import Foundation
import Testing
@testable import EnsembleKit

/// Background tasks and plan limit stops from the Claude CLI's stream. `stream-usage-limit.jsonl` is synthetic: no real
/// limit was spent. It follows the shapes in claude 2.1.319's SDK schema and message builder (see `AutoContinue.swift`):
/// a `rate_limit_event` with status `rejected`, the CLI's own assistant message with `"error":"rate_limit"`, and a
/// `result` with `is_error` and `api_error_status` 429 whose text is "You've hit your 5-hour limit · resets ...".
@Suite("Claude background tasks and limits")
struct ClaudeBackgroundTests {
    typealias F = ClaudeFixtures

    @Test func usageLimitResultBecomesALimitStop() throws {
        let (outputs, decoder) = try F.decode("stream-usage-limit.jsonl")
        let events = F.events(outputs)
        let ended = try #require(events.compactMap { event -> (String, String?)? in
            if case .executionEnded(F.root, let outcome, let error) = event { (outcome, error) } else { nil }
        }.first)
        #expect(ended.0 == "failed")
        #expect(ended.1?.hasPrefix("Your Claude plan's usage limit is reached.") == true)
        #expect(ended.1.map(UsageLimitText.isUsageLimit) == true)
        #expect(outputs.contains { if case .rateLimit(let limits) = $0 { limits.isLimited } else { false } })

        let stop = try #require(decoder.lastLimitStop)
        #expect(stop.resetsAt == Date(timeIntervalSince1970: 1_795_543_200))
        #expect(stop.window == "five_hour")
        #expect(stop.message?.contains("5-hour limit") == true)
        #expect(decoder.lastRateLimit?.windows.map(\.name) == ["five_hour", "seven_day"])
    }

    @Test func nextTurnClearsTheStopAndOtherFailuresAreNotLimits() throws {
        var (_, decoder) = try F.decode("stream-usage-limit.jsonl")
        _ = decoder.decode(line: #"{"type":"result","subtype":"success","is_error":false,"result":"ok","model_usage_since_last_result":{}}"#)
        #expect(decoder.lastLimitStop == nil)

        var other = ClaudeStreamDecoder(rootID: "s", directory: "/p")
        _ = other.decode(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"],"model_usage_since_last_result":{}}"#)
        #expect(other.lastLimitStop == nil)
        // The typed kind alone is enough, and an older CLI's text carries its own reset time.
        _ = other.decode(line: #"{"type":"result","subtype":"success","is_error":true,"api_error":"usage_limit_reached","result":"Claude AI usage limit reached|1795543200","model_usage_since_last_result":{}}"#)
        #expect(other.lastLimitStop?.resetsAt == Date(timeIntervalSince1970: 1_795_543_200))
    }

    static let bashLines = [
        #"{"type":"assistant","message":{"id":"msg_bg","role":"assistant","content":[{"type":"tool_use","id":"toolu_bash1","name":"Bash","input":{"command":"npm run dev","run_in_background":true}}]},"parent_tool_use_id":null}"#,
        #"{"type":"system","subtype":"task_started","task_id":"b1","tool_use_id":"toolu_bash1","description":"npm run dev","task_type":"local_bash","is_backgrounded":true}"#,
        #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash","description":"npm run dev"},{"task_id":"w1","task_type":"local_workflow","description":"Review workflow"}]}"#,
    ]

    @Test func backgroundShellIsBackgroundWorkNotASubagent() {
        var decoder = ClaudeStreamDecoder(rootID: "root", directory: "/p")
        var outputs: [ClaudeStreamDecoder.Output] = []
        for line in Self.bashLines { outputs += decoder.decode(line: line) }
        let events = F.events(outputs)
        #expect(!events.contains { if case .sessionCreated = $0 { true } else { false } })
        #expect(events.contains(.other(type: ClaudeEventTypes.backgroundTasks)))
        let running = decoder.tasks.running()
        #expect(running.map(\.id) == ["b1", "w1"])
        #expect(running.first?.kind == .shell)
        #expect(running.first?.sessionID == "root")
        #expect(running.first?.title == "npm run dev")
        #expect(running.last?.kind == .task)

        // Stopped or finished: it leaves the list, and no subagent session hears about it.
        let notified = decoder.decode(line: #"{"type":"system","subtype":"task_notification","task_id":"b1","tool_use_id":"toolu_bash1","status":"stopped","output_file":"","summary":""}"#)
        #expect(notified == [.event(.other(type: ClaudeEventTypes.backgroundTasks))])
        #expect(decoder.tasks.running().map(\.id) == ["w1"])
        _ = decoder.decode(line: #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
        #expect(decoder.tasks.running().isEmpty)
    }

    @Test func foregroundCommandIsListedOnceBackgrounded() {
        var decoder = ClaudeStreamDecoder(rootID: "root", directory: "/p")
        _ = decoder.decode(line: #"{"type":"system","subtype":"task_started","task_id":"b2","tool_use_id":"toolu_2","description":"swift build","task_type":"local_bash","is_backgrounded":false}"#)
        #expect(decoder.tasks.running().isEmpty)
        let moved = decoder.decode(line: #"{"type":"system","subtype":"task_updated","task_id":"b2","patch":{"is_backgrounded":true}}"#)
        #expect(moved == [.event(.other(type: ClaudeEventTypes.backgroundTasks))])
        #expect(decoder.tasks.running().map(\.id) == ["b2"])
        _ = decoder.decode(line: #"{"type":"system","subtype":"task_updated","task_id":"b2","patch":{"status":"killed"}}"#)
        #expect(decoder.tasks.running().isEmpty)
    }

    @Test func subagentTaskIdIsKeptForStop() throws {
        // The recorded subagent run, up to its `task_updated` (status completed) and `task_notification`.
        let lines = try F.lines("stream-subagent.jsonl")
        let end = try #require(lines.firstIndex { $0.contains("\"subtype\":\"task_updated\"") })
        var decoder = ClaudeStreamDecoder(rootID: F.root, directory: F.directory)
        let child = ClaudeSessionIDs.child(root: F.root, toolUseID: "toolu_01WJd3ydmJdPAFjh93jKrT5Y")
        for line in lines[..<end] { _ = decoder.decode(line: line) }
        #expect(decoder.tasks.taskID(forChild: child) == "acac3665c8053e218")
        #expect(decoder.tasks.running().isEmpty)
        // Once it ends there is nothing to stop.
        _ = decoder.decode(line: lines[end])
        #expect(decoder.tasks.taskID(forChild: child) == nil)
    }
}
