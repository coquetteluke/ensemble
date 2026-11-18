import SwiftUI
import EnsembleKit

/// Menu bar items for search, the palette, the shortcut list and the transcript view, with their shortcuts
/// from `CommandRegistry`. Added next to `EnsembleCommands`.
struct FindingCommands: Commands {
    let search: SearchCenter
    let hasStore: Bool
    @AppStorage(TranscriptViewMode.storageKey) private var mode = TranscriptViewMode.normal.rawValue

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search Sessions\u{2026}") { search.toggle(.search) }
                .appShortcut(.searchTranscripts)
                .disabled(!hasStore)
        }

        CommandGroup(after: .sidebar) {
            Picker("Transcript View", selection: $mode) {
                ForEach(TranscriptViewMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            Button("Next Transcript View") { TranscriptViewMode.cycle() }
                .appShortcut(.nextTranscriptView)
            Button("Command Palette\u{2026}") { search.toggle(.palette) }
                .appShortcut(.commandPalette)
                .disabled(!hasStore)
            if search.filePreview != nil {
                Button("Close File Viewer") { search.closeFile() }
            }
            Divider()
        }

        // After the Help menu's own items (its search field stays).
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { search.toggle(.shortcuts) }
                .appShortcut(.keyboardShortcuts)
        }
    }
}

/// The small transcript view control for the window's header: shows the current mode, opens the three choices.
struct TranscriptViewModeMenu: View {
    @AppStorage(TranscriptViewMode.storageKey) private var saved = TranscriptViewMode.normal.rawValue
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.transcriptViewMode) private var forced
    @State private var hovering = false

    private var mode: TranscriptViewMode { forced ?? TranscriptViewMode(rawValue: saved) ?? .normal }

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Picker("Transcript view", selection: $saved) {
                    ForEach(TranscriptViewMode.allCases) { mode in
                        Label { Text(mode.label) } icon: { Image(systemName: mode.symbol) }
                            .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Next Transcript View") { TranscriptViewMode.cycle() }
                    .appShortcut(.nextTranscriptView)
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help("Transcript view: \(mode.label). \(mode.summary). Control-O switches.")
        }
    }

    private var label: some View {
        HStack(spacing: theme.z(5)) {
            Image(systemName: mode.symbol)
                .font(theme.font(size: 11.5))
            Text(mode.label)
                .font(theme.font(size: 12))
            Image(systemName: "chevron.down")
                .font(theme.font(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
        .padding(.horizontal, theme.z(8))
        .frame(height: theme.z(24))
        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(hovering ? theme.hover : .clear))
        .contentShape(Rectangle())
        .accessibilityLabel("Transcript view, \(mode.label)")
    }
}
