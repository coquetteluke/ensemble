import SwiftUI
import EnsembleKit

/// Promotes an active solo chat into a multi-agent room in the same folder with a compact context handoff.
struct PromoteToRoomSheet: View {
    let store: SessionStore
    let session: SessionModel
    let rooms: RoomsController
    @Binding var isCreating: Bool
    var onPromoted: (UUID) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var mode: RoomMode = .team
    @State private var selectedIDs: [String] = []
    @State private var starterPrompt = ""
    @State private var error: String?

    init(
        store: SessionStore,
        session: SessionModel,
        rooms: RoomsController,
        isCreating: Binding<Bool>,
        onPromoted: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.session = session
        self.rooms = rooms
        self._isCreating = isCreating
        self.onPromoted = onPromoted
        let rawTitle = session.info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderTitle = Format.folderName(store.projectFolder(for: session))
        self._title = State(initialValue: rawTitle.isEmpty || rawTitle == "New session" ? folderTitle : rawTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(16)) {
            header
            titleAndFolder
            leadSummary
            modeSection
            additionalAgentsSection
            starterSection

            if let error {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
            }

            footer
        }
        .padding(theme.z(22))
        .frame(width: theme.z(560))
        .background(theme.background)
        .onAppear(perform: selectDefaultModel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            Text("Add agents to a room")
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Folder: \(Format.abbreviatedPath(store.projectFolder(for: session)))")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var titleAndFolder: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            sectionLabel("Room title")
            InputField("Room title", text: $title, height: 30)
        }
    }

    private var leadSummary: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.accent)
            Text("Lead participant:")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text(store.modelName(session.info.model))
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)
            Text("Up to 12,000 chars of chat handed off")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(8))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border))
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            sectionLabel("Room mode")
            HStack(spacing: theme.z(8)) {
                ForEach([RoomMode.team, .debate, .roundTable], id: \.self) { candidate in
                    let selected = mode == candidate
                    Button {
                        mode = candidate
                    } label: {
                        HStack(spacing: theme.z(6)) {
                            Image(systemName: candidate.symbolName)
                                .font(theme.font(size: 11))
                            Text(candidate.label)
                                .font(theme.font(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                        .padding(.horizontal, theme.z(10))
                        .frame(height: theme.z(28))
                        .background(
                            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                                .fill(selected ? theme.accent : theme.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                                .strokeBorder(selected ? theme.accent : theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            Text(mode.explanation)
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var additionalAgentsSection: some View {
        let options = availableOptions
        return VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack {
                sectionLabel("Add 1 to 3 models")
                Spacer()
                Text("\(selectedIDs.count) of 3 selected")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(4)) {
                    ForEach(options) { option in
                        let checked = selectedIDs.contains(option.id)
                        Button {
                            toggle(option.id)
                        } label: {
                            HStack(spacing: theme.z(8)) {
                                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                    .font(theme.font(size: 13))
                                    .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                                Text(option.name)
                                    .font(theme.font(size: 12.5, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(option.makerName)
                                    .font(theme.font(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.horizontal, theme.z(6))
                                    .padding(.vertical, theme.z(2))
                                    .background(Capsule().fill(theme.codeBackground))
                            }
                            .padding(.horizontal, theme.z(8))
                            .padding(.vertical, theme.z(6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle(selected: checked, cornerRadius: theme.z(6)))
                    }
                }
            }
            .frame(maxHeight: theme.z(160))
            .padding(theme.z(6))
            .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border))
        }
    }

    private var starterSection: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            sectionLabel("Opening instruction (optional)")
            RoomTextEditor(
                placeholder: "Leave blank to continue straight from the handed-off solo chat",
                text: $starterPrompt,
                minHeight: 54,
                maxHeight: 96
            )
        }
    }

    private var footer: some View {
        HStack(spacing: theme.z(8)) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

            Button(isCreating ? "Starting..." : "Start") {
                startRoom()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty || isCreating)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
    }

    private var availableOptions: [SecondOpinionModelOption] {
        SecondOpinionModels.options(from: store.models, current: session.info.model)
    }

    private func selectDefaultModel() {
        guard selectedIDs.isEmpty, let first = availableOptions.first else { return }
        selectedIDs = [first.id]
    }

    private func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) {
            if selectedIDs.count > 1 {
                selectedIDs.remove(at: index)
            }
        } else if selectedIDs.count < 3 {
            selectedIDs.append(id)
        }
    }

    private func startRoom() {
        let pickedModels = selectedIDs.compactMap { id in
            store.models.first { $0.available && $0.ref.description == id }
        }
        guard !pickedModels.isEmpty else {
            error = "Choose at least one available model."
            return
        }
        isCreating = true
        error = nil
        Task { @MainActor in
            defer { isCreating = false }
            do {
                let engine = try await rooms.promoteSessionToRoom(
                    session: session,
                    store: store,
                    title: title,
                    additionalModels: pickedModels,
                    mode: mode,
                    starterPrompt: starterPrompt
                )
                dismiss()
                onPromoted(engine.state.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
