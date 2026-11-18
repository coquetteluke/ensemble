import SwiftUI
import EnsembleKit

/// One scheduled task: name, prompt, when, where and how it runs, next and last run, its folder's trust state, the
/// actions, and its history.
struct ScheduleTaskCard: View {
    let store: SessionStore
    let scheduler: TaskScheduler
    let task: ScheduledTask
    let now: Date
    let trustLine: NewSessionTrustLine?
    @Binding var expanded: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenSession: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var showAll = false

    /// History rows shown before "Show all".
    static let historyPreview = 6

    var body: some View {
        let runs = scheduler.runs(for: task.id)
        let active = scheduler.hasActiveRun(task.id)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: theme.z(8)) {
                titleRow(active: active)
                Text(task.prompt)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                facts
                timing(last: runs.first)
                if let trustLine {
                    ScheduleTrustLine(line: trustLine)
                }
            }
            .padding(theme.z(14))

            HLine(color: theme.border)
            historyToggle(count: runs.count)
            if expanded {
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    if runs.isEmpty {
                        Text("No runs yet")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, theme.z(14))
                            .padding(.vertical, theme.z(8))
                    }
                    ForEach(showAll ? runs : Array(runs.prefix(Self.historyPreview))) { run in
                        ScheduleRunRow(store: store, run: run, now: now, onOpen: onOpenSession)
                    }
                    if runs.count > Self.historyPreview, !showAll {
                        Button("Show all \(runs.count)") { showAll = true }
                            .buttonStyle(.plain)
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, theme.z(14))
                            .padding(.vertical, theme.z(6))
                    }
                }
                .padding(.horizontal, theme.z(4))
                .padding(.bottom, theme.z(8))
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
    }

    private func titleRow(active: Bool) -> some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: task.paused ? "pause.circle" : "clock")
                .font(theme.font(size: 13.5))
                .foregroundStyle(task.paused ? theme.textTertiary : theme.accent)
            Text(task.name.isEmpty ? "Untitled task" : task.name)
                .font(theme.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if task.paused { SchedulePill(text: "Paused") }
            Spacer(minLength: theme.z(8))
            Button {
                Task { await scheduler.runNow(task.id) }
            } label: {
                Label("Run now", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(active || !store.isLoaded)
            .help(active ? "A run of this task is still going" : "Run this task now")
            IconButton(task.paused ? "play.circle" : "pause.circle", help: task.paused ? "Resume" : "Pause", size: 28) {
                scheduler.setPaused(!task.paused, taskID: task.id)
            }
            IconButton("pencil", help: "Edit", size: 28, action: onEdit)
            IconButton("trash", help: "Delete", size: 28, action: onDelete)
        }
    }

    /// When, where, which model and which mode.
    private var facts: some View {
        HStack(spacing: theme.z(6)) {
            fact("calendar", task.trigger.summary())
            dot
            if let sessionID = task.continueSessionID {
                fact("arrow.turn.down.right", "Continues \u{201C}\(store.session(sessionID)?.title ?? "a deleted session")\u{201D}")
            } else {
                fact("folder", Format.folderName(task.directory))
                dot
                fact("cpu", store.modelName(task.model))
            }
            dot
            Label(task.permissionMode.shortLabel, systemImage: task.permissionMode.symbolName)
                .labelStyle(ScheduleFactLabelStyle())
                .foregroundStyle(task.permissionMode.isDangerous ? theme.danger : theme.textSecondary)
        }
        .font(theme.font(size: 12))
        .lineLimit(1)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(ScheduleFactLabelStyle())
            .foregroundStyle(theme.textSecondary)
    }

    private var dot: some View {
        Text("\u{00B7}").foregroundStyle(theme.textTertiary)
    }

    private func timing(last: ScheduleRun?) -> some View {
        HStack(spacing: theme.z(24)) {
            HStack(spacing: theme.z(6)) {
                Text("Next")
                    .foregroundStyle(theme.textTertiary)
                Text(nextText)
                    .foregroundStyle(task.paused ? theme.textTertiary : theme.textPrimary)
            }
            HStack(spacing: theme.z(6)) {
                Text("Last")
                    .foregroundStyle(theme.textTertiary)
                if let last {
                    ScheduleStatusIcon(status: last.status)
                    Text(last.status.label)
                        .foregroundStyle(ScheduleStatusIcon.color(last.status, theme))
                    Text(ScheduleFormat.when(last.started, now: now))
                        .foregroundStyle(theme.textSecondary)
                    if last.reason == .caughtUp { SchedulePill(text: "Caught up") }
                } else {
                    Text("Never").foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(theme.font(size: 12))
        .lineLimit(1)
    }

    private var nextText: String {
        if task.paused { return "Paused" }
        guard let next = scheduler.nextRun(for: task) else { return "Never" }
        return ScheduleFormat.when(next, now: now)
    }

    private func historyToggle(count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: theme.z(6)) {
                Image(systemName: "chevron.right")
                    .font(theme.font(size: 9.5, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("History")
                    .font(theme.font(size: 12, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(34))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One run in a task's history: outcome, when, how long, why (for failures, skips and misses), and Open.
struct ScheduleRunRow: View {
    let store: SessionStore
    let run: ScheduleRun
    let now: Date
    let onOpen: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let session = run.sessionID.flatMap { store.session($0) }
        Button {
            if let session { onOpen(session.id) }
        } label: {
            HStack(alignment: .top, spacing: theme.z(10)) {
                ScheduleStatusIcon(status: run.status)
                    .frame(height: theme.z(17))
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    HStack(spacing: theme.z(8)) {
                        Text(run.status.label)
                            .font(theme.font(size: 12.5, weight: .medium))
                            .foregroundStyle(ScheduleStatusIcon.color(run.status, theme))
                        if run.reason == .caughtUp { SchedulePill(text: "Caught up") }
                        if run.reason == .manual { SchedulePill(text: "Run now") }
                        Text(ScheduleFormat.when(run.scheduledFor ?? run.started, now: now))
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                        if let duration = run.duration, run.status == .succeeded || run.status == .failed {
                            Text(ScheduleFormat.duration(duration))
                                .font(theme.font(size: 12).monospacedDigit())
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: theme.z(8))
                if session != nil {
                    HStack(spacing: theme.z(3)) {
                        Text("Open")
                        Image(systemName: "arrow.up.right")
                            .font(theme.font(size: 9.5, weight: .semibold))
                    }
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(height: theme.z(17))
                }
            }
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(7))
        }
        .buttonStyle(RowButtonStyle())
        .disabled(session == nil)
        .help(session.map { "Open \u{201C}\($0.title)\u{201D}" } ?? "")
    }

    /// The reason for failures, skips and misses; otherwise the session's title, or when a caught-up run started.
    private var detail: String? {
        if let message = run.message, !message.isEmpty { return message }
        var parts: [String] = []
        if run.reason == .caughtUp, let due = run.scheduledFor {
            parts.append("Due \(ScheduleFormat.when(due, now: now)), ran \(ScheduleFormat.when(run.started, now: now))")
        }
        if let title = run.sessionTitle ?? run.sessionID.flatMap({ store.session($0)?.title }) { parts.append(title) }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }
}

/// The outcome's icon and colour.
struct ScheduleStatusIcon: View {
    let status: ScheduleRunStatus
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if status == .running {
                Spinner(size: 11, color: theme.accent)
            } else {
                Image(systemName: Self.symbol(status))
                    .font(theme.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(Self.color(status, theme))
            }
        }
        .frame(width: theme.z(14))
    }

    static func symbol(_ status: ScheduleRunStatus) -> String {
        switch status {
        case .running: "circle.dotted"
        case .needsYou: "hand.raised.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "forward.end.circle"
        case .missed: "moon.zzz"
        case .unknown: "questionmark.circle"
        }
    }

    static func color(_ status: ScheduleRunStatus, _ theme: Theme) -> Color {
        switch status {
        case .running: theme.accent
        case .needsYou: theme.warning
        case .succeeded: theme.success
        case .failed: theme.danger
        case .skipped, .missed, .unknown: theme.textSecondary
        }
    }
}

/// A small grey tag ("Paused", "Caught up", "Run now").
struct SchedulePill: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 10.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, theme.z(6))
            .frame(height: theme.z(17))
            .background(Capsule().fill(theme.track))
    }
}

/// The task's folder trust state, when the folder is not trusted.
struct ScheduleTrustLine: View {
    let line: NewSessionTrustLine
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.z(6)) {
            Image(systemName: line.tone == .blocked ? "exclamationmark.shield" : "lock.shield")
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(line.tone == .blocked ? theme.warning : theme.textTertiary)
            Text(line.tone == .blocked ? line.text + " Its runs will fail until you trust the folder." : line.text)
                .font(theme.font(size: 11.5))
                .foregroundStyle(line.tone == .blocked ? theme.warning : theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Icon and text close together, for the facts row.
struct ScheduleFactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        FactLabel(configuration: configuration)
    }

    private struct FactLabel: View {
        let configuration: LabelStyleConfiguration
        @Environment(\.theme) private var theme

        var body: some View {
            HStack(spacing: theme.z(4)) {
                configuration.icon
                    .font(theme.font(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                configuration.title
            }
        }
    }
}
