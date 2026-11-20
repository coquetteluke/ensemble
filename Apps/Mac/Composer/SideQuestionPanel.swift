import SwiftUI
import EnsembleKit

/// The `/btw` panel above the composer: a question about the session, answered in a hidden copy of it, so nothing
/// is added to the session itself. Close deletes the copy; Continue in new session keeps it as a normal session.
struct SideQuestionPanel: View {
    let question: SideQuestion
    let answer: String
    let streaming: Bool
    var onAsk: (String) -> Void
    var onContinue: () -> Void
    var onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HLine(color: theme.border)
            content
                .padding(.horizontal, theme.z(16))
                .padding(.vertical, theme.z(12))
            HLine(color: theme.border)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.popover))
        .overlay(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).strokeBorder(theme.border))
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: theme.z(14), y: theme.z(4))
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side question")
    }

    private var header: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "text.bubble")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.accent)
            Text("Side question")
                .font(theme.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Uses this session's context. Nothing is added to it.")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.z(14))
        .frame(height: theme.z(36))
    }

    @ViewBuilder private var content: some View {
        if question.phase == .composing {
            TextField("Ask about this session", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...6)
                .focused($fieldFocused)
                .onSubmit(ask)
                .onAppear { if !isSnapshot { fieldFocused = true } }
                .accessibilityLabel("Side question")
        } else {
            VStack(alignment: .leading, spacing: theme.z(10)) {
                Text(question.question)
                    .font(theme.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                answerView
            }
        }
    }

    @ViewBuilder private var answerView: some View {
        if case .failed(let message) = question.phase {
            HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(theme.font(size: 11))
                Text(message)
                    .font(theme.font(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme.danger)
        } else if answer.isEmpty {
            HStack(spacing: theme.z(8)) {
                Spinner(size: theme.z(11))
                Text("Answering")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
            }
        } else {
            AdaptiveScroll(.vertical) {
                MarkdownView(answer, streaming: streaming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: theme.z(300))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: theme.z(8)) {
            if question.phase == .composing {
                Text("Return asks")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Close", action: onClose)
                .buttonStyle(SecondaryButtonStyle())
                .help("Close and delete the side question's copy of the session")
            if question.phase == .composing {
                Button("Ask", action: ask)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Continue in new session", action: onContinue)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(question.forkSessionID == nil)
                    .help("Keep the question and its answer as a new session")
            }
        }
        .padding(.horizontal, theme.z(12))
        .frame(height: theme.z(46))
    }

    private func ask() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAsk(text)
    }
}
