import SwiftUI
import EnsembleKit

/// The rounded card every account row sits in.
struct AccountCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var compact = false
    let content: Content

    init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(compact ? 8 : 10)) { content }
            .padding(.horizontal, theme.z(compact ? 12 : 14))
            .padding(.vertical, theme.z(compact ? 8 : 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
    }
}

/// Avatar, name, an optional second line, and the connection state on the right.
struct AccountHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var subtitle: String?
    let status: AccountStatus
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, status: AccountStatus, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: theme.z(10)) {
            LetterAvatar(title, size: 22)
            VStack(alignment: .leading, spacing: theme.z(1)) {
                Text(title)
                    .font(theme.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: theme.z(8))
            AccountStatusLabel(status: status)
            trailing
        }
    }
}

extension AccountHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, status: AccountStatus) {
        self.init(title: title, subtitle: subtitle, status: status) { EmptyView() }
    }
}

/// Connection state of an account.
struct AccountStatus: Equatable {
    enum Tone { case good, warning, off, working }
    var text: String
    var tone: Tone

    static func good(_ text: String) -> AccountStatus { AccountStatus(text: text, tone: .good) }
    static func warning(_ text: String) -> AccountStatus { AccountStatus(text: text, tone: .warning) }
    static func off(_ text: String) -> AccountStatus { AccountStatus(text: text, tone: .off) }
    static func working(_ text: String) -> AccountStatus { AccountStatus(text: text, tone: .working) }
}

struct AccountStatusLabel: View {
    @Environment(\.theme) private var theme
    let status: AccountStatus

    var body: some View {
        HStack(spacing: theme.z(6)) {
            if status.tone == .working {
                Spinner(size: theme.z(10), lineWidth: 1.4)
            } else {
                StatusDot(color)
            }
            Text(status.text)
                .font(theme.font(size: 12))
                .foregroundStyle(status.tone == .off ? theme.textTertiary : theme.textSecondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var color: Color {
        switch status.tone {
        case .good: theme.success
        case .warning: theme.warning
        case .off, .working: theme.textTertiary.opacity(0.6)
        }
    }
}

/// A status line under a row (saved, failed...).
struct AccountNoteText: View {
    @Environment(\.theme) private var theme
    let note: AccountNote?

    var body: some View {
        if let note {
            Text(note.text)
                .font(theme.font(size: 11.5))
                .foregroundStyle(note.isError ? theme.danger : theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
        }
    }
}

/// One step of setup instructions: a sentence or a command to run in Terminal.
enum SetupStep: Hashable {
    case text(String)
    case command(String)
}

struct SetupStepsView: View {
    @Environment(\.theme) private var theme
    let steps: [SetupStep]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            ForEach(steps, id: \.self) { step in
                switch step {
                case .text(let text):
                    Text(text)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .command(let command):
                    TerminalCommandView(command: command)
                }
            }
        }
    }
}

/// A Terminal command with a Copy button.
struct TerminalCommandView: View {
    @Environment(\.theme) private var theme
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Text(command)
                .font(theme.font(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .selectableText()
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                copyToPasteboard(command)
                copied = true
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(6))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
    }
}

/// The fields of a sign-in method's form. Hidden fields and fields whose condition is not met are left out.
struct AccountFormFields: View {
    @Environment(\.theme) private var theme
    let fields: [OpenCodeIntegration.FormField]
    @Binding var values: [String: String]

    var body: some View {
        let visible = fields.filter { $0.kind != .external && $0.isVisible(in: values, fields: fields) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: theme.z(8)) {
                ForEach(visible) { field in
                    VStack(alignment: .leading, spacing: theme.z(4)) {
                        Text(field.title ?? field.key)
                            .font(theme.font(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        control(for: field)
                        if let summary = field.summary {
                            Text(summary)
                                .font(theme.font(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func control(for field: OpenCodeIntegration.FormField) -> some View {
        if field.kind == .boolean {
            Toggle(field.title ?? field.key, isOn: Binding(
                get: { (values[field.key] ?? field.defaultValue) == "true" },
                set: { values[field.key] = $0 ? "true" : "false" }))
                .labelsHidden()
                .toggleStyle(CompactSwitchStyle())
        } else if !field.options.isEmpty && !field.allowsCustom {
            Picker(field.title ?? field.key, selection: binding(for: field)) {
                if field.defaultValue == nil { Text("Choose").tag("") }
                ForEach(field.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: theme.z(320), alignment: .leading)
        } else {
            HStack(spacing: theme.z(6)) {
                InputField(field.placeholder ?? field.defaultValue ?? "", text: binding(for: field))
                if !field.options.isEmpty {
                    Menu {
                        ForEach(field.options, id: \.value) { option in
                            Button(option.label) { values[field.key] = option.value }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick a value")
                }
            }
        }
    }

    private func binding(for field: OpenCodeIntegration.FormField) -> Binding<String> {
        Binding(get: { values[field.key] ?? field.defaultValue ?? "" }, set: { values[field.key] = $0 })
    }
}

/// A section heading inside the Accounts tab.
struct AccountsSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(theme.font(size: 12, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.top, theme.z(8))
    }
}
