#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// A dev server's exit is reported only after its last output, and never waits forever on a pipe a child keeps open.
@MainActor
@Suite("Dev server exit")
struct DevServerExitTests {
    final class Events {
        var lines: [String] = []
        var exit: Int32?
        var linesAtExit: Int?
    }

    func python() -> URL? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3"].map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    func run(_ script: String, folder: URL) throws -> (DevServerProcess, Events) {
        let python = try #require(python(), "python3 is not installed")
        let process = DevServerProcess(executable: python, arguments: ["-I", "-u", "-c", script], folder: folder.path)
        let events = Events()
        process.onOutput = { events.lines.append($0.text) }
        process.onExit = { code in
            events.exit = code
            events.linesAtExit = events.lines.count
        }
        try process.start(environment: ["PATH": "/usr/bin:/bin"])
        return (process, events)
    }

    @Test func outputStillInThePipeComesBeforeTheExit() async throws {
        let folder = FileManager.default.temporaryDirectory
        // A child outside the server's group holds the pipe a moment longer and prints one last line after the server
        // has exited. The exit must wait for it.
        let script = """
        import subprocess, sys
        print('parent')
        subprocess.Popen(['/bin/sh', '-c', 'sleep 0.3; echo late'], start_new_session=True)
        sys.exit(3)
        """
        let (process, events) = try run(script, folder: folder)
        try await waitUntil("the exit to be reported") { events.exit != nil }
        #expect(events.exit == 3)
        #expect(events.lines == ["parent", "late"])
        #expect(events.linesAtExit == 2)
        #expect(!process.isRunning)
    }

    @Test func everyLineOnBothStreamsComesBeforeTheExit() async throws {
        let folder = FileManager.default.temporaryDirectory
        // More output than a pipe holds, on both streams, right up to the exit.
        let script = """
        import sys
        pad = 'x' * 100
        for i in range(1500):
            print(f'out {i} {pad}')
            print(f'err {i} {pad}', file=sys.stderr)
        sys.exit(3)
        """
        let (process, events) = try run(script, folder: folder)
        try await waitUntil("the exit to be reported") { events.exit != nil }
        #expect(events.exit == 3)
        #expect(events.linesAtExit == 3000)
        #expect(events.lines.last(where: { $0.hasPrefix("out") })?.hasPrefix("out 1499 ") == true)
        #expect(events.lines.last(where: { $0.hasPrefix("err") })?.hasPrefix("err 1499 ") == true)
        #expect(!process.isRunning)
    }

    @Test func aChildHoldingThePipeDoesNotHoldTheExit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-devexit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("child-done")
        // The server starts a child in a new session (outside its group, so nothing stops it) that keeps stdout open
        // for a minute and then leaves a marker. The exit has to be reported while the child still holds the pipe; the
        // child is killed when the test ends.
        let script = """
        import subprocess, sys
        child = subprocess.Popen(['/bin/sh', '-c', 'sleep 60; touch "$0"', \(String(reflecting: marker.path))], start_new_session=True)
        print(f'child {child.pid}')
        sys.exit(0)
        """
        // Held like the runner holds its servers: the exit is reported by the process object.
        let (process, events) = try run(script, folder: folder)
        defer {
            for line in events.lines where line.hasPrefix("child ") {
                if let pid = Int32(line.dropFirst(6)), pid > 1 { kill(pid, SIGKILL) }
            }
        }
        try await waitUntil("the exit to be reported") { events.exit != nil }
        #expect(events.exit == 0)
        #expect(events.lines.contains { $0.hasPrefix("child ") })
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the exit waited for the child to close the pipe")
        #expect(!process.isRunning)
    }
}
#endif
