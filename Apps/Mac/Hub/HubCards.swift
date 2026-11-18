import SwiftUI
import EnsembleKit

// MARK: - Session card

/// A session on the Hub: status, title, folder, agents, age, what it waits on in a line, then the answers that fit in
/// place. Each card observes only its own session, so a streaming transcript redraws its card and nothing else.
struct HubSessionCard: View {
    let store: SessionStore
    @Bindable var window: WindowState
    let session: SessionModel
    let item: HubCardItem
    let now: Date
    let selected: Bool
    let attention: AttentionCenter
    let onOpen: () -> Void
    let onSelect: () -> Void
    @Environment(\.theme) private var theme

    private var replyOpen: Bool { window.hubReplySessionID == session.id }
    private var requests: [PermissionRequest] { item.candidate.requests }

    var body: some View {
        HubCardFrame(selected: selected, onSelect: onSelect) {
            HStack(alignment: .top, spacing: theme.z(10)) {
                HubStatusIcon(reason: item.reason, count: requests.count)
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                        Text(session.title)
                            .font(theme.font(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: theme.z(8))
                        Text(Format.relative(session.info.updated, now: now))
                            .font(theme.font(size: 11.5).monospacedDigit())
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    HubMetaLine(directory: session.directory, agents: agents, model: agents.isEmpty ? store.modelName(session.info.model) : nil)
                }
                actionIcons
            }
            VStack(alignment: .leading, spacing: theme.z(10)) {
                summary
                quickActions
                if replyOpen {
                    HubReplyBox(store: store, window: window, sessionID: session.id, working: session.isWorking)
                }
            }
            .padding(.leading, theme.z(30))
        }
    }

    private var agents: [AgentSpec] {
        (store.sessionAgentIDs[session.id] ?? []).compactMap { store.agents[$0] }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        switch item.reason {
        case .permission(let request):
            HubSummaryText(more(HubText.question(for: request)), emphasis: true)
        case .plan(let request):
            HubSummaryText(more("Plan ready: " + (request.plan?.title ?? request.title)), emphasis: true)
            if let plan = request.plan {
                let preview = HubText.planPreview(plan)
                if !preview.isEmpty {
                    Text(preview)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .question:
            if requests.count > 1 { HubSummaryText(more("Question"), emphasis: true) }
        case .failed:
            HubSummaryText(HubText.failure(of: session.id, store: store), color: theme.danger)
        case .askedQuestion:
            HubSummaryText(HubText.lastWords(of: session.id, store: store) ?? "Asked you something", emphasis: true)
        case .running:
            HubSummaryText(HubText.activity(of: session, store: store))
        case .unread, .finished, .quiet:
            if let words = HubText.lastWords(of: session.id, store: store) { HubSummaryText(words) }
        case .completed:
            HubSummaryText("Marked completed")
        case .archived:
            HubSummaryText("Archived")
        case .roomDecision, .roomPaused:
            EmptyView()
        }
    }

    /// "and 2 more" after the first request when several wait.
    private func more(_ text: String) -> String {
        requests.count > 1 ? text + " (and \(requests.count - 1) more)" : text
    }

    // MARK: Quick actions

    @ViewBuilder private var quickActions: some View {
        switch item.reason {
        case .permission(let request):
            if HubSorter.allowsQuickApproval(request) {
                HubCommandBox(text: request.title)
                HStack(spacing: theme.z(8)) {
                    Button("Allow once") { Task { await store.reply(to: request, decision: .once) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Allow this once")
                    Button("Reject") { Task { await store.reply(to: request, decision: .reject) } }
                        .buttonStyle(SecondaryButtonStyle())
                    replyButton
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: theme.z(8)) {
                    Button("Review in session", action: onOpen)
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Long or multi-line requests open in the session so you can read all of it")
                    replyButton
                    Spacer(minLength: 0)
                }
            }
        case .plan(let request):
            let mode = request.plan?.allowedProceedModes.first ?? .acceptEdits
            HStack(spacing: theme.z(8)) {
                Button("Proceed in \(mode.shortLabel)") {
                    Task { await store.respondToPlan(request, decision: .proceed(mode)) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Switch to \(mode.label) and carry out the plan")
                Button("Keep planning") {
                    Task { await store.respondToPlan(request, decision: .keepPlanning(comments: [])) }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Read plan", action: onOpen)
                    .buttonStyle(SecondaryButtonStyle())
                Spacer(minLength: 0)
            }
        case .question(let request):
            QuestionCardView(
                request: request,
                onAnswer: { answers in Task { await store.answerQuestion(request, answers: answers) } },
                onDecline: { Task { await store.declineQuestion(request) } })
                .id(request.id)
        case .failed, .askedQuestion:
            // Replying is how these get answered, so the button sits in the card; elsewhere it is an icon.
            if !replyOpen {
                HStack(spacing: theme.z(8)) {
                    replyButton
                    Spacer(minLength: 0)
                }
            }
        default:
            EmptyView()
        }
    }

    /// Reply lives in the card's icons unless the card offers it as a button.
    private var replyIsIcon: Bool {
        switch item.reason {
        case .permission, .plan, .question, .failed, .askedQuestion: false
        default: true
        }
    }

    @ViewBuilder private var replyButton: some View {
        if !replyOpen {
            Button {
                window.openHubReply(session.id)
                onSelect()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(session.isWorking ? "Queue a message for when the agent finishes" : "Send a message without opening the session")
        }
    }

    // MARK: Card icons

    private var actionIcons: some View {
        HStack(spacing: theme.z(2)) {
            if replyIsIcon && !replyOpen {
                IconButton("arrowshape.turn.up.left", help: session.isWorking ? "Reply: queue a message for when the agent finishes" : "Reply",
                           size: 26) {
                    window.openHubReply(session.id)
                    onSelect()
                }
            }
            IconButton("arrow.up.right", help: "Open (Return)", size: 26, action: onOpen)
            if canComplete {
                IconButton("checkmark.circle", help: "Mark as completed", size: 26) {
                    attention.setCompleted(session.id, true)
                }
            }
            IconButton("archivebox", help: "Archive", size: 26) {
                if window.hubReplySessionID == session.id { window.closeHubReply() }
                Task { await store.archive(session.id) }
            }
        }
        .padding(.top, theme.z(-4))
        .padding(.trailing, theme.z(-6))
    }

    /// Marking completed only moves a card when nothing open still waits on the user.
    private var canComplete: Bool {
        guard requests.isEmpty else { return false }
        switch item.reason {
        case .running, .completed, .archived: return false
        default: return true
        }
    }
}

// MARK: - Room card

/// A room on the Hub: its agents and colours, mode, phase, what it waits on, and Allow once or Reject for a short
/// command from one of its agents. Decisions open the room.
struct HubRoomCard: View {
    let rooms: RoomsController
    let room: RoomState
    let item: HubCardItem
    let now: Date
    let selected: Bool
    let attention: AttentionCenter
    let onOpen: () -> Void
    let onSelect: () -> Void
    @Environment(\.theme) private var theme

    private var requests: [PermissionRequest] { item.candidate.requests }

    var body: some View {
        HubCardFrame(selected: selected, onSelect: onSelect) {
            HStack(alignment: .top, spacing: theme.z(10)) {
                HubStatusIcon(reason: item.reason, count: max(requests.count, rooms.needsYouCount(room.id)), room: true)
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                        Text(room.spec.title)
                            .font(theme.font(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        HubTag(text: room.runMode.label)
                        Spacer(minLength: theme.z(8))
                        Text(Format.relative(item.candidate.lastActivity, now: now))
                            .font(theme.font(size: 11.5).monospacedDigit())
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    HubMetaLine(directory: room.spec.directory, agents: room.spec.agents, model: nil)
                }
                HStack(spacing: theme.z(2)) {
                    IconButton("arrow.up.right", help: "Open room (Return)", size: 26, action: onOpen)
                    if requests.isEmpty && !item.candidate.roomNeedsUser && !item.candidate.running && !item.candidate.completed {
                        IconButton("checkmark.circle", help: "Mark as completed", size: 26) {
                            attention.marks.setCompleted(HubBoardSource.markID(room: room.id), true)
                        }
                    }
                }
                .padding(.top, theme.z(-4))
                .padding(.trailing, theme.z(-6))
            }
            VStack(alignment: .leading, spacing: theme.z(10)) {
                summary
                actions
            }
            .padding(.leading, theme.z(30))
        }
    }

    private func agentName(_ id: UUID) -> String? { room.spec.agents.first { $0.id == id }?.name }

    /// The agent whose session asked.
    private func asker(of request: PermissionRequest) -> AgentSpec? {
        let root = rooms.roomSession(for: request.sessionID) ?? request.sessionID
        return room.sessions.first { $0.value == root }.flatMap { pair in room.spec.agents.first { $0.id == pair.key } }
    }

    @ViewBuilder private var summary: some View {
        switch item.reason {
        case .permission(let request):
            HubSummaryText(prefix(request) + HubText.question(for: request), emphasis: true)
        case .plan(let request):
            HubSummaryText(prefix(request) + "Plan ready: " + (request.plan?.title ?? request.title), emphasis: true)
        case .question(let request):
            HubSummaryText(prefix(request) + "Asks: " + (request.questions?.first?.text ?? request.title), emphasis: true)
        case .roomDecision(let decision):
            HubSummaryText(HubSorter.decisionText(decision, agentName: agentName), emphasis: true)
        case .roomPaused:
            HubSummaryText(room.pauseReason ?? "Paused: an agent reached its spending cap", emphasis: true)
        case .running:
            HubSummaryText(room.isPaused ? "Paused" : room.phase.label)
        default:
            HubSummaryText(room.phase == .idle ? "Idle" : room.phase.label)
        }
    }

    private func prefix(_ request: PermissionRequest) -> String {
        asker(of: request).map { $0.name + ": " } ?? ""
    }

    @ViewBuilder private var actions: some View {
        switch item.reason {
        case .permission(let request) where HubSorter.allowsQuickApproval(request):
            HubCommandBox(text: request.title)
            HStack(spacing: theme.z(8)) {
                Button("Allow once") { Task { await rooms.reply(to: request, decision: .once) } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Reject") { Task { await rooms.reply(to: request, decision: .reject) } }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer(minLength: 0)
            }
        case .permission, .plan, .question, .roomDecision, .roomPaused:
            HStack(spacing: theme.z(8)) {
                Button("Open room", action: onOpen)
                    .buttonStyle(PrimaryButtonStyle())
                Spacer(minLength: 0)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Old row

/// A compact row for the Old bucket: title, folder, age, Open, and Archive or Unarchive.
struct HubOldRow: View {
    let item: HubCardItem
    let title: String
    let directory: String
    let date: Date
    let now: Date
    let selected: Bool
    let onOpen: () -> Void
    let onSelect: () -> Void
    /// Sessions only: archives (true) or unarchives (false).
    var onArchive: ((Bool) -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Image(systemName: symbol)
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(20))
            Text(title)
                .font(theme.font(size: 13))
                .foregroundStyle(item.reason == .archived ? theme.textTertiary : theme.textSidebar)
                .lineLimit(1)
            Text(Format.folderName(directory))
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: theme.z(8))
            if hovering || selected {
                if let onArchive {
                    let archived = item.reason == .archived
                    IconButton(archived ? "tray.and.arrow.up" : "archivebox", help: archived ? "Unarchive" : "Archive", size: 24) {
                        onArchive(!archived)
                    }
                }
                IconButton("arrow.up.right", help: "Open (Return)", size: 24, action: onOpen)
            }
            Text(Format.relative(date, now: now))
                .font(theme.font(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(34))
        .background(
            RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                .fill(selected ? theme.selection : (hovering ? theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(Format.folderName(directory))")
    }

    private var symbol: String {
        switch item.reason {
        case .archived: "archivebox"
        case .completed: "checkmark"
        default: item.isRoom ? "person.3" : "bubble.left"
        }
    }
}

// MARK: - Reply box

/// The Hub's inline reply: a message to the session without opening it (queued while its agent works). Return or
/// Command-Return sends, Esc closes. Shares the session's composer draft.
struct HubReplyBox: View {
    let store: SessionStore
    @Bindable var window: WindowState
    let sessionID: String
    let working: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    private var draft: Binding<String> {
        Binding(get: { window.drafts[sessionID] ?? "" }, set: { window.drafts[sessionID] = $0 })
    }

    private var placeholder: String { working ? "Queue a message for when the agent finishes" : "Send a message" }

    var body: some View {
        let text = draft.wrappedValue
        HStack(alignment: .bottom, spacing: theme.z(8)) {
            Group {
                if isSnapshot {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("", text: draft, prompt: Text(placeholder).foregroundStyle(theme.textTertiary), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .foregroundStyle(theme.textPrimary)
                        .focused($focused)
                        .onSubmit(send)
                        .onExitCommand { window.closeHubReply() }
                }
            }
            .font(theme.font(size: 13.5))
            .padding(.vertical, theme.z(4))
            Text("\u{2318}\u{21A9}")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, theme.z(6))
                .help("Command-Return sends")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(theme.font(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? theme.onAccent : theme.textTertiary)
                    .frame(width: theme.z(26), height: theme.z(26))
                    .background(Circle().fill(canSend ? theme.accent : theme.hover))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(working ? "Queue" : "Send")
            .accessibilityLabel(working ? "Queue" : "Send")
            IconButton("xmark", help: "Close (Esc)", size: 24) { window.closeHubReply() }
                .padding(.bottom, theme.z(1))
        }
        .padding(.leading, theme.z(12))
        .padding(.trailing, theme.z(6))
        .padding(.vertical, theme.z(5))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.background))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(focused || isSnapshot ? theme.accent.opacity(0.6) : theme.border))
        .onAppear { if !isSnapshot { focused = true } }
    }

    private var canSend: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        window.sendHubReply(to: sessionID, store: store)
    }
}

// MARK: - Pieces

/// Card background, border (accent when selected by keyboard or click) and the click that selects it.
struct HubCardFrame<Content: View>: View {
    let selected: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(9)) {
            content
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(12), style: .continuous)
                .strokeBorder(selected ? theme.accent.opacity(0.75) : theme.border, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }
}

/// The card's left mark: needs-you count, spinner, failed or unread dot, finished check.
struct HubStatusIcon: View {
    let reason: HubReason
    var count = 0
    var room = false
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch reason {
            case .permission, .plan, .question, .roomDecision, .roomPaused:
                CountBadge(max(count, 1))
            case .askedQuestion:
                Image(systemName: "questionmark")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: theme.z(17), height: theme.z(17))
                    .background(Circle().fill(theme.accent))
            case .failed:
                StatusDot(theme.danger, size: 8)
            case .running:
                Spinner(size: 12)
            case .unread:
                StatusDot(theme.contextBlue, size: 8)
            case .finished:
                Image(systemName: room ? "person.3" : "checkmark")
                    .font(theme.font(size: room ? 10 : 11, weight: .semibold))
                    .foregroundStyle(room ? theme.textTertiary : theme.success)
            case .completed, .archived, .quiet:
                Image(systemName: "checkmark")
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(width: theme.z(20), height: theme.z(20))
    }
}

/// Folder, then the agents with their colours (room agents), or the model.
struct HubMetaLine: View {
    let directory: String
    let agents: [AgentSpec]
    let model: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: "folder")
                .font(theme.font(size: 10.5))
            Text(Format.folderName(directory))
                .lineLimit(1)
                .help(Format.abbreviatedPath(directory))
            if !agents.isEmpty || model != nil {
                Text("\u{00B7}")
            }
            ForEach(agents.prefix(5)) { agent in
                HStack(spacing: theme.z(4)) {
                    Circle().fill(Color(hexString: agent.colorHex)).frame(width: theme.z(7), height: theme.z(7))
                    Text(agent.name).lineLimit(1)
                }
            }
            if agents.count > 5 { Text("+\(agents.count - 5)") }
            if let model { Text(model).lineLimit(1) }
        }
        .font(theme.font(size: 12))
        .foregroundStyle(theme.textTertiary)
    }
}

/// The one-line summary of what a card waits on.
struct HubSummaryText: View {
    let text: String
    var emphasis = false
    var color: Color?
    @Environment(\.theme) private var theme

    init(_ text: String, emphasis: Bool = false, color: Color? = nil) {
        self.text = text
        self.emphasis = emphasis
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(theme.font(size: 13, weight: emphasis ? .medium : .regular))
            .foregroundStyle(color ?? (emphasis ? theme.textPrimary : theme.textSecondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }
}

/// The whole command a quick approval would allow, in monospace, never cut off.
struct HubCommandBox: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(PermissionDisplay.visible(text, keepLineBreaks: false))
            .font(theme.font(size: 12.5, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(7))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border.opacity(0.7)))
            .selectableText()
    }
}

/// A small grey label (a room's mode).
struct HubTag: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, theme.z(6))
            .padding(.vertical, theme.z(1.5))
            .background(Capsule().fill(theme.hover))
            .fixedSize()
    }
}
