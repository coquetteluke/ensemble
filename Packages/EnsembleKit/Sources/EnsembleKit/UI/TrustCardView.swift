import SwiftUI

/// The "Trust this folder?" card: what the session's engine skips or refuses in a folder the user has not trusted, and
/// what trusting changes. Trust this folder calls `WorkspaceTrust.trust` (through the store); Not now hides the card
/// for the folder until the app quits. After trusting, a refused message can be sent again with one click.
public struct TrustCardView: View {
    let prompt: TrustPrompt
    let error: String?
    let onTrust: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void
    @Environment(\.theme) private var theme

    public init(prompt: TrustPrompt, error: String? = nil, onTrust: @escaping () -> Void, onDismiss: @escaping () -> Void,
                onRetry: @escaping () -> Void = {}) {
        self.prompt = prompt
        self.error = error
        self.onTrust = onTrust
        self.onDismiss = onDismiss
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(alignment: .top, spacing: theme.z(10)) {
            Image(systemName: symbol)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: theme.z(16))
                .padding(.top, theme.z(1))
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Text(prompt.title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.message)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: theme.z(8)) {
                    buttons
                    Text(Format.abbreviatedPath(prompt.folder))
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(prompt.folder)
                    Spacer(minLength: 0)
                }
                .padding(.top, theme.z(4))
                if let error {
                    Text(error)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(12), style: .continuous)
                .strokeBorder(prompt.kind == .refused ? theme.warning.opacity(0.55) : theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.title)
    }

    @ViewBuilder private var buttons: some View {
        switch prompt.kind {
        case .skipped, .refused, .loadsUntrusted:
            Button("Trust this folder", action: onTrust)
                .buttonStyle(PrimaryButtonStyle())
                .help("Trust \(prompt.folder) so agents load its own settings")
            Button("Not now", action: onDismiss)
                .buttonStyle(SecondaryButtonStyle())
                .help("Hide this until Ensemble restarts")
        case .retry:
            Button("Send again", action: onRetry)
                .buttonStyle(PrimaryButtonStyle())
                .help("Send the refused message to \(prompt.engineName) again")
            Button("Not now", action: onDismiss)
                .buttonStyle(SecondaryButtonStyle())
        case .keepsSkipping:
            Button("Hide", action: onDismiss)
                .buttonStyle(SecondaryButtonStyle())
                .help("Hide this until Ensemble restarts")
        }
    }

    private var symbol: String {
        switch prompt.kind {
        case .skipped, .loadsUntrusted: "lock.shield"
        case .refused: "exclamationmark.shield"
        case .retry: "checkmark.shield"
        case .keepsSkipping: "info.circle"
        }
    }

    private var tint: Color {
        switch prompt.kind {
        case .skipped, .refused, .loadsUntrusted: theme.warning
        case .retry: theme.success
        case .keepsSkipping: theme.textTertiary
        }
    }
}

/// The trust card for one session, placed above the composer. Takes no space when there is nothing to say. Follows
/// `WorkspaceTrust` (observable), so it updates when a folder is trusted here, in Settings or in the review pane.
public struct SessionTrustCard: View {
    let store: SessionStore
    let session: SessionModel
    @Environment(\.theme) private var theme

    public init(store: SessionStore, session: SessionModel) {
        self.store = store
        self.session = session
    }

    public var body: some View {
        if let prompt = store.trustPrompt(for: session) {
            TrustCardView(prompt: prompt, error: store.trustError(for: session.directory),
                          onTrust: { store.trustFolder(of: session) },
                          onDismiss: { store.dismissTrustPrompt(for: session) },
                          onRetry: { Task { await store.sendRefusedMessageAgain(for: session) } })
                .padding(.bottom, theme.z(8))
                .transition(.opacity)
        }
    }
}
