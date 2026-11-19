import EnsembleKit
import SwiftUI

/// Adaptive theme wrapper for EnsembleKit's shared interactive cards on the phone.
enum PhoneCardTheme {
    static func theme(for scheme: ColorScheme) -> Theme {
        var base = scheme == .dark ? Theme.dark : Theme.light
        base.scale = 1.08
        return base
    }
}

/// An agent's question on the phone, answered through the Mac.
struct RemoteQuestionCard: View {
    let request: PermissionRequest
    let client: RemoteClient
    var onError: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var busy = false

    private var answered: Bool {
        client.isAnswered(request.id) || !client.permissions.contains { $0.id == request.id }
    }

    var body: some View {
        if answered {
            Label(
                client.permissionDecisions[request.id] == .reject ? "Question declined" : "Question answered",
                systemImage: client.permissionDecisions[request.id] == .reject ? "xmark.circle.fill" : "checkmark.circle.fill"
            )
            .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(RemoteTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            QuestionCardView(
                request: request,
                onAnswer: { answers in send(answers) },
                onDecline: { send([]) }
            )
            .environment(\.theme, PhoneCardTheme.theme(for: scheme))
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

/// A plan presented on the phone in Ensemble Serif Markdown, with Proceed modes and Keep planning.
struct RemotePlanCard: View {
    let request: PermissionRequest
    let client: RemoteClient
    var onError: (String) -> Void
    @State private var busy = false
    @State private var expanded = false
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 15

    private var plan: PlanProposal { request.plan ?? PlanProposal(markdown: request.title) }
    private var answered: Bool {
        client.isAnswered(request.id) || !client.permissions.contains { $0.id == request.id }
    }
    private var lines: [String] { plan.markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    private var isLong: Bool { lines.count > 14 }
    private var visibleMarkdown: String {
        if expanded || !isLong { return plan.markdown }
        return lines.prefix(14).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(RemoteTheme.accent)
                Text("Plan")
                    .font(RemoteTheme.font(size: 14.5, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(RemoteTheme.primaryText)
                Spacer()
            }

            MarkdownView(visibleMarkdown, fontSize: messageSize)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLong {
                Button(expanded ? "Show less" : "Show the whole plan") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(RemoteTheme.secondaryText)
                .frame(minHeight: 36)
            }

            if answered {
                Label(
                    client.permissionDecisions[request.id] == .reject ? "Kept planning" : "Proceeded",
                    systemImage: client.permissionDecisions[request.id] == .reject
                        ? "arrow.uturn.backward.circle.fill"
                        : "checkmark.circle.fill"
                )
                .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(RemoteTheme.secondaryText)
            } else {
                PlanButtons(plan: plan, onDecide: decide)
                    .disabled(busy || !client.state.isConnected)
            }
        }
        .remoteCard(padding: 14, attention: !answered)
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
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(plan.allowedProceedModes.enumerated()), id: \.element) { index, mode in
                if index == 0 {
                    Button("Proceed in \(mode.shortLabel)") { onDecide(.proceed(mode)) }
                        .buttonStyle(RemotePrimaryButtonStyle())
                } else {
                    Button("Proceed in \(mode.shortLabel)") { onDecide(.proceed(mode)) }
                        .buttonStyle(RemoteSecondaryButtonStyle())
                }
            }
            Button("Keep planning") { onDecide(.keepPlanning(comments: [])) }
                .buttonStyle(RemoteSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
