import EnsembleKit
import SwiftUI

/// The Settings rows for fonts: one for the chat font (what agents write) and one for the interface font
/// (everything else). Each shows the chosen font's name and a sample line set in it, and opens the list of
/// fonts. Choices and added fonts sync with the paired Mac (`FontSync`); the newer choice wins on both.
struct FontSettingsRows: View {
    var store: FontStore = .shared
    /// False in the demo, where there is no Mac to sync with.
    var syncsWithMac = true
    @State private var editing: FontRole?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(FontRole.allCases) { role in
                if role != FontRole.allCases.first {
                    Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                }
                Button {
                    editing = role
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(role.title)
                                .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.tertiaryText)
                            FontLabel(font: store.font(for: role), role: role)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                    .frame(minHeight: RemoteTheme.minTapTarget)
                    .padding(.horizontal, RemoteTheme.cardPadding)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(role.title), \(store.font(for: role).name)")
                .accessibilityHint("Shows the fonts you can choose")
            }
        }
        .remoteCard(padding: 0)
        .sheet(item: $editing) { role in
            FontSheet(store: store, role: role, syncsWithMac: syncsWithMac)
                .remoteThemeEnvironment()
        }
    }
}

/// A font's name and the sample line of a role, both set in that font, following Dynamic Type.
private struct FontLabel: View {
    let font: AppFont
    let role: FontRole
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var sampleSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(font.name)
                .font(font.font(size: nameSize))
                .foregroundStyle(RemoteTheme.primaryText)
            Text(LocalizedStringKey(role.sample))
                .font(font.font(size: sampleSize))
                .foregroundStyle(RemoteTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
    }
}

/// Every font that can be chosen for the chat or the interface, with "Add Font" for .ttf and .otf files from
/// Files or AirDrop. Added fonts are copied into this app's own storage, sent to the paired Mac, and can be
/// removed here.
struct FontSheet: View {
    let store: FontStore
    @State var role: FontRole
    var syncsWithMac = true
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var problems: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Font for", selection: $role) {
                        ForEach(FontRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 0) {
                        ForEach(Array(store.choices.enumerated()), id: \.element.id) { index, font in
                            if index > 0 {
                                Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                            }
                            FontChoiceRow(
                                font: font,
                                role: role,
                                selected: font.id == store.font(for: role).id,
                                select: { store.select(font, for: role) },
                                remove: font.isCustom ? { store.remove(font) } : nil
                            )
                        }
                    }
                    .remoteCard(padding: 0)

                    Button {
                        picking = true
                    } label: {
                        Text("Add Font\u{2026}")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())

                    ForEach(problems, id: \.self) { problem in
                        Text(problem)
                            .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                            .foregroundStyle(RemoteTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(footer)
                        .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, RemoteTheme.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .remoteScreen()
            .navigationTitle("Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: CustomFontLibrary.contentTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let files): problems = store.add(files)
                case .failure(let error): problems = [error.localizedDescription]
                }
            }
        }
    }

    private var footer: String {
        let roles = "The chat font is used for what agents write: replies, plans and questions. The interface font is used for everything else. Code stays in the system's fixed-width font."
        let adding = "Add Font takes .ttf and .otf files, several at once for a family's regular, bold and italic."
        let sync = syncsWithMac
            ? "Your choices and the fonts you add sync with your paired Mac while the two are connected."
            : "In the demo there is no Mac to sync with."
        return [roles, adding, sync].joined(separator: " ")
    }
}

/// One font in the list: tap to choose it for the role. An added font has a Remove button.
private struct FontChoiceRow: View {
    let font: AppFont
    let role: FontRole
    let selected: Bool
    let select: () -> Void
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        FontLabel(font: font, role: role)
                        Text(font.detail)
                            .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RemoteTheme.accent)
                        .opacity(selected ? 1 : 0)
                }
                .frame(minHeight: RemoteTheme.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(font.name), \(font.detail)")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if let remove {
                Button("Remove", role: .destructive, action: remove)
                    .font(RemoteTheme.font(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(RemoteTheme.danger)
                    .frame(minWidth: RemoteTheme.minTapTarget, minHeight: RemoteTheme.minTapTarget)
                    .accessibilityLabel("Remove \(font.name)")
            }
        }
        .padding(.horizontal, RemoteTheme.cardPadding)
        .padding(.vertical, 10)
    }
}
