import SwiftUI
import EnsembleKit

// Swarm views of a room (`RoomSwarm.swift`): the who-messaged-whom graph with its replay control, the replay banner over
// the board, the Follow switch, and how a member's state is shown.

// MARK: - Graph section

/// Side panel section: the message graph and the replay control under it.
struct RoomGraphSection: View {
    let engine: RoomEngine
    @Binding var replayStep: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        let board = engine.state.board
        let ids = engine.agents.map(\.id)
        let step = RoomReplay.clamp(replayStep, board: board)
        let graph = RoomReplay.graph(board, agents: ids, at: step)
        VStack(alignment: .leading, spacing: theme.z(8)) {
            RoomSectionTitle(text: "Messages", trailing: trailing(graph))
            RoomGraphView(graph: graph, agents: engine.agents)
                .frame(height: theme.z(engine.agents.count > 3 ? 210 : 180))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(graph))
            if board.isEmpty {
                Text("Nothing on the board yet.")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ReplayControl(board: board, agentIDs: ids, step: $replayStep)
                caption(board: board, step: step)
            }
        }
    }

    private func trailing(_ graph: RoomGraph) -> String {
        let sent = graph.edges.reduce(0) { $0 + $1.count }
        return sent == 1 ? "1 sent" : "\(sent) sent"
    }

    /// Who sent the message the step ends on, to whom, and when.
    @ViewBuilder private func caption(board: [BoardMessage], step: Int?) -> some View {
        if let message = RoomReplay.message(board, at: step) {
            HStack(spacing: theme.z(5)) {
                Text("\(step ?? board.count) of \(board.count)")
                    .font(theme.font(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                Text("\u{00B7}").foregroundStyle(theme.textTertiary)
                Text(route(message))
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(message.date, format: .dateTime.hour().minute())
                    .font(theme.font(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
            .font(theme.font(size: 11.5))
        }
    }

    private func route(_ message: BoardMessage) -> String {
        func name(_ id: UUID) -> String { engine.agent(id)?.name ?? "Agent" }
        let from: String
        switch message.from {
        case .agent(let id): from = name(id)
        case .user: from = "You"
        case .room: return "Room notice"
        }
        if let routed = RoomGraph.route(message, agents: engine.agents.map(\.id)) {
            let to = routed.to.compactMap { node -> String? in if case .agent(let id) = node { name(id) } else { nil } }
            return to.count == engine.agents.count || (to.count > 1 && to.count == engine.agents.count - 1)
                ? "\(from) to everyone" : "\(from) to \(to.joined(separator: ", "))"
        }
        return "\(from) on the board"
    }

    private func accessibilitySummary(_ graph: RoomGraph) -> String {
        func name(_ node: RoomGraph.Node) -> String {
            switch node {
            case .user: "You"
            case .agent(let id): engine.agent(id)?.name ?? "Agent"
            }
        }
        guard !graph.edges.isEmpty else { return "Message graph: no messages between agents yet" }
        let parts = graph.edges.map { "\(name($0.from)) to \(name($0.to)): \($0.count)" }
        return "Message graph. " + parts.joined(separator: ", ")
    }
}

// MARK: - Graph

/// Agents as dots in their colours on a circle (you at the bottom when you wrote), a line for each pair that exchanged
/// messages, thicker for more messages, and the newest message's lines drawn bright with its sender ringed.
struct RoomGraphView: View {
    let graph: RoomGraph
    let agents: [AgentSpec]
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    private func color(_ node: RoomGraph.Node) -> Color {
        switch node {
        case .user: theme.textSecondary
        case .agent(let id): agents.first { $0.id == id }.map { Color(hexString: $0.colorHex) } ?? theme.textTertiary
        }
    }

    private func label(_ node: RoomGraph.Node) -> String {
        switch node {
        case .user: "You"
        case .agent(let id): agents.first { $0.id == id }?.name ?? "Agent"
        }
    }

    /// Node centres: on a circle from the top, clockwise; two nodes side by side; one in the middle.
    private func positions(_ size: CGSize) -> [RoomGraph.Node: CGPoint] {
        let nodes = graph.nodes
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(theme.z(20), min(size.width / 2 - theme.z(46), size.height / 2 - theme.z(34)))
        var out: [RoomGraph.Node: CGPoint] = [:]
        switch nodes.count {
        case 0: break
        case 1: out[nodes[0]] = center
        case 2:
            out[nodes[0]] = CGPoint(x: center.x - radius, y: center.y)
            out[nodes[1]] = CGPoint(x: center.x + radius, y: center.y)
        default:
            for (i, node) in nodes.enumerated() {
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(nodes.count)
                out[node] = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
        }
        return out
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let points = positions(size)
        let nodeRadius = theme.z(graph.nodes.count > 4 ? 9 : 11)
        let maxCount = max(1, graph.maxCount)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // Lines, the newest message's last so they sit on top.
        let ordered = graph.edges.filter { !graph.isLatest($0) } + graph.edges.filter { graph.isLatest($0) }
        for edge in ordered {
            guard let a = points[edge.from], let b = points[edge.to] else { continue }
            let latest = graph.isLatest(edge)
            let twoWay = graph.count(from: edge.to, to: edge.from) > 0
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(1, hypot(dx, dy))
            // Perpendicular, so the two directions of a pair bow apart.
            let nx = -dy / length, ny = dx / length
            let bow = twoWay ? theme.z(12) : theme.z(0)
            let control = CGPoint(x: (a.x + b.x) / 2 + nx * bow, y: (a.y + b.y) / 2 + ny * bow)
            let start = step(from: a, toward: control, by: nodeRadius + theme.z(2))
            let end = step(from: b, toward: control, by: nodeRadius + theme.z(4))
            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            let weight = theme.z(1) + theme.z(3) * CGFloat(edge.count) / CGFloat(maxCount)
            let tint = color(edge.from)
            // Older edges: 0.4 is enough on the dark background; light needs more to stay visible.
            context.stroke(path, with: .color(tint.opacity(latest ? 0.95 : (theme.isDark ? 0.4 : 0.75))),
                           style: StrokeStyle(lineWidth: latest ? weight + theme.z(0.5) : weight, lineCap: .round))
            arrow(&context, tip: end, from: control, size: theme.z(latest ? 6.5 : 5.5), color: tint.opacity(latest ? 0.95 : 0.55))
            if edge.count > 1 {
                let mid = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x, y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
                let offset = CGPoint(x: mid.x + nx * theme.z(twoWay ? 9 : 8), y: mid.y + ny * theme.z(twoWay ? 9 : 8))
                context.draw(Text("\(edge.count)")
                    .font(theme.font(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(latest ? theme.textPrimary : theme.textTertiary), at: offset)
            }
        }

        // Dots and names.
        for node in graph.nodes {
            guard let p = points[node] else { continue }
            let rect = CGRect(x: p.x - nodeRadius, y: p.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)
            if node == graph.latestFrom {
                let ring = rect.insetBy(dx: -theme.z(3.5), dy: -theme.z(3.5))
                context.stroke(Path(ellipseIn: ring), with: .color(color(node).opacity(0.6)), lineWidth: theme.z(1.5))
            }
            if node == .user {
                context.fill(Path(ellipseIn: rect), with: .color(theme.elevated))
                context.stroke(Path(ellipseIn: rect), with: .color(theme.textSecondary.opacity(0.7)), lineWidth: theme.z(1.2))
                var person = context.resolve(Image(systemName: "person.fill"))
                person.shading = .color(theme.textSecondary)
                context.draw(person, in: rect.insetBy(dx: nodeRadius * 0.45, dy: nodeRadius * 0.45))
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(color(node)))
            }
            // Name outside the circle, away from the centre.
            let dx = p.x - center.x, dy = p.y - center.y
            let length = max(1, hypot(dx, dy))
            let ux = graph.nodes.count == 1 ? 0 : dx / length, uy = graph.nodes.count == 1 ? 1 : dy / length
            let gap = nodeRadius + theme.z(9)
            let labelPoint = CGPoint(x: p.x + ux * gap, y: p.y + uy * gap)
            let anchor = UnitPoint(x: 0.5 - ux * 0.5, y: 0.5 - uy * 0.5)
            context.draw(Text(label(node))
                .font(theme.font(size: 11.5, weight: node == graph.latestFrom ? .semibold : .medium))
                .foregroundStyle(theme.textPrimary), at: labelPoint, anchor: anchor)
        }
    }

    private func step(from point: CGPoint, toward target: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = target.x - point.x, dy = target.y - point.y
        let length = max(1, hypot(dx, dy))
        return CGPoint(x: point.x + dx / length * distance, y: point.y + dy / length * distance)
    }

    private func arrow(_ context: inout GraphicsContext, tip: CGPoint, from: CGPoint, size: CGFloat, color: Color) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * size * 0.55, y: base.y + ux * size * 0.55))
        head.addLine(to: CGPoint(x: base.x + uy * size * 0.55, y: base.y - ux * size * 0.55))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

// MARK: - Replay

/// Step back, a scrubber over every board message, step forward, and Live. Drawn with shapes so it also renders in
/// snapshots. The last step is the live board.
struct ReplayControl: View {
    let board: [BoardMessage]
    let agentIDs: [UUID]
    @Binding var step: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        let count = board.count
        let current = RoomReplay.clamp(step, board: board) ?? count
        HStack(spacing: theme.z(6)) {
            iconButton("backward.frame.fill", help: "Previous message", enabled: current > 1) {
                step = max(1, current - 1)
            }
            Scrubber(count: count, position: current) { newValue in
                step = newValue >= count ? nil : newValue
            }
            iconButton("forward.frame.fill", help: "Next message", enabled: step != nil) {
                let next = current + 1
                step = next >= count ? nil : next
            }
            Button {
                step = nil
            } label: {
                Text("Live")
                    .font(theme.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(step == nil ? theme.accent : theme.textSecondary)
                    .padding(.horizontal, theme.z(7))
                    .frame(height: theme.z(20))
                    .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                        .fill(step == nil ? theme.accent.opacity(0.13) : theme.hover))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(step == nil ? "Showing the live board" : "Back to the live board")
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 10))
                .foregroundStyle(enabled ? theme.textSecondary : theme.textTertiary.opacity(0.5))
                .frame(width: theme.z(20), height: theme.z(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A track with a knob; click or drag to pick a step.
private struct Scrubber: View {
    let count: Int
    let position: Int
    let onChange: (Int) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let knob = theme.z(11)
            let width = max(1, proxy.size.width - knob)
            let fraction = count > 1 ? CGFloat(position - 1) / CGFloat(count - 1) : 1
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: theme.z(4))
                Capsule().fill(theme.accent.opacity(0.65)).frame(width: knob / 2 + fraction * width, height: theme.z(4))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(theme.border))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: fraction * width)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard count > 0 else { return }
                let f = min(max((value.location.x - knob / 2) / width, 0), 1)
                onChange(1 + Int((f * CGFloat(max(0, count - 1))).rounded()))
            })
        }
        .frame(height: theme.z(18))
        .accessibilityElement()
        .accessibilityLabel("Replay")
        .accessibilityValue("Message \(position) of \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(count, position + 1))
            case .decrement: onChange(max(1, position - 1))
            @unknown default: break
            }
        }
    }
}

/// Over the board while replaying: where the replay is, and the way back to live.
struct ReplayBanner: View {
    let step: Int
    let count: Int
    let backToLive: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "clock.arrow.circlepath")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.accent)
            Text("Replaying message \(step) of \(count)")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .help("Newer messages, live text and prompts are hidden until you go back to live")
            Spacer(minLength: 8)
            Button("Back to live", action: backToLive)
                .buttonStyle(.plain)
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(8))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.accent.opacity(0.25)))
    }
}

// MARK: - Follow

/// Follow on or off: while on, the side panel shows whichever agent is working.
struct FollowToggle: View {
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: theme.z(5)) {
                Image(systemName: isOn ? "eye.fill" : "eye").font(theme.font(size: 11))
                Text("Follow").font(theme.font(size: 12, weight: .medium))
            }
            .foregroundStyle(isOn ? theme.accent : (hovering ? theme.textPrimary : theme.textSecondary))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(26))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .fill(isOn ? theme.accent.opacity(0.13) : (hovering ? theme.elevatedHover : theme.elevated)))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .strokeBorder(isOn ? theme.accent.opacity(0.45) : theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Stop following" : "Show the transcript of whichever agent is working")
        .accessibilityLabel("Follow the working agent")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Member state

extension MemberState {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .active: theme.accent
        case .standingBy: theme.textTertiary
        case .waitingOnYou: theme.warning
        case .finished: theme.success
        case .stopped: theme.danger
        }
    }
}

/// A member's state: a spinner while active, otherwise a small mark, and the state's name.
struct MemberStateBadge: View {
    let state: MemberState
    let agentColor: Color
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(5)) {
            switch state {
            case .active: Spinner(size: 10, color: agentColor)
            case .standingBy: Circle().strokeBorder(theme.textTertiary, lineWidth: theme.z(1.2)).frame(width: theme.z(8), height: theme.z(8))
            case .waitingOnYou: Image(systemName: "hand.raised.fill").font(theme.font(size: 10))
            case .finished: Image(systemName: "checkmark").font(theme.font(size: 10, weight: .bold))
            case .stopped: Image(systemName: "stop.circle").font(theme.font(size: 10.5))
            }
            Text(state.label).font(theme.font(size: 11.5, weight: .medium))
        }
        .foregroundStyle(state.color(theme))
        .fixedSize()
    }
}
