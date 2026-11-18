import SwiftUI
import EnsembleKit

/// What the room's main column shows.
enum RoomTab: Hashable {
    case board
    case rounds
}

/// A room: header (title, mode, phase, cost, Pause / Resume, Stop, Take over), agent chips, the board thread with
/// live text, decision and permission cards, the composer, and the side panel (agents, pieces or rounds, or one
/// agent's own session).
struct RoomView: View {
    let controller: RoomsController
    let engine: RoomEngine
    /// Room for the window's traffic lights when the app sidebar is hidden.
    var leadingInset: CGFloat = 0
    var showsSidePanel = true
    /// Opens an agent's session in the app's normal session view.
    var openSession: (@MainActor @Sendable (String) -> Void)?
    /// Snapshots set these.
    var initialTab: RoomTab = .board
    var initialAgentID: UUID?
    var snapshotDraft: String?

    @Environment(\.theme) private var theme
    @State private var tab: RoomTab?
    @State private var selectedAgentID: UUID?
    @State private var agentSelectionSet = false
    @State private var draft = ""
    @State private var recipients: [UUID] = []

    static let columnWidth: CGFloat = 760
    static let panelWidth: CGFloat = 303
    static let transcriptPanelWidth: CGFloat = 420

    var body: some View {
        HStack(spacing: theme.z(0)) {
            VStack(spacing: theme.z(0)) {
                RoomHeader(controller: controller, engine: engine, leadingInset: leadingInset)
                AgentChipRow(controller: controller, engine: engine, selectedAgentID: agentSelection,
                             tab: tabBinding, showsTabs: engine.state.runMode == .debate || engine.state.debate != nil)
                content
                VStack(spacing: theme.z(0)) {
                    if engine.state.isPaused, let reason = engine.state.pauseReason {
                        PauseBanner(reason: reason) { Task { await engine.resume() } }
                            .padding(.bottom, theme.z(8))
                    }
                    RoomComposer(engine: engine, models: models, draft: $draft, recipients: $recipients, snapshotDraft: snapshotDraft)
                    RoomStatusLine(engine: engine)
                }
                .frame(maxWidth: theme.z(Self.columnWidth + 24))
                .padding(.horizontal, theme.z(20))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            if showsSidePanel {
                VLine()
                RoomSidePanel(controller: controller, engine: engine, selectedAgentID: agentSelection, openSession: openSession)
                    .frame(width: theme.z(agentSelection.wrappedValue == nil ? Self.panelWidth : Self.transcriptPanelWidth))
            }
        }
        .environment(\.transcriptActions, actions)
        .environment(\.sessionDirectory, engine.state.spec.directory)
    }

    private var models: [ModelInfo] { controller.models(for: engine.state.spec.directory) }

    private var tabBinding: Binding<RoomTab> {
        Binding(get: { tab ?? initialTab }, set: { tab = $0 })
    }

    private var agentSelection: Binding<UUID?> {
        Binding(get: { agentSelectionSet ? selectedAgentID : initialAgentID },
                set: { selectedAgentID = $0; agentSelectionSet = true })
    }

    private var actions: TranscriptActions {
        let controller = controller
        let openSession = openSession
        return TranscriptActions(
            openSession: { id in openSession?(id) },
            replyPermission: { request, decision in Task { await controller.reply(to: request, decision: decision) } }
        )
    }

    @ViewBuilder private var content: some View {
        if tabBinding.wrappedValue == .rounds {
            RoomScroll(scrollKey: scrollKey, roomID: engine.state.id) {
                VStack(alignment: .leading, spacing: theme.z(18)) {
                    DebateRoundsView(controller: controller, engine: engine, models: models)
                    RoomPermissionCards(controller: controller, engine: engine)
                    RoomDecisionArea(engine: engine, models: models)
                }
            }
        } else {
            RoomScroll(scrollKey: scrollKey, roomID: engine.state.id) {
                RoomBoardContent(controller: controller, engine: engine, models: models)
            }
        }
    }

    /// Changes whenever new content should pull the thread to the bottom.
    private var scrollKey: Int {
        var hasher = Hasher()
        hasher.combine(engine.state.board.count)
        hasher.combine(engine.state.pendingDecision)
        hasher.combine(engine.state.phase)
        hasher.combine(engine.state.debate?.arguments.count)
        for agent in engine.agents {
            hasher.combine(controller.liveText(of: agent.id, in: engine)?.count ?? 0)
            hasher.combine(controller.activity(of: agent.id, in: engine))
        }
        hasher.combine(controller.pendingPermissions(in: engine).count)
        return hasher.finalize()
    }
}

/// Board messages, streaming text, working agents, permission prompts, decisions and errors.
struct RoomBoardContent: View {
    let controller: RoomsController
    let engine: RoomEngine
    let models: [ModelInfo]
    @Environment(\.theme) private var theme
    @State private var dismissedError: String?

    var body: some View {
        let state = engine.state
        let agentsByID = Dictionary(engine.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = engine.agents.compactMap { agent in controller.liveText(of: agent.id, in: engine).map { (agent, $0) } }
        let working = engine.agents.filter { agent in
            controller.activity(of: agent.id, in: engine) == .working && !live.contains { $0.0.id == agent.id }
        }
        let prompted = Set(controller.pendingPermissions(in: engine).map(\.agent.id))
        let waiting = engine.agents.filter {
            controller.activity(of: $0.id, in: engine) == .waitingForPermission && !prompted.contains($0.id)
        }
        VStack(alignment: .leading, spacing: theme.z(18)) {
            if state.board.isEmpty {
                RoomEmptyState(engine: engine, models: models)
            }
            RoomBoardThread(messages: boardMessages(state), agents: agentsByID, models: models)
            ForEach(live, id: \.0.id) { agent, text in
                LiveAgentRow(agent: agent, text: text, models: models)
            }
            if !working.isEmpty || !waiting.isEmpty {
                WorkingAgentsRow(working: working, waiting: waiting)
            }
            RoomPermissionCards(controller: controller, engine: engine)
            RoomDecisionArea(engine: engine, models: models)
            if let error = engine.lastError, error != dismissedError {
                HStack(alignment: .top, spacing: theme.z(6)) {
                    ErrorRow(message: error)
                    Button {
                        dismissedError = error
                    } label: {
                        Image(systemName: "xmark")
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: theme.z(22), height: theme.z(22))
                    }
                    .buttonStyle(.plain)
                    .help("Hide this error")
                }
            }
        }
    }
}

extension RoomBoardContent {
    /// While the verdict card is up, the verdict message itself is shown by the card.
    func boardMessages(_ state: RoomState) -> [BoardMessage] {
        guard state.phase == .verdict, state.debate?.verdict != nil,
              let index = state.board.lastIndex(where: { $0.kind == .verdict }) else { return state.board }
        var list = state.board
        list.remove(at: index)
        return list
    }
}

/// Permission prompts from the room's agents, each with the agent's name and colour.
struct RoomPermissionCards: View {
    let controller: RoomsController
    let engine: RoomEngine
    @Environment(\.theme) private var theme

    var body: some View {
        let pending = controller.pendingPermissions(in: engine)
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: theme.z(12)) {
                ForEach(pending, id: \.request.id) { item in
                    VStack(alignment: .leading, spacing: theme.z(6)) {
                        HStack(spacing: theme.z(6)) {
                            AgentDot(hex: item.agent.colorHex, size: 8)
                            Text(item.agent.name)
                                .font(theme.font(size: 12.5, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text("asks")
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                        PermissionCardView(request: item.request)
                    }
                }
            }
        }
    }
}

/// Shown before the first message: what the mode does and who is in the room.
private struct RoomEmptyState: View {
    let engine: RoomEngine
    let models: [ModelInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        let mode = engine.state.spec.mode
        VStack(alignment: .leading, spacing: theme.z(12)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: mode.symbolName)
                    .font(theme.font(size: 14))
                    .foregroundStyle(theme.accent)
                Text(mode.label)
                    .font(theme.font(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            Text(mode.explanation)
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: theme.z(6)) {
                ForEach(engine.agents) { agent in
                    HStack(spacing: theme.z(8)) {
                        AgentHeader(agent: agent, models: models)
                        if !agent.role.isEmpty {
                            Text(agent.role)
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(theme.z(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.separator))
    }
}

/// Scrolls to the bottom when new content arrives, unless the user scrolled up.
struct RoomScroll<Content: View>: View {
    let scrollKey: Int
    let roomID: UUID
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var pinnedToBottom = true
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        if isSnapshot {
            padded
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: theme.z(0), maxHeight: .infinity, alignment: .bottom)
                .clipped()
        } else {
            ScrollView { padded }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
                } action: { _, atBottom in
                    pinnedToBottom = atBottom
                }
                .onChange(of: scrollKey) {
                    if pinnedToBottom { position.scrollTo(edge: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !pinnedToBottom {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(theme.font(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .frame(width: theme.z(30), height: theme.z(30))
                                .background(Circle().fill(theme.elevated))
                                .overlay(Circle().strokeBorder(theme.border))
                                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Jump to the newest message")
                        .padding(.bottom, theme.z(10))
                    }
                }
                .clipped()
                .id(roomID)
        }
    }

    private var padded: some View {
        content
            .frame(maxWidth: theme.z(RoomView.columnWidth), alignment: .leading)
            .padding(.horizontal, theme.z(32))
            .padding(.top, theme.z(14))
            .padding(.bottom, theme.z(22))
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Header

/// Title, mode, phase, total cost, and Pause / Resume, Stop, Take over.
struct RoomHeader: View {
    let controller: RoomsController
    let engine: RoomEngine
    var leadingInset: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if leadingInset > 0 { Color.clear.frame(width: leadingInset, height: 1) }
            // Narrow windows (or a large zoom) first drop the cost and shorten the title, then show icon-only controls.
            ViewThatFits(in: .horizontal) {
                row(compact: false, showsCost: true, titleLimit: nil)
                row(compact: false, showsCost: false, titleLimit: theme.z(180))
                row(compact: true, showsCost: false, titleLimit: nil)
            }
        }
        .padding(.leading, theme.z(20))
        .padding(.trailing, theme.z(16))
        .frame(height: 52)
        .background(theme.background)
    }

    private func row(compact: Bool, showsCost: Bool, titleLimit: CGFloat?) -> some View {
        let state = engine.state
        return HStack(spacing: theme.z(10)) {
            title(state.spec.title, limit: titleLimit, flexible: compact)
            HStack(spacing: theme.z(4)) {
                Image(systemName: state.runMode.symbolName).font(theme.font(size: 10.5))
                if !compact { Text(state.runMode.label) }
            }
            .font(theme.font(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, theme.z(7))
            .frame(height: theme.z(20))
            .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).strokeBorder(theme.border))
            .help(state.runMode.label)
            .fixedSize()
            phase.fixedSize()
            if showsCost {
                Text(Format.usd(state.totalUsage.costUSD))
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .help("\(Format.tokens(state.totalUsage.inputTokens + state.totalUsage.outputTokens)) tokens across the room")
                    .fixedSize()
            }
            Spacer(minLength: theme.z(12))
            controls(compact: compact).fixedSize()
        }
    }

    @ViewBuilder private func title(_ text: String, limit: CGFloat?, flexible: Bool) -> some View {
        let label = Text(text)
            .font(theme.font(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .help(text)
        if flexible {
            label.truncationMode(.tail)
        } else if let limit {
            label.truncationMode(.tail).frame(maxWidth: limit, alignment: .leading)
        } else {
            label.fixedSize()
        }
    }

    @ViewBuilder private var phase: some View {
        let state = engine.state
        HStack(spacing: theme.z(6)) {
            if state.isPaused {
                Image(systemName: "pause.circle.fill").font(theme.font(size: 11)).foregroundStyle(theme.warning)
                Text("Paused").foregroundStyle(theme.warning)
            } else if state.pendingDecision != nil || state.phase == .verdict {
                Circle().fill(theme.accent).frame(width: theme.z(6), height: theme.z(6))
                Text(state.pendingDecision != nil ? "Needs you" : state.phase.label).foregroundStyle(theme.accent)
            } else if state.phase.isRunning {
                Spinner(size: 10, color: theme.accent)
                Text(state.phase.label).foregroundStyle(theme.textSecondary)
            } else {
                Text(state.phase.label).foregroundStyle(theme.textTertiary)
            }
        }
        .font(theme.font(size: 12))
    }

    @ViewBuilder private func controls(compact: Bool) -> some View {
        let state = engine.state
        HStack(spacing: theme.z(6)) {
            if state.isPaused {
                RoomHeaderButton(title: "Resume", symbol: "play.fill", compact: compact) { Task { await engine.resume() } }
            } else {
                RoomHeaderButton(title: "Pause", symbol: "pause.fill", compact: compact) { Task { await engine.pause() } }
                    .disabled(!state.phase.isRunActive)
            }
            RoomHeaderButton(title: "Stop", symbol: "stop.fill", tint: theme.danger, compact: compact) { Task { await engine.stop() } }
                .disabled(!(state.phase.isRunActive || state.isPaused))
            if state.spec.mode != .solo {
                if state.userIsLead {
                    ChoiceChip(title: compact ? "" : (state.runMode == .debate ? "You judge" : "You lead"), symbol: "person.crop.circle",
                               options: engine.agents.map { ($0.id, "Give the lead to \($0.name)", nil, $0.colorHex, true) },
                               selection: UUID()) { engine.setLead($0) }
                        .help(state.runMode == .debate ? "You judge. Choose an agent to judge instead." : "You lead. Choose an agent to lead instead.")
                } else {
                    RoomHeaderButton(title: "Take over", symbol: "person.crop.circle", compact: compact,
                                     tooltip: state.runMode == .debate ? "Take over: you write the verdict"
                                         : "Take over: plans, conflicts and verdicts come to you") { engine.takeOver() }
                }
            }
        }
    }
}

// MARK: - Agent chips

/// One chip per agent (colour, name, model, activity); click to open its session. Debate rooms also get
/// Board and Rounds tabs.
struct AgentChipRow: View {
    let controller: RoomsController
    let engine: RoomEngine
    @Binding var selectedAgentID: UUID?
    @Binding var tab: RoomTab
    var showsTabs: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                HStack(spacing: theme.z(6)) {
                    ForEach(engine.agents) { agent in
                        AgentChip(agent: agent,
                                  model: shortModelName(agent.model, models: controller.models(for: engine.state.spec.directory)),
                                  activity: controller.activity(of: agent.id, in: engine),
                                  isLead: engine.leadID == agent.id && engine.state.spec.mode != .solo,
                                  leadLabel: engine.state.runMode == .debate ? "Judge" : "Lead",
                                  selected: selectedAgentID == agent.id) {
                            selectedAgentID = selectedAgentID == agent.id ? nil : agent.id
                        }
                    }
                }
                .padding(.vertical, theme.z(1))
            }
            .scrollIndicators(.never)
            if showsTabs {
                RoomTabs(tab: $tab)
            }
        }
        .padding(.horizontal, theme.z(20))
        .padding(.bottom, theme.z(8))
    }
}

struct AgentChip: View {
    let agent: AgentSpec
    let model: String
    let activity: AgentActivity
    let isLead: Bool
    let leadLabel: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(6)) {
                AgentDot(hex: agent.colorHex, size: 8)
                Text(agent.name)
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(model)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                if isLead { RoomTag(text: leadLabel, color: theme.accent) }
                ActivityBadge(activity: activity, color: Color(hexString: agent.colorHex))
            }
            .padding(.horizontal, theme.z(10))
            .frame(height: theme.z(28))
            .background(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                    .fill(selected ? theme.selection : (hovering ? theme.elevatedHover : theme.elevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                    .strokeBorder(selected ? Color(hexString: agent.colorHex).opacity(0.8) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(agent.name): \(activity.label). Click to see its session.")
        .accessibilityLabel("\(agent.name), \(model), \(activity.label)")
    }
}

/// Board / Rounds switch.
private struct RoomTabs: View {
    @Binding var tab: RoomTab
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(2)) {
            item("Board", .board)
            item("Rounds", .rounds)
        }
        .padding(theme.z(2))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border))
    }

    private func item(_ title: String, _ value: RoomTab) -> some View {
        Button { tab = value } label: {
            Text(title)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(tab == value ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, theme.z(10))
                .frame(height: theme.z(22))
                .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(tab == value ? theme.selection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Composer

/// Message box for the room: to everyone, or one agent (chip or a leading @name).
struct RoomComposer: View {
    let engine: RoomEngine
    let models: [ModelInfo]
    @Binding var draft: String
    @Binding var recipients: [UUID]
    var snapshotDraft: String?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if !mentions.isEmpty { mentionRow }
            textArea
            HStack(spacing: theme.z(6)) {
                ChoiceChip(title: recipientTitle, dotHex: recipientDot, bordered: false,
                           options: recipientOptions, selection: recipients.first) { id in
                    recipients = id.map { [$0] } ?? []
                }
                .help("Who gets the message. You can also start it with @name or @all.")
                Spacer(minLength: 8)
                sendButton
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.top, theme.z(12))
        .padding(.bottom, theme.z(10))
        .background(RoundedRectangle(cornerRadius: theme.z(16), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(16), style: .continuous).strokeBorder(focused ? theme.accent.opacity(0.5) : theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: 10, y: 3)
    }

    private var startsRun: Bool {
        recipients.isEmpty && [.idle, .finished, .stopped].contains(engine.state.phase) && !engine.state.isPaused
    }

    private var placeholder: String {
        if startsRun {
            return engine.state.spec.mode == .debate ? "Ask the room a question" : "Give the room a task"
        }
        if let id = recipients.first, let agent = engine.agent(id) { return "Message \(agent.name)" }
        return "Message the room, or start with @name for one agent"
    }

    @ViewBuilder private var textArea: some View {
        let text = snapshotDraft ?? draft
        if isSnapshot {
            Text(text.isEmpty ? placeholder : text)
                .font(theme.font(size: 14))
                .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                .padding(.top, theme.z(2))
                .frame(maxWidth: .infinity, minHeight: theme.z(22), alignment: .topLeading)
        } else {
            TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(theme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(send)
                .onKeyPress(.tab) {
                    guard let first = mentions.first else { return .ignored }
                    complete(first.name)
                    return .handled
                }
                .padding(.top, theme.z(2))
        }
    }

    // MARK: @name completion

    /// Agents (and "all") matching an `@` typed at the start of the message, before the first space.
    private var mentions: [(name: String, colorHex: String?)] {
        let text = snapshotDraft ?? draft
        guard recipients.isEmpty, text.hasPrefix("@"), !text.contains(where: \.isWhitespace) else { return [] }
        let query = text.dropFirst().lowercased()
        var out: [(String, String?)] = engine.agents
            .filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
            .map { ($0.name, $0.colorHex) }
        if engine.agents.count > 1, query.isEmpty || "all".hasPrefix(query) { out.append(("all", nil)) }
        if out.count == 1, out[0].0.lowercased() == query { return [] }
        return out
    }

    private var mentionRow: some View {
        HStack(spacing: theme.z(6)) {
            ForEach(Array(mentions.enumerated()), id: \.offset) { index, mention in
                Button { complete(mention.name) } label: {
                    HStack(spacing: theme.z(5)) {
                        if let hex = mention.colorHex { AgentDot(hex: hex, size: 7) }
                        Text("@" + mention.name)
                            .font(theme.font(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.horizontal, theme.z(8))
                    .frame(height: theme.z(24))
                    .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(index == 0 ? theme.selection : theme.hover))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mention.name == "all" ? "Message every agent" : "Message only \(mention.name)")
            }
            Text("Tab to complete")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .padding(.leading, theme.z(4))
            Spacer(minLength: 0)
        }
    }

    private func complete(_ name: String) {
        draft = "@\(name) "
        focused = true
    }

    private var recipientTitle: String {
        guard let id = recipients.first, let agent = engine.agent(id) else { return "To everyone" }
        return "To \(agent.name)"
    }

    private var recipientDot: String? {
        recipients.first.flatMap { engine.agent($0)?.colorHex }
    }

    private var recipientOptions: [(value: UUID?, title: String, detail: String?, dotHex: String?, enabled: Bool)] {
        [(nil, "Everyone", nil, nil, true)] + engine.agents.map { ($0.id, $0.name, shortModelName($0.model, models: models), $0.colorHex, true) }
    }

    private var sendButton: some View {
        let hasText = canSend
        return Button(action: send) {
            Image(systemName: "arrow.up")
                .font(theme.font(size: 13, weight: .bold))
                .foregroundStyle(hasText ? theme.onAccent : theme.textTertiary)
                .frame(width: theme.z(30), height: theme.z(30))
                .background(Circle().fill(hasText ? theme.accent : theme.hover))
        }
        .buttonStyle(.plain)
        .disabled(!hasText)
        .help(startsRun ? "Start the run (Return)" : "Send (Return)")
        .accessibilityLabel("Send")
    }

    /// Some text beyond a bare `@name`.
    private var canSend: Bool {
        let text = (snapshotDraft ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !(text.hasPrefix("@") && !text.contains(where: \.isWhitespace))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let to = recipients
        draft = ""
        Task { await engine.send(text, to: to) }
    }
}

/// Under the composer: room spend and the permission mode.
struct RoomStatusLine: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme

    var body: some View {
        let state = engine.state
        let usage = state.totalUsage
        HStack(spacing: theme.z(12)) {
            HStack(spacing: theme.z(5)) {
                Image(systemName: "chart.bar").font(theme.font(size: 10.5))
                Text("\(Format.usd(usage.costUSD))  \(Format.tokens(usage.inputTokens + usage.outputTokens)) tokens")
                    .monospacedDigit()
            }
            .help("Spend across the room's agents")
            Spacer(minLength: 8)
            HStack(spacing: theme.z(5)) {
                Image(systemName: state.spec.permissionMode.symbolName).font(theme.font(size: 10.5))
                Text(state.spec.permissionMode.label)
            }
            .foregroundStyle(state.spec.permissionMode.isDangerous ? theme.danger : theme.textTertiary)
        }
        .font(theme.font(size: 11.5))
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(30))
    }
}

/// Why the room is paused, with Resume.
struct PauseBanner: View {
    let reason: String
    let resume: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "pause.circle.fill")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
            Text(reason)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Resume", action: resume)
                .buttonStyle(.plain)
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(8))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.warning.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.warning.opacity(0.3)))
    }
}
