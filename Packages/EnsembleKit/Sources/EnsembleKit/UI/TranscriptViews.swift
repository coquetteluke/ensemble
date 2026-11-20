import SwiftUI

/// What transcript rows can ask the app to do. Set with `.environment(\.transcriptActions, ...)`.
public struct TranscriptActions: Sendable {
    public var openSession: @MainActor @Sendable (String) -> Void
    public var replyPermission: @MainActor @Sendable (PermissionRequest, PermissionDecision) -> Void
    /// Fork, rewind and edit-and-resend from one of your messages (by message id).
    public var fork: @MainActor @Sendable (String) -> Void
    public var rewind: @MainActor @Sendable (String) -> Void
    public var edit: @MainActor @Sendable (String) -> Void
    /// False when the engine cannot fork or rewind; the buttons stay visible but disabled.
    public var historySupported: Bool
    /// The agent's name while it is working; rewind and edit wait until it stops.
    public var workingAgentName: String?
    /// The prompt that answers to Command-Y (Allow once), Option-Command-Y (Always allow) and
    /// Command-period (Reject): the newest open one in the session on screen.
    public var shortcutPermissionID: String?
    /// Current session id shown in the transcript, for exchange card perspective and anchors.
    public var currentSessionID: String?
    /// Cross-session exchanges (`message_agent`, `ask_agent`) visible in this session.
    public var agentExchanges: [AgentExchange]
    /// Inline second opinions keyed by transcript item id.
    public var secondOpinions: [String: [SecondOpinion]]
    /// Available models for the Second opinion menu (other makers ordered first).
    public var secondOpinionModels: [SecondOpinionModelOption]
    /// True when the Second opinion action bar should appear on completed assistant replies.
    public var canShowSecondOpinion: Bool
    public var requestSecondOpinion: @MainActor @Sendable (_ itemID: String, _ replyText: String, _ model: ModelRef) -> Void
    public var retrySecondOpinion: @MainActor @Sendable (SecondOpinion) -> Void
    public var dismissSecondOpinion: @MainActor @Sendable (SecondOpinion) -> Void
    public var dismissAgentExchange: @MainActor @Sendable (AgentExchange) -> Void

    public init(openSession: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                replyPermission: @escaping @MainActor @Sendable (PermissionRequest, PermissionDecision) -> Void = { _, _ in },
                fork: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                rewind: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                edit: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                historySupported: Bool = false,
                workingAgentName: String? = nil,
                shortcutPermissionID: String? = nil,
                currentSessionID: String? = nil,
                agentExchanges: [AgentExchange] = [],
                secondOpinions: [String: [SecondOpinion]] = [:],
                secondOpinionModels: [SecondOpinionModelOption] = [],
                canShowSecondOpinion: Bool = false,
                requestSecondOpinion: @escaping @MainActor @Sendable (_ itemID: String, _ replyText: String, _ model: ModelRef) -> Void = { _, _, _ in },
                retrySecondOpinion: @escaping @MainActor @Sendable (SecondOpinion) -> Void = { _ in },
                dismissSecondOpinion: @escaping @MainActor @Sendable (SecondOpinion) -> Void = { _ in },
                dismissAgentExchange: @escaping @MainActor @Sendable (AgentExchange) -> Void = { _ in }) {
        self.openSession = openSession
        self.replyPermission = replyPermission
        self.fork = fork
        self.rewind = rewind
        self.edit = edit
        self.historySupported = historySupported
        self.workingAgentName = workingAgentName
        self.shortcutPermissionID = shortcutPermissionID
        self.currentSessionID = currentSessionID
        self.agentExchanges = agentExchanges
        self.secondOpinions = secondOpinions
        self.secondOpinionModels = secondOpinionModels
        self.canShowSecondOpinion = canShowSecondOpinion
        self.requestSecondOpinion = requestSecondOpinion
        self.retrySecondOpinion = retrySecondOpinion
        self.dismissSecondOpinion = dismissSecondOpinion
        self.dismissAgentExchange = dismissAgentExchange
    }

    public static let none = TranscriptActions()
}

public extension EnvironmentValues {
    @Entry var transcriptActions: TranscriptActions = .none
    /// Forces a view mode (snapshots); nil uses the saved setting (`TranscriptViewMode.storageKey`).
    @Entry var transcriptViewMode: TranscriptViewMode? = nil
    /// A message to scroll to and flash, set when a search result is opened.
    @Entry var transcriptFocus: TranscriptFocus? = nil
    /// Persistent row highlights while live Find-in-Transcript is open.
    @Entry var transcriptFindHighlight: TranscriptFindHighlight? = nil
}

/// How much of a transcript is shown. Control-O cycles through them; the choice is saved.
public enum TranscriptViewMode: String, CaseIterable, Identifiable, Sendable {
    /// Tool calls collapsed into activity groups, thinking collapsed.
    case normal
    /// Thinking shown in full between the tool calls.
    case thinking
    /// Every tool call on its own row, opened, with its full output. No activity groups.
    case verbose

    public static let storageKey = "transcriptViewMode"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .thinking: "Thinking"
        case .verbose: "Verbose"
        }
    }

    /// One line on what the mode shows.
    public var summary: String {
        switch self {
        case .normal: "Tool calls grouped, thinking collapsed"
        case .thinking: "Thinking shown in full"
        case .verbose: "Every tool call opened, with full output"
        }
    }

    public var symbol: String {
        switch self {
        case .normal: "text.alignleft"
        case .thinking: "lightbulb"
        case .verbose: "list.bullet.rectangle"
        }
    }

    public var next: TranscriptViewMode {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    /// The saved mode.
    public static func saved(_ defaults: UserDefaults = .standard) -> TranscriptViewMode {
        defaults.string(forKey: storageKey).flatMap(TranscriptViewMode.init(rawValue:)) ?? .normal
    }

    /// Saves the next mode (Control-O). Views reading `@AppStorage(TranscriptViewMode.storageKey)` follow.
    @discardableResult
    public static func cycle(_ defaults: UserDefaults = .standard) -> TranscriptViewMode {
        let next = saved(defaults).next
        defaults.set(next.rawValue, forKey: storageKey)
        return next
    }

    /// Rows as drawn in this mode.
    public func blocks(_ items: [TranscriptItem], resolutions: [String: PermissionResolution]) -> [TranscriptBlock] {
        switch self {
        case .normal:
            return TranscriptGrouping.blocks(items, resolutions: resolutions)
        case .thinking:
            // Thinking stands on its own row, so groups form only from the tool calls between thoughts.
            var blocks: [TranscriptBlock] = []
            var segment: [TranscriptItem] = []
            for item in items {
                if case .reasoning = item {
                    blocks += TranscriptGrouping.blocks(segment, resolutions: resolutions)
                    segment.removeAll()
                    blocks.append(.single(item))
                } else {
                    segment.append(item)
                }
            }
            return blocks + TranscriptGrouping.blocks(segment, resolutions: resolutions)
        case .verbose:
            return items.map { .single($0) }
        }
    }
}

/// A message to bring into view. `token` changes for every request, so opening the same result twice scrolls twice.
public struct TranscriptFocus: Equatable, Sendable {
    public var sessionID: String
    public var itemID: String
    public var token: Int

    public init(sessionID: String, itemID: String, token: Int) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.token = token
    }
}

/// All rows of a transcript, spaced like the reference app. The caller provides the scroll container.
public struct TranscriptList: View {
    let items: [TranscriptItem]
    let resolutions: [String: PermissionResolution]
    let agents: [UUID: AgentSpec]
    let onRetry: (() -> Void)?
    let onContinueWithModel: ((ModelRef) -> Void)?
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.theme) private var theme
    @Environment(\.transcriptViewMode) private var forcedMode
    @Environment(\.transcriptFocus) private var focus
    @Environment(\.transcriptFindHighlight) private var findHighlight
    @Environment(\.transcriptActions) private var actions
    @AppStorage(TranscriptViewMode.storageKey) private var savedMode = TranscriptViewMode.normal.rawValue
    @State private var appliedFocusToken: Int?
    @State private var highlightedBlockID: String?

    public init(
        items: [TranscriptItem],
        resolutions: [String: PermissionResolution] = [:],
        agents: [UUID: AgentSpec] = [:],
        onRetry: (() -> Void)? = nil,
        onContinueWithModel: ((ModelRef) -> Void)? = nil
    ) {
        self.items = items
        self.resolutions = resolutions
        self.agents = agents
        self.onRetry = onRetry
        self.onContinueWithModel = onContinueWithModel
    }

    private var mode: TranscriptViewMode { forcedMode ?? TranscriptViewMode(rawValue: savedMode) ?? .normal }

    public var body: some View {
        let blocks = mode.blocks(items, resolutions: resolutions)
        if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { rows(blocks) }
                .environment(\.transcriptViewMode, mode)
        } else {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 0) { rows(blocks) }
                    // Rows keep their own open or closed state; a new mode starts them over.
                    .id(mode)
                    .environment(\.transcriptViewMode, mode)
                    .onAppear {
                        applyFocus(blocks, proxy: proxy)
                        scrollToActiveFindMatch(blocks, proxy: proxy)
                    }
                    .onChange(of: focus) { applyFocus(blocks, proxy: proxy) }
                    .onChange(of: findHighlight?.activeItemID) { scrollToActiveFindMatch(blocks, proxy: proxy) }
                    .onChange(of: findHighlight?.scrollToken) { scrollToActiveFindMatch(blocks, proxy: proxy) }
                    .onChange(of: items.count) { applyFocus(blocks, proxy: proxy) }
            }
        }
    }

    private func rows(_ blocks: [TranscriptBlock]) -> some View {
        let partitioned = partitionExchanges(blocks)
        let modelLabels = switchedModelLabels()
        let latestReply = latestReplyID()
        let retryError = retryableErrorID()
        return Group {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                let previous = index > 0 ? blocks[index - 1] : nil
                let attached = partitioned.anchored[block.id] ?? []
                VStack(alignment: .leading, spacing: theme.z(10)) {
                    Group {
                        switch block {
                        case .single(let item):
                            TranscriptItemView(
                                item: item,
                                previous: previous?.lastItem,
                                resolution: resolutions[item.id],
                                agents: agents,
                                modelLabel: modelLabels[item.id],
                                isLatestReply: item.id == latestReply,
                                onRetry: item.id == retryError ? onRetry : nil,
                                onContinueWithModel: onContinueWithModel
                            )
                        case .activity(_, let steps):
                            ActivityGroupView(items: steps, resolutions: resolutions)
                        }
                    }
                    ForEach(attached) { exchange in
                        exchangeCard(exchange)
                    }
                }
                .background {
                    let isActiveFind = findHighlight?.activeItemID.map { block.contains(itemID: $0) } ?? false
                    let isMatchedFind = !isActiveFind && (findHighlight?.matchedItemIDs.contains { block.contains(itemID: $0) } ?? false)
                    if highlightedBlockID == block.id || isActiveFind {
                        RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                            .fill(theme.accent.opacity(theme.isDark ? 0.16 : 0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                                    .strokeBorder(theme.accent.opacity(isActiveFind ? 0.55 : 0.0), lineWidth: 1)
                            )
                            .padding(.horizontal, -theme.z(10))
                            .padding(.vertical, -theme.z(6))
                            .transition(.opacity)
                    } else if isMatchedFind {
                        RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                            .fill(theme.accent.opacity(theme.isDark ? 0.07 : 0.05))
                            .padding(.horizontal, -theme.z(10))
                            .padding(.vertical, -theme.z(6))
                            .transition(.opacity)
                    }
                }
                .id(block.id)
                .padding(.top, index == 0 ? 0 : spacing(before: block, after: previous))
            }

            if !partitioned.trailing.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(10)) {
                    ForEach(partitioned.trailing) { exchange in
                        exchangeCard(exchange)
                    }
                }
                .padding(.top, blocks.isEmpty ? 0 : theme.z(12))
            }
        }
    }

    /// Maps the first assistant reply after each mid-chat model switch notice to the switched model's name.
    private func switchedModelLabels() -> [String: String] {
        var labels: [String: String] = [:]
        var pendingModel: String?
        for item in items {
            switch item {
            case .notice(_, let text):
                if let switched = TranscriptExport.switchedModelName(fromNotice: text) {
                    pendingModel = switched
                }
            case .agentText(let id, let text, let agentID, _):
                guard agentID == nil,
                      let model = pendingModel,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                labels[id] = model
                pendingModel = nil
            default:
                continue
            }
        }
        return labels
    }

    private func latestReplyID() -> String? {
        for item in items.reversed() {
            if case .agentText(let id, let text, _, _) = item,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return id
            }
        }
        return nil
    }

    private func retryableErrorID() -> String? {
        guard onRetry != nil, !isTranscriptWorking else { return nil }
        for item in items.reversed() {
            switch item {
            case .error(let id, _):
                return id
            case .user, .agentText, .board:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private var isTranscriptWorking: Bool {
        if actions.workingAgentName != nil { return true }
        return items.contains { item in
            switch item {
            case .agentText(_, _, _, let streaming): streaming
            case .reasoning(_, _, let streaming): streaming
            case .tool(let tool): tool.status == .running || tool.status == .pending
            default: false
            }
        }
    }

    private func partitionExchanges(_ blocks: [TranscriptBlock]) -> (anchored: [String: [AgentExchange]], trailing: [AgentExchange]) {
        guard !actions.agentExchanges.isEmpty, let sessionID = actions.currentSessionID else {
            return ([:], [])
        }
        var anchored: [String: [AgentExchange]] = [:]
        var trailing: [AgentExchange] = []
        for exchange in actions.agentExchanges {
            if let itemID = exchange.anchors[sessionID],
               let block = blocks.first(where: { $0.contains(itemID: itemID) }) {
                anchored[block.id, default: []].append(exchange)
            } else {
                trailing.append(exchange)
            }
        }
        return (anchored, trailing)
    }

    private func exchangeCard(_ exchange: AgentExchange) -> some View {
        let sessionID = actions.currentSessionID ?? ""
        return AgentExchangeCardView(
            exchange: exchange,
            currentSessionID: sessionID,
            onOpenTarget: { targetID in actions.openSession(targetID) },
            onDismiss: { actions.dismissAgentExchange(exchange) }
        )
    }

    /// Scrolls to the active Find-in-Transcript match without flashing or clearing its highlight.
    private func scrollToActiveFindMatch(_ blocks: [TranscriptBlock], proxy: ScrollViewProxy) {
        guard let activeID = findHighlight?.activeItemID,
              let block = blocks.first(where: { $0.contains(itemID: activeID) }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(block.id, anchor: .center)
        }
    }

    /// Scrolls to the focused message once it is loaded, then flashes its row.
    private func applyFocus(_ blocks: [TranscriptBlock], proxy: ScrollViewProxy) {
        guard let focus, focus.token != appliedFocusToken,
              let block = blocks.first(where: { $0.contains(itemID: focus.itemID) }) else { return }
        appliedFocusToken = focus.token
        let target = block.id
        Task { @MainActor in
            // Let the conversation finish its own scroll to the newest message first.
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo(target, anchor: .center)
            try? await Task.sleep(for: .milliseconds(80))
            proxy.scrollTo(target, anchor: .center)
            withAnimation(.easeOut(duration: 0.2)) { highlightedBlockID = target }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.6)) {
                if highlightedBlockID == target { highlightedBlockID = nil }
            }
        }
    }

    private func kind(_ block: TranscriptBlock) -> TranscriptRowKind {
        switch block {
        case .activity: return .tool
        case .single(let item):
            if case .permission(let request) = item, resolutions[item.id] != nil, !request.isInteraction { return .resolvedPermission }
            return item.kind
        }
    }

    /// Steps sit close together; everything else gets room to breathe. Your messages carry their own
    /// hover toolbar underneath, which takes most of the gap after them.
    private func spacing(before block: TranscriptBlock, after previous: TranscriptBlock?) -> CGFloat {
        guard let previous else { return 0 }
        switch (kind(previous), kind(block)) {
        case (.user, _): return theme.z(2)
        case (.tool, .tool), (.tool, .resolvedPermission), (.resolvedPermission, .tool): return theme.z(6)
        case (.reasoning, .tool), (.tool, .reasoning): return theme.z(8)
        case (_, .user): return theme.z(22)
        default: return theme.z(14)
        }
    }
}

extension TranscriptBlock {
    /// The newest item in the block (used to decide whether a room message repeats its agent name).
    var lastItem: TranscriptItem? {
        switch self {
        case .single(let item): item
        case .activity(_, let items): items.last
        }
    }

    /// True when the item is this row or one of its steps.
    public func contains(itemID: String) -> Bool {
        switch self {
        case .single(let item): item.id == itemID
        case .activity(_, let items): items.contains { $0.id == itemID }
        }
    }
}

enum TranscriptRowKind {
    case user, text, reasoning, tool, card, resolvedPermission, other
}

extension TranscriptItem {
    var kind: TranscriptRowKind {
        switch self {
        case .user: .user
        case .agentText: .text
        case .reasoning: .reasoning
        case .tool(let tool): ToolCategory(tool.name) == .subagent ? .card : .tool
        case .permission: .card
        case .board: .card
        case .error, .notice: .other
        }
    }
}

/// One transcript row.
public struct TranscriptItemView: View {
    let item: TranscriptItem
    let previous: TranscriptItem?
    let resolution: PermissionResolution?
    let agents: [UUID: AgentSpec]
    let modelLabel: String?
    let isLatestReply: Bool
    let onRetry: (() -> Void)?
    let onContinueWithModel: ((ModelRef) -> Void)?
    @Environment(\.transcriptViewMode) private var mode
    /// Knows which error rows are plan limit stops (`AutoContinue.swift`).
    @Environment(\.interactionStore) private var store

    public init(
        item: TranscriptItem,
        previous: TranscriptItem? = nil,
        resolution: PermissionResolution? = nil,
        agents: [UUID: AgentSpec] = [:],
        modelLabel: String? = nil,
        isLatestReply: Bool = false,
        onRetry: (() -> Void)? = nil,
        onContinueWithModel: ((ModelRef) -> Void)? = nil
    ) {
        self.item = item
        self.previous = previous
        self.resolution = resolution
        self.agents = agents
        self.modelLabel = modelLabel
        self.isLatestReply = isLatestReply
        self.onRetry = onRetry
        self.onContinueWithModel = onContinueWithModel
    }

    public var body: some View {
        switch item {
        case .user(let id, let text, let date):
            UserBubble(id: id, text: text, date: date)
        case .agentText(let id, let text, let agentID, let streaming):
            AgentTextRow(
                itemID: id,
                text: text,
                agent: agentID.flatMap { agents[$0] },
                showHeader: showsAgentHeader(agentID),
                streaming: streaming,
                modelLabel: modelLabel,
                isLatestReply: isLatestReply,
                onContinueWithModel: onContinueWithModel
            )
        case .reasoning(let id, let text, let streaming):
            ReasoningRow(id: id, text: text, streaming: streaming, expanded: (mode ?? .normal) != .normal)
        case .tool(let tool):
            if ToolCategory(tool.name) == .subagent {
                SubagentCardView(tool: tool)
            } else {
                ToolCardView(tool: tool, expanded: mode == .verbose)
            }
        case .permission(let request):
            PermissionCardView(request: request, resolution: resolution)
        case .board(_, let from, let to, let text, _):
            BoardRow(from: agents[from], to: to.compactMap { agents[$0] }, text: text)
        case .error(let id, let message):
            if let stop = store?.usageLimitStop(forItem: id) {
                UsageLimitCard(stop: stop)
            } else {
                ErrorRow(message: message, onRetry: onRetry)
            }
        case .notice(let id, let text):
            if let store, let notice = store.rewindNotice(forItem: id) {
                RewindNoticeRow(notice: notice, redoUnavailableReason: store.redoUnavailableReason(notice)) {
                    Task { await store.redoRewind(noticeID: id) }
                }
            } else {
                NoticeRow(text: text)
            }
        }
    }

    private func showsAgentHeader(_ agentID: UUID?) -> Bool {
        guard let agentID else { return false }
        if case .agentText(_, _, let previousAgent, _) = previous { return previousAgent != agentID }
        return true
    }
}

/// The user's message, right-aligned in a soft bubble. Hovering near it shows when it was sent and
/// Fork from here, Rewind, Edit and Copy.
public struct UserBubble: View {
    let id: String
    let text: String
    let date: Date?
    /// Snapshots draw the toolbar without hovering.
    var alwaysShowActions: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    public init(id: String = "", text: String, date: Date? = nil, alwaysShowActions: Bool = false) {
        self.id = id
        self.text = text
        self.date = date
        self.alwaysShowActions = alwaysShowActions
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: theme.z(4)) {
            bubble
            MessageActionBar(id: id, text: text, date: date)
                .opacity(hovering || alwaysShowActions ? 1 : 0)
                .allowsHitTesting(hovering || alwaysShowActions)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        HStack {
            Spacer(minLength: theme.z(72))
            Text(text)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(theme.z(3))
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
                .padding(.horizontal, theme.z(14))
                .padding(.vertical, theme.z(9))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(14), style: .continuous)
                        .fill(theme.userBubble)
                )
        }
    }
}

/// Sent time and Fork / Rewind / Edit / Copy under one of your messages.
struct MessageActionBar: View {
    let id: String
    let text: String
    let date: Date?
    @Environment(\.theme) private var theme
    @Environment(\.transcriptActions) private var actions
    @State private var copied = false

    static let exactFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: theme.z(2)) {
            if let date {
                let relative = Format.relative(date)
                Text(relative == "now" ? "Just now" : "\(relative) ago")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.trailing, theme.z(4))
                    .help(Self.exactFormat.string(from: date))
            }
            MessageActionButton(symbol: "arrow.triangle.branch", help: forkHelp, enabled: actions.historySupported) {
                actions.fork(id)
            }
            MessageActionButton(symbol: "arrow.counterclockwise", help: rewindHelp, enabled: canChangeHistory) {
                actions.rewind(id)
            }
            MessageActionButton(symbol: "pencil", help: editHelp, enabled: canChangeHistory) {
                actions.edit(id)
            }
            MessageActionButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy", enabled: true) {
                copyToPasteboard(text)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
        .frame(height: theme.z(22))
    }

    private var canChangeHistory: Bool { actions.historySupported && actions.workingAgentName == nil }

    private var forkHelp: String {
        actions.historySupported ? "Fork from here" : "This engine does not support forking"
    }

    private var rewindHelp: String {
        if !actions.historySupported { return "This engine does not support rewinding" }
        if let name = actions.workingAgentName { return "Rewind is unavailable while \(name) is working" }
        return "Rewind to before this message"
    }

    private var editHelp: String {
        if !actions.historySupported { return "This engine does not support editing messages" }
        if let name = actions.workingAgentName { return "Edit is unavailable while \(name) is working" }
        return "Edit and resend"
    }
}

/// Small icon button. When disabled it stays hoverable so its tooltip can say why.
struct MessageActionButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            if enabled { action() }
        } label: {
            Image(systemName: symbol)
                .font(theme.font(size: 11.5))
                .foregroundStyle(enabled ? (hovering ? theme.textPrimary : theme.textSecondary) : theme.textTertiary.opacity(0.6))
                .frame(width: theme.z(24), height: theme.z(22))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(hovering && enabled ? theme.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(enabled ? [] : .isStaticText)
    }
}

/// Agent Markdown. In rooms it starts with the agent's colour dot and name.
public struct AgentTextRow: View {
    let itemID: String
    let text: String
    let agent: AgentSpec?
    let showHeader: Bool
    let streaming: Bool
    let modelLabel: String?
    let isLatestReply: Bool
    let onContinueWithModel: ((ModelRef) -> Void)?
    @Environment(\.theme) private var theme
    @Environment(\.transcriptActions) private var actions
    @State private var hovering = false
    @State private var secondOpinionHovered = false
    @State private var copied = false
    @State private var showModelPicker = false

    public init(
        itemID: String = "",
        text: String,
        agent: AgentSpec?,
        showHeader: Bool,
        streaming: Bool,
        modelLabel: String? = nil,
        isLatestReply: Bool = false,
        onContinueWithModel: ((ModelRef) -> Void)? = nil
    ) {
        self.itemID = itemID
        self.text = text
        self.agent = agent
        self.showHeader = showHeader
        self.streaming = streaming
        self.modelLabel = modelLabel
        self.isLatestReply = isLatestReply
        self.onContinueWithModel = onContinueWithModel
    }

    public init(text: String, agent: AgentSpec?, showHeader: Bool, streaming: Bool) {
        self.init(itemID: "", text: text, agent: agent, showHeader: showHeader, streaming: streaming)
    }

    public var body: some View {
        let opinions = itemID.isEmpty ? [] : (actions.secondOpinions[itemID] ?? [])
        VStack(alignment: .leading, spacing: theme.z(6)) {
            if showHeader, let agent {
                AgentNameTag(agent: agent)
            } else if let modelLabel, !modelLabel.isEmpty {
                Text(modelLabel)
                    .font(theme.font(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, theme.z(6))
                    .padding(.vertical, theme.z(2))
                    .background(Capsule().fill(theme.codeBackground))
                    .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
                    .accessibilityLabel("Model: \(modelLabel)")
            }
            MarkdownView(text, streaming: streaming)

            if showsActionBar {
                replyActionBar
            }

            if !opinions.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    ForEach(opinions) { opinion in
                        SecondOpinionCardView(
                            opinion: opinion,
                            onRetry: { actions.retrySecondOpinion(opinion) },
                            onDismiss: { actions.dismissSecondOpinion(opinion) },
                            onUseModel: onContinueWithModel
                        )
                    }
                }
                .padding(.top, theme.z(4))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var showsActionBar: Bool {
        actions.canShowSecondOpinion
            && !streaming
            && !itemID.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionBarOpacity: Double {
        if hovering || showModelPicker || copied { return 1 }
        return isLatestReply ? 0.55 : 0
    }

    private var replyActionBar: some View {
        HStack(spacing: theme.z(6)) {
            MessageActionButton(
                symbol: copied ? "checkmark" : "doc.on.doc",
                help: copied ? "Copied" : "Copy reply",
                enabled: true
            ) {
                copyToPasteboard(text)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }

            if !actions.secondOpinionModels.isEmpty {
                secondOpinionTrigger
            }
            Spacer(minLength: 0)
        }
        .opacity(actionBarOpacity)
        .allowsHitTesting(hovering || showModelPicker || copied || isLatestReply)
        .animation(.easeOut(duration: 0.15), value: actionBarOpacity)
    }

    @ViewBuilder
    private var secondOpinionTrigger: some View {
        if actions.secondOpinionModels.count == 1, let sole = actions.secondOpinionModels.first {
            Button {
                actions.requestSecondOpinion(itemID, text, sole.ref)
            } label: {
                secondOpinionLabel(title: "Second opinion (\(sole.name))")
            }
            .buttonStyle(.plain)
            .onHover { secondOpinionHovered = $0 }
            .help("Ask \(sole.name) for a second opinion")
        } else {
            Button {
                showModelPicker.toggle()
            } label: {
                secondOpinionLabel(title: "Second opinion")
            }
            .buttonStyle(.plain)
            .onHover { secondOpinionHovered = $0 }
            .help("Ask another model for a second opinion")
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                SecondOpinionModelPicker(options: actions.secondOpinionModels) { option in
                    showModelPicker = false
                    actions.requestSecondOpinion(itemID, text, option.ref)
                }
            }
        }
    }

    private func secondOpinionLabel(title: String) -> some View {
        HStack(spacing: theme.z(4)) {
            Image(systemName: "text.bubble")
                .font(theme.font(size: 11))
            Text(title)
                .font(theme.font(size: 11.5, weight: .medium))
        }
        .foregroundStyle(secondOpinionHovered || showModelPicker ? theme.textPrimary : theme.textSecondary)
        .padding(.horizontal, theme.z(7))
        .frame(height: theme.z(22))
        .background(
            RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                .fill(theme.hover.opacity(secondOpinionHovered || showModelPicker ? 1 : (hovering ? 0.5 : 0.35)))
        )
        .contentShape(Rectangle())
    }
}

private struct SecondOpinionModelPicker: View {
    let options: [SecondOpinionModelOption]
    let onPick: (SecondOpinionModelOption) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let other = options.filter(\.isOtherMaker)
        let same = options.filter { !$0.isOtherMaker }

        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text("Ask another model")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, theme.z(6))

            if !other.isEmpty {
                section("Other makers", items: other)
            }
            if !same.isEmpty {
                section("Same maker", items: same)
            }
        }
        .padding(theme.z(10))
        .frame(minWidth: theme.z(240), maxWidth: theme.z(320))
        .background(theme.popover)
    }

    private func section(_ title: String, items: [SecondOpinionModelOption]) -> some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            Text(title)
                .font(theme.font(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, theme.z(6))
                .padding(.top, theme.z(2))

            ForEach(items) { option in
                Button {
                    onPick(option)
                } label: {
                    HStack(spacing: theme.z(8)) {
                        Text(option.name)
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: theme.z(8))
                        Text(option.makerName)
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, theme.z(8))
                    .padding(.vertical, theme.z(5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }
}

/// Colour dot and agent name.
public struct AgentNameTag: View {
    let agent: AgentSpec
    @Environment(\.theme) private var theme

    public init(agent: AgentSpec) { self.agent = agent }

    public var body: some View {
        HStack(spacing: theme.z(6)) {
            StatusDot(Color(hexString: agent.colorHex), size: 8)
            Text(agent.name)
                .font(theme.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(agent.model.id)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
        }
    }
}

/// Collapsed "Thinking" row that expands to the model's reasoning.
public struct ReasoningRow: View {
    let id: String?
    let text: String
    let streaming: Bool
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.transcriptFindHighlight) private var findHighlight

    public init(id: String? = nil, text: String, streaming: Bool, expanded: Bool = false) {
        self.id = id
        self.text = text
        self.streaming = streaming
        self._expanded = State(initialValue: expanded)
    }

    private var isActiveFindMatch: Bool {
        guard let id else { return false }
        return findHighlight?.activeItemID == id
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: theme.z(8)) {
                    Image(systemName: "lightbulb")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(16))
                    Text(streaming ? "Thinking" : "Thought")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textSecondary)
                    if streaming { Spinner(size: 10) }
                    Image(systemName: "chevron.right")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: theme.z(22))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                HStack(alignment: .top, spacing: theme.z(10)) {
                    RoundedRectangle(cornerRadius: theme.z(1)).fill(theme.border).frame(width: theme.z(2))
                    MarkdownView(text, fontSize: 13, textColor: theme.textSecondary, serif: false)
                }
                .padding(.leading, theme.z(7))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if isActiveFindMatch, !expanded { expanded = true }
        }
        .onChange(of: findHighlight?.activeItemID) {
            if isActiveFindMatch, !expanded {
                withAnimation(.easeOut(duration: 0.15)) { expanded = true }
            }
        }
        .onChange(of: findHighlight?.scrollToken) {
            if isActiveFindMatch, !expanded {
                withAnimation(.easeOut(duration: 0.15)) { expanded = true }
            }
        }
    }
}

/// A message one agent posted to the room board.
public struct BoardRow: View {
    let from: AgentSpec?
    let to: [AgentSpec]
    let text: String
    @Environment(\.theme) private var theme

    public init(from: AgentSpec?, to: [AgentSpec], text: String) {
        self.from = from
        self.to = to
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: theme.z(10)) {
            RoundedRectangle(cornerRadius: theme.z(1.5))
                .fill(from.map { Color(hexString: $0.colorHex) } ?? theme.border)
                .frame(width: theme.z(3))
            VStack(alignment: .leading, spacing: theme.z(5)) {
                HStack(spacing: theme.z(5)) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(theme.font(size: 11))
                    Text(from?.name ?? "Agent").fontWeight(.semibold)
                    if !to.isEmpty {
                        Image(systemName: "arrow.right").font(theme.font(size: 9, weight: .semibold))
                        Text(to.map(\.name).joined(separator: ", "))
                    }
                }
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                MarkdownView(text, fontSize: 13.5, textColor: theme.textPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, theme.z(2))
    }
}

public struct ErrorRow: View {
    let message: String
    let onRetry: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var retryHovered = false

    public init(message: String, onRetry: (() -> Void)? = nil) {
        self.message = message
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.danger)
            Text(message)
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
            Spacer(minLength: theme.z(6))
            if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: theme.z(4)) {
                        Image(systemName: "arrow.clockwise")
                            .font(theme.font(size: 10.5, weight: .medium))
                        Text("Retry")
                            .font(theme.font(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(retryHovered ? theme.textPrimary : theme.textSecondary)
                    .padding(.horizontal, theme.z(8))
                    .padding(.vertical, theme.z(4))
                    .background(
                        RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                            .fill(retryHovered ? theme.danger.opacity(0.18) : theme.danger.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                            .strokeBorder(theme.danger.opacity(retryHovered ? 0.45 : 0.25), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { retryHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: retryHovered)
                .help("Retry last message")
            }
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(9))
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.danger.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.danger.opacity(0.3)))
    }
}

/// In place of the error row of a turn that stopped on a plan limit: which limit, when it resets, and the switch that
/// sends "Continue" a minute after the reset (on by default). After it sent, the card says when.
public struct UsageLimitCard: View {
    let stop: UsageLimitStop
    var now: Date
    @Environment(\.theme) private var theme
    @Environment(\.interactionStore) private var store

    public init(stop: UsageLimitStop, now: Date = Date()) {
        self.stop = stop
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: theme.z(10)) {
                Image(systemName: "hourglass")
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.warning)
                    .frame(width: theme.z(16))
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    Text("\(stop.windowLabel) reached")
                        .font(theme.font(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(resetLine)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(12))
            .padding(.vertical, theme.z(10))
            .help(stop.message)

            if let footer {
                Rectangle().fill(theme.warning.opacity(0.22)).frame(height: 1)
                footer
                    .padding(.horizontal, theme.z(12))
                    .frame(minHeight: theme.z(36))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.warning.opacity(0.32)))
        .accessibilityElement(children: .contain)
    }

    private var resetLine: String {
        guard let resetsAt = stop.resetsAt else { return "Reset time not reported" }
        let time = Self.timeText(resetsAt, now: now)
        return resetsAt > now ? "Resets \(time)" : "Reset at \(time)"
    }

    private var footer: AnyView? {
        switch stop.state {
        case .waiting:
            guard let continueAt = stop.continueAt else { return nil }
            return AnyView(
                HStack(spacing: theme.z(10)) {
                    Text("Continue automatically at \(Self.timeText(continueAt, now: now))")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textPrimary)
                        // Offered the row before the spacer, so a narrow pane wraps it only when it must.
                        .layoutPriority(1)
                    Spacer(minLength: theme.z(8))
                    Toggle(isOn: Binding(get: { stop.autoContinue },
                                         set: { store?.setAutoContinue($0, forItem: stop.id) })) { EmptyView() }
                        .toggleStyle(CompactSwitchStyle())
                        .accessibilityLabel("Continue automatically")
                }
                .help("Sends \u{201C}\(SessionStore.autoContinueText)\u{201D} to this session a minute after the limit resets, if it is idle")
            )
        case .sent:
            let sentAt = stop.sentAt ?? stop.continueAt ?? now
            return AnyView(
                HStack(spacing: theme.z(8)) {
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.success)
                    Text("Sent \u{201C}\(SessionStore.autoContinueText)\u{201D} at \(Self.timeText(sentAt, now: now))")
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                }
            )
        case .superseded:
            return nil
        }
    }

    /// "3:41 PM" today, "Thu 9:00 AM" within a week, "Nov 25, 9:00 AM" later.
    public static func timeText(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if abs(date.timeIntervalSince(now)) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Small grey status line ("Interrupted", "Compacting conversation").
public struct NoticeRow: View {
    let text: String
    @Environment(\.theme) private var theme

    public init(text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "info.circle")
                .font(theme.font(size: 11.5))
                .frame(width: theme.z(16))
            Text(text)
                .font(theme.font(size: 12.5))
        }
        .foregroundStyle(theme.textTertiary)
        .frame(minHeight: theme.z(20))
    }
}
