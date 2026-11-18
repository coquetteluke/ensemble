import SwiftUI

/// Window menu item that opens the Pair iPhone window.
struct PairIPhoneButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Pair iPhone…") { openWindow(id: "pair-iphone") }
            .keyboardShortcut("p", modifiers: [.command, .shift, .option])
    }
}
