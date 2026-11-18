import AppKit
import SwiftUI
import EnsembleKit

extension PowerController {
    /// The app's controller: the real macOS backend, released when the app quits.
    /// Create it once (as `@State` in the App), put it in the environment with `.environment(power)`,
    /// and call `start()` once at launch.
    static func makeForMac() -> PowerController {
        let controller = PowerController(backend: MacPowerBackend())
        PowerQuitHook.install(controller)
        return controller
    }
}

/// Releases the assertions and Ensemble's own lid lock in `applicationWillTerminate`.
/// A crash skips this; the kernel drops the assertions with the process and the marker file turns the
/// lid lock off at the next launch.
@MainActor
enum PowerQuitHook {
    private static var observer: (any NSObjectProtocol)?

    static func install(_ controller: PowerController) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.releaseAllForQuit() }
        }
    }
}

/// Small text helpers for the power views.
enum PowerFormat {
    /// "1 min", "10 min", "1 hour", "2 hours", with a no-break space so the number stays with its unit.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 && minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1\u{00A0}hour" : "\(hours)\u{00A0}hours"
        }
        return "\(max(1, minutes))\u{00A0}min"
    }

    /// "1 session", "2 sessions, 1 room".
    static func holderCount(_ holders: [PowerHolderID]) -> String {
        let sessions = holders.filter { $0.kind == .session }.count
        let rooms = holders.filter { $0.kind == .room }.count
        var parts: [String] = []
        if sessions > 0 { parts.append(sessions == 1 ? "1 session" : "\(sessions) sessions") }
        if rooms > 0 { parts.append(rooms == 1 ? "1 room" : "\(rooms) rooms") }
        return parts.joined(separator: ", ")
    }

    static func symbol(for level: PowerLevel) -> String {
        switch level {
        case .off: "cup.and.saucer"
        case .awake: "cup.and.saucer.fill"
        case .lidLock: "lock.laptopcomputer"
        }
    }

    static let batteryWarning = "On battery. The Mac will not sleep in a bag."
    static let externalLidLock = "Lid lock was already on outside Ensemble. Ensemble leaves it on."
}

/// Explains the one-time lid lock setup, then installs the sudo rule if the user agrees.
@MainActor
enum PowerSetupPrompt {
    static func present(_ power: PowerController) {
        let user = NSUserName()
        let alert = NSAlert()
        alert.messageText = "Set up lid lock"
        alert.informativeText = """
        Keeping the Mac running with the lid closed uses pmset disablesleep, which needs administrator rights. \
        Setup adds the sudo rule below, which lets your account run only that command without a password. \
        It is checked with visudo, then installed as \(PowerSudoers.displayPath) with owner root and mode 0440.

        macOS asks for your administrator password. Ensemble never sees it.
        """
        let rule = NSTextField(labelWithString: PowerSudoers.ruleLine(user: user))
        rule.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        rule.isSelectable = true
        rule.lineBreakMode = .byCharWrapping
        rule.maximumNumberOfLines = 3
        rule.preferredMaxLayoutWidth = 300
        rule.frame = NSRect(x: 0, y: 0, width: 300, height: 34)
        alert.accessoryView = rule
        alert.addButton(withTitle: "Install Rule")
        alert.addButton(withTitle: "Cancel")
        guard PowerSudoers.isValidUserName(user) else {
            let failure = NSAlert()
            failure.messageText = "Lid lock setup is not available"
            failure.informativeText = "The user name \(user) cannot be used in a sudo rule."
            failure.runModal()
            return
        }
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await power.runSetup() }
        }
    }
}
