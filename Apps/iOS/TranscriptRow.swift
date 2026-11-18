import EnsembleKit
import SwiftUI

/// Simple rendering of one transcript row: text, tool one-liners, permission cards, board messages.
struct TranscriptRow: View {
    let item: TranscriptItem
    let agents: [UUID: RemoteAgent]
    let client: RemoteClient
    var onError: (String) -> Void

    var body: some View {
        switch item {
        case .user(_, let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.body)
                    .foregroundStyle(RemoteTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RemoteTheme.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
        case .agentText(_, let text, let agentID, let streaming):
            VStack(alignment: .leading, spacing: 4) {
                if let agent = agentID.flatMap({ agents[$0] }) {
                    AgentTag(agent: agent)
                }
                AgentMessageText(text: text)
                if streaming {
                    ProgressView().controlSize(.mini)
                }
            }
        case .reasoning(_, let text, _):
            DisclosureGroup {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.secondaryText)
            }
            .tint(RemoteTheme.secondaryText)
        case .tool(let tool):
            ToolLine(tool: tool)
        case .permission(let request):
            if request.isQuestion {
                RemoteQuestionCard(request: request, client: client, onError: onError)
            } else if request.isPlan {
                RemotePlanCard(request: request, client: client, onError: onError)
            } else {
                // In a room, the agent that asks (its own session, or one of its subagents' prompts).
                PermissionCard(request: request, client: client, onError: onError,
                               agent: agents.values.first { $0.sessionID == request.sessionID })
            }
        case .board(_, let from, let to, let text, _):
            BoardMessage(from: agents[from], to: to.compactMap { agents[$0] }, text: text)
        case .error(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(RemoteTheme.danger)
        case .notice(_, let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(RemoteTheme.tertiaryText)
                .frame(maxWidth: .infinity)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// What an agent wrote, in the same tuned serif as the Mac app (`MessageType`), following Dynamic Type.
struct AgentMessageText: View {
    let text: String
    @ScaledMetric private var size: CGFloat

    init(text: String, size: CGFloat = 17) {
        self.text = text
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Text(TranscriptRow.markdown(text))
            .font(MessageType.font(size: size))
            .tracking(MessageType.tracking(size))
            .lineSpacing(MessageType.lineSpacing(size))
            .foregroundStyle(RemoteTheme.primaryText)
            .textSelection(.enabled)
    }
}

struct AgentTag: View {
    let agent: RemoteAgent

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(remoteHex: agent.colorHex)).frame(width: 8, height: 8)
            Text(agent.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(remoteHex: agent.colorHex))
        }
    }
}

/// A tool call in one line: icon, name, what it touched, status.
struct ToolLine: View {
    let tool: ToolCallInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(RemoteTheme.secondaryText)
                .frame(width: 16)
            Text(tool.name.capitalized)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RemoteTheme.secondaryText)
            Text(tool.title)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(RemoteTheme.primaryText.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            status
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch tool.name {
        case "bash", "shell": "terminal"
        case "edit", "write", "patch": "pencil"
        case "read": "doc.text"
        case "grep", "glob", "search", "list": "magnifyingglass"
        case "webfetch", "websearch": "globe"
        case "task": "person.crop.circle.badge.plus"
        default: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch tool.status {
        case .pending, .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(RemoteTheme.success)
        case .failed: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(RemoteTheme.danger)
        }
    }
}

/// A permission prompt with Allow once, Always and Reject.
struct PermissionCard: View {
    let request: PermissionRequest
    let client: RemoteClient
    var onError: (String) -> Void
    /// The room agent that asks, when in a room.
    var agent: RemoteAgent?
    @State private var busy = false

    private var decision: PermissionDecision? { client.permissionDecisions[request.id] }
    private var answered: Bool {
        client.isAnswered(request.id) || (!client.permissions.contains { $0.id == request.id } && decision != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(RemoteTheme.warning)
                Text("Permission needed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RemoteTheme.primaryText)
                if let agent { AgentTag(agent: agent) }
                Spacer(minLength: 4)
                Chip(text: request.kind)
            }
            Text(PermissionDisplay.visible(request.title))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(RemoteTheme.primaryText)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)
            if let detail = request.detail.map({ PermissionDisplay.visible($0) }), !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(RemoteTheme.secondaryText)
            }
            let patterns = PermissionDisplay.patterns(request)
            if !patterns.isEmpty {
                Label {
                    Text("Always allows " + patterns.joined(separator: "; "))
                        .font(.system(.caption, design: .monospaced))
                } icon: {
                    Image(systemName: "infinity")
                }
                .font(.caption)
                .foregroundStyle(RemoteTheme.tertiaryText)
            }
            if answered {
                Label(answerText, systemImage: decision == .reject ? "xmark.circle" : "checkmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(decision == .reject ? RemoteTheme.danger : RemoteTheme.success)
            } else {
                HStack(spacing: 8) {
                    Button("Allow once") { reply(.once) }
                        .buttonStyle(.borderedProminent)
                    Button("Always") { reply(.always) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Reject", role: .destructive) { reply(.reject) }
                        .buttonStyle(.bordered)
                        .tint(RemoteTheme.danger)
                }
                .controlSize(.small)
                .disabled(busy || !client.state.isConnected)
            }
        }
        .remoteCard(padding: 12)
    }

    private var answerText: String {
        switch decision {
        case .once: "Allowed once"
        case .always: "Always allowed"
        case .reject: "Rejected"
        case nil: "Answered"
        }
    }

    private func reply(_ d: PermissionDecision) {
        busy = true
        Task {
            do { try await client.reply(to: request, decision: d) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

/// A message one agent posted to the room board.
struct BoardMessage: View {
    let from: RemoteAgent?
    let to: [RemoteAgent]
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(from.map { Color(remoteHex: $0.colorHex) } ?? RemoteTheme.stroke)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let from { AgentTag(agent: from) }
                    if !to.isEmpty {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(RemoteTheme.tertiaryText)
                        Text(to.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(RemoteTheme.secondaryText)
                    }
                }
                AgentMessageText(text: text, size: 16)
            }
            .padding(.leading, 10)
            .padding(.vertical, 2)
        }
    }
}
