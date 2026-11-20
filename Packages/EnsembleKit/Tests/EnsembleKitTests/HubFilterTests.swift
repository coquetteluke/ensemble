import Foundation
import Testing
@testable import EnsembleKit

@Suite struct HubFilterTests {
    private func sampleSummaries(now: Date) -> [SessionSummary] {
        [
            SessionSummary(
                id: "s1",
                title: "Fix relay reconnect",
                directory: "/Users/sam/work/Ensemble",
                agentNames: ["Claude"],
                activity: .waitingForPermission,
                lastActivity: now.addingTimeInterval(-60),
                pendingAsk: "Run swift test",
                pendingPermissions: 1
            ),
            SessionSummary(
                id: "s2",
                title: "Add sidebar badges",
                directory: "/Users/sam/work/Ensemble/",
                agentNames: ["Gemini"],
                activity: .idle,
                lastActivity: now.addingTimeInterval(-300)
            ),
            SessionSummary(
                id: "s3",
                title: "Update API docs",
                directory: "/Users/sam/client/app",
                agentNames: ["Codex"],
                activity: .idle,
                lastActivity: now.addingTimeInterval(-600)
            ),
            SessionSummary(
                id: "s4",
                title: "Backend worker",
                directory: "/Users/sam/server/app",
                agentNames: ["Claude"],
                activity: .working,
                lastActivity: now.addingTimeInterval(-120)
            ),
            SessionSummary(
                id: "r1",
                title: "Architecture Debate",
                directory: "/Users/sam/work/Ensemble",
                roomID: UUID(),
                agentNames: ["Ada", "Byron"],
                activity: .idle,
                lastActivity: now.addingTimeInterval(-400)
            ),
        ]
    }

    @Test func projectsDeduplicatesTrailingSlashesAndDisambiguatesDuplicates() {
        let now = Date()
        let projects = HubFilter.projects(from: sampleSummaries(now: now), now: now)
        #expect(projects.count == 3)
        // Ensemble has Needs You so it sorts first.
        #expect(projects[0].directory == "/Users/sam/work/Ensemble")
        #expect(projects[0].label == "Ensemble")
        #expect(projects[0].count == 3)
        #expect(projects[0].needsYouCount == 1)

        // Two different folders named "app" get parent disambiguation.
        let labels = Set(projects.map(\.label))
        #expect(labels.contains("server/app"))
        #expect(labels.contains("client/app"))
    }

    @Test func filtersByQueryFolderAndNeedsYou() {
        let now = Date()
        let summaries = sampleSummaries(now: now)

        let byFolder = HubFilter(selectedDirectory: "/Users/sam/work/Ensemble").filter(summaries, now: now)
        #expect(byFolder.map(\.id) == ["s1", "s2", "r1"])

        let byQuery = HubFilter(query: "sidebar gemini").filter(summaries, now: now)
        #expect(byQuery.map(\.id) == ["s2"])

        let byNeedsYou = HubFilter(onlyNeedsYou: true).filter(summaries, now: now)
        #expect(byNeedsYou.map(\.id) == ["s1"])
    }

    @Test func archivableFinishedExcludesRoomsRunningAndNeedsYou() {
        let now = Date()
        let summaries = sampleSummaries(now: now)
        let archivable = HubFilter.archivableFinishedSessionIDs(from: summaries, now: now)
        // s1 is needsYou, s4 is running, r1 is a room -> only s2 and s3 are archivable finished sessions.
        #expect(archivable == ["s2", "s3"])
    }
}
