#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The review pane's ties to the store: turn snapshots taken as turns start, and the commit message asked of a
/// hidden copy of the session. Runs on the preview engine; the folder is a throwaway git repository.
@Suite @MainActor struct GitReviewStoreTests {
    let helper = GitReviewServiceTests()

    @Test func eachTurnStartSnapshotsTheSessionFolder() async throws {
        let repo = try helper.makeRepo(files: ["a.txt": "a\n"])
        let store = SessionStore(engine: PreviewEngine(delayScale: 0.02))
        await store.start()
        let session = try await store.newSession(directory: repo.path, model: nil, permissionMode: .bypass)
        let snapshots = GitTurnSnapshots(fileURL: nil, service: helper.service)
        snapshots.follow(store)
        snapshots.follow(store)

        await store.send("First turn", to: session.id)
        try await waitUntil("the first snapshot") { snapshots.marks[session.id]?.count == 1 }
        try await waitUntil("the first turn to end") { !session.isWorking }
        try helper.write("a2\n", "a.txt", in: repo)
        await store.send("Second turn", to: session.id)
        try await waitUntil("the second snapshot") { snapshots.marks[session.id]?.count == 2 }
        try await waitUntil("the second turn to end") { !session.isWorking }

        let marks = try #require(snapshots.marks[session.id])
        #expect(marks.count == 2, "one snapshot per turn, not per activity change")
        let top = await helper.service.topLevel(repo.path)
        #expect(marks[0].root == top && marks[1].root == top)
        #expect(marks[0].tree != marks[1].tree, "the second snapshot has the edit made between the turns")
        // Hidden sessions (side questions, commit message copies) are not followed.
        #expect(snapshots.marks.keys.allSatisfy { !store.hiddenSessionIDs.contains($0) })
        store.stopListening()
    }

    @Test func commitMessageComesFromAHiddenCopyThatIsDeletedAfter() async throws {
        let engine = PreviewEngine(delayScale: 0.02)
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/review-demo", model: nil, permissionMode: .bypass)
        await store.send("Build the panel", to: session.id)
        try await waitUntil("the first turn") { !session.isWorking }
        let itemsBefore = session.items
        let sidebarBefore = store.sidebarOrder.map(\.id)
        let sessionsBefore = try await engine.listSessions().count

        let files = [ReviewFileDiff(root: "/tmp/review-demo", path: "Panel.swift", kind: .modified, additions: 2, deletions: 1,
                                    patch: "@@ -1 +1,2 @@\n-a\n+b\n+c\n")]
        let message = try await store.draftCommitMessage(sessionID: session.id, directory: session.directory, files: files)
        #expect(!message.isEmpty)
        #expect(!message.contains("\n") && !message.hasSuffix("."))
        #expect(session.items == itemsBefore, "nothing was added to the session")
        #expect(store.sidebarOrder.map(\.id) == sidebarBefore, "the copy never showed in the sidebar")

        try await waitUntil("the copy to be deleted") { store.hiddenSessionIDs.isEmpty }
        #expect(try await engine.listSessions().count == sessionsBefore)
        store.stopListening()
    }
}
#endif
