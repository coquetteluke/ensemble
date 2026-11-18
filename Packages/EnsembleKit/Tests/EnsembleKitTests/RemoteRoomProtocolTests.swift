import Foundation
import Testing
@testable import EnsembleKit

/// Rooms on the phone: the messages added after protocol 3 shipped round-trip, frames from older Macs still decode,
/// newer frames still decode on older phones, and a Mac without room decisions answers `unknownMessage`.
@Suite struct RemoteRoomProtocolTests {
    let data = RemoteDemoData.showcase(now: Date(timeIntervalSince1970: 1_800_000_000))

    func roundTrip<M>(_ frame: RemoteFrame<M>) throws -> RemoteFrame<M> {
        try RemoteCoding.decode(RemoteFrame<M>.self, from: try RemoteCoding.encode(frame))
    }

    var team: RemoteRoom { data.rooms.first { $0.id == RemoteDemoData.IDs.teamRoomID }! }

    @Test func roomDecisionMessageRoundTrips() throws {
        let replies = [
            RemoteRoomDecisionReply(roomID: RemoteDemoData.IDs.teamRoomID, decisionID: "approvePlan-1", choice: "approve"),
            RemoteRoomDecisionReply(roomID: RemoteDemoData.IDs.teamRoomID, decisionID: "approvePlan-1", choice: "redo",
                                    text: "Split the sync queue into its own piece"),
        ]
        for reply in replies {
            let frame = RemoteClientFrame(.decideRoom(reply), id: "7")
            #expect(try roundTrip(frame) == frame)
        }
        let json = try JSONSerialization.jsonObject(with: RemoteCoding.encode(RemoteClientFrame(.decideRoom(replies[1]), id: "7")))
            as? [String: Any]
        #expect(json?["type"] as? String == "roomDecision")
        let payload = json?["data"] as? [String: Any]
        #expect(payload?["choice"] as? String == "redo")
        #expect(payload?["decisionID"] as? String == "approvePlan-1")
    }

    @Test func roomsWithDecisionsAndPromptsRoundTrip() throws {
        #expect(team.decision?.kind == .approvePlan)
        #expect(data.rooms[0].permissions.count == 2)
        let messages: [RemoteServerMessage] = [
            .rooms(data.rooms),
            .update(.roomUpserted(room: team)),
            .update(.roomUpserted(room: data.rooms[0])),
            .update(.sessionUpserted(session: RemoteRoomBridge.hubRow(team))),
        ]
        for m in messages {
            let frame = RemoteServerFrame(m, replyTo: "3")
            #expect(try roundTrip(frame) == frame)
        }
        // Every kind, style and input survives the trip.
        let all = RemoteRoomDecision(
            id: "x", kind: .mergeConflict, title: "Merging stopped", agentID: RemoteDemoData.IDs.agentB, text: "t",
            items: [.init(text: "Sources/App.swift")], note: "Resolve it on the Mac.",
            choices: [RemoteRoomChoice(id: "a", label: "A", style: .destructive, input: .required, placeholder: "p", template: "PLAN: ")],
            needsYou: false)
        var room = team
        room.decision = all
        #expect(try roundTrip(RemoteServerFrame(.update(.roomUpserted(room: room)))).message == .update(.roomUpserted(room: room)))
    }

    /// A room exactly as a protocol 3 Mac from before rooms on the phone wrote it.
    static let oldRoomJSON = """
    {"id":"6F1D1E9A-2B7C-4C55-9E1A-6B0C8F3A2D11","title":"Design the sync API","directory":"/Users/demo/code/notes",\
    "mode":"roundTable","agents":[{"id":"0B5E7C1A-1111-4E2B-9C3D-2A6F8E9B0C01","name":"Ada","model":"anthropic/claude-opus-5.5",\
    "colorHex":"#D97757","activity":"working","sessionID":"demo-room-ada"}],"leadAgentID":"0B5E7C1A-1111-4E2B-9C3D-2A6F8E9B0C01",\
    "state":"running","permissionMode":"acceptEdits","sessionID":"demo-room-api",\
    "usage":{"inputTokens":1,"outputTokens":2,"reasoningTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"costUSD":0.5},"lastActivity":810000000}
    """

    @Test func oldMacFramesStillDecode() throws {
        let rooms = #"{"v":3,"re":"4","type":"rooms","data":{"rooms":["# + Self.oldRoomJSON + "]}}"
        let frame = try RemoteCoding.decode(RemoteServerFrame.self, from: Data(rooms.utf8))
        guard case .rooms(let list) = frame.message, let room = list.first else {
            Issue.record("Expected rooms, got \(frame.message.typeName)")
            return
        }
        #expect(room.title == "Design the sync API")
        #expect(room.state == .running)
        #expect(room.agents.first?.capped == nil)
        #expect(room.decision == nil)
        #expect(room.permissions.isEmpty)
        #expect(room.phaseLabel == nil)
        #expect(!room.needsYou)

        // The same room as a live update.
        let update = #"{"v":3,"type":"update","data":{"roomUpserted":{"room":"# + Self.oldRoomJSON + "}}}"
        let decoded = try RemoteCoding.decode(RemoteServerFrame.self, from: Data(update.utf8))
        #expect(decoded.message == .update(.roomUpserted(room: room)))
    }

    @Test func newFramesDecodeOnOldPhones() throws {
        // The phone's room type as it was before: synthesised decoding ignores the new keys.
        struct OldAgent: Decodable { var id: UUID; var name: String; var model: String; var colorHex: String; var activity: SessionActivity; var sessionID: String? }
        struct OldRoom: Decodable {
            var id: UUID; var title: String; var directory: String; var mode: RoomMode; var agents: [OldAgent]; var leadAgentID: UUID?
            var state: RemoteRoom.State; var permissionMode: PermissionMode; var sessionID: String; var usage: Usage; var lastActivity: Date
        }
        var room = team
        room.agents[0].capped = true
        let encoded = try RemoteCoding.encoder().encode(room)
        let old = try RemoteCoding.decoder().decode(OldRoom.self, from: encoded)
        #expect(old.title == "Add offline sync")
        #expect(old.agents.map(\.name) == ["Ada", "Grace", "Linus"])
        #expect(old.state == .idle)
        // The room's hub row is an ordinary session row.
        let row = try RemoteCoding.decoder().decode(SessionSummary.self, from: RemoteCoding.encoder().encode(RemoteRoomBridge.hubRow(team)))
        #expect(row.roomID == team.id)
    }

    @Test func unknownDecisionPartsDecodeLeniently() throws {
        let json = #"""
        {"id":"d1","kind":"teleport","title":"Something new","items":[],"choices":[
          {"id":"go","label":"Go","style":"sparkly","input":"voice"},{"id":"no","label":"No"}]}
        """#
        let decision = try JSONDecoder().decode(RemoteRoomDecision.self, from: Data(json.utf8))
        #expect(decision.kind == .other)
        #expect(decision.needsYou)
        #expect(decision.choices[0].style == .standard)
        #expect(decision.choices[0].input == .required)
        #expect(decision.choices[1].style == .standard && decision.choices[1].input == .none)

        // A decision that cannot be read at all leaves the rest of the room intact.
        var room = try JSONSerialization.jsonObject(with: RemoteCoding.encoder().encode(team)) as! [String: Any]
        room["decision"] = ["id": 5]
        room["permissions"] = "nonsense"
        let broken = try RemoteCoding.decoder().decode(RemoteRoom.self, from: JSONSerialization.data(withJSONObject: room))
        #expect(broken.decision == nil)
        #expect(broken.permissions.isEmpty)
        #expect(broken.title == team.title)
    }

    /// A Mac's host that predates room decisions.
    final class LegacyHost: RemoteHost, @unchecked Sendable {
        func hubSnapshot() async -> RemoteHubSnapshot { RemoteHubSnapshot(sessions: []) }
        func transcript(sessionID: String) async throws -> RemoteTranscript { throw RemoteError(.notFound, "none") }
        func rooms() async -> [RemoteRoom] { [] }
        func usageSummary() async -> RemoteUsageSummary { RemoteUsageSummary() }
        func updates() async -> AsyncStream<RemoteUpdate> { AsyncStream { $0.finish() } }
        func sendMessage(_ text: String, to target: RemoteTarget, agent: String?) async throws {}
        func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision) async throws {}
        func setPermissionMode(_ mode: PermissionMode, for target: RemoteTarget) async throws {}
        func interrupt(_ target: RemoteTarget) async throws {}
        func controlRoom(_ roomID: UUID, action: RemoteRoomAction) async throws {}
    }

    @Test func hostWithoutRoomDecisionsAnswersUnknownMessage() async {
        let reply = await RemoteDispatcher.respond(
            to: .decideRoom(RemoteRoomDecisionReply(roomID: UUID(), decisionID: "d", choice: "approve")), host: LegacyHost())
        guard case .error(let error) = reply else {
            Issue.record("Expected an error, got \(reply.typeName)")
            return
        }
        #expect(error.code == .unknownMessage)
    }

    @Test func showcaseHubSortsRoomsIntoNeedsYou() {
        let groups = HubBoard.group(data.sessions, now: Date(timeIntervalSince1970: 1_800_000_000))
        let needsYou = Set((groups[.needsYou] ?? []).map(\.id))
        #expect(needsYou.contains(RemoteDemoData.IDs.teamRoomID.uuidString))
        #expect(needsYou.contains(RemoteDemoData.IDs.roomSession))
        let teamRow = data.sessions.first { $0.roomID == RemoteDemoData.IDs.teamRoomID }
        #expect(teamRow?.pendingAsk == "The plan is ready")
    }
}
