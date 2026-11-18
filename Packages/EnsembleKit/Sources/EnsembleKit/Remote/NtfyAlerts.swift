import Foundation

/// Alerts from the Mac to the user's phone through the user's own ntfy server (ntfy.sh or self-hosted), for people
/// whose free Apple account cannot send push notifications. ntfy's iPhone app shows them.
///
/// An alert is one short line: what happened and, unless hidden, the session title with anything that looks like a
/// path taken out. It never carries transcript text, commands or paths. Requests go over HTTPS; plain HTTP is allowed
/// only to this Mac and to Tailscale names, whose traffic Tailscale encrypts. Redirects are not followed, so the token
/// is only ever sent to the server the user typed.
public enum NtfyAlerts {
    /// Where alerts go. Kept in the keychain by the Mac app.
    public struct Settings: Codable, Hashable, Sendable {
        /// The server, e.g. `https://ntfy.sh`.
        public var server: String
        public var topic: String
        /// Optional access token (`tk_...`), sent as `Authorization: Bearer`.
        public var accessToken: String?

        public init(server: String, topic: String, accessToken: String? = nil) {
            self.server = server
            self.topic = topic
            self.accessToken = accessToken
        }
    }

    public enum Event: String, Sendable, CaseIterable {
        case needsYou
        case finished
        case failed
        case test
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case missingServer
        case invalidServer
        /// Plain `http` to a host that is not this Mac or a Tailscale name.
        case insecureServer
        case invalidTopic
        case rejected(status: Int)
        case unreachable(String)

        public var errorDescription: String? {
            switch self {
            case .missingServer: "Enter your ntfy server."
            case .invalidServer: "The server must be a web address such as https://ntfy.sh."
            case .insecureServer: "Use https. Plain http is only allowed for this Mac (localhost) and Tailscale names (*.ts.net)."
            case .invalidTopic: "The topic can use letters, numbers, - and _ (up to 64)."
            case .rejected(let status):
                switch status {
                case 401, 403: "The server refused the alert (\(status)). Check the access token."
                case 429: "The server is limiting alerts (429). Try again later."
                default: "The server answered \(status)."
                }
            case .unreachable(let reason): "Could not reach the server: \(reason)"
            }
        }
    }

    public static let maxTitleLength = 80

    /// The server as a URL, if it is one alerts may go to: `https` anywhere, `http` only for `localhost`, loopback
    /// addresses and `*.ts.net`. No user name or password in the URL, no query or fragment. A name without a scheme
    /// gets `https://`.
    public static func serverURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.missingServer }
        // A bare name means https.
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, let url = components.url else {
            throw Failure.invalidServer
        }
        switch scheme {
        case "https": return url
        case "http":
            guard allowsPlainHTTP(host: host) else { throw Failure.insecureServer }
            return url
        default: throw Failure.invalidServer
        }
    }

    /// True for this Mac and Tailscale names.
    public static func allowsPlainHTTP(host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.hasSuffix(".") { h.removeLast() }
        if ["localhost", "127.0.0.1", "::1"].contains(h) || h.hasSuffix(".localhost") { return true }
        return h.hasSuffix(".ts.net") && h.count > ".ts.net".count
    }

    /// The topic, if ntfy accepts it: letters, digits, `-` and `_`, 1 to 64 characters.
    public static func topic(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...64).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw Failure.invalidTopic
        }
        return trimmed
    }

    /// The alert's one line. `title` is the session title; with `hideTitles`, or without a usable title, the line names
    /// no session.
    public static func message(for event: Event, title: String?, hideTitles: Bool) -> String {
        let shown = hideTitles ? nil : title.map(cleanTitle).flatMap { $0.isEmpty ? nil : $0 }
        switch event {
        case .needsYou: return shown.map { "Needs you: \($0)" } ?? "A session needs you"
        case .finished: return shown.map { "Finished: \($0)" } ?? "A session finished"
        case .failed: return shown.map { "Failed: \($0)" } ?? "A session failed"
        case .test: return "Test alert from Ensemble"
        }
    }

    /// A session title fit for an alert: one line, no control characters, no words that look like paths, at most
    /// `maxTitleLength` characters.
    public static func cleanTitle(_ title: String) -> String {
        let oneLine = String(String.UnicodeScalarView(title.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: " "
            default: scalar
            }
        }))
        let words = oneLine.split(whereSeparator: { $0.isWhitespace }).map(String.init).map { word -> String in
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`([{<"))
            let looksLikePath = bare.hasPrefix("/") || bare.hasPrefix("~/") || bare.hasPrefix("./") || bare.hasPrefix("../")
                || bare.contains(":\\") || bare.hasPrefix("\\\\") || bare.lowercased().hasPrefix("file:")
            return looksLikePath ? "\u{2026}" : word
        }
        var text = words.joined(separator: " ")
        if text.count > maxTitleLength { text = String(text.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        return text
    }

    /// The POST that publishes one alert: the line as a UTF-8 body, an ASCII title, a tag and a priority, and the token
    /// when there is one.
    public static func request(for event: Event, message: String, settings: Settings) throws -> URLRequest {
        let base = try serverURL(settings.server)
        let topic = try topic(settings.topic)
        var request = URLRequest(url: base.appendingPathComponent(topic), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(message.utf8)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Ensemble", forHTTPHeaderField: "Title")
        request.setValue(event == .needsYou ? "4" : "3", forHTTPHeaderField: "Priority")
        request.setValue(tag(event), forHTTPHeaderField: "Tags")
        if let token = settings.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func tag(_ event: Event) -> String {
        switch event {
        case .needsYou: "raised_hand"
        case .finished: "white_check_mark"
        case .failed: "x"
        case .test: "bell"
        }
    }

    /// Publishes one alert. Throws `Failure` when the settings are not usable or the server does not accept it.
    public static func send(_ event: Event, title: String?, hideTitles: Bool, settings: Settings,
                            session: URLSession = NtfyAlerts.session) async throws {
        let request = try request(for: event, message: message(for: event, title: title, hideTitles: hideTitles), settings: settings)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch let error as URLError {
            throw Failure.unreachable(describe(error))
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable("no answer") }
        guard (200..<300).contains(http.statusCode) else { throw Failure.rejected(status: http.statusCode) }
    }

    /// No cookies, no cache, no stored credentials.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: "the server name was not found."
        case .cannotConnectToHost: "the server refused the connection."
        case .timedOut: "the server did not answer in time."
        case .notConnectedToInternet: "this Mac is offline."
        case .appTransportSecurityRequiresSecureConnection: "macOS allows only https to this server."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            "its certificate is not trusted."
        default: error.localizedDescription
        }
    }

    /// Refuses every redirect, so the alert and the token only go to the server that was typed.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}

/// Spaces alerts out: the same event for the same session at most once per `repeatInterval`, and at most `limit`
/// alerts per `window` in all, so a busy evening cannot flood the phone or use up a public server's allowance.
public struct NtfyAlertLimiter: Sendable {
    public var repeatInterval: TimeInterval
    public var limit: Int
    public var window: TimeInterval
    private var lastSent: [String: Date] = [:]
    private var recent: [Date] = []

    public init(repeatInterval: TimeInterval = 60, limit: Int = 30, window: TimeInterval = 3600) {
        self.repeatInterval = repeatInterval
        self.limit = limit
        self.window = window
    }

    /// True (and counted) when an alert with `key` may go now.
    public mutating func allow(_ key: String, now: Date = Date()) -> Bool {
        recent = recent.filter { now.timeIntervalSince($0) < window }
        if let last = lastSent[key], now.timeIntervalSince(last) < repeatInterval { return false }
        guard recent.count < limit else { return false }
        recent.append(now)
        lastSent[key] = now
        if lastSent.count > 512 { lastSent = lastSent.filter { now.timeIntervalSince($0.value) < repeatInterval } }
        return true
    }
}
