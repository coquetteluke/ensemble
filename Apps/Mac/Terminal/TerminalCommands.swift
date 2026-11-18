import SwiftUI
import AppKit
import EnsembleKit

/// Toolbar button that shows and hides the terminal pane.
struct TerminalToolbarButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        IconButton("terminal", help: isOpen ? "Hide terminal (Control-`)" : "Show terminal (Control-`)",
                   size: 28, active: isOpen, action: action)
    }
}

/// View menu item: Show Terminal or Hide Terminal, Control-backquote.
struct TerminalMenuCommand: View {
    let isOpen: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(isOpen ? "Hide Terminal" : "Show Terminal", action: action)
            .appShortcut(.toggleTerminal)
            .disabled(!isAvailable)
    }
}

/// The app's delegate. Before quitting it asks once when programs are still running in terminal tabs, and when
/// quitting it ends every terminal shell (killing any that ignore the hangup) so none outlive the app.
@MainActor
final class EnsembleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TerminalCenter.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalCenter.shared.terminateAll()
    }
}
