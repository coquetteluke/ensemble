import SwiftUI
import EnsembleKit

/// Comments under one diff line, and the editor when you are writing one there.
struct ReviewLineComments: View {
    @Bindable var model: ReviewModel
    let key: ReviewLineKey
    let comments: [ReviewComment]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            ForEach(comments) { comment in
                if model.draft?.editing == comment.id {
                    ReviewCommentEditor(model: model)
                } else {
                    ReviewCommentCard(model: model, comment: comment)
                }
            }
            if let draft = model.draft, draft.key == key, draft.editing == nil {
                ReviewCommentEditor(model: model)
            }
        }
        .padding(.leading, theme.z(40))
        .padding(.trailing, theme.z(12))
        .padding(.vertical, theme.z(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
    }
}

/// A comment waiting to be sent: its text, with Edit and Delete.
struct ReviewCommentCard: View {
    @Bindable var model: ReviewModel
    let comment: ReviewComment
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: "text.bubble")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.accent)
                .padding(.top, theme.z(1.5))
            Text(comment.text)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableText()
            HStack(spacing: theme.z(2)) {
                IconButton("pencil", help: "Edit this comment", size: 20) { model.edit(comment) }
                IconButton("trash", help: "Delete this comment", size: 20) { model.delete(comment) }
            }
        }
        .padding(.leading, theme.z(10))
        .padding(.trailing, theme.z(4))
        .padding(.vertical, theme.z(7))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.accent.opacity(0.35)))
    }
}

/// Writing or editing a comment. Return adds it, Option-Return starts a new line, Escape cancels.
struct ReviewCommentEditor: View {
    @Bindable var model: ReviewModel
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    var body: some View {
        let draft = model.draft
        VStack(alignment: .trailing, spacing: theme.z(8)) {
            field(placeholder: draft.map { "Comment on line \($0.key.line)" } ?? "Comment")
                .padding(.horizontal, theme.z(10))
                .padding(.vertical, theme.z(8))
                .frame(maxWidth: .infinity, minHeight: theme.z(54), alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                        .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.7), lineWidth: theme.z(1))
                )
            HStack(spacing: theme.z(8)) {
                Button("Cancel") { model.cancelDraft() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(draft?.editing == nil ? "Add comment" : "Save") { model.saveDraft() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled((draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onExitCommand { model.cancelDraft() }
    }

    @ViewBuilder private func field(placeholder: String) -> some View {
        let text = model.draft?.text ?? ""
        if isSnapshot {
            Text(text.isEmpty ? placeholder : text)
                .font(theme.font(size: 12.5))
                .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: binding, prompt: Text(placeholder).foregroundStyle(theme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { model.saveDraft() }
                .onAppear { focused = true }
        }
    }

    private var binding: Binding<String> {
        Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 })
    }
}
