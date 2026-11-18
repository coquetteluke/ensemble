import SwiftUI
import AppKit
import EnsembleKit

/// What the new room sheet edits.
struct NewRoomDraft {
    struct Agent: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var modelID: String
        var role: String = ""
        var colorHex: String
        var cap: String = ""
    }

    /// Who leads: an agent, or the user.
    enum Lead: Hashable {
        case user
        case agent(UUID)
    }

    var title = ""
    var directory = ""
    var mode: RoomMode = .team
    var agents: [Agent] = []
    var lead: Lead = .user
    var permissionMode: PermissionMode = .auto
    var debateRounds = 3

    static let maxAgents = 6
    static let minAgents = 2

    /// Agents the mode uses (Solo uses the first one).
    var activeAgents: [Agent] { mode == .solo ? Array(agents.prefix(1)) : agents }

    var problems: [String] {
        var out: [String] = []
        if title.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the room a title.") }
        if directory.isEmpty { out.append("Choose a project folder.") }
        let list = activeAgents
        if mode != .solo && list.count < Self.minAgents { out.append("Add at least two agents.") }
        let names = list.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains(where: \.isEmpty) { out.append("Every agent needs a name.") }
        if Set(names).count != names.count { out.append("Agent names must be different.") }
        if list.contains(where: { ModelRef(string: $0.modelID) == nil }) { out.append("Pick a model for every agent.") }
        if list.contains(where: { !$0.cap.trimmingCharacters(in: .whitespaces).isEmpty && Self.parseCap($0.cap) == nil }) {
            out.append("Spending caps must be amounts in dollars.")
        }
        return out
    }

    static func parseCap(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    func spec() -> RoomSpec {
        let list = activeAgents
        let agents = list.map { a in
            AgentSpec(id: a.id, name: a.name.trimmingCharacters(in: .whitespaces),
                      model: ModelRef(string: a.modelID) ?? ModelRef(providerID: "", id: a.modelID),
                      role: a.role.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: a.colorHex,
                      spendingCapUSD: Self.parseCap(a.cap))
        }
        var leadID: UUID?
        if case .agent(let id) = lead, list.contains(where: { $0.id == id }) { leadID = id }
        if mode == .solo { leadID = agents.first?.id }
        return RoomSpec(title: title.trimmingCharacters(in: .whitespaces), directory: directory, agents: agents, mode: mode,
                        leadAgentID: leadID, permissionMode: permissionMode, debateRounds: debateRounds)
    }

    /// True when the user should lead (Team and Round table fall back to the first agent otherwise).
    var userLeads: Bool { lead == .user && mode != .solo }

    /// A short name from a model name: "Opus" for "Claude Opus 5.5", "GPT" for "GPT-5.5".
    static func defaultName(for model: ModelInfo?, taken: [String]) -> String {
        var base = "Agent"
        if let model {
            let words = model.name.split(separator: " ").map(String.init).filter { $0 != "Claude" }
            if let first = words.first {
                base = first.split(separator: "-").first.map(String.init) ?? first
            }
        }
        var name = base
        var n = 2
        while taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}

/// New room: title, folder, mode, agents (name, model, role, colour, cap), lead, permissions, debate rounds.
struct NewRoomSheet: View {
    let controller: RoomsController
    /// Folders to offer as quick picks.
    var recentFolders: [String] = []
    var onCreated: (UUID) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var draft: NewRoomDraft
    @State private var creating = false
    @State private var error: String?
    @State private var triedCreate = false
    private let prefilled: Bool

    init(controller: RoomsController, recentFolders: [String] = [], draft: NewRoomDraft? = nil, onCreated: @escaping (UUID) -> Void = { _ in }) {
        self.controller = controller
        self.recentFolders = recentFolders
        self.onCreated = onCreated
        self._draft = State(initialValue: draft ?? NewRoomDraft())
        self.prefilled = draft != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(0)) {
            Text("New room")
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.bottom, theme.z(18))

            VStack(alignment: .leading, spacing: theme.z(18)) {
                titleAndFolder
                modePicker
                agentList
                options
            }

            if let message = error ?? (triedCreate ? draft.problems.first : nil) {
                Text(message)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
                    .padding(.top, theme.z(14))
            }

            HStack(spacing: theme.z(8)) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating..." : "Create room", action: create)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)
            }
            .padding(.top, theme.z(20))
        }
        .padding(theme.z(22))
        .frame(width: theme.z(680))
        .background(theme.background)
        .onAppear(perform: fillDefaults)
        .task(id: draft.directory) {
            guard !isSnapshot else { return }
            await controller.loadModels(directory: draft.directory.isEmpty ? nil : draft.directory)
            fixModels()
        }
    }

    // MARK: Sections

    private var titleAndFolder: some View {
        HStack(alignment: .top, spacing: theme.z(14)) {
            VStack(alignment: .leading, spacing: theme.z(8)) {
                label("Title")
                InputField("Room title", text: $draft.title, height: 30)
            }
            .frame(width: theme.z(220))

            VStack(alignment: .leading, spacing: theme.z(8)) {
                label("Project folder")
                HStack(spacing: theme.z(8)) {
                    HStack(spacing: theme.z(8)) {
                        Image(systemName: "folder")
                            .foregroundStyle(theme.textSecondary)
                        Text(draft.directory.isEmpty ? "Choose a project folder" : Format.abbreviatedPath(draft.directory))
                            .foregroundStyle(draft.directory.isEmpty ? theme.textTertiary : theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .font(theme.font(size: 13))
                    .padding(.horizontal, theme.z(10))
                    .frame(height: theme.z(30))
                    .background(RoundedRectangle(cornerRadius: theme.z(7)).fill(theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(7)).strokeBorder(theme.border))
                    Button("Choose...", action: chooseFolder)
                        .buttonStyle(SecondaryButtonStyle())
                }
                let quick = folders.filter { $0 != draft.directory }.prefix(4)
                if !quick.isEmpty {
                    HStack(spacing: theme.z(6)) {
                        ForEach(Array(quick), id: \.self) { folder in
                            Button(Format.folderName(folder)) { draft.directory = folder }
                                .buttonStyle(.plain)
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, theme.z(8))
                                .frame(height: theme.z(22))
                                .background(RoundedRectangle(cornerRadius: theme.z(6)).fill(theme.hover))
                                .help(folder)
                        }
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            label("Mode")
            VStack(spacing: theme.z(8)) {
                ForEach([Array(RoomMode.sheetOrder.prefix(2)), Array(RoomMode.sheetOrder.suffix(2))], id: \.self) { row in
                    HStack(spacing: theme.z(8)) {
                        ForEach(row, id: \.self) { mode in
                            ModeCard(mode: mode, selected: draft.mode == mode) { select(mode) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack {
                label(draft.mode == .solo ? "Agent" : "Agents")
                if draft.mode != .solo {
                    Text("\(draft.agents.count) of \(NewRoomDraft.maxAgents)")
                        .font(theme.font(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                if draft.mode != .solo {
                    Button {
                        addAgent()
                    } label: {
                        Label("Add agent", systemImage: "plus")
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.agents.count >= NewRoomDraft.maxAgents)
                }
            }
            HStack(spacing: theme.z(8)) {
                columnLabel("").frame(width: theme.z(22))
                columnLabel("Name").frame(width: theme.z(104), alignment: .leading)
                columnLabel("Model").frame(width: theme.z(168), alignment: .leading)
                columnLabel("Role").frame(maxWidth: .infinity, alignment: .leading)
                columnLabel("Spending cap").frame(width: theme.z(92), alignment: .leading)
                Color.clear.frame(width: theme.z(20), height: theme.z(1))
            }
            VStack(spacing: theme.z(6)) {
                ForEach($draft.agents) { $agent in
                    if draft.mode != .solo || agent.id == draft.agents.first?.id {
                        AgentDraftRow(agent: $agent, models: models, usedColors: draft.agents.map(\.colorHex),
                                      canRemove: draft.agents.count > NewRoomDraft.minAgents && draft.mode != .solo) {
                            remove(agent.id)
                        }
                    }
                }
            }
        }
    }

    private var options: some View {
        HStack(alignment: .top, spacing: theme.z(22)) {
            if draft.mode != .solo {
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    label(draft.mode == .debate ? "Judge" : "Lead")
                    ChoiceChip(title: leadTitle, dotHex: leadDot, options: leadOptions, selection: draft.lead) { draft.lead = $0 }
                }
            }
            VStack(alignment: .leading, spacing: theme.z(8)) {
                label("Permissions")
                ChoiceChip(title: draft.permissionMode.label, symbol: draft.permissionMode.symbolName,
                           tint: draft.permissionMode.isDangerous ? theme.danger : nil,
                           options: PermissionMode.allCases.map { ($0, $0.label, $0.summary, nil, true) },
                           selection: draft.permissionMode) { draft.permissionMode = $0 }
                Text(draft.permissionMode.summary)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(draft.permissionMode.isDangerous ? theme.danger : theme.textTertiary)
            }
            if draft.mode == .debate {
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    label("Rounds")
                    RoundStepper(value: $draft.debateRounds, range: 1...6)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Lead

    private var leadOptions: [(value: NewRoomDraft.Lead, title: String, detail: String?, dotHex: String?, enabled: Bool)] {
        var out: [(NewRoomDraft.Lead, String, String?, String?, Bool)] = draft.agents.map { agent in
            (.agent(agent.id), agent.name.isEmpty ? "Unnamed agent" : agent.name, nil, agent.colorHex, true)
        }
        out.append((.user, draft.mode == .debate ? "You judge" : "You lead", nil, nil, true))
        return out
    }

    private var leadTitle: String {
        switch draft.lead {
        case .user: draft.mode == .debate ? "You judge" : "You lead"
        case .agent(let id): draft.agents.first { $0.id == id }?.name ?? "You lead"
        }
    }

    private var leadDot: String? {
        if case .agent(let id) = draft.lead { return draft.agents.first { $0.id == id }?.colorHex }
        return nil
    }

    // MARK: Helpers

    private var models: [ModelInfo] {
        controller.models(for: draft.directory.isEmpty ? nil : draft.directory)
    }

    private var folders: [String] {
        var seen = Set<String>()
        return (recentFolders + controller.rooms.map(\.spec.directory)).filter { seen.insert($0).inserted }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 11))
            .foregroundStyle(theme.textTertiary)
    }

    private func fillDefaults() {
        guard !prefilled, draft.agents.isEmpty else { return }
        draft.directory = controller.newRoomDirectory ?? folders.first ?? ""
        let available = models.filter(\.available)
        for i in 0..<2 {
            let model = available.isEmpty ? nil : available[min(i, available.count - 1)]
            draft.agents.append(newAgent(model: model))
        }
        if let first = draft.agents.first { draft.lead = .agent(first.id) }
    }

    private func newAgent(model: ModelInfo?) -> NewRoomDraft.Agent {
        NewRoomDraft.Agent(name: NewRoomDraft.defaultName(for: model, taken: draft.agents.map(\.name)),
                           modelID: model?.ref.description ?? "",
                           colorHex: RoomPalette.next(after: draft.agents.map(\.colorHex)))
    }

    /// Gives agents without a usable model the first available one (after the folder's models load).
    private func fixModels() {
        let available = models.filter(\.available)
        guard !available.isEmpty else { return }
        for i in draft.agents.indices where !available.contains(where: { $0.ref.description == draft.agents[i].modelID }) {
            let model = available[min(i, available.count - 1)]
            let taken = draft.agents.enumerated().filter { $0.offset != i }.map(\.element.name)
            let wasDefault = draft.agents[i].name.isEmpty || draft.agents[i].name.hasPrefix("Agent")
            draft.agents[i].modelID = model.ref.description
            if wasDefault { draft.agents[i].name = NewRoomDraft.defaultName(for: model, taken: taken) }
        }
    }

    private func addAgent() {
        guard draft.agents.count < NewRoomDraft.maxAgents else { return }
        let available = models.filter(\.available)
        let model = available.isEmpty ? nil : available[draft.agents.count % available.count]
        draft.agents.append(newAgent(model: model))
    }

    private func remove(_ id: UUID) {
        draft.agents.removeAll { $0.id == id }
        if draft.lead == .agent(id) { draft.lead = draft.agents.first.map { .agent($0.id) } ?? .user }
    }

    private func select(_ mode: RoomMode) {
        let old = draft.mode
        draft.mode = mode
        if mode == .debate && old != .debate { draft.lead = .user }
        if old == .debate && mode != .debate, draft.lead == .user, let first = draft.agents.first { draft.lead = .agent(first.id) }
        if mode != .solo && draft.agents.count < NewRoomDraft.minAgents { addAgent() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !draft.directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: draft.directory) }
        if panel.runModal() == .OK, let url = panel.url {
            draft.directory = url.path
            if draft.title.isEmpty { draft.title = url.lastPathComponent }
        }
    }

    private func create() {
        triedCreate = true
        error = nil
        guard draft.problems.isEmpty else { return }
        creating = true
        let spec = draft.spec()
        let userLeads = draft.userLeads
        Task {
            do {
                try await controller.create(spec: spec, userLeads: userLeads)
                onCreated(spec.id)
                dismiss()
            } catch {
                self.error = "Could not create the room: \(error.localizedDescription)"
            }
            creating = false
        }
    }
}

/// One of the four mode choices.
private struct ModeCard: View {
    let mode: RoomMode
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: theme.z(10)) {
                Image(systemName: mode.symbolName)
                    .font(theme.font(size: 14))
                    .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                    .frame(width: theme.z(20), height: theme.z(18))
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    Text(mode.label)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(mode.explanation)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(theme.z(10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.1) : (hovering ? theme.elevatedHover : theme.elevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                    .strokeBorder(selected ? theme.accent.opacity(0.8) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One agent in the new room sheet.
private struct AgentDraftRow: View {
    @Binding var agent: NewRoomDraft.Agent
    let models: [ModelInfo]
    let usedColors: [String]
    let canRemove: Bool
    let onRemove: () -> Void
    @Environment(\.theme) private var theme
    @State private var choosingColor = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Button { choosingColor.toggle() } label: {
                AgentDot(hex: agent.colorHex, size: 14)
                    .frame(width: theme.z(22), height: theme.z(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Colour")
            .popover(isPresented: $choosingColor, arrowEdge: .bottom) {
                HStack(spacing: theme.z(8)) {
                    ForEach(RoomPalette.colors, id: \.self) { hex in
                        Button {
                            agent.colorHex = hex
                            choosingColor = false
                        } label: {
                            Circle()
                                .fill(Color(hexString: hex))
                                .frame(width: theme.z(18), height: theme.z(18))
                                .overlay(Circle().strokeBorder(Color.white.opacity(hex == agent.colorHex ? 0.9 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(usedColors.contains(hex) && hex != agent.colorHex ? "Used by another agent" : "")
                    }
                }
                .padding(theme.z(10))
                .ensembleTheme()
            }

            InputField("Name", text: $agent.name, height: 28)
                .frame(width: theme.z(104))

            ChoiceChip(title: modelTitle, maxWidth: 124, options: modelOptions, selection: agent.modelID) { id in
                agent.modelID = id
            }
            .frame(width: theme.z(168), alignment: .leading)

            InputField("What this agent does", text: $agent.role, height: 28)
                .frame(maxWidth: .infinity)

            InputField("No cap", text: $agent.cap, icon: "dollarsign", height: 28)
                .frame(width: theme.z(92))
                .help("Stop this agent when it has spent this many dollars")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: theme.z(20), height: theme.z(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canRemove ? 1 : 0)
            .disabled(!canRemove)
            .help("Remove \(agent.name)")
        }
    }

    private var modelTitle: String {
        guard let ref = ModelRef(string: agent.modelID) else { return "Choose a model" }
        return shortModelName(ref, models: models)
    }

    private var modelOptions: [(value: String, title: String, detail: String?, dotHex: String?, enabled: Bool)] {
        models.map { ($0.ref.description, $0.name, $0.available ? $0.providerName : "\($0.providerName), no key", nil, $0.available) }
    }
}

/// "- 3 +" stepper drawn in SwiftUI.
private struct RoundStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(0)) {
            stepButton("minus") { value = max(range.lowerBound, value - 1) }
                .disabled(value <= range.lowerBound)
            Text("\(value)")
                .font(theme.font(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .frame(width: theme.z(30))
            stepButton("plus") { value = min(range.upperBound, value + 1) }
                .disabled(value >= range.upperBound)
        }
        .frame(height: theme.z(28))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(28), height: theme.z(28))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
