import SwiftUI
import EnsembleKit

/// Cards the user closed, by session and turn, for this run of the app. A new turn gets a new card.
@Observable @MainActor
final class NextStepDismissals {
    static let shared = NextStepDismissals()
    private var dismissed: [String: String] = [:]

    func isDismissed(_ sessionID: String, turn: String) -> Bool { dismissed[sessionID] == turn }
    func dismiss(_ sessionID: String, turn: String) { dismissed[sessionID] = turn }
}

/// The next-step card for the session's newest turn, under the transcript: what the turn changed, the agent's
/// closing question, and buttons that answer it or open the changes. Nothing while the agent works or a prompt
/// waits (`NextStepBuilder`).
struct NextStepCardHost: View {
    let session: SessionModel
    var dismissals: NextStepDismissals = .shared
    @Environment(\.interactionStore) private var store

    var body: some View {
        if let step = NextStepBuilder.build(items: session.items, isWorking: session.isWorking,
                                            hasOpenPrompt: !session.pendingPermissions.isEmpty),
           !dismissals.isDismissed(session.id, turn: step.turnID) {
            NextStepCard(step: step, onAction: run) {
                dismissals.dismiss(session.id, turn: step.turnID)
            }
        }
    }

    private func run(_ action: NextStepAction) {
        if let reply = action.reply {
            guard let store else { return }
            let id = session.id
            Task { await store.send(reply, to: id) }
        } else {
            NotificationCenter.default.post(name: .ensembleShowReview, object: nil)
        }
    }
}

/// One next-step card. With a question: the recap, the question, then the buttons on their own row. Without one:
/// the recap and the button on a single row.
struct NextStepCard: View {
    let step: NextStep
    let onAction: (NextStepAction) -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let question = step.question {
                VStack(alignment: .leading, spacing: theme.z(10)) {
                    HStack(alignment: .top, spacing: theme.z(8)) {
                        VStack(alignment: .leading, spacing: theme.z(5)) {
                            if !step.recap.isEmpty { recap }
                            Text(question)
                                .font(theme.font(size: 13.5, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: theme.z(8))
                        dismiss
                    }
                    buttons
                }
            } else {
                HStack(spacing: theme.z(10)) {
                    recap
                    Spacer(minLength: theme.z(8))
                    buttons
                    dismiss
                }
            }
        }
        .padding(.leading, theme.z(14))
        .padding(.trailing, theme.z(8))
        .padding(.vertical, theme.z(10))
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.elevated.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).strokeBorder(theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next step")
    }

    private var recap: some View {
        Text(step.recap)
            .font(theme.font(size: 12.5))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: theme.z(8)) {
            ForEach(Array(step.actions.enumerated()), id: \.element) { index, action in
                if index == 0 {
                    Button(action.label) { onAction(action) }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(action.label) { onAction(action) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .fixedSize()
    }

    private var dismiss: some View {
        IconButton("xmark", help: "Hide until the next turn", size: 22, action: onDismiss)
    }
}

extension Notification.Name {
    /// Opens the review pane on the changes of the session on screen (the next-step card's Review changes).
    static let ensembleShowReview = Notification.Name("ensemble.showReview")
}
