import EnsembleKit
import UserNotifications

/// Local notifications for what needs you, from the live connection to the Mac. A free Apple account cannot send push
/// notifications, so these work while the app is open and for the short time iOS lets it finish in the background
/// (`RemoteAppModel` keeps the connection for that long). The text says who waits and on what kind of thing, never the
/// command, since notifications can show on the lock screen.
@MainActor
final class RemoteNotifier {
    /// UserDefaults key of the on/off switch in Settings. On unless turned off.
    nonisolated static let enabledKey = "alerts.local"
    nonisolated static let sessionKey = "sessionID"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private let delegate: Delegate

    /// - Parameters:
    ///   - isShowing: true when that chat is on screen right now (no banner then).
    ///   - open: opens a chat when a notification is tapped.
    init(isShowing: @escaping @MainActor @Sendable (String) -> Bool, open: @escaping @MainActor @Sendable (String) -> Void) {
        delegate = Delegate(isShowing: isShowing, open: open)
    }

    /// Becomes the notification delegate, so banners show while the app is open and taps open the chat.
    func install() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Shows the system prompt the first time; later calls return the saved answer.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func post(_ alert: RemoteAlert) {
        guard Self.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.sessionID
        content.userInfo = [Self.sessionKey: alert.sessionID]
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        Task {
            let status = await Self.authorizationStatus()
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Removes the delivered notifications of a chat the user has opened.
    func clear(sessionID: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == sessionID }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
        let isShowing: @MainActor @Sendable (String) -> Bool
        let open: @MainActor @Sendable (String) -> Void

        init(isShowing: @escaping @MainActor @Sendable (String) -> Bool, open: @escaping @MainActor @Sendable (String) -> Void) {
            self.isShowing = isShowing
            self.open = open
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions {
            let sessionID = notification.request.content.userInfo[RemoteNotifier.sessionKey] as? String
            if let sessionID, await isShowing(sessionID) { return [] }
            return [.banner, .list, .sound]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let sessionID = response.notification.request.content.userInfo[RemoteNotifier.sessionKey] as? String else { return }
            await open(sessionID)
        }
    }
}
