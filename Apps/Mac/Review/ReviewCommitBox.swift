import SwiftUI
import EnsembleKit

/// Bottom of the pane: comments waiting to be sent, the last error, and the commit box.
struct ReviewFooter: View {
    @Bindable var model: ReviewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if !model.comments.isEmpty || model.sentNote != nil {
                HLine()
                ReviewCommentsBar(model: model)
            }
            if let error = model.actionError {
                HLine()
                errorRow(error)
            }
            if model.isGit, !model.files.isEmpty {
                HLine()
                ReviewCommitBox(model: model)
            }
        }
        .background(theme.panel)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.danger)
                .padding(.top, theme.z(1))
            Text(message)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableText()
            IconButton("xmark", help: "Dismiss", size: 18) { model.actionError = nil }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(8))
    }
}

/// "3 comments" with Clear and Send to agent (Shift-Command-Return).
struct ReviewCommentsBar: View {
    @Bindable var model: ReviewModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            if model.comments.isEmpty, let note = model.sentNote {
                Image(systemName: "checkmark.circle.fill")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.success)
                Text(note)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "text.bubble")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.accent)
                Text(model.comments.count == 1 ? "1 comment" : "\(model.comments.count) comments")
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Button("Clear") { model.clearComments() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .help("Delete every comment without sending")
                Button {
                    Task { await model.sendComments() }
                } label: {
                    HStack(spacing: theme.z(6)) {
                        if model.isSending { Spinner(size: 10, color: theme.onAccent) }
                        Text("Send to agent")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.isSending)
                .help(sendHelp)
            }
        }
        .padding(.horizontal, theme.z(14))
        .frame(height: theme.z(44))
    }

    private var sendHelp: String {
        let working = model.environment.isAgentWorking(model.focusedAgentID)
        return working
            ? "Sends every comment as one message when the agent's turn ends (Shift-Command-Return)"
            : "Sends every comment as one message (Shift-Command-Return)"
    }
}

/// Message field with Write message and Commit. Commits what is staged; with nothing staged, stages every
/// change shown first.
struct ReviewCommitBox: View {
    @Bindable var model: ReviewModel
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(6)) {
                Text("Commit")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: theme.z(8))
                Text(summary)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            messageField
            HStack(spacing: theme.z(8)) {
                Button {
                    Task { await model.writeMessage() }
                } label: {
                    HStack(spacing: theme.z(6)) {
                        if model.isWritingMessage {
                            Spinner(size: 10)
                        } else {
                            Image(systemName: "sparkles").font(theme.font(size: 11))
                        }
                        Text(model.isWritingMessage ? "Writing" : "Write message")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isWritingMessage || model.uncommittedFiles.isEmpty)
                .help("Ask the agent for a one-line summary of what will be committed")
                if let commit = model.lastCommit {
                    HStack(spacing: theme.z(5)) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                        Text("Committed \(commit)").foregroundStyle(theme.textSecondary)
                    }
                    .font(theme.font(size: 11.5))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await model.commit() }
                } label: {
                    HStack(spacing: theme.z(6)) {
                        if model.isCommitting { Spinner(size: 10, color: theme.onAccent) }
                        Text(model.commitTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canCommit)
                .help(model.stagedFiles.isEmpty ? "Stage every change shown here, then commit" : "Commit the staged changes")
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(12))
    }

    private var summary: String {
        let staged = model.stagedFiles.count
        let total = model.uncommittedFiles.count
        let files = total == 0 ? "Nothing to commit" : (staged == 0 ? "Nothing staged" : "\(staged) of \(total) staged")
        let branch = model.commitBranches
        return branch.isEmpty ? files : "\(files) on \(branch)"
    }

    @ViewBuilder private var messageField: some View {
        let shape = RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
        Group {
            if isSnapshot {
                Text(model.commitMessage.isEmpty ? "Commit message" : model.commitMessage)
                    .foregroundStyle(model.commitMessage.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                TextField("", text: $model.commitMessage, prompt: Text("Commit message").foregroundStyle(theme.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1...5)
            }
        }
        .font(theme.font(size: 12.5))
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(8))
        .frame(minHeight: theme.z(34), alignment: .topLeading)
        .background(shape.fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035)))
        .overlay(shape.strokeBorder(theme.border, lineWidth: 1))
    }
}
