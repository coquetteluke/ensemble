import SwiftUI
import EnsembleKit

/// The board as a chat thread: every message shows who sent it (colour and name) and who it is for.
/// Agent-to-agent messages sit indented in a tinted card so the conversation between agents is easy to follow.
struct RoomBoardThread: View {
    let messages: [BoardMessage]
    let agents: [UUID: AgentSpec]
    let models: [ModelInfo]
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: theme.z(0)) { rows }
        } else {
            LazyVStack(alignment: .leading, spacing: theme.z(0)) { rows }
        }
    }

    private var rows: some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            let previous = index > 0 ? messages[index - 1] : nil
            VStack(alignment: .leading, spacing: theme.z(0)) {
                if let round = roundStart(message, previous: previous) {
                    RoundDivider(round: round)
                        .padding(.top, index == 0 ? 0 : 18)
                        .padding(.bottom, theme.z(4))
                }
                BoardMessageRow(message: message, agents: agents, models: models,
                                continued: continues(message, previous: previous))
            }
            .padding(.top, index == 0 ? 0 : theme.z(spacing(message, previous: previous)))
        }
    }

    /// Debate and round table rounds get a divider when the round changes.
    private func roundStart(_ message: BoardMessage, previous: BoardMessage?) -> Int? {
        guard let round = message.round, message.kind == .argument else { return nil }
        let last = previous.flatMap { $0.kind == .argument ? $0.round : nil }
        return last == round ? nil : round
    }

    /// Same sender, same audience, back to back: the header is not repeated.
    private func continues(_ message: BoardMessage, previous: BoardMessage?) -> Bool {
        guard let previous, case .agent = message.from else { return false }
        return previous.from == message.from && previous.to == message.to && previous.kind == message.kind
            && message.kind != .argument && message.date.timeIntervalSince(previous.date) < 120
    }

    private func spacing(_ message: BoardMessage, previous: BoardMessage?) -> CGFloat {
        guard let previous else { return 0 }
        if continues(message, previous: previous) { return 6 }
        if message.from == .room && previous.from == .room { return 6 }
        if message.from == .user || previous.from == .user { return 20 }
        return 14
    }
}

/// One board message.
struct BoardMessageRow: View {
    let message: BoardMessage
    let agents: [UUID: AgentSpec]
    let models: [ModelInfo]
    var continued = false
    @Environment(\.theme) private var theme

    var body: some View {
        switch message.from {
        case .room:
            RoomNoticeRow(text: message.text)
        case .user:
            userRow
        case .agent(let id):
            if message.kind == .assignment {
                AssignmentBoardRow(from: agents[id], to: recipients, text: message.text)
            } else if !message.to.isEmpty {
                AgentToAgentRow(from: agents[id], to: recipients, message: message, continued: continued)
            } else {
                AgentBoardRow(agent: agents[id], message: message, models: models, roster: Array(agents.values), continued: continued)
            }
        }
    }

    private var recipients: [AgentSpec] { message.to.compactMap { agents[$0] } }

    private var userRow: some View {
        VStack(alignment: .trailing, spacing: theme.z(5)) {
            if !message.to.isEmpty || message.kind.tag != nil {
                HStack(spacing: theme.z(5)) {
                    if let tag = message.kind.tag { RoomTag(text: tag) }
                    if !recipients.isEmpty {
                        Text("You to")
                            .foregroundStyle(theme.textTertiary)
                        RecipientNames(agents: recipients)
                    }
                }
                .font(theme.font(size: 11.5))
            }
            HStack {
                Spacer(minLength: 72)
                Group {
                    if message.kind == .plan || message.kind == .verdict {
                        MarkdownView(message.text, fontSize: 13.5, textColor: theme.textPrimary)
                    } else {
                        Text(message.text)
                            .font(theme.font(size: 14))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(theme.z(3))
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableText()
                    }
                }
                .padding(.horizontal, theme.z(14))
                .padding(.vertical, theme.z(9))
                .background(RoundedRectangle(cornerRadius: theme.z(14), style: .continuous).fill(theme.userBubble))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// An agent speaking to the whole room (or the user and the lead).
struct AgentBoardRow: View {
    let agent: AgentSpec?
    let message: BoardMessage
    let models: [ModelInfo]
    /// The room's agents, to colour the owners in a plan's ASSIGN lines.
    var roster: [AgentSpec] = []
    var continued = false
    @Environment(\.theme) private var theme

    var body: some View {
        let shown = BoardKeyword.split(message.text, kind: message.kind)
        VStack(alignment: .leading, spacing: theme.z(6)) {
            if !continued {
                HStack(spacing: theme.z(6)) {
                    AgentHeader(agent: agent, models: models)
                    if let keyword = shown.keyword {
                        RoomTag(text: keyword.label, color: keyword.color(theme))
                    } else if let tag = message.kind.tag, message.kind != .argument {
                        RoomTag(text: tag, color: message.kind == .verdict ? theme.accent : nil)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !shown.text.isEmpty {
                content(for: message.kind, text: shown.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(for kind: BoardMessageKind, text: String) -> some View {
        switch kind {
        case .plan:
            let plan = PlanText(text, roster: roster)
            VStack(alignment: .leading, spacing: theme.z(10)) {
                if !plan.summary.isEmpty {
                    MarkdownView(plan.summary, fontSize: 13.5, textColor: theme.textPrimary)
                }
                if !plan.assignments.isEmpty {
                    VStack(alignment: .leading, spacing: theme.z(6)) {
                        ForEach(Array(plan.assignments.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                                if let owner = item.agent { AgentDot(hex: owner.colorHex, size: 7) }
                                Text(item.agent?.name ?? item.name)
                                    .font(theme.font(size: 12.5, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .frame(minWidth: theme.z(60), alignment: .leading)
                                Text(item.task)
                                    .font(theme.font(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .selectableText()
                            }
                        }
                    }
                }
            }
                .padding(theme.z(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.border))
        case .verdict:
            MarkdownView(text, fontSize: 13.5, textColor: theme.textPrimary)
                .padding(theme.z(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.accent.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.accent.opacity(0.45)))
        default:
            MarkdownView(text, fontSize: 14, textColor: theme.textPrimary)
        }
    }
}

/// A plan split into its text and its `ASSIGN @Name: task` lines.
struct PlanText {
    struct Item {
        var name: String
        var agent: AgentSpec?
        var task: String
    }

    var summary: String
    var assignments: [Item]

    init(_ text: String, roster: [AgentSpec]) {
        var kept: [String] = []
        var items: [Item] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("ASSIGN"), let colon = trimmed.firstIndex(of: ":") else {
                kept.append(line)
                continue
            }
            let who = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<colon]
                .trimmingCharacters(in: CharacterSet(charactersIn: " @*_"))
            let task = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let agent = roster.first { $0.name.compare(who, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            items.append(Item(name: who, agent: agent, task: task))
        }
        summary = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        assignments = items
    }
}

/// An agent writing to other agents: indented, tinted with the sender's colour, "Ada to Byron".
struct AgentToAgentRow: View {
    let from: AgentSpec?
    let to: [AgentSpec]
    let message: BoardMessage
    var continued = false
    @Environment(\.theme) private var theme

    var body: some View {
        let color = from.map { Color(hexString: $0.colorHex) } ?? theme.border
        HStack(alignment: .top, spacing: theme.z(0)) {
            Image(systemName: "arrow.turn.down.right")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(26), height: theme.z(20), alignment: .center)
                .opacity(continued ? 0 : 1)
            HStack(alignment: .top, spacing: theme.z(10)) {
                RoundedRectangle(cornerRadius: theme.z(1.5)).fill(color).frame(width: theme.z(3))
                VStack(alignment: .leading, spacing: theme.z(5)) {
                    if !continued {
                        HStack(spacing: theme.z(5)) {
                            if let from {
                                AgentDot(hex: from.colorHex, size: 7)
                                Text(from.name).fontWeight(.semibold).foregroundStyle(theme.textPrimary)
                            }
                            Text("to").foregroundStyle(theme.textTertiary)
                            RecipientNames(agents: to)
                            if let tag = message.kind.tag { RoomTag(text: tag) }
                        }
                        .font(theme.font(size: 12))
                    }
                    MarkdownView(message.text, fontSize: 13.5, textColor: theme.textPrimary)
                }
                .padding(.vertical, theme.z(9))
                .padding(.trailing, theme.z(12))
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(color.opacity(theme.isDark ? 0.07 : 0.08)))
            .clipShape(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Ada gave Byron: build the parser" (Team assignments).
struct AssignmentBoardRow: View {
    let from: AgentSpec?
    let to: [AgentSpec]
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
            Image(systemName: "checklist")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(16))
            VStack(alignment: .leading, spacing: theme.z(3)) {
                HStack(spacing: theme.z(5)) {
                    if let from {
                        AgentDot(hex: from.colorHex, size: 7)
                        Text(from.name).fontWeight(.semibold).foregroundStyle(theme.textPrimary)
                    } else {
                        Text("You").fontWeight(.semibold).foregroundStyle(theme.textPrimary)
                    }
                    Text("assigned").foregroundStyle(theme.textTertiary)
                    RecipientNames(agents: to)
                }
                .font(theme.font(size: 12))
                Text(assignmentText)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectableText()
            }
            Spacer(minLength: 0)
        }
    }

    /// The engine writes "Name: task"; the name is already in the header.
    private var assignmentText: String {
        guard let name = to.first?.name, text.hasPrefix(name + ": ") else { return text }
        return String(text.dropFirst(name.count + 2))
    }
}

/// Recipient names, each in its own colour.
struct RecipientNames: View {
    let agents: [AgentSpec]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(4)) {
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                HStack(spacing: theme.z(4)) {
                    AgentDot(hex: agent.colorHex, size: 7)
                    Text(agent.name + (index < agents.count - 1 ? "," : ""))
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textPrimary)
                }
            }
        }
    }
}

/// Dot, name and model of an agent.
struct AgentHeader: View {
    let agent: AgentSpec?
    let models: [ModelInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(6)) {
            if let agent {
                AgentDot(hex: agent.colorHex, size: 8)
                Text(agent.name)
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(shortModelName(agent.model, models: models))
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text("Removed agent")
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

/// The room's own notices: phases, merges, caps.
struct RoomNoticeRow: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 11))
                .frame(width: theme.z(16))
            Text(text)
                .font(theme.font(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textTertiary)
        .frame(minHeight: theme.z(18))
    }

    private var symbol: String {
        let lower = text.lowercased()
        if lower.hasPrefix("merged") || lower.contains("merge") { return "arrow.triangle.merge" }
        if lower.contains("spending cap") { return "dollarsign.circle" }
        if lower.hasPrefix("paused") { return "pause.circle" }
        if lower.hasPrefix("resumed") { return "play.circle" }
        if lower.hasPrefix("stopped") { return "stop.circle" }
        return "info.circle"
    }
}

/// "Round 2" between debate rounds.
struct RoundDivider: View {
    let round: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Rectangle().fill(theme.separator).frame(height: 1)
            Text("Round \(round)")
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

/// An agent's turn while it streams.
struct LiveAgentRow: View {
    let agent: AgentSpec
    let text: String
    let models: [ModelInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            HStack(spacing: theme.z(6)) {
                AgentHeader(agent: agent, models: models)
                Spinner(size: 10, color: Color(hexString: agent.colorHex))
            }
            MarkdownView(text, fontSize: 14, textColor: theme.textPrimary)
                .opacity(0.92)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Agents working without streamed text yet, or waiting on a permission prompt.
struct WorkingAgentsRow: View {
    let working: [AgentSpec]
    let waiting: [AgentSpec]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            if !working.isEmpty {
                HStack(spacing: theme.z(8)) {
                    Spinner(size: 11, color: theme.accent).frame(width: theme.z(16))
                    AgentDots(colors: working.map(\.colorHex), size: 7, ring: theme.background)
                    Text("\(Self.list(working.map(\.name))) \(working.count == 1 ? "is" : "are") working")
                }
            }
            if !waiting.isEmpty {
                HStack(spacing: theme.z(8)) {
                    Image(systemName: "hand.raised")
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.warning)
                        .frame(width: theme.z(16))
                    AgentDots(colors: waiting.map(\.colorHex), size: 7, ring: theme.background)
                    Text("\(Self.list(waiting.map(\.name))) \(waiting.count == 1 ? "is" : "are") waiting for permission")
                }
            }
        }
        .font(theme.font(size: 12.5))
        .foregroundStyle(theme.textSecondary)
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

/// A room keyword that ends (or starts) an agent's message, shown as a tag instead of a line of text.
enum BoardKeyword {
    case done, approved, changes, agrees, takeover, plan, verdict

    var label: String {
        switch self {
        case .done: "Done"
        case .approved: "Approved"
        case .changes: "Changes requested"
        case .agrees: "Agrees"
        case .takeover: "Offers to take over"
        case .plan: "Plan"
        case .verdict: "Verdict"
        }
    }

    func color(_ theme: Theme) -> Color {
        switch self {
        case .done, .approved, .agrees: theme.success
        case .changes: theme.warning
        case .takeover, .plan, .verdict: theme.accent
        }
    }

    /// The message without its keyword line, and the keyword. A leading `PLAN:` or `VERDICT:` is dropped too
    /// (plan and verdict messages already carry their tag).
    static func split(_ text: String, kind: BoardMessageKind) -> (text: String, keyword: BoardKeyword?) {
        guard kind != .argument else { return (text, nil) }
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, keyword) in [("PLAN:", BoardKeyword.plan), ("VERDICT:", .verdict)] where whole.uppercased().hasPrefix(prefix) {
            let rest = whole.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let body = rest.prefix(1).uppercased() + rest.dropFirst()
            return (body, kind == .plan || kind == .verdict ? nil : keyword)
        }
        guard kind != .plan && kind != .verdict else { return (text, nil) }
        var lines = text.components(separatedBy: "\n")
        func word(_ line: String) -> BoardKeyword? {
            let w = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*_`.!")).uppercased()
            switch w {
            case "DONE": return .done
            case "APPROVE", "APPROVED": return .approved
            case "AGREE", "AGREED", "I AGREE": return .agrees
            case "TAKEOVER", "TAKE OVER": return .takeover
            default: return nil
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last, let keyword = word(last) {
            lines.removeLast()
            return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), keyword)
        }
        if let first = lines.first, let keyword = word(first) {
            lines.removeFirst()
            return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), keyword)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("CHANGES:") {
            let rest = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            return (rest.prefix(1).uppercased() + rest.dropFirst(), .changes)
        }
        return (text, nil)
    }
}
