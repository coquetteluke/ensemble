import SwiftUI
import AppKit
import EnsembleKit

/// Message box: text, attachments, attach button, permission-mode menu, model chip, send or stop.
struct ComposerView: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    /// Snapshots can open the mode menu inline.
    var snapshotDraft: String?

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var textHeight: CGFloat = 22
    @State private var showModeMenu = false
    @State private var showModelMenu = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                attachmentChips
            }
            textArea
            HStack(spacing: 4) {
                attachButton
                modeChip
                Spacer(minLength: 8)
                modelChip
                sendButton
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropTargeted ? theme.accent : theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: 10, y: 3)
        .modifier(FileDrop(enabled: !isSnapshot, targeted: $dropTargeted) { urls in
            window.attachments[session.id, default: []].append(contentsOf: urls.filter(\.isFileURL))
        })
    }

    // MARK: Text

    private var draft: Binding<String> {
        Binding(get: { window.drafts[session.id] ?? "" }, set: { window.drafts[session.id] = $0 })
    }

    private var attachments: [URL] { window.attachments[session.id] ?? [] }

    private var placeholder: String { "Send a message" }

    @ViewBuilder private var textArea: some View {
        let text = snapshotDraft ?? draft.wrappedValue
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
            if isSnapshot {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
            } else {
                ComposerTextView(
                    text: draft,
                    height: $textHeight,
                    focusToken: window.composerFocusToken,
                    textColor: NSColor(theme.textPrimary),
                    accentColor: NSColor(theme.accent),
                    onSubmit: { window.sendDraft(store: store) },
                    onCycleMode: { Task { await store.setPermissionMode(session.permissionMode.next, for: session.id) } }
                )
                .frame(height: min(max(textHeight, 22), 220))
            }
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Button {
                            window.attachments[session.id]?.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(url.lastPathComponent)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover))
                }
            }
        }
    }

    // MARK: Controls

    private var attachButton: some View {
        ComposerIconButton(symbol: "paperclip", help: "Attach files") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.directoryURL = URL(fileURLWithPath: session.directory)
            panel.prompt = "Attach"
            if panel.runModal() == .OK {
                window.attachments[session.id, default: []].append(contentsOf: panel.urls)
            }
        }
    }

    private var modeChip: some View {
        let mode = session.permissionMode
        return ComposerChip(symbol: mode.symbolName, title: mode.label,
                            tint: mode.isDangerous ? theme.danger : nil) {
            showModeMenu.toggle()
        }
        .help("Permission mode (Shift-Tab to switch)")
        .popover(isPresented: $showModeMenu, arrowEdge: .bottom) {
            ModeMenuContent(current: mode) { newMode in
                showModeMenu = false
                Task { await store.setPermissionMode(newMode, for: session.id) }
            }
            .ensembleTheme()
        }
    }

    private var modelChip: some View {
        ComposerChip(symbol: nil, title: store.modelName(session.info.model), tint: nil) {
            showModelMenu.toggle()
        }
        .help("Model")
        .popover(isPresented: $showModelMenu, arrowEdge: .bottom) {
            ModelMenuContent(models: store.models, current: session.info.model) { ref in
                showModelMenu = false
                Task { await store.switchModel(ref, for: session.id) }
            }
            .ensembleTheme()
        }
    }

    @ViewBuilder private var sendButton: some View {
        let hasText = !(snapshotDraft ?? draft.wrappedValue).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        if session.isWorking && !hasText {
            Button {
                Task { await store.stop() }
            } label: {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(theme.background)
                    .frame(width: 10, height: 10)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.textPrimary))
            }
            .buttonStyle(.plain)
            .help("Stop (Esc)")
            .accessibilityLabel("Stop")
        } else {
            Button {
                window.sendDraft(store: store)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hasText ? theme.onAccent : theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(hasText ? theme.accent : theme.hover))
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
    }
}

/// Round icon button in the composer's bottom row.
struct ComposerIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? theme.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Text chip with an optional icon and a small chevron (mode and model pickers).
struct ComposerChip: View {
    let symbol: String?
    let title: String
    let tint: Color?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11.5))
                }
                Text(title).font(.system(size: 12.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(tint ?? (hovering ? theme.textPrimary : theme.textSecondary))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? theme.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Accepts dropped files. Off in snapshots, where the drop target cannot be drawn.
struct FileDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}
