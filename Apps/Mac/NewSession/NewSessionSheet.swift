import SwiftUI
import AppKit
import EnsembleKit

/// New session: folder (and whether to work in a copy of it), model, permission mode.
struct NewSessionSheet: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var directory = ""
    @State private var modelID = ""
    @State private var mode: PermissionMode = .auto
    @State private var creating = false
    @State private var error: String?
    /// "Work in a copy (git worktree)", for folders in a git repository.
    @State private var inWorktree = false

    /// `initialDirectory` presets the folder (snapshots); otherwise it is chosen when the sheet appears. `initialWorktree`
    /// presets the copy switch (snapshots).
    init(store: SessionStore, window: WindowState, initialDirectory: String = "", initialWorktree: Bool = false) {
        self.store = store
        self.window = window
        _directory = State(initialValue: initialDirectory)
        _inWorktree = State(initialValue: initialWorktree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(18)) {
            Text("New session")
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: theme.z(8)) {
                label("Folder")
                HStack(spacing: theme.z(8)) {
                    HStack(spacing: theme.z(8)) {
                        Image(systemName: "folder")
                            .foregroundStyle(theme.textSecondary)
                        Text(directory.isEmpty ? "Choose a project folder" : Format.abbreviatedPath(directory))
                            .foregroundStyle(directory.isEmpty ? theme.textTertiary : theme.textPrimary)
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
                if let line = store.newSessionTrustLine(directory: directory, model: ModelRef(string: modelID)) {
                    NewSessionTrustRow(line: line, error: store.trustError(for: directory)) {
                        store.trustFolder(directory)
                    }
                }
                if showsWorktreeOption {
                    worktreeOption
                }
                if !recentFolders.isEmpty {
                    HStack(spacing: theme.z(6)) {
                        ForEach(recentFolders.prefix(4), id: \.self) { folder in
                            Button(Format.folderName(folder)) { directory = folder }
                                .buttonStyle(.plain)
                                .font(theme.font(size: 12))
                                .foregroundStyle(directory == folder ? theme.textPrimary : theme.textSecondary)
                                .padding(.horizontal, theme.z(8))
                                .frame(height: theme.z(24))
                                .background(RoundedRectangle(cornerRadius: theme.z(6)).fill(directory == folder ? theme.selection : theme.hover))
                                .help(folder)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: theme.z(8)) {
                label("Model")
                Picker("Model", selection: $modelID) {
                    ForEach(store.models) { model in
                        Text("\(model.name)  (\(model.providerName))")
                            .tag(model.ref.description)
                            .disabled(!model.available)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: theme.z(8)) {
                label("Permissions")
                Picker("Permissions", selection: $mode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                Text(mode.summary)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(mode.isDangerous ? theme.danger : theme.textTertiary)
            }

            if let error {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(directory.isEmpty || creating)
            }
        }
        .padding(theme.z(22))
        .frame(width: theme.z(460))
        .background(theme.background)
        .task(id: "\(directory)|\(WorkspaceTrust.shared.isTrusted(directory))") {
            guard !directory.isEmpty else { return }
            await store.checkWorktreeAvailability(directory)
        }
        .onAppear {
            if directory.isEmpty {
                directory = window.newSessionDirectory ?? store.selected?.directory ?? recentFolders.first ?? ""
            }
            modelID = (store.defaultModel ?? store.models.first(where: \.available)?.ref)?.description ?? ""
            mode = store.defaultPermissionMode
        }
    }

    private var recentFolders: [String] { store.projects.map(\.directory) }

    /// Why the chosen folder cannot get a copy ("" when it can, nil while checking).
    private var worktreeReason: String? { store.worktrees.availability[directory] }

    /// Shown for folders in a git repository.
    private var showsWorktreeOption: Bool {
        guard !directory.isEmpty, let reason = worktreeReason else { return false }
        return reason != WorktreeStatusControls.notRepository
    }

    private var worktreeAvailable: Bool { worktreeReason == "" }

    private var worktreeOption: some View {
        VStack(alignment: .leading, spacing: theme.z(3)) {
            Toggle(isOn: Binding(get: { inWorktree && worktreeAvailable }, set: { inWorktree = $0 })) {
                HStack(spacing: theme.z(4)) {
                    Text("Work in a copy")
                        .foregroundStyle(worktreeAvailable ? theme.textPrimary : theme.textTertiary)
                    Text("(git worktree)")
                        .foregroundStyle(theme.textTertiary)
                }
                .font(theme.font(size: 12.5))
            }
            .toggleStyle(CompactSwitchStyle())
            .disabled(!worktreeAvailable)
            Text(worktreeAvailable ? "The session gets its own checkout on a new branch, in .ensemble/worktrees inside this folder"
                 : (worktreeReason ?? ""))
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, theme.z(2))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
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
        }
    }

    private func create() {
        creating = true
        error = nil
        let model = ModelRef(string: modelID)
        Task {
            do {
                try await store.newSession(directory: directory, model: model, permissionMode: mode,
                                           inWorktree: inWorktree && worktreeAvailable)
                window.route = .session
                window.composerFocusToken &+= 1
                dismiss()
            } catch {
                self.error = "Could not create the session: \(error.localizedDescription)"
            }
            creating = false
        }
    }
}

/// The chosen folder's trust state in a line, with Trust when the folder has settings, hooks or MCP servers the agent
/// would skip (or the agent does not start in untrusted folders).
struct NewSessionTrustRow: View {
    let line: NewSessionTrustLine
    let error: String?
    let onTrust: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            HStack(spacing: theme.z(6)) {
                Image(systemName: symbol)
                    .font(theme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(tint)
                Text(line.text)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(line.tone == .blocked ? theme.warning : theme.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if line.offersTrust {
                    Button("Trust", action: onTrust)
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Trust this folder so agents load its own settings")
                }
            }
            if let error {
                Text(error)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch line.tone {
        case .trusted: "checkmark.shield"
        case .untrusted: "lock.shield"
        case .blocked: "exclamationmark.shield"
        }
    }

    private var tint: Color {
        switch line.tone {
        case .trusted: theme.success
        case .untrusted: theme.textTertiary
        case .blocked: theme.warning
        }
    }
}
