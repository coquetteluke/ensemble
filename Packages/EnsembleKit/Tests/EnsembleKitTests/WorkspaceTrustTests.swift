import Foundation
import Observation
import Testing
@testable import EnsembleKit

@Suite("Workspace trust")
struct WorkspaceTrustTests {
    /// A fake home with a few projects and links, in a temporary folder.
    final class Box: @unchecked Sendable {
        let folder: URL
        let home: URL
        let app: URL
        let other: URL
        let file: URL

        init() throws {
            let fm = FileManager.default
            folder = fm.temporaryDirectory.appendingPathComponent("ens-trust-\(UUID().uuidString.prefix(8))")
            home = folder.appendingPathComponent("home")
            app = home.appendingPathComponent("code/app")
            other = home.appendingPathComponent("code/other")
            file = home.appendingPathComponent("code/readme.txt")
            try fm.createDirectory(at: app.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
            try fm.createSymbolicLink(at: home.appendingPathComponent("link-app"), withDestinationURL: app)
            try fm.createSymbolicLink(at: app.appendingPathComponent("escape"), withDestinationURL: other)
            try fm.createSymbolicLink(at: app.appendingPathComponent("dangling"),
                                      withDestinationURL: folder.appendingPathComponent("nowhere/new.txt"))
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        var storeURL: URL { folder.appendingPathComponent("trusted-folders.json") }
        func store() -> WorkspaceTrust { WorkspaceTrust(fileURL: storeURL, homeDirectory: home.path) }
        func real(_ url: URL) -> String { WorkspaceTrust.resolvedPath(url.path) ?? "?" }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var value: Bool { lock.withLock { raised } }
    }

    @Test func parentsTrustChildrenAndPathsAreResolved() throws {
        let box = try Box()
        let trust = box.store()
        #expect(!trust.isTrusted(box.app.path))
        try trust.trust(box.app.path)
        #expect(trust.folders == [box.real(box.app)])
        #expect(trust.isTrusted(box.app.path))
        #expect(trust.isTrusted(box.app.appendingPathComponent("sub").path))
        #expect(trust.isTrusted(box.app.appendingPathComponent("not/made/yet").path))
        // A link to the folder is the folder; a link inside it that points elsewhere is not trusted.
        #expect(trust.isTrusted(box.home.appendingPathComponent("link-app").path))
        #expect(!trust.isTrusted(box.app.appendingPathComponent("escape").path))
        #expect(!trust.isTrusted(box.app.appendingPathComponent("dangling").path))
        #expect(!trust.isTrusted(box.other.path))
        #expect(!trust.isTrusted(box.home.appendingPathComponent("code/application").path))
        #expect(!trust.isTrusted("code/app"))
        #expect(!trust.isTrusted(box.app.path + "/../other"))

        // Saved and read back by a new store.
        #expect(box.store().isTrusted(box.app.appendingPathComponent("sub").path))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: box.storeURL)) as? [String: Any]
        #expect(saved?["folders"] as? [String] == [box.real(box.app)])

        // Revoking through the link removes the resolved entry.
        try trust.revoke(box.home.appendingPathComponent("link-app").path)
        #expect(!trust.isTrusted(box.app.path))
        #expect(!box.store().isTrusted(box.app.path))

        // Revoking a parent removes trusted folders inside it; revoking a child leaves a trusted parent in place.
        try trust.trust(box.app.appendingPathComponent("sub").path)
        try trust.revoke(box.home.appendingPathComponent("code").path)
        #expect(trust.folders.isEmpty)
        try trust.trust(box.home.appendingPathComponent("code").path)
        try trust.revoke(box.app.path)
        #expect(trust.isTrusted(box.app.path))
    }

    @Test func refusesTooBroadAndMissingFolders() throws {
        let box = try Box()
        let trust = box.store()
        #expect(throws: WorkspaceTrustError.self) { try trust.trust(box.home.path) }
        #expect(throws: WorkspaceTrustError.self) { try trust.trust(box.folder.path) }
        #expect(throws: WorkspaceTrustError.self) { try trust.trust("/") }
        #expect(throws: WorkspaceTrustError.self) { try trust.trust(box.app.path + "/../../..") }
        #expect(throws: WorkspaceTrustError.notAFolder(box.home.appendingPathComponent("missing").path)) {
            try trust.trust(box.home.appendingPathComponent("missing").path)
        }
        #expect(throws: WorkspaceTrustError.self) { try trust.trust(box.file.path) }
        #expect(throws: WorkspaceTrustError.self) { try trust.trust("relative/folder") }
        #expect(trust.folders.isEmpty)
    }

    @Test func changesAreObservable() throws {
        let box = try Box()
        let trust = box.store()
        let listChanged = Flag()
        withObservationTracking { _ = trust.folders } onChange: { listChanged.raise() }
        let checkChanged = Flag()
        withObservationTracking { _ = trust.isTrusted(box.app.path) } onChange: { checkChanged.raise() }
        try trust.trust(box.app.path)
        #expect(listChanged.value)
        #expect(checkChanged.value)
    }

    @Test func resolvedPathsForNewFilesAndLinks() throws {
        let box = try Box()
        let app = box.real(box.app)
        #expect(app.hasPrefix("/"))
        #expect(WorkspaceTrust.resolvedPath(box.app.appendingPathComponent("new/file.txt").path) == app + "/new/file.txt")
        #expect(WorkspaceTrust.resolvedPath(box.app.appendingPathComponent("sub/../x.txt").path) == app + "/x.txt")
        #expect(WorkspaceTrust.resolvedPath(box.app.appendingPathComponent("escape/x.txt").path) == box.real(box.other) + "/x.txt")
        #expect(WorkspaceTrust.resolvedPath(box.app.appendingPathComponent("dangling").path) == nil)
        #expect(WorkspaceTrust.resolvedPath(box.app.appendingPathComponent("dangling/x").path) == nil)
        #expect(WorkspaceTrust.resolvedPath(box.app.appendingPathComponent("missing/../x").path) == nil)
        #expect(WorkspaceTrust.resolvedPath("relative") == nil)
        #if os(macOS)
        #expect(WorkspaceTrust.resolvedPath("/tmp")?.hasPrefix("/private/tmp") == true)
        #endif
    }
}
