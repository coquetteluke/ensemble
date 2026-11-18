import SwiftUI
import EnsembleKit

/// Toolbar button that opens and closes the review pane.
struct ReviewToolbarButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        IconButton("plus.forwardslash.minus", help: isOpen ? "Hide changes (Option-Command-R)" : "Show changes (Option-Command-R)",
                   size: 28, active: isOpen, action: action)
    }
}

/// View menu item: Show Changes or Hide Changes, Option-Command-R.
struct ReviewMenuCommand: View {
    let isOpen: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(isOpen ? "Hide Changes" : "Show Changes", action: action)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!isAvailable)
    }
}
