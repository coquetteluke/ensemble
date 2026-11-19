import EnsembleKit
import SwiftUI

/// Shared wording and status dot colours for `RelayHostStatus` in Settings and the pairing sheet.
enum RemoteRelayStatusDisplay {
    static func text(for status: RelayHostStatus) -> String {
        switch status {
        case .off:
            "Off"
        case .connecting:
            "Connecting to the relay"
        case .connected:
            "Connected through the relay"
        case .unreachable:
            "Relay unreachable"
        case .limitReached(let resetsAt):
            if let resetsAt {
                "Daily relay limit reached, resets at \(resetsAt.formatted(date: .omitted, time: .shortened))"
            } else {
                "Daily relay limit reached"
            }
        case .mailboxTaken:
            "This relay address is in use by another Mac"
        }
    }

    static func color(for status: RelayHostStatus, theme: Theme) -> Color {
        switch status {
        case .off, .connecting:
            theme.textTertiary.opacity(0.6)
        case .connected:
            theme.success
        case .unreachable, .limitReached:
            theme.warning
        case .mailboxTaken:
            theme.danger
        }
    }

    static func help(for status: RelayHostStatus) -> String {
        if case .unreachable(let reason) = status { return reason }
        return ""
    }
}

/// The pairing sheet: QR code for the iPhone, the addresses it will try, Regenerate code, connected phones.
struct RemotePairingView: View {
    @Bindable var controller: RemoteControlController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var confirmRegenerate = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(18)) {
            HStack {
                Text("Pair your iPhone")
                    .font(theme.font(size: 18, weight: .semibold))
                Spacer()
                Toggle("Remote Control", isOn: Binding(
                    get: { controller.isOn },
                    set: { on in Task { await controller.setEnabled(on) } }))
                    .toggleStyle(.switch)
            }

            if controller.needsRescanNotice {
                HStack(spacing: theme.z(8)) {
                    Image(systemName: "qrcode")
                        .foregroundStyle(theme.warning)
                    Text("Scan the new pairing code")
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { controller.dismissRescanNotice() }
                }
                .padding(.horizontal, theme.z(12))
                .padding(.vertical, theme.z(8))
                .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: theme.z(8), style: .continuous))
            }

            HStack(alignment: .top, spacing: theme.z(24)) {
                qrPanel
                VStack(alignment: .leading, spacing: theme.z(14)) {
                    steps
                    hostList
                    statusLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            devicesSection

            HStack(spacing: theme.z(8)) {
                Button("Copy pairing code") { controller.copyPairingCode() }
                    .disabled(controller.pairing == nil)
                    .help("Copies the code as text, for pasting into the iPhone app instead of scanning.")
                Button("Regenerate code") { confirmRegenerate = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(theme.font(size: 13))
        .controlSize(theme.scale >= 1.4 ? .extraLarge : (theme.scale >= 1.15 ? .large : .regular))
        .padding(theme.z(24))
        .frame(width: theme.z(620))
        .onAppear {
            if controller.pairing == nil { controller.rebuildPairing() }
        }
        .task {
            guard !isSnapshot else { return }
            await controller.refreshNetwork()
        }
        .confirmationDialog("Regenerate the pairing code?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { Task { await controller.regenerateCode() } }
        } message: {
            Text("Every paired iPhone is disconnected and must scan the new code.")
        }
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.z(14), style: .continuous)
                .fill(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(14), style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
            if let image = controller.qrImage {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(theme.z(14))
                    .accessibilityLabel("Pairing QR code")
            } else {
                VStack(spacing: theme.z(8)) {
                    Image(systemName: "network.slash")
                        .font(theme.font(size: 28))
                    Text(noCodeReason)
                        .font(theme.font(size: 12.5))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.black.opacity(0.65))
                .padding(theme.z(14))
            }
        }
        .frame(width: theme.z(224), height: theme.z(224))
    }

    private var noCodeReason: String {
        if let error = controller.tokenError { return error }
        return "Turn on Connect from anywhere or start Tailscale on this Mac to pair."
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text("1. Install Ensemble on your iPhone and open it.")
            Text("2. Tap Scan pairing code and point it at this code.")
            if controller.relayEnabled {
                Text("3. Keep Remote Control on so your iPhone can connect from anywhere.")
            } else {
                Text("3. Keep Tailscale on on both devices to connect from anywhere.")
            }
        }
        .font(theme.font(size: 13))
        .foregroundStyle(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hostList: some View {
        let hosts = controller.pairing?.hosts ?? []
        let relay = controller.pairing?.relay
        return VStack(alignment: .leading, spacing: theme.z(4)) {
            Text("Addresses the iPhone tries, in order")
                .font(theme.font(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if hosts.isEmpty && relay == nil {
                Text("None yet")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(hosts, id: \.self) { host in
                    Text("\(host):\(String(controller.port))")
                        .font(theme.font(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let relay {
                    Text("Relay (\(Self.relayDisplayHost(relay.url)))")
                        .font(theme.font(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private static func relayDisplayHost(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL), let host = url.host(percentEncoded: false), !host.isEmpty else {
            return rawURL
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.phase {
        case .off:
            Label("Remote Control is off. Turn it on so the iPhone can connect.", systemImage: "pause.circle")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .starting:
            Label("Starting", systemImage: "hourglass")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
        case .on:
            VStack(alignment: .leading, spacing: theme.z(4)) {
                if !controller.status.listening.isEmpty {
                    Label("Listening on \(controller.status.listening.joined(separator: ", "))",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.relayEnabled {
                    HStack(spacing: theme.z(6)) {
                        StatusDot(RemoteRelayStatusDisplay.color(for: controller.relayStatus, theme: theme))
                        Text(RemoteRelayStatusDisplay.text(for: controller.relayStatus))
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(controller.status.failedAddresses.sorted(by: { $0.key < $1.key }), id: \.key) { address, reason in
                    Text("\(address): \(reason)")
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.warning)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text("Connected iPhones")
                .font(theme.font(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if controller.devices.isEmpty {
                Text("None")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(controller.devices) { device in
                    HStack(spacing: theme.z(8)) {
                        Image(systemName: "iphone")
                        Text(device.name.isEmpty ? "iPhone" : device.name)
                        Text(device.address.hasPrefix("relay:") ? "via relay" : device.address)
                            .font(theme.font(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("since \(device.connectedAt.formatted(date: .omitted, time: .shortened))")
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .font(theme.font(size: 13))
                }
            }
        }
        .padding(theme.z(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: theme.z(10), style: .continuous))
    }
}

/// Remote Control settings: the toggle, cloud relay, direct connection options and the pairing sheet.
struct RemoteControlSettingsView: View {
    @Bindable var controller: RemoteControlController
    @Environment(\.theme) private var theme
    @State private var showPairing = false
    @State private var portText: String
    @State private var advancedExpanded: Bool
    @State private var relayAddressText: String
    @State private var relayAddressError: String?

    init(controller: RemoteControlController,
         advancedInitiallyExpanded: Bool = false,
         initialRelayAddressText: String? = nil,
         initialRelayAddressError: String? = nil) {
        self.controller = controller
        _portText = State(initialValue: String(controller.port))
        _advancedExpanded = State(initialValue: advancedInitiallyExpanded)
        _relayAddressText = State(initialValue: initialRelayAddressText ?? controller.relayURL)
        _relayAddressError = State(initialValue: initialRelayAddressError)
    }

    private var relayAddressEdited: Bool {
        relayAddressText.trimmingCharacters(in: .whitespacesAndNewlines) != controller.relayURL
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remote Control", isOn: Binding(
                    get: { controller.isOn },
                    set: { on in Task { await controller.setEnabled(on) } }))
                Text("Lets Ensemble on your iPhone watch and steer this Mac. Only paired phones can connect.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                Button("Show pairing code") { showPairing = true }
                if controller.needsRescanNotice {
                    HStack(spacing: theme.z(8)) {
                        Image(systemName: "qrcode")
                            .foregroundStyle(theme.warning)
                        Text("Scan the new pairing code")
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { controller.dismissRescanNotice() }
                    }
                }
            }

            Section("Relay") {
                Toggle("Connect from anywhere (end-to-end encrypted)", isOn: Binding(
                    get: { controller.relayEnabled },
                    set: { on in Task { await controller.setRelayEnabled(on) } }))
                if controller.relayEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: theme.z(6)) {
                            StatusDot(RemoteRelayStatusDisplay.color(for: controller.relayStatus, theme: theme))
                            Text(RemoteRelayStatusDisplay.text(for: controller.relayStatus))
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .help(RemoteRelayStatusDisplay.help(for: controller.relayStatus))
                    }
                }
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: theme.z(8)) {
                        LabeledContent("Relay address") {
                            HStack(spacing: theme.z(8)) {
                                TextField("Relay address", text: $relayAddressText, prompt: Text(verbatim: RelayDefaults.url))
                                    .labelsHidden()
                                    .textContentType(.URL)
                                    .autocorrectionDisabled()
                                    .onSubmit { applyRelayAddress() }
                                if relayAddressEdited {
                                    Button("Save") { applyRelayAddress() }
                                } else if controller.relayURL != RelayDefaults.url {
                                    Button("Use default") { resetRelayAddress() }
                                }
                            }
                        }
                        if let relayAddressError {
                            Label(relayAddressError, systemImage: "exclamationmark.triangle.fill")
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, theme.z(6))
                }
            }

            Section("Direct connection") {
                LabeledContent("Status", value: statusText)
                LabeledContent("Connected iPhones", value: "\(controller.devices.count)")
                TextField("Port", text: $portText)
                    .onSubmit { applyPort() }
                    .help("Port the server listens on. Phones paired before a change must scan the new code.")
                Toggle("Also listen on the local network", isOn: Binding(
                    get: { controller.allowLocalNetwork },
                    set: { allow in Task { await controller.setAllowLocalNetwork(allow) } }))
                Text("Off by default: direct connections only listen on this Mac and on Tailscale.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .zoomedForm()
        .onChange(of: controller.port) {
            portText = String(controller.port)
        }
        .onChange(of: controller.relayURL) {
            relayAddressText = controller.relayURL
        }
        .onChange(of: relayAddressText) {
            if !relayAddressEdited {
                relayAddressError = nil
            }
        }
        .sheet(isPresented: $showPairing) {
            RemotePairingView(controller: controller)
                .ensembleTheme()
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .off: "Off"
        case .starting: "Starting"
        case .on:
            switch controller.status.listening.count {
            case 0: "On"
            case 1: "On, 1 address"
            case let count: "On, \(count) addresses"
            }
        case .failed(let message): message
        }
    }

    private func applyRelayAddress() {
        let candidate = relayAddressText
        Task {
            if let error = await controller.setRelayURL(candidate) {
                relayAddressError = error
            } else {
                relayAddressError = nil
                relayAddressText = controller.relayURL
            }
        }
    }

    private func resetRelayAddress() {
        Task {
            relayAddressError = await controller.setRelayURL(RelayDefaults.url)
            relayAddressText = controller.relayURL
        }
    }

    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(value) else {
            portText = String(controller.port)
            return
        }
        Task { await controller.setPort(value) }
    }
}

#Preview("Pairing") {
    RemotePairingView(controller: .snapshot())
        .ensembleTheme()
}

#Preview("Settings") {
    RemoteControlSettingsView(controller: .snapshot())
        .ensembleTheme()
        .frame(width: 560, height: 620)
}
