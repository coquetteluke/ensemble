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
            // The status goes under the count in a narrow pane.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.z(6)) {
                    countText
                    statusText.lineLimit(1)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    countText
                    statusText.fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var countText: some View {
        Text(messages.count == 1 ? "1 queued message" : "\(messages.count) queued messages")
            .font(theme.font(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
    }

    private var statusText: some View {
        Text(status)
            .font(theme.font(size: 11.5))
            .foregroundStyle(held ? theme.warning : theme.textTertiary)
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
        // In a narrow pane Send now keeps its icon only (the tooltip keeps the words).
        ViewThatFits(in: .horizontal) {
            content(labelled: true)
            content(labelled: false)
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

extension QueueRow {
    /// The preview takes the room the buttons leave (at least a short stretch, so a narrow pane drops the Send now
    /// label rather than the preview).
    fileprivate func content(labelled: Bool) -> some View {
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
                .frame(minWidth: 0, idealWidth: theme.z(90), maxWidth: .infinity, alignment: .leading)
                .help(message.text)
            QueueTextButton(title: "Send now", help: sendNow.help, iconOnly: !labelled, action: onSendNow)
            QueueIconButton(symbol: "pencil", help: "Edit: put this message back in the box", action: onEdit)
            QueueIconButton(symbol: "xmark", help: "Cancel: remove this message", action: onCancel)
        }
    }
}

private struct QueueTextButton: View {
    let title: String
    let help: String
    var iconOnly = false
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(4)) {
                Image(systemName: "arrow.up")
                    .font(theme.font(size: 10, weight: .bold))
                if !iconOnly {
                    Text(title)
                        .font(theme.font(size: 12, weight: .medium))
                }
            }
            .fixedSize()
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
        .help(iconOnly ? "\(title): \(help)" : help)
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
