import Foundation
import Observation

/// Keeps the Mac awake (and optionally running with the lid closed) while sessions and rooms that asked
/// for it are working.
///
/// Each holder (a session or a room) has a switch level: off, awake, or lid lock. A holder holds while its
/// switch is on and it is working, and for a grace period after it stops (default 10 minutes). Turning a
/// switch on counts as activity, so it holds for the grace period even when idle. When the grace period
/// runs out the holder stops holding but keeps its switch, so it holds again the next time it works.
/// The effective level is the highest level over the holders that hold.
///
/// Keep awake uses power assertions. Lid lock runs `sudo -n /usr/bin/pmset disablesleep 1`; if
/// `SleepDisabled` was already 1 (Luke's `lidlock`, or anything else), Ensemble relies on it and never sets
/// it back to 0. A marker file records that Ensemble turned lid lock on, so a crash is cleaned up at the
/// next launch.
@MainActor @Observable
public final class PowerController {
    // MARK: State for views

    /// The Mac has a built-in lid. The lid lock option is hidden when false.
    public private(set) var hasLid = false
    public private(set) var sudoStatus: SudoRuleStatus = .unknown
    public private(set) var onBattery = false
    /// Ensemble holds the keep-awake power assertions.
    public private(set) var awakeActive = false
    public private(set) var lidLockSource: LidLockSource = .off
    /// Why lid lock is not in effect, or could not be turned off.
    public private(set) var lidLockProblem: LidLockProblem?
    /// A one-line message about something that happened outside a direct action.
    public private(set) var notice: String?
    /// Seconds a holder keeps holding after it stops working.
    public private(set) var gracePeriod: TimeInterval
    public private(set) var setupRunning = false
    /// Why the last setup did not finish, if it failed.
    public private(set) var setupMessage: String?
    /// Holders that hold right now, with the level each asks for.
    public private(set) var activeLevels: [PowerHolderID: PowerLevel] = [:]
    public private(set) var started = false

    private var holders: [PowerHolderID: HolderState] = [:]

    struct HolderState: Equatable {
        var level: PowerLevel
        var working = false
        /// When it last stopped working, or when its switch was last changed while idle.
        var lastActive: Date?
    }

    // MARK: Configuration

    public static let defaultGracePeriod: TimeInterval = 600
    public static let gracePeriodChoices: [TimeInterval] = [60, 300, 600, 900, 1800, 3600]
    /// How often `pmset` and the power source are re-read while lid lock is wanted.
    public static let pollInterval: TimeInterval = 60
    public static let assertionReason = "Ensemble is keeping the Mac awake for a working agent"

    enum Keys {
        static let levels = "power.levels"
        static let gracePeriod = "power.gracePeriodSeconds"
    }

    @ObservationIgnored private let backend: any PowerBackend
    @ObservationIgnored private let marker: PowerMarker
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let schedulesTimers: Bool
    /// Lid lock changes wait until crash recovery has run.
    @ObservationIgnored private var recovered = false
    /// Set after `sudo -n pmset disablesleep 1` failed, so it is not retried on every change.
    @ObservationIgnored private var lidAttemptBlocked = false
    @ObservationIgnored private var lidPending = false
    @ObservationIgnored private var lidTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var quitting = false

    public init(
        backend: any PowerBackend,
        marker: PowerMarker = .standard,
        defaults: UserDefaults = .standard,
        schedulesTimers: Bool = true,
        now: @escaping () -> Date = { Date() }
    ) {
        self.backend = backend
        self.marker = marker
        self.defaults = defaults
        self.schedulesTimers = schedulesTimers
        self.now = now
        let savedGrace = defaults.double(forKey: Keys.gracePeriod)
        self.gracePeriod = savedGrace > 0 ? savedGrace : Self.defaultGracePeriod
        if let saved = defaults.dictionary(forKey: Keys.levels) as? [String: Int] {
            for (key, raw) in saved {
                guard let id = PowerHolderID(key: key), let level = PowerLevel(rawValue: raw), level > .off else { continue }
                holders[id] = HolderState(level: level)
            }
        }
    }

    // MARK: Summary

    /// Highest level any holder asks for right now.
    public var effectiveLevel: PowerLevel { activeLevels.values.max() ?? .off }

    /// What Ensemble actually has in effect: lid lock (its own or one it relies on), awake, or off.
    public var heldLevel: PowerLevel {
        if lidLockSource != .off { return .lidLock }
        return awakeActive ? .awake : .off
    }

    /// Holders that hold right now, highest level first, then by key.
    public var activeHolders: [(id: PowerHolderID, level: PowerLevel)] {
        activeLevels
            .map { (id: $0.key, level: $0.value) }
            .sorted { $0.level != $1.level ? $0.level > $1.level : $0.id.key < $1.id.key }
    }

    /// True if any holder has a switch on, holding or not.
    public var anySwitchOn: Bool { holders.values.contains { $0.level > .off } }

    /// True while lid lock is on and the Mac runs on battery: it will not sleep in a bag.
    public var showsBatteryWarning: Bool { lidLockSource != .off && onBattery }

    // MARK: Switches

    /// The switch level of a holder (remembered while it is idle).
    public func level(for holder: PowerHolderID) -> PowerLevel { holders[holder]?.level ?? .off }

    /// True while the holder is holding (switch on and working, or inside the grace period).
    public func isHolding(_ holder: PowerHolderID) -> Bool { activeLevels[holder] != nil }

    /// "Keep Mac awake". Turning it off also turns lid lock off.
    public func setKeepAwake(_ on: Bool, for holder: PowerHolderID) {
        setLevel(level(for: holder).settingKeepAwake(on), for: holder)
    }

    /// "Keep running with the lid closed". Turning it on also turns Keep awake on.
    public func setLidLock(_ on: Bool, for holder: PowerHolderID) {
        if on {
            lidAttemptBlocked = false
            if lidLockProblem == .needsSetup || lidLockSource == .off { lidLockProblem = nil }
        }
        setLevel(level(for: holder).settingLidLock(on), for: holder)
    }

    public func setLevel(_ level: PowerLevel, for holder: PowerHolderID) {
        guard !quitting else { return }
        var state = holders[holder] ?? HolderState(level: .off)
        guard state.level != level else { return }
        state.level = level
        if level > .off && !state.working { state.lastActive = now() }
        holders[holder] = state.level == .off && !state.working ? nil : state
        persistLevels()
        evaluate()
    }

    /// Turns every switch off.
    public func turnOffAll() {
        guard !holders.isEmpty else { return }
        for id in Array(holders.keys) {
            holders[id]?.level = .off
            if holders[id]?.working == false { holders[id] = nil }
        }
        persistLevels()
        evaluate()
    }

    // MARK: Activity

    /// Reports whether a holder is working (an agent in the session or room is running).
    public func setWorking(_ working: Bool, for holder: PowerHolderID) {
        if applyWorking(working, holder) { evaluate() }
    }

    /// Sets the working holders of one kind in one call: those in `working` work, the rest do not.
    public func syncWorking(_ working: Set<PowerHolderID>, kind: PowerHolderID.Kind) {
        var changed = false
        for (id, state) in holders where id.kind == kind && state.working && !working.contains(id) {
            changed = applyWorking(false, id) || changed
        }
        for id in working where id.kind == kind {
            changed = applyWorking(true, id) || changed
        }
        if changed { evaluate() }
    }

    /// Forgets a deleted session or room: it stops holding and its switch is dropped.
    public func remove(_ holder: PowerHolderID) {
        guard holders.removeValue(forKey: holder) != nil else { return }
        persistLevels()
        evaluate()
    }

    /// Forgets every holder of one kind that is not in `existing` (sessions or rooms that were deleted).
    /// Call it only with a complete list (after the store has loaded).
    public func syncExisting(_ existing: Set<PowerHolderID>, kind: PowerHolderID.Kind) {
        let gone = holders.keys.filter { $0.kind == kind && !existing.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { holders[id] = nil }
        persistLevels()
        evaluate()
    }

    private func applyWorking(_ working: Bool, _ holder: PowerHolderID) -> Bool {
        var state = holders[holder] ?? HolderState(level: .off)
        guard state.working != working else { return false }
        state.working = working
        if !working { state.lastActive = now() }
        holders[holder] = state.level == .off && !working ? nil : state
        return true
    }

    // MARK: Settings

    public func setGracePeriod(_ seconds: TimeInterval) {
        let value = max(1, seconds)
        guard value != gracePeriod else { return }
        gracePeriod = value
        defaults.set(value, forKey: Keys.gracePeriod)
        evaluate()
    }

    public func dismissNotice() { notice = nil }

    /// Tries lid lock again after a failure.
    public func retryLidLock() {
        lidAttemptBlocked = false
        lidLockProblem = nil
        evaluate()
    }

    /// Re-reads whether the sudo rule works.
    public func recheckSetup() async {
        let backend = self.backend
        sudoStatus = await Self.offMain { backend.sudoRuleStatus() }
        if sudoStatus == .ready { clearSetupProblem() }
        evaluate()
    }

    /// Installs the sudoers rule through the macOS password dialog, then checks it.
    public func runSetup() async {
        guard !setupRunning else { return }
        setupRunning = true
        setupMessage = nil
        let backend = self.backend
        let result = await Self.offMain { backend.installSudoRule() }
        sudoStatus = await Self.offMain { backend.sudoRuleStatus() }
        switch result {
        case .installed:
            if sudoStatus != .ready { setupMessage = "The rule was installed, but sudo still asks for a password." }
        case .cancelled:
            break
        case .failed(let message):
            setupMessage = message
        }
        if sudoStatus == .ready { clearSetupProblem() }
        setupRunning = false
        evaluate()
    }

    private func clearSetupProblem() {
        lidAttemptBlocked = false
        if lidLockProblem == .needsSetup { lidLockProblem = nil }
    }

    // MARK: Lifecycle

    /// Call once at launch: detects the lid and power source, cleans up a lid lock left on by a crash,
    /// and checks the sudo rule.
    public func start() async {
        guard !started else { return }
        started = true
        let backend = self.backend
        let probe = await Self.offMain { (backend.hasLid(), backend.isOnBattery()) }
        hasLid = probe.0
        onBattery = probe.1
        await recoverFromCrash()
        recovered = true
        if hasLid {
            sudoStatus = await Self.offMain { backend.sudoRuleStatus() }
        }
        evaluate()
    }

    /// Releases everything before the app exits. Synchronous, so it finishes inside
    /// `applicationWillTerminate`. Switches stay remembered.
    public func releaseAllForQuit() {
        quitting = true
        timerTask?.cancel()
        lidTask?.cancel()
        backend.releaseAwake()
        awakeActive = false
        if lidLockSource == .owned || marker.exists {
            if !backend.externalLidLockToolActive() {
                _ = backend.setSleepDisabled(false)
            }
            marker.remove()
        }
        lidLockSource = .off
        activeLevels = [:]
    }

    /// Re-reads `pmset` and the power source (while lid lock matters) and re-applies the policy.
    /// The controller calls this on its own timer; tests call it after moving the clock.
    public func refresh() async {
        guard !quitting else { return }
        if lidLockSource != .off || effectiveLevel == .lidLock {
            await waitUntilSettled()
            let backend = self.backend
            let source = lidLockSource
            let reading = await Self.offMain { (backend.readSleepDisabled(), backend.isOnBattery()) }
            onBattery = reading.1
            if source != .off, lidLockSource == source, lidTask == nil, reading.0 == false {
                lidLockTurnedOffOutside()
            }
        }
        evaluate()
    }

    /// Waits for running lid lock commands to finish.
    public func waitUntilSettled() async {
        while let task = lidTask { await task.value }
    }

    // MARK: Policy

    private func evaluate() {
        guard !quitting else { return }
        let date = now()
        var active: [PowerHolderID: PowerLevel] = [:]
        for (id, state) in holders {
            let level = hasLid ? state.level : min(state.level, .awake)
            guard level > .off else { continue }
            let inGrace = state.lastActive.map { date < $0.addingTimeInterval(gracePeriod) } ?? false
            if state.working || inGrace { active[id] = level }
        }
        if active != activeLevels { activeLevels = active }

        let wantsAwake = effectiveLevel >= .awake
        if wantsAwake && !awakeActive {
            awakeActive = backend.holdAwake(reason: Self.assertionReason)
        } else if !wantsAwake && awakeActive {
            backend.releaseAwake()
            awakeActive = false
        }

        let wantsLid = effectiveLevel == .lidLock
        if !wantsLid && lidLockSource == .off {
            lidAttemptBlocked = false
            if lidLockProblem != nil { lidLockProblem = nil }
        }
        if wantsLid != (lidLockSource != .off) { requestLidReconcile() }
        scheduleTimer()
    }

    private func requestLidReconcile() {
        lidPending = true
        guard lidTask == nil else { return }
        lidTask = Task { await self.runLidLoop() }
    }

    private func runLidLoop() async {
        while lidPending && !quitting {
            lidPending = false
            await reconcileLidOnce()
        }
        lidTask = nil
        scheduleTimer()
    }

    private func reconcileLidOnce() async {
        guard recovered else { return }
        let backend = self.backend
        var failed = false
        switch (effectiveLevel == .lidLock, lidLockSource) {
        case (true, .off):
            guard !lidAttemptBlocked else { return }
            let reading = await Self.offMain { (backend.readSleepDisabled(), backend.isOnBattery()) }
            let current = reading.0
            onBattery = reading.1
            guard !quitting else { return }
            guard effectiveLevel == .lidLock else { break }
            if current == true {
                // Already on (lidlock or anything else): rely on it, never turn it off.
                lidLockSource = .external
                lidLockProblem = nil
                break
            }
            // The marker goes down first, so a crash during the command is still cleaned up.
            marker.write(now: now())
            let result = await Self.offMain { backend.setSleepDisabled(true) }
            switch result {
            case .ok:
                lidLockSource = .owned
                lidLockProblem = nil
                sudoStatus = .ready
            case .needsSetup:
                marker.remove()
                sudoStatus = .missing
                lidLockProblem = .needsSetup
                lidAttemptBlocked = true
                failed = true
            case .failed(let message):
                marker.remove()
                lidLockProblem = .failed("Could not turn lid lock on: \(message)")
                lidAttemptBlocked = true
                failed = true
            }
        case (false, .owned):
            let toolActive = await Self.offMain { backend.externalLidLockToolActive() }
            guard !quitting, effectiveLevel != .lidLock, lidLockSource == .owned else { break }
            if toolActive {
                // The lidlock tool turned it on too and still wants it: hand it over.
                lidLockSource = .off
                marker.remove()
                break
            }
            let result = await Self.offMain { backend.setSleepDisabled(false) }
            guard !quitting else { return }
            switch result {
            case .ok:
                lidLockSource = .off
                lidLockProblem = nil
                marker.remove()
            case .needsSetup:
                lidLockProblem = .failed("Could not turn lid lock off: sudo asked for a password.")
                failed = true
            case .failed(let message):
                lidLockProblem = .failed("Could not turn lid lock off: \(message)")
                failed = true
            }
        case (false, .external):
            lidLockSource = .off
        case (true, .owned), (true, .external), (false, .off):
            break
        }
        // What is wanted may have changed while a command ran.
        if !failed, (effectiveLevel == .lidLock) != (lidLockSource != .off) {
            lidPending = true
        }
    }

    private func recoverFromCrash() async {
        guard marker.exists else { return }
        let backend = self.backend
        let reading = await Self.offMain { (backend.readSleepDisabled(), backend.externalLidLockToolActive()) }
        let (current, toolActive) = reading
        if current == true && effectiveLevel == .lidLock {
            // Something needs it right now: keep it as Ensemble's.
            lidLockSource = .owned
            return
        }
        guard current == true, !toolActive else {
            marker.remove()
            return
        }
        let result = await Self.offMain { backend.setSleepDisabled(false) }
        if result == .ok {
            marker.remove()
            notice = "Turned off the lid lock left on by Ensemble's last run."
        } else {
            // Keep the marker; the normal release path retries.
            lidLockSource = .owned
            lidLockProblem = .failed("Could not turn off the lid lock left on by Ensemble's last run.")
        }
    }

    private func lidLockTurnedOffOutside() {
        if lidLockSource == .owned { marker.remove() }
        lidLockSource = .off
        for id in Array(holders.keys) where holders[id]?.level == .lidLock {
            holders[id]?.level = .awake
        }
        persistLevels()
        notice = "Lid lock was turned off outside Ensemble."
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        timerTask = nil
        guard schedulesTimers, !quitting else { return }
        let date = now()
        var next: Date?
        for state in holders.values where !state.working && state.level > .off {
            guard let last = state.lastActive else { continue }
            let deadline = last.addingTimeInterval(gracePeriod)
            if deadline > date { next = min(next ?? deadline, deadline) }
        }
        if lidLockSource != .off || effectiveLevel == .lidLock {
            let poll = date.addingTimeInterval(Self.pollInterval)
            next = min(next ?? poll, poll)
        }
        guard let next else { return }
        let delay = max(0.5, next.timeIntervalSince(date) + 0.25)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func persistLevels() {
        var saved: [String: Int] = [:]
        for (id, state) in holders where state.level > .off {
            saved[id.key] = state.level.rawValue
        }
        defaults.set(saved, forKey: Keys.levels)
    }

    /// Runs blocking backend work on a background thread.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
}
