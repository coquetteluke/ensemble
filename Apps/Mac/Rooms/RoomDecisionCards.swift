import SwiftUI
import EnsembleKit

/// The card for whatever the room is waiting on the user for, plus the verdict card after a debate.
struct RoomDecisionArea: View {
    let engine: RoomEngine
    let models: [ModelInfo]
    @Environment(\.theme) private var theme

    var body: some View {
        let state = engine.state
        VStack(alignment: .leading, spacing: theme.z(12)) {
            switch state.pendingDecision {
            case .approvePlan?:
                PlanApprovalCard(engine: engine)
            case .writePlan?:
                WritePlanCard(engine: engine)
            case .reviewStalemate(let agentID)?:
                ReviewStalemateCard(engine: engine, authorID: agentID)
            case .takeover(let agentID)?:
                TakeoverCard(engine: engine, agentID: agentID)
            case .judge?:
                JudgeCard(engine: engine)
            case .mergeConflict(let agentID, let files)?:
                MergeConflictCard(engine: engine, agentID: agentID, files: files)
            case nil:
                EmptyView()
            }
            if state.phase == .verdict, let verdict = state.debate?.verdict {
                VerdictCard(engine: engine, verdict: verdict, actionable: true)
            }
        }
    }
}

/// Card title row: icon, title, and who it is about.
private struct DecisionHeader: View {
    let symbol: String
    let title: String
    var agent: AgentSpec?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(title)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let agent {
                HStack(spacing: theme.z(5)) {
                    AgentDot(hex: agent.colorHex, size: 7)
                    Text(agent.name)
                }
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

/// Team in Ask or Accept-edits mode: approve, edit or redo the lead's plan.
struct PlanApprovalCard: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var redoing = false
    @State private var editText = ""
    @State private var feedback = ""

    var body: some View {
        let state = engine.state
        RoomCard(accent: theme.accent) {
            DecisionHeader(symbol: "checklist", title: "The plan is ready", agent: engine.leadID.flatMap { engine.agent($0) })
            if editing {
                RoomTextEditor(placeholder: "PLAN: ...\nASSIGN @Name: task", text: $editText, minHeight: 140, maxHeight: 320, monospaced: true)
                Text("Keep one ASSIGN @Name: line per agent.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                HStack(spacing: theme.z(8)) {
                    Button("Start with this plan") { Task { await engine.submitPlan(editText) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                }
            } else {
                if let plan = displayPlan(state), !plan.isEmpty {
                    MarkdownView(plan, fontSize: 13.5, textColor: theme.textPrimary)
                }
                if !state.assignments.isEmpty {
                    VStack(alignment: .leading, spacing: theme.z(6)) {
                        ForEach(state.assignments) { a in
                            HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                                if let agent = engine.agent(a.agentID) {
                                    AgentDot(hex: agent.colorHex, size: 7)
                                    Text(agent.name)
                                        .font(theme.font(size: 12.5, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                        .frame(minWidth: theme.z(60), alignment: .leading)
                                }
                                Text(a.task)
                                    .font(theme.font(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(theme.z(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.codeBackground))
                }
                if redoing {
                    RoomTextEditor(placeholder: "What should change (optional)", text: $feedback, minHeight: 56, maxHeight: 120)
                }
                HStack(spacing: theme.z(8)) {
                    if redoing {
                        Button("Send back to the lead") { Task { await engine.redoPlan(feedback: feedback) } }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Cancel") { redoing = false }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Approve") { Task { await engine.approvePlan() } }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Edit") {
                            editText = editableText(state)
                            editing = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Redo") { redoing = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The plan without its ASSIGN lines (they show in the list below it).
    private func displayPlan(_ state: RoomState) -> String? {
        guard let plan = state.plan else { return nil }
        return plan.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("ASSIGN") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func editableText(_ state: RoomState) -> String {
        var lines = ["PLAN: " + (displayPlan(state) ?? ""), ""]
        for a in state.assignments {
            lines.append("ASSIGN @\(engine.agent(a.agentID)?.name ?? "Name"): \(a.task)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Team with the user as lead: the user writes the plan.
struct WritePlanCard: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        RoomCard(accent: theme.accent) {
            DecisionHeader(symbol: "square.and.pencil", title: "You lead this room. Write the plan.")
            RoomTextEditor(placeholder: template, text: $text, minHeight: 130, maxHeight: 320, monospaced: true)
            HStack(spacing: theme.z(8)) {
                Button("Start the work") { Task { await engine.submitPlan(text) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!text.uppercased().contains("ASSIGN"))
                Text("One ASSIGN @Name: line per agent.")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .onAppear { if text.isEmpty { text = template } }
    }

    private var template: String {
        (["PLAN: ", ""] + engine.agents.map { "ASSIGN @\($0.name): " }).joined(separator: "\n")
    }
}

/// A piece still has requested changes after the fix rounds.
struct ReviewStalemateCard: View {
    let engine: RoomEngine
    let authorID: UUID
    @Environment(\.theme) private var theme

    var body: some View {
        let assignment = engine.state.assignments.first { $0.agentID == authorID }
        let reviewer = assignment?.reviewerID.flatMap { engine.agent($0) }
        RoomCard(accent: theme.warning) {
            DecisionHeader(symbol: "exclamationmark.bubble",
                           title: "\(reviewer?.name ?? "The reviewer") still asks for changes to \(engine.agent(authorID)?.name ?? "this")'s piece after \(RoomEngine.maxFixRounds) fix rounds",
                           agent: engine.agent(authorID))
            if let review = assignment?.lastReview, !review.isEmpty {
                MarkdownView(review, fontSize: 13, textColor: theme.textSecondary)
                    .padding(theme.z(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.codeBackground))
            }
            HStack(spacing: theme.z(8)) {
                Button("Approve it") { Task { await engine.decideReview(for: authorID, .approve) } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Another round") { Task { await engine.decideReview(for: authorID, .anotherRound) } }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Drop the piece") { Task { await engine.decideReview(for: authorID, .drop) } }
                    .buttonStyle(SecondaryButtonStyle(foreground: theme.danger))
                Spacer(minLength: 0)
            }
        }
    }
}

/// Round table: a reviewer offers to take over building.
struct TakeoverCard: View {
    let engine: RoomEngine
    let agentID: UUID
    @Environment(\.theme) private var theme

    var body: some View {
        let rt = engine.state.roundTable
        let builder = rt?.builderID.flatMap { engine.agent($0) }
        RoomCard(accent: theme.accent) {
            DecisionHeader(symbol: "arrow.left.arrow.right",
                           title: "\(engine.agent(agentID)?.name ?? "A reviewer") offers to take over building from \(builder?.name ?? "the builder")",
                           agent: engine.agent(agentID))
            if case .takeover(let reason)? = rt?.reviews[agentID], !reason.isEmpty {
                MarkdownView(reason, fontSize: 13, textColor: theme.textSecondary)
            }
            HStack(spacing: theme.z(8)) {
                Button("Accept") { Task { await engine.acceptTakeover() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Keep \(builder?.name ?? "the builder")") { Task { await engine.rejectTakeover() } }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer(minLength: 0)
            }
        }
    }
}

/// Debate without a judge agent: the user writes the verdict.
struct JudgeCard: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        RoomCard(accent: theme.accent) {
            DecisionHeader(symbol: "scalemass", title: "The arguments are in. Write the verdict.")
            RoomTextEditor(placeholder: "The decision, the reasons, and the strongest dissent", text: $text, minHeight: 90, maxHeight: 240)
            HStack(spacing: theme.z(8)) {
                Button("Give the verdict") { Task { await engine.submitVerdict(text) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }
        }
    }
}

/// A merge stopped and no lead agent can resolve it.
struct MergeConflictCard: View {
    let engine: RoomEngine
    let agentID: UUID
    let files: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let state = engine.state
        let branch = state.assignments.first { $0.agentID == agentID }?.branch ?? "the branch"
        RoomCard(accent: theme.danger) {
            DecisionHeader(symbol: "arrow.triangle.merge",
                           title: "Merging \(branch) into \(state.git?.baseBranch ?? "the base branch") stopped",
                           agent: engine.agent(agentID))
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    ForEach(files, id: \.self) { file in
                        Text(file).font(theme.font(size: 12, design: .monospaced)).foregroundStyle(theme.textPrimary)
                    }
                }
                .padding(theme.z(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.codeBackground))
            }
            Text("Resolve it in \(Format.abbreviatedPath(state.spec.directory)), commit, then continue.")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: theme.z(8)) {
                Button("Continue merging") { Task { await engine.resolveMergeConflict() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Show in Finder") { revealInFinder(state.spec.directory) }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer(minLength: 0)
            }
        }
    }
}

/// The judge's decision, with Build it and Debate again while the verdict is fresh.
struct VerdictCard: View {
    let engine: RoomEngine
    let verdict: String
    var actionable: Bool
    @Environment(\.theme) private var theme
    @State private var buildMode: RoomMode?

    var body: some View {
        let debate = engine.state.debate
        let judge = debate?.judgeID.flatMap { engine.agent($0) }
        RoomCard(accent: theme.accent) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "scalemass")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text("Verdict")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                HStack(spacing: theme.z(5)) {
                    if let judge {
                        AgentDot(hex: judge.colorHex, size: 7)
                        Text("Judged by \(judge.name)")
                    } else {
                        Text("Judged by you")
                    }
                }
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
            }
            if let question = debate?.question {
                Text(question)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MarkdownView(verdict, fontSize: 14, textColor: theme.textPrimary)
            if actionable {
                HStack(spacing: theme.z(8)) {
                    Button("Build it") { Task { await engine.buildVerdict(as: buildMode ?? defaultMode) } }
                        .buttonStyle(PrimaryButtonStyle())
                    ChoiceChip(title: "As \((buildMode ?? defaultMode).label)", bordered: false,
                               options: buildModes.map { ($0, $0.label, $0.explanation, nil, true) },
                               selection: buildMode ?? defaultMode) { buildMode = $0 }
                    Spacer(minLength: 0)
                    Button("Debate again") { Task { await engine.debateAgain() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var defaultMode: RoomMode { engine.agents.count > 1 ? .team : .solo }

    private var buildModes: [RoomMode] {
        engine.agents.count > 1 ? [.team, .roundTable, .solo] : [.solo]
    }
}
