import SwiftUI
import AppKit
import Observation
import EnsembleKit

/// Watches every session from outside the store and tells the user when one needs them, finishes or fails:
/// macOS notifications, sounds, the Dock badge and the menu bar count. Also owns the sidebar marks
/// (pinned, unread, completed) and opens a session from a notification or the menu bar.
///
/// Alerts only fire when the session is not on screen (the selected session, or any split pane), or when Ensemble is not
/// the frontmost app.
/// Started by the sidebar (`attach`); the app-wide instance is `shared`.
@Observable @MainActor
final class AttentionCenter {
    /// The app-wide instance. While rendering snapshots it never starts (no alerts, no permission prompt), and
    /// with sample data (`--preview`) its marks stay in memory so sample sessions never reach the saved file.
    static let shared: AttentionCenter = {
        let rendering = CommandLine.arguments.contains("--render-snapshots")
        let sampleData = rendering || AppEngine.usePreview
        return AttentionCenter(marks: SessionAttentionMarks(fileURL: sampleData ? nil : SessionAttentionMarks.defaultURL),
                               canStart: !rendering)
    }()

    /// Pinned, unread and completed, saved in Application Support.
    let marks: SessionAttentionMarks
    /// Top-level sessions as last seen (for the menu bar).
    private(set) var snapshots: [SessionAttentionSnapshot] = []
    /// Dock badge and menu bar totals, including `extraNeedsYou`.
    private(set) var totals = SessionAttentionTotals()

    /// Extra needs-you count from outside the session list (rooms: `{ rooms.needsYouTotal }`). It is read while
    /// observing, so when it reads observable state its changes update the badge and the menu bar too.
    @ObservationIgnored var extraNeedsYou: (@MainActor () -> Int)? {
        didSet { refresh() }
    }
    private(set) var extraCount = 0

    /// Called for every event with whether it alerted (tests and diagnostics).
    @ObservationIgnored var eventObserver: (@MainActor (SessionAttentionEvent, _ alerted: Bool) -> Void)?

    @ObservationIgnored private(set) weak var store: SessionStore?
    @ObservationIgnored private weak var window: WindowState?
    @ObservationIgnored private weak var mainWindow: NSWindow?
    @ObservationIgnored private var openMainWindow: (@MainActor () -> Void)?
    @ObservationIgnored private var tracker = SessionAttentionTracker()
    @ObservationIgnored private var notifier: AttentionNotifier?
    /// A session asked to open before the sessions had loaded (a notification clicked while Ensemble was closed).
    @ObservationIgnored private var pendingOpen: String?
    @ObservationIgnored private var statusItem: AttentionStatusItem?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var visibleSessionIDs: Set<String> = []
    /// Notification ids posted per session, so they can be removed once seen.
    @ObservationIgnored private var posted: [String: Set<String>] = [:]
    @ObservationIgnored private var lastSound = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    /// False for centers that only feed views (snapshots): `attach` does nothing.
    @ObservationIgnored private let canStart: Bool

    init(marks: SessionAttentionMarks, canStart: Bool = true) {
        self.marks = marks
        self.canStart = canStart
    }

    // MARK: Setup

    /// Starts watching `store`. Safe to call again; a new store starts a fresh baseline.
    func attach(store: SessionStore, window: WindowState) {
        guard canStart, self.store !== store || self.window !== window else { return }
        self.store = store
        self.window = window
        tracker = SessionAttentionTracker()
        visibleSessionIDs = []
        installNotificationHandler()
        if statusItem == nil { statusItem = AttentionStatusItem(center: self) }
        if observers.isEmpty { installObservers() }
        if AttentionSettings.notifications { requestNotificationPermission() }
        refresh()
    }

    /// Becomes the notification delegate. Call at launch too, so a notification clicked while Ensemble was
    /// closed still opens its session once the sessions load.
    func installNotificationHandler() {
        guard canStart, notifier == nil else { return }
        let notifier = AttentionNotifier { [weak self] sessionID in self?.open(sessionID) }
        notifier.install()
        self.notifier = notifier
    }

    /// The window that shows the sessions, so "on screen" can check it is visible.
    func registerMainWindow(_ window: NSWindow?) {
        guard let window, window !== mainWindow else { return }
        mainWindow = window
        refresh()
    }

    /// How to reopen the main window after it was closed (`openWindow(id: "main")`).
    func registerOpenWindow(_ action: @escaping @MainActor () -> Void) {
        openMainWindow = action
    }

    func requestNotificationPermission() {
        Task { await AttentionNotifier.requestAuthorization() }
    }

    // MARK: Menu bar and sidebar queries

    /// Sessions with an open prompt, longest waiting first.
    var needsYouSessions: [SessionAttentionSnapshot] {
        snapshots.filter(\.needsYou).sorted { ($0.prompts.first?.created ?? .distantPast) < ($1.prompts.first?.created ?? .distantPast) }
    }

    /// Sessions working right now, by title.
    var runningSessions: [SessionAttentionSnapshot] {
        snapshots.filter(\.working).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The sidebar's arrangement with the saved group and sort choices.
    func arrangement(store: SessionStore, grouping: SidebarGrouping? = nil, sort: SidebarSort? = nil, search: String = "") -> SidebarArrangement {
        let defaults = UserDefaults.standard
        let grouping = grouping ?? SidebarGrouping(rawValue: defaults.string(forKey: AttentionSettings.Key.sidebarGrouping) ?? "") ?? .project
        let sort = sort ?? SidebarSort(rawValue: defaults.string(forKey: AttentionSettings.Key.sidebarSort) ?? "") ?? .recent
        let entries = store.sidebarEntries(marks: marks).filter { $0.matches(search) }
        return SidebarArrangement.arrange(entries, grouping: grouping, sort: sort, parents: store.sessionParents,
                                          folderOrder: AttentionSettings.sidebarFolderOrder)
    }

    /// Sessions in the order the sidebar shows them (for Command-1 to 9).
    func sidebarOrder(store: SessionStore) -> [SessionModel] {
        arrangement(store: store).order.compactMap { store.session($0.id) }
    }

    // MARK: Actions

    /// Brings Ensemble forward and opens the session.
    func open(_ sessionID: String) {
        showMainWindow()
        guard let store, let window, store.isLoaded, store.session(sessionID) != nil else {
            // Tried again once the sessions have loaded (dropped then if the session is gone).
            pendingOpen = sessionID
            return
        }
        pendingOpen = nil
        window.open(sessionID, store: store)
    }

    /// Brings Ensemble's main window forward, reopening it if it was closed.
    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    func setPinned(_ sessionID: String, _ on: Bool) { marks.setPinned(sessionID, on) }
    func setCompleted(_ sessionID: String, _ on: Bool) { marks.setCompleted(sessionID, on) }
    func setUnread(_ sessionID: String, _ on: Bool) { marks.setUnread(sessionID, on) }

    /// Forgets a deleted session's marks and notifications.
    func forget(_ sessionID: String) {
        marks.forget(sessionID)
        removeNotifications(for: sessionID)
    }

    /// Applies the Dock badge and menu bar settings to the current totals.
    func applyPreferences() {
        let label = AttentionSettings.dockBadge ? totals.badgeLabel : ""
        let wanted: String? = label.isEmpty ? nil : label
        if NSApp.dockTile.badgeLabel != wanted { NSApp.dockTile.badgeLabel = wanted }
        statusItem?.update(totals: totals, visible: AttentionSettings.menuBarIcon)
    }

    func playSound(_ name: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSound) > 1.5 else { return }
        lastSound = now
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Observing

    /// Re-reads the store now and keeps observing it.
    func refresh() {
        guard let store, let window else { return }
        generation &+= 1
        let mine = generation
        let (snapshots, extra, visible) = withObservationTracking {
            (store.isLoaded ? store.attentionSnapshots() : [], extraNeedsYou?() ?? 0, visibleSessions(store: store, window: window))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == mine else { return }
                self.refresh()
            }
        }
        process(snapshots: snapshots, extra: extra, visible: visible, loaded: store.isLoaded)
    }

    private func process(snapshots: [SessionAttentionSnapshot], extra: Int, visible: Set<String>, loaded: Bool) {
        if self.snapshots != snapshots { self.snapshots = snapshots }
        if extraCount != extra { extraCount = extra }
        let totals = SessionAttentionTotals.count(snapshots, extraNeedsYou: extra)
        if self.totals != totals { self.totals = totals }
        applyPreferences()

        if visible != visibleSessionIDs {
            // Sessions that just came on screen are read, and their notifications are no longer needed.
            let appeared = visible.subtracting(visibleSessionIDs)
            visibleSessionIDs = visible
            for id in appeared.sorted() { seen(id) }
        }

        guard loaded else { return }
        if let id = pendingOpen, let store, let window {
            pendingOpen = nil
            if store.session(id) != nil { window.open(id, store: store) }
        }
        handle(tracker.update(snapshots, now: Date()))
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        guard let deadline = tracker.nextDeadline else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.handle(self.tracker.flush(now: Date()))
            self.scheduleFlush()
        }
    }

    /// The top-level sessions on screen: every split pane's, or the selected one's. None when Ensemble is not in front,
    /// its window is hidden or miniaturized, or it shows something else.
    private func visibleSessions(store: SessionStore, window: WindowState) -> Set<String> {
        let windowShown = mainWindow.map { $0.isVisible && !$0.isMiniaturized } ?? true
        return Self.visibleSessions(store: store, window: window, appActive: NSApp.isActive, windowShown: windowShown)
    }

    /// `visibleSessions` from plain values (the snapshot run checks it). A pane showing a subagent counts as its parent.
    static func visibleSessions(store: SessionStore, window: WindowState, appActive: Bool, windowShown: Bool) -> Set<String> {
        guard appActive, windowShown, window.route == .session else { return [] }
        let shown = window.split.isActive ? window.split.panes.map(\.sessionID) : (store.selectedSessionID.map { [$0] } ?? [])
        return Set(shown.compactMap { id in store.session(id).map { $0.info.parentID ?? $0.id } })
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            // Checked on the next turn: a window closes after its notification is sent.
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            observers.append(token)
        }
        // Settings changed (here or in the Settings window): badge and menu bar icon follow at once.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyPreferences() }
        })
    }

    // MARK: Events

    private func handle(_ events: [SessionAttentionEvent]) {
        guard !events.isEmpty, let store else { return }
        var sound: String?
        for event in events {
            let id = event.sessionID
            let alerted = alerts(event) && shouldAlert(id)
            defer { eventObserver?(event, alerted) }
            // The same alert to the phone through ntfy, when the user set that up (Settings > Alerts).
            if alerted { NtfyAlertCenter.shared.forward(event, title: (tracker.snapshot(id) ?? snapshots.first { $0.id == id })?.title) }
            switch event {
            case .needsYou(_, let request):
                marks.setCompleted(id, false)
                guard alerted else { continue }
                notify(id, identifier: "needs-\(request.id)", state: "Needs you", body: SessionAttentionText.ask(request))
                if AttentionSettings.needsYouSound { sound = AttentionSettings.needsYouSoundName }

            case .promptClosed(_, let requestID):
                removeNotification("needs-\(requestID)", for: id)

            case .started:
                marks.setCompleted(id, false)
                removeNotification("done-\(id)", for: id)
                removeNotification("failed-\(id)", for: id)

            case .finished:
                guard alerted else { continue }
                marks.setUnread(id, true)
                let body = store.lastAgentText(id).map { SessionAttentionText.excerpt($0) } ?? ""
                notify(id, identifier: "done-\(id)", state: "Finished", body: body)
                if AttentionSettings.finishedSound, sound == nil { sound = AttentionSettings.finishedSoundName }

            case .failed:
                guard alerted else { continue }
                marks.setUnread(id, true)
                let body = store.lastErrorText(id).map { SessionAttentionText.excerpt($0) } ?? ""
                notify(id, identifier: "failed-\(id)", state: "Failed", body: body)
                if AttentionSettings.needsYouSound { sound = AttentionSettings.needsYouSoundName }
            }
        }
        if let sound { playSound(sound) }
    }

    private func alerts(_ event: SessionAttentionEvent) -> Bool {
        switch event {
        case .needsYou, .finished, .failed: true
        case .promptClosed, .started: false
        }
    }

    /// False when the session is on screen (in any split pane) in the frontmost app (checked now, not at the last
    /// observation).
    private func shouldAlert(_ sessionID: String) -> Bool {
        guard let store, let window else { return true }
        return !visibleSessions(store: store, window: window).contains(sessionID)
    }

    /// The user is looking at the session: it is read, and its notifications are no longer needed.
    private func seen(_ sessionID: String) {
        marks.setUnread(sessionID, false)
        removeNotifications(for: sessionID)
    }

    private func notify(_ sessionID: String, identifier: String, state: String, body: String) {
        guard AttentionSettings.notifications, let notifier else { return }
        let snapshot = tracker.snapshot(sessionID) ?? snapshots.first { $0.id == sessionID }
        let title = snapshot?.title ?? "Session"
        let folder = snapshot.map { Format.folderName($0.directory) } ?? ""
        notifier.post(identifier: identifier, sessionID: sessionID, title: title,
                      subtitle: folder.isEmpty ? state : "\(state) \u{00B7} \(folder)", body: body)
        posted[sessionID, default: []].insert(identifier)
    }

    private func removeNotification(_ identifier: String, for sessionID: String) {
        guard posted[sessionID]?.remove(identifier) != nil else { return }
        notifier?.remove(identifiers: [identifier])
    }

    private func removeNotifications(for sessionID: String) {
        guard let ids = posted.removeValue(forKey: sessionID), !ids.isEmpty else { return }
        notifier?.remove(identifiers: Array(ids))
    }
}
