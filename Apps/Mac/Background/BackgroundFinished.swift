import SwiftUI
import EnsembleKit

/// Background work that ended while Ensemble was open, for the Background list's Finished group. The engines only
/// report what runs now; this keeps the rest (`BackgroundHistory`), in memory.
@Observable @MainActor
final class BackgroundHistoryCenter {
    static let shared = BackgroundHistoryCenter()
    private(set) var history = BackgroundHistory()

    /// Call whenever the set of running rows changes.
    func sync(_ store: SessionStore, at date: Date = Date()) {
        history.update(running: store.backgroundItems, at: date)
    }

    func clearFinished() {
        history.clearFinished()
    }
}

/// The Finished group: what ended, how long it ran, Open for its session, and Clear for the whole group.
struct BackgroundFinishedSection: View {
    let store: SessionStore
    let finished: [FinishedBackgroundItem]
    let onOpen: (String) -> Void
    let onClear: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(6)) {
                Text("Finished")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("\(finished.count)")
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .help("Clear the finished rows")
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(26))
            ForEach(finished) { entry in
                BackgroundFinishedRow(entry: entry,
                                      canOpen: entry.item.openSessionID.map { store.session($0) != nil } ?? false,
                                      onOpen: onOpen)
                    .padding(.horizontal, theme.z(6))
            }
        }
    }
}

/// One finished row: icon, title, what it was, how long it ran, Open.
struct BackgroundFinishedRow: View {
    let entry: FinishedBackgroundItem
    let canOpen: Bool
    let onOpen: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: BackgroundRow.symbol(entry.item.kind))
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(16))
            VStack(alignment: .leading, spacing: theme.z(1)) {
                Text(entry.item.title)
                    .font(entry.item.kind == .shell ? theme.font(size: 12, design: .monospaced) : theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Text(kindText)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .help(entry.item.title)
            Spacer(minLength: theme.z(6))
            if let duration = entry.duration {
                Text(BackgroundHistory.durationText(duration))
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .help("Ran for \(BackgroundHistory.durationText(duration))")
            }
            if canOpen, let sessionID = entry.item.openSessionID {
                IconButton("arrow.up.forward.app", help: entry.item.kind == .subagent ? "Open this subagent" : "Open the session that started it",
                           size: 22) {
                    onOpen(sessionID)
                }
            } else {
                Color.clear.frame(width: theme.z(22), height: theme.z(22))
            }
        }
        .padding(.horizontal, theme.z(8))
        .frame(minHeight: theme.z(38))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering ? theme.raisedHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var kindText: String {
        switch entry.item.kind {
        case .subagent: entry.item.detail.map { "Subagent \u{00B7} \($0)" } ?? "Subagent"
        case .shell: "Background command"
        case .task, .schedule: "Background task"
        }
    }
}
