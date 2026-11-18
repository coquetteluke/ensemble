#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import EnsembleKit

/// Real dev servers: `python3 -m http.server` in a temporary folder, on free ports. Every test stops what it starts and
/// checks the port is closed and the processes are gone.
@MainActor
@Suite("Dev servers", .serialized)
struct LaunchConfigRunnerTests {
    @MainActor final class Box {
        let root: URL
        let site: URL
        let trust: WorkspaceTrust
        let approvals: LaunchApprovals
        let servers: DevServers
        let python: String?
        var output: [String] = []
        var ready: [URL] = []

        init(trusted: Bool = true) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("ens-dev-\(UUID().uuidString.prefix(8))")
            site = root.appendingPathComponent("site")
            try fm.createDirectory(at: site, withIntermediateDirectories: true)
            try Data("<h1>hello</h1>".utf8).write(to: site.appendingPathComponent("index.html"))
            trust = WorkspaceTrust(fileURL: root.appendingPathComponent("trust.json"), homeDirectory: root.appendingPathComponent("home").path)
            if trusted { try trust.trust(site.path) }
            approvals = LaunchApprovals(fileURL: root.appendingPathComponent("approvals.json"))
            servers = DevServers(trust: trust, approvals: approvals)
            servers.portTimeout = .seconds(20)
            python = LaunchCommand.resolveExecutable("python3", folder: site.path, searchPath: LaunchCommand.searchPath())?.path
            servers.onOutput = { [unowned self] _, line in output.append(line.text) }
            servers.onReady = { [unowned self] _, url in ready.append(url) }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func key(_ entry: LaunchEntry) -> DevServers.Key { DevServers.Key(owner: "ses_1", folder: site.path, name: entry.name) }

        func httpServer(name: String = "web", port: Int) -> LaunchEntry {
            LaunchEntry(name: name, arguments: ["python3", "-u", "-m", "http.server", String(port), "--bind", "127.0.0.1"], port: port)
        }
    }

    /// A port nothing listens on right now.
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Waits up to `seconds` for `condition`, letting main-actor work run.
    func until(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test func untrustedFoldersRunNothing() async throws {
        let box = try Box(trusted: false)
        let port = Self.freePort()
        let entry = box.httpServer(port: port)
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1") == .needsTrust)
        // Confirming does not get past trust.
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1", confirmed: true) == .needsTrust)
        #expect(box.servers.statuses.isEmpty)
        #expect(!box.approvals.isApproved(entry.arguments, folder: box.site.path))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!PortProbe.isListening(port))
    }

    @Test func theFirstStartAsksAndLaterStartsDoNot() async throws {
        let box = try Box()
        let python = try #require(box.python, "python3 is not installed")
        let port = Self.freePort()
        let entry = box.httpServer(port: port)

        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1") == .needsConfirmation(program: python))
        #expect(box.servers.statuses.isEmpty)
        #expect(!PortProbe.isListening(port))

        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1", confirmed: true) == .started)
        #expect(box.servers.status(box.key(entry)) == .starting || box.servers.status(box.key(entry)) == .running(entry.url))
        #expect(await until { box.servers.status(box.key(entry)) == .running(entry.url) })
        #expect(box.ready == [entry.url])
        #expect(PortProbe.isListening(port))
        #expect(await until { box.output.contains { $0.contains("Serving HTTP") } })
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1") == .alreadyRunning)

        await box.servers.stop(box.key(entry))
        #expect(box.servers.status(box.key(entry)) == .stopped)
        #expect(await until(5) { !PortProbe.isListening(port) })

        // Confirmed once: the same command in the same folder starts without asking.
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1") == .started)
        #expect(await until { box.servers.status(box.key(entry)) == .running(entry.url) })
        await box.servers.stop(box.key(entry))
        #expect(await until(5) { !PortProbe.isListening(port) })

        // A changed command is asked about again.
        var changed = entry
        changed.arguments += ["--directory", "."]
        #expect(box.servers.start(changed, folder: box.site.path, owner: "ses_1") == .needsConfirmation(program: python))
    }

    @Test func stopEndsTheWholeTreeEvenAChildInItsOwnSession() async throws {
        let box = try Box()
        _ = try #require(box.python, "python3 is not installed")
        let port = Self.freePort()
        // The parent only waits; the child holds the port, in a session (and process group) of its own.
        let script = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-m', 'http.server', '\(port)', "
            + "'--bind', '127.0.0.1'], start_new_session=True); time.sleep(600)"
        let entry = LaunchEntry(name: "tree", arguments: ["python3", "-c", script], port: port)
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1", confirmed: true) == .started)
        #expect(await until { box.servers.status(box.key(entry)) == .running(entry.url) })

        let root = try #require(box.servers.processID(box.key(entry)))
        let children = [root] + ProcessTree.descendants(of: root)
        #expect(children.count >= 2)
        #expect(ProcessTree.ownGroup(of: root) == root)

        await box.servers.stop(box.key(entry))
        #expect(await until(5) { !PortProbe.isListening(port) })
        #expect(await until(5) { !children.contains(where: ProcessTree.isAlive) })
    }

    @Test func somethingAlreadyOnThePortIsOpenedNotStarted() async throws {
        let box = try Box()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(listen(fd, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let entry = box.httpServer(port: port)
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1") == .portInUse(entry.url))
        #expect(box.servers.statuses.isEmpty)
    }

    @Test func aServerThatExitsSaysSo() async throws {
        let box = try Box()
        _ = try #require(box.python, "python3 is not installed")
        let entry = LaunchEntry(name: "boom", arguments: ["python3", "-u", "-c", "import sys; print('boom'); sys.exit(3)"], port: Self.freePort())
        #expect(box.servers.start(entry, folder: box.site.path, owner: "ses_1", confirmed: true) == .started)
        #expect(await until { box.servers.status(box.key(entry)) == .ended("Exited with code 3.") })
        #expect(box.output.contains("boom"))
    }

    @Test func aMissingProgramIsReported() throws {
        let box = try Box()
        let entry = LaunchEntry(name: "nope", arguments: ["ensemble-no-such-program-xyz"], port: Self.freePort())
        guard case .failed(let message) = box.servers.start(entry, folder: box.site.path, owner: "ses_1", confirmed: true) else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("was not found"))
        #expect(box.servers.statuses.isEmpty)
    }

    @Test func closingASessionOrQuittingStopsItsServers() async throws {
        let box = try Box()
        _ = try #require(box.python, "python3 is not installed")
        let first = box.httpServer(name: "one", port: Self.freePort())
        let second = box.httpServer(name: "two", port: Self.freePort())
        let third = box.httpServer(name: "three", port: Self.freePort())
        #expect(box.servers.start(first, folder: box.site.path, owner: "ses_1", confirmed: true) == .started)
        #expect(box.servers.start(second, folder: box.site.path, owner: "ses_1", confirmed: true) == .started)
        #expect(box.servers.start(third, folder: box.site.path, owner: "ses_2", confirmed: true) == .started)
        #expect(await until { [first, second, third].allSatisfy { PortProbe.isListening($0.port) } })
        #expect(box.servers.activeOwners == ["ses_1", "ses_2"])

        await box.servers.stopAll(owner: "ses_1")
        #expect(await until(5) { !PortProbe.isListening(first.port) && !PortProbe.isListening(second.port) })
        #expect(PortProbe.isListening(third.port))
        #expect(box.servers.activeOwners == ["ses_2"])

        box.servers.stopAllNow()
        #expect(!PortProbe.isListening(third.port))
        #expect(box.servers.activeOwners.isEmpty)
    }
}
#endif
