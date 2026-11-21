import EnsembleKit
import SwiftUI

/// The Settings row for the chat font: the chosen font's name and a sample line set in it. Tapping it opens
/// the list of fonts. The choice is this iPhone's own (`ChatFontStore`); the Mac keeps its own.
struct ChatFontSettingsRow: View {
    var store: ChatFontStore = .shared
    @State private var showFonts = false

    var body: some View {
        Button {
            showFonts = true
        } label: {
            HStack(spacing: 12) {
                ChatFontLabel(font: store.current)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RemoteTheme.tertiaryText)
            }
            .frame(minHeight: RemoteTheme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .remoteCard()
        .accessibilityLabel("Chat font, \(store.current.name)")
        .accessibilityHint("Shows the fonts you can choose")
        .sheet(isPresented: $showFonts) {
            ChatFontSheet(store: store)
                .remoteThemeEnvironment()
        }
    }
}

/// A font's name and the sample line, both set in that font, following Dynamic Type.
private struct ChatFontLabel: View {
    let font: ChatFont
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var sampleSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(font.name)
                .font(font.font(size: nameSize))
                .foregroundStyle(RemoteTheme.primaryText)
            Text(LocalizedStringKey(ChatFontSample.line))
                .font(font.font(size: sampleSize))
                .foregroundStyle(RemoteTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
    }
}

/// Every font that can be chosen, with "Add Font" for .ttf and .otf files from Files or AirDrop. Added fonts
/// are copied into this app's own storage on this iPhone and can be removed here.
struct ChatFontSheet: View {
    let store: ChatFontStore
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var problems: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.choices.enumerated()), id: \.element.id) { index, font in
                            if index > 0 {
                                Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                            }
                            ChatFontChoiceRow(
                                font: font,
                                selected: font.id == store.current.id,
                                select: { store.select(font) },
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

                    Text("Used for what agents write: replies, plans and questions. Add Font takes .ttf and .otf files, several at once for a family's regular, bold and italic. Added fonts are kept on this iPhone only.")
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
            .navigationTitle("Chat font")
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
}

/// One font in the list: tap to choose it. An added font has a Remove button.
private struct ChatFontChoiceRow: View {
    let font: ChatFont
    let selected: Bool
    let select: () -> Void
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        ChatFontLabel(font: font)
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
