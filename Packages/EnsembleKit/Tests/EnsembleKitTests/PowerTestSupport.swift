import Foundation
import Synchronization
@testable import EnsembleKit

/// In-memory stand-in for the Mac: assertions, SleepDisabled, the sudo rule, lid and battery.
final class FakePowerBackend: PowerBackend {
    struct State {
        var awakeHeld = false
        var awakeHoldCount = 0
        var sleepDisabled = false
        var sudoReady = true
        var lid = true
        var battery = false
        var toolActive = false
        var installResult: PowerSetupResult = .installed
        /// Every pmset command, as "disablesleep 1" or "disablesleep 0".
        var commands: [String] = []
        /// Whether the crash marker existed when `disablesleep 1` ran.
        var markerExistedOnEnable: [Bool] = []
        var sudoChecks = 0
    }

    let state: Mutex<State>
    let markerURL: URL?

    init(_ initial: State = State(), markerURL: URL? = nil) {
        self.state = Mutex(initial)
        self.markerURL = markerURL
    }

    var snapshot: State { state.withLock { $0 } }

    func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    func holdAwake(reason: String) -> Bool {
        state.withLock {
            if !$0.awakeHeld { $0.awakeHoldCount += 1 }
            $0.awakeHeld = true
        }
        return true
    }

    func releaseAwake() {
        state.withLock { $0.awakeHeld = false }
    }

    func readSleepDisabled() -> Bool? {
        state.withLock { $0.sleepDisabled }
    }

    func setSleepDisabled(_ disabled: Bool) -> PowerCommandResult {
        let markerExists = markerURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return state.withLock {
            $0.commands.append("disablesleep \(disabled ? 1 : 0)")
            if disabled { $0.markerExistedOnEnable.append(markerExists) }
            guard $0.sudoReady else { return .needsSetup }
            $0.sleepDisabled = disabled
            return .ok
        }
    }

    func sudoRuleStatus() -> SudoRuleStatus {
        state.withLock {
            $0.sudoChecks += 1
            return $0.sudoReady ? .ready : .missing
        }
    }

    func installSudoRule() -> PowerSetupResult {
        state.withLock {
            if $0.installResult == .installed { $0.sudoReady = true }
            return $0.installResult
        }
    }

    func hasLid() -> Bool { state.withLock { $0.lid } }
    func isOnBattery() -> Bool { state.withLock { $0.battery } }
    func externalLidLockToolActive() -> Bool { state.withLock { $0.toolActive } }
}

/// A clock the test moves by hand.
@MainActor final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { date = date.addingTimeInterval(minutes * 60) }
}

/// A controller wired to a fake backend, a temporary marker file and private defaults.
@MainActor struct PowerHarness {
    let backend: FakePowerBackend
    let clock: TestClock
    let marker: PowerMarker
    let defaults: UserDefaults
    let controller: PowerController

    init(_ initial: FakePowerBackend.State = .init(), markerExists: Bool = false, defaults: UserDefaults? = nil) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ensemble-power-tests-\(UUID().uuidString)", isDirectory: true)
        let marker = PowerMarker(url: folder.appendingPathComponent("power-lid-lock.marker"))
        if markerExists { marker.write() }
        let suite = defaults ?? UserDefaults(suiteName: "ensemble-power-tests-\(UUID().uuidString)")!
        let backend = FakePowerBackend(initial, markerURL: marker.url)
        let clock = TestClock()
        self.backend = backend
        self.clock = clock
        self.marker = marker
        self.defaults = suite
        self.controller = PowerController(backend: backend, marker: marker, defaults: suite,
                                          schedulesTimers: false, now: { clock.date })
    }

    /// Starts the controller and waits for lid lock commands to finish.
    func start() async {
        await controller.start()
        await controller.waitUntilSettled()
    }

    func settle() async {
        await controller.waitUntilSettled()
    }
}
