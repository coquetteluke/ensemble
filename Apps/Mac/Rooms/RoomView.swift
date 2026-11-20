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
    /// Room for the window's toolbar button when nothing is to the right of the room.
    var trailingInset: CGFloat = 0
    var showsSidePanel = true
    /// Opens an agent's session in the app's normal session view.
    var openSession: (@MainActor @Sendable (String) -> Void)?
    /// Snapshots set these.
    var initialTab: RoomTab = .board
    var initialAgentID: UUID?
    var snapshotDraft: String?
    var initialReplayStep: Int?
    var initialFollow = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var tab: RoomTab?
    @State private var selectedAgentID: UUID?
    @State private var agentSelectionSet = false
    @State private var draft = ""
    @State private var recipients: [UUID] = []
    /// Replay: how many board messages are shown (`nil` is live).
    @State private var replayStep: Int?
    @State private var replaySet = false
    /// Follow mode: the side panel shows whichever agent is working.
    @State private var followSet: Bool?
    @State private var followTracker = RoomFollow()
    /// Board filter and jump-to-agent state.
    @State private var boardFilter = RoomBoardFilter()
    @State private var showBoardFilter = false
    @State private var jumpTargetID: UUID?
    @State private var jumpToken = 0
    @State private var filterFocusToken = 0

    static let columnWidth: CGFloat = 760
    static let panelWidth: CGFloat = 303
    static let transcriptPanelWidth: CGFloat = 420

    var body: some View {
        let onBoard = tabBinding.wrappedValue == .board
        let allMessages = currentBoardMessages
        let agentsByID = Dictionary(engine.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let filteredCount = boardFilter.isActive ? boardFilter.filter(allMessages, agents: agentsByID).count : allMessages.count

        HStack(spacing: theme.z(0)) {
            VStack(spacing: theme.z(0)) {
                RoomHeader(controller: controller, engine: engine, leadingInset: leadingInset,
                           trailingInset: showsSidePanel ? 0 : trailingInset)
                AgentChipRow(controller: controller, engine: engine, selectedAgentID: agentSelection,
                             tab: tabBinding, showsTabs: engine.state.runMode == .debate || engine.state.debate != nil,
                             follow: showsSidePanel && engine.agents.count > 1 ? followBinding : nil,
                             filterOpen: onBoard ? $showBoardFilter : nil,
                             filterActive: boardFilter.isActive,
                             onFilterAgent: { filterBoard(to: $0) },
                             onJumpToLatest: { jumpToLatestMessage(for: $0) })
                if onBoard && showBoardFilter {
                    RoomBoardFilterBar(
                        filter: $boardFilter,
                        agents: engine.agents,
                        messages: allMessages,
                        filteredCount: filteredCount,
                        focusToken: filterFocusToken,
                        onJumpToAgent: { jumpToLatestMessage(for: $0) },
                        onClose: {
                            withAnimation(.easeOut(duration: 0.12)) { showBoardFilter = false }
                        }
                    )
                }
                content
                VStack(spacing: theme.z(0)) {
                    if engine.state.isPaused, let reason = engine.state.pauseReason {
                        PauseBanner(reason: reason) { Task { await engine.resume() } }
                            .padding(.bottom, theme.z(8))
                    }
                    RoomComposer(engine: engine, models: models, draft: $draft, recipients: $recipients, snapshotDraft: snapshotDraft)
                    RoomStatusLine(engine: engine)
                }
                .modifier(AdaptiveInsetModifier(wide: 20, narrow: 10, maxContentWidth: Self.columnWidth + 24))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            if showsSidePanel {
                VLine()
                RoomSidePanel(controller: controller, engine: engine, selectedAgentID: agentSelection, openSession: openSession,
                              replayStep: replayBinding, following: isFollowing)
                    .frame(width: theme.z(agentSelection.wrappedValue == nil ? Self.panelWidth : Self.transcriptPanelWidth))
            }
        }
        .environment(\.transcriptActions, actions)
        .environment(\.sessionDirectory, engine.state.spec.directory)
        .onChange(of: workingAgentIDs) { followWorkingAgent() }
        .onChange(of: isFollowing) { if isFollowing { followWorkingAgent() } }
        .onChange(of: tab) { _, nextTab in
            if nextTab == .rounds { jumpTargetID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ensembleFindInCurrentView)) { _ in
            guard !isSnapshot else { return }
            if tabBinding.wrappedValue != .board { tabBinding.wrappedValue = .board }
            withAnimation(.easeOut(duration: 0.14)) { showBoardFilter = true }
            filterFocusToken &+= 1
        }
    }

    private var currentBoardMessages: [BoardMessage] {
        let state = engine.state
        if let step = RoomReplay.clamp(replayBinding.wrappedValue, board: state.board) {
            return RoomReplay.messages(state.board, at: step)
        }
        return RoomBoardContent.rawBoardMessages(state)
    }

    private func filterBoard(to agentID: UUID) {
        if tabBinding.wrappedValue != .board { tabBinding.wrappedValue = .board }
        boardFilter.agentID = agentID
        withAnimation(.easeOut(duration: 0.14)) { showBoardFilter = true }
    }

    private func jumpToLatestMessage(for agentID: UUID) {
        guard let targetID = RoomBoardFilter.latestMessageID(for: agentID, in: engine.state.board) else { return }
        if tabBinding.wrappedValue != .board { tabBinding.wrappedValue = .board }
        if replayBinding.wrappedValue != nil { replayBinding.wrappedValue = nil }
        if boardFilter.isActive { boardFilter.clear() }
        jumpTargetID = targetID
        jumpToken &+= 1
    }

    // MARK: Replay and Follow

    private var replayBinding: Binding<Int?> {
        Binding(get: { replaySet ? replayStep : initialReplayStep },
                set: { replayStep = $0; replaySet = true })
    }

    private var isFollowing: Bool { followSet ?? initialFollow }

    private var followBinding: Binding<Bool> {
        Binding(get: { isFollowing }, set: { followSet = $0 })
    }

    /// Agents in a turn or waiting for permission, in roster order.
    private var workingAgentIDs: [UUID] {
        RoomFollow.working(engine.agents) { controller.activity(of: $0, in: engine) }
    }

    /// Follow mode: shows the agent that works now, moving on when it hands off. Leaves the panel alone when nobody works.
    private func followWorkingAgent() {
        guard isFollowing else { return }
        if let id = followTracker.update(working: workingAgentIDs), id != agentSelection.wrappedValue {
            selectedAgentID = id
            agentSelectionSet = true
        }
    }

    private var models: [ModelInfo] { controller.models(for: engine.state.spec.directory) }

    private var tabBinding: Binding<RoomTab> {
        Binding(get: { tab ?? initialTab }, set: { tab = $0 })
    }

    /// The agent whose session the side panel shows. Picking one by hand (or closing it) turns Follow off.
    private var agentSelection: Binding<UUID?> {
        Binding(get: { agentSelectionSet ? selectedAgentID : initialAgentID },
                set: {
                    selectedAgentID = $0
                    agentSelectionSet = true
                    if isFollowing { followSet = false }
                })
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
            let step = RoomReplay.clamp(replayBinding.wrappedValue, board: engine.state.board)
            VStack(spacing: theme.z(0)) {
                if let step {
                    // Pinned above the thread so it stays in view however far the board scrolls.
                    ReplayBanner(step: step, count: engine.state.board.count) { replayBinding.wrappedValue = nil }
                        .frame(maxWidth: theme.z(RoomView.columnWidth))
                        .padding(.top, theme.z(6))
                        .modifier(AdaptiveInsetModifier(wide: 32, narrow: 16))
                }
                RoomScroll(scrollKey: scrollKey, roomID: engine.state.id,
                           jumpMessageID: jumpTargetID, jumpToken: jumpToken) {
                    RoomBoardContent(
                        controller: controller,
                        engine: engine,
                        models: models,
                        replayStep: step,
                        boardFilter: boardFilter,
                        onClearFilter: { boardFilter.clear() }
                    )
                }
            }
        }
    }

    /// Changes whenever new content should pull the thread to the bottom.
    private var scrollKey: Int {
        var hasher = Hasher()
        hasher.combine(engine.state.board.count)
        hasher.combine(replayBinding.wrappedValue)
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
    /// Replay: the board as it was after this many messages (`nil` is live). Live text, prompts and decisions are left
    /// out while replaying.
    var replayStep: Int?
    var boardFilter = RoomBoardFilter()
    var onClearFilter: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var dismissedError: String?

    var body: some View {
        if let step = replayStep {
            let agentsByID = Dictionary(engine.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let raw = RoomReplay.messages(engine.state.board, at: step)
            let shown = boardFilter.filter(raw, agents: agentsByID)
            if boardFilter.isActive && shown.isEmpty && !raw.isEmpty {
                filteredEmptyState
            } else {
                RoomBoardThread(messages: shown, agents: agentsByID, models: models)
            }
        } else {
            live
        }
    }

    @ViewBuilder private var live: some View {
        let state = engine.state
        let agentsByID = Dictionary(engine.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rawMessages = Self.rawBoardMessages(state)
        let shownMessages = boardMessages(state, agents: agentsByID)
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
            if boardFilter.isActive && shownMessages.isEmpty && !rawMessages.isEmpty {
                filteredEmptyState
            } else {
                RoomBoardThread(messages: shownMessages, agents: agentsByID, models: models)
            }
            ForEach(live, id: \.0.id) { agent, text in
                LiveAgentRow(agent: agent, text: text, models: models)
            }
            if !working.isEmpty || !waiting.isEmpty {
                WorkingAgentsRow(working: working, waiting: waiting)
            }
            RoomPermissionCards(controller: controller, engine: engine)
            if let verdictID = Self.verdictCardMessageID(state) {
                RoomDecisionArea(engine: engine, models: models)
                    .id(verdictID)
            } else {
                RoomDecisionArea(engine: engine, models: models)
            }
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

    private var filteredEmptyState: some View {
        HStack(spacing: theme.z(12)) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textTertiary)
            Text("No board messages match this filter.")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: theme.z(8))
            if let onClearFilter {
                Button("Clear filter", action: onClearFilter)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.separator))
    }
}

extension RoomBoardContent {
    /// The verdict board message currently rendered by `RoomDecisionArea` instead of `RoomBoardThread`.
    static func verdictCardMessageID(_ state: RoomState) -> UUID? {
        guard state.phase == .verdict, state.debate?.verdict != nil else { return nil }
        return state.board.last(where: { $0.kind == .verdict })?.id
    }

    /// While the verdict card is up, the verdict message itself is shown by the card.
    static func rawBoardMessages(_ state: RoomState) -> [BoardMessage] {
        guard state.phase == .verdict, state.debate?.verdict != nil,
              let index = state.board.lastIndex(where: { $0.kind == .verdict }) else { return state.board }
        var list = state.board
        list.remove(at: index)
        return list
    }

    func boardMessages(_ state: RoomState, agents: [UUID: AgentSpec] = [:]) -> [BoardMessage] {
        boardFilter.filter(Self.rawBoardMessages(state), agents: agents)
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
    var jumpMessageID: UUID? = nil
    var jumpToken: Int = 0
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var pinnedToBottom = true
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var lastHandledJumpToken = 0

    var body: some View {
        if isSnapshot {
            padded
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: theme.z(0), maxHeight: .infinity, alignment: .bottom)
                .clipped()
        } else {
            ScrollViewReader { proxy in
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
                    .onAppear { performPendingJump(proxy: proxy) }
                    .onChange(of: jumpToken) { performPendingJump(proxy: proxy) }
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
                                    .shadow(color: .black.opacity(0.25), radius: theme.z(6), y: theme.z(2))
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
    }

    private func performPendingJump(proxy: ScrollViewProxy) {
        guard jumpToken != lastHandledJumpToken, let targetID = jumpMessageID else { return }
        lastHandledJumpToken = jumpToken
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    private var padded: some View {
        content
            .frame(maxWidth: theme.z(RoomView.columnWidth), alignment: .leading)
            .padding(.top, theme.z(14))
            .padding(.bottom, theme.z(22))
            .modifier(AdaptiveInsetModifier(wide: 32, narrow: 16))
    }
}

// MARK: - Header

/// Title, mode, phase, total cost, and Pause / Resume, Stop, Take over.
struct RoomHeader: View {
    let controller: RoomsController
    let engine: RoomEngine
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.z(0)) {
            HStack(spacing: 0) {
                if leadingInset > 0 { Color.clear.frame(width: leadingInset, height: 1) }
                // Narrow windows (or a large zoom) first drop the cost and shorten the title, then show icon-only controls.
                ViewThatFits(in: .horizontal) {
                    row(compact: false, showsCost: true, showsMode: true, compactPhase: false, titleLimit: nil, minTitleWidth: nil)
                    row(compact: false, showsCost: false, showsMode: true, compactPhase: false, titleLimit: theme.z(180), minTitleWidth: nil)
                    row(compact: true, showsCost: false, showsMode: true, compactPhase: false, titleLimit: nil, minTitleWidth: theme.z(100))
                    row(compact: true, showsCost: false, showsMode: false, compactPhase: true, titleLimit: nil, minTitleWidth: nil)
                }
            }
            .padding(.leading, theme.z(20))
            .padding(.trailing, theme.z(20) + trailingInset)
            .frame(height: 52)
            if let goal = engine.state.goal {
                RoomGoalBar(engine: engine, goal: goal,
                            waitingOnYou: engine.state.needsUser || !controller.pendingPermissions(in: engine).isEmpty)
                    .padding(.leading, theme.z(20))
                    .padding(.trailing, theme.z(20) + trailingInset)
                    .padding(.bottom, theme.z(8))
            }
        }
        .background(theme.background)
    }

    private func row(compact: Bool, showsCost: Bool, showsMode: Bool, compactPhase: Bool,
                     titleLimit: CGFloat?, minTitleWidth: CGFloat?) -> some View {
        let state = engine.state
        return HStack(spacing: theme.z(compactPhase ? 6 : 10)) {
            title(state.spec.title, limit: titleLimit, minWidth: minTitleWidth, flexible: compact)
            if showsMode {
                HStack(spacing: theme.z(4)) {
                    Image(systemName: state.runMode.symbolName).font(theme.font(size: 10.5))
                    if !compact { Text(state.runMode.label).lineLimit(1) }
                }
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, theme.z(7))
                .frame(height: theme.z(20))
                .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).strokeBorder(theme.border))
                .help(state.runMode.label)
                .fixedSize()
            }
            phase(compact: compactPhase).fixedSize()
            if showsCost {
                Text(Format.usd(state.totalUsage.costUSD))
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .help("\(Format.tokens(state.totalUsage.inputTokens + state.totalUsage.outputTokens)) tokens across the room")
                    .fixedSize()
            }
            Spacer(minLength: theme.z(compactPhase ? 6 : 12))
            controls(compact: compact).fixedSize()
        }
    }

    @ViewBuilder private func title(_ text: String, limit: CGFloat?, minWidth: CGFloat?, flexible: Bool) -> some View {
        let label = Text(text)
            .font(theme.font(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .help(text)
        if let minWidth {
            label.truncationMode(.tail).frame(minWidth: minWidth, alignment: .leading)
        } else if flexible {
            label.truncationMode(.tail)
        } else if let limit {
            label.truncationMode(.tail).frame(maxWidth: limit, alignment: .leading)
        } else {
            label.fixedSize()
        }
    }

    private func phase(compact: Bool) -> some View {
        let state = engine.state
        let info = phaseInfo(state, compact: compact)
        return HStack(spacing: theme.z(6)) {
            if state.isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.warning)
            } else if state.pendingDecision != nil || state.phase == .verdict {
                Circle()
                    .fill(theme.accent)
                    .frame(width: theme.z(6), height: theme.z(6))
            } else if state.phase.isRunning {
                Spinner(size: 10, color: theme.accent)
            }
            Text(info.text)
                .foregroundStyle(info.color)
                .lineLimit(1)
        }
        .font(theme.font(size: 12, weight: info.pill ? .medium : .regular).monospacedDigit())
        .padding(.horizontal, info.pill ? theme.z(8) : 0)
        .frame(height: info.pill ? theme.z(20) : nil)
        .background {
            if info.pill {
                Capsule().fill(info.pillFill)
            }
        }
        .help(state.phase.label)
    }

    private func phaseInfo(_ state: RoomState, compact: Bool) -> (text: String, color: Color, pill: Bool, pillFill: Color) {
        if state.isPaused {
            return ("Paused", theme.warning, true, theme.warning.opacity(theme.isDark ? 0.14 : 0.12))
        }
        if state.pendingDecision != nil {
            return ("Needs you", theme.accent, true, theme.accent.opacity(theme.isDark ? 0.15 : 0.11))
        }
        if state.phase == .verdict {
            return (state.phase.label, theme.accent, true, theme.accent.opacity(theme.isDark ? 0.15 : 0.11))
        }
        if state.phase == .debating, let debate = state.debate {
            let label = compact ? "R\(min(debate.round, debate.totalRounds))/\(debate.totalRounds)" : "Round \(min(debate.round, debate.totalRounds))/\(debate.totalRounds)"
            return (label, theme.textSecondary, true, theme.hover)
        }
        if state.phase == .discussing, let rt = state.roundTable {
            let label = compact ? "R\(min(rt.round, rt.maxRounds))/\(rt.maxRounds)" : "Round \(min(rt.round, rt.maxRounds))/\(rt.maxRounds)"
            return (label, theme.textSecondary, true, theme.hover)
        }
        if state.phase == .working, !state.assignments.isEmpty {
            let done = state.assignments.filter { [.approved, .merged].contains($0.status) }.count
            let label = compact ? "\(done)/\(state.assignments.count)" : "Working \(done)/\(state.assignments.count)"
            return (label, theme.textSecondary, true, theme.hover)
        }
        if state.phase.isRunning {
            return (state.phase.label, theme.textSecondary, false, .clear)
        }
        return (state.phase.label, theme.textTertiary, false, .clear)
    }

    @ViewBuilder private func controls(compact: Bool) -> some View {
        let state = engine.state
        HStack(spacing: theme.z(6)) {
            if state.goal?.isActive != true {
                GoalButton(engine: engine, compact: compact)
            }
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
    /// Follow mode's switch; nil hides it (no side panel, or one agent).
    var follow: Binding<Bool>?
    /// Board filter toggle; nil hides it.
    var filterOpen: Binding<Bool>? = nil
    var filterActive: Bool = false
    var onFilterAgent: ((UUID) -> Void)? = nil
    var onJumpToLatest: ((UUID) -> Void)? = nil
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
                                  selected: selectedAgentID == agent.id,
                                  onOpenTranscript: { selectedAgentID = agent.id },
                                  onFilterAgent: onFilterAgent.map { cb in { cb(agent.id) } },
                                  onJumpToLatest: onJumpToLatest.map { cb in { cb(agent.id) } }) {
                            selectedAgentID = selectedAgentID == agent.id ? nil : agent.id
                        }
                    }
                }
                .padding(.vertical, theme.z(1))
            }
            .scrollIndicators(.never)
            if let filterOpen {
                BoardFilterToggle(isOpen: filterOpen, isActive: filterActive)
                    .fixedSize()
            }
            if let follow {
                FollowToggle(isOn: follow)
                    .fixedSize()
            }
            if showsTabs {
                RoomTabs(tab: $tab)
                    .fixedSize()
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
    var onOpenTranscript: (() -> Void)? = nil
    var onFilterAgent: (() -> Void)? = nil
    var onJumpToLatest: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let agentColor = Color(hexString: agent.colorHex)
        Button(action: action) {
            HStack(spacing: theme.z(6)) {
                AgentDot(hex: agent.colorHex, size: 8)
                Text(agent.name)
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(model)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                if isLead { RoomTag(text: leadLabel, color: theme.accent) }
                ActivityBadge(activity: activity, color: agentColor)
            }
            .padding(.horizontal, theme.z(10))
            .frame(height: theme.z(28))
            .background(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                    .fill(selected ? agentColor.opacity(theme.isDark ? 0.14 : 0.10) : (hovering ? theme.elevatedHover : theme.elevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                    .strokeBorder(selected ? agentColor.opacity(0.85) : theme.border, lineWidth: selected ? theme.z(1.5) : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .contextMenu {
            if onFilterAgent != nil || onJumpToLatest != nil {
                Button("Open transcript") { (onOpenTranscript ?? action)() }
                if let onFilterAgent {
                    Button("Filter board to \(agent.name)", action: onFilterAgent)
                }
                if let onJumpToLatest {
                    Button("Jump to latest message", action: onJumpToLatest)
                }
            }
        }
        .help("\(agent.name): \(activity.label). Click to see its session.")
        .accessibilityLabel("\(agent.name), \(model), \(activity.label)")
    }
}

/// Compact toggle button in `AgentChipRow` for opening and closing the board filter bar.
private struct BoardFilterToggle: View {
    @Binding var isOpen: Bool
    let isActive: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let highlighted = isOpen || isActive
        Button {
            withAnimation(.easeOut(duration: 0.14)) { isOpen.toggle() }
        } label: {
            HStack(spacing: theme.z(5)) {
                Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(theme.font(size: 11.5))
                Text("Filter")
                    .font(theme.font(size: 12, weight: .medium))
                if isActive {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: theme.z(5), height: theme.z(5))
                }
            }
            .foregroundStyle(isActive ? theme.accent : (highlighted || hovering ? theme.textPrimary : theme.textSecondary))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(26))
            .background(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .fill(isActive ? theme.accent.opacity(0.13) : (highlighted ? theme.selection : (hovering ? theme.elevatedHover : theme.elevated)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .strokeBorder(isActive ? theme.accent.opacity(0.45) : theme.border)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOpen ? "Hide board filter" : "Filter board messages (Command-F)")
        .accessibilityLabel("Filter board")
        .accessibilityValue(isActive ? "Active" : (isOpen ? "Open" : "Off"))
    }
}

/// Compact filter bar below `AgentChipRow` for filtering room board messages by category, agent, or search text.
private struct RoomBoardFilterBar: View {
    @Binding var filter: RoomBoardFilter
    let agents: [AgentSpec]
    let messages: [BoardMessage]
    let filteredCount: Int
    let focusToken: Int
    let onJumpToAgent: (UUID) -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        let counts = RoomBoardFilter.messageCountsByAgent(in: messages)
        VStack(alignment: .leading, spacing: theme.z(7)) {
            HStack(spacing: theme.z(8)) {
                HStack(spacing: theme.z(6)) {
                    Image(systemName: "magnifyingglass")
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.textTertiary)
                    TextField("", text: $filter.query, prompt: Text("Filter board").foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.plain)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textPrimary)
                        .focused($searchFocused)
                        .onExitCommand {
                            if !filter.query.isEmpty {
                                filter.query = ""
                            } else if !filter.isActive {
                                onClose()
                            } else {
                                searchFocused = false
                            }
                        }
                    if !filter.query.isEmpty {
                        Button {
                            filter.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(theme.font(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search text")
                    }
                }
                .padding(.horizontal, theme.z(8))
                .frame(height: theme.z(26))
                .frame(minWidth: theme.z(140), maxWidth: theme.z(240))
                .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .strokeBorder(searchFocused ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1))

                AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                    HStack(spacing: theme.z(4)) {
                        ForEach(RoomBoardCategory.allCases) { category in
                            RoomFilterCategoryPill(
                                label: category.label,
                                selected: filter.category == category
                            ) {
                                filter.category = category
                            }
                        }
                    }
                }
                .scrollIndicators(.never)

                Spacer(minLength: theme.z(4))

                if filter.isActive {
                    Text("Showing \(filteredCount) of \(messages.count)")
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                    Button {
                        filter.clear()
                    } label: {
                        Text("Clear")
                            .font(theme.font(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, theme.z(7))
                            .frame(height: theme.z(22))
                            .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(theme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Clear all board filters")
                } else {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: theme.z(22), height: theme.z(22))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide filter bar")
                }
            }

            if !agents.isEmpty {
                AdaptiveScroll(.horizontal, snapshotAlignment: .leading) {
                    HStack(spacing: theme.z(5)) {
                        RoomFilterAgentAllPill(selected: filter.agentID == nil) {
                            filter.agentID = nil
                        }
                        ForEach(agents) { agent in
                            let count = counts[agent.id] ?? 0
                            RoomFilterAgentPill(
                                agent: agent,
                                count: count,
                                selected: filter.agentID == agent.id,
                                onToggle: {
                                    filter.agentID = filter.agentID == agent.id ? nil : agent.id
                                },
                                onJump: count > 0 ? { onJumpToAgent(agent.id) } : nil
                            )
                        }
                    }
                    .padding(.vertical, theme.z(1))
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, theme.z(20))
        .padding(.bottom, theme.z(8))
        .onChange(of: focusToken) {
            searchFocused = true
        }
        .onAppear {
            if focusToken > 0 { searchFocused = true }
        }
    }
}

private struct RoomFilterCategoryPill: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(theme.font(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? theme.textPrimary : (hovering ? theme.textPrimary : theme.textSecondary))
                .lineLimit(1)
                .padding(.horizontal, theme.z(8))
                .frame(height: theme.z(24))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(selected ? theme.selection : (hovering ? theme.hover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .strokeBorder(selected ? theme.border : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

private struct RoomFilterAgentAllPill: View {
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("All agents")
                .font(theme.font(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? theme.textPrimary : (hovering ? theme.textPrimary : theme.textSecondary))
                .lineLimit(1)
                .padding(.horizontal, theme.z(8))
                .frame(height: theme.z(24))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(selected ? theme.selection : (hovering ? theme.elevatedHover : theme.elevated))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .strokeBorder(selected ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

private struct RoomFilterAgentPill: View {
    let agent: AgentSpec
    let count: Int
    let selected: Bool
    let onToggle: () -> Void
    let onJump: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var jumpHovering = false

    var body: some View {
        let agentColor = Color(hexString: agent.colorHex)
        HStack(spacing: theme.z(4)) {
            Button(action: onToggle) {
                HStack(spacing: theme.z(5)) {
                    AgentDot(hex: agent.colorHex, size: 7)
                    Text(agent.name)
                        .font(theme.font(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text("\(count)")
                        .font(theme.font(size: 10.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selected ? "Show all agents" : "Filter board to \(agent.name)")

            if let onJump, selected || hovering {
                Button(action: onJump) {
                    Image(systemName: "arrow.down.to.line")
                        .font(theme.font(size: 9.5, weight: .semibold))
                        .foregroundStyle(jumpHovering ? theme.accent : theme.textSecondary)
                        .frame(width: theme.z(18), height: theme.z(18))
                        .background(
                            RoundedRectangle(cornerRadius: theme.z(4), style: .continuous)
                                .fill(jumpHovering ? theme.accent.opacity(0.14) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { jumpHovering = $0 }
                .help("Jump to \(agent.name)'s latest message")
                .accessibilityLabel("Jump to \(agent.name)'s latest message")
            }
        }
        .padding(.leading, theme.z(8))
        .padding(.trailing, (onJump != nil && (selected || hovering)) ? theme.z(4) : theme.z(8))
        .frame(height: theme.z(24))
        .background(
            RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                .fill(selected ? agentColor.opacity(theme.isDark ? 0.16 : 0.11) : (hovering ? theme.elevatedHover : theme.elevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                .strokeBorder(selected ? agentColor.opacity(0.7) : theme.border, lineWidth: 1)
        )
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// Board / Rounds switch.
private struct RoomTabs: View {
    @Binding var tab: RoomTab
    @Environment(\.theme) private var theme
    @State private var hoveredTab: RoomTab?

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
        let selected = tab == value
        let hovered = hoveredTab == value
        return Button { tab = value } label: {
            Text(title)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(selected || hovered ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, theme.z(10))
                .frame(height: theme.z(22))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(selected ? theme.raisedSelection : (hovered ? theme.raisedHover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? value : (hoveredTab == value ? nil : hoveredTab) }
        .animation(.easeOut(duration: 0.12), value: hoveredTab)
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
        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: theme.z(10), y: theme.z(3))
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
                        .fill(index == 0 ? theme.raisedSelection : theme.raisedFill))
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
        // `/goal <condition>`, `/goal stop` and `/goal` are the room's own command.
        if let command = SlashCommands.parse(text), command.name.lowercased() == "goal" {
            Task { await engine.runGoalCommand(command.arguments) }
            return
        }
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
                    .lineLimit(1)
            }
            .help("Spend across the room's agents")
            Spacer(minLength: theme.z(8))
            HStack(spacing: theme.z(5)) {
                Image(systemName: state.spec.permissionMode.symbolName).font(theme.font(size: 10.5))
                Text(state.spec.permissionMode.label)
                    .lineLimit(1)
            }
            .fixedSize()
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
    @State private var resumeHovered = false

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
            Button(action: resume) {
                Text("Resume")
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, theme.z(8))
                    .padding(.vertical, theme.z(4))
                    .background(
                        RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                            .fill(resumeHovered ? theme.accent.opacity(theme.isDark ? 0.18 : 0.12) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { resumeHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: resumeHovered)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(8))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.warning.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.warning.opacity(0.3)))
    }
}
