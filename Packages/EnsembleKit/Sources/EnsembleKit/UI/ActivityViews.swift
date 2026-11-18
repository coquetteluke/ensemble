import SwiftUI

// MARK: - Activity group

/// Consecutive tool calls as one summary row ("Ran a command, read 3 files"). Expanding shows each step;
/// each step opens to its input, output or diff.
public struct ActivityGroupView: View {
    let items: [TranscriptItem]
    let resolutions: [String: PermissionResolution]
    @State private var expanded: Bool
    @State private var hovering = false
    @Environment(\.theme) private var theme

    public init(items: [TranscriptItem], resolutions: [String: PermissionResolution] = [:], expanded: Bool = false) {
        self.items = items
        self.resolutions = resolutions
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        let running = TranscriptGrouping.isRunning(items)
        VStack(alignment: .leading, spacing: theme.z(8)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: theme.z(8)) {
                    if running {
                        Spinner(size: 11).frame(width: theme.z(16))
                    } else {
                        Image(systemName: "square.stack")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: theme.z(16))
                    }
                    Text(TranscriptGrouping.summary(items))
                        .font(theme.font(size: 13))
                        .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: theme.z(22))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(TranscriptGrouping.summary(items))
            .accessibilityHint(expanded ? "Hide the steps" : "Show the steps")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { HLine() }
                        step(item)
                            .padding(.horizontal, theme.z(12))
                            .padding(.vertical, theme.z(8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(11), style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .padding(.leading, theme.z(2))
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private func step(_ item: TranscriptItem) -> some View {
        switch item {
        case .tool(let tool):
            if ToolCategory(tool.name) == .subagent {
                SubagentCardView(tool: tool, compact: true)
            } else {
                ToolCardView(tool: tool)
            }
        case .reasoning(_, let text, let streaming):
            ReasoningRow(text: text, streaming: streaming)
        case .permission(let request):
            PermissionCardView(request: request, resolution: resolutions[request.id])
        default:
            EmptyView()
        }
    }
}

// MARK: - Working row

/// Four dots turning, shown while an agent works.
public struct DotsSpinner: View {
    var size: CGFloat
    var color: Color?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var turning = false

    public init(size: CGFloat = 14, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        let side = theme.z(size)
        let dot = side * 0.3
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let angle = Double(index) * .pi / 2 + .pi / 4
                Circle()
                    .fill(color ?? theme.accent)
                    .frame(width: dot, height: dot)
                    .opacity([1, 0.8, 0.55, 0.35][index])
                    .offset(x: cos(angle) * side * 0.32, y: sin(angle) * side * 0.32)
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(turning ? 360 : 0))
        .onAppear {
            guard !isSnapshot else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

/// At the end of the transcript while the agent works: dots, what it is doing now, elapsed time.
/// Clicking shows the steps of the current turn.
public struct WorkingRow: View {
    let items: [TranscriptItem]
    let since: Date?
    let waitingForPermission: Bool
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.sessionDirectory) private var baseDirectory

    public init(items: [TranscriptItem], since: Date?, waitingForPermission: Bool) {
        self.items = items
        self.since = since
        self.waitingForPermission = waitingForPermission
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: theme.z(10)) {
                    if waitingForPermission {
                        Image(systemName: "hand.raised")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.warning)
                            .frame(width: theme.z(16))
                    } else {
                        DotsSpinner(size: 14).frame(width: theme.z(16))
                    }
                    Text(Self.currentStep(items, waiting: waitingForPermission, baseDirectory: baseDirectory))
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    elapsed
                    Image(systemName: "chevron.right")
                        .font(theme.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: theme.z(24))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                let steps = Self.currentTurnSteps(items)
                VStack(alignment: .leading, spacing: theme.z(6)) {
                    if steps.isEmpty {
                        Text("No tool calls yet in this turn")
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                    }
                    ForEach(steps, id: \.id) { tool in
                        ToolCardView(tool: tool)
                    }
                }
                .padding(.leading, theme.z(26))
            }
        }
    }

    @ViewBuilder private var elapsed: some View {
        if let since {
            if isSnapshot {
                Text(Self.elapsed(from: since, to: Date()))
                    .font(theme.font(size: 13).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            } else {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .font(theme.font(size: 13).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    /// What the agent is doing right now, from the newest transcript item.
    public static func currentStep(_ items: [TranscriptItem], waiting: Bool, baseDirectory: String = "") -> String {
        if waiting { return "Waiting for you" }
        switch items.last {
        case .tool(let tool) where tool.status == .running || tool.status == .pending:
            let summary = ToolSummary(tool, baseDirectory: baseDirectory)
            return summary.subject.isEmpty ? summary.verb : "\(summary.verb) \(summary.subject)"
        case .agentText(_, _, _, true):
            return "Writing"
        default:
            return "Thinking"
        }
    }

    /// Tool calls since your last message (newest four).
    static func currentTurnSteps(_ items: [TranscriptItem]) -> [ToolCallInfo] {
        let start = (items.lastIndex { if case .user = $0 { true } else { false } } ?? -1) + 1
        let tools = items[start...].compactMap { item -> ToolCallInfo? in
            if case .tool(let tool) = item { return tool }
            return nil
        }
        return Array(tools.suffix(4))
    }

    /// "9s", "1m 9s", "1h 2m".
    public static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

// MARK: - Task list

/// The agent's todo list, pinned under the newest message: check marks for done, a spinner for the
/// item in progress, dashed circles for the rest.
public struct TaskListCard: View {
    let items: [TodoItem]
    @Environment(\.theme) private var theme

    public init(items: [TodoItem]) { self.items = items }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(11)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: theme.z(10)) {
                    icon(item.status)
                        .frame(width: theme.z(16), height: theme.z(16))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + theme.z(4.5) }
                    Text(item.status == .inProgress ? (item.activeForm ?? item.content) : item.content)
                        .font(theme.font(size: 13.5))
                        .foregroundStyle(color(item.status))
                        .strikethrough(item.status == .cancelled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.content), \(label(item.status))")
            }
        }
        .padding(.horizontal, theme.z(16))
        .padding(.vertical, theme.z(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(12), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder private func icon(_ status: TodoItem.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(theme.font(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(theme.background, theme.textSecondary)
        case .inProgress:
            Spinner(size: 12.5, lineWidth: 1.6)
        case .pending:
            Circle()
                .strokeBorder(theme.textSecondary, style: StrokeStyle(lineWidth: theme.z(1.3), dash: [theme.z(2.4), theme.z(2.1)]))
                .frame(width: theme.z(13), height: theme.z(13))
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func color(_ status: TodoItem.Status) -> Color {
        switch status {
        case .completed: theme.textSecondary
        case .cancelled: theme.textTertiary
        case .inProgress, .pending: theme.textPrimary
        }
    }

    private func label(_ status: TodoItem.Status) -> String {
        switch status {
        case .completed: "done"
        case .inProgress: "in progress"
        case .pending: "to do"
        case .cancelled: "cancelled"
        }
    }
}
