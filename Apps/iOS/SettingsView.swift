import EnsembleKit
import SwiftUI

/// Connection details, reconnect, pair again, unpair.
struct SettingsView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model
    @State private var showPairing = false
    @State private var confirmUnpair = false

    var body: some View {
        List {
            Section("Mac") {
                LabeledContent("Name", value: client.macName)
                if let version = client.macAppVersion {
                    LabeledContent("Ensemble", value: version)
                }
            }
            .listRowBackground(RemoteTheme.card)

            Section("Connection") {
                LabeledContent("Status", value: statusText)
                if let error = client.lastError, !client.state.isConnected {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
                if !client.isInProcess {
                    Button("Reconnect now") { client.reconnectNow() }
                }
            }
            .listRowBackground(RemoteTheme.card)

            if !client.isInProcess {
                Section {
                    ForEach(client.pairing.hosts, id: \.self) { host in
                        HStack {
                            Text(host)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if client.state == .connected(host: host) {
                                Image(systemName: "checkmark").foregroundStyle(RemoteTheme.success)
                            }
                        }
                    }
                    LabeledContent("Port", value: String(client.pairing.port))
                } header: {
                    Text("Addresses tried in order")
                } footer: {
                    Text("Away from home the phone reaches your Mac through Tailscale. Keep it on on both devices.")
                }
                .listRowBackground(RemoteTheme.card)
            }

            Section {
                Button(client.isInProcess ? "Pair with a Mac" : "Pair again") { showPairing = true }
                if client.isInProcess {
                    Button("Leave demo", role: .destructive) { model.unpair() }
                } else {
                    Button("Unpair this iPhone", role: .destructive) { confirmUnpair = true }
                }
            }
            .listRowBackground(RemoteTheme.card)
        }
        .remoteScreen()
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(client: client) } }
        .sheet(isPresented: $showPairing) {
            NavigationStack { PairingView(isSheet: true) }
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: {
            Text("You will need to scan the pairing code on your Mac again.")
        }
    }

    private var statusText: String {
        if client.isInProcess { return "Demo, no Mac" }
        switch client.state {
        case .idle: return "Offline"
        case .connecting(let host): return "Connecting to \(host)"
        case .connected(let host): return "Connected via \(host)"
        case .waiting(let s): return "Retrying in \(s)s"
        case .rejected(let why): return why
        }
    }
}
