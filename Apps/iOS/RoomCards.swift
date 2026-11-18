import EnsembleKit
import SwiftUI

// Pieces the Hub, the Rooms tab and the room chat share: the state chip, the agent strip, one-tap approval for short
// commands, and the card for what a room waits on.

/// The room's step ("Waiting for plan approval", "Paused"), coloured by what it means for the user.
struct RoomStateChip: View {
    let room: RemoteRoom

    var body: some View {
        Chip(text: room.phaseLabel ?? room.state.label, color: color)
    }

    private var color: Color {
        if room.needsYou { return RemoteTheme.warning }
        switch room.state {
        case .running: return RemoteTheme.success
        case .paused: return RemoteTheme.warning
        case .stopped: return RemoteTheme.danger
        case .idle: return RemoteTheme.secondaryText
        }
    }
}

/// Each agent with its colour, name and what it is doing, in a line that scrolls sideways when it does not fit.
struct RoomAgentsBar: View {
    let room: RemoteRoom

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                RoomStateChip(room: room)
                ForEach(room.agents) { agent in
                    HStack(spacing: 5) {
                        Circle().fill(Color(remoteHex: agent.colorHex)).frame(width: 8, height: 8)
                        Text(agent.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RemoteTheme.primaryText)
                        AgentActivityIcon(agent: agent)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RemoteTheme.cardRaised, in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(agent.name), \(RoomText.activity(agent))")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(RemoteTheme.background)
    }
}

/// A small mark for what an agent is doing: a spinner while it works, a raised hand while it waits for permission.
struct AgentActivityIcon: View {
    let agent: RemoteAgent

    var body: some View {
        if agent.capped == true {
            Image(systemName: "dollarsign.circle").font(.caption2).foregroundStyle(RemoteTheme.danger)
        } else {
            switch agent.activity {
            case .working: ProgressView().controlSize(.mini)
            case .waitingForPermission: Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(RemoteTheme.warning)
            case .failed: Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(RemoteTheme.danger)
            case .idle: EmptyView()
            }
        }
    }
}

enum RoomText {
    static func activity(_ agent: RemoteAgent) -> String {
        if agent.capped == true { return "Spending cap reached" }
        switch agent.activity {
        case .idle: return "Idle"
        case .working: return "Working"
        case .waitingForPermission: return "Needs permission"
        case .failed: return "Failed"
        }
    }

    /// The button that opens a decision in the room chat.
    static func openLabel(_ decision: RemoteRoomDecision) -> String {
        switch decision.kind {
        case .approvePlan: "Review the plan"
        case .writePlan: "Write the plan"
        case .judge: "Write the verdict"
        case .verdict: "See the verdict"
        default: "Review"
        }
    }

    static func symbol(_ kind: RemoteRoomDecision.Kind) -> String {
        switch kind {
        case .approvePlan: "checklist"
        case .writePlan: "square.and.pencil"
        case .reviewStalemate: "exclamationmark.bubble"
        case .takeover: "arrow.left.arrow.right"
        case .judge, .verdict: "scalemass"
        case .mergeConflict: "arrow.triangle.merge"
        case .other: "questionmark.circle"
        }
    }

    /// What a prompt asks, without the command (shown in full under it).
    static func ask(_ request: PermissionRequest, agent: String?) -> String {
        let who = agent ?? "An agent"
        switch request.kind {
        case "bash", "shell", "command": return "\(who) wants to run"
        case "edit", "write", "patch", "multiedit": return "\(who) wants to edit"
        case "webfetch", "fetch", "websearch": return "\(who) wants to open"
        default: return "\(who) asks to use \(request.kind)"
        }
    }
}

/// One room prompt in a list: short single-line commands in full with Allow once and Reject; anything longer only says
/// how long it is and opens the room chat, where the whole command is on its card.
struct RoomPromptRow: View {
    let request: PermissionRequest
    let agent: RemoteAgent?
    let client: RemoteClient
    var open: () -> Void
    var onError: (String) -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(RemoteTheme.warning)
                if let agent {
                    Circle().fill(Color(remoteHex: agent.colorHex)).frame(width: 7, height: 7)
                }
                Text(RoomText.ask(request, agent: agent?.name))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RemoteTheme.primaryText)
            }
            if PermissionDisplay.fitsQuickApproval(request) && !request.isInteraction {
                // Never truncated: everything a one-tap approval covers is on screen.
                Text(request.title)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                AdaptiveButtonRow {
                    Button("Allow once") { reply(.once) }
                        .buttonStyle(.borderedProminent)
                    Button("Reject", role: .destructive) { reply(.reject) }
                        .buttonStyle(.bordered)
                        .tint(RemoteTheme.danger)
                }
                .disabled(busy || !client.state.isConnected)
            } else {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.secondaryText)
                Button(action: open) {
                    Label("Read it in full", systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var summary: String {
        let lines = request.title.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 1 { return "A command of \(lines) lines" }
        return "A command of \(request.title.count) characters"
    }

    private func reply(_ decision: PermissionDecision) {
        busy = true
        Task {
            do { try await client.reply(to: request, decision: decision) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

/// Buttons side by side, or one under another when they do not fit (narrow screen, large text).
struct AdaptiveButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
        .controlSize(.small)
    }
}

/// What a room waits on: the decision's title and agent, its text (the plan, the review, the verdict), its items
/// (assignments, conflicting files), and a button per answer. Answers that take text open a sheet.
struct RoomDecisionCard: View {
    let room: RemoteRoom
    let decision: RemoteRoomDecision
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var busy = false
    @State private var expanded = false
    @State private var writing: RemoteRoomChoice?

    private var agents: [UUID: RemoteAgent] {
        Dictionary(room.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var isLong: Bool { (decision.text ?? "").split(separator: "\n").count > 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: RoomText.symbol(decision.kind))
                    .foregroundStyle(decision.needsYou ? RemoteTheme.warning : Color.accentColor)
                Text(decision.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let agent = decision.agentID.flatMap({ agents[$0] }) {
                AgentTag(agent: agent)
            }
            if let text = decision.text, !text.isEmpty {
                AgentMessageText(text: text, size: 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(expanded || !isLong ? nil : 12)
                if isLong {
                    Button(expanded ? "Show less" : "Show all of it") { withAnimation(.snappy) { expanded.toggle() } }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
            }
            if !decision.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(decision.items.enumerated()), id: \.offset) { _, item in
                        if let agent = item.agentID.flatMap({ agents[$0] }) {
                            VStack(alignment: .leading, spacing: 2) {
                                AgentTag(agent: agent)
                                Text(item.text)
                                    .font(.footnote)
                                    .foregroundStyle(RemoteTheme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(PermissionDisplay.visible(item.text))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(RemoteTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let note = decision.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AdaptiveButtonRow {
                ForEach(decision.choices) { choice in
                    choiceButton(choice)
                }
            }
            .disabled(busy || !client.state.isConnected)
        }
        .remoteCard(padding: 12)
        .overlay {
            if decision.needsYou {
                RoundedRectangle(cornerRadius: RemoteTheme.cornerRadius, style: .continuous)
                    .strokeBorder(RemoteTheme.warning.opacity(0.55), lineWidth: 1)
            }
        }
        .sheet(item: $writing) { choice in
            DecisionTextSheet(decision: decision, choice: choice) { text in
                send(choice, text: text)
            }
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: RemoteRoomChoice) -> some View {
        let action = {
            if choice.input == .none { send(choice, text: nil) } else { writing = choice }
        }
        switch choice.style {
        case .primary:
            Button(choice.label, action: action).buttonStyle(.borderedProminent)
        case .destructive:
            Button(choice.label, role: .destructive, action: action).buttonStyle(.bordered).tint(RemoteTheme.danger)
        case .standard:
            Button(choice.label, action: action).buttonStyle(.bordered)
        }
    }

    private func send(_ choice: RemoteRoomChoice, text: String?) {
        busy = true
        Task {
            do { try await client.decide(decision, in: room.id, choice: choice, text: text) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

/// Text for an answer that takes it: the redo feedback, the plan you write, the verdict.
struct DecisionTextSheet: View {
    let decision: RemoteRoomDecision
    let choice: RemoteRoomChoice
    var onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(decision: RemoteRoomDecision, choice: RemoteRoomChoice, onSend: @escaping (String) -> Void) {
        self.decision = decision
        self.choice = choice
        self.onSend = onSend
        _text = State(initialValue: choice.template ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(decision.title)
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(choice.placeholder ?? "", text: $text, axis: .vertical)
                    .font(choice.template != nil ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(4...16)
                    .focused($focused)
                    .padding(10)
                    .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(16)
            .remoteScreen()
            .navigationTitle(choice.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(trimmed)
                        dismiss()
                    }
                    .disabled(choice.input == .required && trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

/// Pause, Resume and Stop for a room. Stop asks first: it ends the run.
struct RoomControls: View {
    let room: RemoteRoom
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var confirmStop = false

    var body: some View {
        if room.state == .running || room.state == .paused || room.isRunActive {
            AdaptiveButtonRow {
                if room.state == .paused {
                    Button { control(.resume) } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                } else if room.state == .running {
                    Button { control(.pause) } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(.bordered)
                }
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
                    .tint(RemoteTheme.danger)
            }
            .disabled(!client.state.isConnected)
            .confirmationDialog("Stop \(room.title)?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the room", role: .destructive) { control(.stop) }
            } message: {
                Text("Ends the run. The sessions and the board stay, and a new message starts another run.")
            }
        }
    }

    private func control(_ action: RemoteRoomAction) {
        Task {
            do { try await client.controlRoom(room.id, action: action) } catch { onError(error.localizedDescription) }
        }
    }
}
