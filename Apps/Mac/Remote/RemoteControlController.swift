import AppKit
import CryptoKit
import EnsembleKit
import Observation

/// Starts and stops the iPhone remote server from the Remote Control toggle, keeps the pairing code,
/// relay host and QR image current, and lists connected phones. The app creates one with its `RemoteHost`
/// and calls `restore()` at launch.
@MainActor @Observable
final class RemoteControlController {
    enum Phase: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    enum RelayURLError: LocalizedError, Equatable {
        case invalidScheme
        case invalidAddress

        var errorDescription: String? {
            switch self {
            case .invalidScheme:
                #if DEBUG
                "Relay address must start with wss:// (or ws://127.0.0.1 in Debug)."
                #else
                "Relay address must start with wss://."
                #endif
            case .invalidAddress:
                "Enter a valid relay address such as wss://relay.coquettemc.com."
            }
        }
    }

    static let previousRelayWindow: TimeInterval = 30 * 24 * 60 * 60

    private(set) var phase: Phase = .off
    private(set) var network = RemoteNetworkInfo()
    private(set) var pairing: RemotePairing?
    private(set) var qrImage: CGImage?
    private(set) var status: RemoteServer.Status = .stopped
    private(set) var port: Int
    private(set) var allowLocalNetwork: Bool
    private(set) var relayEnabled: Bool
    private(set) var relayURL: String
    private(set) var relayStatus: RelayHostStatus = .off
    private(set) var needsRescanNotice = false
    /// Set when the Keychain could not be read or written.
    private(set) var tokenError: String?

    var isOn: Bool { phase == .on || phase == .starting }
    var devices: [RemoteServer.Device] { status.devices }

    @ObservationIgnored private let host: any RemoteHost
    @ObservationIgnored private let tokenStore: any RemoteTokenStore
    @ObservationIgnored private let identityStore: any RelayIdentityStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bindPortOverride: UInt16?
    @ObservationIgnored private let detectNetwork: @Sendable () async -> RemoteNetworkInfo
    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var serverGeneration = 0
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var identity: RelayIdentity?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var relayGeneration = 0
    @ObservationIgnored private var pendingRelayStop: Task<Void, Never>?
    @ObservationIgnored private var relayHost: RelayHost?
    @ObservationIgnored private var relayStatusTask: Task<Void, Never>?
    @ObservationIgnored private var previousRelayHost: RelayHost?
    @ObservationIgnored private var previousRelayExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var rotatedTakenMailboxOnce = false

    enum Keys {
        static let enabled = "remote.enabled"
        static let port = "remote.port"
        static let allowLocalNetwork = "remote.allowLocalNetwork"
        static let relayEnabled = "remoteRelayEnabled"
        static let relayURL = "remoteRelayURL"
        static let relayPreviousURL = "remoteRelayPreviousURL"
        static let relayPreviousUntil = "remoteRelayPreviousUntil"
    }

    init(host: any RemoteHost,
         tokenStore: any RemoteTokenStore = KeychainRemoteTokenStore(),
         identityStore: any RelayIdentityStore = KeychainRelayIdentityStore(),
         defaults: UserDefaults = .standard,
         bindPortOverride: UInt16? = nil,
         detectNetwork: @escaping @Sendable () async -> RemoteNetworkInfo = { await RemoteNetworkInfo.detect() }) {
        self.host = host
        self.tokenStore = tokenStore
        self.identityStore = identityStore
        self.defaults = defaults
        self.bindPortOverride = bindPortOverride
        self.detectNetwork = detectNetwork
        let savedPort = defaults.integer(forKey: Keys.port)
        self.port = (1...65535).contains(savedPort) ? savedPort : remoteDefaultPort
        self.allowLocalNetwork = defaults.bool(forKey: Keys.allowLocalNetwork)
        self.relayEnabled = (defaults.object(forKey: Keys.relayEnabled) as? Bool) ?? true
        if let savedURL = defaults.string(forKey: Keys.relayURL),
           case .success(let normalized) = Self.validateRelayURL(savedURL) {
            self.relayURL = normalized
        } else {
            self.relayURL = RelayDefaults.url
        }
        _ = activePreviousRelay()
    }

    /// Deterministic controller for snapshots and SwiftUI previews; never touches Keychain, saved settings or the network.
    static func snapshot(phase: Phase = .on,
                         listening: [String] = ["127.0.0.1:47823"],
                         failedAddresses: [String: String] = [:],
                         network: RemoteNetworkInfo = .init(computerName: "Alex's MacBook Air"),
                         relayEnabled: Bool = true,
                         relayURL: String = RelayDefaults.url,
                         relayStatus: RelayHostStatus = .connected,
                         needsRescanNotice: Bool = false) -> RemoteControlController {
        let defaults = InMemoryDefaults()
        defaults.set(relayEnabled, forKey: Keys.relayEnabled)
        defaults.set(relayURL, forKey: Keys.relayURL)
        let tokenStore = InMemoryRemoteTokenStore(token: "preview-token")
        let identityStore = InMemoryRelayIdentityStore()
        let fixedBytes = Data((0..<32).map(UInt8.init))
        let mailboxID = RemoteHandshake.encode(fixedBytes)
        if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: fixedBytes) {
            try? identityStore.saveIdentity(RelayIdentity(mailboxID: mailboxID, hostKey: key))
        }
        let controller = RemoteControlController(host: DemoRemoteHost(), tokenStore: tokenStore,
                                                 identityStore: identityStore, defaults: defaults,
                                                 detectNetwork: { network })
        var status = RemoteServer.Status.stopped
        status.running = phase == .on
        status.listening = phase == .on ? listening : []
        status.failedAddresses = failedAddresses
        controller.phase = phase
        controller.status = status
        controller.network = network
        controller.relayStatus = relayEnabled ? relayStatus : .off
        controller.needsRescanNotice = needsRescanNotice
        controller.rebuildPairing()
        return controller
    }

    /// Validates and normalizes a relay URL (`wss://` in all builds, plus `ws://127.0.0.1` in Debug).
    static func validateRelayURL(_ raw: String) -> Result<String, RelayURLError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return .failure(.invalidAddress)
        }
        guard let scheme = components.scheme?.lowercased() else {
            return .failure(.invalidScheme)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return scheme == "wss" || scheme == "ws" ? .failure(.invalidAddress) : .failure(.invalidScheme)
        }
        switch scheme {
        case "wss":
            break
        case "ws":
            #if DEBUG
            guard host == "127.0.0.1" else { return .failure(.invalidScheme) }
            #else
            return .failure(.invalidScheme)
            #endif
        default:
            return .failure(.invalidScheme)
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return .failure(.invalidAddress)
        }
        if let port = components.port, !(1...65535).contains(port) {
            return .failure(.invalidAddress)
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        if scheme == "wss", components.port == 443 { components.port = nil }
        if scheme == "ws", components.port == 80 { components.port = nil }
        guard let url = components.url else { return .failure(.invalidAddress) }
        return .success(url.absoluteString)
    }

    /// Turns the server back on at launch if it was on when the app quit.
    func restore() async {
        if defaults.bool(forKey: Keys.enabled) { await start() }
    }

    func setEnabled(_ on: Bool) async {
        defaults.set(on, forKey: Keys.enabled)
        if on { await start() } else { await stop() }
    }

    func setPort(_ newPort: Int) async {
        guard (1024...65535).contains(newPort), newPort != port else { return }
        port = newPort
        defaults.set(newPort, forKey: Keys.port)
        await restartIfOn()
    }

    func setAllowLocalNetwork(_ allow: Bool) async {
        guard allow != allowLocalNetwork else { return }
        allowLocalNetwork = allow
        defaults.set(allow, forKey: Keys.allowLocalNetwork)
        await restartIfOn()
    }

    func setRelayEnabled(_ enabled: Bool) async {
        guard enabled != relayEnabled else { return }
        relayEnabled = enabled
        defaults.set(enabled, forKey: Keys.relayEnabled)
        rotatedTakenMailboxOnce = false
        rebuildPairing()
        let gen = relayGeneration
        if enabled {
            await server?.setActiveRelay(currentActiveRelay())
            guard relayGeneration == gen, relayEnabled else { return }
            await syncRelayHosts()
        } else {
            await stopRelayHosts()
            guard relayGeneration == gen + 1, !relayEnabled else { return }
            await server?.setActiveRelay(currentActiveRelay())
        }
    }

    /// Updates the relay address when valid, returning `nil` on success or a short validation message on failure.
    @discardableResult
    func setRelayURL(_ raw: String) async -> String? {
        let normalized: String
        switch Self.validateRelayURL(raw) {
        case .success(let valid):
            normalized = valid
        case .failure(let error):
            return error.errorDescription
        }
        guard normalized != relayURL else { return nil }
        recordPreviousRelay(changingFrom: relayURL, to: normalized)
        relayURL = normalized
        defaults.set(normalized, forKey: Keys.relayURL)
        rotatedTakenMailboxOnce = false
        rebuildPairing()
        await server?.setActiveRelay(currentActiveRelay())
        if relayEnabled, server != nil {
            await syncRelayHosts()
        }
        return nil
    }

    func dismissRescanNotice() {
        needsRescanNotice = false
    }

    /// Makes a new token and relay identity. Every paired phone is disconnected and must scan the new code.
    func regenerateCode() async {
        let fresh = RemoteToken.generate()
        let freshIdentity: RelayIdentity
        do {
            try tokenStore.saveToken(fresh)
            freshIdentity = try RelayIdentity.regenerate(in: identityStore)
            tokenError = nil
        } catch {
            tokenError = error.localizedDescription
            return
        }
        token = fresh
        identity = freshIdentity
        needsRescanNotice = false
        rotatedTakenMailboxOnce = false
        clearPreviousRelay()
        rebuildPairing()
        await stopRelayHosts()
        await server?.setToken(fresh)
        await server?.setActiveRelay(currentActiveRelay())
        if relayEnabled, server != nil {
            await syncRelayHosts()
        }
    }

    /// Re-reads the Mac's Tailscale and LAN addresses.
    func refreshNetwork() async {
        let info = await detectNetwork()
        let addressesChanged = info.bindAddresses(includeLocalNetwork: allowLocalNetwork)
            != network.bindAddresses(includeLocalNetwork: allowLocalNetwork)
        network = info
        if let server {
            await server.setAcceptedHosts(info.pairingHosts(includeLocalNetwork: allowLocalNetwork))
            if addressesChanged {
                await server.rebind(to: info.bindAddresses(includeLocalNetwork: allowLocalNetwork))
            }
        }
        rebuildPairing()
    }

    func copyPairingCode() {
        guard let code = pairing?.code() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    // MARK: - Server

    private func start() async {
        switch phase {
        case .on, .starting:
            return
        case .off, .failed:
            break
        }
        serverGeneration += 1
        let gen = serverGeneration
        phase = .starting
        guard loadToken() != nil else {
            phase = .failed(tokenError ?? "Could not read the pairing token")
            return
        }
        if relayEnabled, loadIdentity() == nil {
            phase = .failed(tokenError ?? "Could not read the relay identity")
            return
        }

        let detected = await detectNetwork()
        guard serverGeneration == gen else { return }
        network = detected

        guard let initialToken = loadToken() else {
            phase = .failed(tokenError ?? "Could not read the pairing token")
            return
        }
        if relayEnabled, loadIdentity() == nil {
            phase = .failed(tokenError ?? "Could not read the relay identity")
            return
        }

        let listenPort = bindPortOverride ?? UInt16(port)
        let config = RemoteServer.Configuration(
            port: listenPort,
            bindAddresses: network.bindAddresses(includeLocalNetwork: allowLocalNetwork),
            macName: network.computerName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            acceptedHosts: network.pairingHosts(includeLocalNetwork: allowLocalNetwork),
            activeRelay: currentActiveRelay())
        let newServer = RemoteServer(host: host, token: initialToken, configuration: config)
        do {
            try await newServer.start()
        } catch {
            guard serverGeneration == gen else { return }
            phase = .failed(error.localizedDescription)
            return
        }

        guard serverGeneration == gen else {
            await newServer.stop()
            return
        }

        if let latestToken = loadToken(), latestToken != initialToken {
            await newServer.setToken(latestToken)
        }
        await newServer.setAcceptedHosts(network.pairingHosts(includeLocalNetwork: allowLocalNetwork))
        await newServer.setActiveRelay(currentActiveRelay())
        guard serverGeneration == gen else {
            await newServer.stop()
            return
        }

        self.server = newServer
        phase = .on
        rotatedTakenMailboxOnce = false
        rebuildPairing()
        watch(newServer)
        if relayEnabled {
            await syncRelayHosts()
        } else {
            relayStatus = .off
        }
    }

    private func stop() async {
        serverGeneration += 1
        statusTask?.cancel()
        statusTask = nil
        networkTask?.cancel()
        networkTask = nil
        let runningServer = server
        server = nil
        status = .stopped
        phase = .off
        await stopRelayHosts()
        await runningServer?.stop()
    }

    private func restartIfOn() async {
        guard isOn else {
            rebuildPairing()
            return
        }
        await stop()
        await start()
    }

    private func watch(_ server: RemoteServer) {
        statusTask = Task { [weak self] in
            for await s in await server.statusUpdates() {
                guard !Task.isCancelled, let self, self.server === server else { return }
                self.status = s
            }
        }
        // Tailscale can come up, change address or go away while the app runs.
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.server === server else { return }
                await self.refreshNetwork()
            }
        }
    }

    // MARK: - Relay

    private func teardownCurrentRelayHosts() -> (primary: RelayHost?, secondary: RelayHost?) {
        relayStatusTask?.cancel()
        relayStatusTask = nil
        previousRelayExpiryTask?.cancel()
        previousRelayExpiryTask = nil
        let primary = relayHost
        let secondary = previousRelayHost
        relayHost = nil
        previousRelayHost = nil
        relayStatus = .off
        return (primary, secondary)
    }

    private func enqueueRelayStop(_ hosts: (primary: RelayHost?, secondary: RelayHost?)) async {
        let prior = pendingRelayStop
        let stopTask = Task { @MainActor in
            await prior?.value
            await hosts.primary?.stop()
            await hosts.secondary?.stop()
        }
        pendingRelayStop = stopTask
        await stopTask.value
    }

    private func stopRelayHosts() async {
        relayGeneration += 1
        let old = teardownCurrentRelayHosts()
        await enqueueRelayStop(old)
    }

    /// Stops any active relay hosts and starts fresh ones from the controller's current credentials and URL.
    private func syncRelayHosts() async {
        relayGeneration += 1
        let gen = relayGeneration
        let old = teardownCurrentRelayHosts()
        await enqueueRelayStop(old)

        guard relayGeneration == gen, !Task.isCancelled else { return }
        guard relayEnabled, let server = self.server,
              let currentToken = loadToken(),
              let currentIdentity = loadIdentity(),
              let primaryURL = URL(string: relayURL) else {
            return
        }

        let primary = RelayHost(relayURL: primaryURL, identity: currentIdentity, token: currentToken, server: server)
        relayHost = primary
        relayStatus = .connecting

        let updates = await primary.statusUpdates()
        guard relayGeneration == gen, relayHost === primary, !Task.isCancelled else {
            if relayHost === primary {
                _ = teardownCurrentRelayHosts()
            }
            await enqueueRelayStop((primary, nil))
            return
        }

        relayStatusTask = Task { [weak self] in
            for await s in updates {
                guard !Task.isCancelled, let self else { return }
                self.handleRelayStatus(s, from: primary)
            }
        }

        await primary.start()
        guard relayGeneration == gen, relayHost === primary, !Task.isCancelled else {
            if relayHost === primary {
                let stale = teardownCurrentRelayHosts()
                await enqueueRelayStop(stale)
            } else {
                await enqueueRelayStop((primary, nil))
            }
            return
        }

        if let prev = activePreviousRelay(), prev.url != relayURL, let prevURL = URL(string: prev.url) {
            let secondary = RelayHost(relayURL: prevURL, identity: currentIdentity, token: currentToken, server: server)
            previousRelayHost = secondary
            let waitSeconds = max(0, prev.until.timeIntervalSinceNow)
            previousRelayExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(waitSeconds))
                guard !Task.isCancelled, let self else { return }
                await self.expirePreviousRelayHost(secondary, generation: gen)
            }
            await secondary.start()
            guard relayGeneration == gen, previousRelayHost === secondary, !Task.isCancelled else {
                if previousRelayHost === secondary {
                    previousRelayExpiryTask?.cancel()
                    previousRelayExpiryTask = nil
                    previousRelayHost = nil
                }
                await enqueueRelayStop((nil, secondary))
                return
            }
        }
    }

    private func handleRelayStatus(_ newStatus: RelayHostStatus, from source: RelayHost) {
        guard relayHost === source else { return }
        if newStatus == .mailboxTaken {
            guard !rotatedTakenMailboxOnce else {
                relayStatus = .mailboxTaken
                needsRescanNotice = true
                return
            }
            rotatedTakenMailboxOnce = true
            do {
                identity = try RelayIdentity.regenerate(in: identityStore)
                tokenError = nil
            } catch {
                tokenError = error.localizedDescription
                relayStatus = .mailboxTaken
                return
            }
            clearPreviousRelay()
            needsRescanNotice = true
            rebuildPairing()
            // Cancel `relayStatusTask` and restart from a fresh unstructured task so `RelayHost.start()` never runs
            // inside a cancelled `relayStatusTask`.
            relayStatusTask?.cancel()
            relayStatusTask = nil
            let gen = relayGeneration
            let rotatedMailbox = identity?.mailboxID
            Task { @MainActor [weak self] in
                guard let self,
                      self.relayGeneration == gen,
                      self.identity?.mailboxID == rotatedMailbox else { return }
                await self.server?.setActiveRelay(self.currentActiveRelay())
                guard self.relayGeneration == gen,
                      self.identity?.mailboxID == rotatedMailbox else { return }
                await self.syncRelayHosts()
            }
            return
        }
        if newStatus == .connected {
            rotatedTakenMailboxOnce = false
        }
        relayStatus = newStatus
    }

    private func expirePreviousRelayHost(_ host: RelayHost, generation gen: Int) async {
        guard relayGeneration == gen, previousRelayHost === host else { return }
        previousRelayExpiryTask = nil
        previousRelayHost = nil
        clearPreviousRelay()
        await enqueueRelayStop((nil, host))
    }

    /// Returns the unexpired previous relay URL and deadline, clearing expired entries from UserDefaults.
    func activePreviousRelay(now: Date = Date()) -> (url: String, until: Date)? {
        guard let rawURL = defaults.string(forKey: Keys.relayPreviousURL),
              let untilTimestamp = defaults.object(forKey: Keys.relayPreviousUntil) as? Double else {
            return nil
        }
        let until = Date(timeIntervalSince1970: untilTimestamp)
        guard until > now, case .success(let normalized) = Self.validateRelayURL(rawURL) else {
            clearPreviousRelay()
            return nil
        }
        return (normalized, until)
    }

    private func recordPreviousRelay(changingFrom oldURL: String, to newURL: String, now: Date = Date()) {
        guard oldURL != newURL else { return }
        defaults.set(oldURL, forKey: Keys.relayPreviousURL)
        defaults.set(now.addingTimeInterval(Self.previousRelayWindow).timeIntervalSince1970,
                     forKey: Keys.relayPreviousUntil)
    }

    private func clearPreviousRelay() {
        defaults.removeObject(forKey: Keys.relayPreviousURL)
        defaults.removeObject(forKey: Keys.relayPreviousUntil)
    }

    // MARK: - Credentials and pairing

    private func loadToken() -> String? {
        if let token { return token }
        do {
            let t = try RemoteToken.loadOrCreate(in: tokenStore)
            token = t
            tokenError = nil
            return t
        } catch {
            tokenError = error.localizedDescription
            return nil
        }
    }

    private func loadIdentity() -> RelayIdentity? {
        if let identity { return identity }
        do {
            let loaded = try RelayIdentity.loadOrCreate(in: identityStore)
            identity = loaded
            tokenError = nil
            return loaded
        } catch {
            tokenError = error.localizedDescription
            return nil
        }
    }

    private func currentActiveRelay() -> RemotePairing.Relay? {
        guard relayEnabled, let identity = loadIdentity() else { return nil }
        return RemotePairing.Relay(url: relayURL, mailbox: identity.mailboxID)
    }

    /// The pairing shown as a QR code. Built even while off, so the sheet can show it next to the toggle.
    func rebuildPairing() {
        guard let token = loadToken() else {
            pairing = nil
            qrImage = nil
            return
        }
        let relay = currentActiveRelay()
        let hosts = network.pairingHosts(includeLocalNetwork: allowLocalNetwork)
        guard !hosts.isEmpty || relay != nil else {
            pairing = nil
            qrImage = nil
            return
        }
        let p = RemotePairing(hosts: hosts, port: port, token: token, macName: network.computerName, relay: relay)
        if p != pairing {
            pairing = p
            qrImage = RemoteQRCode.cgImage(for: p.code(), scale: 10)
        }
    }
}
