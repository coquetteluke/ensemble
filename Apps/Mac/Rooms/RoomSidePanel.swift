import SwiftUI
import EnsembleKit

/// Right-hand panel of a room: Members (role, state, current step, spend and caps), the message graph with replay,
/// the mode's state (Team pieces, debate rounds, round table turns), and the room's folder and usage. Clicking an agent
/// opens its own session transcript.
struct RoomSidePanel: View {
    let controller: RoomsController
    let engine: RoomEngine
    @Binding var selectedAgentID: UUID?
    var openSession: (@MainActor @Sendable (String) -> Void)?
    /// Replay of the board (`nil` is live), shared with the board column.
    var replayStep: Binding<Int?> = .constant(nil)
    /// Follow mode picks the agent shown.
    var following = false
    var topInset: CGFloat = 52

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.z(0)) {
            Color.clear.frame(height: topInset)
            if let id = selectedAgentID, let agent = engine.agent(id), let sid = engine.sessionID(for: id) {
                AgentSessionPanel(controller: controller, engine: engine, agent: agent, sessionID: sid,
                                  openSession: openSession, following: following) { selectedAgentID = nil }
            } else {
                AdaptiveScroll(.vertical) {
                    VStack(alignment: .leading, spacing: theme.z(0)) {
                        agentsSection
                        PanelDivider()
                        if engine.agents.count > 1 {
                            RoomGraphSection(engine: engine, replayStep: replayStep)
                            PanelDivider()
                        }
                        switch engine.state.runMode {
                        case .team:
                            TeamPanelSection(engine: engine)
                            PanelDivider()
                        case .debate:
                            DebatePanelSection(engine: engine)
                            PanelDivider()
                        case .roundTable:
                            RoundTablePanelSection(engine: engine)
                            PanelDivider()
                        case .solo:
                            EmptyView()
                        }
                        roomSection
                    }
                    .padding(.leading, theme.z(14))
                    .padding(.trailing, theme.z(14))
                    .padding(.bottom, theme.z(24))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
    }

    // MARK: Agents

    private var agentsSection: some View {
        let activity = Dictionary(engine.agents.map { ($0.id, controller.activity(of: $0.id, in: engine)) },
                                  uniquingKeysWith: { a, _ in a })
        let members = RoomSwarm.members(engine.state, activity: activity)
        return VStack(alignment: .leading, spacing: theme.z(4)) {
            RoomSectionTitle(text: "Members", trailing: membersSummary(members))
                .padding(.bottom, theme.z(6))
            ForEach(members) { member in
                let agent = member.agent
                AgentPanelRow(agent: agent, member: member, engine: engine,
                              activity: activity[agent.id] ?? .idle,
                              models: controller.models(for: engine.state.spec.directory)) {
                    selectedAgentID = agent.id
                }
                .contextMenu {
                    Button("Show transcript") { selectedAgentID = agent.id }
                    if let openSession, let sid = engine.sessionID(for: agent.id) {
                        Button("Open as session") { openSession(sid) }
                    }
                    if engine.state.spec.mode != .solo && engine.leadID != agent.id {
                        Button(engine.state.runMode == .debate ? "Make judge" : "Make lead") { engine.setLead(agent.id) }
                    }
                }
            }
        }
        .padding(.top, theme.z(4))
    }

    /// "2 active of 3", or the count when nobody works.
    private func membersSummary(_ members: [RoomMember]) -> String {
        let active = members.filter { $0.state == .active }.count
        return active == 0 ? "\(members.count)" : "\(active) active of \(members.count)"
    }

    // MARK: Room

    private var roomSection: some View {
        let state = engine.state
        let usage = state.totalUsage
        return VStack(alignment: .leading, spacing: theme.z(8)) {
            RoomSectionTitle(text: "Room")
                .padding(.bottom, theme.z(2))
            infoRow("folder", Format.abbreviatedPath(state.spec.directory))
                .help(state.spec.directory)
            if let base = state.git?.baseBranch {
                infoRow("arrow.triangle.branch", "Base branch \(base)")
            }
            infoRow(state.spec.permissionMode.symbolName, state.spec.permissionMode.label,
                    tint: state.spec.permissionMode.isDangerous ? theme.danger : nil)
            if state.runMode == .debate {
                infoRow("number", "\(state.spec.debateRounds) rounds")
            }
            infoRow("chart.bar", "\(Format.usd(usage.costUSD))  \(Format.tokens(usage.inputTokens + usage.outputTokens)) tokens")
        }
    }

    private func infoRow(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: theme.z(9)) {
            Image(systemName: symbol)
                .font(theme.font(size: 11.5))
                .foregroundStyle(tint ?? theme.textTertiary)
                .frame(width: theme.z(16))
            Text(text)
                .font(theme.font(size: 12.5).monospacedDigit())
                .foregroundStyle(tint ?? theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

private struct PanelDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HLine().padding(.vertical, theme.z(16))
    }
}

/// One member in the panel: colour and name, its part in the run (lead, builder, reviewer), its state, model and role,
/// what it is doing now, and spend against its cap.
private struct AgentPanelRow: View {
    let agent: AgentSpec
    let member: RoomMember
    let engine: RoomEngine
    let activity: AgentActivity
    let models: [ModelInfo]
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var editingCap = false
    @State private var capText = ""
    @State private var hovering = false

    var body: some View {
        let spent = engine.state.usage[agent.id]?.costUSD ?? 0
        VStack(alignment: .leading, spacing: theme.z(4)) {
                HStack(spacing: theme.z(7)) {
                    AgentDot(hex: agent.colorHex, size: 9)
                    Text(agent.name)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if engine.state.spec.mode != .solo {
                        RoomTag(text: member.role.label, color: [.lead, .judge].contains(member.role) ? theme.accent : nil)
                    }
                    Spacer(minLength: 4)
                    MemberStateBadge(state: member.state, agentColor: Color(hexString: agent.colorHex))
                        .help(member.state == .stopped && activity == .capped ? "Reached its spending cap" : member.state.label)
                }
                Text([shortModelName(agent.model, models: models), agent.role].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .padding(.leading, theme.z(16))
                if let step = member.step {
                    HStack(alignment: .firstTextBaseline, spacing: theme.z(5)) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(theme.font(size: 9.5))
                            .foregroundStyle(theme.textTertiary)
                        Text(step)
                            .font(theme.font(size: 12))
                            .foregroundStyle(member.state == .waitingOnYou ? theme.warning : theme.textPrimary.opacity(0.85))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, theme.z(16))
                    .help(step)
                }
                HStack(spacing: theme.z(6)) {
                    Text(Format.usd(spent))
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                    if let cap = agent.spendingCapUSD {
                        CapBar(fraction: cap > 0 ? spent / cap : 1, capped: activity == .capped)
                            .frame(width: theme.z(60))
                        Text("of \(Format.usd(cap))")
                            .font(theme.font(size: 11.5).monospacedDigit())
                            .foregroundStyle(theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button(agent.spendingCapUSD == nil ? "Set cap" : "Change cap") {
                        capText = agent.spendingCapUSD.map { String(format: "%.2f", $0) } ?? ""
                        editingCap = true
                    }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .popover(isPresented: $editingCap, arrowEdge: .bottom) {
                        capEditor.ensembleTheme()
                    }
                }
                .padding(.leading, theme.z(16))
            }
        .padding(.horizontal, theme.z(8))
        .padding(.vertical, theme.z(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering ? theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .padding(.horizontal, theme.z(-8))
        .help("Show \(agent.name)'s session")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(member.role.label), \(member.state.label)\(member.step.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }

    private var capEditor: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            Text("Spending cap for \(agent.name)")
                .font(theme.font(size: 12.5, weight: .semibold))
            InputField("No cap", text: $capText, icon: "dollarsign", height: 28)
                .frame(width: theme.z(180))
            HStack(spacing: theme.z(8)) {
                Button("Save") {
                    let cleaned = capText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
                    engine.setSpendingCap(cleaned.isEmpty ? nil : Double(cleaned), for: agent.id)
                    editingCap = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!capText.trimmingCharacters(in: .whitespaces).isEmpty && Double(capText.replacingOccurrences(of: "$", with: "")) == nil)
                Button("Remove cap") {
                    engine.setSpendingCap(nil, for: agent.id)
                    editingCap = false
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(theme.z(14))
    }
}

/// Thin spend bar; red once the cap is reached.
private struct CapBar: View {
    let fraction: Double
    let capped: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule()
                    .fill(capped || fraction >= 1 ? theme.danger : (fraction > 0.8 ? theme.warning : theme.accent))
                    .frame(width: max(2, min(1, fraction) * proxy.size.width))
            }
        }
        .frame(height: theme.z(4))
    }
}

/// Working spinner, permission hand, or a Capped tag.
struct ActivityBadge: View {
    let activity: AgentActivity
    let color: Color
    @Environment(\.theme) private var theme

    var body: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .working:
            Spinner(size: 10, color: color)
                .help("Working")
        case .waitingForPermission:
            Image(systemName: "hand.raised.fill")
                .font(theme.font(size: 10.5))
                .foregroundStyle(theme.warning)
                .help("Waiting for permission")
        case .capped:
            RoomTag(text: "Capped", color: theme.danger)
                .help("Reached its spending cap")
        }
    }
}

// MARK: - Mode sections

private struct TeamPanelSection: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme
    @State private var showWholePlan = false

    var body: some View {
        let state = engine.state
        VStack(alignment: .leading, spacing: theme.z(10)) {
            RoomSectionTitle(text: "Pieces", trailing: state.assignments.isEmpty ? nil : progress(state))
            if state.assignments.isEmpty {
                Text(state.phase == .planning ? "The lead is writing the plan." : "No plan yet.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(state.assignments) { a in
                AssignmentPanelRow(assignment: a, engine: engine)
            }
            if let plan = state.plan.map(Self.withoutAssignLines), !plan.isEmpty {
                VStack(alignment: .leading, spacing: theme.z(6)) {
                    Text("Plan")
                        .font(theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text(plan)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(showWholePlan ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableText()
                    Button(showWholePlan ? "Show less" : "Show all") { showWholePlan.toggle() }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.top, theme.z(4))
            }
        }
    }

    static func withoutAssignLines(_ plan: String) -> String {
        plan.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("ASSIGN") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func progress(_ state: RoomState) -> String {
        let done = state.assignments.filter { [.approved, .merged].contains($0.status) }.count
        return "\(done) of \(state.assignments.count) done"
    }
}

/// Owner, status, reviewer, branch and fix rounds of one Team piece.
private struct AssignmentPanelRow: View {
    let assignment: Assignment
    let engine: RoomEngine
    @Environment(\.theme) private var theme

    var body: some View {
        let owner = engine.agent(assignment.agentID)
        VStack(alignment: .leading, spacing: theme.z(5)) {
            HStack(spacing: theme.z(7)) {
                if let owner { AgentDot(hex: owner.colorHex, size: 8) }
                Text(owner?.name ?? "Removed agent")
                    .font(theme.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 4)
                RoomTag(text: assignment.status.label, color: assignment.status.color(theme))
            }
            Text(assignment.task)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: theme.z(3)) {
                if let reviewer = assignment.reviewerID.flatMap({ engine.agent($0) }) {
                    detail("eye", "Reviewer") {
                        HStack(spacing: theme.z(4)) {
                            AgentDot(hex: reviewer.colorHex, size: 6)
                            Text(reviewer.name).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                if let branch = assignment.branch {
                    detail("arrow.triangle.branch", nil) {
                        Text(branch).font(theme.font(size: 11.5, design: .monospaced)).foregroundStyle(theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if assignment.fixRounds > 0 {
                    detail("arrow.uturn.backward", nil) {
                        Text("Fix round \(assignment.fixRounds) of \(RoomEngine.maxFixRounds)").foregroundStyle(theme.textSecondary)
                    }
                }
                if !assignment.changedFiles.isEmpty {
                    detail("doc", nil) {
                        Text("\(assignment.changedFiles.count) changed \(assignment.changedFiles.count == 1 ? "file" : "files")")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .help(assignment.changedFiles.joined(separator: "\n"))
                }
            }
            .padding(.leading, theme.z(15))
        }
        .padding(theme.z(10))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.separator))
    }

    private func detail<V: View>(_ symbol: String, _ label: String?, @ViewBuilder _ value: () -> V) -> some View {
        HStack(spacing: theme.z(5)) {
            Image(systemName: symbol).font(theme.font(size: 10)).foregroundStyle(theme.textTertiary).frame(width: theme.z(12))
            if let label { Text(label).foregroundStyle(theme.textTertiary) }
            value()
        }
        .font(theme.font(size: 11.5))
    }
}

private struct DebatePanelSection: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme

    var body: some View {
        let state = engine.state
        VStack(alignment: .leading, spacing: theme.z(10)) {
            RoomSectionTitle(text: "Debate", trailing: state.debate.map { "Round \(min($0.round, $0.totalRounds)) of \($0.totalRounds)" })
            if let debate = state.debate {
                Text(debate.question)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.z(4)) {
                    ForEach(1...max(1, debate.totalRounds), id: \.self) { round in
                        Capsule()
                            .fill(roundColor(round, debate: debate, phase: state.phase))
                            .frame(height: theme.z(4))
                    }
                }
                ForEach(engine.agents) { agent in
                    let count = debate.arguments.filter { $0.agentID == agent.id }.count
                    HStack(spacing: theme.z(7)) {
                        AgentDot(hex: agent.colorHex, size: 7)
                        Text(agent.name).foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 4)
                        Text("\(count) \(count == 1 ? "argument" : "arguments")").foregroundStyle(theme.textTertiary)
                    }
                    .font(theme.font(size: 12))
                }
                HStack(spacing: theme.z(7)) {
                    Image(systemName: "scalemass").font(theme.font(size: 11)).foregroundStyle(theme.textTertiary)
                    Text(debate.judgeID.flatMap { engine.agent($0)?.name }.map { "\($0) judges" } ?? "You judge")
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                    if debate.verdict != nil { RoomTag(text: "Verdict given", color: theme.accent) }
                }
                .font(theme.font(size: 12))
            } else {
                Text("Ask the room a question to start.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func roundColor(_ round: Int, debate: DebateState, phase: RoomPhase) -> Color {
        if round < debate.round || [.judging, .verdict, .finished].contains(phase) || debate.verdict != nil { return theme.accent }
        if round == debate.round { return theme.accent.opacity(0.45) }
        return theme.track
    }
}

private struct RoundTablePanelSection: View {
    let engine: RoomEngine
    @Environment(\.theme) private var theme

    var body: some View {
        let state = engine.state
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if let rt = state.roundTable {
                if state.phase == .discussing {
                    RoomSectionTitle(text: "Discussion", trailing: "Round \(min(rt.round, rt.maxRounds)) of \(rt.maxRounds)")
                    ForEach(Array(rt.order.enumerated()), id: \.element) { index, id in
                        if let agent = engine.agent(id) {
                            HStack(spacing: theme.z(7)) {
                                Text("\(index + 1)").foregroundStyle(theme.textTertiary).frame(width: theme.z(12))
                                AgentDot(hex: agent.colorHex, size: 7)
                                Text(agent.name).foregroundStyle(theme.textPrimary)
                                if rt.currentSpeaker == id { RoomTag(text: "Speaking", color: theme.accent) }
                                Spacer(minLength: 4)
                                if rt.agreed.contains(id) {
                                    Label("Agrees", systemImage: "checkmark").foregroundStyle(theme.success)
                                }
                            }
                            .font(theme.font(size: 12))
                        }
                    }
                } else {
                    RoomSectionTitle(text: "Build", trailing: rt.buildTurns > 0 ? "\(rt.buildTurns) \(rt.buildTurns == 1 ? "step" : "steps")" : nil)
                    if let builder = rt.builderID.flatMap({ engine.agent($0) }) {
                        HStack(spacing: theme.z(7)) {
                            Image(systemName: "hammer").font(theme.font(size: 11)).foregroundStyle(theme.textTertiary).frame(width: theme.z(12))
                            AgentDot(hex: builder.colorHex, size: 7)
                            Text("\(builder.name) builds").foregroundStyle(theme.textPrimary)
                            Spacer(minLength: 0)
                            if rt.builderDone { RoomTag(text: "Done", color: theme.success) }
                        }
                        .font(theme.font(size: 12))
                    }
                    ForEach(engine.agents.filter { $0.id != rt.builderID }) { agent in
                        HStack(spacing: theme.z(7)) {
                            Image(systemName: "eye").font(theme.font(size: 10)).foregroundStyle(theme.textTertiary).frame(width: theme.z(12))
                            AgentDot(hex: agent.colorHex, size: 7)
                            Text(agent.name).foregroundStyle(theme.textPrimary)
                            Spacer(minLength: 4)
                            reviewTag(rt.reviews[agent.id])
                        }
                        .font(theme.font(size: 12))
                    }
                }
                if let plan = rt.plan ?? state.plan {
                    Text(plan)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, theme.z(2))
                }
            } else {
                RoomSectionTitle(text: "Round table")
                Text("Give the room a task to start.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    @ViewBuilder private func reviewTag(_ review: RoundTableReview?) -> some View {
        switch review {
        case .approve?: RoomTag(text: "Approved", color: theme.success)
        case .changes?: RoomTag(text: "Changes", color: theme.warning)
        case .takeover?: RoomTag(text: "Takeover", color: theme.accent)
        case nil: Text("Waiting").foregroundStyle(theme.textTertiary)
        }
    }
}

// MARK: - Agent session

/// One agent's own session transcript (tools, edits, reasoning), shown with the shared transcript views.
struct AgentSessionPanel: View {
    let controller: RoomsController
    let engine: RoomEngine
    let agent: AgentSpec
    let sessionID: String
    var openSession: (@MainActor @Sendable (String) -> Void)?
    /// Follow mode chose this agent.
    var following = false
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let transcript = controller.transcripts[sessionID]
        VStack(alignment: .leading, spacing: theme.z(0)) {
            HStack(spacing: theme.z(8)) {
                Button(action: onClose) {
                    HStack(spacing: theme.z(4)) {
                        Image(systemName: "chevron.left").font(theme.font(size: 10, weight: .semibold))
                        Text("Room")
                    }
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if let openSession {
                    Button("Open as session") { openSession(sessionID) }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, theme.z(14))
            .padding(.bottom, theme.z(10))
            HStack(spacing: theme.z(8)) {
                AgentHeader(agent: agent, models: controller.models(for: engine.state.spec.directory))
                if following {
                    RoomTag(text: "Following", color: theme.accent)
                        .help("Follow is on: this panel moves to whichever agent is working")
                }
                Spacer(minLength: 4)
                ActivityBadge(activity: controller.activity(of: agent.id, in: engine), color: Color(hexString: agent.colorHex))
            }
            .padding(.horizontal, theme.z(14))
            .padding(.bottom, theme.z(10))
            HLine()
            AdaptiveScroll(.vertical, snapshotAlignment: .bottom) {
                VStack(alignment: .leading, spacing: theme.z(0)) {
                    if let transcript, transcript.loaded, !transcript.items.isEmpty {
                        TranscriptList(items: transcript.items, resolutions: transcript.resolutions,
                                       agents: Dictionary(engine.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
                    } else if transcript?.loaded != true {
                        HStack(spacing: theme.z(8)) {
                            Spinner(size: 11)
                            Text("Loading").font(theme.font(size: 12.5)).foregroundStyle(theme.textTertiary)
                        }
                    } else {
                        Text("Nothing in this session yet.")
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(theme.z(14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.sessionDirectory, engine.state.spec.directory)
        }
        .task(id: sessionID) { _ = controller.transcript(for: sessionID, agentID: agent.id) }
    }
}
