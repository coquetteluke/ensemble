import EnsembleKit
import SwiftUI

/// Standalone Rooms screen for compact width (outer Duo screen).
struct RoomsView: View {
    let client: RemoteClient
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void

    @State private var showNewRoom = false

    private var newRoomAccessibilityHint: String {
        if !client.state.isConnected { return "Connect to your Mac to create a room" }
        if client.availableModels.isEmpty { return "Loading available models from your Mac" }
        return "Create a new multi-agent room"
    }

    var body: some View {
        RoomsListContent(client: client, selectedSessionID: selectedSessionID, open: open)
            .navigationTitle("Rooms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNewRoom = true
                    } label: {
                        Image(systemName: "plus")
                            .font(RemoteTheme.font(size: 15, weight: .semibold, relativeTo: .body))
                            .foregroundStyle(RemoteTheme.accent)
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .disabled(!client.state.isConnected || client.availableModels.isEmpty)
                    .accessibilityLabel("New room")
                    .accessibilityHint(newRoomAccessibilityHint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(client: client, inToolbar: true)
                }
            }
            .sheet(isPresented: $showNewRoom) {
                RemoteNewRoomSheet(client: client) { room in
                    open(ChatRoute(sessionID: room.sessionID, title: room.title))
                }
                .remoteThemeEnvironment()
            }
    }
}

/// Reusable Rooms list used in both the compact tab and the unfolded split sidebar.
struct RoomsListContent: View {
    let client: RemoteClient
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void
    @State private var actionError: String?

    private var sorted: [RemoteRoom] {
        client.rooms.sorted { a, b in
            if a.needsYou != b.needsYou { return a.needsYou }
            return a.lastActivity > b.lastActivity
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: RemoteTheme.cardGap) {
                if !client.isInProcess && !client.state.isConnected {
                    HubConnectionBanner(client: client)
                }

                if client.rooms.isEmpty {
                    RoomsEmptyState()
                }

                ForEach(sorted) { room in
                    RoomCard(
                        room: room,
                        client: client,
                        selected: room.sessionID == selectedSessionID,
                        open: { open(ChatRoute(sessionID: room.sessionID, title: room.title)) },
                        onError: { actionError = $0 }
                    )
                }
            }
            .padding(.horizontal, RemoteTheme.screenHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .remoteScreen()
        .refreshable {
            if !client.state.isConnected && !client.isInProcess {
                client.reconnectNow()
            }
            try? await client.refreshRooms()
            try? await client.refreshHub()
        }
        .actionErrorAlert($actionError)
    }
}

private struct RoomsEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(RemoteTheme.tertiaryText)
            Text("No rooms")
                .font(RemoteTheme.font(size: 16, weight: .medium, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }
}

/// One room card in the Rooms list.
struct RoomCard: View {
    let room: RemoteRoom
    let client: RemoteClient
    var selected = false
    var open: () -> Void
    var onError: (String) -> Void

    private var prompts: [PermissionRequest] { client.pendingPermissions(inRoom: room.id) }
    private var decision: RemoteRoomDecision? { client.openDecision(inRoom: room.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                RoomCardHeader(room: room)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the room")

            if let goal = room.goal {
                RoomGoalStrip(goal: goal)
            }

            if !room.members.isEmpty {
                RoomMembersList(room: room)
            } else {
                RoomFallbackAgentsList(room: room)
            }

            if let reason = room.pauseReason, room.state == .paused {
                Label(reason, systemImage: "pause.circle")
                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
            }

            if decision != nil || !prompts.isEmpty {
                RoomAttentionBox(
                    decision: decision,
                    prompts: prompts,
                    agents: room.agents,
                    client: client,
                    open: open,
                    onError: onError
                )
            }

            RoomControls(room: room, client: client, onError: onError)
        }
        .remoteCard(selected: selected, attention: room.needsYou)
    }
}

private struct RoomCardHeader: View {
    let room: RemoteRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(room.title)
                    .font(RemoteTheme.font(size: 16, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(RemoteFormat.age(room.lastActivity))
                    .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(RemoteTheme.font(size: 11.5, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.tertiaryText)
            }

            FlowRow(spacing: 6, lineSpacing: 6) {
                Chip(text: room.mode.label, color: RemoteTheme.accent, symbol: roomModeSymbol)
                RoomStateChip(room: room)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(RemoteTheme.font(size: 10.5, relativeTo: .caption2))
                    Text(RemoteFormat.folderName(room.directory))
                }
                .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RemoteTheme.inlineCodeBackground, in: Capsule())

                if room.usage.costUSD > 0 {
                    Text(RemoteFormat.cost(room.usage.costUSD))
                        .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .padding(.vertical, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var roomModeSymbol: String {
        switch room.mode {
        case .solo: "person"
        case .team: "person.3"
        case .debate: "bubble.left.and.bubble.right"
        case .roundTable: "circle.hexagongrid"
        }
    }
}

private struct RoomFallbackAgentsList: View {
    let room: RemoteRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(room.agents) { agent in
                HStack(spacing: 8) {
                    AgentTag(agent: agent)
                    if agent.id == room.leadAgentID { Chip(text: "Lead") }
                    Spacer(minLength: 4)
                    AgentActivityIcon(agent: agent)
                    Text(RoomText.activity(agent))
                        .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(
                            agent.activity == .waitingForPermission ? RemoteTheme.warning : RemoteTheme.tertiaryText
                        )
                }
            }
        }
    }
}

private struct RoomAttentionBox: View {
    let decision: RemoteRoomDecision?
    let prompts: [PermissionRequest]
    let agents: [RemoteAgent]
    let client: RemoteClient
    let open: () -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let decision {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(decision.title)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: RoomText.symbol(decision.kind))
                    }
                    .font(RemoteTheme.font(size: 13.5, weight: .semibold, relativeTo: .footnote))
                    .foregroundStyle(decision.needsYou ? RemoteTheme.warning : RemoteTheme.primaryText)

                    Button(RoomText.openLabel(decision), action: open)
                        .buttonStyle(RemotePrimaryButtonStyle())
                }
            }

            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, request in
                if decision != nil || index > 0 {
                    Rectangle()
                        .fill(RemoteTheme.warning.opacity(0.22))
                        .frame(height: 1)
                }
                RoomPromptRow(
                    request: request,
                    agent: agents.first { $0.sessionID == request.sessionID },
                    client: client,
                    open: open,
                    onError: onError
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemoteTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(RemoteTheme.warning.opacity(0.4), lineWidth: 1)
        )
    }
}

#Preview("Rooms") {
    NavigationStack {
        RoomsView(client: .preview(.showcase()), open: { _ in })
    }
    .remoteThemeEnvironment()
}
