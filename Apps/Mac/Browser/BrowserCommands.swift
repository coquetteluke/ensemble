import SwiftUI
import EnsembleKit

/// Toolbar button that opens and closes the browser pane.
struct BrowserToolbarButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        IconButton("globe", help: isOpen ? "Hide the browser (Option-Command-B)" : "Show the browser (Option-Command-B)",
                   size: 28, active: isOpen, action: action)
    }
}

/// View menu item: Show Browser or Hide Browser, Option-Command-B.
struct BrowserMenuCommand: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(isOpen ? "Hide Browser" : "Show Browser", action: action)
            .appShortcut(.toggleBrowser)
    }
}
