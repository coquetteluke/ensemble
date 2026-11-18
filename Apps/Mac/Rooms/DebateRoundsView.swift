import SwiftUI
import EnsembleKit

/// Debate rounds side by side: one row per round, one card per agent, then the verdict.
struct DebateRoundsView: View {
    let controller: RoomsController
    let engine: RoomEngine
    let models: [ModelInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        let state = engine.state
        VStack(alignment: .leading, spacing: theme.z(22)) {
            if let debate = state.debate {
                VStack(alignment: .leading, spacing: theme.z(4)) {
                    Text("Question")
                        .font(theme.font(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Text(debate.question)
                        .font(theme.font(size: 15, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableText()
                }
                ForEach(1...max(1, debate.totalRounds), id: \.self) { round in
                    if round <= debate.round || !debate.arguments(inRound: round).isEmpty {
                        roundRow(round, debate: debate, phase: state.phase)
                    }
                }
                if state.phase == .judging, let judge = debate.judgeID.flatMap({ engine.agent($0) }) {
                    if let text = controller.liveText(of: judge.id, in: engine) {
                        LiveAgentRow(agent: judge, text: text, models: models)
                    } else {
                        HStack(spacing: theme.z(8)) {
                            Spinner(size: 11, color: Color(hexString: judge.colorHex))
                            Text("\(judge.name) is writing the verdict")
                                .font(theme.font(size: 12.5))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                if let verdict = debate.verdict, state.phase != .verdict {
                    VerdictCard(engine: engine, verdict: verdict, actionable: false)
                }
            } else {
                Text("No debate yet. Ask the room a question.")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func roundRow(_ round: Int, debate: DebateState, phase: RoomPhase) -> some View {
        let current = round == debate.round && phase == .debating
        let rows = chunks(engine.agents, size: 3)
        return VStack(alignment: .leading, spacing: theme.z(10)) {
            HStack(spacing: theme.z(8)) {
                Text("Round \(round)")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if current { RoomTag(text: "In progress", color: theme.accent) }
                Spacer(minLength: 0)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: theme.z(10)) {
                    ForEach(row) { agent in
                        ArgumentCard(agent: agent,
                                     text: debate.arguments(inRound: round).last { $0.agentID == agent.id }?.text,
                                     live: current ? controller.liveText(of: agent.id, in: engine) : nil,
                                     pending: current,
                                     models: models)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chunks(_ list: [AgentSpec], size: Int) -> [[AgentSpec]] {
        stride(from: 0, to: list.count, by: size).map { Array(list[$0..<min($0 + size, list.count)]) }
    }
}

/// One agent's argument in one round.
private struct ArgumentCard: View {
    let agent: AgentSpec
    let text: String?
    let live: String?
    let pending: Bool
    let models: [ModelInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        let color = Color(hexString: agent.colorHex)
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(6)) {
                AgentHeader(agent: agent, models: models)
                Spacer(minLength: 0)
                if text == nil && pending { Spinner(size: 10, color: color) }
            }
            if let text {
                MarkdownView(text, fontSize: 13, textColor: theme.textPrimary)
            } else if let live {
                MarkdownView(live, fontSize: 13, textColor: theme.textSecondary)
            } else {
                Text(pending ? "Thinking" : "No argument this round")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(theme.z(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.elevated))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: theme.z(9), topTrailingRadius: theme.z(9), style: .continuous)
                .fill(color)
                .frame(height: theme.z(3))
        }
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.border))
        .clipShape(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous))
    }
}
