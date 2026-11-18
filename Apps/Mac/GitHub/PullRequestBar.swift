import SwiftUI
import AppKit
import EnsembleKit

/// Above the composer: the session branch's pull request with its checks, review and actions, or the step
/// that comes before one (Create branch, Create pull request, installing or signing in to gh). Hidden when the
/// folder is not a GitHub repository.
struct PullRequestBar: View {
    @Bindable var controller: GitHubPullRequestController
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
                .padding(.leading, theme.z(12))
                .padding(.trailing, theme.z(6))
                .frame(minHeight: theme.z(38))
            if let error = controller.actionError {
                HLine()
                MessageLine(symbol: "exclamationmark.triangle.fill", tint: theme.danger, text: error) { controller.actionError = nil }
            } else if let notice = controller.notice {
                HLine()
                MessageLine(symbol: "checkmark.circle.fill", tint: theme.success, text: notice) { controller.notice = nil }
                    .task(id: notice) {
                        guard !isSnapshot else { return }
                        try? await Task.sleep(for: .seconds(8))
                        if controller.notice == notice { controller.notice = nil }
                    }
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pull request")
        .alert(controller.confirmation?.title ?? "", isPresented: confirmationShown, presenting: controller.confirmation) { confirmation in
            Button(confirmation.confirmTitle) { Task { await controller.confirm() } }
            Button("Cancel", role: .cancel) { controller.cancelConfirmation() }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(isPresented: formShown) {
            PullRequestFormSheet(controller: controller)
        }
    }

    /// The bar's own alert; while the form is open the form shows the confirmation instead.
    private var confirmationShown: Binding<Bool> {
        Binding(get: { controller.confirmation != nil && controller.form == nil },
                set: { if !$0, controller.form == nil { controller.cancelConfirmation() } })
    }

    private var formShown: Binding<Bool> {
        Binding(get: { controller.form != nil && !isSnapshot }, set: { if !$0 { controller.cancelPullRequest() } })
    }

    @ViewBuilder private var row: some View {
        switch controller.state {
        case .pullRequest(let pr):
            PullRequestRow(controller: controller, pr: pr)
        case .noPullRequest(let branch, let base):
            BranchRow(controller: controller, branch: branch, base: base)
        case .defaultBranch(let branch):
            DefaultBranchRow(controller: controller, branch: branch)
        case .needsCLI:
            NoteRow(symbol: "terminal", title: "GitHub CLI not installed", lead: "Install it with", code: "brew install gh",
                    trail: nil, controller: controller)
        case .signedOut(let host, let problem):
            NoteRow(symbol: "person.crop.circle.badge.exclamationmark", title: problem ?? "Not signed in to \(host == "github.com" ? "GitHub" : host)",
                    lead: "Sign in with", code: host == "github.com" ? "gh auth login" : "gh auth login -h \(host)", trail: "in Terminal",
                    controller: controller)
        case .failed(let message):
            FailedRow(controller: controller, message: message)
        case .loading, .hidden:
            EmptyView()
        }
    }
}

// MARK: Rows

/// "#42 Fix the README · 2 checks failing · Changes requested" with Fix checks, Push and the menu.
private struct PullRequestRow: View {
    @Bindable var controller: GitHubPullRequestController
    let pr: GitHubPullRequest
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                .font(theme.font(size: 12.5, weight: .semibold))
                .foregroundStyle(GitHubColors.state(pr, theme))
                .frame(width: theme.z(16))
                .help(pr.stateLabel)
            Button {
                if let url = controller.pullRequestURL { openURL(url) }
            } label: {
                HStack(spacing: theme.z(6)) {
                    Text("#\(pr.number)")
                        .font(theme.font(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(pr.title)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open #\(pr.number) on GitHub")
            .layoutPriority(-1)
            Spacer(minLength: theme.z(6))
            status
            actions
            PullRequestMenu(controller: controller, pr: pr)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: theme.z(10)) {
            if pr.state != .open || pr.isDraft {
                StateBadge(text: pr.stateLabel, tint: GitHubColors.state(pr, theme))
            }
            if pr.isOpen {
                if pr.autoMergeEnabled {
                    HStack(spacing: theme.z(4)) {
                        Image(systemName: "arrow.triangle.merge").font(theme.font(size: 11, weight: .semibold))
                        Text("Auto-merge on").font(theme.font(size: 12))
                    }
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .help("GitHub merges #\(pr.number) once its required checks and reviews pass")
                }
                if let decision = pr.reviewDecision {
                    Text(decision.label)
                        .font(theme.font(size: 12))
                        .foregroundStyle(GitHubColors.review(decision, theme))
                        .lineLimit(1)
                }
                ChecksSummaryView(pr: pr)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var actions: some View {
        if pr.isOpen, !pr.failingChecks.isEmpty {
            BarButton(title: controller.busy.contains(.fixing) ? "Fetching logs" : "Fix checks", symbol: "wrench.and.screwdriver",
                      busy: controller.busy.contains(.fixing),
                      help: "Send the failed logs to the agent as one message") {
                Task { await controller.fixFailingChecks() }
            }
        }
        if pr.isOpen, let plan = controller.pushPlan {
            BarButton(title: controller.busy.contains(.pushing) ? "Pushing" : "Push", symbol: "arrow.up",
                      busy: controller.busy.contains(.pushing),
                      help: "Push \(plan.commits.map { $0 == 1 ? "1 commit" : "\($0) commits" } ?? plan.branch) to \(plan.remoteName)") {
                Task { await controller.requestPush() }
            }
        }
    }
}

/// The checks in one item: a coloured symbol and "2 checks failing", with each check in the tooltip.
private struct ChecksSummaryView: View {
    let pr: GitHubPullRequest
    @Environment(\.theme) private var theme

    var body: some View {
        let summary = pr.checkSummary
        if summary.overall != .none {
            HStack(spacing: theme.z(5)) {
                switch summary.overall {
                case .pending:
                    Spinner(size: 10, lineWidth: 1.6, color: theme.warning)
                case .failing:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.danger)
                default:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                }
                Text(summary.label)
                    .foregroundStyle(summary.overall == .failing ? theme.danger : theme.textSecondary)
            }
            .font(theme.font(size: 12))
            .lineLimit(1)
            .help(pr.checks.map { "\($0.label): \(Self.word($0.bucket))" }.joined(separator: "\n"))
        }
    }

    static func word(_ bucket: GitHubCheck.Bucket) -> String {
        switch bucket {
        case .pass: "passed"
        case .fail: "failed"
        case .pending: "running"
        case .skipping: "skipped"
        case .cancel: "cancelled"
        }
    }
}

/// A branch without a pull request: its name, how far ahead it is, and Create pull request.
private struct BranchRow: View {
    @Bindable var controller: GitHubPullRequestController
    let branch: String
    let base: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            BranchName(branch)
            if let detail {
                Text(detail)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: theme.z(6))
            Button {
                Task { await controller.beginPullRequest() }
            } label: {
                HStack(spacing: theme.z(5)) {
                    if controller.busy.contains(.creatingPullRequest) {
                        Spinner(size: 10, color: theme.onAccent)
                    } else {
                        Image(systemName: "arrow.triangle.pull").font(theme.font(size: 11, weight: .semibold))
                    }
                    Text("Create pull request")
                }
            }
            .buttonStyle(SmallPrimaryButtonStyle())
            .disabled(controller.createUnavailableReason != nil || controller.busy.contains(.creatingPullRequest))
            .help(controller.createUnavailableReason ?? "Push \(branch) and open a pull request into \(base ?? "the default branch")")
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let ahead = controller.local?.ahead {
            let target = base ?? "the default branch"
            parts.append(ahead == 0 ? "No commits ahead of \(target)" : (ahead == 1 ? "1 commit ahead of \(target)" : "\(ahead) commits ahead of \(target)"))
        }
        if let uncommitted = controller.local?.uncommitted, uncommitted > 0 {
            parts.append(uncommitted == 1 ? "1 file not committed" : "\(uncommitted) files not committed")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

/// On the default branch: Create branch opens a field for the new branch's name.
private struct DefaultBranchRow: View {
    @Bindable var controller: GitHubPullRequestController
    let branch: String
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: theme.z(8)) {
            BranchName(branch)
            Text("Pull requests need their own branch")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: theme.z(6))
            BarButton(title: "Create branch", symbol: "plus", busy: controller.busy.contains(.creatingBranch),
                      help: "Make a branch from here and switch this folder to it") {
                controller.beginCreateBranch()
            }
            .popover(isPresented: branchShown, arrowEdge: .top) {
                CreateBranchPopover(controller: controller)
            }
        }
    }

    private var branchShown: Binding<Bool> {
        Binding(get: { controller.branchName != nil && !isSnapshot }, set: { if !$0 { controller.branchName = nil } })
    }
}

/// gh is missing or signed out: what to run in Terminal, and a close button.
private struct NoteRow: View {
    let symbol: String
    let title: String
    let lead: String
    let code: String
    let trail: String?
    let controller: GitHubPullRequestController
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.warning)
                .frame(width: theme.z(16))
            Text(title)
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            HStack(spacing: theme.z(5)) {
                Text(lead)
                CodeChip(code)
                if let trail { Text(trail) }
            }
            .font(theme.font(size: 12))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
            Spacer(minLength: theme.z(6))
            IconButton("arrow.clockwise", help: "Check again", size: 24) {
                Task { await controller.refresh(force: true) }
            }
            IconButton("xmark", help: "Hide for this session", size: 24) { controller.isDismissed = true }
        }
    }
}

private struct FailedRow: View {
    let controller: GitHubPullRequestController
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.warning)
                .frame(width: theme.z(16))
            Text("Could not check for a pull request: \(message)")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
            Spacer(minLength: theme.z(6))
            BarButton(title: "Try again", symbol: nil, busy: controller.isRefreshing, help: "Ask GitHub again") {
                Task { await controller.refresh(force: true) }
            }
            IconButton("xmark", help: "Hide for this session", size: 24) { controller.isDismissed = true }
        }
    }
}

/// The pull request's "..." menu: Open on GitHub, Fix failing checks, Merge when ready, the auto-archive
/// switch and Refresh.
private struct PullRequestMenu: View {
    @Bindable var controller: GitHubPullRequestController
    let pr: GitHubPullRequest
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.openURL) private var openURL

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Button("Open on GitHub") { if let url = controller.pullRequestURL { openURL(url) } }
                    .disabled(controller.pullRequestURL == nil)
                Divider()
                Button("Fix Failing Checks") { Task { await controller.fixFailingChecks() } }
                    .disabled(!pr.isOpen || pr.failingChecks.isEmpty || controller.busy.contains(.fixing))
                if pr.autoMergeEnabled {
                    Button("Turn Off Auto-merge") { Task { await controller.disableAutoMerge() } }
                        .disabled(controller.busy.contains(.merging))
                } else {
                    Button("Merge When Ready\u{2026}") { Task { await controller.requestMerge() } }
                        .disabled(!pr.isOpen || pr.isDraft || controller.busy.contains(.merging))
                }
                Divider()
                Toggle("Archive Session After Merge", isOn: $controller.autoArchive)
                Divider()
                Button("Refresh") { Task { await controller.refresh(force: true) } }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pull request actions")
        }
    }

    private var label: some View {
        Image(systemName: "ellipsis")
            .font(theme.font(size: 13, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .frame(width: theme.z(26), height: theme.z(26))
            .contentShape(Rectangle())
    }
}

// MARK: Pieces

private struct BranchName: View {
    let name: String
    @Environment(\.theme) private var theme

    init(_ name: String) { self.name = name }

    var body: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: "arrow.triangle.branch")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(16))
            Text(name)
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .layoutPriority(1)
    }
}

/// A command to type, in a monospaced chip; click to copy it.
private struct CodeChip: View {
    let code: String
    @Environment(\.theme) private var theme
    @State private var copied = false

    init(_ code: String) { self.code = code }

    var body: some View {
        Button {
            copyToPasteboard(code)
            copied = true
        } label: {
            Text(code)
                .font(theme.font(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.inlineCodeText)
                .padding(.horizontal, theme.z(5))
                .padding(.vertical, theme.z(1.5))
                .background(RoundedRectangle(cornerRadius: theme.z(4), style: .continuous).fill(theme.inlineCodeBackground))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy \(code)")
    }
}

private struct StateBadge: View {
    let text: String
    let tint: Color
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, theme.z(6))
            .padding(.vertical, theme.z(2))
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// A small bordered button that fits the bar's height.
private struct BarButton: View {
    let title: String
    let symbol: String?
    var busy = false
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(5)) {
                if busy {
                    Spinner(size: 10)
                } else if let symbol {
                    Image(systemName: symbol).font(theme.font(size: 10.5, weight: .semibold))
                }
                Text(title).font(theme.font(size: 12, weight: .medium))
            }
            .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, theme.z(8))
            .frame(height: theme.z(24))
            .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(hovering ? theme.elevatedHover : .clear))
            .overlay(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help(help)
        .fixedSize()
    }
}

/// The accent button at the bar's height.
private struct SmallPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, theme.z(9))
                .frame(height: theme.z(24))
                .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(theme.accent)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
                .contentShape(Rectangle())
                .fixedSize()
        }
    }
}

/// A line under the bar after an action: what worked or what failed, with a close button.
private struct MessageLine: View {
    let symbol: String
    let tint: Color
    let text: String
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 11))
                .foregroundStyle(tint)
                .frame(width: theme.z(16))
                .padding(.top, theme.z(1))
            Text(text)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableText()
            IconButton("xmark", help: "Dismiss", size: 20, action: onClose)
        }
        .padding(.leading, theme.z(12))
        .padding(.trailing, theme.z(6))
        .padding(.vertical, theme.z(6))
    }
}

enum GitHubColors {
    /// Green open, grey draft, purple merged, red closed (the colours GitHub uses).
    static func state(_ pr: GitHubPullRequest, _ theme: Theme) -> Color {
        switch pr.state {
        case .open: pr.isDraft ? theme.textTertiary : theme.success
        case .merged: theme.isDark ? Color(hex: 0xA371F7) : Color(hex: 0x8250DF)
        case .closed: theme.danger
        }
    }

    static func review(_ decision: GitHubPullRequest.ReviewDecision, _ theme: Theme) -> Color {
        switch decision {
        case .approved: theme.success
        case .changesRequested: theme.danger
        case .reviewRequired: theme.textTertiary
        }
    }
}
