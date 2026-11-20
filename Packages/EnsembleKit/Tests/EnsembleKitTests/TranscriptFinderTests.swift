import Foundation
import Testing
@testable import EnsembleKit

@Suite struct TranscriptFinderTests {
    private func sampleItems() -> [TranscriptItem] {
        let now = Date()
        return [
            .user(id: "u1", text: "Fix the auth token refresh race", date: now),
            .reasoning(id: "r1", text: "Checking Keychain expiry logic", streaming: false),
            .tool(ToolCallInfo(
                id: "t1",
                name: "edit",
                title: "Sources/AuthClient.swift",
                inputJSON: "{\"path\":\"Sources/AuthClient.swift\"}",
                status: .succeeded,
                outputPreview: "Updated refreshToken()",
                diff: "+ guard !isRefreshing else { return }"
            )),
            .agentText(id: "a1", text: "Added a lock around token refresh in AuthClient.", agentID: nil, streaming: false),
            .permission(PermissionRequest(
                id: "p1",
                sessionID: "s1",
                kind: "bash",
                title: "swift test --filter AuthClientTests",
                detail: "Run unit tests"
            )),
            .notice(id: "n1", text: "Switched to Gemini 4"),
            .error(id: "e1", message: "Network timeout while refreshing token"),
        ]
    }

    @Test func emptyAndWhitespaceQueriesReturnEmptyResult() {
        let items = sampleItems()
        #expect(TranscriptFinder.search("", in: items).isEmpty)
        #expect(TranscriptFinder.search("   \n\t  ", in: items).isEmpty)
        #expect(TranscriptFinder.search("   ", in: items).statusText(at: 0) == "")
    }

    @Test func findsMatchesAcrossAllItemKindsCaseInsensitively() {
        let result = TranscriptFinder.search("TOKEN", in: sampleItems())
        #expect(result.matches.map(\.itemID) == ["u1", "t1", "a1", "e1"])
        #expect(result.matchedItemIDs == Set(["u1", "t1", "a1", "e1"]))
        #expect(result.statusText(at: 0) == "1 of 4")
        #expect(result.statusText(at: 2) == "3 of 4")
    }

    @Test func multiTermQueryRequiresAllTerms() {
        let result = TranscriptFinder.search("refresh AuthClient", in: sampleItems())
        #expect(result.matches.map(\.itemID) == ["t1", "a1"])
        #expect(result.totalOccurrences >= 2)
    }

    @Test func findsToolDiffAndPermissionDetail() {
        let diffResult = TranscriptFinder.search("isRefreshing", in: sampleItems())
        #expect(diffResult.matches.map(\.itemID) == ["t1"])

        let permResult = TranscriptFinder.search("AuthClientTests", in: sampleItems())
        #expect(permResult.matches.map(\.itemID) == ["p1"])
    }

    @Test func navigationWrapsAndClampsSafely() {
        let result = TranscriptFinder.search("token", in: sampleItems())
        #expect(result.matchCount == 4)
        #expect(result.nextIndex(after: 0) == 1)
        #expect(result.nextIndex(after: 3) == 0)
        #expect(result.previousIndex(before: 0) == 3)
        #expect(result.previousIndex(before: 2) == 1)
        #expect(result.clampedIndex(99) == 3)
        #expect(result.clampedIndex(-5) == 0)
        #expect(result.activeItemID(at: 99) == "e1")

        let empty = TranscriptFinder.search("nonexistent_xyz", in: sampleItems())
        #expect(empty.statusText(at: 0) == "No matches")
        #expect(empty.activeItemID(at: 0) == nil)
        #expect(empty.nextIndex(after: 0) == 0)
        #expect(empty.previousIndex(before: 0) == 0)
    }

    @Test func searchesBoardMessagesIncludingAgentNames() {
        let ada = AgentSpec(id: UUID(), name: "Ada", model: ModelRef(providerID: "anthropic", id: "claude-opus"), colorHex: "#A78BFA")
        let byron = AgentSpec(id: UUID(), name: "Byron", model: ModelRef(providerID: "google", id: "gemini-4"), colorHex: "#34D399")
        let agents = [ada.id: ada, byron.id: byron]
        let m1 = BoardMessage(from: .agent(ada.id), to: [byron.id], kind: .review, text: "Check the retry timer.")
        let m2 = BoardMessage(from: .room, kind: .notice, text: "Round 2 started")

        let byName = TranscriptFinder.search("Byron retry", in: [m1, m2], agents: agents)
        #expect(byName.matches.map(\.itemID) == [m1.id.uuidString])
    }

    @Test func highlightPropagatesScrollTokenForRepeatedNavigation() {
        let result = TranscriptFinder.search("isRefreshing", in: sampleItems())
        #expect(result.matchCount == 1)

        let initial = result.highlight(at: 0)
        #expect(initial.activeItemID == "t1")
        #expect(initial.matchedItemIDs == Set(["t1"]))
        #expect(initial.scrollToken == 0)

        let next = result.highlight(at: result.nextIndex(after: 0), scrollToken: 1)
        #expect(next.activeItemID == "t1")
        #expect(next.scrollToken == 1)
        #expect(next != initial)

        let explicit = TranscriptFindHighlight(matchedItemIDs: ["t1"], activeItemID: "t1", scrollToken: 4)
        #expect(explicit.scrollToken == 4)
    }
}
