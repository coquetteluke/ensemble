import SwiftUI

/// An agent asking to run a command, edit a file or reach outside the project.
/// Pending: title, the exact command or path, detail, and Allow once / Always allow / Reject.
/// Answered: a single line saying how it was resolved.
public struct PermissionCardView: View {
    let request: PermissionRequest
    let resolution: PermissionResolution?
    @Environment(\.theme) private var theme
    @Environment(\.transcriptActions) private var actions

    public init(request: PermissionRequest, resolution: PermissionResolution? = nil) {
        self.request = request
        self.resolution = resolution
    }

    public var body: some View {
        if let resolution {
            resolvedRow(resolution)
        } else {
            pendingCard
        }
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.warning)
                Text(question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Text(request.kind)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }

            Text(request.title)
                .font(EFont.mono)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.separator))
                .selectableText()

            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Allow once") { actions.replyPermission(request, .once) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Always allow") { actions.replyPermission(request, .always) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Reject") { actions.replyPermission(request, .reject) }
                    .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.warning.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question) \(request.title)")
    }

    private func resolvedRow(_ resolution: PermissionResolution) -> some View {
        HStack(spacing: 8) {
            Image(systemName: resolution == .rejected ? "xmark.circle" : "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(resolution == .rejected ? theme.danger : theme.textTertiary)
                .frame(width: 16)
            Text("\(Text(resolution.label).foregroundStyle(theme.textSecondary)) \(Text(request.title).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(theme.textPrimary))")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }

    private var question: String {
        switch request.kind {
        case "bash", "shell", "command": "Allow this command?"
        case "edit", "write", "patch", "multiedit": "Allow this edit?"
        case "webfetch", "fetch", "websearch": "Allow this web request?"
        case "external_directory": "Allow access outside the project?"
        case "read": "Allow reading this file?"
        default: "Allow \(request.kind)?"
        }
    }

    private var symbol: String {
        switch request.kind {
        case "bash", "shell", "command": "terminal"
        case "edit", "write", "patch", "multiedit": "pencil"
        case "webfetch", "fetch", "websearch": "globe"
        case "external_directory": "folder"
        default: "exclamationmark.shield"
        }
    }
}
