import SwiftUI

/// Renders a cross-session `message_agent` or `ask_agent` exchange inline inside a transcript.
public struct AgentExchangeCardView: View {
    let exchange: AgentExchange
    let currentSessionID: String
    let onOpenTarget: ((String) -> Void)?
    let onDismiss: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var expanded = false

    public init(
        exchange: AgentExchange,
        currentSessionID: String,
        onOpenTarget: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.exchange = exchange
        self.currentSessionID = currentSessionID
        self.onOpenTarget = onOpenTarget
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            header
            messageBox(label: exchange.kind == .ask ? "Question" : "Message", text: exchange.message)

            if let reply = exchange.replyPreview, !reply.isEmpty {
                replySection(reply)
            }

            if case .failed(let error) = exchange.status {
                HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(size: 11))
                    Text(error)
                        .font(theme.font(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.danger)
            }

            if let targetID = counterpartSessionID, let onOpenTarget {
                HStack(spacing: theme.z(8)) {
                    Button(isOutgoing ? "Open target" : "Open sender") {
                        onOpenTarget(targetID)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(theme.z(12))
        .background(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var isOutgoing: Bool {
        exchange.fromSessionID == currentSessionID
    }

    private var counterpartSessionID: String? {
        if isOutgoing {
            return exchange.toSessionID
        }
        return exchange.fromSessionID.isEmpty ? nil : exchange.fromSessionID
    }

    private var headerIcon: String {
        switch exchange.kind {
        case .ask: "questionmark.bubble"
        case .message: isOutgoing ? "arrow.up.right.circle" : "arrow.down.left.circle"
        }
    }

    private var headerTitle: String {
        switch exchange.kind {
        case .ask:
            return "Asked \(exchange.toModelName)"
        case .message:
            return isOutgoing ? "To \(exchange.toTitle)" : "From \(exchange.fromTitle)"
        }
    }

    private var peerModelBadge: String {
        switch exchange.kind {
        case .ask: ""
        case .message: isOutgoing ? exchange.toModelName : exchange.fromModelName
        }
    }

    private var header: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: headerIcon)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)

            Text(headerTitle)
                .font(theme.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            if !peerModelBadge.isEmpty {
                Text(peerModelBadge)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.z(6))
                    .padding(.vertical, theme.z(2))
                    .background(Capsule().fill(theme.codeBackground))
                    .lineLimit(1)
            }

            Spacer(minLength: theme.z(6))

            statusPill

            Text(exchange.timestamp.formatted(date: .omitted, time: .shortened))
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(20), height: theme.z(20))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss exchange")
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch exchange.status {
        case .sending:
            HStack(spacing: theme.z(5)) {
                Spinner(size: 10, color: theme.textSecondary)
                Text(exchange.status.label)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        case .queued:
            pill(exchange.status.label, color: theme.warning)
        case .delivered, .answered:
            pill(exchange.status.label, color: theme.success)
        case .failed:
            pill(exchange.status.label, color: theme.danger)
        }
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(theme.font(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, theme.z(6))
            .padding(.vertical, theme.z(2))
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func messageBox(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            Text(text)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(7))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.separator))
        .accessibilityLabel("\(label): \(text)")
    }

    private func replySection(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            if expanded {
                MarkdownView(reply, streaming: false)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.background))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.separator))
            } else {
                Text(reply)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if reply.count > 160 || exchange.message.count > 220 {
                Button(expanded ? "Show less" : "Show full reply") {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.accent)
            }
        }
    }
}

#Preview("Exchange cards") {
    VStack(spacing: 12) {
        AgentExchangeCardView(
            exchange: AgentExchange(
                kind: .message,
                fromSessionID: "s1",
                fromTitle: "Backend API",
                fromModelName: "Claude Sonnet",
                toSessionID: "s2",
                toTitle: "SwiftUI Client",
                toModelName: "Gemini 2.5 Pro",
                message: "Updated `/api/rooms` to return the lead agent ID cleanly. Can you wire the badge?",
                status: .delivered
            ),
            currentSessionID: "s1",
            onOpenTarget: { _ in },
            onDismiss: {}
        )
        AgentExchangeCardView(
            exchange: AgentExchange(
                kind: .ask,
                fromSessionID: "s1",
                fromTitle: "Backend API",
                fromModelName: "Claude Sonnet",
                toSessionID: nil,
                toTitle: "GPT-5",
                toModelName: "GPT-5",
                message: "Does the hop guard reset cleanly when a user sends a direct turn?",
                replyPreview: "Yes. Checking activeChain against both turn and single-increment turns handles queued delivery cleanly.",
                status: .answered
            ),
            currentSessionID: "s1",
            onDismiss: {}
        )
    }
    .padding()
    .frame(width: 520)
    .ensembleTheme()
    .preferredColorScheme(.dark)
}
