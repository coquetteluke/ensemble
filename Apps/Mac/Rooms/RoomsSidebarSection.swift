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
    @State private var newHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(1)) {
            SidebarSectionHeader(title: "Rooms", collapsed: collapsed, onToggle: onToggle) {
                Button(action: onNewRoom) {
                    Image(systemName: "plus")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(newHovering ? theme.textPrimary : theme.textTertiary)
                        .frame(width: theme.z(20), height: theme.z(20))
                        .background(
                            RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                                .fill(newHovering ? theme.hover : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { newHovering = $0 }
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
                                .font(theme.font(size: 9.5, weight: .bold))
                                .foregroundStyle(theme.accent)
                                .frame(width: theme.z(16), height: theme.z(16))
                                .background(Circle().fill(theme.accent.opacity(theme.isDark ? 0.16 : 0.12)))
                            Text("New room")
                                .font(theme.font(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, theme.z(9))
                        .frame(maxWidth: .infinity, minHeight: theme.z(30), alignment: .leading)
                    }
                    .buttonStyle(RowButtonStyle(cornerRadius: theme.z(7)))
                    .help("Create a room for multiple agents (Shift-Command-N)")
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
    @State private var hovering = false

    var body: some View {
        let dotRing = selected ? theme.selection : (hovering ? theme.hover : theme.sidebar)
        let agents = room.spec.agents
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
                if !agents.isEmpty {
                    HStack(spacing: theme.z(3)) {
                        AgentDots(colors: agents.map(\.colorHex), size: 7, maxCount: 4, ring: dotRing)
                        if agents.count > 4 {
                            Text("+\(agents.count - 4)")
                                .font(theme.font(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .fixedSize()
                }
                Spacer(minLength: theme.z(6))
                trailing
                    .fixedSize()
            }
            .padding(.leading, theme.z(10))
            .padding(.trailing, theme.z(10))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: theme.z(7)))
        .onHover { hovering = $0 }
        .help(helpText)
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
                .lineLimit(1)
        }
    }

    private var helpText: String {
        let count = room.spec.agents.count
        let noun = count == 1 ? "agent" : "agents"
        return "\(room.spec.title) (\(room.spec.mode.label), \(count) \(noun)) \u{00B7} \(Format.abbreviatedPath(room.spec.directory))"
    }

    private var accessibilityText: String {
        var parts = [room.spec.title, room.spec.mode.label]
        if needsYou > 0 { parts.append("\(needsYou) waiting for you") }
        if running { parts.append("running") }
        return parts.joined(separator: ", ")
    }
}
