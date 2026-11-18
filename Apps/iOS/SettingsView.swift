import EnsembleKit
import SwiftUI
import UIKit

/// Connection details, reconnect, pair again, unpair.
struct SettingsView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model
    @State private var showPairing = false
    @State private var confirmUnpair = false
    @AppStorage(RemoteNotifier.enabledKey) private var alerts = true
    @State private var notificationsDenied = false
    @Environment(\.openURL) private var openURL

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
                if let error = client.lastError, !client.state.isConnected, error != statusText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
                if !client.isInProcess {
                    Button("Reconnect now") { client.reconnectNow() }
                }
            }
            .listRowBackground(RemoteTheme.card)

            Section {
                Toggle("Notify me when something needs me", isOn: $alerts)
                if alerts && notificationsDenied {
                    Button("Turn on notifications in iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Works while this app is open and for about half a minute after you leave it. For alerts at any time, turn on Send alerts through ntfy in Settings > Alerts on your Mac.")
            }
            .listRowBackground(RemoteTheme.card)

            if !client.isInProcess {
                Section {
                    if client.pairing.relay != nil {
                        HStack {
                            Text("Cloud relay")
                                .font(.footnote)
                            Spacer()
                            if client.state == .connected(via: .relay) {
                                Image(systemName: "checkmark").foregroundStyle(RemoteTheme.success)
                            }
                        }
                    }
                    ForEach(client.pairing.hosts, id: \.self) { host in
                        HStack {
                            Text(host)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if client.state == .connected(via: .direct(host: host)) {
                                Image(systemName: "checkmark").foregroundStyle(RemoteTheme.success)
                            }
                        }
                    }
                    if !client.pairing.hosts.isEmpty {
                        LabeledContent("Port", value: String(client.pairing.port))
                    }
                } header: {
                    Text("Connection paths")
                } footer: {
                    if client.pairing.relay == nil {
                        Text("Away from home the phone reaches your Mac through Tailscale. Keep it on on both devices.")
                    }
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
        .task(id: alerts) {
            if alerts { await RemoteNotifier.requestAuthorization() }
            notificationsDenied = await RemoteNotifier.authorizationStatus() == .denied
        }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: {
            Text("You will need to scan the pairing code on your Mac again.")
        }
    }

    private var statusText: String {
        client.statusText
    }
}
