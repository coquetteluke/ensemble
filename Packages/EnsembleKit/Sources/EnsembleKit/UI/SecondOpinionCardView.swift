import SwiftUI

/// Inline critique card rendered directly underneath a completed assistant reply.
public struct SecondOpinionCardView: View {
    let opinion: SecondOpinion
    let onRetry: () -> Void
    let onDismiss: () -> Void
    public var onUseModel: ((ModelRef) -> Void)?

    @Environment(\.theme) private var theme
    @State private var showFullText = false
    @State private var retryHovered = false
    @State private var dismissHovered = false
    @State private var toggleReviewHovered = false
    @State private var continueHovered = false

    public init(
        opinion: SecondOpinion,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onUseModel: ((ModelRef) -> Void)? = nil
    ) {
        self.opinion = opinion
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        self.onUseModel = onUseModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            header

            switch opinion.status {
            case .loading:
                HStack(spacing: theme.z(8)) {
                    Spinner(size: 11, color: theme.accent)
                    Text("Getting a second opinion from \(opinion.modelName)")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(theme.font(size: 11))
                        Text(message)
                            .font(theme.font(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.danger)

                    HStack(spacing: theme.z(8)) {
                        Button("Retry", action: onRetry)
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Dismiss", action: onDismiss)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }

            case .answered:
                answeredBody
            }
        }
        .padding(theme.z(12))
        .background(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: "text.bubble")
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.accent)

            Text("Second opinion")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            Text(opinion.modelName)
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            if !opinion.makerName.isEmpty,
               opinion.makerName.caseInsensitiveCompare(opinion.modelName) != .orderedSame,
               !opinion.modelName.localizedCaseInsensitiveContains(opinion.makerName) {
                Text(opinion.makerName)
                    .font(theme.font(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, theme.z(6))
                    .padding(.vertical, theme.z(1.5))
                    .background(Capsule().fill(theme.codeBackground))
            }

            if case .answered = opinion.status {
                verdictBadge(opinion.verdict)
            }

            Spacer(minLength: theme.z(6))

            if case .answered = opinion.status {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(retryHovered ? theme.textPrimary : theme.textSecondary)
                        .frame(width: theme.z(22), height: theme.z(22))
                        .background(
                            RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                                .fill(retryHovered ? theme.hover : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { retryHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: retryHovered)
                .help("Retry second opinion")
                .accessibilityLabel("Retry second opinion")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(theme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(dismissHovered ? theme.textPrimary : theme.textTertiary)
                    .frame(width: theme.z(22), height: theme.z(22))
                    .background(
                        RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                            .fill(dismissHovered ? theme.hover : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { dismissHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: dismissHovered)
            .help("Dismiss")
            .accessibilityLabel("Dismiss second opinion")
        }
    }

    private func verdictBadge(_ verdict: SecondOpinion.Verdict) -> some View {
        let tint: Color = switch verdict {
        case .agrees: theme.success
        case .mixed: theme.warning
        case .disagrees: theme.danger
        case .note: theme.accent
        }
        return Text(verdict.label)
            .font(theme.font(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, theme.z(6))
            .padding(.vertical, theme.z(2))
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    @ViewBuilder
    private var answeredBody: some View {
        if !opinion.summary.isEmpty {
            Text(opinion.summary)
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        if !opinion.concerns.isEmpty {
            VStack(alignment: .leading, spacing: theme.z(4)) {
                ForEach(Array(opinion.concerns.enumerated()), id: \.offset) { _, concern in
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(6)) {
                        Image(systemName: "exclamationmark.circle")
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.warning)
                        Text(concern)
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        if hasExtraDetails {
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showFullText.toggle() }
                } label: {
                    Text(showFullText ? "Hide full review" : "Show full review")
                        .font(theme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .underline(toggleReviewHovered)
                        .padding(.vertical, theme.z(2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { toggleReviewHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: toggleReviewHovered)

                if showFullText {
                    MarkdownView(opinion.fullText, streaming: false)
                        .padding(.horizontal, theme.z(10))
                        .padding(.vertical, theme.z(8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.codeBackground))
                        .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.separator))
                }
            }
        }

        if let onUseModel {
            HStack(spacing: theme.z(8)) {
                Button {
                    onUseModel(opinion.model)
                } label: {
                    HStack(spacing: theme.z(5)) {
                        Image(systemName: "arrow.right.circle")
                            .font(theme.font(size: 11.5, weight: .medium))
                            .foregroundStyle(continueHovered ? theme.accent : theme.textSecondary)
                        Text("Continue with \(opinion.modelName)")
                            .font(theme.font(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(continueHovered ? theme.textPrimary : theme.textSecondary)
                    .padding(.horizontal, theme.z(9))
                    .padding(.vertical, theme.z(4))
                    .background(
                        Capsule()
                            .fill(continueHovered ? theme.elevatedHover : theme.codeBackground)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(continueHovered ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { continueHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: continueHovered)
                .help("Continue this conversation with \(opinion.modelName)")
                Spacer(minLength: 0)
            }
            .padding(.top, theme.z(2))
        }
    }

    private var hasExtraDetails: Bool {
        let trimmed = opinion.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != opinion.summary
    }
}

#Preview("Second opinions") {
    VStack(spacing: 12) {
        SecondOpinionCardView(
            opinion: SecondOpinion(
                sessionID: "s1",
                itemID: "m1",
                replyText: "Sample reply",
                model: ModelRef(providerID: "google", id: "gemini-2.5-pro"),
                modelName: "Gemini 2.5 Pro",
                makerName: "Google",
                status: .loading
            ),
            onRetry: {},
            onDismiss: {}
        )
        SecondOpinionCardView(
            opinion: SecondOpinion(
                sessionID: "s1",
                itemID: "m2",
                replyText: "Sample reply",
                model: ModelRef(providerID: "openai", id: "gpt-5"),
                modelName: "GPT-5",
                makerName: "OpenAI",
                status: .answered,
                verdict: .mixed,
                summary: "The direction works, though error propagation and cleanup on task cancellation need explicit coverage.",
                concerns: [
                    "Temporary helper session deletion should run even if the outer task cancels.",
                    "Unverified folder trust check must reject ACP models before launching."
                ],
                fullText: "VERDICT: MIXED\nSUMMARY: The direction works, though error propagation and cleanup on task cancellation need explicit coverage.\nDETAILS:\nAdd a detached cleanup step and verify with PreviewEngine."
            ),
            onRetry: {},
            onDismiss: {},
            onUseModel: { _ in }
        )
        SecondOpinionCardView(
            opinion: SecondOpinion(
                sessionID: "s1",
                itemID: "m3",
                replyText: "Sample reply",
                model: ModelRef(providerID: "xai", id: "grok-4"),
                modelName: "Grok 4",
                makerName: "xAI",
                status: .failed("This folder is not trusted for that provider.")
            ),
            onRetry: {},
            onDismiss: {}
        )
    }
    .padding()
    .frame(width: 540)
    .ensembleTheme()
    .preferredColorScheme(.dark)
}
