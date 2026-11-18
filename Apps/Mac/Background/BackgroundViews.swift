import SwiftUI
import AppKit
import EnsembleKit

/// The window's Background button: a toolbar popover listing every running subagent, background shell and task
/// across all sessions and rooms, plus the next scheduled runs, with Open and Stop on each row. A count badge shows
/// while anything runs. It also re-checks auto-continue when the Mac wakes.
///
/// A toolbar popover, like the reference app's Background tasks in its title bar, because the list covers every
/// session; the context panel is about the selected session, so it gets only that session's rows
/// (`BackgroundPanelSection`).
struct BackgroundToolbarButton: View {
    let store: SessionStore
    let window: WindowState
    var rooms: RoomsController?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showList = false
    @State private var hovering = false
    @State private var wake: WakeObserver?

    /// How often the engines are asked for background shells while the window is open (events also refresh the list).
    static let pollInterval: Duration = .seconds(10)

    var body: some View {
        let running = store.backgroundRunningCount
        Button {
            showList.toggle()
        } label: {
            Image(systemName: "rectangle.stack")
                .font(theme.font(size: 14))
                .foregroundStyle(showList ? theme.textPrimary : theme.textSecondary)
                .frame(width: theme.z(28), height: theme.z(28))
                .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering ? theme.hover : .clear))
                .overlay(alignment: .topTrailing) {
                    if running > 0 { BackgroundCountBadge(count: running).offset(x: theme.z(3), y: -theme.z(1)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(running == 0 ? "Background work" : "Background work: \(running) running")
        .accessibilityLabel("Background work")
        .accessibilityValue(running == 0 ? "Nothing running" : "\(running) running")
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            BackgroundListView(store: store, roomTitles: roomTitles) { sessionID in
                showList = false
                window.open(sessionID, store: store)
            }
            .ensembleTheme()
        }
        .task {
            guard !isSnapshot else { return }
            while !Task.isCancelled {
                await store.refreshBackgroundTasks()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        .onAppear {
            guard !isSnapshot, wake == nil else { return }
            let store = store
            wake = WakeObserver {
                Task {
                    await store.autoContinueAfterWake()
                    await store.refreshBackgroundTasks()
                }
            }
        }
    }

    private var roomTitles: [String: String] { Self.roomTitles(rooms) }

    /// The room title of each room agent's session.
    static func roomTitles(_ rooms: RoomsController?) -> [String: String] {
        guard let rooms else { return [:] }
        var titles: [String: String] = [:]
        for room in rooms.rooms {
            for sessionID in room.sessions.values { titles[sessionID] = room.spec.title }
        }
        return titles
    }
}

/// The popover's content: one group per session with running work, then the scheduled runs.
struct BackgroundListView: View {
    let store: SessionStore
    var roomTitles: [String: String] = [:]
    var now: Date?
    let onOpen: (String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let groups = store.backgroundWork(roomTitles: roomTitles)
        let running = groups.filter { !$0.isScheduled }.reduce(0) { $0 + $1.items.count }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text("Background")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: theme.z(8))
                if running > 0 {
                    Text("\(running) running")
                        .font(theme.font(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(38))
            HLine()
            if groups.isEmpty {
                Text("Nothing is running in the background")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.z(28))
            } else {
                AdaptiveScroll(.vertical) {
                    VStack(alignment: .leading, spacing: theme.z(4)) {
                        if running == 0 {
                            Text("Nothing is running in the background")
                                .font(theme.font(size: 12.5))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, theme.z(14))
                                .padding(.vertical, theme.z(8))
                        }
                        ForEach(groups) { group in
                            BackgroundGroupView(store: store, group: group, now: now, onOpen: onOpen)
                        }
                    }
                    .padding(.vertical, theme.z(6))
                }
                .frame(maxHeight: theme.z(440))
            }
        }
        .frame(width: theme.z(380), alignment: .leading)
        .background(theme.popover)
        .task {
            // Fresher than the toolbar's own refresh while the list is open.
            guard !isSnapshot else { return }
            while !Task.isCancelled {
                await store.refreshBackgroundTasks()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// A session's header (room agent dot, title, room or folder) and its rows.
struct BackgroundGroupView: View {
    let store: SessionStore
    let group: BackgroundWorkGroup
    var now: Date?
    let onOpen: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(6)) {
                if let agent = group.agentID.flatMap({ store.agents[$0] }) {
                    StatusDot(Color(hexString: agent.colorHex), size: 7)
                }
                Text(group.title)
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(26))
            ForEach(group.items) { item in
                BackgroundRow(store: store, item: item, now: now, onOpen: onOpen)
                    .padding(.horizontal, theme.z(6))
            }
        }
    }
}

/// One subagent, shell, task or scheduled run: icon, title, type, elapsed time (or next run), Open and Stop.
struct BackgroundRow: View {
    let store: SessionStore
    let item: BackgroundWorkItem
    var now: Date?
    /// The context panel's one-line rows, without an Open button for the session already shown.
    var compact = false
    var shownSessionID: String?
    let onOpen: (String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(compact ? 11 : 8)) {
            Image(systemName: Self.symbol(item.kind))
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(compact ? 18 : 16))
            VStack(alignment: .leading, spacing: theme.z(1)) {
                Text(item.title)
                    .font(item.kind == .shell ? theme.font(size: 12, design: .monospaced) : theme.font(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !compact, let detail = detailText {
                    Text(detail)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .help(item.title)
            Spacer(minLength: theme.z(6))
            timeText
            if let sessionID = item.openSessionID, sessionID != shownSessionID {
                RowIconButton(symbol: "arrow.up.forward.app", help: openHelp) {
                    onOpen(sessionID)
                }
            }
            if item.scheduledTaskID != nil, !store.isStopping(item) {
                let running = store.scheduledTaskIsRunning(item)
                RowIconButton(symbol: "play.circle", help: running ? "A run of this task is still going" : "Run this task now") {
                    Task { await store.runScheduledTaskNow(item) }
                }
                .disabled(running)
                .opacity(running ? 0.4 : 1)
            }
            if store.isStopping(item) {
                Spinner(size: 10)
                    .frame(width: theme.z(22), height: theme.z(22))
            } else {
                RowIconButton(symbol: item.kind == .schedule ? "pause.circle" : "stop.circle", help: item.stopHelp) {
                    Task { await store.stopBackground(item) }
                }
                .accessibilityLabel(item.stopLabel)
            }
        }
        .padding(.horizontal, theme.z(8))
        .frame(minHeight: theme.z(compact ? 28 : 38))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering ? theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let id = item.openSessionID { onOpen(id) } }
    }

    private var openHelp: String {
        switch item.kind {
        case .subagent: "Open this subagent"
        case .schedule: "Open the session it is running in"
        case .shell, .task: "Open the session that started it"
        }
    }

    private var detailText: String? {
        switch item.kind {
        case .subagent: item.detail.map { "Subagent \u{00B7} \($0)" } ?? "Subagent"
        case .shell: "Background command"
        case .task: "Background task"
        case .schedule: item.detail.map { "Scheduled \u{00B7} \($0)" } ?? "Scheduled"
        }
    }

    @ViewBuilder private var timeText: some View {
        if let next = item.nextRun {
            Text(PlanLimitRow.resetText(next, now: now ?? Date(), prefix: ""))
                .font(theme.font(size: 12).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .help("Next run")
        } else if let started = item.started {
            if isSnapshot || now != nil {
                elapsed(from: started, to: now ?? Date())
            } else {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    elapsed(from: started, to: context.date)
                }
            }
        }
    }

    private func elapsed(from start: Date, to end: Date) -> some View {
        Text(WorkingRow.elapsed(from: start, to: end))
            .font(theme.font(size: 12).monospacedDigit())
            .foregroundStyle(theme.textTertiary)
            .help("Running for \(WorkingRow.elapsed(from: start, to: end))")
    }

    static func symbol(_ kind: BackgroundWorkItem.Kind) -> String {
        switch kind {
        case .subagent: "person.2"
        case .shell: "terminal"
        case .task: "gearshape.2"
        case .schedule: "clock"
        }
    }
}

/// Small square icon button for list rows.
private struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 13))
                .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                .frame(width: theme.z(22), height: theme.z(22))
                .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(hovering ? theme.elevatedHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The toolbar button's running count.
struct BackgroundCountBadge: View {
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Text("\(count)")
            .font(theme.font(size: 9, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, theme.z(3.5))
            .frame(minWidth: theme.z(13), minHeight: theme.z(13))
            .background(Capsule().fill(theme.accent))
            .accessibilityHidden(true)
    }
}

/// The context panel's Background section: the selected session's running subagents, shells and tasks, with Open and
/// Stop. Shown only while something runs.
struct BackgroundPanelSection: View {
    let store: SessionStore
    let session: SessionModel
    let items: [BackgroundWorkItem]
    var now: Date?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Background").foregroundStyle(theme.textPrimary)
                Spacer(minLength: theme.z(8))
                Text("\(items.count) running").foregroundStyle(theme.textSecondary).monospacedDigit()
            }
            .font(theme.font(size: 13))
            .frame(height: theme.z(30))
            ForEach(items) { item in
                BackgroundRow(store: store, item: item, now: now, compact: true, shownSessionID: session.id) { id in store.select(id) }
                    .padding(.horizontal, -theme.z(8))
            }
        }
        .padding(.top, theme.z(8))
        .padding(.bottom, theme.z(8))
    }
}

/// Runs an action on the main actor each time the Mac wakes from sleep.
@MainActor
final class WakeObserver {
    nonisolated(unsafe) private var token: (any NSObjectProtocol)?

    init(_ action: @escaping @MainActor @Sendable () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                  queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
