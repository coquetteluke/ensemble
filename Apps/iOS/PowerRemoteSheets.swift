import EnsembleKit
import SwiftUI

// MARK: - Model Picker Sheet

struct RemoteModelPickerSheet: View {
    let models: [RemoteModelOption]
    let currentProviderID: String?
    let currentModelID: String?
    let pendingModelName: String?
    let hasHistory: Bool
    let onSelect: (RemoteModelOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [RemoteModelOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.makerName.localizedCaseInsensitiveContains(trimmed)
                || $0.engineLabel.localizedCaseInsensitiveContains(trimmed)
                || $0.modelID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var sections: [(maker: String, items: [RemoteModelOption])] {
        var order: [String] = []
        var grouped: [String: [RemoteModelOption]] = [:]
        for item in filtered {
            let key = item.makerName.isEmpty ? "Other" : item.makerName
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(hasHistory
                         ? "Changes take effect on your next sent message."
                         : "Switches immediately for this empty session.")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)

                    if let pendingModelName {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.accent)
                            Text("Staged for next message: \(pendingModelName)")
                                .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                                .foregroundStyle(RemoteTheme.primaryText)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RemoteTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(RemoteTheme.accent.opacity(0.35), lineWidth: 1)
                        )
                    }

                    if models.count > 6 {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                                .foregroundStyle(RemoteTheme.tertiaryText)
                            TextField("Filter models...", text: $query)
                                .font(RemoteTheme.font(size: 14.5, relativeTo: .body))
                                .foregroundStyle(RemoteTheme.primaryText)
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(RemoteTheme.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 42)
                        .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                        )
                    }

                    if sections.isEmpty {
                        Text("No matching models available on your Mac.")
                            .font(RemoteTheme.font(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 28)
                    } else {
                        ForEach(sections, id: \.maker) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.maker)
                                    .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                                    .padding(.leading, 4)

                                VStack(spacing: 0) {
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, option in
                                        let isCurrent = option.providerID == currentProviderID && option.modelID == currentModelID
                                        Button {
                                            onSelect(option)
                                            dismiss()
                                        } label: {
                                            HStack(spacing: 10) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(option.name)
                                                        .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .body))
                                                        .foregroundStyle(RemoteTheme.primaryText)
                                                    if !option.engineLabel.isEmpty {
                                                        Text(option.engineLabel)
                                                            .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                                                            .foregroundStyle(RemoteTheme.tertiaryText)
                                                    }
                                                }
                                                Spacer(minLength: 8)
                                                if isCurrent {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(RemoteTheme.font(size: 16, relativeTo: .body))
                                                        .foregroundStyle(RemoteTheme.accent)
                                                }
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 11)
                                            .frame(minHeight: RemoteTheme.minTapTarget, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        if idx < section.items.count - 1 {
                                            Rectangle()
                                                .fill(RemoteTheme.separator)
                                                .frame(height: 1)
                                                .padding(.leading, 14)
                                        }
                                    }
                                }
                                .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
            .remoteScreen()
            .navigationTitle("Switch model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - New Session Sheet

struct RemoteNewSessionSheet: View {
    let client: RemoteClient
    let onCreated: (SessionSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var selectedModelID = ""
    @State private var title = ""
    @State private var creating = false
    @State private var errorText: String?

    private var selectedModel: RemoteModelOption? {
        client.availableModels.first { $0.id == selectedModelID } ?? client.availableModels.first
    }

    private var canCreate: Bool {
        !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedModel != nil
            && !creating
            && client.state.isConnected
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    folderSection
                    modelSection
                    titleSection

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.danger)
                    }

                    Button {
                        create()
                    } label: {
                        HStack(spacing: 8) {
                            if creating { Spinner(size: 13, color: RemoteTheme.onAccent) }
                            Text(creating ? "Starting..." : "Start session")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemotePrimaryButtonStyle())
                    .disabled(!canCreate)
                }
                .padding(16)
            }
            .remoteScreen()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if folder.isEmpty, let first = client.recentFolders.first {
                    folder = first
                }
                if selectedModelID.isEmpty, let first = client.availableModels.first {
                    selectedModelID = first.id
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project folder")
                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.secondaryText)

            if !client.recentFolders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(client.recentFolders, id: \.self) { path in
                            let active = folder == path
                            Button {
                                folder = path
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "folder")
                                        .font(RemoteTheme.font(size: 11, relativeTo: .caption))
                                    Text(RemoteFormat.folderName(path))
                                        .font(RemoteTheme.font(size: 13, weight: active ? .semibold : .medium, relativeTo: .footnote))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(active ? RemoteTheme.onAccent : RemoteTheme.primaryText)
                                .padding(.horizontal, 11)
                                .frame(minHeight: 36)
                                .background(active ? RemoteTheme.accent : RemoteTheme.card, in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(active ? RemoteTheme.accent : RemoteTheme.border, lineWidth: 0.75)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            TextField("/Users/you/project", text: $folder)
                .font(RemoteTheme.font(size: 13.5, design: .monospaced, relativeTo: .footnote))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                )
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.secondaryText)

            if client.availableModels.isEmpty {
                Text("No models reported by Mac yet.")
                    .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.tertiaryText)
            } else {
                Menu {
                    ForEach(client.availableModels) { option in
                        Button {
                            selectedModelID = option.id
                        } label: {
                            let label = option.makerName.isEmpty ? option.name : "\(option.name) (\(option.makerName))"
                            if option.id == selectedModel?.id {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedModel?.name ?? "Choose a model")
                                .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .body))
                                .foregroundStyle(RemoteTheme.primaryText)
                            if let engine = selectedModel?.engineLabel, !engine.isEmpty {
                                Text(engine)
                                    .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                                    .foregroundStyle(RemoteTheme.tertiaryText)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(RemoteTheme.font(size: 12, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                    )
                }
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title (optional)")
                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.secondaryText)
            TextField("What are you working on?", text: $title)
                .font(RemoteTheme.font(size: 14.5, relativeTo: .body))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                )
        }
    }

    private func create() {
        guard let model = selectedModel else { return }
        creating = true
        errorText = nil
        let targetDir = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let created = try await client.createSession(
                    directory: targetDir,
                    providerID: model.providerID,
                    modelID: model.modelID,
                    title: cleanTitle.isEmpty ? nil : cleanTitle
                )
                dismiss()
                onCreated(created)
            } catch {
                errorText = error.localizedDescription
            }
            creating = false
        }
    }
}

// MARK: - New Room Sheet

struct RemoteNewRoomSheet: View {
    let client: RemoteClient
    let onCreated: (RemoteRoom) -> Void

    private struct DraftAgent: Identifiable {
        let id = UUID()
        var name: String
        var role: String
        var modelOptionID: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var title = ""
    @State private var mode: RoomMode = .team
    @State private var draftAgents: [DraftAgent] = []
    @State private var creating = false
    @State private var errorText: String?

    private let supportedModes: [RoomMode] = [.team, .debate, .roundTable]
    private let defaultNames = ["Ada", "Grace", "Linus", "Alan"]

    private var canCreate: Bool {
        !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftAgents.count >= 2
            && !client.availableModels.isEmpty
            && !creating
            && client.state.isConnected
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title")
                            .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.secondaryText)
                        TextField("Design the sync API", text: $title)
                            .font(RemoteTheme.font(size: 15, relativeTo: .body))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Project folder")
                            .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.secondaryText)
                        if !client.recentFolders.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(client.recentFolders, id: \.self) { path in
                                        let active = folder == path
                                        Button {
                                            folder = path
                                        } label: {
                                            Text(RemoteFormat.folderName(path))
                                                .font(RemoteTheme.font(size: 13, weight: active ? .semibold : .medium, relativeTo: .footnote))
                                                .foregroundStyle(active ? RemoteTheme.onAccent : RemoteTheme.primaryText)
                                                .padding(.horizontal, 11)
                                                .frame(minHeight: 36)
                                                .background(active ? RemoteTheme.accent : RemoteTheme.card, in: Capsule())
                                                .overlay(
                                                    Capsule().strokeBorder(active ? RemoteTheme.accent : RemoteTheme.border, lineWidth: 0.75)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        TextField("/Users/you/project", text: $folder)
                            .font(RemoteTheme.font(size: 13.5, design: .monospaced, relativeTo: .footnote))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mode")
                            .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.secondaryText)
                        HStack(spacing: 8) {
                            ForEach(supportedModes, id: \.self) { candidate in
                                let active = mode == candidate
                                Button {
                                    mode = candidate
                                } label: {
                                    Text(candidate.label)
                                        .font(RemoteTheme.font(size: 13, weight: active ? .semibold : .medium, relativeTo: .footnote))
                                        .foregroundStyle(active ? RemoteTheme.onAccent : RemoteTheme.primaryText)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(active ? RemoteTheme.accent : RemoteTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(active ? RemoteTheme.accent : RemoteTheme.border, lineWidth: 0.75)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Agents (\(draftAgents.count))")
                                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.secondaryText)
                            Spacer()
                            if draftAgents.count < 4, !client.availableModels.isEmpty {
                                Button {
                                    addAgent()
                                } label: {
                                    Label("Add", systemImage: "plus")
                                        .font(RemoteTheme.font(size: 13, weight: .semibold, relativeTo: .footnote))
                                        .foregroundStyle(RemoteTheme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ForEach($draftAgents) { $agent in
                            let currentOption = client.availableModels.first { $0.id == agent.modelOptionID } ?? client.availableModels.first
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    TextField("Name", text: $agent.name)
                                        .font(RemoteTheme.font(size: 14.5, weight: .semibold, relativeTo: .body))
                                        .foregroundStyle(RemoteTheme.primaryText)
                                    Spacer()
                                    if draftAgents.count > 2 {
                                        Button {
                                            draftAgents.removeAll { $0.id == agent.id }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundStyle(RemoteTheme.danger)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                TextField("Role (optional)", text: $agent.role)
                                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                                    .foregroundStyle(RemoteTheme.secondaryText)

                                if !client.availableModels.isEmpty {
                                    Menu {
                                        ForEach(client.availableModels) { option in
                                            Button {
                                                agent.modelOptionID = option.id
                                            } label: {
                                                if option.id == currentOption?.id {
                                                    Label(option.name, systemImage: "checkmark")
                                                } else {
                                                    Text(option.name)
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "cpu")
                                                .font(RemoteTheme.font(size: 11.5, relativeTo: .caption))
                                            Text(currentOption?.name ?? "Model")
                                                .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                                            Spacer()
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(RemoteTheme.font(size: 10, relativeTo: .caption2))
                                        }
                                        .foregroundStyle(RemoteTheme.primaryText)
                                        .padding(.horizontal, 10)
                                        .frame(minHeight: 36)
                                        .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                }
                            }
                            .remoteCard(padding: 12)
                        }
                    }

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.danger)
                    }

                    Button {
                        create()
                    } label: {
                        HStack(spacing: 8) {
                            if creating { Spinner(size: 13, color: RemoteTheme.onAccent) }
                            Text(creating ? "Creating..." : "Create room")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemotePrimaryButtonStyle())
                    .disabled(!canCreate)
                }
                .padding(16)
            }
            .remoteScreen()
            .navigationTitle("New room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if folder.isEmpty, let first = client.recentFolders.first {
                    folder = first
                }
                if draftAgents.isEmpty {
                    seedDefaultAgents()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func seedDefaultAgents() {
        let models = client.availableModels
        guard let first = models.first else { return }
        let second = models.first(where: { $0.makerName != first.makerName }) ?? models.dropFirst().first ?? first
        draftAgents = [
            DraftAgent(name: defaultNames[0], role: "Lead", modelOptionID: first.id),
            DraftAgent(name: defaultNames[1], role: "Reviewer", modelOptionID: second.id),
        ]
    }

    private func addAgent() {
        let idx = draftAgents.count
        let models = client.availableModels
        guard !models.isEmpty else { return }
        let chosen = models[idx % models.count]
        let name = idx < defaultNames.count ? defaultNames[idx] : "Agent \(idx + 1)"
        draftAgents.append(DraftAgent(name: name, role: "", modelOptionID: chosen.id))
    }

    private func create() {
        let models = client.availableModels
        guard let fallback = models.first else { return }
        creating = true
        errorText = nil
        let specs: [RemoteNewRoomAgent] = draftAgents.map { draft in
            let opt = models.first { $0.id == draft.modelOptionID } ?? fallback
            return RemoteNewRoomAgent(
                name: draft.name,
                role: draft.role,
                providerID: opt.providerID,
                modelID: opt.modelID
            )
        }
        let targetDir = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let room = try await client.createRoom(
                    directory: targetDir,
                    title: cleanTitle,
                    mode: mode,
                    agents: specs
                )
                dismiss()
                onCreated(room)
            } catch {
                errorText = error.localizedDescription
            }
            creating = false
        }
    }
}

// MARK: - Git Diff Sheet

struct RemoteDiffSheet: View {
    let client: RemoteClient
    let sessionID: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var diff: RemoteSessionDiff?
    @State private var loading = false
    @State private var errorText: String?
    @State private var collapsedPaths: Set<String> = []

    private var totalAdditions: Int { diff?.files.reduce(0) { $0 + $1.additions } ?? 0 }
    private var totalDeletions: Int { diff?.files.reduce(0) { $0 + $1.deletions } ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading && diff == nil {
                        ProgressView("Loading git changes...")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if let errorText, diff == nil {
                        VStack(spacing: 12) {
                            Label(errorText, systemImage: "exclamationmark.triangle")
                                .font(RemoteTheme.font(size: 14, relativeTo: .subheadline))
                                .foregroundStyle(RemoteTheme.danger)
                                .multilineTextAlignment(.center)
                            Button("Try again") { Task { await reload() } }
                                .buttonStyle(RemoteSecondaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else if let diff {
                        summaryBar(diff)

                        if diff.files.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(RemoteTheme.tertiaryText)
                                Text("No uncommitted changes")
                                    .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .headline))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        } else {
                            ForEach(diff.files) { file in
                                diffFileCard(file)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .remoteScreen()
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .accessibilityLabel("Refresh changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
        }
        .presentationDetents([.medium, .large])
    }

    private func summaryBar(_ diff: RemoteSessionDiff) -> some View {
        HStack(spacing: 8) {
            Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                .font(RemoteTheme.font(size: 13.5, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.primaryText)
            if totalAdditions > 0 {
                Text("+\(totalAdditions)")
                    .font(RemoteTheme.font(size: 12.5, weight: .semibold, design: .monospaced, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.success)
            }
            if totalDeletions > 0 {
                Text("-\(totalDeletions)")
                    .font(RemoteTheme.font(size: 12.5, weight: .semibold, design: .monospaced, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.danger)
            }
            Spacer(minLength: 4)
            if diff.truncated {
                Chip(text: "Truncated", color: RemoteTheme.warning)
            }
        }
    }

    private func diffFileCard(_ file: RemoteDiffFile) -> some View {
        let collapsed = collapsedPaths.contains(file.path)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if collapsed { collapsedPaths.remove(file.path) } else { collapsedPaths.insert(file.path) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(RemoteTheme.font(size: 10.5, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .frame(width: 12)
                    Text(file.path)
                        .font(RemoteTheme.font(size: 12.5, weight: .medium, design: .monospaced, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(RemoteTheme.font(size: 11.5, weight: .semibold, design: .monospaced, relativeTo: .caption2))
                            .foregroundStyle(RemoteTheme.success)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .font(RemoteTheme.font(size: 11.5, weight: .semibold, design: .monospaced, relativeTo: .caption2))
                            .foregroundStyle(RemoteTheme.danger)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed && !file.diffText.isEmpty {
                Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        let lines = file.diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(RemoteTheme.font(size: 11.5, design: .monospaced, relativeTo: .caption2))
                                .foregroundStyle(diffLineColor(line))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(diffLineBackground(line))
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(RemoteTheme.codeBackground)
            }
        }
        .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return RemoteTheme.success }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return RemoteTheme.danger }
        if line.hasPrefix("@@") { return RemoteTheme.accent }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return RemoteTheme.tertiaryText
        }
        return RemoteTheme.primaryText
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return RemoteTheme.success.opacity(0.11) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return RemoteTheme.danger.opacity(0.11) }
        if line.hasPrefix("@@") { return RemoteTheme.accent.opacity(0.08) }
        return .clear
    }

    private func reload() async {
        loading = true
        errorText = nil
        do {
            diff = try await client.sessionDiff(sessionID: sessionID)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Inline Second Opinion Card

struct RemoteSecondOpinionCard: View {
    let opinion: RemoteSecondOpinion
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.accent)
                Text("Second opinion")
                    .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.secondaryText)
                Text(opinion.modelName)
                    .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let verdict = opinion.verdict, !verdict.isEmpty {
                    Chip(text: verdict, color: verdictColor(verdict))
                }
            }

            if opinion.status == "running" {
                HStack(spacing: 8) {
                    Spinner(size: 11, color: RemoteTheme.accent)
                    Text("Getting a second opinion from \(opinion.modelName)...")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)
                }
            } else if opinion.status == "failed" {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(RemoteTheme.font(size: 11.5, relativeTo: .caption))
                    Text(opinion.error ?? "Second opinion failed.")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(RemoteTheme.danger)
            } else {
                if let summary = opinion.summary, !summary.isEmpty {
                    Text(summary)
                        .font(RemoteTheme.font(size: 13.5, relativeTo: .subheadline))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !opinion.concerns.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(opinion.concerns.enumerated()), id: \.offset) { _, concern in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle()
                                    .fill(RemoteTheme.warning)
                                    .frame(width: 5, height: 5)
                                Text(concern)
                                    .font(RemoteTheme.font(size: 12.5, relativeTo: .footnote))
                                    .foregroundStyle(RemoteTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let details = opinion.details, !details.isEmpty {
                    Button {
                        withAnimation(.snappy) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? "Hide full critique" : "Show full critique")
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                                .font(RemoteTheme.font(size: 9.5, weight: .semibold, relativeTo: .caption2))
                        }
                        .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(RemoteTheme.accent)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        Text(details)
                            .font(RemoteTheme.font(size: 12.5, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .remoteCard(padding: 12, cornerRadius: 12)
    }

    private func verdictColor(_ verdict: String) -> Color {
        let lower = verdict.lowercased()
        if lower.contains("agree") || lower.contains("solid") { return RemoteTheme.success }
        if lower.contains("disagree") { return RemoteTheme.danger }
        if lower.contains("mixed") { return RemoteTheme.warning }
        return RemoteTheme.accent
    }
}
