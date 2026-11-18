import SwiftUI
import EnsembleKit

/// The session's proposal cards (`propose_session`), in the order the agent made them, under the transcript.
struct ProposalCardsHost: View {
    let session: SessionModel
    var center: AgentToolsCenter = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        if let coordinator = center.coordinator {
            let proposals = coordinator.proposals(for: session.id)
            if !proposals.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(10)) {
                    ForEach(proposals) { proposal in
                        ProposalCardView(
                            proposal: proposal,
                            onStart: { Task { await coordinator.start(proposal.id) } },
                            onDoItHere: { Task { await coordinator.doItHere(proposal.id) } },
                            onDismiss: { coordinator.dismiss(proposal.id) },
                            onOpen: { center.open($0) }
                        )
                    }
                }
            }
        }
    }
}
