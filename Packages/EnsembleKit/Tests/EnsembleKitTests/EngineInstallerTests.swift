#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

@Suite struct EngineInstallerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Choosing the release (a trimmed copy of OpenCode's real release list)

    @Test func picksTheNewestTwoPointRelease() throws {
        let release = try EngineInstaller.newestRelease(in: Fixtures.data("opencode-releases.json"))
        #expect(release.version == "2.3.2")
        #expect(release.download.absoluteString == "https://github.com/anomalyco/opencode/releases/download/v2.3.2/opencode-darwin-arm64.zip")
        #expect(release.sha256 == "31ab5a06a29edc7e49b895f35c2b64ebfe7c7f0437b0f2581b006efcd79fee1a")
        #expect(release.size == 109_126_744)
    }

    @Test func ignoresOlderLinesAndOtherProducts() throws {
        // 1.19.6 is what GitHub calls "latest", and process-daemon releases share the list.
        #expect(EngineInstaller.version(fromTag: "v2.3.2") == [2, 3, 2])
        #expect(EngineInstaller.version(fromTag: "process-daemon-v0.6.0") == nil)
        #expect(EngineInstaller.version(fromTag: "v2.3") == nil)
        #expect(EngineInstaller.version(fromTag: "v2.3.x") == nil)
        let onlyOld = try JSONSerialization.data(withJSONObject: [
            release("v1.19.6"), release("process-daemon-v0.6.0"), release("v2.2.7"),
        ])
        #expect(throws: EngineInstaller.InstallError.noRelease) { try EngineInstaller.newestRelease(in: onlyOld) }
    }

    @Test func skipsDraftsPrereleasesAndDownloadsItCannotCheck() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            release("v2.9.0", prerelease: true),
            release("v2.8.0", draft: true),
            release("v2.7.0", digest: nil),
            release("v2.6.0", digest: "sha256:nothex"),
            release("v2.5.0", asset: "opencode-linux-x64.tar.gz"),
            release("v2.4.1", url: "http://example.com/opencode-darwin-arm64.zip"),
            release("v2.4.0"),
            release("v3.0.0"),
        ])
        #expect(try EngineInstaller.newestRelease(in: json).version == "2.4.0")
    }

    @Test func reportsAListItCannotRead() {
        #expect(throws: EngineInstaller.InstallError.noRelease) { try EngineInstaller.newestRelease(in: Data("not json".utf8)) }
        #expect(throws: EngineInstaller.InstallError.noRelease) { try EngineInstaller.newestRelease(in: Data("[]".utf8)) }
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false,
                         digest: String? = "sha256:" + String(repeating: "ab", count: 32),
                         asset: String = EngineInstaller.assetName,
                         url: String = "https://example.com/opencode-darwin-arm64.zip") -> [String: Any] {
        var item: [String: Any] = ["name": asset, "size": 10, "browser_download_url": url]
        if let digest { item["digest"] = digest }
        return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": [item]]
    }

    // MARK: Checks

    @Test func hashesAFile() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("hello.txt")
        try Data("hello\n".utf8).write(to: file)
        #expect(try EngineInstaller.sha256(of: file) == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    @Test func aProgramAppleSignedIsNotFromOpenCode() {
        #expect(!EngineInstaller.isSigned(URL(fileURLWithPath: "/usr/bin/true"), byTeam: EngineInstaller.publisherTeam))
    }

    // MARK: The whole install, from files on disk instead of the network

    /// A release list and a zip in `folder`, holding a stand-in `opencode` that reports `version`.
    private func makeRelease(in folder: URL, version: String, tag: String = "v2.4.0", wrongDigest: Bool = false) throws -> URL {
        let payload = folder.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let program = payload.appendingPathComponent("opencode")
        try "#!/bin/sh\necho \"opencode v\(version)\"\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let zip = folder.appendingPathComponent(EngineInstaller.assetName)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", payload.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let digest = wrongDigest ? String(repeating: "00", count: 32) : try EngineInstaller.sha256(of: zip)
        let list = folder.appendingPathComponent("releases.json")
        try JSONSerialization.data(withJSONObject: [[
            "tag_name": tag, "draft": false, "prerelease": false,
            "assets": [["name": EngineInstaller.assetName, "size": 1, "digest": "sha256:\(digest)", "browser_download_url": zip.absoluteString]],
        ]]).write(to: list)
        return list
    }

    @Test func installsACheckedDownload() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = try makeRelease(in: folder, version: "2.4.0")
        let destination = folder.appendingPathComponent("home/.opencode/bin")
        let stages = StageRecorder()
        let installer = EngineInstaller(releases: list, destinationFolder: destination, requirePublisherSignature: false)
        let version = try await installer.install { stages.add($0) }
        #expect(version == "2.4.0")
        #expect(FileManager.default.isExecutableFile(atPath: installer.installedURL.path))
        #expect(EngineInstaller.reportedVersion(of: installer.installedURL) == [2, 4, 0])
        #expect(stages.names == ["finding", "downloading", "checking", "installing"])
        // What the setup screens look for.
        #expect(EngineSetup.detect(engineSearchPaths: [destination.path], homebrewDirectories: []).openCodeInstalled)
    }

    @Test func replacesAnOlderEngine() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = try makeRelease(in: folder, version: "2.4.0")
        let destination = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let old = destination.appendingPathComponent("opencode")
        try "#!/bin/sh\necho \"opencode v2.3.0\"\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        let installer = EngineInstaller(releases: list, destinationFolder: destination, requirePublisherSignature: false)
        #expect(try await installer.install() == "2.4.0")
        #expect(EngineInstaller.reportedVersion(of: old) == [2, 4, 0])
    }

    @Test func throwsAwayADownloadWithTheWrongChecksum() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = try makeRelease(in: folder, version: "2.4.0", wrongDigest: true)
        let installer = EngineInstaller(releases: list, destinationFolder: folder.appendingPathComponent("bin"), requirePublisherSignature: false)
        await #expect(throws: EngineInstaller.InstallError.wrongChecksum) { try await installer.install() }
        #expect(!FileManager.default.fileExists(atPath: installer.installedURL.path))
    }

    @Test func refusesADownloadOpenCodeDidNotSign() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = try makeRelease(in: folder, version: "2.4.0")
        let installer = EngineInstaller(releases: list, destinationFolder: folder.appendingPathComponent("bin"))
        await #expect(throws: EngineInstaller.InstallError.notFromOpenCode) { try await installer.install() }
        #expect(!FileManager.default.fileExists(atPath: installer.installedURL.path))
    }

    @Test func refusesAnEngineThatIsTooOldOrDoesNotStart() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = try makeRelease(in: folder, version: "2.2.9")
        let installer = EngineInstaller(releases: list, destinationFolder: folder.appendingPathComponent("bin"), requirePublisherSignature: false)
        await #expect(throws: EngineInstaller.InstallError.doesNotRun) { try await installer.install() }
        #expect(!FileManager.default.fileExists(atPath: installer.installedURL.path))
    }

    @Test func reportsAListThatIsNotThere() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installer = EngineInstaller(releases: folder.appendingPathComponent("missing.json"), destinationFolder: folder.appendingPathComponent("bin"))
        do {
            try await installer.install()
            Issue.record("expected an error")
        } catch let error as EngineInstaller.InstallError {
            guard case .noAnswer = error else { Issue.record("unexpected \(error)"); return }
        }
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ stage: EngineInstaller.Stage) {
        let name: String = switch stage {
        case .finding: "finding"
        case .downloading: "downloading"
        case .checking: "checking"
        case .installing: "installing"
        }
        lock.lock()
        if seen.last != name { seen.append(name) }
        lock.unlock()
    }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}
#endif
