#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import EnsembleKit

/// Live end-to-end tests against a real local `wrangler dev` relay worker (`workerd`).
///
/// Opt-in only: runs when `ENSEMBLE_LIVE_RELAY=1` is set in the environment so normal `swift test` never launches
/// `wrangler dev`. Reads `ENSEMBLE_RELAY_URL` (defaults to `ws://127.0.0.1:8787`). If nothing is listening on the
/// target port yet, the test starts `npx wrangler dev --local --port <port>` in `<repo-root>/relay/` in its own
/// process group and terminates the entire group on exit.
enum RelayLiveConfig {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_RELAY"] == "1"
    }

    static var relayURL: URL {
        let raw = ProcessInfo.processInfo.environment["ENSEMBLE_RELAY_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (raw?.isEmpty == false) ? raw! : "ws://127.0.0.1:8787"
        return URL(string: text) ?? URL(string: "ws://127.0.0.1:8787")!
    }
}

@MainActor @Suite(.serialized) struct RelayLiveTests {
    @Test(.enabled(if: RelayLiveConfig.enabled))
    func endToEndThroughWranglerDev() async throws {
        let relayURL = RelayLiveConfig.relayURL
        let worker = try await WranglerDevProcess.ensureRunning(for: relayURL)
        defer { worker?.stop() }

        // Build a DemoRemoteHost with a >5 MiB transcript entry to test large Mac-to-phone frames through workerd.
        let largeSessionID = "sess-large-5mib"
        let largePayload = Self.makeLargePayload(bytes: 5 * 1024 * 1024 + 64 * 1024)
        var data = RemoteDemoData.sample()
        let largeSummary = SessionSummary(
            id: largeSessionID,
            title: "Large 5 MiB transcript",
            directory: "/Users/luke/Ensemble",
            activity: .idle,
            lastActivity: Date(),
            usage: .zero
        )
        data.sessions.append(largeSummary)
        data.transcripts[largeSessionID] = RemoteTranscript(
            sessionID: largeSessionID,
            title: largeSummary.title,
            items: [
                .user(id: "u-large", text: "Send the big output", date: Date().addingTimeInterval(-2)),
                .agentText(id: "a-large", text: largePayload, agentID: nil, streaming: false),
            ],
            activity: .idle,
            permissionMode: .ask
        )

        let host = DemoRemoteHost(data: data)
        let identity = RelayIdentity.make()
        let token = RemoteToken.generate()
        let pairingRelay = RemotePairing.Relay(url: relayURL.absoluteString, mailbox: identity.mailboxID)

        // Short heartbeat (1 s -> drop timeout 4 s) to verify idle WebSocket ping/pong survival through workerd.
        let config = RemoteServer.Configuration(
            port: 0,
            bindAddresses: ["127.0.0.1"],
            macName: "Live Relay Mac",
            heartbeatInterval: .seconds(1),
            helloTimeout: .seconds(30),
            activeRelay: pairingRelay
        )
        let server = RemoteServer(host: host, token: token, configuration: config)
        try await server.start()

        let relayHost = RelayHost(relayURL: relayURL, identity: identity, token: token, server: server)
        await relayHost.start()

        // Relay-only pairing (hosts: []) forces all traffic through wrangler dev.
        let pairing = RemotePairing(
            hosts: [],
            port: remoteDefaultPort,
            token: token,
            macName: "Live Relay Mac",
            relay: pairingRelay
        )
        let client = RemoteClient(
            pairing: pairing,
            deviceName: "Live Test iPhone",
            deviceID: "live-phone-\(UUID().uuidString)"
        )
        client.handshakeTimeout = .seconds(30)
        client.requestTimeout = .seconds(60)
        client.pingInterval = .seconds(1)

        do {
            try await pollUntil("RelayHost to claim and sign in on wrangler dev", timeout: .seconds(30)) {
                await relayHost.status == .connected
            }

            client.start()

            // 1. Pair and receive initial hubSnapshot, rooms, and usage over the real relay.
            try await waitUntil("RemoteClient to connect through wrangler dev", timeout: .seconds(30)) {
                client.state == .connected(via: .relay)
                    && client.sessions.count == data.sessions.count
                    && client.rooms.count == data.rooms.count
                    && client.usage != nil
            }
            #expect(client.macName == "Live Relay Mac")
            #expect(client.statusText == "Connected through the relay")

            let initialDevices = await server.status.devices
            #expect(initialDevices.count == 1)
            let initialPeerID = try #require(initialDevices.first?.id)
            #expect(initialDevices.first?.address.hasPrefix("relay:") == true)

            // 2. Real transcript round trip: open session, send a message, observe host action and live update.
            try await client.open(sessionID: RemoteDemoData.IDs.fixSession)
            #expect(client.openTranscript?.sessionID == RemoteDemoData.IDs.fixSession)
            #expect((client.openTranscript?.items.count ?? 0) >= 2)

            let roundTripText = "Hello through real wrangler dev"
            try await client.send(roundTripText, to: .session(RemoteDemoData.IDs.fixSession))
            let actionsAfterFirstSend = await host.recordedActions
            #expect(actionsAfterFirstSend == [
                .sendMessage(text: roundTripText, target: .session(RemoteDemoData.IDs.fixSession), agent: nil),
            ])
            try await waitUntil("transcript upsert from host to arrive on phone", timeout: .seconds(15)) {
                client.openTranscript?.items.contains {
                    if case .user(_, let text, _) = $0 { return text == roundTripText }
                    return false
                } == true
            }

            // 3. 5 MiB frame: open the >5 MiB transcript from Mac to phone through workerd, byte-for-byte.
            try await client.open(sessionID: largeSessionID)
            #expect(client.openTranscript?.sessionID == largeSessionID)
            let receivedLargeText: String? = client.openTranscript?.items.compactMap { item in
                if case .agentText(let id, let text, _, _) = item, id == "a-large" { return text }
                return nil
            }.first
            let actualPayload = try #require(receivedLargeText)
            #expect(actualPayload.utf8.count == largePayload.utf8.count)
            #expect(actualPayload.utf8.count > 5 * 1024 * 1024)
            #expect(actualPayload == largePayload)

            // 4. Idle WebSocket ping/pong survival: stay idle for 5.5 s (> 4 s server heartbeat limit at 1 s interval,
            //    and > 5 client ping intervals). If workerd does not answer WebSocket .ping frames on either socket,
            //    the connection drops or reconnects with a new peer ID.
            try await Task.sleep(for: .milliseconds(5500))

            #expect(client.state == .connected(via: .relay))
            let devicesAfterIdle = await server.status.devices
            #expect(devicesAfterIdle.count == 1)
            #expect(devicesAfterIdle.first?.id == initialPeerID)

            // Confirm the same idle connection still carries sealed traffic cleanly.
            let postIdleText = "Still alive after idle pings"
            try await client.send(postIdleText, to: .session(RemoteDemoData.IDs.fixSession))
            let finalActions = await host.recordedActions
            #expect(finalActions.count == 2)
            #expect(finalActions.last == .sendMessage(text: postIdleText, target: .session(RemoteDemoData.IDs.fixSession), agent: nil))

            client.stop()
            await relayHost.stop()
            await server.stop()
        } catch {
            client.stop()
            await relayHost.stop()
            await server.stop()
            throw error
        }
    }

    private static func makeLargePayload(bytes: Int) -> String {
        let chunk = "0123456789abcdef-ensemble-relay-5mib-frame-check-line-content-\n"
        let repeats = (bytes / chunk.utf8.count) + 1
        var out = String()
        out.reserveCapacity(repeats * chunk.utf8.count)
        for i in 0..<repeats {
            // Vary a few characters per line so truncation or block repetition cannot hide.
            let tag = String(format: "%06d:", i)
            out.append(tag)
            out.append(chunk)
        }
        return out
    }
}

/// Manages a local `npx wrangler dev --local` child process in its own process group so `stop()` cleanly terminates
/// `npx`, `wrangler`, and `workerd` with no orphaned processes.
private final class WranglerDevProcess: Sendable {
    private let process: Process
    private let persistDir: URL
    private let logPipe: Pipe

    private init(process: Process, persistDir: URL, logPipe: Pipe) {
        self.process = process
        self.persistDir = persistDir
        self.logPipe = logPipe
    }

    /// Reuses an already-running relay if `GET /v1/nope` returns 404; otherwise spawns `wrangler dev` for loopback URLs.
    static func ensureRunning(for relayURL: URL) async throws -> WranglerDevProcess? {
        guard let probeURL = httpProbeURL(from: relayURL) else {
            throw LiveTimeout(what: "a valid ENSEMBLE_RELAY_URL (\(relayURL.absoluteString))")
        }
        if await probeReturns404(probeURL) {
            return nil
        }

        let host = relayURL.host(percentEncoded: false)?.lowercased() ?? "127.0.0.1"
        guard host == "127.0.0.1" || host == "localhost" else {
            throw LiveTimeout(what: "relay at \(probeURL.absoluteString) to answer 404 (cannot auto-launch non-loopback)")
        }
        let port = relayURL.port ?? 8787

        let relayDir = LiveConfig.repoRoot.appendingPathComponent("relay", isDirectory: true)
        guard FileManager.default.fileExists(atPath: relayDir.appendingPathComponent("wrangler.toml").path) else {
            throw LiveTimeout(what: "relay/wrangler.toml under \(LiveConfig.repoRoot.path)")
        }

        let persistDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("ensemble-wrangler-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: persistDir, withIntermediateDirectories: true)

        var wranglerArgs = [
            "npx", "wrangler", "dev",
            "--local",
            "--port", "\(port)",
            "--persist-to", persistDir.path,
            "--show-interactive-dev-session=false",
        ]
        if host == "127.0.0.1" {
            wranglerArgs.append(contentsOf: ["--ip", "127.0.0.1"])
        }

        let process = Process()
        // Use perl setsid() + exec so the child becomes its own process group leader (pgid == pid).
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MPOSIX=setsid", "-e", "setsid(); exec @ARGV or die $!", "--"] + wranglerArgs
        process.currentDirectoryURL = relayDir

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let missing = extraPaths.filter { !currentPath.split(separator: ":").contains(Substring($0)) }
        if !missing.isEmpty {
            env["PATH"] = (missing + [currentPath]).joined(separator: ":")
        }
        env["CI"] = "1"
        env["WRANGLER_SEND_METRICS"] = "false"
        process.environment = env

        let logPipe = Pipe()
        process.standardOutput = logPipe
        process.standardError = logPipe
        process.standardInput = FileHandle.nullDevice

        let logBuffer = LogBuffer()
        logPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            logBuffer.append(chunk)
        }

        do {
            try process.run()
        } catch {
            logPipe.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: persistDir)
            throw error
        }

        let wrapper = WranglerDevProcess(process: process, persistDir: persistDir, logPipe: logPipe)
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                let output = logBuffer.text()
                wrapper.stop()
                throw LiveTimeout(what: "wrangler dev exited early (status \(process.terminationStatus)):\n\(output)")
            }
            if await probeReturns404(probeURL) {
                return wrapper
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let output = logBuffer.text()
        wrapper.stop()
        throw LiveTimeout(what: "wrangler dev at \(probeURL.absoluteString) to return 404:\n\(output)")
    }

    func stop() {
        logPipe.fileHandleForReading.readabilityHandler = nil
        let pid = process.processIdentifier
        if pid > 0 {
            // Terminate the entire process group (npx, wrangler, workerd).
            _ = Darwin.kill(-pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline {
                let groupAlive = (Darwin.kill(-pid, 0) == 0 || errno == EPERM)
                if !process.isRunning && !groupAlive { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning || Darwin.kill(-pid, 0) == 0 {
                _ = Darwin.kill(-pid, SIGKILL)
                if process.isRunning {
                    process.waitUntilExit()
                }
            }
        }
        try? FileManager.default.removeItem(at: persistDir)
    }

    private static func httpProbeURL(from relayURL: URL) -> URL? {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        components.path = "/v1/nope"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func probeReturns404(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 404
        } catch {
            return false
        }
    }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.count < 64 * 1024 {
            data.append(chunk)
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
