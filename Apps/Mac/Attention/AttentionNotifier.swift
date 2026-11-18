import AppKit
import UserNotifications

/// macOS notifications for sessions: posts them, removes them once seen or answered, and routes a click
/// back to the session through `onOpen`.
///
/// The app is ad-hoc signed; macOS still allows notifications once the user agrees to the system prompt.
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// `userInfo` key holding the session id.
    static let sessionKey = "sessionID"

    private let onOpen: @MainActor @Sendable (String) -> Void

    init(onOpen: @escaping @MainActor @Sendable (String) -> Void) {
        self.onOpen = onOpen
        super.init()
    }

    /// Becomes the notification center's delegate, so clicks reach `onOpen`.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows the system prompt the first time; later calls return the saved answer.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
    }

    /// Opens System Settings > Notifications.
    @MainActor
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Posts one notification. `identifier` makes it unique: posting the same one again replaces it.
    func post(identifier: String, sessionID: String, title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.threadIdentifier = sessionID
        content.userInfo = [Self.sessionKey: sessionID]
        // Sounds are played by the app itself so they follow Ensemble's own sound settings.
        content.sound = nil
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            guard await Self.authorizationStatus() != .denied else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func remove(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let sessionID = response.notification.request.content.userInfo[Self.sessionKey] as? String else { return }
        await onOpen(sessionID)
    }

    /// Ensemble only posts while the session is not on screen, so a banner is right even when the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
