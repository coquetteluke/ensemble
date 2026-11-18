import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// Answers requests from a per-host handler so tests can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    typealias Handler = @Sendable (Recorded) -> (status: Int, body: String)

    static let handlers = Mutex<[String: Handler]>([:])
    static let recorded = Mutex<[String: [Recorded]]>([:])

    static func register(host: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func requests(host: String) -> [Recorded] {
        recorded.withLock { $0[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let entry = Recorded(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.recorded.withLock { $0[host, default: []].append(entry) }
        let handler = Self.handlers.withLock { $0[host] }
        let (status, text) = handler?(entry) ?? (404, #"{"_tag":"NotFound","message":"no stub"}"#)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct OpenCodeClientRequestTests {
    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (OpenCodeClient, String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = OpenCodeClient(baseURL: URL(string: "http://\(host):4096")!, password: "secret",
                                    defaultDirectory: "/tmp/project dir", configuration: configuration)
        return (client, host)
    }

    private func json(_ data: Data?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(data))
    }

    @Test func sendsBasicAuth() async throws {
        let (client, host) = makeClient { _ in (200, #"{"version":"2.3.0","pid":1,"urls":[],"paths":{"tmp":"/tmp"}}"#) }
        let info = try await client.serverInfo()
        #expect(info.version == "2.3.0")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url.path == "/api/info")
        // base64("opencode:secret")
        #expect(request.headers["Authorization"] == "Basic b3BlbmNvZGU6c2VjcmV0")
    }

    @Test func createsSessionWithPermissionRules() async throws {
        let session = try Fixtures.text("session.json")
        let (client, host) = makeClient { _ in (200, session) }
        let created = try await client.createSession(directory: "/tmp/ensemble-probe", model: ModelRef(providerID: "mock", id: "mock-1", variant: "high"),
                                                     agent: "build", permissionMode: .ask, parentID: "ses_parent")
        #expect(created.id == "ses_e13556bb5ffeY1uEs1EG2lGeBf")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/session")
        let body = try json(request.body)
        #expect(body["location"]?["directory"] == "/tmp/ensemble-probe")
        #expect(body["model"] == ["providerID": "mock", "id": "mock-1", "variant": "high"])
        #expect(body["agent"] == "build")
        #expect(body["parentID"] == "ses_parent")
        let rules = try #require(body["permissions"]?.arrayValue)
        #expect(rules.contains(["action": "shell", "resource": "*", "effect": "ask"]))
        #expect(rules.count == PermissionRules.ruleset(for: .ask).count)
    }

    @Test func promptsWithFileAttachments() async throws {
        let (client, host) = makeClient { _ in (200, #"{"data":{}}"#) }
        try await client.prompt("ses_1", text: "look", files: [URL(fileURLWithPath: "/tmp/a b.txt")])
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url.path == "/api/session/ses_1/prompt")
        let body = try json(request.body)
        #expect(body["text"] == "look")
        #expect(body["files"] == [["uri": "file:///tmp/a%20b.txt", "name": "a b.txt"]])
        #expect(body["delivery"] == nil)
    }

    @Test func injectsSyntheticWithWake() async throws {
        let (client, host) = makeClient { _ in (200, #"{"data":{}}"#) }
        try await client.injectSynthetic("ses_1", text: "[Board] hi", wake: true)
        try await client.injectSynthetic("ses_1", text: "later", wake: false)
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.url.path) == ["/api/session/ses_1/synthetic", "/api/session/ses_1/synthetic"])
        #expect(try json(requests[0].body) == ["text": "[Board] hi", "resume": true])
        #expect(try json(requests[1].body) == ["text": "later", "resume": false])
    }

    @Test func repliesToPermissions() async throws {
        let (client, host) = makeClient { _ in (200, "") }
        try await client.replyPermission(sessionID: "ses_1", requestID: "per_2", decision: .once, message: nil)
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url.path == "/api/session/ses_1/permission/per_2/reply")
        #expect(try json(request.body) == ["decision": "once"])
    }

    @Test func encodesLocationQuery() async throws {
        let (client, host) = makeClient { _ in (200, #"{"location":{"directory":"/tmp/project dir"},"data":[]}"#) }
        _ = try await client.connectors()
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url.query(percentEncoded: true) == "location%5Bdirectory%5D=%2Ftmp%2Fproject%20dir")
    }

    @Test func followsMessageCursorsWithoutRepeatingOrder() async throws {
        let firstPage: String = {
            let items = (0..<200).map { #"{"id":"msg_\#($0)","type":"user","time":{"created":\#($0)},"text":"m\#($0)"}"# }
            return #"{"data":[\#(items.joined(separator: ","))],"cursor":{"previous":null,"next":"c2"}}"#
        }()
        let secondPage = #"{"data":[{"id":"msg_last","type":"user","time":{"created":1},"text":"last"}],"cursor":{"previous":"c1","next":"c3"}}"#
        let (client, host) = makeClient { request in
            request.url.query?.contains("cursor=c2") == true ? (200, secondPage) : (200, firstPage)
        }
        let items = try await client.transcript("ses_1")
        #expect(items.count == 201)
        #expect(items.last == .user(id: "msg_last", text: "last", date: Date(timeIntervalSince1970: 0.001)))
        // (The transcript also reads the session, for a staged revert to hide.)
        let requests = StubURLProtocol.requests(host: host).filter { $0.url.path.hasSuffix("/message") }
        #expect(requests.count == 2)
        #expect(requests[0].url.query?.contains("order=asc") == true)
        #expect(requests[1].url.query?.contains("order=") == false)
    }

    @Test func mapsErrorBodies() async throws {
        let (client, _) = makeClient { _ in
            (403, #"{"_tag":"ForbiddenError","message":"Scheduled tasks are disabled; set experimental.schedules in config"}"#)
        }
        await #expect(throws: OpenCodeError.http(status: 403, tag: "ForbiddenError",
                                                 message: "Scheduled tasks are disabled; set experimental.schedules in config")) {
            try await client.setSchedulePaused("sch_1", paused: true)
        }
    }

    @Test func removesEveryCredentialOfAProvider() async throws {
        let (client, host) = makeClient { request in
            if request.method == "GET" {
                return (200, #"{"data":[{"id":"cred_a","integrationID":"openai","label":"x","active":true,"value":{"type":"key","key":"k1"}},{"id":"cred_b","integrationID":"anthropic","label":"y","active":true,"value":{"type":"key","key":"k2"}},{"id":"cred_c","integrationID":"openai","label":"z","active":false,"value":{"type":"key","key":"k3"}}]}"#)
            }
            return (204, "")
        }
        try await client.removeAPIKey(providerID: "openai")
        let deletes = StubURLProtocol.requests(host: host).filter { $0.method == "DELETE" }.map(\.url.path)
        #expect(deletes == ["/api/credential/cred_a", "/api/credential/cred_c"])
    }

    @Test func eventStreamReconnectsAndRefreshesRenamedSessions() async throws {
        let session = try Fixtures.text("session.json")
        let stream = """
            data: {"id":"evt_1","type":"server.connected","data":{}}

            : heartbeat

            data: {"id":"evt_2","created":1,"type":"session.renamed","data":{"sessionID":"ses_e13556bb5ffeY1uEs1EG2lGeBf","title":"Mock session"}}

            data: {"id":"evt_3","created":2,"type":"session.text.delta","data":{"sessionID":"ses_1","assistantMessageID":"msg_1","ordinal":0,"delta":"Hi"}}


            """
        let (client, host) = makeClient { request in
            request.url.path == "/api/event" ? (200, stream) : (200, session)
        }
        var received: [EngineEvent] = []
        for await event in client.events() {
            received.append(event)
            if received.filter({ $0 == .other(type: "server.connected") }).count == 2 { break }
        }
        #expect(received.first == .other(type: "server.connected"))
        #expect(received.contains { if case .sessionUpdated(let s) = $0 { s.id == "ses_e13556bb5ffeY1uEs1EG2lGeBf" && s.title == "Mock session" } else { false } })
        #expect(received.contains(.textDelta(sessionID: "ses_1", itemID: "msg_1:text:0", delta: "Hi")))
        let eventRequests = StubURLProtocol.requests(host: host).filter { $0.url.path == "/api/event" }
        #expect(eventRequests.count == 2)
        #expect(eventRequests[0].headers["Accept"] == "text/event-stream")
        #expect(eventRequests[0].headers["Authorization"] == "Basic b3BlbmNvZGU6c2VjcmV0")
    }

    @Test func setsAPIKeyThroughTheIntegration() async throws {
        let (client, host) = makeClient { _ in (204, "") }
        try await client.setAPIKey(providerID: "anthropic", key: "  sk-test-not-real \n")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url.path == "/api/integration/anthropic/connect/key")
        #expect(try json(request.body) == ["key": "sk-test-not-real", "label": "Ensemble"])
        await #expect(throws: OpenCodeError.self) { try await client.setAPIKey(providerID: "anthropic", key: " ") }
    }
}
