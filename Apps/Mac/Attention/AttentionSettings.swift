import SwiftUI
import AppKit
import UserNotifications
import EnsembleKit

/// Alert preferences, stored in UserDefaults. Views bind to the same keys with `@AppStorage`.
enum AttentionSettings {
    enum Key {
        static let notifications = "attention.notifications"
        static let needsYouSound = "attention.needsYouSound"
        static let finishedSound = "attention.finishedSound"
        static let menuBarIcon = "attention.menuBarIcon"
        static let dockBadge = "attention.dockBadge"
        static let sidebarGrouping = "sidebar.grouping"
        static let sidebarSort = "sidebar.sort"
        /// The user's own folder order when grouping by project: an array of folder paths (`SidebarFolderOrder`).
        static let sidebarFolderOrder = "sidebar.folderOrder"
    }

    enum Default {
        static let notifications = true
        static let needsYouSound = true
        static let finishedSound = false
        static let menuBarIcon = true
        static let dockBadge = true
    }

    /// Short system sounds (from /System/Library/Sounds).
    static let needsYouSoundName = "Glass"
    static let finishedSoundName = "Pop"

    static var notifications: Bool { bool(Key.notifications, Default.notifications) }
    static var needsYouSound: Bool { bool(Key.needsYouSound, Default.needsYouSound) }
    static var finishedSound: Bool { bool(Key.finishedSound, Default.finishedSound) }
    static var menuBarIcon: Bool { bool(Key.menuBarIcon, Default.menuBarIcon) }
    static var dockBadge: Bool { bool(Key.dockBadge, Default.dockBadge) }

    /// The saved folder order (empty when the order is automatic).
    static var sidebarFolderOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.sidebarFolderOrder) ?? [] }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Key.sidebarFolderOrder)
            } else {
                UserDefaults.standard.set(newValue, forKey: Key.sidebarFolderOrder)
            }
        }
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

/// Alerts settings for a grouped `Form`: notifications, sounds, menu bar icon and Dock badge.
struct AttentionSettingsSection: View {
    @AppStorage(AttentionSettings.Key.notifications) private var notifications = AttentionSettings.Default.notifications
    @AppStorage(AttentionSettings.Key.needsYouSound) private var needsYouSound = AttentionSettings.Default.needsYouSound
    @AppStorage(AttentionSettings.Key.finishedSound) private var finishedSound = AttentionSettings.Default.finishedSound
    @AppStorage(AttentionSettings.Key.menuBarIcon) private var menuBarIcon = AttentionSettings.Default.menuBarIcon
    @AppStorage(AttentionSettings.Key.dockBadge) private var dockBadge = AttentionSettings.Default.dockBadge
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Section {
            Toggle("Show notifications", isOn: $notifications)
            if notifications, authorization == .denied {
                LabeledContent("macOS has notifications turned off for Ensemble") {
                    Button("Open Notification Settings") { AttentionNotifier.openSystemSettings() }
                }
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
            }
            Toggle("Play a sound when a session needs you", isOn: $needsYouSound)
            Toggle("Play a sound when a session finishes", isOn: $finishedSound)
            Toggle("Show running agents in the menu bar", isOn: $menuBarIcon)
            Toggle("Show the needs-you count on the Dock icon", isOn: $dockBadge)
        } header: {
            Text("Alerts")
        } footer: {
            Text("Alerts come when a session asks for permission, finishes or fails while you are not looking at it.")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
        }
        .onChange(of: notifications) { _, on in
            if on { AttentionCenter.shared.requestNotificationPermission() }
            refreshAuthorization()
        }
        .onChange(of: dockBadge) { AttentionCenter.shared.applyPreferences() }
        .onChange(of: menuBarIcon) { AttentionCenter.shared.applyPreferences() }
        .onChange(of: needsYouSound) { _, on in if on { AttentionCenter.shared.playSound(AttentionSettings.needsYouSoundName) } }
        .onChange(of: finishedSound) { _, on in if on { AttentionCenter.shared.playSound(AttentionSettings.finishedSoundName) } }
        .task { refreshAuthorization() }
    }

    private func refreshAuthorization() {
        guard !isSnapshot else { return }
        Task { authorization = await AttentionNotifier.authorizationStatus() }
    }
}

/// `AttentionSettingsSection` in its own grouped form, for a Settings tab.
struct AttentionSettingsTab: View {
    var body: some View {
        Form {
            AttentionSettingsSection()
            NtfyAlertsSection()
        }
        .formStyle(.grouped)
    }
}
