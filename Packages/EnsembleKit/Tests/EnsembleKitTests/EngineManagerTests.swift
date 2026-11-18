#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

@Suite struct EngineManagerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func locatesAnExecutableOnTheSearchPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("opencode")
        try "#!/bin/sh\necho opencode v9.9.9\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(EngineManager.locate(in: ["/nonexistent", directory.path])?.lastPathComponent == "opencode")
        #expect(EngineManager.locate(in: ["/nonexistent"]) == nil)
    }

    @Test func runsCommandsAndReadsOutput() async throws {
        let result = try #require(await EngineManager.run(URL(fileURLWithPath: "/bin/echo"), ["opencode", "v2.3.0"], timeout: 10))
        #expect(result.status == 0)
        #expect(EngineVersion(result.output) == EngineVersion("2.3.0"))
    }

    @Test func checksProcesses() {
        #expect(EngineManager.processIsAlive(getpid()))
        #expect(!EngineManager.processIsAlive(0))
        #expect(!EngineManager.processIsAlive(Int32.max - 1))
    }

    @Test @MainActor func reportsNotInstalled() async throws {
        let manager = EngineManager(serviceFileURL: URL(fileURLWithPath: "/nonexistent/service.json"), searchPaths: ["/nonexistent"])
        let updates = manager.statusUpdates()
        #expect(await manager.checkNow() == false)
        #expect(manager.status == .notInstalled)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .starting)
        #expect(await iterator.next() == .notInstalled)
    }

    @Test @MainActor func reportsTooOld() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("opencode")
        try "#!/bin/sh\necho opencode v2.2.1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let manager = EngineManager(serviceFileURL: directory.appendingPathComponent("service.json"), searchPaths: [directory.path])
        #expect(await manager.checkNow() == false)
        #expect(manager.status == .tooOld(found: "2.2.1", required: EnsembleKit.minimumEngineVersion))
    }
}
#endif
