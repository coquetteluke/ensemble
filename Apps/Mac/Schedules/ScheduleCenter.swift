import SwiftUI
import AppKit
import EnsembleKit

/// The app's scheduler: owns the `TaskScheduler` for the store, re-checks when the Mac wakes or the clock changes,
/// keeps the Mac awake while a run works (when the task asks for it, through Ensemble's own keep-awake), and stops App
/// Nap from delaying the timer while any task is active. It never wakes a sleeping Mac.
///
/// Started once the store has loaded its sessions (`start(store:preview:)`), so runs missed while Ensemble was closed are
/// checked against real sessions.
@MainActor @Observable
final class ScheduleCenter {
    static let shared = ScheduleCenter()

    private(set) var scheduler: TaskScheduler?
    /// Set by the app; nil leaves the Mac's sleep alone.
    @ObservationIgnored var power: PowerController?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    /// Sessions whose keep-awake switch a run turned on (turned off again when the run ends).
    @ObservationIgnored private var heldForRuns: Set<String> = []

    /// Starts the scheduler for `store`. Sample data keeps its tasks in memory and never touches the saved file.
    func start(store: SessionStore, preview: Bool) {
        guard scheduler == nil else { return }
        let scheduler = TaskScheduler(storage: preview ? InMemoryScheduleStorage(ScheduleSamples.contents()) : ScheduleFileStorage.standard)
        scheduler.onRunStarted = { [weak self] task, run in self?.runStarted(task, run) }
        scheduler.onRunEnded = { [weak self] _, run in self?.runEnded(run) }
        self.scheduler = scheduler
        // The Background popover lists the tasks' next runs with Run now and Pause.
        store.background.scheduler = scheduler
        observe(scheduler)
        Task {
            await scheduler.start(runner: store)
            self.updateActivity()
        }
    }

    /// How long after the Mac wakes the missed runs start, so Wi-Fi and the engines are back first. (The timer's own
    /// minute check may start them a little sooner; either way they run once.)
    static let wakeDelay: Duration = .seconds(15)

    // MARK: Waking and clock changes

    private func observe(_ scheduler: TaskScheduler) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: ScheduleCenter.wakeDelay)
                await scheduler.didWake()
            }
        })
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in await scheduler.check() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { scheduler.stop() }
        })
        // Re-evaluated whenever tasks change.
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = scheduler.tasks
                    } onChange: {
                        continuation.resume()
                    }
                }
                self?.updateActivity()
            }
        }
    }

    /// Holds an activity that keeps App Nap from delaying the timer while any task is active. Idle sleep stays allowed.
    private func updateActivity() {
        let needed = (scheduler?.activeTaskCount ?? 0) > 0
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Waiting to run scheduled tasks")
        } else if !needed, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    // MARK: Keep awake

    private func runStarted(_ task: ScheduledTask, _ run: ScheduleRun) {
        guard task.keepAwake, let sessionID = run.sessionID, let power else { return }
        let holder = PowerHolderID.session(sessionID)
        guard power.level(for: holder) == .off else { return }
        power.setKeepAwake(true, for: holder)
        heldForRuns.insert(sessionID)
    }

    private func runEnded(_ run: ScheduleRun) {
        guard let sessionID = run.sessionID, heldForRuns.remove(sessionID) != nil, let power else { return }
        let holder = PowerHolderID.session(sessionID)
        if power.level(for: holder) == .awake { power.setKeepAwake(false, for: holder) }
    }
}

/// What the editor sheet edits: a new task (optionally prefilled) or an existing one.
struct ScheduleEditorRequest: Identifiable {
    let id = UUID()
    var task: ScheduledTask
    var isNew: Bool
}
