import Foundation
import Testing
@testable import EnsembleKit

@Suite struct TranscriptExportTests {
    @Test func soloChatIncludesMetadataAndMessages() {
        let now = Date()
        let items: [TranscriptItem] = [
            .user(id: "u1", text: "Fix the reconnect loop", date: now),
            .reasoning(id: "r1", text: "Internal chain of thought", streaming: false),
            .agentText(id: "a1", text: "Added exponential backoff to the SSE client.", agentID: nil, streaming: false),
            .user(id: "u2", text: "Great, add a test too.", date: now),
            .agentText(id: "a2", text: "Added unit tests in `StreamTests.swift`.", agentID: nil, streaming: false),
        ]

        let md = TranscriptExport.markdown(
            title: "Reconnect Fix",
            directory: "/Users/sam/Ensemble",
            modelName: "Claude Sonnet",
            items: items
        )

        #expect(md.hasPrefix("# Reconnect Fix\n\n"))
        #expect(md.contains("Folder: `/Users/sam/Ensemble` \u{00B7} Model: Claude Sonnet"))
        #expect(md.contains("## You\n\nFix the reconnect loop"))
        #expect(md.contains("## Assistant\n\nAdded exponential backoff to the SSE client."))
        #expect(md.contains("## You\n\nGreat, add a test too."))
        #expect(md.contains("## Assistant\n\nAdded unit tests in `StreamTests.swift`."))
        #expect(!md.contains("Internal chain of thought"))
        #expect(!md.contains("\u{2014}"))
        #expect(!md.contains("\u{2013}"))
    }

    @Test func roomChatResolvesAgentNamesAndBoardMessages() {
        let now = Date()
        let leadID = UUID()
        let reviewerID = UUID()
        let unknownID = UUID()
        let agents: [UUID: AgentSpec] = [
            leadID: AgentSpec(id: leadID, name: "Architect", model: ModelRef(providerID: "anthropic", id: "claude-opus"), colorHex: "#8B7CF6"),
            reviewerID: AgentSpec(id: reviewerID, name: "Reviewer", model: ModelRef(providerID: "google", id: "gemini-4"), colorHex: "#328CF0"),
        ]

        let items: [TranscriptItem] = [
            .user(id: "u1", text: "Design the export helper", date: now),
            .agentText(id: "a1", text: "Let's keep it in EnsembleKit/Model.", agentID: leadID, streaming: false),
            .board(id: "b1", fromAgentID: leadID, toAgentIDs: [reviewerID], text: "Check edge cases for empty placeholders.", date: now),
            .board(id: "b2", fromAgentID: reviewerID, toAgentIDs: [], text: "Looks solid.", date: now),
            .agentText(id: "a2", text: "Verified all edge cases.", agentID: reviewerID, streaming: false),
            .agentText(id: "a3", text: "Fallback speaker check.", agentID: unknownID, streaming: false),
        ]

        let md = TranscriptExport.markdown(
            title: "Export Design",
            items: items,
            agents: agents
        )

        #expect(md.contains("## Architect\n\nLet's keep it in EnsembleKit/Model."))
        #expect(md.contains("> *Architect to Reviewer: Check edge cases for empty placeholders.*"))
        #expect(md.contains("> *Reviewer: Looks solid.*"))
        #expect(md.contains("## Reviewer\n\nVerified all edge cases."))
        #expect(md.contains("## Assistant\n\nFallback speaker check."))
    }

    @Test func toolCallsErrorsNoticesAndStreamingPlaceholders() {
        let now = Date()
        let items: [TranscriptItem] = [
            .notice(id: "n1", text: "Switched to Gemini 4 for this message"),
            .tool(ToolCallInfo(id: "t1", name: "read", title: "TranscriptViews.swift", status: .succeeded)),
            .tool(ToolCallInfo(id: "t2", name: "bash", title: "", status: .failed)),
            .permission(PermissionRequest(id: "p1", sessionID: "s1", kind: "bash", title: "swift test", created: now)),
            .agentText(id: "a1", text: "   \n  ", agentID: nil, streaming: true),
            .error(id: "e1", message: "Connection timed out.\nCheck your network."),
        ]

        let md = TranscriptExport.markdown(
            title: "Tool Run",
            directory: "/tmp/repo",
            items: items
        )

        #expect(md.contains("Folder: `/tmp/repo`"))
        #expect(!md.contains("Model:"))
        #expect(md.contains("> *Switched to Gemini 4 for this message*"))
        #expect(md.contains("- Tool: TranscriptViews.swift (succeeded)\n- Tool: bash (failed)"))
        #expect(md.contains("> Error: Connection timed out.\n> Check your network."))
        #expect(!md.contains("## Assistant"))
        #expect(!md.contains("swift test"))
    }

    @Test func emptyTranscriptAndBlankTitleFallback() {
        let md = TranscriptExport.markdown(
            title: "   ",
            modelName: "Grok 5",
            items: []
        )

        #expect(md == "# Conversation\n\nModel: Grok 5\n")
    }

    @Test func switchedModelNameParsesPermanentAndOneTurnNotices() {
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to Gemini 4") == "Gemini 4")
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to Haiku 5.5 for this message") == "Haiku 5.5")
        #expect(TranscriptExport.switchedModelName(fromNotice: "  Switched to Claude Sonnet 4.6 for this message  ") == "Claude Sonnet 4.6")
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to Grok 5") == "Grok 5")
    }

    @Test func switchedModelNameIgnoresNonModelNotices() {
        #expect(TranscriptExport.switchedModelName(fromNotice: "") == nil)
        #expect(TranscriptExport.switchedModelName(fromNotice: "Interrupted") == nil)
        #expect(TranscriptExport.switchedModelName(fromNotice: "Compacting conversation") == nil)
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to ") == nil)
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to  for this message") == nil)
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to agent build") == nil)
        #expect(TranscriptExport.switchedModelName(fromNotice: "Switched to agent ") == nil)
    }
}
