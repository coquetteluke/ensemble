#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

@Suite struct AppInstallerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in app bundle: an Info.plist with a version and one program file.
    private func makePayload(in folder: URL, version: String = "1.2.3", marker: String = "new") throws -> URL {
        let app = folder.appendingPathComponent("Ensemble.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try marker.write(to: macOS.appendingPathComponent("Ensemble"), atomically: true, encoding: .utf8)
        return app
    }

    private func quarantine(_ url: URL) {
        let value = "0083;00000000;Safari;"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    private func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    @Test func installsIntoAnEmptyFolderAndClearsTheDownloadMark() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root.appendingPathComponent("installer"))
        quarantine(payload)
        quarantine(payload.appendingPathComponent("Contents/MacOS/Ensemble"))
        let destination = root.appendingPathComponent("Applications")
        let stages = Recorder()
        let installed = try AppInstaller(payload: payload, destinationFolder: destination)
            .install(progress: { stages.add($0) }, verify: { _ in true })
        #expect(installed.path == destination.appendingPathComponent("Ensemble.app").path)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Ensemble"), encoding: .utf8) == "new")
        #expect(!isQuarantined(installed))
        #expect(!isQuarantined(installed.appendingPathComponent("Contents/MacOS/Ensemble")))
        // The installer's own copy is left as it was.
        #expect(isQuarantined(payload))
        #expect(stages.values == [.copying, .checking, .finishing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Ensemble.app"])
    }

    @Test func replacesAnOlderCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Applications")
        _ = try makePayload(in: destination, version: "0.9", marker: "old")
        let payload = try makePayload(in: root.appendingPathComponent("installer"), version: "1.0", marker: "new")
        let installed = try AppInstaller(payload: payload, destinationFolder: destination).install(verify: { _ in true })
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Ensemble"), encoding: .utf8) == "new")
        #expect(AppInstaller.version(of: installed) == "1.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { !$0.hasPrefix(".") } == ["Ensemble.app"])
    }

    @Test func aCopyThatFailsItsCheckIsRemovedAndTheOldAppStays() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Applications")
        let old = try makePayload(in: destination, marker: "old")
        let payload = try makePayload(in: root.appendingPathComponent("installer"), marker: "new")
        #expect(throws: AppInstaller.InstallError.damaged) {
            try AppInstaller(payload: payload, destinationFolder: destination).install(verify: { _ in false })
        }
        #expect(try String(contentsOf: old.appendingPathComponent("Contents/MacOS/Ensemble"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Ensemble.app"])
    }

    @Test func reportsAMissingPayload() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AppInstaller(payload: root.appendingPathComponent("Ensemble.app"), destinationFolder: root.appendingPathComponent("Applications"))
        #expect(throws: AppInstaller.InstallError.payloadMissing) { try installer.install(verify: { _ in true }) }
    }

    @Test func reportsAFolderItMayNotChange() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Applications").path)
            try? FileManager.default.removeItem(at: root)
        }
        let payload = try makePayload(in: root.appendingPathComponent("installer"))
        let destination = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)
        #expect(throws: AppInstaller.InstallError.notWritable(destination.path)) {
            try AppInstaller(payload: payload, destinationFolder: destination).install(verify: { _ in true })
        }
    }

    @Test func fallsBackToTheAccountsOwnApplicationsFolder() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        let open = root.appendingPathComponent("open")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        #expect(AppInstaller.defaultDestination(systemApplications: open, home: root).path == open.path)
        #expect(AppInstaller.defaultDestination(systemApplications: locked, home: root).path == root.appendingPathComponent("Applications").path)
    }

    @Test func readsTheVersionOfAnApp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root, version: "0.1.0")
        #expect(AppInstaller.version(of: payload) == "0.1.0")
        #expect(AppInstaller.version(of: root.appendingPathComponent("Missing.app")) == nil)
    }

    @Test func theRealSignatureCheckRefusesAnUnsignedFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(!AppInstaller.signatureIsValid(payload))
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [AppInstaller.Stage] = []
    func add(_ stage: AppInstaller.Stage) { lock.lock(); stages.append(stage); lock.unlock() }
    var values: [AppInstaller.Stage] { lock.lock(); defer { lock.unlock() }; return stages }
}
#endif
