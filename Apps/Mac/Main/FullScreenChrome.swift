import AppKit
import SwiftUI

/// Whether the main window is in full screen. In full screen the window toolbar shows only on hover
/// (`windowToolbarFullScreenVisibility(.onHover)`), so the window draws its own buttons in the title row instead of
/// leaving an empty strip over it.
@Observable @MainActor
final class FullScreenState {
    static let shared = FullScreenState()
    var isOn = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        // A window restored in full screen entered it before anyone was listening.
        isOn = NSApp?.windows.contains { $0.styleMask.contains(.fullScreen) } ?? false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FullScreenState.shared.isOn = true }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FullScreenState.shared.isOn = false }
        })
    }
}
