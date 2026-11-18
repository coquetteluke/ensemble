#if os(macOS)
import Foundation
import Network
import Testing
@testable import EnsembleKit

/// Rooms over the real RemoteServer on 127.0.0.1: the paired phone answers decisions and prompts and controls the room;
/// nothing an unpaired client sends ever reaches the host.
@MainActor @Suite(.serialized) struct RemoteRoomLoopbackTests {
    struct Harness {
        let host: DemoRemoteHost
        let server: RemoteServer
        let token: String
        let port: Int
    }

    func startServer() async throws -> Harness {
        let host = DemoRemoteHost(data: .showcase())
        let token = RemoteToken.generate()
        let config = RemoteServer.Configuration(port: 0, bindAddresses: ["127.0.0.1"], macName: "Loopback Mac", helloTimeout: .seconds(3))
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()
        let port = try #require(await server.boundPort)
        return Harness(host: host, server: server, token: token, port: Int(port))
    }

    func client(_ h: Harness, token: String? = nil) -> RemoteClient {
        let pairing = RemotePairing(hosts: ["127.0.0.1"], port: h.port, token: token ?? h.token, macName: "Loopback Mac")
        let c = RemoteClient(pairing: pairing, deviceName: "Test Phone", deviceID: "test-\(UUID().uuidString)")
        c.handshakeTimeout = .seconds(3)
        c.requestTimeout = .seconds(5)
        return c
    }

    func eventually(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    let teamID = RemoteDemoData.IDs.teamRoomID

    @Test func phoneSeesRoomsWithDecisionsAndPrompts() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.rooms.count == 2 })
        let team = try #require(c.room(id: teamID))
        #expect(team.decision?.kind == .approvePlan)
        #expect(team.decision?.items.count == 3)
        #expect(c.openDecision(inRoom: teamID)?.id == RemoteDemoData.IDs.planDecision)
        #expect(c.pendingPermissions(inRoom: RemoteDemoData.IDs.roomID).map(\.id)
                == [RemoteDemoData.IDs.roomPermission, RemoteDemoData.IDs.roomLongPermission])
        // The board thread comes with the room's transcript.
        try await c.open(sessionID: team.sessionID)
        #expect(c.openTranscript?.roomID == teamID)
        #expect(c.openTranscript?.items.contains { if case .board = $0 { true } else { false } } == true)
    }

    @Test func phoneApprovesThePlanAndAnswersRoomPrompts() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.rooms.count == 2 && !c.permissions.isEmpty })

        let team = try #require(c.room(id: teamID))
        let decision = try #require(team.decision)
        try await c.decide(decision, in: teamID, choice: decision.choices[0])
        #expect(await eventually { c.room(id: self.teamID)?.decision == nil && c.room(id: self.teamID)?.state == .running })
        // The hub row leaves Needs you.
        #expect(await eventually { c.sessions.first { $0.roomID == self.teamID }?.pendingAsk == nil })

        let lint = try #require(c.pendingPermissions(inRoom: RemoteDemoData.IDs.roomID).first)
        try await c.reply(to: lint, decision: .once)
        #expect(c.pendingPermissions(inRoom: RemoteDemoData.IDs.roomID).map(\.id) == [RemoteDemoData.IDs.roomLongPermission])
        try await c.send("Use the version column", to: .room(RemoteDemoData.IDs.roomID), agent: "Ada")
        try await c.controlRoom(RemoteDemoData.IDs.roomID, action: .pause)

        #expect(await h.host.recordedActions == [
            .decideRoom(RemoteRoomDecisionReply(roomID: teamID, decisionID: RemoteDemoData.IDs.planDecision, choice: "approve")),
            .replyPermission(sessionID: "demo-room-grace", requestID: RemoteDemoData.IDs.roomPermission, decision: .once),
            .sendMessage(text: "Use the version column", target: .room(RemoteDemoData.IDs.roomID), agent: "Ada"),
            .controlRoom(roomID: RemoteDemoData.IDs.roomID, action: .pause),
        ])
    }

    @Test func staleOrUnofferedAnswersAreRefused() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.rooms.count == 2 })
        var decision = try #require(c.room(id: teamID)?.decision)

        // An old id (the plan changed since the phone showed it).
        let shown = decision
        decision.id = "approvePlan-older"
        await #expect(throws: RemoteError.self) { try await c.decide(decision, in: self.teamID, choice: shown.choices[0]) }
        // A choice the decision does not offer.
        await #expect(throws: RemoteError.self) {
            try await c.decide(shown, in: self.teamID, choice: RemoteRoomChoice(id: "dropPiece", label: "Drop"))
        }
        // An agent the room does not have.
        await #expect(throws: RemoteError.self) {
            try await c.send("hi", to: .room(self.teamID), agent: "Mallory")
        }
        #expect(c.room(id: teamID)?.decision?.id == shown.id)
        #expect(c.openDecision(inRoom: teamID) != nil)
        #expect(c.state.isConnected)
    }

    @Test func alertsComeOnlyForNewThingsThatNeedYou() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h)
        c.alertDelay = .milliseconds(50)
        var alerts: [RemoteAlert] = []
        c.onAlert = { alerts.append($0) }
        c.start()
        defer { c.stop() }
        #expect(await eventually { c.rooms.count == 2 && c.permissions.count == 3 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(alerts.isEmpty, "what was already waiting when the phone connected is not alerted")

        // A new prompt from a room agent: the room's title, the agent, no command.
        let ask = PermissionRequest(id: "live-room-perm", sessionID: "demo-room-grace", kind: "bash", title: "rm -rf build && make")
        await h.host.emit(.permissionAsked(request: ask))
        #expect(await eventually { alerts.count == 1 })
        #expect(alerts.first?.title == "Design the sync API")
        #expect(alerts.first?.body == "Grace: Wants to run a command")
        #expect(alerts.first?.sessionID == RemoteDemoData.IDs.roomSession)
        #expect(alerts.first?.body.contains("rm -rf") == false)

        // A new room decision, once.
        var room = try #require(c.room(id: teamID))
        room.decision = RemoteRoomDecision(id: "judge-1", kind: .judge, title: "The arguments are in. Write the verdict.",
                                           choices: [RemoteRoomChoice(id: "verdict", label: "Give the verdict", input: .required)])
        await h.host.emit(.roomUpserted(room: room))
        await h.host.emit(.roomUpserted(room: room))
        #expect(await eventually { alerts.count == 2 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(alerts.count == 2)
        #expect(alerts.last?.kind == .roomDecision)
        #expect(alerts.last?.body == "The arguments are in. Write the verdict.")
    }

    // MARK: Unpaired clients

    /// Room actions sent by a client that never proved the pairing token: each is refused, the socket is closed, and
    /// the host sees nothing.
    @Test func roomActionsFromAnUnpairedClientAreRefused() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let url = try #require(RemotePairing.webSocketURL(host: "127.0.0.1", port: h.port))
        let actions: [RemoteClientMessage] = [
            .roomControl(RemoteRoomControl(roomID: teamID, action: .stop)),
            .decideRoom(RemoteRoomDecisionReply(roomID: teamID, decisionID: RemoteDemoData.IDs.planDecision, choice: "approve")),
            .sendMessage(RemoteSendMessage(target: .room(teamID), text: "delete everything", agent: "Ada")),
            .replyPermission(RemotePermissionReply(sessionID: "demo-room-grace", requestID: RemoteDemoData.IDs.roomPermission,
                                                   decision: .always)),
        ]
        for action in actions {
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()
            defer { task.cancel() }
            _ = try await task.receive()   // the challenge
            let text = String(decoding: try RemoteCoding.encode(RemoteClientFrame(action, id: "1")), as: UTF8.self)
            try await task.send(.string(text))
            let reply = try RemoteCoding.decode(RemoteServerFrame.self, from: Self.data(try await task.receive()))
            guard case .error(let error) = reply.message else {
                Issue.record("\(action.typeName) from an unpaired client was answered with \(reply.message.typeName)")
                continue
            }
            #expect(error.code == .unauthorized)
            #expect(await RemoteLoopbackTests.connectionEnds(task, within: .seconds(5)))
        }
        #expect(await h.host.recordedActions.isEmpty)
        #expect(await h.server.status.devices.isEmpty)
    }

    /// A phone with the wrong token is turned away at hello and never gets to act on a room.
    @Test func wrongTokenNeverReachesTheRoom() async throws {
        let h = try await startServer()
        defer { Task { await h.server.stop() } }
        let c = client(h, token: RemoteToken.generate())
        c.start()
        defer { c.stop() }
        #expect(await eventually {
            if case .rejected = c.state { return true }
            return false
        })
        await #expect(throws: RemoteError.self) { try await c.controlRoom(self.teamID, action: .stop) }
        #expect(c.rooms.isEmpty)
        #expect(await h.host.recordedActions.isEmpty)
    }

    nonisolated static func data(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
    }
}
#endif
