import SwiftUI
import EnsembleKit

/// Above the composer: messages sent while the agent works, oldest first, each with Send now, Edit and Cancel.
struct ComposerQueueStrip: View {
    let messages: [QueuedMessage]
    /// The last turn was stopped or failed, so nothing goes out on its own.
    let held: Bool
    let delivery: QueuedDelivery
    let sendNow: SendNowBehavior
    var onSendNow: (QueuedMessage) -> Void
    var onEdit: (QueuedMessage) -> Void
    var onCancel: (QueuedMessage) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            HStack(spacing: theme.z(6)) {
                Text(messages.count == 1 ? "1 queued message" : "\(messages.count) queued messages")
                    .font(theme.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text(status)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(held ? theme.warning : theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(10))
            .padding(.top, theme.z(4))
            .padding(.bottom, theme.z(2))
            ForEach(messages) { message in
                QueueRow(message: message, sendNow: sendNow,
                         onSendNow: { onSendNow(message) }, onEdit: { onEdit(message) }, onCancel: { onCancel(message) })
            }
        }
        .padding(theme.z(5))
        .background(
            RoundedRectangle(cornerRadius: theme.z(12), style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(12), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
    }

    private var status: String {
        if held { return "Held because the last turn stopped" }
        switch delivery {
        case .combined: return "Sent together when the turn ends"
        case .inOrder: return messages.count == 1 ? "Sent when the turn ends" : "Sent in order, one per turn"
        }
    }
}

private struct QueueRow: View {
    let message: QueuedMessage
    let sendNow: SendNowBehavior
    var onSendNow: () -> Void
    var onEdit: () -> Void
    var onCancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: message.files.isEmpty ? "arrow.turn.down.right" : "paperclip")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(16))
            Text(message.preview)
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message.text)
            Spacer(minLength: theme.z(8))
            QueueTextButton(title: "Send now", help: sendNow.help, action: onSendNow)
            QueueIconButton(symbol: "pencil", help: "Edit: put this message back in the box", action: onEdit)
            QueueIconButton(symbol: "xmark", help: "Cancel: remove this message", action: onCancel)
        }
        .padding(.leading, theme.z(8))
        .padding(.trailing, theme.z(4))
        .frame(height: theme.z(32))
        .background(
            RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                .fill(hovering ? theme.hover : .clear)
        )
        .onHover { hovering = $0 }
    }
}

private struct QueueTextButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(4)) {
                Image(systemName: "arrow.up")
                    .font(theme.font(size: 10, weight: .bold))
                Text(title)
                    .font(theme.font(size: 12, weight: .medium))
            }
            .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, theme.z(8))
            .frame(height: theme.z(24))
            .background(
                RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                    .fill(hovering ? theme.elevatedHover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

private struct QueueIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(hovering ? theme.textPrimary : theme.textTertiary)
                .frame(width: theme.z(24), height: theme.z(24))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(hovering ? theme.elevatedHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
