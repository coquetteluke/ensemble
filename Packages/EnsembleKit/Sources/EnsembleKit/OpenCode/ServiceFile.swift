import Foundation

/// The OpenCode background service's registration file, `~/.local/state/opencode/service.json`
/// (or `$XDG_STATE_HOME/opencode/service.json`). It holds the URL, process id and the service password.
///
/// The password is never included in `description`, logs or errors.
public struct ServiceFile: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: String?
    public var version: String?
    public var url: URL
    public var pid: Int32?
    public var password: String

    public init(id: String? = nil, version: String? = nil, url: URL, pid: Int32? = nil, password: String) {
        self.id = id
        self.version = version
        self.url = url
        self.pid = pid
        self.password = password
    }

    public var description: String {
        "ServiceFile(url: \(url.absoluteString), pid: \(pid.map(String.init) ?? "nil"), version: \(version ?? "nil"), password: <hidden>)"
    }

    public var debugDescription: String { description }

    /// Default location of `service.json` for the current user.
    public static var defaultURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state).appendingPathComponent("opencode/service.json")
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #endif
        return home.appendingPathComponent(".local/state/opencode/service.json")
    }

    /// Reads and decodes the file. Throws `OpenCodeError.serviceFileMissing` when it does not exist.
    public static func read(from url: URL = ServiceFile.defaultURL) throws -> ServiceFile {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OpenCodeError.serviceFileMissing }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ServiceFile.self, from: data)
        } catch {
            throw OpenCodeError.invalidResponse("service.json could not be read")
        }
    }
}

public enum OpenCodeError: Error, LocalizedError, Equatable, Sendable {
    /// The engine answered with an error status. `tag` is OpenCode's error type, e.g. `ForbiddenError`.
    case http(status: Int, tag: String?, message: String)
    case invalidResponse(String)
    case decoding(String)
    case serviceFileMissing
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let tag, let message):
            let detail = message.isEmpty ? (tag ?? "error") : message
            return "OpenCode returned \(status): \(detail)"
        case .invalidResponse(let message): return "Unexpected response from OpenCode: \(message)"
        case .decoding(let message): return "Could not read OpenCode's response: \(message)"
        case .serviceFileMissing: return "The OpenCode service is not running (no service.json)."
        case .invalidArgument(let message): return message
        }
    }

    public var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }
}
