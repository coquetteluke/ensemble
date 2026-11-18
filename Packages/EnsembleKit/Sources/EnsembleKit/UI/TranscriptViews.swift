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

    public init(openSession: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                replyPermission: @escaping @MainActor @Sendable (PermissionRequest, PermissionDecision) -> Void = { _, _ in },
                fork: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                rewind: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                edit: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                historySupported: Bool = false,
                workingAgentName: String? = nil,
                shortcutPermissionID: String? = nil) {
        self.openSession = openSession
        self.replyPermission = replyPermission
        self.fork = fork
        self.rewind = rewind
        self.edit = edit
        self.historySupported = historySupported
        self.workingAgentName = workingAgentName
        self.shortcutPermissionID = shortcutPermissionID
    }

    public static let none = TranscriptActions()
}

public extension EnvironmentValues {
    @Entry var transcriptActions: TranscriptActions = .none
    /// Forces a view mode (snapshots); nil uses the saved setting (`TranscriptViewMode.storageKey`).
    @Entry var transcriptViewMode: TranscriptViewMode? = nil
    /// A message to scroll to and flash, set when a search result is opened.
    @Entry var transcriptFocus: TranscriptFocus? = nil
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
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.theme) private var theme
    @Environment(\.transcriptViewMode) private var forcedMode
    @Environment(\.transcriptFocus) private var focus
    @AppStorage(TranscriptViewMode.storageKey) private var savedMode = TranscriptViewMode.normal.rawValue
    @State private var appliedFocusToken: Int?
    @State private var highlightedBlockID: String?

    public init(items: [TranscriptItem], resolutions: [String: PermissionResolution] = [:], agents: [UUID: AgentSpec] = [:]) {
        self.items = items
        self.resolutions = resolutions
        self.agents = agents
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
                    .onAppear { applyFocus(blocks, proxy: proxy) }
                    .onChange(of: focus) { applyFocus(blocks, proxy: proxy) }
                    .onChange(of: items.count) { applyFocus(blocks, proxy: proxy) }
            }
        }
    }

    private func rows(_ blocks: [TranscriptBlock]) -> some View {
        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
            let previous = index > 0 ? blocks[index - 1] : nil
            Group {
                switch block {
                case .single(let item):
                    TranscriptItemView(item: item, previous: previous?.lastItem, resolution: resolutions[item.id], agents: agents)
                case .activity(_, let steps):
                    ActivityGroupView(items: steps, resolutions: resolutions)
                }
            }
            .background {
                if highlightedBlockID == block.id {
                    RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                        .fill(theme.accent.opacity(0.13))
                        .padding(.horizontal, -theme.z(10))
                        .padding(.vertical, -theme.z(6))
                        .transition(.opacity)
                }
            }
            .id(block.id)
            .padding(.top, index == 0 ? 0 : spacing(before: block, after: previous))
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
            if case .permission = item, resolutions[item.id] != nil { return .resolvedPermission }
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
    @Environment(\.transcriptViewMode) private var mode

    public init(item: TranscriptItem, previous: TranscriptItem? = nil, resolution: PermissionResolution? = nil, agents: [UUID: AgentSpec] = [:]) {
        self.item = item
        self.previous = previous
        self.resolution = resolution
        self.agents = agents
    }

    public var body: some View {
        switch item {
        case .user(let id, let text, let date):
            UserBubble(id: id, text: text, date: date)
        case .agentText(_, let text, let agentID, let streaming):
            AgentTextRow(text: text, agent: agentID.flatMap { agents[$0] }, showHeader: showsAgentHeader(agentID), streaming: streaming)
        case .reasoning(_, let text, let streaming):
            ReasoningRow(text: text, streaming: streaming, expanded: (mode ?? .normal) != .normal)
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
        case .error(_, let message):
            ErrorRow(message: message)
        case .notice(_, let text):
            NoticeRow(text: text)
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
    let text: String
    let agent: AgentSpec?
    let showHeader: Bool
    let streaming: Bool
    @Environment(\.theme) private var theme

    public init(text: String, agent: AgentSpec?, showHeader: Bool, streaming: Bool) {
        self.text = text
        self.agent = agent
        self.showHeader = showHeader
        self.streaming = streaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            if showHeader, let agent {
                AgentNameTag(agent: agent)
            }
            MarkdownView(text, streaming: streaming)
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
    let text: String
    let streaming: Bool
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.theme) private var theme

    public init(text: String, streaming: Bool, expanded: Bool = false) {
        self.text = text
        self.streaming = streaming
        self._expanded = State(initialValue: expanded)
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
    @Environment(\.theme) private var theme

    public init(message: String) { self.message = message }

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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(9))
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.danger.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.danger.opacity(0.3)))
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
