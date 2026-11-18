import SwiftUI
import EnsembleKit

/// "Rooms" section for the app sidebar: each room with its mode icon, agent colour dots, and a needs-you badge,
/// running spinner, paused icon or age. The header's + opens the new room sheet.
struct RoomsSidebarSection: View {
    let controller: RoomsController
    /// True while the window shows a room (so the selected row is highlighted).
    var isShowingRoom: Bool
    let onSelect: (UUID) -> Void
    var onNewRoom: () -> Void = {}

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var collapsed = false
    @State private var hovering = false
    @State private var deleting: RoomState?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(1)) {
            header
            if !collapsed {
                ForEach(controller.rooms) { room in
                    RoomSidebarRow(room: room,
                                   selected: isShowingRoom && controller.selectedRoomID == room.id,
                                   running: controller.isRunning(room.id),
                                   needsYou: controller.needsYouCount(room.id)) {
                        onSelect(room.id)
                    }
                    .contextMenu {
                        Button("Show folder in Finder") { revealInFinder(room.spec.directory) }
                        Divider()
                        Button("Delete room", role: .destructive) { deleting = room }
                    }
                }
                if controller.rooms.isEmpty {
                    Button(action: onNewRoom) {
                        HStack(spacing: theme.z(8)) {
                            Image(systemName: "plus").font(theme.font(size: 10, weight: .semibold))
                            Text("New room")
                        }
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, theme.z(30))
                        .frame(maxWidth: .infinity, minHeight: theme.z(28), alignment: .leading)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .confirmationDialog("Delete this room?", isPresented: deleteShown, presenting: deleting) { room in
            Button("Delete \"\(room.spec.title)\"", role: .destructive) {
                controller.delete(room.id)
                deleting = nil
            }
        } message: { _ in
            Text("The board and the room's settings are removed. The agents' sessions stay in the session list.")
        }
    }

    private var header: some View {
        HStack(spacing: theme.z(6)) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: theme.z(6)) {
                    Image(systemName: hovering ? (collapsed ? "chevron.right" : "chevron.down") : "person.3")
                        .font(theme.font(size: hovering ? 9 : 10.5, weight: hovering ? .bold : .regular))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(14))
                    Text("Rooms")
                        .font(theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering || isSnapshot {
                Button(action: onNewRoom) {
                    Image(systemName: "plus")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: theme.z(20), height: theme.z(20))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New room")
                .opacity(isSnapshot ? 0 : 1)
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(26))
        .onHover { hovering = $0 }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil && !isSnapshot }, set: { if !$0 { deleting = nil } })
    }
}

/// One room in the sidebar.
struct RoomSidebarRow: View {
    let room: RoomState
    let selected: Bool
    let running: Bool
    let needsYou: Int
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: room.spec.mode.symbolName)
                    .font(theme.font(size: 10.5))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textTertiary)
                    .frame(width: theme.z(16))
                Text(room.spec.title)
                    .font(theme.font(size: 13))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSidebar)
                    .lineLimit(1)
                AgentDots(colors: room.spec.agents.map(\.colorHex), size: 7, ring: selected ? theme.selection : theme.sidebar)
                Spacer(minLength: 6)
                trailing
            }
            .padding(.leading, theme.z(12))
            .padding(.trailing, theme.z(10))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var trailing: some View {
        if needsYou > 0 {
            CountBadge(needsYou)
        } else if running {
            Spinner(size: 11)
        } else if room.isPaused || room.phase.isRunning {
            Image(systemName: "pause.circle")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .help("Paused")
        } else {
            Text(Format.relative(room.board.last?.date ?? room.spec.created))
                .font(theme.font(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var accessibilityText: String {
        var parts = [room.spec.title, room.spec.mode.label]
        if needsYou > 0 { parts.append("\(needsYou) waiting for you") }
        if running { parts.append("running") }
        return parts.joined(separator: ", ")
    }
}
