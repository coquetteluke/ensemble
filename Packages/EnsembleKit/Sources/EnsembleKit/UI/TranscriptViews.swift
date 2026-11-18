import SwiftUI

/// What transcript rows can ask the app to do. Set with `.environment(\.transcriptActions, ...)`.
public struct TranscriptActions: Sendable {
    public var openSession: @MainActor @Sendable (String) -> Void
    public var replyPermission: @MainActor @Sendable (PermissionRequest, PermissionDecision) -> Void

    public init(openSession: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                replyPermission: @escaping @MainActor @Sendable (PermissionRequest, PermissionDecision) -> Void = { _, _ in }) {
        self.openSession = openSession
        self.replyPermission = replyPermission
    }

    public static let none = TranscriptActions()
}

public extension EnvironmentValues {
    @Entry var transcriptActions: TranscriptActions = .none
}

/// All rows of a transcript, spaced like the reference app. The caller provides the scroll container.
public struct TranscriptList: View {
    let items: [TranscriptItem]
    let resolutions: [String: PermissionResolution]
    let agents: [UUID: AgentSpec]
    @Environment(\.isSnapshot) private var isSnapshot

    public init(items: [TranscriptItem], resolutions: [String: PermissionResolution] = [:], agents: [UUID: AgentSpec] = [:]) {
        self.items = items
        self.resolutions = resolutions
        self.agents = agents
    }

    public var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { rows }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) { rows }
        }
    }

    private var rows: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let previous = index > 0 ? items[index - 1] : nil
            TranscriptItemView(item: item, previous: previous, resolution: resolutions[item.id], agents: agents)
                .padding(.top, index == 0 ? 0 : spacing(before: item, after: previous))
        }
    }

    private func kind(_ item: TranscriptItem) -> TranscriptRowKind {
        if case .permission = item, resolutions[item.id] != nil { return .resolvedPermission }
        return item.kind
    }

    /// Tool rows sit close together; everything else gets room to breathe.
    private func spacing(before item: TranscriptItem, after previous: TranscriptItem?) -> CGFloat {
        guard let previous else { return 0 }
        switch (kind(previous), kind(item)) {
        case (.tool, .tool), (.tool, .resolvedPermission), (.resolvedPermission, .tool): return 6
        case (.reasoning, .tool), (.tool, .reasoning): return 8
        case (_, .user), (.user, _): return 22
        default: return 14
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
        case .tool(let tool): ["task", "agent", "subagent"].contains(tool.name.lowercased()) ? .card : .tool
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

    public init(item: TranscriptItem, previous: TranscriptItem? = nil, resolution: PermissionResolution? = nil, agents: [UUID: AgentSpec] = [:]) {
        self.item = item
        self.previous = previous
        self.resolution = resolution
        self.agents = agents
    }

    public var body: some View {
        switch item {
        case .user(_, let text, _):
            UserBubble(text: text)
        case .agentText(_, let text, let agentID, let streaming):
            AgentTextRow(text: text, agent: agentID.flatMap { agents[$0] }, showHeader: showsAgentHeader(agentID), streaming: streaming)
        case .reasoning(_, let text, let streaming):
            ReasoningRow(text: text, streaming: streaming)
        case .tool(let tool):
            if ["task", "agent", "subagent"].contains(tool.name.lowercased()) {
                SubagentCardView(tool: tool)
            } else {
                ToolCardView(tool: tool)
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

/// The user's message, right-aligned in a soft bubble.
public struct UserBubble: View {
    let text: String
    @Environment(\.theme) private var theme

    public init(text: String) { self.text = text }

    public var body: some View {
        HStack {
            Spacer(minLength: 72)
            Text(text)
                .font(EFont.transcript)
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.userBubble)
                )
        }
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
        VStack(alignment: .leading, spacing: 6) {
            if showHeader, let agent {
                AgentNameTag(agent: agent)
            }
            MarkdownView(text)
        }
    }
}

/// Colour dot and agent name.
public struct AgentNameTag: View {
    let agent: AgentSpec
    @Environment(\.theme) private var theme

    public init(agent: AgentSpec) { self.agent = agent }

    public var body: some View {
        HStack(spacing: 6) {
            StatusDot(Color(hexString: agent.colorHex), size: 8)
            Text(agent.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(agent.model.id)
                .font(.system(size: 11.5))
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

    public init(text: String, streaming: Bool) {
        self.text = text
        self.streaming = streaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 16)
                    Text(streaming ? "Thinking" : "Thought")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                    if streaming { Spinner(size: 10) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1).fill(theme.border).frame(width: 2)
                    MarkdownView(text, fontSize: 13, textColor: theme.textSecondary)
                }
                .padding(.leading, 7)
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
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(from.map { Color(hexString: $0.colorHex) } ?? theme.border)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 11))
                    Text(from?.name ?? "Agent").fontWeight(.semibold)
                    if !to.isEmpty {
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                        Text(to.map(\.name).joined(separator: ", "))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                MarkdownView(text, fontSize: 13.5, textColor: theme.textPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
}

public struct ErrorRow: View {
    let message: String
    @Environment(\.theme) private var theme

    public init(message: String) { self.message = message }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.danger.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.danger.opacity(0.3)))
    }
}

/// Small grey status line ("Interrupted", "Compacting conversation").
public struct NoticeRow: View {
    let text: String
    @Environment(\.theme) private var theme

    public init(text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11.5))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12.5))
        }
        .foregroundStyle(theme.textTertiary)
        .frame(minHeight: 20)
    }
}

/// Shown under the transcript while the agent works.
public struct WorkingRow: View {
    let since: Date?
    let waitingForPermission: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    public init(since: Date?, waitingForPermission: Bool) {
        self.since = since
        self.waitingForPermission = waitingForPermission
    }

    public var body: some View {
        HStack(spacing: 8) {
            if waitingForPermission {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.warning)
                    .frame(width: 16)
                Text("Waiting for you")
            } else {
                Spinner(size: 11, color: theme.accent)
                    .frame(width: 16)
                if let since, !isSnapshot {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("Working \(Self.elapsed(from: since, to: context.date))")
                    }
                } else {
                    Text("Working")
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(theme.textSecondary)
        .frame(minHeight: 22)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
