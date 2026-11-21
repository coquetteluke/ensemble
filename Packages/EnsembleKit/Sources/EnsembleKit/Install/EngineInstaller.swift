#if os(macOS)
import Foundation
import CryptoKit

/// Downloads OpenCode, the engine, straight from OpenCode's own releases, so nobody needs Homebrew.
/// It only runs when the person presses a button (or asks for it on the command line), and it installs nothing it
/// could not check: the download must match the checksum OpenCode publishes, be signed by OpenCode's Apple developer
/// team, and answer `--version` with a version Ensemble can use.
/// Foundation and CryptoKit only: the installer app compiles this file on its own, without the rest of EnsembleKit.
public struct EngineInstaller: Sendable {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let download: URL
        /// Lowercase hex.
        public let sha256: String
        public let size: Int64
    }

    public enum Stage: Equatable, Sendable {
        case finding
        case downloading(fraction: Double)
        case checking
        case installing
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        case noAnswer(String)
        case noRelease
        case wrongChecksum
        case notFromOpenCode
        case badArchive
        case doesNotRun
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noAnswer(let reason): "OpenCode could not be downloaded. \(reason)"
            case .noRelease: "No OpenCode download that Ensemble can use was found."
            case .wrongChecksum: "The download did not match the checksum OpenCode publishes, so it was thrown away."
            case .notFromOpenCode: "The download is not signed by OpenCode, so it was thrown away."
            case .badArchive: "The download could not be unpacked."
            case .doesNotRun: "The downloaded OpenCode did not start, so it was not installed."
            case .failed(let reason): "OpenCode was not installed. \(reason)"
            }
        }
    }

    /// OpenCode's releases on GitHub. Its "latest" release is still the 1.x line, so the list is read instead.
    public static let releasesURL = URL(string: "https://api.github.com/repos/anomalyco/opencode/releases?per_page=30")!
    /// The Apple silicon command line build.
    public static let assetName = "opencode-darwin-arm64.zip"
    /// The oldest OpenCode Ensemble works with. Only releases with the same first number are used.
    public static let minimumVersion = [2, 3, 0]
    /// OpenCode's Apple developer team (Anomaly Innovations, Inc.). The download must be signed by it.
    public static let publisherTeam = "5NZ4Q7NXJ4"

    public var releases: URL
    /// Where `opencode` goes: `~/.opencode/bin`, the folder OpenCode's own installer uses and Ensemble looks in.
    public var destinationFolder: URL
    /// Tests install a stand-in that OpenCode did not sign.
    public var requirePublisherSignature: Bool

    public init(releases: URL = EngineInstaller.releasesURL,
                destinationFolder: URL = EngineInstaller.defaultDestination(),
                requirePublisherSignature: Bool = true) {
        self.releases = releases
        self.destinationFolder = destinationFolder
        self.requirePublisherSignature = requirePublisherSignature
    }

    public static func defaultDestination() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".opencode/bin", isDirectory: true)
    }

    public var installedURL: URL { destinationFolder.appendingPathComponent("opencode") }

    // MARK: Choosing the release

    private struct ListedRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64?
            let digest: String?
            let browser_download_url: String
        }
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// `v2.3.2` to `[2, 3, 2]`. Anything else (for example `process-daemon-v0.6.0`) is not an OpenCode release.
    static func version(fromTag tag: String) -> [Int]? {
        guard tag.hasPrefix("v") else { return nil }
        let parts = tag.dropFirst().split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// The newest finished release with the same first number as `minimum`, at least `minimum`, that has the Mac
    /// download with a published SHA-256.
    public static func newestRelease(in json: Data, assetName: String = EngineInstaller.assetName,
                                     minimum: [Int] = EngineInstaller.minimumVersion) throws -> Release {
        guard let listed = try? JSONDecoder().decode([ListedRelease].self, from: json) else { throw InstallError.noRelease }
        var best: (version: [Int], release: Release)?
        for item in listed where item.draft != true && item.prerelease != true {
            guard let version = version(fromTag: item.tag_name), version.first == minimum.first,
                  !version.lexicographicallyPrecedes(minimum),
                  let asset = item.assets.first(where: { $0.name == assetName }),
                  let digest = asset.digest, digest.hasPrefix("sha256:"),
                  let url = URL(string: asset.browser_download_url), url.scheme == "https" || url.isFileURL else { continue }
            let sha = String(digest.dropFirst("sha256:".count)).lowercased()
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { continue }
            if let current = best, !current.version.lexicographicallyPrecedes(version) { continue }
            best = (version, Release(version: version.map(String.init).joined(separator: "."), download: url, sha256: sha,
                                     size: asset.size ?? 0))
        }
        guard let best else { throw InstallError.noRelease }
        return best.release
    }

    // MARK: Checks

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the file carries a valid Developer ID signature from the given Apple developer team.
    public static func isSigned(_ file: URL, byTeam team: String) -> Bool {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        return run("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", file.path])?.status == 0
    }

    /// The version a program reports for `--version`, for example `[2, 3, 2]`.
    public static func reportedVersion(of program: URL) -> [Int]? {
        guard let result = run(program.path, ["--version"], timeout: 30), result.status == 0 else { return nil }
        guard let match = result.output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return result.output[match].split(separator: ".").compactMap { Int($0) }
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Installing

    /// Finds, downloads, checks and installs OpenCode. Returns the version installed.
    @discardableResult
    public func install(progress: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> String {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("ensemble-engine-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        defer { try? files.removeItem(at: work) }

        progress(.finding)
        let release = try Self.newestRelease(in: try await fetch(releases))

        progress(.downloading(fraction: 0))
        let archive = work.appendingPathComponent(Self.assetName)
        try await download(release.download, to: archive, expectedSize: release.size, progress: progress)

        progress(.checking)
        guard (try? Self.sha256(of: archive)) == release.sha256 else { throw InstallError.wrongChecksum }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])?.status == 0 else { throw InstallError.badArchive }
        let program = unpacked.appendingPathComponent("opencode")
        guard files.fileExists(atPath: program.path) else { throw InstallError.badArchive }
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        if requirePublisherSignature, !Self.isSigned(program, byTeam: Self.publisherTeam) { throw InstallError.notFromOpenCode }
        guard let reported = Self.reportedVersion(of: program), !reported.lexicographicallyPrecedes(Self.minimumVersion) else {
            throw InstallError.doesNotRun
        }

        progress(.installing)
        do {
            try files.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            if files.fileExists(atPath: installedURL.path) {
                _ = try files.replaceItemAt(installedURL, withItemAt: program)
            } else {
                try files.moveItem(at: program, to: installedURL)
            }
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        return reported.map(String.init).joined(separator: ".")
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ensemble-Installer", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.noAnswer("GitHub answered with status \(http.statusCode). Try again in a few minutes.")
            }
            return data
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.noAnswer(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to destination: URL, expectedSize: Int64,
                          progress: @escaping @Sendable (Stage) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Ensemble-Installer", forHTTPHeaderField: "User-Agent")
        let watcher = DownloadWatcher(expectedSize: expectedSize) { progress(.downloading(fraction: $0)) }
        do {
            let (file, response) = try await URLSession.shared.download(for: request, delegate: watcher)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.noAnswer("The download answered with status \(http.statusCode).")
            }
            try FileManager.default.moveItem(at: file, to: destination)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.noAnswer(error.localizedDescription)
        }
    }
}

/// Reports how much of the download has arrived.
private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate, Sendable {
    private let expectedSize: Int64
    private let report: @Sendable (Double) -> Void

    init(expectedSize: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        guard total > 0 else { return }
        report(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
#endif
