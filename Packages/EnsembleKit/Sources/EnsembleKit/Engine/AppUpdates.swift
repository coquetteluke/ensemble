import Foundation

/// A version such as "0.1.0" or "v1.2": dot-separated numbers, compared number by number. A leading "v" and
/// anything after a hyphen or plus ("-beta", "+build5") are ignored for the comparison.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let numbers: [Int]

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        numbers = parts.compactMap { $0 }
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let left = index < a.numbers.count ? a.numbers[index] : 0
            let right = index < b.numbers.count ? b.numbers[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// One published release, as the project's release feed lists it.
public struct AppRelease: Decodable, Equatable, Sendable {
    public var tag: String
    public var name: String?
    /// The release's page, where the download is.
    public var page: URL
    public var isDraft: Bool
    public var isPrerelease: Bool
    public var published: Date?

    public var version: AppVersion? { AppVersion(tag) }

    public init(tag: String, name: String? = nil, page: URL, isDraft: Bool = false, isPrerelease: Bool = false, published: Date? = nil) {
        self.tag = tag
        self.name = name
        self.page = page
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.published = published
    }

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, page = "html_url", isDraft = "draft", isPrerelease = "prerelease", published = "published_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        page = try c.decode(URL.self, forKey: .page)
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        isPrerelease = try c.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        published = (try c.decodeIfPresent(String.self, forKey: .published)).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// What a check for updates found.
public enum AppUpdateResult: Equatable, Sendable {
    case upToDate(current: AppVersion)
    case available(AppRelease, current: AppVersion)
}

public enum AppUpdates {
    /// The project's public release feed. Reading it sends nothing about the user or the Mac.
    public static let feed = URL(string: "https://api.github.com/repos/coquetteluke/ensemble/releases?per_page=20")!
    /// Only pages on the project's own releases are ever opened from an update notice.
    public static let pagePrefix = "https://github.com/coquetteluke/ensemble/releases/"

    public static func decode(_ data: Data) throws -> [AppRelease] {
        try JSONDecoder().decode([AppRelease].self, from: data)
    }

    /// The newest published release above `current`, if any. Drafts and tags that are not versions are ignored;
    /// pre-releases count unless `includePrereleases` is off. A release whose page is not on the project's own
    /// releases is ignored too, so a tampered feed cannot send the user elsewhere.
    public static func result(current: AppVersion, releases: [AppRelease], includePrereleases: Bool = true) -> AppUpdateResult {
        let newer = releases
            .filter { !$0.isDraft && (includePrereleases || !$0.isPrerelease) }
            .filter { $0.page.absoluteString.hasPrefix(pagePrefix) }
            .compactMap { release in release.version.map { (release: release, version: $0) } }
            .filter { $0.version > current }
            .max { $0.version < $1.version }
        if let newer { return .available(newer.release, current: current) }
        return .upToDate(current: current)
    }
}

/// Fetches the release feed. The app uses `URLSessionReleaseFeed`; tests and sample data pass their own.
public protocol AppReleaseFeed: Sendable {
    func releases() async throws -> [AppRelease]
}

public struct URLSessionReleaseFeed: AppReleaseFeed {
    public init() {}

    public func releases() async throws -> [AppRelease] {
        var request = URLRequest(url: AppUpdates.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // A plain client name: no version, machine or account details.
        request.setValue("Ensemble", forHTTPHeaderField: "User-Agent")
        // No cookies or saved credentials go with the request.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppUpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try AppUpdates.decode(data)
    }
}

public enum AppUpdateError: LocalizedError, Equatable {
    case badResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .badResponse(403), .badResponse(429): "The release list is busy right now. Try again in a few minutes."
        case .badResponse(let status): "The release list did not answer (status \(status))."
        }
    }
}
