#if os(macOS)
import Foundation
import Network
import Synchronization
import Testing
@testable import EnsembleKit

/// Alerts through ntfy, against a stub HTTP server on 127.0.0.1 (never a real ntfy server).
@Suite(.serialized) struct NtfyAlertTests {
    /// Built at runtime: not a real credential, and token-shaped literals are kept out of the source.
    static let fakeToken = FakeSecret.make("tk_", 14)

    func settings(_ server: StubHTTPServer, token: String? = nil) -> NtfyAlerts.Settings {
        NtfyAlerts.Settings(server: "http://127.0.0.1:\(server.port)", topic: "ensemble-test_1", accessToken: token)
    }

    @Test func postsOneShortLineWithItsHeaders() async throws {
        let server = try await StubHTTPServer.start()
        defer { server.stop() }
        try await NtfyAlerts.send(.needsYou, title: "Fix login redirect loop", hideTitles: false,
                                  settings: settings(server, token: Self.fakeToken))
        let request = try #require(server.received.first)
        #expect(server.received.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/ensemble-test_1")
        #expect(request.header("Title") == "Ensemble")
        #expect(request.header("Priority") == "4")
        #expect(request.header("Tags") == "raised_hand")
        #expect(request.header("Authorization") == "Bearer " + Self.fakeToken)
        #expect(request.header("Content-Type") == "text/plain; charset=utf-8")
        #expect(request.header("Cookie") == nil)
        #expect(String(decoding: request.body, as: UTF8.self) == "Needs you: Fix login redirect loop")
    }

    @Test func finishedAndFailedHaveTheirOwnLineAndNoTokenMeansNoAuthorization() async throws {
        let server = try await StubHTTPServer.start()
        defer { server.stop() }
        try await NtfyAlerts.send(.finished, title: "Write README install steps", hideTitles: false, settings: settings(server))
        try await NtfyAlerts.send(.failed, title: "Try the new chart library", hideTitles: false, settings: settings(server))
        try await NtfyAlerts.send(.test, title: "ignored", hideTitles: false, settings: settings(server))
        #expect(server.received.map { String(decoding: $0.body, as: UTF8.self) }
                == ["Finished: Write README install steps", "Failed: Try the new chart library", "Test alert from Ensemble"])
        #expect(server.received.map { $0.header("Priority") } == ["3", "3", "3"])
        #expect(server.received.map { $0.header("Tags") } == ["white_check_mark", "x", "bell"])
        #expect(server.received.allSatisfy { $0.header("Authorization") == nil })
    }

    @Test func hideTitlesNamesNoSession() async throws {
        let server = try await StubHTTPServer.start()
        defer { server.stop() }
        for event in [NtfyAlerts.Event.needsYou, .finished, .failed] {
            try await NtfyAlerts.send(event, title: "Fix login redirect loop", hideTitles: true, settings: settings(server))
        }
        let bodies = server.received.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies == ["A session needs you", "A session finished", "A session failed"])
        #expect(!server.received.contains { $0.raw.range(of: Data("redirect loop".utf8)) != nil })
    }

    /// The Mac passes only the session title. Whatever is in the session's transcript (the agent's words, commands,
    /// files, the prompt) never reaches the server, in the body or a header.
    @Test func nothingFromTheTranscriptIsSent() async throws {
        let server = try await StubHTTPServer.start()
        defer { server.stop() }
        let data = RemoteDemoData.sample()
        let session = try #require(data.sessions.first { $0.id == RemoteDemoData.IDs.fixSession })
        let transcript = try #require(data.transcripts[session.id])
        for event in [NtfyAlerts.Event.needsYou, .finished, .failed] {
            try await NtfyAlerts.send(event, title: session.title, hideTitles: false, settings: settings(server, token: "tk_x"))
        }
        var secrets: [String] = [session.directory]
        for item in transcript.items {
            switch item {
            case .user(_, let text, _), .agentText(_, let text, _, _): secrets.append(String(text.prefix(30)))
            case .tool(let tool): secrets.append(tool.title)
            case .permission(let p): secrets += [p.title, p.detail ?? p.title]
            default: break
            }
        }
        #expect(server.received.count == 3)
        for request in server.received {
            for secret in secrets where !secret.isEmpty {
                #expect(request.raw.range(of: Data(secret.utf8)) == nil, "sent \(secret)")
            }
        }
    }

    @Test func titlesLoseLineBreaksPathsAndLength() {
        let message = NtfyAlerts.message(for: .needsYou, title: "Fix /Users/someone/app/main.swift\nand ~/notes.md (see ./build)",
                                         hideTitles: false)
        #expect(message == "Needs you: Fix \u{2026} and \u{2026} (see \u{2026}")
        #expect(!message.contains("/"))
        let long = NtfyAlerts.cleanTitle(String(repeating: "word ", count: 40))
        #expect(long.count == NtfyAlerts.maxTitleLength)
        #expect(NtfyAlerts.message(for: .finished, title: "  \n ", hideTitles: false) == "A session finished")
        #expect(NtfyAlerts.message(for: .failed, title: nil, hideTitles: false) == "A session failed")
        #expect(NtfyAlerts.cleanTitle("Add CI/CD checks") == "Add CI/CD checks")
    }

    @Test func plainHTTPIsRefusedExceptForThisMacAndTailscale() throws {
        #expect(try NtfyAlerts.serverURL("https://ntfy.sh").absoluteString == "https://ntfy.sh")
        #expect(try NtfyAlerts.serverURL("ntfy.example.com").absoluteString == "https://ntfy.example.com")
        #expect(try NtfyAlerts.serverURL("https://example.com/ntfy").absoluteString == "https://example.com/ntfy")
        for allowed in ["http://localhost:8080", "http://127.0.0.1:2586", "http://[::1]:80", "http://mac.tail1234.ts.net",
                        "http://NTFY.TAIL1234.TS.NET.", "http://box.localhost"] {
            #expect(throws: Never.self, "\(allowed)") { _ = try NtfyAlerts.serverURL(allowed) }
        }
        for refused in ["http://ntfy.sh", "http://192.168.1.20", "http://ts.net", "http://evil.ts.net.example.com",
                        "http://100.101.102.103"] {
            #expect(throws: NtfyAlerts.Failure.insecureServer, "\(refused)") { _ = try NtfyAlerts.serverURL(refused) }
        }
        for invalid in ["ftp://ntfy.sh", "https://user:pass@ntfy.sh", "https://ntfy.sh/?topic=x", "https://ntfy.sh/#x", "https://"] {
            #expect(throws: NtfyAlerts.Failure.invalidServer, "\(invalid)") { _ = try NtfyAlerts.serverURL(invalid) }
        }
        #expect(throws: NtfyAlerts.Failure.missingServer) { _ = try NtfyAlerts.serverURL("  ") }
        // Nothing is sent to a refused server.
        #expect(throws: NtfyAlerts.Failure.insecureServer) {
            _ = try NtfyAlerts.request(for: .test, message: "x", settings: .init(server: "http://ntfy.sh", topic: "t"))
        }
    }

    @Test func topicsAreChecked() throws {
        #expect(try NtfyAlerts.topic(" my_topic-2 ") == "my_topic-2")
        for bad in ["", "has space", "slash/topic", "dot.topic", String(repeating: "a", count: 65), "émoji"] {
            #expect(throws: NtfyAlerts.Failure.invalidTopic, "\(bad)") { _ = try NtfyAlerts.topic(bad) }
        }
    }

    @Test func serverRefusalsAreReported() async throws {
        let server = try await StubHTTPServer.start(status: 403)
        defer { server.stop() }
        await #expect(throws: NtfyAlerts.Failure.rejected(status: 403)) {
            try await NtfyAlerts.send(.test, title: nil, hideTitles: false, settings: settings(server, token: "tk_bad"))
        }
        #expect(NtfyAlerts.Failure.rejected(status: 403).errorDescription?.contains("access token") == true)
    }

    /// A redirect could carry the token to another server, so it is not followed.
    @Test func redirectsAreNotFollowed() async throws {
        let target = try await StubHTTPServer.start()
        defer { target.stop() }
        let server = try await StubHTTPServer.start(status: 307, location: "http://127.0.0.1:\(target.port)/stolen")
        defer { server.stop() }
        await #expect(throws: NtfyAlerts.Failure.rejected(status: 307)) {
            try await NtfyAlerts.send(.needsYou, title: "x", hideTitles: false, settings: settings(server, token: "tk_secret"))
        }
        #expect(server.received.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(target.received.isEmpty)
    }

    @Test func limiterSpacesAlertsOut() {
        var limiter = NtfyAlertLimiter(repeatInterval: 60, limit: 3, window: 3600)
        let t0 = Date(timeIntervalSince1970: 1000)
        let steps: [(String, TimeInterval)] = [("needs:s1", 0), ("needs:s1", 10), ("needs:s2", 10), ("needs:s1", 61),
                                                ("needs:s3", 62), ("needs:s3", 3700)]
        let allowed = steps.map { limiter.allow($0.0, now: t0.addingTimeInterval($0.1)) }
        // The same session within a minute is skipped; three an hour at most.
        #expect(allowed == [true, false, true, true, false, true])
    }
}

/// A tiny HTTP/1.1 server on 127.0.0.1 that records each request and answers with a fixed status.
final class StubHTTPServer: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [(String, String)]
        var body: Data
        /// Everything that came over the socket.
        var raw: Data

        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
    }

    let port: UInt16
    private let listener: NWListener
    private let log = Mutex<[Request]>([])
    private let status: Int
    private let location: String?

    var received: [Request] { log.withLock { $0 } }

    private init(listener: NWListener, port: UInt16, status: Int, location: String?) {
        self.listener = listener
        self.port = port
        self.status = status
        self.location = location
    }

    static func start(status: Int = 200, location: String? = nil) async throws -> StubHTTPServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "stub-http")
        let box = Mutex<StubHTTPServer?>(nil)
        listener.newConnectionHandler = { connection in
            guard let server = box.withLock({ $0 }) else { connection.cancel(); return }
            connection.start(queue: queue)
            server.read(connection, buffer: Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Mutex(false)
            listener.stateUpdateHandler = { state in
                let first = once.withLock { done in defer { done = true }; return !done }
                switch state {
                case .ready: if first { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if first { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let server = StubHTTPServer(listener: listener, port: port, status: status, location: location)
        box.withLock { $0 = server }
        return server
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] content, _, isComplete, error in
            var data = buffer
            if let content { data.append(content) }
            if let request = Self.parse(data) {
                log.withLock { $0.append(request) }
                var head = "HTTP/1.1 \(status) Stub\r\nContent-Length: 2\r\nConnection: close\r\n"
                if let location { head += "Location: \(location)\r\n" }
                connection.send(content: Data((head + "\r\n{}").utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read(connection, buffer: data)
            }
        }
    }

    /// A whole request (headers and `Content-Length` bytes of body), or nil while more is needed.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let length = headers.first { $0.0.lowercased() == "content-length" }.flatMap { Int($0.1) } ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: start.first.map(String.init) ?? "", path: start.dropFirst().first.map(String.init) ?? "",
                       headers: headers, body: Data(body.prefix(length)), raw: data)
    }
}
#endif
