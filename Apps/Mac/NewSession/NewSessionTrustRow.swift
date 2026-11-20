import SwiftUI
import AppKit
import EnsembleKit

/// The chosen folder's trust state in a line, with Trust when the folder has settings, hooks or MCP servers the agent
/// would skip (or the agent does not start in untrusted folders).
struct NewSessionTrustRow: View {
    let line: NewSessionTrustLine
    let error: String?
    let onTrust: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            HStack(spacing: theme.z(6)) {
                Image(systemName: symbol)
                    .font(theme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(tint)
                Text(line.text)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(line.tone == .blocked ? theme.warning : theme.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if line.offersTrust {
                    Button("Trust", action: onTrust)
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Trust this folder so agents load its own settings")
                }
            }
            if let error {
                Text(error)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch line.tone {
        case .trusted: "checkmark.shield"
        case .untrusted: "lock.shield"
        case .blocked: "exclamationmark.shield"
        }
    }

    private var tint: Color {
        switch line.tone {
        case .trusted: theme.success
        case .untrusted: theme.textTertiary
        case .blocked: theme.warning
        }
    }
}
