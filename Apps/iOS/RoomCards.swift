import EnsembleKit
import SwiftUI

// Pieces shared across Hub, Rooms, and Room Chat: state chip, tappable agent strip,
// permission prompt row, room decision card, goal strip, and member roster.

/// The room's current step ("Building", "Awaiting approval", "Paused").
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

/// Horizontal bar showing room state and participant agents. Tapping opens the Members sheet when provided.
struct RoomAgentsBar: View {
    let room: RemoteRoom
    var onTapMembers: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    RoomStateChip(room: room)
                    ForEach(room.agents) { agent in
                        agentChip(agent)
                    }
                    if let onTapMembers, !room.members.isEmpty || !room.agents.isEmpty {
                        Button(action: onTapMembers) {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2")
                                Text("Members")
                                Image(systemName: "chevron.right")
                                    .font(RemoteTheme.font(size: 9.5, weight: .semibold, relativeTo: .caption2))
                            }
                            .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RemoteTheme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(RemoteTheme.sidebar)
            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private func agentChip(_ agent: RemoteAgent) -> some View {
        let chip = HStack(spacing: 6) {
            Circle().fill(Color(remoteHex: agent.colorHex)).frame(width: 8, height: 8)
            Text(agent.name)
                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.primaryText)
            AgentActivityIcon(agent: agent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RemoteTheme.cardRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(RoomText.activity(agent))")

        if let onTapMembers {
            Button(action: onTapMembers) { chip }
                .buttonStyle(.plain)
        } else {
            chip
        }
    }
}

/// Small activity mark for a room agent.
struct AgentActivityIcon: View {
    let agent: RemoteAgent

    var body: some View {
        if agent.capped == true {
            Image(systemName: "dollarsign.circle")
                .font(RemoteTheme.font(size: 11, relativeTo: .caption2))
                .foregroundStyle(RemoteTheme.danger)
        } else {
            switch agent.activity {
            case .working:
                Spinner(size: 10)
            case .waitingForPermission:
                Image(systemName: "hand.raised.fill")
                    .font(RemoteTheme.font(size: 11, relativeTo: .caption2))
                    .foregroundStyle(RemoteTheme.warning)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(RemoteTheme.font(size: 11, relativeTo: .caption2))
                    .foregroundStyle(RemoteTheme.danger)
            case .idle:
                EmptyView()
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

/// One room prompt in a list: short single-line commands inline with Allow once / Reject; longer ones open the room.
struct RoomPromptRow: View {
    let request: PermissionRequest
    let agent: RemoteAgent?
    let client: RemoteClient
    var open: () -> Void
    var onError: (String) -> Void
    @State private var busy = false
    @State private var allowHaptic = 0
    @State private var rejectHaptic = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.warning)
                if let agent {
                    Circle().fill(Color(remoteHex: agent.colorHex)).frame(width: 7, height: 7)
                }
                Text(RoomText.ask(request, agent: agent?.name))
                    .font(RemoteTheme.font(size: 13.5, weight: .semibold, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.primaryText)
            }

            if PermissionDisplay.fitsQuickApproval(request) && !request.isInteraction {
                RemoteCommandBox(text: request.title)
                FlowRow(spacing: 8, lineSpacing: 8) {
                    Button("Allow once") { reply(.once) }
                        .buttonStyle(RemotePrimaryButtonStyle())
                    Button("Reject", role: .destructive) { reply(.reject) }
                        .buttonStyle(
                            RemoteSecondaryButtonStyle(
                                foreground: RemoteTheme.danger,
                                border: RemoteTheme.danger.opacity(0.4)
                            )
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(busy || !client.state.isConnected)
            } else {
                Text(summary)
                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
                Button(action: open) {
                    Label("Read it in full", systemImage: "text.magnifyingglass")
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
            }
        }
        .sensoryFeedback(.success, trigger: allowHaptic)
        .sensoryFeedback(.warning, trigger: rejectHaptic)
    }

    private var summary: String {
        let lines = request.title.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 1 { return "A command of \(lines) lines" }
        return "A command of \(request.title.count) characters"
    }

    private func reply(_ decision: PermissionDecision) {
        if decision == .reject { rejectHaptic += 1 } else { allowHaptic += 1 }
        busy = true
        Task {
            do { try await client.reply(to: request, decision: decision) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

/// Interactive card for what a room waits on (Approve plan, Edit, Accept Verdict, Build it).
struct RoomDecisionCard: View {
    let room: RemoteRoom
    let decision: RemoteRoomDecision
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var busy = false
    @State private var expanded = false
    @State private var writing: RemoteRoomChoice?
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 15

    private var agents: [UUID: RemoteAgent] {
        Dictionary(room.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var lines: [String] {
        (decision.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    private var isLong: Bool { lines.count > 12 }
    private var visibleMarkdown: String {
        guard let text = decision.text else { return "" }
        if expanded || !isLong { return text }
        return lines.prefix(12).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: RoomText.symbol(decision.kind))
                    .foregroundStyle(decision.needsYou ? RemoteTheme.warning : RemoteTheme.accent)
                Text(decision.title)
                    .font(RemoteTheme.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let agent = decision.agentID.flatMap({ agents[$0] }) {
                AgentTag(agent: agent)
            }

            if let text = decision.text, !text.isEmpty {
                MarkdownView(visibleMarkdown, fontSize: messageSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLong {
                    Button(expanded ? "Show less" : "Show all of it") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .frame(minHeight: RemoteTheme.minTapTarget)
                    .contentShape(Rectangle())
                }
            }

            if !decision.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(decision.items.enumerated()), id: \.offset) { _, item in
                        if let agent = item.agentID.flatMap({ agents[$0] }) {
                            VStack(alignment: .leading, spacing: 3) {
                                AgentTag(agent: agent)
                                Text(item.text)
                                    .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                                    .foregroundStyle(RemoteTheme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(PermissionDisplay.visible(item.text))
                                .font(RemoteTheme.font(size: 12.5, design: .monospaced, relativeTo: .footnote))
                                .foregroundStyle(RemoteTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                )
            }

            if let note = decision.note {
                Text(note)
                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowRow(spacing: 8, lineSpacing: 8) {
                ForEach(decision.choices) { choice in
                    choiceButton(choice)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(busy || !client.state.isConnected)
        }
        .remoteCard(padding: 14, attention: decision.needsYou)
        .sheet(item: $writing) { choice in
            DecisionTextSheet(decision: decision, choice: choice) { text in
                send(choice, text: text)
            }
            .remoteThemeEnvironment()
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: RemoteRoomChoice) -> some View {
        let action = {
            if choice.input == .none { send(choice, text: nil) } else { writing = choice }
        }
        switch choice.style {
        case .primary:
            Button(choice.label, action: action)
                .buttonStyle(RemotePrimaryButtonStyle())
        case .destructive:
            Button(choice.label, role: .destructive, action: action)
                .buttonStyle(
                    RemoteSecondaryButtonStyle(
                        foreground: RemoteTheme.danger,
                        border: RemoteTheme.danger.opacity(0.4)
                    )
                )
        case .standard:
            Button(choice.label, action: action)
                .buttonStyle(RemoteSecondaryButtonStyle())
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

/// Text entry sheet for room decisions that carry feedback, plans, or verdicts.
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
            VStack(alignment: .leading, spacing: 12) {
                Text(decision.title)
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(choice.placeholder ?? "", text: $text, axis: .vertical)
                    .font(
                        choice.template != nil
                            ? RemoteTheme.font(size: 14, design: .monospaced, relativeTo: .body)
                            : RemoteTheme.font(size: 15, relativeTo: .body)
                    )
                    .lineLimit(4...16)
                    .focused($focused)
                    .padding(12)
                    .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(RemoteTheme.border, lineWidth: 1)
                    )
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
    }
}

/// Pause, Resume, and Stop controls for an active room.
struct RoomControls: View {
    let room: RemoteRoom
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var confirmStop = false
    @State private var stopPauseHaptic = 0

    var body: some View {
        if room.state == .running || room.state == .paused || room.isRunActive {
            FlowRow(spacing: 8, lineSpacing: 8) {
                if room.state == .paused {
                    Button { control(.resume) } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(RemotePrimaryButtonStyle())
                } else if room.state == .running {
                    Button { control(.pause) } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(RemoteSecondaryButtonStyle())
                }
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(
                        RemoteSecondaryButtonStyle(
                            foreground: RemoteTheme.danger,
                            border: RemoteTheme.danger.opacity(0.4)
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!client.state.isConnected)
            .confirmationDialog("Stop \(room.title)?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the room", role: .destructive) { control(.stop) }
            } message: {
                Text("Ends the run. The sessions and the board stay, and a new message starts another run.")
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: stopPauseHaptic)
        }
    }

    private func control(_ action: RemoteRoomAction) {
        if action == .pause || action == .stop { stopPauseHaptic += 1 }
        Task {
            do { try await client.controlRoom(room.id, action: action) } catch { onError(error.localizedDescription) }
        }
    }
}

// MARK: - Goal and Members

/// The room's goal strip.
struct RoomGoalStrip: View {
    let goal: RemoteGoal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(RemoteTheme.font(size: 13, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.condition)
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .lineLimit(2)
                Text(detail)
                    .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(cost)
                .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(RemoteTheme.tertiaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.25), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(goal.active ? "Active goal" : "Goal"): \(goal.condition). \(detail)")
    }

    private var symbol: String {
        goal.active ? "target" : (goal.statusLabel.hasPrefix("Met") ? "checkmark.circle.fill" : "stop.circle")
    }

    private var color: Color {
        if goal.active { return RemoteTheme.accent }
        return goal.statusLabel.hasPrefix("Met") ? RemoteTheme.success : RemoteTheme.secondaryText
    }

    private var detail: String {
        var parts = [goal.active ? "Active goal" : "Goal", goal.statusLabel]
        if goal.active, let reason = goal.lastReason, !reason.isEmpty {
            parts.append("Not met yet: \(reason)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var cost: String {
        if let cap = goal.maxCostUSD {
            return "\(RemoteFormat.cost(goal.costSpentUSD)) of \(RemoteFormat.cost(cap))"
        }
        return RemoteFormat.cost(goal.costSpentUSD)
    }
}

/// Each agent with its role, state, step, and spend.
struct RoomMembersList: View {
    let room: RemoteRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(room.members) { member in
                if let agent = room.agents.first(where: { $0.id == member.agentID }) {
                    RoomMemberRow(agent: agent, member: member, showsRole: room.mode != .solo)
                }
            }
        }
    }
}

struct RoomMemberRow: View {
    let agent: RemoteAgent
    let member: RemoteMember
    var showsRole = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AgentTag(agent: agent)
                if showsRole {
                    Chip(
                        text: member.role,
                        color: member.role == "Lead" || member.role == "Judge" ? RemoteTheme.accent : RemoteTheme.secondaryText
                    )
                }
                Spacer(minLength: 4)
                Text(member.stateLabel)
                    .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(RoomText.memberColor(member.state))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let step = member.step {
                    Text(step)
                        .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                        .foregroundStyle(member.state == "waitingOnYou" ? RemoteTheme.warning : RemoteTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(RemoteFormat.cost(member.costUSD))
                    .font(RemoteTheme.font(size: 12, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(RemoteTheme.tertiaryText)
            }
            .padding(.leading, 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(member.role), \(member.stateLabel)\(member.step.map { ", \($0)" } ?? "")")
    }
}

extension RoomText {
    static func memberColor(_ state: String) -> Color {
        switch state {
        case "active": RemoteTheme.accent
        case "waitingOnYou": RemoteTheme.warning
        case "finished": RemoteTheme.success
        case "stopped": RemoteTheme.danger
        default: RemoteTheme.tertiaryText
        }
    }
}
