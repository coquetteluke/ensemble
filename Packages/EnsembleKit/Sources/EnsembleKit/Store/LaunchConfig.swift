import Foundation

// A folder's dev servers, from `.ensemble/launch.json` (format: docs/reference/launch-json.md). The file comes from the
// repository, so it is read defensively: a regular file of at most 64 KB, strict field types, commands split without
// a shell (`LaunchCommand`), and page addresses limited to this computer. Running a server is `DevServers`' job.

/// One dev server.
public struct LaunchEntry: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    /// The program and its arguments, exactly as they are passed to the program (no shell).
    public var arguments: [String]
    /// The port Ensemble waits for before it loads the page.
    public var port: Int
    /// The page to load once the port answers: `http://localhost:<port>/` unless the file gives a path or a loopback URL.
    public var url: URL

    public var id: String { name }

    /// The command as one line, quoted so it reads back to the same words.
    public var commandLine: String { LaunchCommand.display(arguments) }

    public init(name: String, arguments: [String], port: Int, url: URL? = nil) {
        self.name = name
        self.arguments = arguments
        self.port = port
        self.url = url ?? LaunchEntry.defaultURL(port: port)
    }

    public static func defaultURL(port: Int) -> URL {
        URL(string: "http://localhost:\(port)/") ?? URL(fileURLWithPath: "/")
    }
}

/// The parsed file: the entries that are fine, and one line for each thing that was wrong or left out.
public struct LaunchConfig: Equatable, Sendable {
    public var entries: [LaunchEntry]
    public var problems: [String]

    public init(entries: [LaunchEntry] = [], problems: [String] = []) {
        self.entries = entries
        self.problems = problems
    }

    /// Where the file lives inside a folder.
    public static let relativePath = ".ensemble/launch.json"
    public static let maxBytes = 64 * 1024
    public static let maxEntries = 20
    public static let maxNameLength = 60
    static let knownFields: Set<String> = ["name", "command", "port", "url"]

    public static func fileURL(in folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(relativePath)
    }

    /// Reads a folder's file. Never blocks on odd files: anything but a regular file (a FIFO, a device, a folder) is
    /// refused before it is opened.
    public static func load(folder: String) -> LaunchConfigLoad {
        let url = fileURL(in: folder)
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failed(LaunchConfigError.notAFile.localizedDescription) }
        guard info.st_size <= off_t(maxBytes) else { return .failed(LaunchConfigError.tooLarge.localizedDescription) }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failed(LaunchConfigError.unreadable.localizedDescription)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        do {
            return .loaded(try parse(data))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Parses the file's bytes: a JSON list of `{name, command, port, url?}` objects.
    public static func parse(_ data: Data) throws(LaunchConfigError) -> LaunchConfig {
        guard data.count <= maxBytes else { throw .tooLarge }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw .invalidJSON
        }
        guard let list = root as? [Any] else { throw .notAList }
        var config = LaunchConfig()
        if list.count > maxEntries {
            config.problems.append("Only the first \(maxEntries) of \(list.count) entries are read.")
        }
        var names: Set<String> = []
        for (index, item) in list.prefix(maxEntries).enumerated() {
            let label = "Entry \(index + 1)"
            guard let object = item as? [String: Any] else {
                config.problems.append("\(label) is not an object.")
                continue
            }
            switch entry(from: object) {
            case .failure(let problem):
                let name = (object["name"] as? String).map(clean).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : " (\($0))" } ?? ""
                config.problems.append("\(label)\(name): \(problem.message)")
            case .success(let entry):
                let unknown = object.keys.filter { !knownFields.contains($0) }.sorted()
                if !unknown.isEmpty {
                    config.problems.append("\(entry.name): unknown " + (unknown.count == 1 ? "field " : "fields ")
                                           + unknown.map { "\"\(clean($0))\"" }.joined(separator: ", ") + " left out.")
                }
                guard names.insert(entry.name.lowercased()).inserted else {
                    config.problems.append("\(label) (\(entry.name)): another entry already has this name.")
                    continue
                }
                config.entries.append(entry)
            }
        }
        return config
    }

    struct Problem: Error { let message: String }

    static func entry(from object: [String: Any]) -> Result<LaunchEntry, Problem> {
        guard let rawName = object["name"] as? String else { return .failure(Problem(message: "\"name\" must be text.")) }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(Problem(message: "\"name\" is empty.")) }
        guard name.count <= maxNameLength else { return .failure(Problem(message: "\"name\" is longer than \(maxNameLength) characters.")) }
        guard !name.contains(where: LaunchCommand.isControl) else {
            return .failure(Problem(message: "\"name\" has a line break or another control character."))
        }

        let arguments: [String]
        do {
            switch object["command"] {
            case let text as String:
                arguments = try LaunchCommand.split(text)
            case let list as [Any]:
                let words = list.compactMap { $0 as? String }
                guard words.count == list.count else { return .failure(Problem(message: "\"command\" must be text or a list of text.")) }
                arguments = try LaunchCommand.validate(words)
            case nil:
                return .failure(Problem(message: "\"command\" is missing."))
            default:
                return .failure(Problem(message: "\"command\" must be text or a list of text."))
            }
        } catch {
            return .failure(Problem(message: error.localizedDescription))
        }

        guard let port = integer(object["port"]) else {
            return .failure(Problem(message: object["port"] == nil ? "\"port\" is missing." : "\"port\" must be a whole number from 1 to 65535."))
        }
        guard (1...65535).contains(port) else { return .failure(Problem(message: "\"port\" must be a whole number from 1 to 65535.")) }

        var url: URL?
        if let value = object["url"] {
            guard let text = value as? String else { return .failure(Problem(message: "\"url\" must be text.")) }
            switch pageURL(text, port: port) {
            case .success(let resolved): url = resolved
            case .failure(let problem): return .failure(problem)
            }
        }
        return .success(LaunchEntry(name: name, arguments: arguments, port: port, url: url))
    }

    /// A JSON number that is a whole number (not true or false, which `JSONSerialization` also gives as numbers).
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    /// `"/admin"` (a path on the server) or a full `http`/`https` URL on this computer (`localhost`, a `.localhost`
    /// name, `127.0.0.1` or `[::1]`). A file in a repository may not point the pane at other sites.
    static func pageURL(_ text: String, port: Int) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(where: LaunchCommand.isControl), !trimmed.contains(" ") else {
            return .failure(Problem(message: "\"url\" is not a web address."))
        }
        if trimmed.hasPrefix("/") && !trimmed.hasPrefix("//") {
            guard let url = URL(string: "http://localhost:\(port)\(trimmed)") else {
                return .failure(Problem(message: "\"url\" is not a web address."))
            }
            return .success(url)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), url.user == nil, url.password == nil else {
            return .failure(Problem(message: "\"url\" must be a path such as /admin, or an http address on this computer."))
        }
        guard BrowserAddress.isLoopback(host) else {
            return .failure(Problem(message: "\"url\" must point at this computer (localhost, 127.0.0.1 or [::1])."))
        }
        return .success(url)
    }

    /// Names and keys from the file, shortened and without control characters, for problem lines.
    static func clean(_ text: String) -> String {
        let visible = String(text.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(Character.init))
        return visible.count > 40 ? String(visible.prefix(40)) + "\u{2026}" : visible
    }
}

/// What reading a folder's file gave.
public enum LaunchConfigLoad: Equatable, Sendable {
    /// The folder has no `.ensemble/launch.json`.
    case missing
    /// The file is there but could not be used; the reason, in a line.
    case failed(String)
    case loaded(LaunchConfig)

    public var entries: [LaunchEntry] {
        if case .loaded(let config) = self { return config.entries }
        return []
    }
}

public enum LaunchConfigError: Error, LocalizedError, Equatable, Sendable {
    case notAFile
    case tooLarge
    case unreadable
    case invalidJSON
    case notAList

    public var errorDescription: String? {
        switch self {
        case .notAFile: "\(LaunchConfig.relativePath) is not a regular file."
        case .tooLarge: "\(LaunchConfig.relativePath) is larger than 64 KB."
        case .unreadable: "\(LaunchConfig.relativePath) could not be read."
        case .invalidJSON: "\(LaunchConfig.relativePath) is not valid JSON."
        case .notAList: "\(LaunchConfig.relativePath) must be a list of servers: [{\"name\": ..., \"command\": ..., \"port\": ...}]."
        }
    }
}
