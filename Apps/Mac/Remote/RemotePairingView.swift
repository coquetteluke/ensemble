import EnsembleKit
import SwiftUI

/// The pairing sheet: QR code for the iPhone, the addresses it will try, Regenerate code, connected phones.
struct RemotePairingView: View {
    @Bindable var controller: RemoteControlController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRegenerate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Pair your iPhone")
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Remote Control", isOn: Binding(
                    get: { controller.isOn },
                    set: { on in Task { await controller.setEnabled(on) } }))
                    .toggleStyle(.switch)
            }

            HStack(alignment: .top, spacing: 24) {
                qrPanel
                VStack(alignment: .leading, spacing: 14) {
                    steps
                    hostList
                    statusLine
                }
            }

            devicesSection

            HStack {
                Button("Copy pairing code") { controller.copyPairingCode() }
                    .disabled(controller.pairing == nil)
                    .help("Copies the code as text, for pasting into the iPhone app instead of scanning.")
                Button("Regenerate code") { confirmRegenerate = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task {
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white)
            if let image = controller.qrImage {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .accessibilityLabel("Pairing QR code")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "network.slash")
                        .font(.largeTitle)
                    Text(noCodeReason)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.black.opacity(0.6))
                .padding()
            }
        }
        .frame(width: 240, height: 240)
    }

    private var noCodeReason: String {
        if let error = controller.tokenError { return error }
        return "Tailscale is not running on this Mac. Turn it on to pair."
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Install Ensemble on your iPhone and open it.")
            Text("2. Tap Scan pairing code and point it at this code.")
            Text("3. Keep Tailscale on on both devices to connect from anywhere.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Addresses the iPhone tries, in order")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let hosts = controller.pairing?.hosts, !hosts.isEmpty {
                ForEach(hosts, id: \.self) { host in
                    Text("\(host):\(String(controller.port))")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                Text("None yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.phase {
        case .off:
            Label("Remote Control is off. Turn it on so the iPhone can connect.", systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .starting:
            Label("Starting", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .on:
            VStack(alignment: .leading, spacing: 2) {
                Label("Listening on \(controller.status.listening.joined(separator: ", "))", systemImage: "dot.radiowaves.left.and.right")
                    .font(.callout)
                    .foregroundStyle(.green)
                ForEach(controller.status.failedAddresses.sorted(by: { $0.key < $1.key }), id: \.key) { address, reason in
                    Text("\(address): \(reason)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected iPhones")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if controller.devices.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(controller.devices) { device in
                    HStack {
                        Image(systemName: "iphone")
                        Text(device.name.isEmpty ? "iPhone" : device.name)
                        Text(device.address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("since \(device.connectedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Remote Control settings: the toggle, port, local network option and the pairing sheet.
struct RemoteControlSettingsView: View {
    @Bindable var controller: RemoteControlController
    @State private var showPairing = false
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Remote Control", isOn: Binding(
                    get: { controller.isOn },
                    set: { on in Task { await controller.setEnabled(on) } }))
                Text("Lets Ensemble on your iPhone watch and steer this Mac over Tailscale. Only paired phones can connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show pairing code") { showPairing = true }
            }

            Section("Connection") {
                LabeledContent("Status", value: statusText)
                LabeledContent("Connected iPhones", value: "\(controller.devices.count)")
                TextField("Port", text: $portText)
                    .onSubmit { applyPort() }
                    .help("Port the server listens on. Phones paired before a change must scan the new code.")
                Toggle("Also listen on the local network", isOn: Binding(
                    get: { controller.allowLocalNetwork },
                    set: { allow in Task { await controller.setAllowLocalNetwork(allow) } }))
                Text("Off by default: the server only listens on this Mac and on Tailscale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(controller.port) }
        .sheet(isPresented: $showPairing) {
            RemotePairingView(controller: controller)
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .off: "Off"
        case .starting: "Starting"
        case .on: controller.status.listening.isEmpty ? "On" : "On, \(controller.status.listening.count) addresses"
        case .failed(let message): message
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
    let controller = RemoteControlController(host: DemoRemoteHost(), tokenStore: InMemoryRemoteTokenStore(token: "preview-token"),
                                             defaults: UserDefaults(suiteName: "preview.remote") ?? .standard)
    return RemotePairingView(controller: controller)
}

#Preview("Settings") {
    let controller = RemoteControlController(host: DemoRemoteHost(), tokenStore: InMemoryRemoteTokenStore(token: "preview-token"),
                                             defaults: UserDefaults(suiteName: "preview.remote") ?? .standard)
    return RemoteControlSettingsView(controller: controller)
        .frame(width: 480, height: 420)
}
