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
    /// Snapshots preset the search text.
    var initialQuery = ""

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var editor: ScheduleEditorRequest?
    @State private var expanded: Set<UUID>?
    @State private var deleting: ScheduledTask?
    @State private var typedQuery: String?
    @AppStorage("scheduleSort") private var sortRaw = ScheduleListing.Sort.created.rawValue

    private var query: String { typedQuery ?? initialQuery }
    private var sort: ScheduleListing.Sort { ScheduleListing.Sort(rawValue: sortRaw) ?? .created }

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
                    let shown = ScheduleListing.sorted(ScheduleListing.filter(scheduler.tasks, query: query), by: sort) {
                        scheduler.nextRun(for: $0)
                    }
                    listTools(shown: shown.count, total: scheduler.tasks.count)
                    if shown.isEmpty {
                        Text("No tasks match \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                            .font(theme.font(size: 13))
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, theme.z(28))
                    }
                    ForEach(shown) { task in
                        ScheduleTaskCard(store: store, scheduler: scheduler, task: task, now: now,
                                         trustLine: trustLine(for: task), expanded: expandedBinding(task.id),
                                         onEdit: { editor = ScheduleEditorRequest(task: task, isNew: false) },
                                         onDelete: { deleting = task },
                                         onOpenSession: { window.open($0, store: store) })
                    }
                }
                if !store.schedules.isEmpty { EngineSchedulesSection(schedules: store.schedules) }
                ScheduleTemplatesSection(templates: ScheduleTemplates.all, enabled: store.isLoaded) { template in
                    let directory = store.selected?.directory ?? store.projects.first?.directory ?? ""
                    editor = ScheduleEditorRequest(task: template.task(directory: directory, model: store.defaultModel), isNew: true)
                }
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

    /// Above the list: a search field over names, prompts and folders, and the order.
    private func listTools(shown: Int, total: Int) -> some View {
        HStack(spacing: theme.z(10)) {
            HStack(spacing: theme.z(7)) {
                Image(systemName: "magnifyingglass")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                if isSnapshot {
                    Text(query.isEmpty ? "Search tasks" : query)
                        .foregroundStyle(query.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: Binding(get: { query }, set: { typedQuery = $0 }),
                              prompt: Text("Search tasks").foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .autocorrectionDisabled()
                }
            }
            .font(theme.font(size: 12.5))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(28))
            .frame(maxWidth: theme.z(260))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
            if shown != total {
                Text("\(shown) of \(total)")
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: theme.z(8))
            if isSnapshot {
                sortLabel
            } else {
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(ScheduleListing.Sort.allCases) { sort in
                            Text(sort.label).tag(sort.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    sortLabel
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Order of the list")
            }
        }
    }

    private var sortLabel: some View {
        HStack(spacing: theme.z(5)) {
            Image(systemName: "arrow.up.arrow.down")
                .font(theme.font(size: 10.5))
            Text(sort.label)
                .font(theme.font(size: 12))
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, theme.z(8))
        .frame(height: theme.z(26))
        .contentShape(Rectangle())
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

/// Ready-made tasks under the list. Picking one opens the editor filled in; nothing is saved until Save.
struct ScheduleTemplatesSection: View {
    let templates: [ScheduleTemplate]
    let enabled: Bool
    let onPick: (ScheduleTemplate) -> Void
    @Environment(\.theme) private var theme

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: theme.z(10), alignment: .top), GridItem(.flexible(), spacing: theme.z(10), alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            Text("Start from a template")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.top, theme.z(14))
            LazyVGrid(columns: columns, alignment: .leading, spacing: theme.z(10)) {
                ForEach(templates) { template in
                    ScheduleTemplateCard(template: template) { onPick(template) }
                        .disabled(!enabled)
                }
            }
        }
    }
}

/// One template: symbol, name, what it does, and when it runs.
private struct ScheduleTemplateCard: View {
    let template: ScheduleTemplate
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: theme.z(11)) {
                Image(systemName: template.symbol)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: theme.z(30), height: theme.z(30))
                    .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    Text(template.name)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(template.summary)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: theme.z(5)) {
                        Image(systemName: "clock")
                            .font(theme.font(size: 10.5))
                        Text(template.trigger.summary())
                            .font(theme.font(size: 11.5))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, theme.z(1))
                }
                Spacer(minLength: 0)
            }
            .padding(theme.z(11))
            // One height for every card, so the grid's rows line up even when a summary wraps.
            .frame(maxWidth: .infinity, minHeight: theme.z(84), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(hovering ? theme.elevated.opacity(0.7) : theme.elevated.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open a new task with this filled in")
        .accessibilityLabel("\(template.name). \(template.summary)")
    }
}
