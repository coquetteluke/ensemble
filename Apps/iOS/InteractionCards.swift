import EnsembleKit
import SwiftUI

/// The theme the shared question card uses on the phone: Ensemble's dark theme, a little larger for touch.
enum PhoneCardTheme {
    static var theme: Theme {
        var theme = Theme.dark
        theme.scale = 1.15
        return theme
    }
}

/// An agent's question on the phone: the Mac's question card (`QuestionCardView`), answered through the Mac. Once
/// answered it shows a line saying so.
struct RemoteQuestionCard: View {
    let request: PermissionRequest
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var busy = false

    private var answered: Bool { client.isAnswered(request.id) || !client.permissions.contains { $0.id == request.id } }

    var body: some View {
        if answered {
            Label(client.permissionDecisions[request.id] == .reject ? "Question declined" : "Question answered",
                  systemImage: client.permissionDecisions[request.id] == .reject ? "xmark.circle" : "checkmark.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(RemoteTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            QuestionCardView(request: request,
                             onAnswer: { answers in send(answers) },
                             onDecline: { send([]) })
                .environment(\.theme, PhoneCardTheme.theme)
                .disabled(busy || !client.state.isConnected)
        }
    }

    private func send(_ answers: [AgentQuestionAnswer]) {
        busy = true
        Task {
            do { try await client.answer(request, answers: answers) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

/// A plan on the phone: the plan in the agent's serif, Proceed in the modes the plan offers, and Keep planning (line
/// comments are written on the Mac).
struct RemotePlanCard: View {
    let request: PermissionRequest
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var busy = false
    @State private var expanded = false

    private var plan: PlanProposal { request.plan ?? PlanProposal(markdown: request.title) }
    private var answered: Bool { client.isAnswered(request.id) || !client.permissions.contains { $0.id == request.id } }
    private var isLong: Bool { plan.markdown.split(separator: "\n").count > 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(Color.accentColor)
                Text("Plan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RemoteTheme.primaryText)
                Spacer()
            }
            AgentMessageText(text: plan.markdown, size: 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(expanded || !isLong ? nil : 14)
            if isLong {
                Button(expanded ? "Show less" : "Show the whole plan") { withAnimation(.snappy) { expanded.toggle() } }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RemoteTheme.secondaryText)
            }
            if answered {
                Label(client.permissionDecisions[request.id] == .reject ? "Kept planning" : "Proceeded",
                      systemImage: client.permissionDecisions[request.id] == .reject ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RemoteTheme.secondaryText)
            } else {
                PlanButtons(plan: plan, onDecide: decide)
                    .disabled(busy || !client.state.isConnected)
            }
        }
        .remoteCard(padding: 12)
    }

    private func decide(_ decision: PlanDecision) {
        busy = true
        Task {
            do { try await client.respond(to: request, decision: decision) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

/// Proceed in each mode the plan offers, then Keep planning.
struct PlanButtons: View {
    let plan: PlanProposal
    let onDecide: (PlanDecision) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(plan.allowedProceedModes.enumerated()), id: \.element) { index, mode in
            if index == 0 {
                Button("Proceed in \(mode.shortLabel)") { onDecide(.proceed(mode)) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Proceed in \(mode.shortLabel)") { onDecide(.proceed(mode)) }
                    .buttonStyle(.bordered)
            }
        }
        Button("Keep planning") { onDecide(.keepPlanning(comments: [])) }
            .buttonStyle(.bordered)
    }
}
