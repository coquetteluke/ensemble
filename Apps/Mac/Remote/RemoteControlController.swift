import AppKit
import EnsembleKit
import Observation

/// Starts and stops the iPhone remote server from the Remote Control toggle, keeps the pairing code and
/// QR image current, and lists connected phones. The app creates one with its `RemoteHost` and calls
/// `restore()` at launch.
@MainActor @Observable
final class RemoteControlController {
    enum Phase: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var network = RemoteNetworkInfo()
    private(set) var pairing: RemotePairing?
    private(set) var qrImage: CGImage?
    private(set) var status: RemoteServer.Status = .stopped
    private(set) var port: Int
    private(set) var allowLocalNetwork: Bool
    /// Set when the Keychain could not be read or written.
    private(set) var tokenError: String?

    var isOn: Bool { phase == .on || phase == .starting }
    var devices: [RemoteServer.Device] { status.devices }

    @ObservationIgnored private let host: any RemoteHost
    @ObservationIgnored private let tokenStore: any RemoteTokenStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?

    private enum Keys {
        static let enabled = "remote.enabled"
        static let port = "remote.port"
        static let allowLocalNetwork = "remote.allowLocalNetwork"
    }

    init(host: any RemoteHost, tokenStore: any RemoteTokenStore = KeychainRemoteTokenStore(), defaults: UserDefaults = .standard) {
        self.host = host
        self.tokenStore = tokenStore
        self.defaults = defaults
        let savedPort = defaults.integer(forKey: Keys.port)
        self.port = (1...65535).contains(savedPort) ? savedPort : remoteDefaultPort
        self.allowLocalNetwork = defaults.bool(forKey: Keys.allowLocalNetwork)
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

    /// Makes a new token. Every paired phone is disconnected and must scan the new code.
    func regenerateCode() async {
        let fresh = RemoteToken.generate()
        do {
            try tokenStore.saveToken(fresh)
            tokenError = nil
        } catch {
            tokenError = error.localizedDescription
            return
        }
        token = fresh
        await server?.setToken(fresh)
        rebuildPairing()
    }

    /// Re-reads the Mac's Tailscale and LAN addresses.
    func refreshNetwork() async {
        let info = await RemoteNetworkInfo.detect()
        let addressesChanged = info.bindAddresses(includeLocalNetwork: allowLocalNetwork)
            != network.bindAddresses(includeLocalNetwork: allowLocalNetwork)
        network = info
        if addressesChanged, let server {
            await server.rebind(to: info.bindAddresses(includeLocalNetwork: allowLocalNetwork))
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
        guard server == nil else { return }
        phase = .starting
        guard let token = loadToken() else {
            phase = .failed(tokenError ?? "Could not read the pairing token")
            return
        }
        network = await RemoteNetworkInfo.detect()
        let config = RemoteServer.Configuration(
            port: UInt16(port),
            bindAddresses: network.bindAddresses(includeLocalNetwork: allowLocalNetwork),
            macName: network.computerName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        let server = RemoteServer(host: host, token: token, configuration: config)
        do {
            try await server.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        self.server = server
        phase = .on
        rebuildPairing()
        watch(server)
    }

    private func stop() async {
        statusTask?.cancel()
        statusTask = nil
        networkTask?.cancel()
        networkTask = nil
        await server?.stop()
        server = nil
        status = .stopped
        phase = .off
    }

    private func restartIfOn() async {
        guard server != nil else {
            rebuildPairing()
            return
        }
        await stop()
        await start()
    }

    private func watch(_ server: RemoteServer) {
        statusTask = Task { [weak self] in
            for await s in await server.statusUpdates() {
                guard let self else { return }
                self.status = s
            }
        }
        // Tailscale can come up, change address or go away while the app runs.
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await self.refreshNetwork()
            }
        }
    }

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

    /// The pairing shown as a QR code. Built even while off, so the sheet can show it next to the toggle.
    func rebuildPairing() {
        guard let token = loadToken() else {
            pairing = nil
            qrImage = nil
            return
        }
        let hosts = network.pairingHosts(includeLocalNetwork: allowLocalNetwork)
        guard !hosts.isEmpty else {
            pairing = nil
            qrImage = nil
            return
        }
        let p = RemotePairing(hosts: hosts, port: port, token: token, macName: network.computerName)
        if p != pairing {
            pairing = p
            qrImage = RemoteQRCode.cgImage(for: p.code(), scale: 10)
        }
    }
}
