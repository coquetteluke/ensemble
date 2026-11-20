import SwiftUI
import EnsembleKit

/// Settings: whether the GitHub CLI is installed and which accounts it is signed in to. Ensemble never signs
/// in itself and never sees the token; this only reads `gh auth status` through `GitHubService`.
struct GitHubSettingsSection: View {
    /// Snapshots pass a status instead of running gh.
    var statusOverride: GitHubCLIStatus?
    /// Snapshots pass whether git has a credential helper.
    var helperOverride: Bool?
    @Environment(\.theme) private var theme
    @State private var status: GitHubCLIStatus?
    @State private var helper: Bool?
    @State private var checking = false

    private var shown: GitHubCLIStatus? { statusOverride ?? status }
    private var hasHelper: Bool? { helperOverride ?? helper }

    var body: some View {
        Section {
            LabeledContent("GitHub CLI") {
                HStack(spacing: theme.z(6)) {
                    if checking && shown == nil {
                        Spinner(size: 10)
                        Text("Checking")
                    } else {
                        StatusDot(cliColor)
                        Text(cliText)
                    }
                }
            }
            if let info = shown?.info {
                LabeledContent("Location") {
                    Text(info.path)
                        .font(theme.font(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(info.path)
                }
                if info.accounts.isEmpty {
                    LabeledContent("Account") {
                        HStack(spacing: theme.z(6)) {
                            StatusDot(theme.warning)
                            Text(info.problem ?? "Not signed in")
                        }
                    }
                } else {
                    ForEach(info.accounts, id: \.self) { account in
                        LabeledContent(account.active ? "Account" : "Other account") {
                            HStack(spacing: theme.z(6)) {
                                StatusDot(accountColor(account))
                                Text("\(account.login) on \(account.host)")
                                if account.state != .valid {
                                    Text(account.state == .invalid ? "Sign-in no longer works" : "Could not reach \(account.host)")
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
            if let hasHelper {
                LabeledContent("HTTPS pushes") {
                    HStack(spacing: theme.z(6)) {
                        StatusDot(hasHelper ? theme.success : theme.warning)
                        Text(hasHelper ? "git has a sign-in helper" : "git has no sign-in helper")
                    }
                }
            }
            HStack {
                Spacer()
                Button(checking ? "Checking\u{2026}" : "Check again") { Task { await check() } }
                    .disabled(checking || statusOverride != nil)
            }
        } header: {
            Text("GitHub")
        } footer: {
            Text(footer)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
        }
        .task {
            guard statusOverride == nil, status == nil else { return }
            await check()
        }
    }

    private var footer: String {
        let base = "Pull requests use the GitHub CLI (gh). Ensemble never sees your GitHub token."
        let helperNote = hasHelper == false
            ? " To push over HTTPS, also run gh auth setup-git in Terminal so git signs in with gh." : ""
        switch shown {
        case .notInstalled?:
            return base + " Install it with brew install gh, then run gh auth login in Terminal." + helperNote
        case .installed(let info)? where info.accounts.isEmpty || info.accounts.allSatisfy({ $0.state == .invalid }):
            return base + " To sign in, run gh auth login in Terminal." + helperNote
        default:
            return base + " To sign in to another account, run gh auth login in Terminal." + helperNote
        }
    }

    private var cliText: String {
        switch shown {
        case .notInstalled?: "Not installed"
        case .installed(let info)?: info.version.map { "Installed, version \($0)" } ?? "Installed"
        case nil: "Not checked"
        }
    }

    private var cliColor: Color {
        switch shown {
        case .notInstalled?: theme.danger
        case .installed?: theme.success
        case nil: theme.textTertiary
        }
    }

    private func accountColor(_ account: GitHubAccount) -> Color {
        switch account.state {
        case .valid: account.active ? theme.success : theme.textTertiary
        case .invalid: theme.danger
        case .unverified: theme.warning
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let service = GitHubService()
        status = await service.cliStatus()
        helper = await service.hasGlobalCredentialHelper()
    }
}

/// The GitHub section as a whole Settings tab.
struct GitHubSettingsTab: View {
    var statusOverride: GitHubCLIStatus?
    var helperOverride: Bool?

    var body: some View {
        Form {
            GitHubSettingsSection(statusOverride: statusOverride, helperOverride: helperOverride)
        }
        .formStyle(.grouped)
        .zoomedForm()
    }
}
