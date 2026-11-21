import EnsembleKit
import SwiftUI
import UIKit

/// Mac pairing details, connection paths, alerts, fonts, demo toggle, and unpairing.
struct SettingsView: View {
    let client: RemoteClient
    var showStatusInToolbar = true

    @Environment(RemoteAppModel.self) private var model
    @State private var showPairing = false
    @State private var confirmUnpair = false
    @AppStorage(RemoteNotifier.enabledKey) private var alerts = true
    @State private var notificationsDenied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsMacHeaderCard(client: client)

                SettingsSection(title: "Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Status")
                                .font(RemoteTheme.font(size: 14, relativeTo: .subheadline))
                                .foregroundStyle(RemoteTheme.secondaryText)
                            Spacer()
                            Text(client.statusText)
                                .font(RemoteTheme.font(size: 14, weight: .medium, relativeTo: .subheadline))
                                .foregroundStyle(statusColor)
                                .multilineTextAlignment(.trailing)
                        }

                        if let error = client.lastError, !client.state.isConnected, error != client.statusText {
                            Text(error)
                                .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !client.isInProcess {
                            Button {
                                client.reconnectNow()
                            } label: {
                                Text("Reconnect now")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RemoteSecondaryButtonStyle())
                        }
                    }
                    .remoteCard()
                }

                if !client.isInProcess {
                    SettingsPathsSection(client: client)
                }

                SettingsSection(title: "Alerts") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $alerts) {
                            Text("Notify me when something needs me")
                                .font(RemoteTheme.font(size: 14.5, relativeTo: .subheadline))
                                .foregroundStyle(RemoteTheme.primaryText)
                        }
                        .tint(RemoteTheme.accent)
                        .frame(minHeight: RemoteTheme.minTapTarget)

                        if alerts && notificationsDenied {
                            Button("Turn on notifications in iOS Settings") {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                    openURL(url)
                                }
                            }
                            .buttonStyle(RemoteSecondaryButtonStyle())
                        }
                    }
                    .remoteCard()
                }

                SettingsSection(title: "Fonts") {
                    FontSettingsRows(syncsWithMac: !client.isInProcess)
                }

                SettingsActionsSection(
                    isDemo: client.isInProcess,
                    onPair: { showPairing = true },
                    onStartDemo: { model.startDemo() },
                    onUnpair: {
                        if client.isInProcess { model.unpair() } else { confirmUnpair = true }
                    }
                )
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, RemoteTheme.screenHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .remoteScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showStatusInToolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(client: client, inToolbar: true)
                }
            }
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                PairingView(isSheet: true)
            }
            .environment(model)
            .remoteThemeEnvironment()
        }
        .task(id: alerts) {
            if alerts { await RemoteNotifier.requestAuthorization() }
            notificationsDenied = await RemoteNotifier.authorizationStatus() == .denied
        }
        .confirmationDialog("Unpair Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair Mac", role: .destructive) { model.unpair() }
        } message: {
            Text("You will need to scan the pairing code on your Mac again.")
        }
    }

    private var statusColor: Color {
        if client.isInProcess { return RemoteTheme.accent }
        switch client.state {
        case .connected: return RemoteTheme.success
        case .connecting, .waiting, .macOffline: return RemoteTheme.warning
        case .idle, .rejected, .limitReached: return RemoteTheme.danger
        }
    }
}

private struct SettingsMacHeaderCard: View {
    let client: RemoteClient

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(RemoteTheme.accent.opacity(0.14))
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(RemoteTheme.accent)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(client.macName)
                    .font(RemoteTheme.font(size: 17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(RemoteTheme.primaryText)
                HStack(spacing: 8) {
                    Text(client.statusText)
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)
                    if let version = client.macAppVersion {
                        Chip(text: "v\(version)")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .remoteCard()
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.secondaryText)
                .padding(.leading, 2)
            content
        }
    }
}

private struct SettingsPathsSection: View {
    let client: RemoteClient

    var body: some View {
        SettingsSection(title: "Connection paths") {
            VStack(spacing: 0) {
                if client.pairing.relay != nil {
                    HStack {
                        Text("Cloud relay")
                            .font(RemoteTheme.font(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(RemoteTheme.primaryText)
                        Spacer()
                        if client.state == .connected(via: .relay) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(RemoteTheme.success)
                        }
                    }
                    .padding(.vertical, 10)
                }

                ForEach(Array(client.pairing.hosts.enumerated()), id: \.element) { index, host in
                    if client.pairing.relay != nil || index > 0 {
                        Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                    }
                    HStack {
                        Text(host)
                            .font(RemoteTheme.font(size: 13, design: .monospaced, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if client.state == .connected(via: .direct(host: host)) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(RemoteTheme.success)
                        }
                    }
                    .padding(.vertical, 10)
                }

                if !client.pairing.hosts.isEmpty {
                    Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                    HStack {
                        Text("Port")
                            .font(RemoteTheme.font(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(RemoteTheme.secondaryText)
                        Spacer()
                        Text(String(client.pairing.port))
                            .font(RemoteTheme.font(size: 13.5, design: .monospaced, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.primaryText)
                    }
                    .padding(.vertical, 10)
                }
            }
            .remoteCard()
        }
    }
}

private struct SettingsActionsSection: View {
    let isDemo: Bool
    let onPair: () -> Void
    let onStartDemo: () -> Void
    let onUnpair: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onPair) {
                Text(isDemo ? "Pair with a Mac" : "Pair again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemotePrimaryButtonStyle())

            if !isDemo {
                Button(action: onStartDemo) {
                    Text("Try Demo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
            }

            Button(role: .destructive, action: onUnpair) {
                Text(isDemo ? "Leave demo" : "Unpair Mac")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(
                RemoteSecondaryButtonStyle(
                    foreground: RemoteTheme.danger,
                    border: RemoteTheme.danger.opacity(0.4)
                )
            )
        }
    }
}
