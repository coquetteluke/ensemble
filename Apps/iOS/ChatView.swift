import EnsembleKit
import SwiftUI

/// One session or room chat: transcript, floating composer card, permission mode, and room controls.
struct ChatView: View {
    let client: RemoteClient
    let sessionID: String
    let title: String

    @Environment(RemoteAppModel.self) private var model
    @State private var sending = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var confirmStop = false
    @State private var showMembers = false
    /// Where the reader was when this view appeared (nil: the end).
    @State private var startAnchor: String??
    @FocusState private var composerFocused: Bool

    private var transcript: RemoteTranscript? {
        client.openTranscript?.sessionID == sessionID ? client.openTranscript : nil
    }

    private var summary: SessionSummary? { client.sessions.first { $0.id == sessionID } }
    private var roomID: UUID? { transcript?.roomID ?? summary?.roomID }
    private var room: RemoteRoom? { client.room(id: roomID) }
    private var target: RemoteTarget { roomID.map { .room($0) } ?? .session(sessionID) }
    private var activity: SessionActivity { transcript?.activity ?? summary?.activity ?? .idle }
    private var currentMode: PermissionMode? { transcript?.permissionMode ?? room?.permissionMode }
    private var agents: [UUID: RemoteAgent] {
        Dictionary((transcript?.agents ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // Kept in RemoteAppModel so drafts, addressees, and scroll position survive Duo fold/unfold transitions.
    private var draft: Binding<String> {
        Binding(
            get: { model.drafts[sessionID] ?? "" },
            set: { model.drafts[sessionID] = $0.isEmpty ? nil : $0 }
        )
    }

    private var addressee: Binding<String?> {
        Binding(
            get: { model.addressees[sessionID] },
            set: { model.addressees[sessionID] = $0 }
        )
    }

    private var scrollAnchor: Binding<String?> {
        Binding(
            get: { model.scrollAnchors[sessionID] },
            set: { model.scrollAnchors[sessionID] = $0 }
        )
    }

    private static let bottomID = "bottom"
    private static let workingID = "working"
    private static let decisionID = "decision"

    private var decision: RemoteRoomDecision? { room.flatMap { client.openDecision(inRoom: $0.id) } }

    private var displayTitle: String {
        let candidate = transcript?.title ?? (title.isEmpty ? (summary?.title ?? "") : title)
        return candidate.isEmpty ? "Chat" : candidate
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let transcript {
                        ForEach(transcript.items) { item in
                            TranscriptRow(
                                item: item,
                                agents: agents,
                                client: client,
                                onError: { actionError = $0 }
                            )
                            .id(item.id)
                        }
                        if let room, let decision {
                            RoomDecisionCard(
                                room: room,
                                decision: decision,
                                client: client,
                                onError: { actionError = $0 }
                            )
                            .id(Self.decisionID)
                        }
                        if activity == .working {
                            HStack(spacing: 8) {
                                ConstellationSpinner(size: 15)
                                Text("Working")
                                    .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                            }
                            .padding(.top, 2)
                            .id(Self.workingID)
                        }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.danger)
                            .padding(.top, 48)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .scrollTargetLayout()
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: scrollAnchor, anchor: .bottom)
            .remoteScreen()
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: transcript?.items.last) { old, _ in
                let anchor = model.scrollAnchors[sessionID]
                let atEnd = anchor == nil || anchor == Self.bottomID || anchor == Self.workingID
                    || anchor == Self.decisionID || anchor == old?.id
                if atEnd {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: transcript != nil) { _, loaded in
                if loaded { restoreScroll(proxy) }
            }
            .onChange(of: decision?.id) { _, id in
                if id != nil {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onAppear {
                if startAnchor == nil { startAnchor = .some(model.scrollAnchors[sessionID]) }
                if transcript != nil { restoreScroll(proxy) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let room {
                VStack(spacing: 0) {
                    RoomAgentsBar(room: room, onTapMembers: { showMembers = true })
                    if let goal = room.goal {
                        RoomGoalStrip(goal: goal)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RemoteTheme.sidebar)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RemoteComposerCard(
                draft: draft,
                addressee: addressee,
                focused: $composerFocused,
                room: room,
                mode: currentMode,
                activity: activity,
                sending: sending,
                connected: client.state.isConnected,
                onSelectMode: { mode in
                    act { try await client.setPermissionMode(mode, for: target) }
                },
                onControlRoom: { action in
                    if action == .stop { confirmStop = true } else { control(action) }
                },
                onInterrupt: {
                    act { try await client.interrupt(target) }
                },
                onSend: send
            )
        }
        .sheet(isPresented: $showMembers) {
            if let room {
                RoomMembersSheet(room: room)
                    .remoteThemeEnvironment()
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: "\(sessionID)-\(client.state.isConnected)") { await open() }
        .actionErrorAlert($actionError)
        .confirmationDialog("Stop \(room?.title ?? "the room")?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop the room", role: .destructive) { control(.stop) }
        } message: {
            Text("Ends the run. The sessions and the board stay, and a new message starts another run.")
        }
    }

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        let anchorTarget = (startAnchor ?? nil) ?? Self.bottomID
        DispatchQueue.main.async { proxy.scrollTo(anchorTarget, anchor: .bottom) }
    }

    private func open() async {
        guard client.state.isConnected else { return }
        do {
            loadError = nil
            try await client.open(sessionID: sessionID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(displayTitle)
                .font(RemoteTheme.font(size: 16, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.primaryText)
                .lineLimit(1)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let room, !room.members.isEmpty || !room.agents.isEmpty {
                Button {
                    showMembers = true
                } label: {
                    Image(systemName: "person.2")
                        .font(RemoteTheme.font(size: 14, weight: .medium, relativeTo: .body))
                        .foregroundStyle(RemoteTheme.secondaryText)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .accessibilityLabel("Members")
            }

            if activity == .working {
                Button {
                    if room != nil {
                        confirmStop = true
                    } else {
                        act { try await client.interrupt(target) }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(RemoteTheme.danger)
                }
                .accessibilityLabel(room == nil ? "Stop" : "Stop room")
            }
        }
    }

    private func control(_ action: RemoteRoomAction) {
        guard let id = roomID else { return }
        act { try await client.controlRoom(id, action: action) }
    }

    private func send() {
        let text = (model.drafts[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        let to = target
        let agent = model.addressees[sessionID]
        Task {
            do {
                try await client.send(text, to: to, agent: agent)
                model.drafts[sessionID] = nil
            } catch {
                actionError = error.localizedDescription
            }
            sending = false
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }
}

// MARK: - Floating Composer Card

private struct RemoteComposerCard: View {
    @Binding var draft: String
    @Binding var addressee: String?
    var focused: FocusState<Bool>.Binding
    let room: RemoteRoom?
    let mode: PermissionMode?
    let activity: SessionActivity
    let sending: Bool
    let connected: Bool
    let onSelectMode: (PermissionMode) -> Void
    let onControlRoom: (RemoteRoomAction) -> Void
    let onInterrupt: () -> Void
    let onSend: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var trimmedEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        if let addressee { return "Message @\(addressee)..." }
        return "Message..."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let room, !room.agents.isEmpty {
                    AddresseeChipStrip(agents: room.agents, selected: $addressee)
                }

                TextField(placeholder, text: $draft, axis: .vertical)
                    .font(RemoteTheme.font(size: 15, relativeTo: .body))
                    .lineLimit(1...6)
                    .focused(focused)
                    .foregroundStyle(RemoteTheme.primaryText)
                    .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    if let room {
                        modeBadge(room.permissionMode)
                        if room.state == .paused {
                            roomActionPill("Resume", systemImage: "play.fill", tint: RemoteTheme.accent) {
                                onControlRoom(.resume)
                            }
                        } else if room.state == .running {
                            roomActionPill("Pause", systemImage: "pause.fill", tint: RemoteTheme.secondaryText) {
                                onControlRoom(.pause)
                            }
                        }
                        if room.isRunActive {
                            roomActionPill("Stop", systemImage: "stop.fill", tint: RemoteTheme.danger) {
                                onControlRoom(.stop)
                            }
                        }
                    } else if let mode {
                        PermissionModeMenuCapsule(current: mode, onSelect: onSelectMode)
                    }

                    Spacer(minLength: 4)

                    actionCircleButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(
                RemoteTheme.card,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        focused.wrappedValue ? RemoteTheme.accent.opacity(0.6) : RemoteTheme.border,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.34 : 0.08),
                radius: 12,
                y: 4
            )
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [RemoteTheme.background.opacity(0), RemoteTheme.background.opacity(0.92), RemoteTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private var actionCircleButton: some View {
        if activity == .working && trimmedEmpty {
            Button(action: onInterrupt) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(RemoteTheme.background)
                    .frame(width: 12, height: 12)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(RemoteTheme.primaryText))
                    .frame(minWidth: RemoteTheme.minTapTarget, minHeight: RemoteTheme.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(room == nil ? "Stop" : "Pause")
        } else {
            let canSend = !trimmedEmpty && !sending && connected
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(RemoteTheme.font(size: 15, weight: .bold, relativeTo: .body))
                    .foregroundStyle(canSend ? RemoteTheme.onAccent : RemoteTheme.tertiaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(canSend ? RemoteTheme.accent : RemoteTheme.track))
                    .frame(minWidth: RemoteTheme.minTapTarget, minHeight: RemoteTheme.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private func modeBadge(_ mode: PermissionMode) -> some View {
        HStack(spacing: 5) {
            Image(systemName: mode.symbolName)
                .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption))
            Text(mode.shortLabel)
                .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(mode.isDangerous ? RemoteTheme.danger : RemoteTheme.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(RemoteTheme.cardRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
        .accessibilityLabel("Permission mode: \(mode.label)")
    }

    private func roomActionPill(
        _ label: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(RemoteTheme.font(size: 11, weight: .semibold, relativeTo: .caption2))
                Text(label)
                    .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.75))
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AddresseeChipStrip: View {
    let agents: [RemoteAgent]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "@all", color: RemoteTheme.accent, isSelected: selected == nil) {
                    selected = nil
                }
                ForEach(agents) { agent in
                    let agentColor = Color(remoteHex: agent.colorHex)
                    chip(label: "@\(agent.name)", color: agentColor, isSelected: selected == agent.name) {
                        selected = selected == agent.name ? nil : agent.name
                    }
                }
            }
        }
    }

    private func chip(label: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isSelected ? color : color.opacity(0.65))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(RemoteTheme.font(size: 12.5, weight: isSelected ? .semibold : .medium, relativeTo: .caption))
                    .foregroundStyle(isSelected ? RemoteTheme.primaryText : RemoteTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (isSelected ? color.opacity(0.16) : RemoteTheme.cardRaised),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? color.opacity(0.6) : RemoteTheme.border, lineWidth: 0.75)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionModeMenuCapsule: View {
    let current: PermissionMode
    let onSelect: (PermissionMode) -> Void

    var body: some View {
        Menu {
            Section("Permission mode") {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        if mode == current {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Label(mode.label, systemImage: mode.symbolName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.symbolName)
                    .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption))
                Text(current.shortLabel)
                    .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(RemoteTheme.font(size: 9.5, weight: .semibold, relativeTo: .caption2))
            }
            .fixedSize()
            .foregroundStyle(current.isDangerous ? RemoteTheme.danger : RemoteTheme.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RemoteTheme.cardRaised, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        current.isDangerous ? RemoteTheme.danger.opacity(0.45) : RemoteTheme.border,
                        lineWidth: 0.75
                    )
            )
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Permission mode: \(current.label)")
    }
}

private struct RoomMembersSheet: View {
    let room: RemoteRoom
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let goal = room.goal {
                        RoomGoalStrip(goal: goal)
                    }
                    if !room.members.isEmpty {
                        RoomMembersList(room: room)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(room.agents) { agent in
                                HStack(spacing: 8) {
                                    AgentTag(agent: agent, showModel: true)
                                    if agent.id == room.leadAgentID { Chip(text: "Lead") }
                                    Spacer()
                                    AgentActivityIcon(agent: agent)
                                    Text(RoomText.activity(agent))
                                        .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                                        .foregroundStyle(RemoteTheme.secondaryText)
                                }
                                .remoteCard(padding: 12)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .remoteScreen()
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
