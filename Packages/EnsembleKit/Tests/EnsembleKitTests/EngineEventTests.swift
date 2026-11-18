import Foundation
import Testing
@testable import EnsembleKit

@Suite struct EngineEventTests {
    /// Decodes the captured stream (`Fixtures/events.sse`) the same way `OpenCodeClient.events()` does.
    private func decodeFixture() throws -> [EngineEventDecoder.Output] {
        var parser = SSEParser()
        var decoder = EngineEventDecoder()
        var outputs: [EngineEventDecoder.Output] = []
        for message in parser.feed(text: try Fixtures.text("events.sse")) {
            outputs += decoder.decode(message.data)
        }
        if let last = parser.finish() { outputs += decoder.decode(last.data) }
        return outputs
    }

    private func events(_ outputs: [EngineEventDecoder.Output]) -> [EngineEvent] {
        outputs.compactMap { if case .event(let e) = $0 { return e } else { return nil } }
    }

    @Test func parsesSSEFraming() {
        var parser = SSEParser()
        let text = ": heartbeat\n\ndata: {\"a\":1}\n\nevent: custom\nid: 7\ndata: line one\ndata: line two\r\n\r\ndata: tail"
        let messages = parser.feed(text: text)
        #expect(messages == [
            SSEMessage(event: nil, data: "{\"a\":1}", id: nil),
            SSEMessage(event: "custom", data: "line one\nline two", id: "7"),
        ])
        #expect(parser.lastEventID == "7")
        #expect(parser.finish() == SSEMessage(event: nil, data: "tail", id: nil))
    }

    @Test func decodesCapturedStream() throws {
        let outputs = try decodeFixture()
        let all = events(outputs)
        #expect(all.first == .other(type: "server.connected"))

        // Subagent child session carries its parent.
        let created = all.compactMap { if case .sessionCreated(let s) = $0 { return s } else { return nil } }
        let child = try #require(created.first { $0.parentID != nil })
        #expect(child.id == "ses_e13556affffeFEMwurgCjXZ3b3")
        #expect(child.parentID == "ses_e13556bb5ffeY1uEs1EG2lGeBf")
        #expect(child.title == "Mock helper task")
        #expect(child.agent == "general")
        #expect(child.directory == "/tmp/ensemble-probe")

        // Text streaming uses the transcript's ids.
        #expect(all.contains(.textDelta(sessionID: "ses_e13556affffeFEMwurgCjXZ3b3", itemID: "msg_1ecaa9509001f23p6HIai3PnrH:text:0",
                                        delta: "Child finished the task.")))
        #expect(all.contains(.textEnded(sessionID: "ses_e13556affffeFEMwurgCjXZ3b3", itemID: "msg_1ecaa9509001f23p6HIai3PnrH:text:0",
                                        text: "Child finished the task.")))
        #expect(all.contains(.reasoningDelta(sessionID: "ses_e13556bb5ffeY1uEs1EG2lGeBf", itemID: "msg_1ecab8156001rTm3pBs8zbnIJC:reasoning:0",
                                             delta: "I should change the greeting.")))

        let tools = all.compactMap { event -> ToolCallInfo? in
            if case .toolUpdated(_, let info) = event { return info }
            return nil
        }
        // Tool name comes from session.tool.input.started even though later events omit it.
        let subagentUpdates = tools.filter { $0.id == "call_bb14e936d687" }
        #expect(subagentUpdates.map(\.status) == [.pending, .running, .running, .succeeded])
        #expect(subagentUpdates.allSatisfy { $0.name == "subagent" })
        #expect(subagentUpdates.last?.childSessionID == "ses_e13556affffeFEMwurgCjXZ3b3")
        #expect(subagentUpdates.last?.title == "Mock helper task")

        let edit = try #require(tools.last { $0.id == "call_481d186a4c96" })
        #expect(edit.name == "edit")
        #expect(edit.status == .succeeded)
        #expect(edit.diff?.contains("+hello from mock") == true)

        let failed = try #require(tools.last { $0.id == "call_c7317112553b" })
        #expect(failed.name == "read")
        #expect(failed.status == .failed)
        #expect(failed.outputPreview == "File not found: does-not-exist.txt")

        let shell = try #require(tools.last { $0.id == "call_eb18edb9ee0f" })
        #expect(shell.name == "shell")
        #expect(shell.title == "echo ensemble-ok")
        #expect(shell.outputPreview == "ensemble-ok\n")

        // Permissions.
        let asked = all.compactMap { if case .permissionAsked(let p) = $0 { return p } else { return nil } }
        let request = try #require(asked.first)
        #expect(request.id == "per_1eca9d413001kCR5o9jXikmnA9")
        #expect(request.sessionID == "ses_e13562c9effe6gN6CSgISlmn7x")
        #expect(request.kind == "shell")
        #expect(request.title == "echo ensemble-ok")
        #expect(request.detail == nil)
        #expect(request.alwaysPatterns == ["echo *"])
        #expect(all.contains(.activity(sessionID: "ses_e13562c9effe6gN6CSgISlmn7x", .waitingForPermission)))
        #expect(all.contains(.permissionReplied(sessionID: "ses_e13562c9effe6gN6CSgISlmn7x", requestID: "per_1eca9d413001kCR5o9jXikmnA9")))

        // Usage is the session's running total.
        let usage = all.compactMap { event -> Usage? in
            if case .usageUpdated(let id, let u) = event, id == "ses_e13556bb5ffeY1uEs1EG2lGeBf" { return u }
            return nil
        }
        #expect(usage.count >= 5)
        #expect(zip(usage, usage.dropFirst()).allSatisfy { $0.inputTokens <= $1.inputTokens })

        // Execution lifecycle.
        #expect(all.contains(.activity(sessionID: "ses_e13556bb5ffeY1uEs1EG2lGeBf", .working)))
        #expect(all.contains(.executionEnded(sessionID: "ses_e13556bb5ffeY1uEs1EG2lGeBf", outcome: "succeeded", error: nil)))
        #expect(all.contains(.executionEnded(sessionID: "ses_e13556bb5ffeY1uEs1EG2lGeBf", outcome: "interrupted", error: nil)))

        // Files and connectors.
        #expect(all.contains(.filesChanged(paths: ["/tmp/ensemble-probe/hello.txt"])))
        #expect(all.contains(.connectorsChanged))
        #expect(all.contains { if case .sessionDeleted = $0 { return true } else { return false } })

        // Session renames are refetched by the client.
        #expect(outputs.contains(.refreshSession(id: "ses_e13556bb5ffeY1uEs1EG2lGeBf", type: "session.renamed")))

        // Everything else is passed through by type.
        #expect(all.contains(.other(type: "session.step.started")))
    }

    @Test func decodesStatusAndFailureEvents() {
        // Shapes from the OpenAPI spec; these did not fire during capture.
        var decoder = EngineEventDecoder()
        #expect(decoder.decode(#"{"id":"e1","type":"session.status","data":{"sessionID":"ses_1","status":{"type":"busy"}}}"#)
            == [.event(.activity(sessionID: "ses_1", .working))])
        #expect(decoder.decode(#"{"id":"e2","type":"session.status","data":{"sessionID":"ses_1","status":{"type":"retry","attempt":1,"message":"rate limited","next":5}}}"#)
            == [.event(.activity(sessionID: "ses_1", .working))])
        #expect(decoder.decode(#"{"id":"e3","type":"session.status","data":{"sessionID":"ses_1","status":{"type":"idle"}}}"#)
            == [.event(.activity(sessionID: "ses_1", .idle))])
        #expect(decoder.decode(#"{"id":"e4","type":"session.idle","data":{"sessionID":"ses_1"}}"#)
            == [.event(.activity(sessionID: "ses_1", .idle))])
        #expect(decoder.decode(#"{"id":"e5","created":1,"type":"session.execution.failed","data":{"sessionID":"ses_1","error":{"type":"provider","message":"401 Unauthorized"}},"durable":{"aggregateID":"ses_1","seq":3,"version":1}}"#)
            == [.event(.executionEnded(sessionID: "ses_1", outcome: "failed", error: "401 Unauthorized")),
                .event(.activity(sessionID: "ses_1", .failed))])
        #expect(decoder.decode(#"{"type":"mcp.status.changed","data":{"server":"x"}}"#) == [.event(.connectorsChanged)])
        #expect(decoder.decode(#"{"type":"something.new","data":{}}"#) == [.event(.other(type: "something.new"))])
        #expect(decoder.decode("not json") == [])
    }
}
