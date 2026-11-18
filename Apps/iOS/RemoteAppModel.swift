import EnsembleKit
import SwiftUI
import UIKit

/// A chat to show: a session, or a room's transcript (same id as its Session Hub row).
struct ChatRoute: Hashable {
    var sessionID: String
    var title: String
}

/// Top-level screens. On the outer screen these are tabs; on the inner screen Hub and Rooms share the
/// sidebar and Usage and Settings show in the detail column.
enum RemoteTab: String, Hashable {
    case hub, rooms, usage, settings
}

/// Holds the pairing (in the Keychain), the live client, and every bit of UI state that must survive the
/// layout switching between the outer and inner screen of a foldable iPhone: the selected screen, the open
/// chat, composer drafts and scroll positions. Views read and write these instead of their own @State.
@MainActor @Observable
final class RemoteAppModel {
    private(set) var client: RemoteClient?
    private(set) var isDemo = false
    private let store = RemotePairingStore()

    // MARK: Navigation and per-chat UI state

    var tab: RemoteTab = .hub {
        didSet { if tab == .hub || tab == .rooms { listTab = tab } }
    }
    /// Hub or Rooms: what the sidebar lists on the inner screen, and the tab a chat was opened from.
    private(set) var listTab: RemoteTab = .hub
    var hubPath: [ChatRoute] = []
    var roomsPath: [ChatRoute] = []
    /// Unsent composer text per chat.
    var drafts: [String: String] = [:]
    /// `@agent` picked in the room composer, per chat.
    var addressees: [String: String] = [:]
    /// Transcript row at the bottom of the screen, per chat, so the position survives a layout change.
    var scrollAnchors: [String: String] = [:]

    /// The chat shown for the current list (Hub or Rooms).
    var selectedChat: ChatRoute? {
        listTab == .rooms ? roomsPath.last : hubPath.last
    }

    /// Opens a chat from the Hub or Rooms list.
    func open(_ route: ChatRoute, from list: RemoteTab) {
        if list == .rooms { roomsPath = [route] } else { hubPath = [route] }
        tab = list == .rooms ? .rooms : .hub
    }

    /// Switches the sidebar between Hub and Rooms (inner screen).
    func showList(_ list: RemoteTab) {
        tab = list == .rooms ? .rooms : .hub
    }

    init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        // Launch arguments for screenshots without tapping: -tab rooms, -open <sessionID>, -pairingCode <code>.
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "tab"), let t = RemoteTab(rawValue: raw) { tab = t }
        if let id = defaults.string(forKey: "open") { open(ChatRoute(sessionID: id, title: ""), from: tab == .rooms ? .rooms : .hub) }
        if let code = defaults.string(forKey: "pairingCode"), (try? pair(with: code)) != nil { return }
        #endif
        if args.contains("-demo") {
            startDemo()
        } else if let saved = store.load() {
            connect(saved)
        }
    }

    /// Reads a pairing code (scanned or pasted), saves it and connects.
    func pair(with code: String) throws {
        let pairing = try RemotePairing(code: code)
        try store.save(pairing)
        isDemo = false
        if let client, !client.isInProcess {
            client.updatePairing(pairing)
            client.reconnectNow()
        } else {
            connect(pairing)
        }
    }

    /// Forgets the Mac.
    func unpair() {
        client?.stop()
        client = nil
        isDemo = false
        resetNavigation()
        try? store.delete()
    }

    private func resetNavigation() {
        hubPath = []
        roomsPath = []
        drafts = [:]
        addressees = [:]
        scrollAnchors = [:]
        tab = .hub
    }

    /// Shows sample data with no Mac, to try the app.
    func startDemo() {
        client?.stop()
        if client != nil { resetNavigation() }
        let demo = RemoteClient(inProcessHost: DemoRemoteHost(), macName: "Demo Mac")
        demo.start()
        client = demo
        isDemo = true
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard let client, !client.isInProcess else { return }
        switch phase {
        case .active:
            if !client.state.isConnected { client.reconnectNow() }
        case .background:
            // iOS suspends sockets in the background; close cleanly and reconnect on return.
            client.stop()
        default:
            break
        }
    }

    private func connect(_ pairing: RemotePairing) {
        client?.stop()
        let c = RemoteClient(pairing: pairing, deviceName: UIDevice.current.name, deviceID: Self.deviceID())
        c.start()
        client = c
    }

    private static func deviceID() -> String {
        let key = "remote.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
