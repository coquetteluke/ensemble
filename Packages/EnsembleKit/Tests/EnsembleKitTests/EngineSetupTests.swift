#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

@Suite struct EngineSetupTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-setup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ name: String, in directory: URL, script: String = "#!/bin/sh\n") throws {
        let file = directory.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test func detectsNothingOnAnEmptyMac() throws {
        let empty = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        let setup = EngineSetup.detect(engineSearchPaths: [empty.path, "/nonexistent"], homebrewDirectories: [empty.path])
        #expect(setup == EngineSetup(homebrewInstalled: false, openCodeInstalled: false))
    }

    @Test func detectsHomebrewAndOpenCodeSeparately() throws {
        let brewDirectory = try temporaryDirectory()
        let engineDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: brewDirectory)
            try? FileManager.default.removeItem(at: engineDirectory)
        }
        try makeExecutable("brew", in: brewDirectory)
        #expect(EngineSetup.detect(engineSearchPaths: [engineDirectory.path], homebrewDirectories: [brewDirectory.path])
                == EngineSetup(homebrewInstalled: true, openCodeInstalled: false))
        try makeExecutable("opencode", in: engineDirectory)
        #expect(EngineSetup.detect(engineSearchPaths: ["/nonexistent", engineDirectory.path], homebrewDirectories: [brewDirectory.path])
                == EngineSetup(homebrewInstalled: true, openCodeInstalled: true))
    }

    @Test func aFileThatCannotRunDoesNotCount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not a program".write(to: directory.appendingPathComponent("opencode"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("opencode").path)
        #expect(!EngineSetup.detect(engineSearchPaths: [directory.path], homebrewDirectories: []).openCodeInstalled)
    }

    @Test func listsHomebrewOnlyWhenItWasMissing() {
        let missing = EngineSetup(homebrewInstalled: false, openCodeInstalled: false)
        #expect(missing.steps(includeHomebrew: true).map(\.kind) == [.homebrew, .openCode])
        #expect(missing.steps(includeHomebrew: true).map(\.done) == [false, false])
        #expect(missing.steps(includeHomebrew: false).map(\.kind) == [.openCode])
    }

    @Test func keepsTheHomebrewStepTickedOnceItIsInstalled() {
        let halfway = EngineSetup(homebrewInstalled: true, openCodeInstalled: false)
        let steps = halfway.steps(includeHomebrew: true)
        #expect(steps.map(\.kind) == [.homebrew, .openCode])
        #expect(steps.map(\.done) == [true, false])
    }

    @Test func commandsAreTheOfficialOnes() {
        #expect(EngineSetup.openCodeCommand == "brew install opencode")
        #expect(EngineSetup.homebrewCommand.contains("https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"))
        #expect(EngineSetup(homebrewInstalled: false, openCodeInstalled: false).steps(includeHomebrew: true).map(\.command)
                == [EngineSetup.homebrewCommand, EngineSetup.openCodeCommand])
    }

    /// Check again and the automatic check can land together. Two checks at once must start the service once.
    @Test @MainActor func checksAtTheSameTimeStartTheServiceOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls.log")
        try makeExecutable("opencode", in: directory, script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "opencode v2.3.0"; exit 0; fi
            echo "$*" >> "\(log.path)"
            sleep 1
            exit 1

            """)
        let manager = EngineManager(serviceFileURL: directory.appendingPathComponent("service.json"), searchPaths: [directory.path])
        manager.startupAttempts = 1
        async let first = manager.checkNow()
        async let second = manager.checkNow()
        let results = await [first, second]
        #expect(results == [false, false])
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        #expect(calls == ["service start"])
    }
}
#endif
