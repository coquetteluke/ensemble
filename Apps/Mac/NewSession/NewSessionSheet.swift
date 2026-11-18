import SwiftUI
import AppKit
import EnsembleKit

/// New session: folder, model, permission mode.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                label("Folder")
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(theme.textSecondary)
                        Text(directory.isEmpty ? "Choose a project folder" : Format.abbreviatedPath(directory))
                            .foregroundStyle(directory.isEmpty ? theme.textTertiary : theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.border))
                    Button("Choose...", action: chooseFolder)
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !recentFolders.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(recentFolders.prefix(4), id: \.self) { folder in
                            Button(Format.folderName(folder)) { directory = folder }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(directory == folder ? theme.textPrimary : theme.textSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(directory == folder ? theme.selection : theme.hover))
                                .help(folder)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
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

            VStack(alignment: .leading, spacing: 8) {
                label("Permissions")
                Picker("Permissions", selection: $mode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                Text(mode.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(mode.isDangerous ? theme.danger : theme.textTertiary)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
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
        .padding(22)
        .frame(width: 460)
        .background(theme.background)
        .onAppear {
            directory = window.newSessionDirectory ?? store.selected?.directory ?? recentFolders.first ?? ""
            modelID = (store.defaultModel ?? store.models.first(where: \.available)?.ref)?.description ?? ""
            mode = store.defaultPermissionMode
        }
    }

    private var recentFolders: [String] { store.projects.map(\.directory) }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
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
                try await store.newSession(directory: directory, model: model, permissionMode: mode)
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
