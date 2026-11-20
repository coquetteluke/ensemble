import Foundation
import Testing
@testable import EnsembleKit

@Suite struct RoomBoardFilterTests {
    private func makeFixture() -> (ada: AgentSpec, byron: AgentSpec, messages: [BoardMessage]) {
        let ada = AgentSpec(id: UUID(), name: "Ada", model: ModelRef(providerID: "anthropic", id: "claude-opus"), colorHex: "#A78BFA")
        let byron = AgentSpec(id: UUID(), name: "Byron", model: ModelRef(providerID: "google", id: "gemini-4"), colorHex: "#34D399")
        let now = Date()
        let messages = [
            BoardMessage(from: .user, kind: .chat, text: "Build the cache layer", date: now),
            BoardMessage(from: .room, kind: .notice, text: "Team run started", date: now.addingTimeInterval(1)),
            BoardMessage(from: .agent(ada.id), kind: .plan, text: "ASSIGN @Byron: write LRU eviction", date: now.addingTimeInterval(2)),
            BoardMessage(from: .agent(byron.id), to: [ada.id], kind: .question, text: "Should TTL be sliding?", date: now.addingTimeInterval(3)),
            BoardMessage(from: .agent(ada.id), to: [byron.id], kind: .review, text: "Yes, sliding TTL looks right.", date: now.addingTimeInterval(4)),
            BoardMessage(from: .agent(byron.id), kind: .update, text: "Tests pass for eviction.", date: now.addingTimeInterval(5)),
            BoardMessage(from: .agent(ada.id), kind: .verdict, text: "Approved and ready to merge.", date: now.addingTimeInterval(6)),
        ]
        return (ada, byron, messages)
    }

    @Test func filtersByAgentIncludesSentAndAddressed() {
        let (ada, byron, messages) = makeFixture()
        let agents = [ada.id: ada, byron.id: byron]

        let byronFilter = RoomBoardFilter(agentID: byron.id)
        let filtered = byronFilter.filter(messages, agents: agents)
        // Messages from Byron (question, update) plus review addressed to Byron.
        #expect(filtered.count == 3)
        #expect(filtered.map(\.kind) == [.question, .review, .update])
    }

    @Test func filtersByCategoryCorrectly() {
        let (ada, byron, messages) = makeFixture()
        let agents = [ada.id: ada, byron.id: byron]

        let decisions = RoomBoardFilter(category: .decisions).filter(messages, agents: agents)
        #expect(decisions.map(\.kind) == [.plan, .verdict])

        let discussions = RoomBoardFilter(category: .discussions).filter(messages, agents: agents)
        #expect(discussions.map(\.kind) == [.question, .review])

        let noNotices = RoomBoardFilter(category: .hideNotices).filter(messages, agents: agents)
        #expect(noNotices.count == 6)
        #expect(!noNotices.contains { $0.from == .room })
    }

    @Test func combinesAgentCategoryAndQuery() {
        let (ada, byron, messages) = makeFixture()
        let agents = [ada.id: ada, byron.id: byron]

        let filter = RoomBoardFilter(agentID: ada.id, category: .discussions, query: "sliding")
        let filtered = filter.filter(messages, agents: agents)
        #expect(filtered.count == 2)
    }

    @Test func latestMessageAndCountsPerAgent() {
        let (ada, byron, messages) = makeFixture()
        #expect(RoomBoardFilter.latestMessageID(for: ada.id, in: messages) == messages[6].id)
        #expect(RoomBoardFilter.latestMessageID(for: byron.id, in: messages) == messages[5].id)

        let counts = RoomBoardFilter.messageCountsByAgent(in: messages)
        #expect(counts[ada.id] == 3)
        #expect(counts[byron.id] == 2)
    }

    @Test func remoteTranscriptFilteringAndJumpToAgent() {
        let adaID = UUID()
        let byronID = UUID()
        let now = Date()
        let agents: [UUID: RemoteAgent] = [
            adaID: RemoteAgent(id: adaID, name: "Ada", model: "claude-opus", colorHex: "#A78BFA", activity: .idle, sessionID: "s-ada"),
            byronID: RemoteAgent(id: byronID, name: "Byron", model: "gemini-4", colorHex: "#34D399", activity: .working, sessionID: "s-byron"),
        ]
        let items: [TranscriptItem] = [
            .user(id: "u1", text: "Compare approaches", date: now),
            .notice(id: "n1", text: "Debate round 1"),
            .agentText(id: "a1", text: "PLAN: start with SQLite.", agentID: adaID, streaming: false),
            .board(id: "b1", fromAgentID: byronID, toAgentIDs: [adaID], text: "What about WAL locking?", date: now),
            .permission(PermissionRequest(id: "p1", sessionID: "s-byron", kind: "bash", title: "swift test")),
        ]

        let byronOnly = RoomBoardFilter(agentID: byronID).filter(items, agents: agents)
        #expect(byronOnly.map(\.id) == ["b1", "p1"])

        let noNotices = RoomBoardFilter(category: .hideNotices).filter(items, agents: agents)
        #expect(!noNotices.contains { $0.id == "n1" })

        #expect(RoomBoardFilter.latestItemID(for: adaID, in: items) == "a1")
        #expect(RoomBoardFilter.latestItemID(for: byronID, in: items) == "b1")
        #expect(RoomBoardFilter.itemCountsByAgent(in: items) == [adaID: 1, byronID: 1])
    }
}
