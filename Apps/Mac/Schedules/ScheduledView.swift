import SwiftUI
import EnsembleKit

/// The Scheduled screen: every scheduled task with its next run, last run and outcome, Run now, Pause or Resume, Edit,
/// Delete, and each task's history. Ensemble runs the tasks itself, on any engine, while it is open.
struct ScheduledView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    /// Snapshots pass their own scheduler; the app uses `ScheduleCenter`'s.
    var scheduler: TaskScheduler?
    /// Snapshots pass a fixed time; the app uses the clock.
    var now: Date?
    /// Snapshots open some histories; the app starts with all closed.
    var initiallyExpanded: Set<UUID> = []
    /// Snapshots pass fixed trust lines; the app asks the store.
    var trustLines: [UUID: NewSessionTrustLine]?

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var editor: ScheduleEditorRequest?
    @State private var expanded: Set<UUID>?
    @State private var deleting: ScheduledTask?

    var body: some View {
        if let scheduler = scheduler ?? ScheduleCenter.shared.scheduler {
            TimelineView(.everyMinute) { context in
                content(scheduler, now: now ?? context.date)
            }
            .sheet(item: $editor) { request in
                ScheduleEditorSheet(store: store, request: request) { task in
                    if request.isNew { scheduler.add(task) } else { scheduler.update(task) }
                }
                .ensembleTheme()
            }
            .alert(deleteTitle, isPresented: deleteShown, presenting: deleting) { task in
                Button("Delete", role: .destructive) { scheduler.delete(task.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its history is deleted too. Sessions it started stay.")
            }
        } else {
            VStack(spacing: theme.z(10)) {
                Spinner(size: 14)
                Text("Loading scheduled tasks")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ scheduler: TaskScheduler, now: Date) -> some View {
        AdaptiveScroll(.vertical) {
            VStack(alignment: .leading, spacing: theme.z(12)) {
                header(scheduler)
                if let error = scheduler.lastError {
                    Text(error)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if scheduler.tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(scheduler.tasks) { task in
                        ScheduleTaskCard(store: store, scheduler: scheduler, task: task, now: now,
                                         trustLine: trustLine(for: task), expanded: expandedBinding(task.id),
                                         onEdit: { editor = ScheduleEditorRequest(task: task, isNew: false) },
                                         onDelete: { deleting = task },
                                         onOpenSession: { window.open($0, store: store) })
                    }
                }
                if !store.schedules.isEmpty { EngineSchedulesSection(schedules: store.schedules) }
            }
            .frame(maxWidth: theme.z(760), alignment: .leading)
            .padding(.horizontal, theme.z(28))
            .padding(.top, theme.z(16))
            .padding(.bottom, theme.z(28))
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ scheduler: TaskScheduler) -> some View {
        HStack(alignment: .top, spacing: theme.z(16)) {
            Text("Tasks run while Ensemble is open. A run missed while the Mac sleeps or Ensemble is closed runs once when "
                 + "it is back, if it was due within the task's catch-up window.")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editor = ScheduleEditorRequest(task: newTask(), isNew: true)
            } label: {
                Label("New task", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!store.isLoaded)
        }
    }

    private var emptyState: some View {
        VStack(spacing: theme.z(10)) {
            Image(systemName: "clock")
                .font(theme.font(size: 26, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("No scheduled tasks")
                .font(theme.font(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Text("A task sends a prompt to an agent on a schedule, in a new session or one you choose.")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, theme.z(48))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    /// A new task in the folder on screen (or the most recent one), with the default model and Ask.
    private func newTask() -> ScheduledTask {
        let directory = store.selected?.directory ?? store.projects.first?.directory ?? ""
        return ScheduledTask(name: "", prompt: "", directory: directory, model: store.defaultModel, permissionMode: .ask)
    }

    private func trustLine(for task: ScheduledTask) -> NewSessionTrustLine? {
        if let trustLines { return trustLines[task.id] }
        let directory = task.continueSessionID.flatMap { store.session($0)?.directory } ?? task.directory
        let model = task.continueSessionID.flatMap { store.session($0)?.info.model } ?? task.model
        guard let line = store.newSessionTrustLine(directory: directory, model: model), line.tone != .trusted else { return nil }
        return line
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { (expanded ?? initiallyExpanded).contains(id) },
                set: { open in
                    var set = expanded ?? initiallyExpanded
                    if open { set.insert(id) } else { set.remove(id) }
                    expanded = set
                })
    }

    private var deleteTitle: String {
        guard let deleting else { return "Delete this task?" }
        let name = deleting.name.isEmpty ? "this task" : "\u{201C}\(deleting.name)\u{201D}"
        return "Delete \(name)?"
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil && !isSnapshot }, set: { if !$0 { deleting = nil } })
    }
}

/// OpenCode's own schedules (made outside Ensemble), listed so they are not invisible. Ensemble's tasks are above.
private struct EngineSchedulesSection: View {
    let schedules: [ScheduleInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text("OpenCode schedules")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.top, theme.z(12))
            ForEach(schedules) { schedule in
                HStack(spacing: theme.z(10)) {
                    Image(systemName: schedule.paused ? "pause.circle" : "clock")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                    Text(schedule.title)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(Format.folderName(schedule.directory))
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                    Spacer(minLength: theme.z(8))
                    Text(schedule.schedule)
                        .font(theme.font(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                    Text(schedule.paused ? "Paused" : "Active")
                        .font(theme.font(size: 12))
                        .foregroundStyle(schedule.paused ? theme.textTertiary : theme.success)
                }
                .padding(.horizontal, theme.z(12))
                .frame(height: theme.z(34))
                .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated.opacity(0.6)))
            }
        }
    }
}
