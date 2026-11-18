import SwiftUI

/// An agent asking to run a command, edit a file or reach outside the project.
/// Pending: title, the exact command or path, detail, and Allow once / Always allow / Reject.
/// Answered: a single line saying how it was resolved.
/// Plans and questions travel as permission requests too; they get their own cards (`PlanCardView`,
/// `QuestionRecordView`) and are never answered with Allow or Reject.
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
        if request.isPlan {
            PlanCardView(request: request, resolution: resolution)
        } else if request.isQuestion {
            QuestionRecordView(request: request, resolution: resolution)
        } else if let resolution {
            resolvedRow(resolution)
        } else {
            pendingCard
        }
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: symbol)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.warning)
                Text(question)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Text(request.kind)
                    .font(theme.font(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }

            // The whole command is always readable: long ones scroll instead of being cut off.
            ViewThatFits(in: .vertical) {
                titleText
                ScrollView(.vertical) { titleText }
            }
            .frame(maxHeight: theme.z(240))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(8))
            .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.separator))
            .selectableText()

            if let detail = request.detail.map({ PermissionDisplay.visible($0) }), !detail.isEmpty {
                Text(detail)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: theme.z(8)) {
                Button("Allow once") { actions.replyPermission(request, .once) }
                    .buttonStyle(PrimaryButtonStyle())
                    .modifier(PermissionShortcut(key: "y", modifiers: .command, enabled: hasShortcuts))
                    .help(hasShortcuts ? "Allow once (Command-Y)" : "Allow once")
                Button("Always allow") { actions.replyPermission(request, .always) }
                    .buttonStyle(SecondaryButtonStyle())
                    .modifier(PermissionShortcut(key: "y", modifiers: [.command, .option], enabled: hasShortcuts))
                    .help(alwaysHelp(patterns))
                Button("Reject") { actions.replyPermission(request, .reject) }
                    .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                    .modifier(PermissionShortcut(key: ".", modifiers: .command, enabled: hasShortcuts))
                    .help(hasShortcuts ? "Reject (Command-period)" : "Reject")
                if !patterns.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(5)) {
                        Image(systemName: "infinity")
                            .font(theme.font(size: 10.5, weight: .semibold))
                        VStack(alignment: .leading, spacing: theme.z(2)) {
                            ForEach(Array(patterns.enumerated()), id: \.offset) { _, pattern in
                                Text(pattern)
                                    .font(theme.font(size: 11.5, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, theme.z(4))
                    .help("Always allow also covers these from now on")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, theme.z(2))
        }
        .padding(theme.z(14))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.warning.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question) \(request.title)")
    }

    private func resolvedRow(_ resolution: PermissionResolution) -> some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: resolution == .rejected ? "xmark.circle" : "checkmark.circle")
                .font(theme.font(size: 12))
                .foregroundStyle(resolution == .rejected ? theme.danger : theme.textTertiary)
                .frame(width: theme.z(16))
            Text("\(Text(resolution.label).foregroundStyle(theme.textSecondary)) \(Text(request.title).font(theme.font(size: 12.5, design: .monospaced)).foregroundStyle(theme.textPrimary))")
                .font(theme.font(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: theme.z(22))
    }

    private var hasShortcuts: Bool { actions.shortcutPermissionID == request.id }

    private var patterns: [String] { PermissionDisplay.patterns(request) }

    private var titleText: some View {
        Text(PermissionDisplay.visible(request.title))
            .font(theme.font(size: 12.5, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alwaysHelp(_ patterns: [String]) -> String {
        let base = patterns.isEmpty ? "Always allow" : "Always allow " + patterns.joined(separator: "; ")
        return hasShortcuts ? base + " (Option-Command-Y)" : base
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

/// A keyboard shortcut only on the prompt that owns the shortcuts, so two open prompts never share one.
private struct PermissionShortcut: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}
