import EnsembleKit
import SwiftUI

/// One session or room chat: transcript, composer, permission mode, room controls.
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
    /// Where the reader was when this view appeared (nil: the end). Read once, before the transcript arrives, because the
    /// scroll view records its first row as the position while the rows come in.
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
    private var agents: [UUID: RemoteAgent] {
        Dictionary((transcript?.agents ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // Kept in the app model so they survive the view being rebuilt when the layout changes (folding).
    private var draft: Binding<String> {
        Binding(get: { model.drafts[sessionID] ?? "" },
                set: { model.drafts[sessionID] = $0.isEmpty ? nil : $0 })
    }
    private var addressee: String? {
        get { model.addressees[sessionID] }
        nonmutating set { model.addressees[sessionID] = newValue }
    }
    private var scrollAnchor: Binding<String?> {
        Binding(get: { model.scrollAnchors[sessionID] },
                set: { model.scrollAnchors[sessionID] = $0 })
    }
    private var draftText: String { model.drafts[sessionID] ?? "" }

    private static let bottomID = "bottom"
    private static let workingID = "working"
    private static let decisionID = "decision"

    /// What the room waits on, while it is open.
    private var decision: RemoteRoomDecision? { room.flatMap { client.openDecision(inRoom: $0.id) } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let transcript {
                        ForEach(transcript.items) { item in
                            TranscriptRow(item: item, agents: agents, client: client, onError: { actionError = $0 })
                                .id(item.id)
                        }
                        if let room, let decision {
                            RoomDecisionCard(room: room, decision: decision, client: client, onError: { actionError = $0 })
                                .id(Self.decisionID)
                        }
                        if activity == .working {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working")
                                    .font(.footnote)
                                    .foregroundStyle(RemoteTheme.secondaryText)
                            }
                            .id(Self.workingID)
                        }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(RemoteTheme.danger)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollPosition(id: scrollAnchor, anchor: .bottom)
            .remoteScreen()
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: transcript?.items.last) { old, _ in
                // Follow new rows only when the reader was already at the end.
                let anchor = model.scrollAnchors[sessionID]
                let atEnd = anchor == nil || anchor == Self.bottomID || anchor == Self.workingID || anchor == Self.decisionID
                    || anchor == old?.id
                if atEnd {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: transcript != nil) { _, loaded in
                if loaded { restoreScroll(proxy) }
            }
            .onChange(of: decision?.id) { _, id in
                // A new decision is what the reader needs next.
                if id != nil { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .onAppear {
                if startAnchor == nil { startAnchor = .some(model.scrollAnchors[sessionID]) }
                if transcript != nil { restoreScroll(proxy) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let room {
                VStack(spacing: 0) {
                    RoomAgentsBar(room: room)
                    if let goal = room.goal {
                        RoomGoalStrip(goal: goal)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
                .background(RemoteTheme.background)
            }
        }
        .sheet(isPresented: $showMembers) {
            if let room {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let goal = room.goal { RoomGoalStrip(goal: goal) }
                            RoomMembersList(room: room)
                        }
                        .padding(16)
                    }
                    .remoteScreen()
                    .navigationTitle("Members")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showMembers = false } }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(transcript?.title ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: sessionID) { await open() }
        .onChange(of: client.state.isConnected) { _, connected in
            if connected && transcript == nil { Task { await open() } }
        }
        .actionErrorAlert($actionError)
        .confirmationDialog("Stop \(room?.title ?? "the room")?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop the room", role: .destructive) { control(.stop) }
        } message: {
            Text("Ends the run. The sessions and the board stay, and a new message starts another run.")
        }
    }

    /// Puts the transcript back where the reader left it, or at the end the first time.
    private func restoreScroll(_ proxy: ScrollViewProxy) {
        let target = (startAnchor ?? nil) ?? Self.bottomID
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func open() async {
        // Not connected yet: the chat opens when the connection comes up (`onChange` of the connection state).
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
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let room {
                    if !room.members.isEmpty {
                        Button { showMembers = true } label: { Label("Members", systemImage: "person.3") }
                    }
                    // A room keeps the permission mode it was made with.
                    Section("Permission mode: \(room.permissionMode.label)") {
                        if room.state == .paused {
                            Button { control(.resume) } label: { Label("Resume room", systemImage: "play.fill") }
                        } else if room.state == .running {
                            Button { control(.pause) } label: { Label("Pause room", systemImage: "pause.fill") }
                        }
                        if room.isRunActive {
                            Button(role: .destructive) { confirmStop = true } label: { Label("Stop room", systemImage: "stop.fill") }
                        }
                    }
                } else {
                    Section("Permission mode") {
                        ForEach(PermissionMode.allCases, id: \.self) { mode in
                            Button {
                                act { try await client.setPermissionMode(mode, for: target) }
                            } label: {
                                if mode == currentMode {
                                    Label(mode.label, systemImage: "checkmark")
                                } else {
                                    Text(mode.label)
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: currentMode == .bypass ? "exclamationmark.shield" : "shield.lefthalf.filled")
                    .foregroundStyle(currentMode == .bypass ? RemoteTheme.danger : RemoteTheme.primaryText)
            }
            .accessibilityLabel(room == nil ? "Permission mode" : "Room controls")
        }
    }

    private var currentMode: PermissionMode? { transcript?.permissionMode ?? room?.permissionMode }

    private func control(_ action: RemoteRoomAction) {
        guard let id = roomID else { return }
        act { try await client.controlRoom(id, action: action) }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let room {
                roomBar(room)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .foregroundStyle(RemoteTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if activity == .working && draftText.isEmpty {
                    Button {
                        act { try await client.interrupt(target) }
                    } label: {
                        Image(systemName: room == nil ? "stop.circle.fill" : "pause.circle.fill").font(.system(size: 32))
                    }
                    .foregroundStyle(RemoteTheme.primaryText)
                    .accessibilityLabel(room == nil ? "Stop" : "Pause the room")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !client.state.isConnected)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var placeholder: String {
        if let addressee { return "Message @\(addressee)" }
        return room != nil ? "Message the room" : "Message"
    }

    private func roomBar(_ room: RemoteRoom) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("Everyone") { addressee = nil }
                ForEach(room.agents) { agent in
                    Button("@\(agent.name)") { addressee = agent.name }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(addressee.map { "To @\($0)" } ?? "To everyone")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(RemoteTheme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RemoteTheme.cardRaised, in: Capsule())
            }
            if let agent = addressee.flatMap({ name in room.agents.first { $0.name == name } }) {
                Circle().fill(Color(remoteHex: agent.colorHex)).frame(width: 8, height: 8)
            }
            Spacer()
        }
    }

    private func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        let to = target
        let agent = addressee
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
