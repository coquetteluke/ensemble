import AppKit
import EnsembleKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders Settings > Remote in each relay status (`connected`, `unreachable`, `limitReached`, `mailboxTaken`, and
/// Advanced validation) plus `RemotePairingView` with relay-only QR codes, dark and light at the requested zoom.
/// Uses in-memory token and identity stores and temporary UserDefaults suites; never touches Keychain or the network.
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

    /// In-memory check of `RemoteControlController` defaults, QR generation without Tailscale, URL validation,
    /// 30-day previous-relay window, and `regenerateCode` identity rotation.
    private static func checkController() {
        let suiteName = "ensemble.relay.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tokenStore = InMemoryRemoteTokenStore()
        let identityStore = InMemoryRelayIdentityStore()
        let controller = RemoteControlController(host: DemoRemoteHost(), tokenStore: tokenStore,
                                                 identityStore: identityStore, defaults: defaults)
        controller.rebuildPairing()
        let defaultOn = controller.relayEnabled && controller.relayURL == RelayDefaults.url
        let qrWithoutHosts = controller.pairing?.hosts.isEmpty == true
            && controller.pairing?.relay?.url == RelayDefaults.url
            && controller.qrImage != nil
        let initialToken = controller.pairing?.token
        let initialMailbox = controller.pairing?.relay?.mailbox

        Task { @MainActor in
            let rejectedHTTP = await controller.setRelayURL("http://relay.example.com") != nil
            let rejectedRemoteWS = await controller.setRelayURL("ws://relay.example.com") != nil
            let acceptedCustom = await controller.setRelayURL("wss://backup.example.com/") == nil
                && controller.relayURL == "wss://backup.example.com"
            let prev = controller.activePreviousRelay()
            let savedThirtyDays = prev?.url == RelayDefaults.url
                && abs((prev?.until.timeIntervalSinceNow ?? 0) - RemoteControlController.previousRelayWindow) < 30
            let reverted = await controller.setRelayURL(RelayDefaults.url) == nil
                && controller.activePreviousRelay() == nil
            await controller.regenerateCode()
            let rotatedBoth = controller.pairing?.token != initialToken
                && controller.pairing?.relay?.mailbox != initialMailbox
            await controller.setRelayEnabled(false)
            let offClearsEmptyHostQR = controller.pairing == nil && controller.qrImage == nil
            print("Relay controller check: defaultOn \(defaultOn), qrWithoutHosts \(qrWithoutHosts), "
                  + "rejectedHTTP \(rejectedHTTP), rejectedRemoteWS \(rejectedRemoteWS), "
                  + "acceptedCustom \(acceptedCustom), savedThirtyDays \(savedThirtyDays), "
                  + "reverted \(reverted), rotatedBoth \(rotatedBoth), offClearsEmptyHostQR \(offClearsEmptyHostQR)")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}
