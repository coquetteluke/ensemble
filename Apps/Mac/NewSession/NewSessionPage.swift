import SwiftUI
import AppKit
import EnsembleKit

/// New session, in the main area: pick a folder from the recent ones (or choose another), optionally work in a copy,
/// then write the first message. Sending creates the session in that folder with the chosen model and permission mode
/// and sends the message.
struct NewSessionPage: View {
    let store: SessionStore
    @Bindable var window: WindowState
    /// Snapshots preset the folder and the draft.
    var initialDirectory = ""
    var initialDraft = ""
    var initialWorktree = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var directory = ""
    @State private var modelID = ""
    @State private var mode: PermissionMode = .auto
    @State private var inWorktree = false
    @State private var draft = ""
    @State private var creating = false
    @State private var error: String?
    @State private var modelBilling: [String: ModelBilling]?
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: theme.z(24))
            VStack(spacing: theme.z(14)) {
                folderCard
                if let line = store.newSessionTrustLine(directory: directory, model: ModelRef(string: modelID)) {
                    NewSessionTrustRow(line: line, error: store.trustError(for: directory)) {
                        store.trustFolder(directory)
                    }
                    .padding(.horizontal, theme.z(4))
                }
                if showsWorktreeOption {
                    worktreeCard
                }
            }
            .frame(maxWidth: theme.z(460))
            Spacer(minLength: theme.z(24))
            VStack(spacing: theme.z(8)) {
                if let error {
                    Text(error)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                composer
                chipRow
            }
            .frame(maxWidth: theme.z(760))
            .padding(.bottom, theme.z(18))
        }
        .padding(.horizontal, theme.z(28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .task(id: "\(directory)|\(WorkspaceTrust.shared.isTrusted(directory))") {
            guard !directory.isEmpty else { return }
            await store.checkWorktreeAvailability(directory)
        }
        .task(id: store.models.count) {
            // Models can arrive after the page opens (right after launch): pick the default then.
            if ModelRef(string: modelID) == nil { seedModel() }
            guard !isSnapshot, let billing = store.engine as? any EngineModelBilling else { return }
            modelBilling = try? await billing.modelBilling()
            let folders = ModelCatalog.folders(store.models, billing: modelBilling)
            if let current = ModelRef(string: modelID),
               let resolved = ModelCatalog.resolvedRef(for: current, in: folders)?.description {
                modelID = resolved
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: window.newSessionToken) { prepare() }
        .onExitCommand { if store.selected != nil { window.route = .session } }
    }

    // MARK: Folder

    private var folderCard: some View {
        VStack(spacing: 0) {
            ForEach(folderChoices, id: \.self) { folder in
                FolderRow(symbol: "laptopcomputer", title: Format.folderName(folder),
                          detail: Format.abbreviatedPath(folder), selected: folder == directory) {
                    directory = folder
                    draftFocused = true
                }
                .help(folder)
            }
            if !folderChoices.isEmpty {
                Rectangle().fill(theme.border).frame(height: 1)
            }
            FolderRow(symbol: "folder.badge.plus", title: "Choose another folder...", detail: nil, selected: false,
                      action: chooseFolder)
        }
        .padding(theme.z(5))
        .background(RoundedRectangle(cornerRadius: theme.z(14), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(14), style: .continuous).strokeBorder(theme.border))
        .overlay(alignment: .topTrailing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: theme.z(30), height: theme.z(30))
                .offset(x: -theme.z(18), y: -theme.z(26))
                .accessibilityHidden(true)
        }
    }

    /// Recent folders, the chosen one first when it is not among them.
    private var folderChoices: [String] {
        var folders = Array(store.projects.map(\.directory).prefix(4))
        if !directory.isEmpty, !folders.contains(directory) { folders.insert(directory, at: 0) }
        return folders
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory) }
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
            draftFocused = true
        }
    }

    // MARK: Worktree

    /// Why the chosen folder cannot get a copy ("" when it can, nil while checking).
    private var worktreeReason: String? { store.worktrees.availability[directory] }

    /// Shown for folders in a git repository.
    private var showsWorktreeOption: Bool {
        guard !directory.isEmpty, let reason = worktreeReason else { return false }
        return reason != WorktreeStatusControls.notRepository
    }

    private var worktreeAvailable: Bool { worktreeReason == "" }
    private var usesWorktree: Bool { inWorktree && worktreeAvailable }

    private var worktreeCard: some View {
        Button {
            inWorktree.toggle()
        } label: {
            HStack(spacing: theme.z(10)) {
                Text(usesWorktree ? "Turn off Worktree" : "Turn on Worktree")
                    .font(theme.font(size: 13, weight: .medium))
                    .foregroundStyle(worktreeAvailable ? theme.textPrimary : theme.textTertiary)
                Text(worktreeAvailable
                     ? (usesWorktree ? "New branch in .ensemble/worktrees" : "Session runs in this folder")
                     : (worktreeReason ?? ""))
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(40))
            .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous)
                .strokeBorder(usesWorktree ? theme.accent.opacity(0.6) : theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!worktreeAvailable)
        .help("Work in a copy: the session gets its own checkout on a new branch, inside this folder")
    }

    // MARK: Composer

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: theme.z(10)) {
            TextField("Describe a task or ask a question", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...10)
                .focused($draftFocused)
                .onSubmit(send)
                .padding(.vertical, theme.z(5))
            Button(action: send) {
                Image(systemName: creating ? "ellipsis" : "arrow.up")
                    .font(theme.font(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? theme.onAccent : theme.textTertiary)
                    .frame(width: theme.z(30), height: theme.z(30))
                    .background(Circle().fill(canSend ? theme.accent : theme.hover))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Start the session and send (Return)")
            .accessibilityLabel("Start the session and send")
        }
        .padding(.leading, theme.z(16))
        .padding(.trailing, theme.z(10))
        .padding(.vertical, theme.z(10))
        .background(RoundedRectangle(cornerRadius: theme.z(16), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(16), style: .continuous).strokeBorder(theme.border))
        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: theme.z(10), y: theme.z(3))
    }

    private var canSend: Bool { hasText && !directory.isEmpty && !creating }

    private var chipRow: some View {
        HStack(spacing: theme.z(4)) {
            Menu {
                ForEach(Array(store.projects.map(\.directory).prefix(8)), id: \.self) { folder in
                    Button(Format.folderName(folder)) { directory = folder }
                }
                Divider()
                Button("Choose another folder...", action: chooseFolder)
            } label: {
                chipLabel(symbol: "folder", title: directory.isEmpty ? "Choose a folder" : Format.folderName(directory))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(directory)

            if showsWorktreeOption {
                Toggle(isOn: Binding(get: { usesWorktree }, set: { inWorktree = $0 })) {
                    Text("Worktree").font(theme.font(size: 12.5))
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(theme.textSecondary)
                .disabled(!worktreeAvailable)
                .padding(.leading, theme.z(6))
            }

            Spacer(minLength: theme.z(8))

            Menu {
                ForEach(ModelCatalog.folders(store.models, billing: modelBilling)) { folder in
                    Section(folder.maker.name) {
                        ForEach(folder.all) { choice in
                            if let route = ModelCatalog.pickerRoute(for: choice, selected: ModelRef(string: modelID)) {
                                Button("\(choice.name)  (\(route.providerName))") { modelID = route.ref.description }
                                    .disabled(!choice.available)
                            }
                        }
                    }
                }
            } label: {
                chipLabel(symbol: nil, title: modelTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                ForEach(PermissionMode.allCases, id: \.self) { choice in
                    Button(choice.label) { mode = choice }
                }
            } label: {
                chipLabel(symbol: nil, title: mode.label, tint: mode.isDangerous ? theme.danger : nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(mode.summary)
        }
        .padding(.horizontal, theme.z(6))
    }

    private var modelTitle: String {
        guard let ref = ModelRef(string: modelID) else { return "Choose a model" }
        return store.modelName(ref)
    }

    private func chipLabel(symbol: String?, title: String, tint: Color? = nil) -> some View {
        HStack(spacing: theme.z(5)) {
            if let symbol { Image(systemName: symbol).font(theme.font(size: 11.5)) }
            Text(title).font(theme.font(size: 12.5)).lineLimit(1)
            Image(systemName: "chevron.down").font(theme.font(size: 8, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(tint ?? theme.textSecondary)
        .padding(.horizontal, theme.z(8))
        .frame(height: theme.z(28))
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func prepare() {
        error = nil
        inWorktree = initialWorktree
        if !initialDraft.isEmpty { draft = initialDraft }
        directory = !initialDirectory.isEmpty ? initialDirectory
            : (window.newSessionDirectory ?? store.selected?.directory ?? store.projects.first?.directory ?? "")
        seedModel()
        mode = store.defaultPermissionMode
        if !isSnapshot { draftFocused = true }
    }

    /// The default model, or the first available one.
    private func seedModel() {
        let folders = ModelCatalog.folders(store.models, billing: modelBilling)
        let fallback = folders.lazy.flatMap(\.all).first(where: \.available)?.primary?.ref
            ?? store.models.first(where: \.available)?.ref
        let seed = store.defaultModel ?? fallback
        modelID = ModelCatalog.resolvedRef(for: seed, in: folders)?.description ?? ""
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        error = nil
        Task {
            do {
                let session = try await store.newSession(directory: directory, model: ModelRef(string: modelID),
                                                         permissionMode: mode, inWorktree: usesWorktree)
                draft = ""
                window.open(session.id, store: store)
                window.composerFocusToken &+= 1
                await store.send(text, to: session.id)
            } catch {
                self.error = "Could not start the session: \(error.localizedDescription)"
            }
            creating = false
        }
    }
}

/// One row of the folder card.
private struct FolderRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(10)) {
                Image(systemName: symbol)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: theme.z(20))
                Text(title)
                    .font(theme.font(size: 14))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(8))
                if let detail {
                    Text(detail)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, theme.z(12))
            .frame(height: theme.z(38))
            .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous)
                .fill(selected ? theme.raisedSelection : (hovering ? theme.raisedHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
