import EnsembleKit
import SwiftUI

/// Every room with its agents, state and Pause / Resume / Stop.
struct RoomsView: View {
    let client: RemoteClient
    var selectedSessionID: String?
    var open: (ChatRoute) -> Void
    @State private var actionError: String?

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
                    }
                    .padding(.top, 80)
                }
                ForEach(client.rooms.sorted { $0.lastActivity > $1.lastActivity }) { room in
                    card(room)
                }
            }
            .padding(16)
        }
        .remoteScreen()
        .navigationTitle("Rooms")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(client: client) } }
        .refreshable { try? await client.refreshRooms() }
        .actionErrorAlert($actionError)
    }

    private func card(_ room: RemoteRoom) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                open(ChatRoute(sessionID: room.sessionID, title: room.title))
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(RemoteTheme.primaryText)
                        Text("\(room.mode.label) · \(RemoteFormat.folderName(room.directory)) · \(RemoteFormat.cost(room.usage.costUSD))")
                            .font(.caption)
                            .foregroundStyle(RemoteTheme.secondaryText)
                    }
                    Spacer()
                    Chip(text: room.state.label, color: stateColor(room.state))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(room.agents) { agent in
                    HStack(spacing: 8) {
                        AgentTag(agent: agent)
                        if agent.id == room.leadAgentID {
                            Chip(text: "Lead")
                        }
                        Spacer()
                        Text(activityLabel(agent.activity))
                            .font(.caption)
                            .foregroundStyle(agent.activity == .waitingForPermission ? RemoteTheme.warning : RemoteTheme.tertiaryText)
                    }
                }
            }

            HStack(spacing: 8) {
                if room.state == .paused || room.state == .stopped {
                    Button { control(room, .resume) } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { control(room, .pause) } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(.bordered)
                }
                if room.state != .stopped {
                    Button(role: .destructive) { control(room, .stop) } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                        .tint(RemoteTheme.danger)
                }
            }
            .controlSize(.small)
        }
        .remoteCard(selected: room.sessionID == selectedSessionID)
    }

    private func stateColor(_ s: RemoteRoom.State) -> Color {
        switch s {
        case .running: RemoteTheme.success
        case .paused: RemoteTheme.warning
        case .stopped: RemoteTheme.danger
        case .idle: RemoteTheme.secondaryText
        }
    }

    private func activityLabel(_ a: SessionActivity) -> String {
        switch a {
        case .idle: "Idle"
        case .working: "Working"
        case .waitingForPermission: "Needs permission"
        case .failed: "Failed"
        }
    }

    private func control(_ room: RemoteRoom, _ action: RemoteRoomAction) {
        Task {
            do { try await client.controlRoom(room.id, action: action) } catch { actionError = error.localizedDescription }
        }
    }
}
