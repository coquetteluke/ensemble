import AppKit
import EnsembleKit
import ImageIO
import Network
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// Renders Settings > Remote in each relay status (`connected`, `unreachable`, `limitReached`, `mailboxTaken`, and
/// Advanced validation) plus `RemotePairingView` with relay-only QR codes, dark and light at the requested zoom.
/// Uses in-memory token and identity stores and temporary UserDefaults suites; never touches Keychain or the internet.
@MainActor
enum RelaySnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat = 1) -> [String] {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        var written: [String] = []
        let resetDate = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())
            ?? Date(timeIntervalSince1970: 1_795_041_600)

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"

            let connected = RemoteControlController.snapshot(relayStatus: .connected)
            if let path = capture(RemoteControlSettingsView(controller: connected),
                                  size: CGSize(width: 640, height: 600), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("relay-settings-connected-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let unreachable = RemoteControlController.snapshot(
                relayStatus: .unreachable("Could not find the relay address."))
            if let path = capture(RemoteControlSettingsView(controller: unreachable),
                                  size: CGSize(width: 640, height: 600), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("relay-settings-unreachable-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let limit = RemoteControlController.snapshot(relayStatus: .limitReached(resetsAt: resetDate))
            if let path = capture(RemoteControlSettingsView(controller: limit),
                                  size: CGSize(width: 640, height: 600), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("relay-settings-limit-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let taken = RemoteControlController.snapshot(relayStatus: .mailboxTaken, needsRescanNotice: true)
            if let path = capture(RemoteControlSettingsView(controller: taken, advancedInitiallyExpanded: true),
                                  size: CGSize(width: 640, height: 680), zoom: zoom, scheme: scheme,
                                  to: directory.appendingPathComponent("relay-settings-taken-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let invalidScheme = RemoteControlController.RelayURLError.invalidScheme.errorDescription
            let advancedError = RemoteControlController.snapshot(relayStatus: .connected)
            if let path = capture(
                RemoteControlSettingsView(controller: advancedError,
                                          advancedInitiallyExpanded: true,
                                          initialRelayAddressText: "http://relay.example.com",
                                          initialRelayAddressError: invalidScheme),
                size: CGSize(width: 640, height: 680), zoom: zoom, scheme: scheme,
                to: directory.appendingPathComponent("relay-settings-advanced-\(tone)\(suffix).png")
            ) {
                written.append(path)
            }

            let pairing = RemoteControlController.snapshot(relayStatus: .connected)
            if let path = captureFitting(RemotePairingView(controller: pairing),
                                         width: 620, zoom: zoom, scheme: scheme,
                                         to: directory.appendingPathComponent("relay-pairing-\(tone)\(suffix).png")) {
                written.append(path)
            }

            let pairingRescan = RemoteControlController.snapshot(relayStatus: .connected, needsRescanNotice: true)
            if let path = captureFitting(RemotePairingView(controller: pairingRescan),
                                         width: 620, zoom: zoom, scheme: scheme,
                                         to: directory.appendingPathComponent("relay-pairing-rescan-\(tone)\(suffix).png")) {
                written.append(path)
            }
        }

        checkController()
        print("Rendered \(written.count) relay snapshots:")
        for path in written { print(path) }
        return written
    }

    /// Hosts `view` in an offscreen borderless window so AppKit-backed grouped forms draw accurately.
    private static func capture<V: View>(_ view: V, size: CGSize, zoom: CGFloat, scheme: ColorScheme, to url: URL) -> String? {
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let root = ThemedCanvas(scheme: scheme, zoom: zoom) {
            view.frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: scaled)
        return renderHosting(hosting, size: scaled, scheme: scheme, to: url)
    }

    private static func captureFitting<V: View>(_ view: V, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                                to url: URL) -> String? {
        let scaledWidth = width * zoom
        let root = ThemedCanvas(scheme: scheme, zoom: zoom) {
            view.fixedSize(horizontal: false, vertical: true)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: scaledWidth, height: 1200 * zoom)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = CGSize(width: scaledWidth, height: max(200, ceil(fitting.height)))
        hosting.frame = CGRect(origin: .zero, size: size)
        return renderHosting(hosting, size: size, scheme: scheme, to: url)
    }

    private static func renderHosting<V: View>(_ hosting: NSHostingView<V>, size: CGSize, scheme: ColorScheme,
                                               to url: URL) -> String? {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let image = rep.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }

    private struct ThemedCanvas<Content: View>: View {
        let scheme: ColorScheme
        let zoom: CGFloat
        @ViewBuilder let content: Content

        var body: some View {
            ThemedBackground { content }
                .ensembleTheme()
                .environment(\.zoom, zoom)
                .environment(\.isSnapshot, true)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
    }

    private struct ThemedBackground<Content: View>: View {
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content.background(theme.background)
        }
    }

    /// In-memory and loopback check of `RemoteControlController`: defaults, QR generation without Tailscale,
    /// URL validation, 30-day previous-relay window across multiple changes and reverts, `regenerateCode` rotation,
    /// `start()`/`stop()` cancellation during `.starting`, and live `mailboxTaken` rotation reaching `.connected`.
    static func checkController() {
        var completed = false
        Task { @MainActor in
            await runControllerChecks()
            completed = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !completed && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(completed, "RelaySnapshots.checkController timed out")
    }

    private static func runControllerChecks() async {
        let suiteName = "ensemble.relay.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not open temporary UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tokenStore = InMemoryRemoteTokenStore()
        let identityStore = InMemoryRelayIdentityStore()
        let controller = RemoteControlController(
            host: DemoRemoteHost(),
            tokenStore: tokenStore,
            identityStore: identityStore,
            defaults: defaults,
            bindPortOverride: 0,
            detectNetwork: { RemoteNetworkInfo(computerName: "Check Mac") })

        controller.rebuildPairing()
        let defaultOn = controller.relayEnabled && controller.relayURL == RelayDefaults.url
        let qrWithoutHosts = controller.pairing?.hosts.isEmpty == true
            && controller.pairing?.relay?.url == RelayDefaults.url
            && controller.qrImage != nil
        let initialToken = controller.pairing?.token
        let initialMailbox = controller.pairing?.relay?.mailbox
        precondition(defaultOn && qrWithoutHosts && initialToken != nil && initialMailbox != nil,
                     "Default relay state or relay-only QR failed")

        let rejectedHTTP = await controller.setRelayURL("http://relay.example.com") != nil
        let rejectedRemoteWS = await controller.setRelayURL("ws://relay.example.com") != nil
        let acceptedFirstChange = await controller.setRelayURL("wss://backup.example.com/") == nil
            && controller.relayURL == "wss://backup.example.com"
        let prev1 = controller.activePreviousRelay()
        let savedFirstChange = prev1?.url == RelayDefaults.url
            && abs((prev1?.until.timeIntervalSinceNow ?? 0) - RemoteControlController.previousRelayWindow) < 30

        let acceptedSecondChange = await controller.setRelayURL("wss://third.example.com") == nil
            && controller.relayURL == "wss://third.example.com"
        let prev2 = controller.activePreviousRelay()
        let savedSecondChange = prev2?.url == "wss://backup.example.com"
            && abs((prev2?.until.timeIntervalSinceNow ?? 0) - RemoteControlController.previousRelayWindow) < 30

        let revertedToDefault = await controller.setRelayURL(RelayDefaults.url) == nil
            && controller.relayURL == RelayDefaults.url
        let prevAfterRevert = controller.activePreviousRelay()
        let savedOnRevert = prevAfterRevert?.url == "wss://third.example.com"
            && abs((prevAfterRevert?.until.timeIntervalSinceNow ?? 0) - RemoteControlController.previousRelayWindow) < 30
        precondition(rejectedHTTP && rejectedRemoteWS && acceptedFirstChange && savedFirstChange
                     && acceptedSecondChange && savedSecondChange && revertedToDefault && savedOnRevert,
                     "Relay URL validation or 30-day previous-relay tracking failed")

        await controller.regenerateCode()
        let rotatedBoth = controller.pairing?.token != initialToken
            && controller.pairing?.relay?.mailbox != initialMailbox
            && controller.activePreviousRelay() == nil
        precondition(rotatedBoth, "regenerateCode failed to rotate token and identity or clear previous relay")

        await controller.setRelayEnabled(false)
        let offClearsEmptyHostQR = controller.pairing == nil && controller.qrImage == nil
        precondition(offClearsEmptyHostQR, "Disabling relay did not clear empty-host pairing")
        await controller.setRelayEnabled(true)

        // Check `stop()` cancelling an in-flight `.starting` phase.
        let slowSuite = "ensemble.relay.slow.\(UUID().uuidString)"
        if let slowDefaults = UserDefaults(suiteName: slowSuite) {
            defer { slowDefaults.removePersistentDomain(forName: slowSuite) }
            let slowController = RemoteControlController(
                host: DemoRemoteHost(),
                tokenStore: InMemoryRemoteTokenStore(),
                identityStore: InMemoryRelayIdentityStore(),
                defaults: slowDefaults,
                bindPortOverride: 0,
                detectNetwork: {
                    try? await Task.sleep(for: .milliseconds(120))
                    return RemoteNetworkInfo(computerName: "Slow Mac")
                })
            await slowController.setRelayEnabled(false)
            let startTask = Task { @MainActor in await slowController.setEnabled(true) }
            try? await Task.sleep(for: .milliseconds(20))
            precondition(slowController.phase == .starting, "Expected slowController to enter .starting")
            await slowController.setEnabled(false)
            await startTask.value
            precondition(slowController.phase == .off && !slowController.isOn,
                         "setEnabled(false) during .starting did not keep controller off")
        }

        #if DEBUG
        // Live loopback check: `mailboxTaken` rotates identity in an uncancelled task, claims the new mailbox,
        // and reaches `.connected`, and changing URLs keeps the 30-day fallback host connected on the previous URL.
        let relay1 = LoopbackControlRelay(rejectFirstAuthAsTaken: true, requireClaimOnce: true)
        let relay2 = LoopbackControlRelay(rejectFirstAuthAsTaken: false, requireClaimOnce: false)
        await relay1.start()
        await relay2.start()
        defer {
            relay1.stop()
            relay2.stop()
        }

        let liveSuite = "ensemble.relay.live.\(UUID().uuidString)"
        guard let liveDefaults = UserDefaults(suiteName: liveSuite) else {
            preconditionFailure("Could not open live UserDefaults suite")
        }
        defer { liveDefaults.removePersistentDomain(forName: liveSuite) }

        let liveIdentityStore = InMemoryRelayIdentityStore()
        let liveController = RemoteControlController(
            host: DemoRemoteHost(),
            tokenStore: InMemoryRemoteTokenStore(),
            identityStore: liveIdentityStore,
            defaults: liveDefaults,
            bindPortOverride: 0,
            detectNetwork: { RemoteNetworkInfo(computerName: "Loopback Mac") })
        let setErr = await liveController.setRelayURL(relay1.urlString)
        precondition(setErr == nil, "Expected ws://127.0.0.1 to be allowed in Debug: \(String(describing: setErr))")
        await liveController.regenerateCode()
        let mailboxBeforeTaken = liveController.pairing?.relay?.mailbox
        precondition(mailboxBeforeTaken != nil, "Expected initial live mailbox")

        await liveController.setEnabled(true)
        let connectedAfterTaken = await pollUntil(timeout: 5) {
            liveController.relayStatus == .connected
        }
        let mailboxAfterTaken = liveController.pairing?.relay?.mailbox
        let storedIdentity = try? liveIdentityStore.loadIdentity()
        precondition(connectedAfterTaken,
                     "Expected liveController to reach .connected after mailboxTaken, got \(liveController.relayStatus)")
        precondition(liveController.needsRescanNotice, "Expected needsRescanNotice after mailboxTaken")
        precondition(mailboxAfterTaken != nil && mailboxAfterTaken != mailboxBeforeTaken,
                     "Expected mailboxTaken to rotate mailbox ID")
        precondition(relay1.takenCount == 1 && relay1.claimedHostKeys == [storedIdentity?.hostPublicKey ?? ""],
                     "Expected rotated identity to claim the new mailbox on relay1")

        let switchErr = await liveController.setRelayURL(relay2.urlString)
        precondition(switchErr == nil && liveController.activePreviousRelay()?.url == relay1.urlString,
                     "Expected switching to relay2 to record relay1 as previous relay")
        let bothRelaysConnected = await pollUntil(timeout: 5) {
            liveController.relayStatus == .connected && relay2.readyCount >= 1 && relay1.readyCount >= 2
        }
        precondition(bothRelaysConnected,
                     "Expected primary relay2 and 30-day fallback relay1 to both sign in")

        await liveController.setEnabled(false)
        precondition(liveController.phase == .off && liveController.relayStatus == .off,
                     "Expected liveController to stop cleanly")
        #endif

        print("Relay controller check: defaultOn \(defaultOn), qrWithoutHosts \(qrWithoutHosts), "
              + "rejectedHTTP \(rejectedHTTP), rejectedRemoteWS \(rejectedRemoteWS), "
              + "savedFirstChange \(savedFirstChange), savedSecondChange \(savedSecondChange), "
              + "savedOnRevert \(savedOnRevert), rotatedBoth \(rotatedBoth), "
              + "offClearsEmptyHostQR \(offClearsEmptyHostQR), liveMailboxTakenConnected true, "
              + "liveFallbackRelayConnected true")
    }

    private static func pollUntil(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

#if DEBUG
/// Minimal loopback WebSocket relay on `127.0.0.1` for exercising `RelayHost` control sign-in, `mailboxTaken` (4001),
/// `noMailbox` (4004) -> `claim`, and `ready` in `RelaySnapshots.checkController()`.
private final class LoopbackControlRelay: Sendable {
    private struct State {
        var rejectNextAuthAsTaken: Bool
        let requireClaimOnce: Bool
        var hasClaimed = false
        var takenCount = 0
        var readyCount = 0
        var claimedHostKeys: [String] = []
        var connections: [NWConnection] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.coquetteluke.ensemble.loopback-relay-check")
    private let state: Mutex<State>

    var urlString: String { "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)" }
    var takenCount: Int { state.withLock { $0.takenCount } }
    var readyCount: Int { state.withLock { $0.readyCount } }
    var claimedHostKeys: [String] { state.withLock { $0.claimedHostKeys } }

    init(rejectFirstAuthAsTaken: Bool, requireClaimOnce: Bool) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else {
            preconditionFailure("Could not create LoopbackControlRelay NWListener")
        }
        self.listener = listener
        self.state = Mutex(State(rejectNextAuthAsTaken: rejectFirstAuthAsTaken, requireClaimOnce: requireClaimOnce))
    }

    func start() async {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let resumed = Mutex(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let first = resumed.withLock { seen in
                        defer { seen = true }
                        return !seen
                    }
                    if first { continuation.resume() }
                case .failed(let error):
                    preconditionFailure("LoopbackControlRelay listener failed: \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let open = state.withLock { s in
            defer { s.connections = [] }
            return s.connections
        }
        for c in open { c.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.stateUpdateHandler = { [weak self] connState in
            if case .ready = connState {
                let nonce = RemoteHandshake.encode(RemoteHandshake.makeNonce())
                Self.sendText(#"{"t":"challenge","nonce":"\#(nonce)"}"#, on: connection)
                self?.receive(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                      as? NWProtocolWebSocket.Metadata else { return }
            guard metadata.opcode == .text else {
                if metadata.opcode != .close { self.receive(on: connection) }
                return
            }
            let text = String(decoding: content ?? Data(), as: UTF8.self)
            if text == "ping" {
                Self.sendText("pong", on: connection)
                self.receive(on: connection)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = json["t"] as? String else { return }

            switch type {
            case "auth":
                let action: UInt16? = self.state.withLock { s in
                    if s.rejectNextAuthAsTaken {
                        s.rejectNextAuthAsTaken = false
                        s.takenCount += 1
                        return 4001
                    }
                    if s.requireClaimOnce && !s.hasClaimed {
                        return 4004
                    }
                    s.readyCount += 1
                    return nil
                }
                if let code = action {
                    Self.sendClose(code: code, on: connection)
                } else {
                    Self.sendText(#"{"t":"ready"}"#, on: connection)
                    self.receive(on: connection)
                }
            case "claim":
                let hostKey = json["hostKey"] as? String ?? ""
                self.state.withLock { s in
                    s.hasClaimed = true
                    s.claimedHostKeys.append(hostKey)
                    s.readyCount += 1
                }
                Self.sendText(#"{"t":"ready"}"#, on: connection)
                self.receive(on: connection)
            default:
                self.receive(on: connection)
            }
        }
    }

    private static func sendText(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private static func sendClose(code: UInt16, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
