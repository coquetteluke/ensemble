import SwiftUI
import EnsembleKit

/// "Rooms" section for the app sidebar, styled like its Pinned and Sessions sections: each room with its mode icon,
/// agent colour dots, and a needs-you badge, running spinner, paused icon or age. The header collapses the section
/// and its + opens the new room sheet.
struct RoomsSidebarSection: View {
    let controller: RoomsController
    /// The sidebar's search text: only rooms whose title, folder or agent names match are listed.
    var search = ""
    /// True while the window shows a room (so the selected row is highlighted).
    var isShowingRoom: Bool
    let onSelect: (UUID) -> Void
    var onNewRoom: () -> Void = {}
    var collapsed = false
    var onToggle: () -> Void = {}

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var deleting: RoomState?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(1)) {
            SidebarSectionHeader(title: "Rooms", collapsed: collapsed, onToggle: onToggle) {
                Button(action: onNewRoom) {
                    Image(systemName: "plus")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(20), height: theme.z(20))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New room (Shift-Command-N)")
                .accessibilityLabel("New room")
            }
            if !collapsed {
                ForEach(Self.matching(controller.rooms, search)) { room in
                    RoomSidebarRow(room: room,
                                   selected: isShowingRoom && controller.selectedRoomID == room.id,
                                   running: controller.isRunning(room.id),
                                   needsYou: controller.needsYouCount(room.id)) {
                        onSelect(room.id)
                    }
                    .contextMenu {
                        Button("Show Folder in Finder") { revealInFinder(room.spec.directory) }
                        Divider()
                        PowerMenuItems(holder: .room(room.id))
                        Divider()
                        Button("Delete Room", role: .destructive) { deleting = room }
                    }
                }
                if controller.rooms.isEmpty && search.isEmpty {
                    Button(action: onNewRoom) {
                        HStack(spacing: theme.z(6)) {
                            Image(systemName: "plus")
                                .font(theme.font(size: 10, weight: .semibold))
                                .frame(width: theme.z(14))
                            Text("New room")
                        }
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, theme.z(10))
                        .frame(maxWidth: .infinity, minHeight: theme.z(30), alignment: .leading)
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

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil && !isSnapshot }, set: { if !$0 { deleting = nil } })
    }

    /// Rooms whose title, folder name or an agent's name contains `search` (all of them when it is empty).
    static func matching(_ rooms: [RoomState], _ search: String) -> [RoomState] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rooms }
        return rooms.filter { room in
            ([room.spec.title, Format.folderName(room.spec.directory)] + room.spec.agents.map(\.name))
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
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
            HStack(spacing: theme.z(6)) {
                // The icon column lines the title up with session titles in the sections below.
                Image(systemName: room.spec.mode.symbolName)
                    .font(theme.font(size: 10.5))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textTertiary)
                    .frame(width: theme.z(14))
                Text(room.spec.title)
                    .font(theme.font(size: 13))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSidebar)
                    .lineLimit(1)
                    .padding(.trailing, theme.z(2))
                AgentDots(colors: room.spec.agents.map(\.colorHex), size: 7, ring: selected ? theme.selection : theme.sidebar)
                Spacer(minLength: theme.z(6))
                trailing
            }
            .padding(.leading, theme.z(10))
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
                .frame(width: theme.z(17))
        } else if room.isPaused || room.phase.isRunning {
            Image(systemName: "pause.circle")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(17))
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
