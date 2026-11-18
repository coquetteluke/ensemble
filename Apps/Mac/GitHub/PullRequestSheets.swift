import SwiftUI
import EnsembleKit

/// Create pull request: title, description (Write description asks a hidden copy of the session), draft
/// switch. Open pull request asks for a confirmation that names the remote, branch and repository first.
struct PullRequestFormSheet: View {
    @Bindable var controller: GitHubPullRequestController
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(14)) {
            VStack(alignment: .leading, spacing: theme.z(4)) {
                Text("Create pull request")
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if let form = controller.form {
                    HStack(spacing: theme.z(5)) {
                        Text(form.head).fontWeight(.medium).foregroundStyle(theme.textSecondary)
                        Image(systemName: "arrow.right").font(theme.font(size: 10, weight: .semibold))
                        Text(form.base).fontWeight(.medium).foregroundStyle(theme.textSecondary)
                        Text("in \(form.remote.slug)")
                    }
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            field("Title") { titleField }
            field("Description") { bodyField }
            HStack(spacing: theme.z(10)) {
                Button {
                    Task { await controller.writeDescription() }
                } label: {
                    HStack(spacing: theme.z(6)) {
                        if controller.busy.contains(.writingDescription) {
                            Spinner(size: 10)
                        } else {
                            Image(systemName: "sparkles").font(theme.font(size: 11))
                        }
                        Text(controller.busy.contains(.writingDescription) ? "Writing" : "Write description")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(controller.busy.contains(.writingDescription))
                .help("Ask the agent for a title and description of the branch's changes")
                Toggle("Open as draft", isOn: draftBinding)
                    .toggleStyle(CompactSwitchStyle())
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            if let error = controller.formError {
                HStack(alignment: .top, spacing: theme.z(6)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .padding(.top, theme.z(1))
                    Text(error)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableText()
                }
                .font(theme.font(size: 12))
            }
            HLine()
            HStack(spacing: theme.z(8)) {
                Text(pushNote)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.z(8))
                Button("Cancel") { controller.cancelPullRequest() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await controller.requestCreatePullRequest() }
                } label: {
                    HStack(spacing: theme.z(6)) {
                        if controller.busy.contains(.creatingPullRequest) { Spinner(size: 10, color: theme.onAccent) }
                        Text(controller.form?.draft == true ? "Open draft" : "Open pull request")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canOpen)
            }
        }
        .padding(theme.z(20))
        .frame(width: theme.z(560))
        .background(theme.background)
        .alert(controller.confirmation?.title ?? "", isPresented: confirmationShown, presenting: controller.confirmation) { confirmation in
            Button(confirmation.confirmTitle) { Task { await controller.confirm() } }
            Button("Cancel", role: .cancel) { controller.cancelConfirmation() }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var canOpen: Bool {
        guard let form = controller.form else { return false }
        return !form.trimmedTitle.isEmpty && !controller.busy.contains(.creatingPullRequest)
            && !controller.busy.contains(.writingDescription)
    }

    /// What Open pull request will send, so nothing about the push is a surprise.
    private var pushNote: String {
        guard let plan = controller.pushPlan else { return "The branch is already on GitHub." }
        let what = plan.commits.map { $0 == 1 ? "1 new commit" : "\($0) new commits" } ?? plan.branch
        return "Pushes \(what) to \(plan.remoteName) first. Never force-pushed."
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { controller.confirmation != nil }, set: { if !$0 { controller.cancelConfirmation() } })
    }

    private var draftBinding: Binding<Bool> {
        Binding(get: { controller.form?.draft ?? false }, set: { controller.form?.draft = $0 })
    }

    private var titleBinding: Binding<String> {
        Binding(get: { controller.form?.title ?? "" }, set: { controller.form?.title = $0 })
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { controller.form?.body ?? "" }, set: { controller.form?.body = $0 })
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text(label)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            content()
        }
    }

    @ViewBuilder private var titleField: some View {
        let title = controller.form?.title ?? ""
        Group {
            if isSnapshot {
                Text(title.isEmpty ? "Title" : title)
                    .foregroundStyle(title.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: titleBinding, prompt: Text("Title").foregroundStyle(theme.textTertiary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .font(theme.font(size: 13))
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(32))
        .modifier(FieldChrome())
    }

    @ViewBuilder private var bodyField: some View {
        let body = controller.form?.body ?? ""
        Group {
            if isSnapshot {
                Text(body.isEmpty ? "What changed and why" : body)
                    .foregroundStyle(body.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(8))
            } else {
                TextEditor(text: bodyBinding)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, theme.z(6))
                    .padding(.vertical, theme.z(6))
                    .overlay(alignment: .topLeading) {
                        if body.isEmpty {
                            Text("What changed and why")
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, theme.z(11))
                                .padding(.vertical, theme.z(6))
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .font(theme.font(size: 13))
        .frame(height: theme.z(180))
        .modifier(FieldChrome())
    }
}

/// The name field for Create branch.
struct CreateBranchPopover: View {
    @Bindable var controller: GitHubPullRequestController
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            Text("Create branch")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Group {
                if isSnapshot {
                    Text(controller.branchName ?? "")
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: nameBinding, prompt: Text("Branch name").foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .onSubmit { Task { await controller.createBranch() } }
                }
            }
            .font(theme.font(size: 12.5, design: .monospaced))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(30))
            .modifier(FieldChrome())
            Text("Switches this folder to the new branch. Uncommitted changes come along.")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: theme.z(8)) {
                Spacer(minLength: 0)
                Button("Cancel") { controller.branchName = nil }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await controller.createBranch() }
                } label: {
                    HStack(spacing: theme.z(6)) {
                        if controller.busy.contains(.creatingBranch) { Spinner(size: 10, color: theme.onAccent) }
                        Text("Create branch")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled((controller.branchName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    || controller.busy.contains(.creatingBranch))
            }
        }
        .padding(theme.z(14))
        .frame(width: theme.z(340))
        .background(theme.popover)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { controller.branchName ?? "" }, set: { controller.branchName = $0 })
    }
}

private struct FieldChrome: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
        content
            .background(shape.fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035)))
            .overlay(shape.strokeBorder(theme.border, lineWidth: 1))
    }
}
