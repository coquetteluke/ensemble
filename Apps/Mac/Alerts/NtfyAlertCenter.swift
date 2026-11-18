import Foundation
import Observation
import EnsembleKit

/// Sends "Needs you", "Finished" and "Failed" to the user's own ntfy topic, so the ntfy app on the iPhone can show them
/// when Ensemble's own iPhone app is closed (a free Apple account cannot send push notifications). Off by default.
///
/// It does not watch sessions itself: `AttentionCenter` tells it about every alert it raises, so the phone hears about
/// exactly what the Mac alerts for. The server, topic and token live in the keychain; the on and hide-titles switches
/// in UserDefaults. Nothing about a session but its title (or not even that) is sent; see `NtfyAlerts`.
@MainActor @Observable
final class NtfyAlertCenter {
    /// The app-wide instance. While rendering snapshots or showing sample data it never reads or writes the keychain.
    static let shared: NtfyAlertCenter = {
        let sampleData = CommandLine.arguments.contains("--render-snapshots") || AppEngine.usePreview
        return NtfyAlertCenter(storage: sampleData ? .memory() : .keychain, defaults: sampleData ? nil : .standard)
    }()

    enum Key {
        static let enabled = "alerts.ntfy.enabled"
        static let hideTitles = "alerts.ntfy.hideTitles"
    }

    /// The outcome of the last alert, for the settings screen.
    enum Status: Equatable {
        case sent(test: Bool, at: Date)
        case failed(String)
    }

    /// Where the server, topic and token are kept.
    struct Storage {
        var load: () -> NtfyAlerts.Settings?
        var save: (NtfyAlerts.Settings) throws -> Void
        var delete: () throws -> Void

        static var keychain: Storage {
            Storage(load: {
                guard let data = try? RemoteKeychain.read(service: service, account: account) else { return nil }
                return try? JSONDecoder().decode(NtfyAlerts.Settings.self, from: data)
            },
            save: { settings in
                try RemoteKeychain.write(try JSONEncoder().encode(settings), service: service, account: account,
                                         label: "Ensemble alerts (ntfy)")
            },
            delete: { try RemoteKeychain.delete(service: service, account: account) })
        }

        static func memory(_ initial: NtfyAlerts.Settings? = nil) -> Storage {
            final class Box { var value: NtfyAlerts.Settings? }
            let box = Box()
            box.value = initial
            return Storage(load: { box.value }, save: { box.value = $0 }, delete: { box.value = nil })
        }

        private static let service = "com.coquetteluke.ensemble.alerts"
        private static let account = "ntfy"
    }

    var enabled: Bool {
        didSet { defaults?.set(enabled, forKey: Key.enabled) }
    }
    var hideTitles: Bool {
        didSet { defaults?.set(hideTitles, forKey: Key.hideTitles) }
    }
    private(set) var settings: NtfyAlerts.Settings?
    private(set) var status: Status?
    private(set) var sendingTest = false

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var limiter = NtfyAlertLimiter()

    init(storage: Storage, defaults: UserDefaults? = .standard, enabled: Bool? = nil, hideTitles: Bool? = nil) {
        self.storage = storage
        self.defaults = defaults
        self.enabled = enabled ?? defaults?.bool(forKey: Key.enabled) ?? false
        self.hideTitles = hideTitles ?? defaults?.bool(forKey: Key.hideTitles) ?? false
        self.settings = storage.load()
    }

    /// Checks and keeps the server, topic and token. Throws `NtfyAlerts.Failure` for a server or topic alerts may not use.
    func save(server: String, topic: String, accessToken: String) throws {
        let url = try NtfyAlerts.serverURL(server)
        let checkedTopic = try NtfyAlerts.topic(topic)
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = NtfyAlerts.Settings(server: url.absoluteString, topic: checkedTopic, accessToken: token.isEmpty ? nil : token)
        guard next != settings else { return }
        try storage.save(next)
        settings = next
        status = nil
    }

    /// Forgets the server, topic and token and turns alerts off.
    func forget() {
        try? storage.delete()
        settings = nil
        enabled = false
        status = nil
    }

    /// Called by `AttentionCenter` for every event it alerted for, with the session's title.
    func forward(_ event: SessionAttentionEvent, title: String?) {
        let kind: NtfyAlerts.Event
        switch event {
        case .needsYou: kind = .needsYou
        case .finished: kind = .finished
        case .failed: kind = .failed
        case .promptClosed, .started: return
        }
        guard enabled, let settings, limiter.allow("\(kind.rawValue):\(event.sessionID)") else { return }
        let hide = hideTitles
        Task {
            do {
                try await NtfyAlerts.send(kind, title: title, hideTitles: hide, settings: settings)
                status = .sent(test: false, at: Date())
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Sends "Test alert from Ensemble" with the saved settings.
    func sendTest() async {
        guard let settings else {
            status = .failed("Save a server and topic first.")
            return
        }
        sendingTest = true
        defer { sendingTest = false }
        do {
            try await NtfyAlerts.send(.test, title: nil, hideTitles: true, settings: settings)
            status = .sent(test: true, at: Date())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// A topic nobody can guess: on a public server anyone who knows a topic can read it.
    static func randomTopic() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return "ensemble-" + String((0..<20).map { _ in letters[Int.random(in: 0..<letters.count, using: &generator)] })
    }
}
