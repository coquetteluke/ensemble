import SwiftUI
import EnsembleKit

/// Settings > General > Fonts: the chat font (what agents write) and the interface font (everything else).
/// A switch picks which of the two the list changes; each row shows a font's name and a sample line in that
/// font. "Add Font" copies .ttf and .otf files into this Mac's Application Support folder
/// (`CustomFontLibrary`); added fonts are listed under their family name and can be removed.
/// A choice applies to every window at once (`FontStore`) and syncs with a paired iPhone (`FontSync`).
struct FontSettingsSection: View {
    private let store: FontStore
    @Environment(\.theme) private var theme
    @State private var role: FontRole
    @State private var picking = false
    /// One line for each file the last "Add Font" refused.
    @State private var problems: [String]

    /// Snapshots pass their own store, the role to show and the lines to show.
    init(store: FontStore = .shared, role: FontRole = .chat, problems: [String] = []) {
        self.store = store
        _role = State(initialValue: role)
        _problems = State(initialValue: problems)
    }

    var body: some View {
        Section {
            Picker("Font for", selection: $role) {
                ForEach(FontRole.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
            .pickerStyle(.segmented)
            ForEach(store.choices) { font in
                FontRow(
                    font: font,
                    role: role,
                    selected: font.id == store.font(for: role).id,
                    select: { store.select(font, for: role) },
                    remove: font.isCustom ? { store.remove(font) } : nil
                )
            }
            Button("Add Font\u{2026}") { picking = true }
                .fileImporter(isPresented: $picking, allowedContentTypes: CustomFontLibrary.contentTypes, allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let files): problems = store.add(files)
                    case .failure(let error): problems = [error.localizedDescription]
                    }
                }
            ForEach(problems, id: \.self) { problem in
                Text(problem)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Fonts")
        } footer: {
            VStack(alignment: .leading, spacing: theme.z(6)) {
                Text("The chat font is used for what agents write: replies, plans and questions. The interface font is used for everything else. Code stays in the system's fixed-width font.")
                Text("Add Font takes .ttf and .otf files, several at once for a family's regular, bold and italic. Added fonts are kept in \(folderText).")
                Text("Your choices and the fonts you add sync with a paired iPhone while the two are connected. The newer choice wins on both.")
            }
            .font(theme.font(size: 11.5))
            .foregroundStyle(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderText: String {
        guard let folder = store.customFontFolder else { return "Application Support" }
        return TrustedFoldersSection.display(folder.path)
    }
}

/// One font: a checkmark when chosen for the role, the name and a sample line set in the font, and where it
/// comes from.
private struct FontRow: View {
    let font: AppFont
    let role: FontRole
    let selected: Bool
    let select: () -> Void
    var remove: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Button(action: select) {
                HStack(spacing: theme.z(10)) {
                    Image(systemName: "checkmark")
                        .font(.system(size: theme.z(11), weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .opacity(selected ? 1 : 0)
                        .frame(width: theme.z(14))
                    VStack(alignment: .leading, spacing: theme.z(3)) {
                        Text(font.name)
                            .font(font.font(size: theme.z(15)))
                            .foregroundStyle(theme.textPrimary)
                        Text(LocalizedStringKey(role.sample))
                            .font(font.font(size: theme.z(12.5)))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: theme.z(8))
                    Text(font.detail)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(font.name), \(font.detail)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let remove {
                Button("Remove", action: remove)
                    .accessibilityLabel("Remove \(font.name)")
            }
        }
        .padding(.vertical, theme.z(2))
    }
}
