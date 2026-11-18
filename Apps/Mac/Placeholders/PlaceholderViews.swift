import SwiftUI
import EnsembleKit

// Stand-ins until the Hub (WP-E) and Schedules (WP-G) work packages fill Apps/Mac/Hub and Apps/Mac/Schedules.

/// Session Hub placeholder: lists sessions that are waiting on you.
struct HubPlaceholderView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        let waiting = store.sessions.filter { !$0.pendingPermissions.isEmpty }
        AdaptiveScroll(.vertical) {
            VStack(alignment: .leading, spacing: theme.z(10)) {
                Text("Needs you")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                if waiting.isEmpty {
                    Text("Nothing is waiting on you.")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                ForEach(waiting) { session in
                    Button {
                        window.open(session.id, store: store)
                    } label: {
                        HStack(spacing: theme.z(10)) {
                            CountBadge(session.pendingPermissions.count)
                            VStack(alignment: .leading, spacing: theme.z(2)) {
                                Text(session.title)
                                    .font(theme.font(size: 13, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                Text(session.pendingPermissions.first.map(MacRemoteHost.askText) ?? "")
                                    .font(theme.font(size: 12, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(Format.folderName(session.directory))
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(theme.z(12))
                        .background(RoundedRectangle(cornerRadius: theme.z(10)).fill(theme.elevated))
                        .overlay(RoundedRectangle(cornerRadius: theme.z(10)).strokeBorder(theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: theme.z(720), alignment: .leading)
            .padding(theme.z(28))
            .frame(maxWidth: .infinity)
        }
    }
}

/// Scheduled placeholder: lists the engine's schedules.
struct ScheduledPlaceholderView: View {
    let store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        AdaptiveScroll(.vertical) {
            VStack(alignment: .leading, spacing: theme.z(10)) {
                if store.schedules.isEmpty {
                    Text("No scheduled tasks.")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                ForEach(store.schedules) { schedule in
                    HStack(spacing: theme.z(12)) {
                        Image(systemName: schedule.paused ? "pause.circle" : "clock")
                            .foregroundStyle(schedule.paused ? theme.textTertiary : theme.accent)
                        VStack(alignment: .leading, spacing: theme.z(2)) {
                            Text(schedule.title)
                                .font(theme.font(size: 13, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                            Text(schedule.prompt)
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(schedule.schedule)
                            .font(theme.font(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                        Text(schedule.paused ? "Paused" : "Active")
                            .font(theme.font(size: 12))
                            .foregroundStyle(schedule.paused ? theme.textTertiary : theme.success)
                    }
                    .padding(theme.z(12))
                    .background(RoundedRectangle(cornerRadius: theme.z(10)).fill(theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(10)).strokeBorder(theme.border))
                }
            }
            .frame(maxWidth: theme.z(720), alignment: .leading)
            .padding(theme.z(28))
            .frame(maxWidth: .infinity)
        }
    }
}
