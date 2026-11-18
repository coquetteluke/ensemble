#if os(macOS)
import SwiftUI

/// A side task an agent proposed (`propose_session`): title, brief, folder and model, with Start (a new session with
/// the brief), Do it here (the brief goes to this session as a message) and Dismiss. Nothing starts on its own.
/// Once answered it shrinks to one line; a started session can be opened from there.
public struct ProposalCardView: View {
    let proposal: SessionProposal
    let onStart: () -> Void
    let onDoItHere: () -> Void
    let onDismiss: () -> Void
    let onOpen: (String) -> Void
    @Environment(\.theme) private var theme

    public init(proposal: SessionProposal, onStart: @escaping () -> Void, onDoItHere: @escaping () -> Void,
                onDismiss: @escaping () -> Void, onOpen: @escaping (String) -> Void) {
        self.proposal = proposal
        self.onStart = onStart
        self.onDoItHere = onDoItHere
        self.onDismiss = onDismiss
        self.onOpen = onOpen
    }

    public var body: some View {
        switch proposal.state {
        case .pending, .failed:
            card
        case .starting:
            line(symbol: nil, text: "Starting a session:", tint: theme.textSecondary)
        case .started(let sessionID):
            line(symbol: "checkmark.circle", text: "Started a session:", tint: theme.textTertiary) {
                Button("Open") { onOpen(sessionID) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Open the new session")
            }
        case .sentHere:
            line(symbol: "arrow.turn.down.left", text: "Sent to this session:", tint: theme.textTertiary)
        case .dismissed:
            EmptyView()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "plus.square.on.square")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text("Proposed session")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }

            Text(proposal.title)
                .font(theme.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // The whole brief stays readable: a long one scrolls inside the card.
            ViewThatFits(in: .vertical) {
                briefText
                ScrollView(.vertical) { briefText }
            }
            .frame(maxHeight: theme.z(180))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(8))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.separator))

            FlowRow(spacing: theme.z(14), lineSpacing: theme.z(4)) {
                detail("folder", Self.displayPath(proposal.folder), help: proposal.folder)
                detail("cpu", proposal.modelName, help: modelHelp)
                detail("hand.raised", proposal.permissionMode.label, help: "The new session starts in this mode")
            }

            if case .failed(let message) = proposal.state {
                HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(size: 11))
                    Text("Could not start: \(message)")
                        .font(theme.font(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.danger)
            }

            FlowRow(spacing: theme.z(8)) {
                Button("Start") { onStart() }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Start a new session with this brief")
                Button("Do it here") { onDoItHere() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Send the brief to this session as a message")
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Close this card")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, theme.z(2))
        }
        .padding(theme.z(14))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed session: \(proposal.title)")
    }

    private var briefText: some View {
        Text(proposal.brief)
            .font(theme.font(size: 12.5))
            .foregroundStyle(theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var modelHelp: String {
        if let asked = proposal.unmatchedModel {
            return "The agent suggested \(asked), which is not one of your models, so this session's model is used."
        }
        return "Model for the new session"
    }

    private func detail(_ symbol: String, _ text: String, help: String) -> some View {
        HStack(spacing: theme.z(5)) {
            Image(systemName: symbol)
                .font(theme.font(size: 10.5))
                .foregroundStyle(theme.textTertiary)
            Text(text)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(help)
    }

    private func line(symbol: String?, text: String, tint: Color) -> some View {
        line(symbol: symbol, text: text, tint: tint) { EmptyView() }
    }

    private func line<Trailing: View>(symbol: String?, text: String, tint: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: theme.z(8)) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(theme.font(size: 12)).foregroundStyle(tint)
                } else {
                    Spinner(size: theme.z(11))
                }
            }
            .frame(width: theme.z(16))
            Text("\(Text(text).foregroundStyle(theme.textSecondary)) \(Text(proposal.title).foregroundStyle(theme.textPrimary))")
                .font(theme.font(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: theme.z(22))
    }

    /// `~/Projects/acme` for folders in the home folder.
    public static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
#endif
