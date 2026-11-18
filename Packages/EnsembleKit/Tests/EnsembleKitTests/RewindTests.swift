import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// A fake engine with rewind with choices: scripted plan, outcome and transcript, and a log of what reached it.
final class RewindFakeEngine: RouterFakeEngine, EngineHistoryControl, EngineRewindControl, @unchecked Sendable {
    struct Script {
        var plan = RewindPlan(choices: [RewindChoice(.codeAndConversation), RewindChoice(.conversationOnly),
                                        RewindChoice(.codeOnly), RewindChoice(.summarizeFromHere, unavailableReason: "no")],
                              files: [FileChange(path: "a.txt", kind: .modified, additions: 1, deletions: 2)],
                              messagesRemoved: 1, canRedo: true)
        var transcript: [TranscriptItem] = []
        var transcriptAfterRewind: [TranscriptItem] = []
        var failRewind = false
        var rewound = false
    }

    let script = Mutex(Script())

    var rewindRestoresFiles: Bool { true }
    func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession { throw OpenCodeError.invalidArgument("no") }
    func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws { log("plainRewind:\(messageID)") }

    override func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        log("transcript:\(sessionID)")
        return script.withLock { $0.rewound ? $0.transcriptAfterRewind : $0.transcript }
    }

    func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan {
        log("plan:\(messageID)")
        return script.withLock { $0.plan }
    }

    func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome {
        log("rewind:\(messageID):\(scope.rawValue)")
        return try script.withLock { script in
            if script.failRewind { throw OpenCodeError.invalidArgument("the disk is full") }
            script.rewound = true
            return RewindOutcome(scope: scope, files: scope.restoresFiles ? script.plan.files : [],
                                 messagesRemoved: scope.removesMessages ? script.plan.messagesRemoved : 0, canRedo: true)
        }
    }

    func redoRewind(_ sessionID: String) async throws {
        log("redo:\(sessionID)")
        script.withLock { $0.rewound = false }
    }
}

@Suite("Rewind with choices")
struct RewindTests {
    // MARK: Models

    @Test func reversedChangeIsWhatTheRewindDoes() {
        let created = FileChange(path: "new.swift", kind: .added, additions: 12, deletions: 0, diff: "+x")
        #expect(created.reversed == FileChange(path: "new.swift", kind: .deleted, additions: 0, deletions: 12))
        let edited = FileChange(path: "a.swift", kind: .modified, additions: 2, deletions: 5)
        #expect(edited.reversed == FileChange(path: "a.swift", kind: .modified, additions: 5, deletions: 2))
        #expect(FileChange(path: "gone", kind: .deleted, deletions: 3).reversed.kind == .added)
    }

    @Test func planAlwaysListsEveryChoiceInOrder() {
        let plan = RewindPlan(choices: [RewindChoice(.codeOnly), RewindChoice(.conversationOnly)])
        #expect(plan.choices.map(\.scope) == RewindScope.allCases)
        #expect(plan.choice(.codeAndConversation).unavailableReason == RewindReason.notOffered)
        #expect(plan.defaultScope == .conversationOnly)

        let none = RewindPlan.unavailable(RewindReason.noRewind("Google Antigravity"))
        #expect(none.choices.allSatisfy { $0.unavailableReason == "Google Antigravity sessions cannot rewind" })
        #expect(none.defaultScope == nil)

        let basic = RewindPlan.basic(restoresFiles: true, messagesRemoved: 2)
        #expect(basic.choices.filter(\.isAvailable).map(\.scope) == [.codeAndConversation])
        #expect(basic.choice(.conversationOnly).unavailableReason == RewindReason.alwaysRestoresFiles)
        #expect(!basic.filesKnown && !basic.canRedo && basic.messagesRemoved == 2)
        #expect(RewindPlan.basic(restoresFiles: false, messagesRemoved: 0).defaultScope == .conversationOnly)
    }

    @Test func noticeSaysWhatWasUndone() {
        let files = [FileChange(path: "a", kind: .modified), FileChange(path: "b", kind: .deleted)]
        var notice = RewindNotice(id: "rewind-1", sessionID: "s", outcome: RewindOutcome(scope: .codeAndConversation, files: files, messagesRemoved: 2))
        #expect(notice.text == "Rewound code and conversation: 2 messages removed, 2 files put back")
        notice.outcome = RewindOutcome(scope: .conversationOnly, messagesRemoved: 1)
        #expect(notice.text == "Rewound the conversation: 1 message removed, files kept")
        notice.outcome = RewindOutcome(scope: .codeOnly, files: [files[0]])
        #expect(notice.text == "Rewound code: 1 file put back, conversation kept")
        notice.state = .redone
        #expect(notice.text.hasPrefix("Rewind undone"))
        #expect(!notice.text.contains("\u{2014}"))
    }

    // MARK: Claude

    @Test func claudeFilesAreDescribedAsTheRewindChangesThem() {
        let agent = [FileChange(path: "Sources/New.swift", kind: .added, additions: 30),
                     FileChange(path: "notes.txt", kind: .modified, additions: 1, deletions: 4)]
        let present: Set<String> = ["/p/Sources/New.swift", "/p/notes.txt"]
        let files = ClaudeCodeEngine.rewindFiles(["/p/Sources/New.swift", "/p/notes.txt", "/p/gone.txt", "/p/notes.txt"],
                                                 agentChanges: agent, directory: "/p") { present.contains($0) }
        #expect(files == [
            FileChange(path: "Sources/New.swift", kind: .deleted, additions: 0, deletions: 30),
            FileChange(path: "notes.txt", kind: .modified, additions: 4, deletions: 1),
            FileChange(path: "gone.txt", kind: .added),
        ])
    }

    @Test func claudeLimitTextShowsOnlyAsTheCard() throws {
        let (outputs, decoder) = try ClaudeFixtures.decode("stream-usage-limit.jsonl")
        let events = ClaudeFixtures.events(outputs)
        // The CLI's own "You've hit your 5-hour limit" assistant line is not agent text...
        #expect(!events.contains { if case .textEnded = $0 { true } else { false } })
        #expect(!events.contains { if case .textDelta = $0 { true } else { false } })
        // ...the turn still fails with it, so the store turns that error row into the limit card.
        #expect(events.contains { if case .executionEnded(_, "failed", let error?) = $0 { error.contains("5-hour limit") } else { false } })
        #expect(decoder.lastLimitStop != nil)

        // The model's own words about limits, and other synthetic lines, stay.
        var other = ClaudeStreamDecoder(rootID: "r", directory: "/p")
        let said = other.decode(line: #"{"type":"assistant","message":{"id":"m1","model":"claude-haiku","content":[{"type":"text","text":"You've hit your 5-hour limit, says the docs."}]}}"#)
        #expect(said.contains { if case .event(.textEnded(_, _, let text)) = $0 { text.contains("5-hour") } else { false } })
        let synthetic = other.decode(line: #"{"type":"assistant","message":{"id":"m2","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#)
        #expect(synthetic.contains { if case .event(.textEnded) = $0 { true } else { false } })
        #expect(ClaudeStreamDecoder.isPlanLimitMessage(.object(["is_api_error_message": true, "error": "rate_limit"])))
    }

    // MARK: OpenCode requests

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (OpenCodeClient, String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = OpenCodeClient(baseURL: URL(string: "http://\(host):4096")!, password: "secret",
                                    defaultDirectory: "/tmp/project", configuration: configuration)
        return (client, host)
    }

    private static let session = #"{"data":{"id":"ses_1","projectID":"p","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1,"updated":2},"location":{"directory":"/tmp/project"}}}"#
    private static let stagedSession = #"{"data":{"id":"ses_1","projectID":"p","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1,"updated":2},"location":{"directory":"/tmp/project"},"revert":{"messageID":"msg_3","snapshot":"abc","files":[]}}}"#
    private static let users = #"{"data":[{"id":"msg_1","type":"user","time":{"created":1},"text":"one"},{"id":"msg_2","type":"user","time":{"created":2},"text":"two"},{"id":"msg_3","type":"user","time":{"created":3},"text":"three"}],"cursor":{"previous":null,"next":null}}"#

    @Test func openCodePlanReversesTheDiffOfTheRemovedTurns() async throws {
        let diff = #"{"data":[{"file":"a.txt","patch":"p","additions":2,"deletions":1,"status":"modified"},{"file":"b.txt","patch":"p","additions":1,"deletions":0,"status":"added"}]}"#
        let (client, host) = makeClient { request in
            if request.url.path.hasSuffix("/diff") { return (200, diff) }
            if request.url.path.hasSuffix("/message") { return (200, Self.users) }
            return (200, Self.session)
        }
        let plan = try await client.rewindPlan("ses_1", toBeforeMessageID: "msg_2")
        #expect(plan.files == [FileChange(path: "a.txt", kind: .modified, additions: 1, deletions: 2),
                               FileChange(path: "b.txt", kind: .deleted, additions: 0, deletions: 1)])
        #expect(plan.messagesRemoved == 2)
        #expect(plan.canRedo)
        #expect(plan.choices.filter(\.isAvailable).map(\.scope) == [.codeAndConversation, .conversationOnly])
        #expect(plan.choice(.codeOnly).unavailableReason == OpenCodeClient.codeOnlyReason)
        #expect(plan.choice(.summarizeFromHere).unavailableReason == OpenCodeClient.summaryReason)
        let diffRequest = try #require(StubURLProtocol.requests(host: host).first { $0.url.path.hasSuffix("/diff") })
        let query = diffRequest.url.query ?? ""
        #expect(query.contains("from=msg_2") && query.contains("to=msg_3") && query.contains("context=3"))
        let messages = try #require(StubURLProtocol.requests(host: host).first { $0.url.path.hasSuffix("/message") })
        #expect(messages.url.query?.contains("type=user") == true)
    }

    @Test func openCodePlanStopsAtAStagedRevert() async throws {
        let (client, host) = makeClient { request in
            if request.url.path.hasSuffix("/diff") { return (200, #"{"data":[]}"#) }
            if request.url.path.hasSuffix("/message") { return (200, Self.users) }
            return (200, Self.stagedSession)
        }
        let plan = try await client.rewindPlan("ses_1", toBeforeMessageID: "msg_1")
        // msg_3 is already hidden by the staged revert: the range ends at msg_2.
        #expect(plan.messagesRemoved == 2)
        let diffRequest = try #require(StubURLProtocol.requests(host: host).first { $0.url.path.hasSuffix("/diff") })
        #expect(diffRequest.url.query?.contains("to=msg_2") == true)
        await #expect(throws: OpenCodeError.self) { try await client.rewindPlan("ses_1", toBeforeMessageID: "msg_3") }
    }

    @Test func openCodeRewindStagesAndRedoClears() async throws {
        let staged = #"{"data":{"messageID":"msg_2","snapshot":"abc","files":[{"file":"a.txt","patch":"p","additions":1,"deletions":2,"status":"modified"},{"file":"b.txt","patch":"p","additions":0,"deletions":1,"status":"deleted"}]}}"#
        // The engine's state: a revert is staged after a stage and gone after a clear.
        let isStaged = Mutex(false)
        let (client, host) = makeClient { request in
            if request.url.path.hasSuffix("/revert/stage") {
                isStaged.withLock { $0 = true }
                return (200, staged)
            }
            if request.url.path.hasSuffix("/revert") {
                isStaged.withLock { $0 = false }
                return (204, "")
            }
            if request.url.path.hasSuffix("/message") { return (200, Self.users) }
            return (200, isStaged.withLock { $0 } ? Self.stagedSession : Self.session)
        }
        let outcome = try await client.rewind("ses_1", toBeforeMessageID: "msg_2", scope: .codeAndConversation)
        #expect(outcome.files == [FileChange(path: "a.txt", kind: .modified, additions: 1, deletions: 2),
                                  FileChange(path: "b.txt", kind: .deleted, additions: 0, deletions: 1)])
        #expect(outcome.messagesRemoved == 2)
        #expect(outcome.canRedo)
        let stage = try #require(StubURLProtocol.requests(host: host).first { $0.url.path.hasSuffix("/revert/stage") })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(stage.body))
        #expect(body == ["messageID": "msg_2", "files": true])
        // Nothing is committed: Redo can still clear it.
        #expect(!StubURLProtocol.requests(host: host).contains { $0.url.path.hasSuffix("/revert/commit") })

        try await client.redoRewind("ses_1")
        #expect(StubURLProtocol.requests(host: host).last.map { "\($0.method) \($0.url.path)" } == "DELETE /api/session/ses_1/revert")

        _ = try await client.rewind("ses_1", toBeforeMessageID: "msg_3", scope: .conversationOnly)
        let second = try #require(StubURLProtocol.requests(host: host).last { $0.url.path.hasSuffix("/revert/stage") })
        #expect(try JSONDecoder().decode(JSONValue.self, from: try #require(second.body)) == ["messageID": "msg_3", "files": false])
        await #expect(throws: OpenCodeError.self) {
            _ = try await client.rewind("ses_1", toBeforeMessageID: "msg_2", scope: .codeOnly)
        }
    }

    @Test func openCodeTranscriptHidesAStagedRevert() async throws {
        let (client, _) = makeClient { request in
            if request.url.path.hasSuffix("/message") { return (200, Self.users) }
            return (200, Self.stagedSession)
        }
        let items = try await client.transcript("ses_1")
        #expect(items.compactMap { if case .user(let id, _, _) = $0 { id } else { nil } } == ["msg_1", "msg_2"])
        let (plain, _) = makeClient { request in
            if request.url.path.hasSuffix("/message") { return (200, Self.users) }
            return (200, Self.session)
        }
        #expect(try await plain.transcript("ses_1").count == 3)
    }

    // MARK: Router

    @Test func routerOffersNothingForAnEngineWithoutRewind() async throws {
        let openCode = RouterCapableFakeEngine(name: "oc")
        let gemini = RouterFakeEngine(name: "agy")
        let router = EngineRouter(fallback: openCode, trust: WorkspaceTrust(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-\(UUID().uuidString).json")))
        router.register(gemini, providers: ["agy"], id: "antigravity", name: "Google Antigravity")
        gemini.setSessions([EngineSession(id: "agy-1", title: "g", directory: "/tmp")])
        openCode.setSessions([EngineSession(id: "oc-1", title: "o", directory: "/tmp")])
        _ = try await router.listSessions()

        let none = try await router.rewindPlan("agy-1", toBeforeMessageID: "m")
        #expect(none.choices.allSatisfy { $0.unavailableReason == "Google Antigravity sessions cannot rewind" })
        await #expect(throws: EngineRouterError.self) { _ = try await router.rewind("agy-1", toBeforeMessageID: "m", scope: .conversationOnly) }

        // History only: its one behaviour, done through the old call.
        let basic = try await router.rewindPlan("oc-1", toBeforeMessageID: "m")
        #expect(basic.defaultScope == .codeAndConversation && !basic.filesKnown)
        let outcome = try await router.rewind("oc-1", toBeforeMessageID: "m", scope: .codeAndConversation)
        #expect(!outcome.canRedo)
        #expect(openCode.calls.contains("rewind:oc-1"))
        await #expect(throws: EngineRouterError.self) { _ = try await router.rewind("oc-1", toBeforeMessageID: "m", scope: .codeOnly) }
    }

    // MARK: Store

    @MainActor
    private func makeStore(_ engine: RewindFakeEngine) -> (SessionStore, String) {
        let store = SessionStore(engine: engine)
        let session = EngineSession(id: "ses_r", title: "Rewind me", directory: "/tmp/project")
        let items: [TranscriptItem] = [
            .user(id: "msg_1", text: "first", date: Date()),
            .agentText(id: "t1", text: "ok", agentID: nil, streaming: false),
            .user(id: "msg_2", text: "second line one\nline two", date: Date()),
            .agentText(id: "t2", text: "done", agentID: nil, streaming: false),
        ]
        engine.script.withLock {
            $0.transcript = items
            $0.transcriptAfterRewind = Array(items.prefix(2))
        }
        store.seed(StoreSeed(sessions: [session], transcripts: ["ses_r": items]))
        return (store, session.id)
    }

    @MainActor
    private func waitForPlan(_ store: SessionStore) async throws {
        try await waitUntil("the rewind plan") {
            if case .failed? = store.rewinds.request?.phase { return true }
            return store.rewinds.request?.plan != nil
        }
        if case .failed(let message)? = store.rewinds.request?.phase { Issue.record("plan failed: \(message)") }
    }

    @Test @MainActor func storeRewindsWithTheChosenScopeAndRedoes() async throws {
        let engine = RewindFakeEngine(name: "fake")
        let (store, id) = makeStore(engine)
        store.beginRewind(id, messageID: "msg_2")
        #expect(store.rewinds.request?.messageText == "second line one")
        try await waitForPlan(store)
        #expect(store.rewinds.request?.selected == .codeAndConversation)
        store.selectRewindScope(.summarizeFromHere)
        #expect(store.rewinds.request?.selected == .codeAndConversation)
        store.selectRewindScope(.conversationOnly)
        #expect(store.rewinds.request?.selected == .conversationOnly)
        store.selectRewindScope(.codeAndConversation)

        #expect(await store.confirmRewind())
        #expect(store.rewinds.request == nil)
        #expect(engine.calls.contains("rewind:msg_2:codeAndConversation"))
        let session = try #require(store.session(id))
        // Transcript reloaded without the removed turn, then the notice at the end.
        #expect(!session.items.contains { $0.id == "msg_2" })
        let noticeID = try #require(session.items.last?.id)
        let notice = try #require(store.rewindNotice(forItem: noticeID))
        #expect(notice.outcome.files.map(\.path) == ["a.txt"])
        #expect(store.redoUnavailableReason(notice) == nil)

        await store.redoRewind(noticeID: noticeID)
        #expect(engine.calls.contains("redo:ses_r"))
        #expect(store.rewindNotice(forItem: noticeID)?.state == .redone)
        #expect(session.items.contains { $0.id == "msg_2" })
        #expect(session.items.last?.id == noticeID)
    }

    @Test @MainActor func redoGoesAwayOnceTheConversationMovesOn() async throws {
        let engine = RewindFakeEngine(name: "fake")
        let (store, id) = makeStore(engine)
        store.beginRewind(id, messageID: "msg_2")
        try await waitForPlan(store)
        store.selectRewindScope(.codeOnly)
        #expect(await store.confirmRewind())
        let session = try #require(store.session(id))
        // Code only keeps the conversation: no reload, the notice goes after it.
        #expect(session.items.contains { $0.id == "msg_2" })
        let noticeID = try #require(session.items.last?.id)
        let notice = try #require(store.rewindNotice(forItem: noticeID))
        #expect(notice.text == "Rewound code: 1 file put back, conversation kept")
        session.items.append(.user(id: "user-later", text: "next", date: Date()))
        #expect(store.redoUnavailableReason(notice) == "The conversation has moved on since")
        await store.redoRewind(noticeID: noticeID)
        #expect(!engine.calls.contains("redo:ses_r"))
    }

    @Test @MainActor func failedRewindKeepsTheSheetOpenWithTheReason() async throws {
        let engine = RewindFakeEngine(name: "fake")
        engine.script.withLock { $0.failRewind = true }
        let (store, id) = makeStore(engine)
        store.beginRewind(id, messageID: "msg_1")
        try await waitForPlan(store)
        #expect(await store.confirmRewind() == false)
        #expect(store.rewinds.request?.error?.contains("the disk is full") == true)
        #expect(store.rewinds.request?.plan != nil)
        store.cancelRewind()
        #expect(store.rewinds.request == nil)
    }

    @Test @MainActor func rewindWaitsWhileTheAgentWorks() async throws {
        let engine = RewindFakeEngine(name: "fake")
        let (store, id) = makeStore(engine)
        store.beginRewind(id, messageID: "msg_2")
        try await waitForPlan(store)
        store.apply(.activity(sessionID: id, .working))
        #expect(store.rewindConfirmUnavailableReason() == RewindReason.working)
        #expect(await store.confirmRewind() == false)
        #expect(!engine.calls.contains { $0.hasPrefix("rewind:") })
    }
}
