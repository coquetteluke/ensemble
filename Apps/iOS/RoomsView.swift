import EnsembleKit
import SwiftUI

/// Every room: its agents with their colours and what they do, its state, what it waits on you for (a decision, or
/// permission prompts from its agents), and Pause, Resume and Stop. Rooms that need you come first.
struct RoomsView: View {
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
            LazyVStack(spacing: 10) {
                if client.rooms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.3")
                            .font(.largeTitle)
                            .foregroundStyle(RemoteTheme.tertiaryText)
                        Text("No rooms")
                            .font(.headline)
                            .foregroundStyle(RemoteTheme.secondaryText)
                        Text("Start a room on your Mac to see it here.")
                            .font(.footnote)
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 80)
                }
                ForEach(sorted) { room in
                    RoomCard(room: room, client: client, selected: room.sessionID == selectedSessionID,
                             open: { open(ChatRoute(sessionID: room.sessionID, title: room.title)) },
                             onError: { actionError = $0 })
                }
            }
            .padding(16)
        }
        .remoteScreen()
        .navigationTitle("Rooms")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(client: client) } }
        .refreshable {
            try? await client.refreshRooms()
            try? await client.refreshHub()
        }
        .actionErrorAlert($actionError)
    }
}

/// One room in the Rooms list.
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(room.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(RemoteTheme.primaryText)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                    Text("\(room.mode.label) · \(RemoteFormat.folderName(room.directory)) · \(RemoteFormat.cost(room.usage.costUSD))")
                        .font(.caption)
                        .foregroundStyle(RemoteTheme.secondaryText)
                    RoomStateChip(room: room)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the room")

            if let goal = room.goal {
                RoomGoalStrip(goal: goal)
            }

            if !room.members.isEmpty {
                RoomMembersList(room: room)
            } else {
                agentRows
            }

            if let reason = room.pauseReason, room.state == .paused {
                Label(reason, systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.secondaryText)
            }

            if decision != nil || !prompts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if let decision {
                        VStack(alignment: .leading, spacing: 8) {
                            Label {
                                Text(decision.title).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: RoomText.symbol(decision.kind))
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(decision.needsYou ? RemoteTheme.warning : RemoteTheme.primaryText)
                            Button(RoomText.openLabel(decision), action: open)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                    ForEach(prompts) { request in
                        RoomPromptRow(request: request, agent: room.agents.first { $0.sessionID == request.sessionID },
                                      client: client, open: open, onError: onError)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RemoteTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            RoomControls(room: room, client: client, onError: onError)
        }
        .remoteCard(selected: selected)
    }

    /// Each agent and what it does, for a Mac that sends no Members list.
    private var agentRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(room.agents) { agent in
                HStack(spacing: 8) {
                    AgentTag(agent: agent)
                    if agent.id == room.leadAgentID { Chip(text: "Lead") }
                    Spacer(minLength: 4)
                    AgentActivityIcon(agent: agent)
                    Text(RoomText.activity(agent))
                        .font(.caption)
                        .foregroundStyle(agent.activity == .waitingForPermission ? RemoteTheme.warning : RemoteTheme.tertiaryText)
                }
            }
        }
    }
}

#Preview("Rooms") {
    NavigationStack {
        RoomsView(client: .preview(.showcase()), open: { _ in })
    }
    .preferredColorScheme(.dark)
}
