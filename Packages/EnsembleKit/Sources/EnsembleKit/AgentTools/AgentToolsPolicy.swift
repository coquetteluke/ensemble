import Foundation

// The rules the app applies to tool calls, kept apart from the UI so they can be tested: which pages the agent may
// act on, per-origin grants, and the proposal limit.

/// Which pages agents may use. Only `http` and `https` pages on this computer: `localhost`, `.localhost` names,
/// `127.x.x.x` and `[::1]`. Everything else is refused before any prompt.
public enum BrowserAgentOrigin {
    /// `scheme://host:port`, lowercased, with the scheme's default port filled in. Nil for anything but http(s).
    public static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(shownHost):\(port)"
    }

    /// True for http(s) pages on this computer.
    public static func isAllowed(_ url: URL?) -> Bool {
        guard origin(of: url) != nil, let host = url?.host(percentEncoded: false) else { return false }
        return BrowserAddress.isLoopback(host)
    }

    /// Why the agent may not use `url`, or nil.
    public static func refusal(for url: URL?) -> String? {
        guard let url else { return "No page is open in the browser pane. Open one with browser_navigate (a localhost address) or ask the user to open it." }
        guard origin(of: url) != nil else { return "Only http and https pages can be used, not \(url.scheme ?? "this") addresses." }
        guard isAllowed(url) else {
            return "Agents may only use pages on this computer (localhost, 127.0.0.1, [::1] or a .localhost name). \(origin(of: url) ?? url.absoluteString) is not one."
        }
        return nil
    }
}

/// Sites the user allowed for the rest of a session ("Always for this site").
public struct BrowserGrants: Equatable, Sendable {
    private var origins: [String: Set<String>] = [:]

    public init() {}

    public func allows(_ origin: String, session: String) -> Bool {
        origins[session]?.contains(origin) == true
    }

    public mutating func grant(_ origin: String, session: String) {
        origins[session, default: []].insert(origin)
    }

    public mutating func revoke(session: String) {
        origins[session] = nil
    }

    public func origins(for session: String) -> [String] {
        (origins[session] ?? []).sorted()
    }
}

/// At most `limit` proposals per turn. A turn is identified by a key the app derives from the transcript (the number
/// of user messages so far), so a new message from the user starts a new allowance.
public struct ProposalLimiter: Equatable, Sendable {
    public static let perTurn = 3
    private struct Entry: Equatable, Sendable {
        var turn: String
        var count: Int
    }

    private var counts: [String: Entry] = [:]
    public let limit: Int

    public init(limit: Int = ProposalLimiter.perTurn) { self.limit = limit }

    /// Counts a proposal and says whether it is within the limit.
    public mutating func admit(session: String, turn: String) -> Bool {
        var entry = counts[session].flatMap { $0.turn == turn ? $0 : nil } ?? Entry(turn: turn, count: 0)
        guard entry.count < limit else { return false }
        entry.count += 1
        counts[session] = entry
        return true
    }
}

/// Folder rules for `propose_session`: the session's own folder, a folder inside it, or a folder another session uses.
///
/// The folder is kept with every symlink resolved, so the card shows where the session would really run, and it is
/// checked again just before Start (`recheck`): an agent that proposes a folder and then points a link in its path
/// somewhere else (the home folder, another repository) gets a failed card, not a session there.
public enum ProposalFolder {
    /// The folder to use, with every symlink resolved, or why not.
    public static func resolve(_ requested: String?, sessionFolder: String, knownFolders: [String]) -> Result<String, ProposalFolderProblem> {
        let base = WorkspaceTrust.resolvedPath(sessionFolder) ?? sessionFolder
        let asked = requested ?? sessionFolder
        let standard = (asked as NSString).standardizingPath
        // Nil for a dangling link or a loop.
        guard let resolved = WorkspaceTrust.resolvedPath(standard) else { return .failure(.missing(asked)) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.missing(asked))
        }
        if resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") { return .success(resolved) }
        let known = knownFolders.map { WorkspaceTrust.resolvedPath($0) ?? $0 }
        if known.contains(resolved) { return .success(resolved) }
        return .failure(.outside(asked))
    }

    /// Checks a proposal's stored folder again just before a session starts there: it must still pass the rule and
    /// still resolve to exactly the same path. Nil when it does.
    public static func recheck(_ stored: String, sessionFolder: String, knownFolders: [String]) -> ProposalFolderProblem? {
        guard let now = WorkspaceTrust.resolvedPath((stored as NSString).standardizingPath) else { return .missing(stored) }
        if now != stored { return .changed(stored, now: now) }
        if case .failure(let problem) = resolve(stored, sessionFolder: sessionFolder, knownFolders: knownFolders) { return problem }
        return nil
    }
}

/// The permission mode a proposed session starts in: Ask, or the target folder's own default when there is one, and
/// never Bypass. Never the proposing session's mode, so an agent in Auto cannot start another Auto session elsewhere.
public enum ProposalMode {
    public static func mode(folderDefault: PermissionMode?) -> PermissionMode {
        guard let folderDefault, folderDefault != .bypass else { return .ask }
        return folderDefault
    }
}

public enum ProposalFolderProblem: Error, Equatable, Sendable {
    case missing(String)
    case outside(String)
    /// The folder now resolves somewhere else (a link in its path changed after the proposal).
    case changed(String, now: String)

    public var message: String {
        switch self {
        case .missing(let path): "The folder \(path) does not exist."
        case .outside(let path):
            "The folder \(path) is not this session's folder, a folder inside it, or a folder another session uses. Leave folder out to use this session's folder."
        case .changed(let path, let now):
            "The folder \(path) now leads to \(now): a link in its path changed after the proposal. Nothing was started."
        }
    }
}
