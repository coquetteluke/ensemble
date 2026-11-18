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
                        Image(systemName: "list.bullet")
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

/// The app icon's constellation, alive: four stars drift on their own orbits, the shape sways, and the links between them draw one after
/// another, so the shape keeps connecting while an agent works. Still in snapshots and with Reduce Motion.
public struct ConstellationSpinner: View {
    var size: CGFloat
    /// A fixed moment to draw instead of animating (snapshots of single frames).
    var frozenAt: Double?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 16, frozenAt: Double? = nil) {
        self.size = size
        self.frozenAt = frozenAt
    }

    /// Where the icon's stars sit, in a unit square: white, teal, amber, pink.
    static let stars: [(x: Double, y: Double)] = [(0.25, 0.27), (0.75, 0.32), (0.35, 0.75), (0.76, 0.70)]
    /// The icon's five links.
    static let links: [(from: Int, to: Int)] = [(0, 1), (1, 3), (3, 2), (2, 0), (1, 2)]
    /// One full round of links, in seconds.
    public static let period = 2.2
    /// Each star's own drift: frequencies (cycles a second) and phases, so they never move in step.
    static let drift: [(fx: Double, fy: Double, phase: Double)] = [(0.55, 0.42, 0.0), (0.48, 0.62, 1.7), (0.66, 0.51, 3.1), (0.44, 0.58, 4.6)]

    public var body: some View {
        let side = theme.z(size)
        Group {
            if let frozenAt {
                frame(at: frozenAt)
            } else if isSnapshot || reduceMotion {
                frame(at: 1.1)
            } else {
                TimelineView(.animation) { context in
                    frame(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func frame(at time: Double) -> some View {
        let dark = colorScheme == .dark
        let colors: [Color] = [
            dark ? Color(red: 0.96, green: 0.96, blue: 0.99) : theme.accent,
            Color(red: 0.18, green: 0.84, blue: 0.70),
            Color(red: 0.98, green: 0.67, blue: 0.20),
            Color(red: 0.96, green: 0.40, blue: 0.67),
        ]
        let line = dark ? Color(red: 0.68, green: 0.63, blue: 1.0) : theme.accent
        return Canvas { context, canvas in
            let side = min(canvas.width, canvas.height)
            let points = Self.positions(at: time, side: side)
            let lineWidth = max(0.8, side * 0.05)
            var glow = [Double](repeating: 0, count: Self.stars.count)
            for (index, link) in Self.links.enumerated() {
                let a = points[link.from], b = points[link.to]
                var base = Path()
                base.move(to: a)
                base.addLine(to: b)
                context.stroke(base, with: .color(line.opacity(0.25)), lineWidth: lineWidth)
                let state = Self.linkState(index: index, time: time)
                guard state.alpha > 0 else { continue }
                var drawn = Path()
                drawn.move(to: a)
                drawn.addLine(to: CGPoint(x: a.x + (b.x - a.x) * state.progress, y: a.y + (b.y - a.y) * state.progress))
                context.stroke(drawn, with: .color(line.opacity(state.alpha)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                glow[link.to] = max(glow[link.to], state.arrival)
            }
            let radius = side * 0.085
            for (index, point) in points.enumerated() {
                let pulse = glow[index]
                let halo = radius * (1.5 + 0.3 * pulse)
                context.fill(Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                             with: .color(colors[index].opacity(0.14 + 0.16 * pulse)))
                let core = radius * (1 + 0.18 * pulse)
                context.fill(Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)),
                             with: .color(colors[index]))
            }
        }
    }

    /// Each star's place at `time`: its spot in the icon plus a small drift.
    static func positions(at time: Double, side: CGFloat) -> [CGPoint] {
        let reach = 0.07
        // The whole constellation also sways a little around its middle.
        let sway = 0.14 * sin(2 * .pi * 0.17 * time)
        let center = (x: 0.52, y: 0.51)
        return stars.indices.map { index in
            let star = stars[index], move = drift[index]
            let dx = star.x - center.x, dy = star.y - center.y
            let x = center.x + dx * cos(sway) - dy * sin(sway) + reach * sin(2 * .pi * move.fx * time + move.phase)
            let y = center.y + dx * sin(sway) + dy * cos(sway) + reach * cos(2 * .pi * move.fy * time + move.phase * 0.7)
            // A small inset keeps a glowing star inside the frame at the far end of its drift.
            return CGPoint(x: (0.06 + x * 0.88) * side, y: (0.06 + y * 0.88) * side)
        }
    }

    /// How far a link has drawn (0 to 1), how bright it is, and how much its end star glows as it arrives.
    /// Each link draws in the first 40% of its turn, holds, then fades back to the faint base line.
    static func linkState(index: Int, time: Double) -> (progress: Double, alpha: Double, arrival: Double) {
        let offset = Double(index) / Double(links.count)
        var local = (time / period - offset).truncatingRemainder(dividingBy: 1)
        if local < 0 { local += 1 }
        let ease = { (x: Double) in x * x * (3 - 2 * x) }
        switch local {
        case ..<0.4:
            return (ease(local / 0.4), 0.9, 0)
        case ..<0.75:
            let fade = (local - 0.4) / 0.35
            let arrival = max(0, 1 - fade * 2)
            return (1, 0.9 - 0.65 * ease(fade), arrival)
        default:
            return (0, 0, 0)
        }
    }
}

/// At the end of the transcript while the agent works: dots, what it is doing now, elapsed time.
/// Clicking shows the steps of the current turn.
public struct WorkingRow: View {
    let items: [TranscriptItem]
    let since: Date?
    let waitingForPermission: Bool
    @State private var expanded: Bool
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.sessionDirectory) private var baseDirectory

    public init(items: [TranscriptItem], since: Date?, waitingForPermission: Bool, expanded: Bool = false) {
        self.items = items
        self.since = since
        self.waitingForPermission = waitingForPermission
        self._expanded = State(initialValue: expanded)
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
                        ConstellationSpinner(size: 16).frame(width: theme.z(16))
                    }
                    Text(Self.currentStep(items, waiting: waitingForPermission, baseDirectory: baseDirectory))
                        .font(theme.font(size: 13))
                        .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
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
            // The time keeps its width in a narrow pane; the step's text is the part that shortens.
            if isSnapshot {
                Text(Self.elapsed(from: since, to: Date()))
                    .font(theme.font(size: 13).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize()
            } else {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .font(theme.font(size: 13).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize()
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
        let iconBaseline = theme.z(4.5)
        VStack(alignment: .leading, spacing: theme.z(11)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: theme.z(10)) {
                    icon(item.status)
                        .frame(width: theme.z(16), height: theme.z(16))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + iconBaseline }
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
