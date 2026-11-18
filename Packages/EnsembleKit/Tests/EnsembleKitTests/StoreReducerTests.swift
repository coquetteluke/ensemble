import Foundation
import Testing
@testable import EnsembleKit

/// The event reducer: every `EngineEvent` applied to `SessionStore`.
@MainActor
@Suite struct StoreReducerTests {
    private static let dir = "/tmp/project"

    private func makeStore(sessions: [EngineSession] = [EngineSession(id: "s1", title: "One", directory: dir)]) -> SessionStore {
        let seed = StoreSeed(sessions: sessions)
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0))
        store.seed(seed)
        return store
    }

    private func items(_ store: SessionStore, _ id: String = "s1") -> [TranscriptItem] {
        store.session(id)?.items ?? []
    }

    @Test func textDeltasStreamIntoOneItemAndTextEndedFinalises() throws {
        let store = makeStore()
        store.apply(.textDelta(sessionID: "s1", itemID: "t1", delta: "Hello "))
        store.apply(.textDelta(sessionID: "s1", itemID: "t1", delta: "world"))
        #expect(items(store).count == 1)
        guard case .agentText(_, let text, _, let streaming) = try #require(items(store).first) else {
            Issue.record("expected agent text"); return
        }
        #expect(text == "Hello world")
        #expect(streaming)

        store.apply(.textEnded(sessionID: "s1", itemID: "t1", text: "Hello world!"))
        guard case .agentText(_, let final, _, let stillStreaming) = try #require(items(store).first) else {
            Issue.record("expected agent text"); return
        }
        #expect(final == "Hello world!")
        #expect(!stillStreaming)
    }

    @Test func textEndedWithoutDeltasAppendsFinalText() {
        let store = makeStore()
        store.apply(.textEnded(sessionID: "s1", itemID: "t9", text: "Done."))
        #expect(items(store) == [.agentText(id: "t9", text: "Done.", agentID: nil, streaming: false)])
    }

    @Test func separateItemIDsMakeSeparateRows() {
        let store = makeStore()
        store.apply(.textDelta(sessionID: "s1", itemID: "a", delta: "First"))
        store.apply(.textDelta(sessionID: "s1", itemID: "b", delta: "Second"))
        #expect(items(store).map(\.id) == ["a", "b"])
    }

    @Test func reasoningStreamsAndStopsWhenAToolStarts() throws {
        let store = makeStore()
        store.apply(.reasoningDelta(sessionID: "s1", itemID: "r1", delta: "Let me "))
        store.apply(.reasoningDelta(sessionID: "s1", itemID: "r1", delta: "think"))
        #expect(items(store) == [.reasoning(id: "r1", text: "Let me think", streaming: true)])

        store.apply(.toolUpdated(sessionID: "s1", ToolCallInfo(id: "tool1", name: "bash", title: "ls", status: .running)))
        #expect(items(store).first == .reasoning(id: "r1", text: "Let me think", streaming: false))
        #expect(items(store).count == 2)
    }

    @Test func toolUpdatesReplaceTheCardByID() throws {
        let store = makeStore()
        store.apply(.toolUpdated(sessionID: "s1", ToolCallInfo(id: "tool1", name: "bash", title: "swift build", status: .running)))
        store.apply(.textDelta(sessionID: "s1", itemID: "t1", delta: "Building"))
        store.apply(.toolUpdated(sessionID: "s1", ToolCallInfo(id: "tool1", name: "bash", title: "swift build", status: .succeeded,
                                                                outputPreview: "Build complete!")))
        #expect(items(store).count == 2)
        guard case .tool(let tool) = try #require(items(store).first) else {
            Issue.record("expected tool"); return
        }
        #expect(tool.status == .succeeded)
        #expect(tool.outputPreview == "Build complete!")
    }

    @Test func permissionAskedAddsCardCountAndWaitingState() throws {
        let store = makeStore()
        let request = PermissionRequest(id: "p1", sessionID: "s1", kind: "bash", title: "rm -rf build")
        store.apply(.activity(sessionID: "s1", .working))
        store.apply(.permissionAsked(request))
        store.apply(.permissionAsked(request))

        let session = try #require(store.session("s1"))
        #expect(session.pendingPermissions == [request])
        #expect(items(store) == [.permission(request)])
        #expect(session.activity == .waitingForPermission)
        #expect(store.needsYouCount("s1") == 1)
        #expect(store.needsYouTotal == 1)
    }

    @Test func permissionRepliedClearsTheCountAndMarksTheCard() throws {
        let store = makeStore()
        let request = PermissionRequest(id: "p1", sessionID: "s1", kind: "bash", title: "rm -rf build")
        store.apply(.activity(sessionID: "s1", .working))
        store.apply(.permissionAsked(request))
        store.apply(.permissionReplied(sessionID: "s1", requestID: "p1"))

        let session = try #require(store.session("s1"))
        #expect(session.pendingPermissions.isEmpty)
        #expect(session.resolutions["p1"] == .answered)
        #expect(session.activity == .working)
        #expect(items(store) == [.permission(request)], "the card stays, drawn as answered")
        #expect(store.needsYouCount("s1") == 0)
    }

    @Test func replyingFromTheAppRecordsTheDecision() async throws {
        let store = makeStore()
        let request = PermissionRequest(id: "p1", sessionID: "s1", kind: "edit", title: "README.md")
        store.apply(.permissionAsked(request))
        await store.reply(to: request, decision: .always)
        let session = try #require(store.session("s1"))
        #expect(session.resolutions["p1"] == .allowedAlways)
        #expect(session.pendingPermissions.isEmpty)
        // The engine's own "replied" event must not overwrite the known decision.
        store.apply(.permissionReplied(sessionID: "s1", requestID: "p1"))
        #expect(session.resolutions["p1"] == .allowedAlways)
    }

    @Test func usageUpdatedReplacesSessionUsage() throws {
        let store = makeStore()
        let usage = Usage(inputTokens: 1200, outputTokens: 300, costUSD: 0.05)
        store.apply(.usageUpdated(sessionID: "s1", usage))
        #expect(store.session("s1")?.usage == usage)
        #expect(store.session("s1")?.info.usage == usage)
    }

    @Test func activityIdleStopsStreaming() {
        let store = makeStore()
        store.apply(.activity(sessionID: "s1", .working))
        #expect(store.session("s1")?.workingSince != nil)
        store.apply(.textDelta(sessionID: "s1", itemID: "t1", delta: "Partial"))
        store.apply(.activity(sessionID: "s1", .idle))
        #expect(items(store) == [.agentText(id: "t1", text: "Partial", agentID: nil, streaming: false)])
        #expect(store.session("s1")?.workingSince == nil)
    }

    @Test func executionEndedWithErrorAddsErrorRowAndFails() throws {
        let store = makeStore()
        store.apply(.activity(sessionID: "s1", .working))
        store.apply(.textDelta(sessionID: "s1", itemID: "t1", delta: "Trying"))
        store.apply(.executionEnded(sessionID: "s1", outcome: "failed", error: "Rate limit reached"))
        let session = try #require(store.session("s1"))
        #expect(session.activity == .failed)
        #expect(session.items.count == 2)
        if case .error(_, let message) = session.items[1] { #expect(message == "Rate limit reached") } else { Issue.record("expected error row") }
        if case .agentText(_, _, _, let streaming) = session.items[0] { #expect(!streaming) }
    }

    @Test func interruptedExecutionAddsNotice() throws {
        let store = makeStore()
        store.apply(.activity(sessionID: "s1", .working))
        store.apply(.executionEnded(sessionID: "s1", outcome: "interrupted", error: nil))
        let session = try #require(store.session("s1"))
        #expect(session.activity == .idle)
        if case .notice(_, let text) = try #require(session.items.last) { #expect(text == "Interrupted") } else { Issue.record("expected notice") }
    }

    @Test func subagentSessionsAreChildrenAndCountTowardsTheParent() throws {
        let store = makeStore()
        store.apply(.sessionCreated(EngineSession(id: "child", parentID: "s1", title: "Check colours", directory: Self.dir)))
        #expect(store.children(of: "s1").map(\.id) == ["child"])
        #expect(store.projects.flatMap(\.sessions).map(\.id) == ["s1"], "subagents are not listed as projects' sessions")

        store.apply(.activity(sessionID: "child", .working))
        #expect(store.isRunning("s1"))
        store.apply(.permissionAsked(PermissionRequest(id: "cp", sessionID: "child", kind: "bash", title: "ls")))
        #expect(store.needsYouCount("s1") == 1)
    }

    @Test func newSessionsDefaultToAutoMode() async throws {
        let store = makeStore()
        #expect(store.defaultPermissionMode == .auto)
        store.apply(.sessionCreated(EngineSession(id: "fromEvent", title: "New", directory: Self.dir)))
        #expect(store.session("fromEvent")?.permissionMode == .auto)
        let created = try await store.newSession(directory: Self.dir, model: nil, permissionMode: store.defaultPermissionMode)
        #expect(created.permissionMode == .auto)
    }

    @Test func sessionUpdatedAndDeleted() throws {
        let store = makeStore(sessions: [
            EngineSession(id: "s1", title: "One", directory: Self.dir, updated: Date()),
            EngineSession(id: "s2", title: "Two", directory: Self.dir, updated: Date().addingTimeInterval(-60)),
        ])
        store.select("s1")
        store.apply(.sessionUpdated(EngineSession(id: "s1", title: "Renamed", directory: Self.dir)))
        #expect(store.session("s1")?.title == "Renamed")

        store.apply(.sessionDeleted(sessionID: "s1"))
        #expect(store.session("s1") == nil)
        #expect(store.selectedSessionID == "s2", "selection moves to the next session")
    }

    // Events arrive through the stream after the store's own optimistic edits. A late echo of an
    // earlier change must not undo a newer local change or bring a deleted session back.

    @Test func lateEventCannotUndoALocalArchive() async throws {
        let store = makeStore()
        // The engine's echo of an earlier rename: built before the archive, so it predates it.
        let earlierEcho = EngineSession(id: "s1", title: "Renamed", directory: Self.dir, updated: Date(), archived: false)
        await store.archive("s1")
        store.apply(.sessionUpdated(earlierEcho))
        let session = try #require(store.session("s1"))
        #expect(session.info.archived, "the late echo must not unarchive")
        #expect(session.title == "Renamed", "fields the user did not change still follow the engine")
        #expect(!store.sidebarOrder.contains { $0.id == "s1" })
    }

    @Test func newerEngineChangeStillWinsOverAnOlderLocalEdit() async throws {
        let store = makeStore()
        await store.archive("s1")
        // Unarchived somewhere else after the local change.
        let later = EngineSession(id: "s1", title: "One", directory: Self.dir, updated: Date().addingTimeInterval(1), archived: false)
        store.apply(.sessionUpdated(later))
        #expect(store.session("s1")?.info.archived == false)
    }

    @Test func lateEventCannotBringBackADeletedSession() async throws {
        let store = makeStore()
        let echo = EngineSession(id: "s1", title: "One", directory: Self.dir)
        await store.delete("s1")
        #expect(store.session("s1") == nil)
        store.apply(.sessionUpdated(echo))
        store.apply(.sessionCreated(echo))
        #expect(store.session("s1") == nil)
        #expect(store.sessions.isEmpty)
    }

    @Test func lateEventCannotUndoALocalRenameOrModelSwitch() async throws {
        let store = makeStore()
        let earlierEcho = EngineSession(id: "s1", title: "One", directory: Self.dir,
                                        model: ModelRef(providerID: "openai", id: "gpt-5.5"), updated: Date())
        let opus = ModelRef(providerID: "anthropic", id: "claude-opus-5-5")
        await store.rename("s1", to: "Two")
        await store.switchModel(opus, for: "s1")
        store.apply(.sessionUpdated(earlierEcho))
        #expect(store.session("s1")?.title == "Two")
        #expect(store.session("s1")?.info.model == opus)
    }

    @Test func roomSessionsTagAgentText() throws {
        let store = makeStore()
        let agent = UUID()
        store.session("s1")?.agentID = agent
        store.apply(.textDelta(sessionID: "s1", itemID: "t1", delta: "From the room"))
        #expect(items(store) == [.agentText(id: "t1", text: "From the room", agentID: agent, streaming: true)])
    }

    @Test func eventsForUnknownSessionsAreIgnored() {
        let store = makeStore()
        store.apply(.textDelta(sessionID: "nope", itemID: "t1", delta: "x"))
        store.apply(.permissionAsked(PermissionRequest(id: "p", sessionID: "nope", kind: "bash", title: "ls")))
        #expect(store.sessions.map(\.id) == ["s1"])
        #expect(store.needsYouTotal == 0)
    }

    @Test func projectsGroupByFolderMostRecentFirst() {
        let now = Date()
        let store = makeStore(sessions: [
            EngineSession(id: "a", title: "A", directory: "/x/alpha", updated: now.addingTimeInterval(-300)),
            EngineSession(id: "b", title: "B", directory: "/x/beta", updated: now),
            EngineSession(id: "c", title: "C", directory: "/x/alpha", updated: now.addingTimeInterval(-10)),
            EngineSession(id: "d", title: "D", directory: "/x/beta", archived: true),
        ])
        #expect(store.projects.map(\.name) == ["beta", "alpha"])
        #expect(store.projects.last?.sessions.map(\.id) == ["c", "a"])
        #expect(store.sidebarOrder.map(\.id) == ["b", "c", "a"])
    }
}
