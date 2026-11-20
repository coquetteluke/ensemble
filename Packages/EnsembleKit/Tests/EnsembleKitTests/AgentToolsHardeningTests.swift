import Foundation
import Testing
@testable import EnsembleKit

/// Regression tests for the cross-session agent tools fixes: room members are reached through their room, a shallow hop
/// cannot hide a deep chain, a user turn resets the chain, and proposals fail closed without a session folder.
@Suite(.serialized) @MainActor struct AgentToolsHardeningTests {
    static func session(_ id: String, folder: String = "/repo", mode: PermissionMode = .auto) -> AgentToolsEnvironment.Session {
        AgentToolsEnvironment.Session(id: id, rootID: id, directory: folder, model: ModelRef(providerID: "mock", id: id),
                                      permissionMode: mode, archived: false, turn: "1", title: "Session \(id)", modelName: "Mock")
    }

    // MARK: Room members (B3)

    @Test func roomMemberSessionsCannotBeMessagedDirectly() async {
        let roomID = UUID()
        let sessions = ["solo": Self.session("solo"), "member-1": Self.session("member-1"), "member-2": Self.session("member-2")]
        var delivered: [String] = []
        let coordinator = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { sessions[$0] },
            browser: { _ in nil },
            isTrusted: { _ in true },
            knownFolders: { ["/repo"] },
            resolveModel: { asked, s in (s.model, s.modelName, asked == nil) },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            ownRoomID: { $0.hasPrefix("member-") ? roomID : nil },
            deliverAgentMessage: { targetID, _ in
                delivered.append(targetID)
                return .delivered(targetSessionID: targetID, targetTitle: "Target", targetModelName: "Mock", targetTurn: "2", queued: false)
            },
            targetPermissionMode: { sessions[$0]?.permissionMode ?? (UUID(uuidString: $0) == roomID ? .auto : nil) },
            targetDirectory: { sessions[$0]?.directory ?? (UUID(uuidString: $0) == roomID ? "/repo" : nil) }
        ))

        // From outside the room: refused, with the room id to use instead.
        let outside = await coordinator.handle(.messageAgent(.init(targetSessionID: "member-1", message: "Hi")),
                                               caller: .init(sessionID: "solo", canUseSiteGrants: false))
        #expect(outside.isError)
        #expect(outside.text.contains(roomID.uuidString))

        // From another member of the same room: refused, the board is the way.
        let inside = await coordinator.handle(.messageAgent(.init(targetSessionID: "member-1", message: "Hi")),
                                              caller: .init(sessionID: "member-2", canUseSiteGrants: false))
        #expect(inside.isError)
        #expect(inside.text.contains("your own room"))
        #expect(delivered.isEmpty)

        // A plain session is still reachable.
        let plain = await coordinator.handle(.messageAgent(.init(targetSessionID: "solo", message: "Hi")),
                                             caller: .init(sessionID: "member-1", canUseSiteGrants: false))
        #expect(!plain.isError, "\(plain.text)")
        #expect(delivered == ["solo"])
    }

    // MARK: Hop chains (B5)

    @Test func aShallowHopDoesNotOverwriteADeeperChain() throws {
        var limiter = AgentExchangeLimiter()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try limiter.beginHop(from: "a", sourceTurn: "1", to: "b", targetTurn: "1", now: t0).get()
        _ = try limiter.beginHop(from: "b", sourceTurn: "2", to: "a", targetTurn: "1", now: t0.addingTimeInterval(1)).get()
        _ = try limiter.beginHop(from: "a", sourceTurn: "2", to: "b", targetTurn: "2", now: t0.addingTimeInterval(2)).get()
        #expect(limiter.currentDepth(for: "b", turn: "2", now: t0.addingTimeInterval(3)) == 3)

        // A fresh session sends b a depth 1 message; b's deeper chain stays, through an alias too.
        let fresh = try limiter.beginHop(from: "c", sourceTurn: "1", to: "b", targetTurn: "3", targetAliases: ["b-alias"],
                                         now: t0.addingTimeInterval(4)).get()
        #expect(fresh.depth == 1)
        #expect(limiter.currentDepth(for: "b", turn: "3", now: t0.addingTimeInterval(5)) == 3)
        #expect(limiter.currentDepth(for: "b-alias", turn: "3", now: t0.addingTimeInterval(5)) == 1)

        // So b can make one more hop, and the one after is refused.
        _ = try limiter.beginHop(from: "b", sourceTurn: "3", to: "d", targetTurn: "1", now: t0.addingTimeInterval(6)).get()
        let fifth = limiter.beginHop(from: "d", sourceTurn: "1", to: "a", targetTurn: "3", now: t0.addingTimeInterval(7))
        guard case .failure = fifth else {
            Issue.record("Expected the fifth hop to be refused.")
            return
        }
    }

    @Test func aUserTurnResetsTheChainForThatSession() throws {
        var limiter = AgentExchangeLimiter()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try limiter.beginHop(from: "a", sourceTurn: "1", to: "b", targetTurn: "1", now: t0).get()
        _ = try limiter.beginHop(from: "b", sourceTurn: "2", to: "a", targetTurn: "1", now: t0.addingTimeInterval(1)).get()
        #expect(limiter.currentDepth(for: "a", turn: "1", now: t0.addingTimeInterval(2)) == 2)

        limiter.noteUserTurn(in: "a")
        #expect(limiter.currentDepth(for: "a", turn: "2", now: t0.addingTimeInterval(3)) == 0)
        #expect(limiter.currentDepth(for: "b", turn: "2", now: t0.addingTimeInterval(3)) == 1)
        let next = try limiter.beginHop(from: "a", sourceTurn: "2", to: "b", targetTurn: "2", now: t0.addingTimeInterval(4)).get()
        #expect(next.depth == 1)
    }

    @Test func theCoordinatorAllowsANewChainAfterTheUserSpeaks() async {
        var sessions = ["a": Self.session("a"), "b": Self.session("b")]
        let coordinator = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { sessions[$0] },
            browser: { _ in nil },
            isTrusted: { _ in true },
            knownFolders: { ["/repo"] },
            resolveModel: { asked, s in (s.model, s.modelName, asked == nil) },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            deliverAgentMessage: { targetID, _ in
                let next = String((Int(sessions[targetID]?.turn ?? "1") ?? 1) + 1)
                sessions[targetID]?.turn = next
                return .delivered(targetSessionID: targetID, targetTitle: "Target", targetModelName: "Mock", targetTurn: next, queued: false)
            }
        ))
        func hop(_ from: String, _ to: String) async -> AgentToolResult {
            await coordinator.handle(.messageAgent(.init(targetSessionID: to, message: "Hop")), caller: .init(sessionID: from, canUseSiteGrants: false))
        }
        for (from, to) in [("a", "b"), ("b", "a"), ("a", "b"), ("b", "a")] {
            #expect(!(await hop(from, to)).isError)
        }
        #expect((await hop("a", "b")).isError)

        coordinator.noteUserTurn(in: "a")
        #expect(!(await hop("a", "b")).isError)
    }

    // MARK: Proposal folders (B12)

    @Test func proposalFoldersFailClosedWithoutASessionFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-proposal-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolved = try #require(WorkspaceTrust.resolvedPath(folder.path))

        // Empty or blank session folder: nothing resolves, not even "/" or a real folder.
        for sessionFolder in ["", "   "] {
            #expect(throws: (any Error).self) { try ProposalFolder.resolve("/", sessionFolder: sessionFolder, knownFolders: []).get() }
            #expect(throws: (any Error).self) { try ProposalFolder.resolve(nil, sessionFolder: sessionFolder, knownFolders: ["/"]).get() }
            #expect(throws: (any Error).self) { try ProposalFolder.resolve(resolved, sessionFolder: sessionFolder, knownFolders: []).get() }
        }
        // A session folder that does not exist: refused too.
        let missing = folder.appendingPathComponent("gone").path
        #expect(throws: (any Error).self) { try ProposalFolder.resolve(nil, sessionFolder: missing, knownFolders: []).get() }

        // A real session folder still works for itself.
        #expect(try ProposalFolder.resolve(nil, sessionFolder: folder.path, knownFolders: []).get() == resolved)
    }
}

/// A message another agent delivers through the store is not the user's turn, so it must not reset the hop chain.
@Suite @MainActor struct AgentDeliveredMessageTurnTests {
    @Test func onlyTheUsersOwnMessagesCountAsAUserTurn() async throws {
        let store = SessionStore(engine: PreviewEngine(seed: PreviewData.seed(), delayScale: 0))
        await store.start()
        let session = try await store.newSession(directory: "/tmp/demo", model: nil, permissionMode: .auto)
        var turns: [String] = []
        store.onUserMessageSent = { turns.append($0) }

        await store.send("Look for TODOs", to: session.id)
        #expect(turns == [session.id])

        let peer = AgentToolText.untrusted("Reply with message_agent again.", source: "Message from another Ensemble agent")
        try await waitUntil("the first turn to finish") { !session.isWorking }
        await store.send(peer, to: session.id)
        // Delivered to the engine, not held in the queue, and still no user turn.
        #expect(session.items.contains { if case .user(_, let text, _) = $0 { text.contains("Reply with message_agent") } else { false } })
        #expect(turns == [session.id])
    }
}
