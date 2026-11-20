import Foundation
import Testing
@testable import EnsembleKit

@MainActor struct RemoteSessionDetailsTests {
    func roundTrip<M>(_ frame: RemoteFrame<M>) throws -> RemoteFrame<M> {
        try RemoteCoding.decode(RemoteFrame<M>.self, from: try RemoteCoding.encode(frame))
    }

    let sample = RemoteSessionDetails(
        sessionID: "s1", macName: "Studio Mac", directory: "/Users/me/code/app", extraFolders: ["/Users/me/code/lib"],
        context: ContextBreakdown(usedTokens: 90_000, limitTokens: 200_000, categories: [
            .init(key: "messages", label: "Messages", tokens: 80_000),
            .init(key: "tools", label: "Tools", tokens: 10_000),
        ]),
        outputs: [FileChange(path: "a.swift", kind: .modified, additions: 3, deletions: 1)],
        connectors: [ConnectorInfo(id: "gh", name: "GitHub", state: .connected, toolCount: 12)])

    @Test func requestRoundTrips() throws {
        let frame = RemoteClientFrame(.sessionDetails(sessionID: "s1"), id: "9")
        #expect(try roundTrip(frame) == frame)
        let json = try JSONSerialization.jsonObject(with: RemoteCoding.encode(frame)) as? [String: Any]
        #expect(json?["type"] as? String == "sessionDetails")
        #expect((json?["data"] as? [String: Any])?["sessionID"] as? String == "s1")
    }

    @Test func replyRoundTrips() throws {
        let frame = RemoteServerFrame(.sessionDetails(sample), replyTo: "9")
        #expect(try roundTrip(frame) == frame)
    }

    @Test func missingKeysBecomeDefaults() throws {
        let details = try RemoteCoding.decoder().decode(RemoteSessionDetails.self, from: Data(#"{"sessionID":"s1"}"#.utf8))
        #expect(details == RemoteSessionDetails(sessionID: "s1", macName: "", directory: ""))

        let partial = try RemoteCoding.decoder().decode(RemoteSessionDetails.self, from: Data(
            #"{"sessionID":"s2","macName":"Mac","directory":"/x","outputs":[{"path":"b.md","kind":"added","additions":2,"deletions":0}]}"#.utf8))
        #expect(partial.context == nil)
        #expect(partial.extraFolders.isEmpty)
        #expect(partial.connectors.isEmpty)
        #expect(partial.outputs.map(\.path) == ["b.md"])
        #expect(partial.outputs.first?.diff == nil)
    }

    @Test func olderMacAnswersUnknownMessage() async {
        let reply = await RemoteDispatcher.respond(to: .sessionDetails(sessionID: "s1"),
                                                   host: RemoteRoomProtocolTests.LegacyHost())
        guard case .error(let error) = reply else {
            Issue.record("Expected an error, got \(reply.typeName)")
            return
        }
        #expect(error.code == .unknownMessage)
    }

    @Test func demoHostAnswersDetails() async throws {
        let host = DemoRemoteHost()
        let c = RemoteClient(inProcessHost: host)
        c.start()
        defer { c.stop() }
        try await waitUntil { c.sessions.count == 4 }

        for id in [RemoteDemoData.IDs.fixSession, RemoteDemoData.IDs.roomSession, RemoteDemoData.IDs.docsSession,
                   RemoteDemoData.IDs.oldSession] {
            let details = try await c.details(sessionID: id)
            #expect(details.sessionID == id)
            #expect(details.macName == RemoteDemoData.macName)
            #expect(!details.directory.isEmpty)
            let context = try #require(details.context)
            #expect(context.fractionUsed >= 0.4 && context.fractionUsed <= 0.6)
            #expect(context.categories.count >= 4)
            #expect((3...5).contains(details.outputs.count))
            #expect(details.outputs.allSatisfy { $0.diff == nil })
            #expect(details.connectors.count == 3)
            #expect(Set(details.connectors.map(\.state)).count == 3)
        }
        #expect(await host.recordedActions.contains(.sessionDetails(sessionID: RemoteDemoData.IDs.fixSession)))

        await #expect(throws: RemoteError.self) {
            try await c.details(sessionID: "does-not-exist")
        }
    }
}
