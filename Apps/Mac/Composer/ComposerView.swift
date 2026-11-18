import SwiftUI
import AppKit
import EnsembleKit

/// Message box: text, attachments, attach button, permission-mode menu, model chip, send or stop.
struct ComposerView: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    /// Snapshots set the text directly.
    var snapshotDraft: String?

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var textHeight: CGFloat = 22
    @State private var showModeMenu = false
    @State private var showModelMenu = false
    @State private var showEffortMenu = false
    @State private var dropTargeted = false
    @State private var slashSelection = 0
    /// The draft the slash menu was closed for with Esc (it stays closed until the text changes).
    @State private var slashDismissedFor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if !attachments.isEmpty {
                attachmentChips
            }
            textArea
            HStack(spacing: theme.z(4)) {
                attachButton
                modeChip
                PowerMenuButton(holder: .session(session.id))
                Spacer(minLength: theme.z(8))
                modelChip
                effortChip
                fastToggle
                sendButton
                    .padding(.leading, theme.z(4))
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.top, theme.z(12))
        .padding(.bottom, theme.z(10))
        .background(
            RoundedRectangle(cornerRadius: theme.z(16), style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(16), style: .continuous)
                .strokeBorder(dropTargeted ? theme.accent : theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: theme.z(10), y: theme.z(3))
        .modifier(FileDrop(enabled: !isSnapshot, targeted: $dropTargeted) { urls in
            window.attachments[session.id, default: []].append(contentsOf: urls.filter(\.isFileURL))
        })
        .overlay(alignment: .top) {
            if !slashMatches.isEmpty {
                SlashCommandMenu(commands: slashMatches, selection: min(slashSelection, slashMatches.count - 1),
                                 onHover: { slashSelection = $0 }, onPick: pick)
                    .alignmentGuide(.top) { $0[.bottom] + theme.z(8) }
            }
        }
        .task(id: session.info.model?.description) { await store.loadModelOptions(for: session.info.model) }
        .task(id: session.directory) { await store.loadCommands(directory: session.directory) }
        .onChange(of: window.requestedMenu) {
            guard let menu = window.requestedMenu else { return }
            window.requestedMenu = nil
            switch menu {
            case .model: showModelMenu = true
            case .mode: showModeMenu = true
            case .effort: showEffortMenu = true
            }
        }
        .onChange(of: draft.wrappedValue) { slashSelection = 0 }
    }

    // MARK: Slash menu

    private var currentText: String { snapshotDraft ?? draft.wrappedValue }

    private var slashMatches: [SlashCommand] {
        let text = currentText
        guard text != slashDismissedFor, let query = SlashCommands.query(in: text) else { return [] }
        return SlashCommands.matches(query, in: store.slashCommands(directory: session.directory))
    }

    private func handleKey(_ key: ComposerKey) -> Bool {
        let matches = slashMatches
        guard !matches.isEmpty else { return false }
        switch key {
        case .up: slashSelection = max(0, min(slashSelection, matches.count - 1) - 1)
        case .down: slashSelection = min(matches.count - 1, slashSelection + 1)
        case .tab: draft.wrappedValue = "/\(matches[min(slashSelection, matches.count - 1)].name) "
        case .submit: pick(matches[min(slashSelection, matches.count - 1)])
        case .escape: slashDismissedFor = draft.wrappedValue
        }
        return true
    }

    /// Return on a command: run it now, or complete it when it takes arguments.
    private func pick(_ command: SlashCommand) {
        if command.source != .ensemble, command.argumentHint != nil {
            draft.wrappedValue = "/\(command.name) "
            return
        }
        draft.wrappedValue = ""
        window.runSlashCommand(command.name, arguments: "", store: store, session: session)
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
                    .font(theme.font(size: 14))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, theme.z(2))
                    .allowsHitTesting(false)
            }
            if isSnapshot {
                Text(text)
                    .font(theme.font(size: 14))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.top, theme.z(2))
                    .frame(maxWidth: .infinity, minHeight: theme.z(22), alignment: .topLeading)
            } else {
                ComposerTextView(
                    text: draft,
                    height: $textHeight,
                    focusToken: window.composerFocusToken,
                    fontSize: theme.z(14),
                    textColor: NSColor(theme.textPrimary),
                    accentColor: NSColor(theme.accent),
                    onSubmit: { window.sendDraft(store: store) },
                    onCycleMode: { Task { await store.setPermissionMode(session.permissionMode.next, for: session.id) } },
                    onKey: handleKey
                )
                .frame(height: min(max(textHeight, theme.z(22)), theme.z(220)))
            }
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.z(6)) {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: theme.z(6)) {
                        Image(systemName: "doc")
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.textTertiary)
                        Text(url.lastPathComponent)
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Button {
                            window.attachments[session.id]?.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark")
                                .font(theme.font(size: 9, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(url.lastPathComponent)")
                    }
                    .padding(.horizontal, theme.z(8))
                    .frame(height: theme.z(26))
                    .background(RoundedRectangle(cornerRadius: theme.z(7)).fill(theme.hover))
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
        .fixedSize()
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

    /// Effort for this model, when the engine offers it.
    @ViewBuilder private var effortChip: some View {
        if let options = store.options(for: session.info.model), !options.effortLevels.isEmpty {
            let current = session.effort ?? options.defaultEffort
            ComposerChip(symbol: "gauge.with.dots.needle.50percent", title: current?.label ?? "Effort", tint: nil) {
                showEffortMenu.toggle()
            }
            .fixedSize()
            .help("How hard the model thinks")
            .popover(isPresented: $showEffortMenu, arrowEdge: .bottom) {
                EffortMenuContent(levels: options.effortLevels, current: current) { level in
                    showEffortMenu = false
                    Task { await store.setEffort(level, for: session.id) }
                }
                .ensembleTheme()
            }
        }
    }

    /// Fast mode, when the model has one.
    @ViewBuilder private var fastToggle: some View {
        if store.options(for: session.info.model)?.supportsFastMode == true {
            let on = session.fastMode
            Button {
                Task { await store.setFastMode(!on, for: session.id) }
            } label: {
                Image(systemName: on ? "bolt.fill" : "bolt")
                    .font(theme.font(size: 13))
                    .foregroundStyle(on ? theme.accent : theme.textSecondary)
                    .frame(width: theme.z(30), height: theme.z(28))
                    .background(
                        RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                            .fill(on ? theme.accent.opacity(0.14) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(on ? "Fast mode is on" : "Fast mode is off")
            .accessibilityLabel("Fast mode")
            .accessibilityValue(on ? "On" : "Off")
        }
    }

    @ViewBuilder private var sendButton: some View {
        let hasText = !(snapshotDraft ?? draft.wrappedValue).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        if session.isWorking && !hasText {
            Button {
                Task { await store.stop() }
            } label: {
                RoundedRectangle(cornerRadius: theme.z(2.5))
                    .fill(theme.background)
                    .frame(width: theme.z(10), height: theme.z(10))
                    .frame(width: theme.z(30), height: theme.z(30))
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
                    .font(theme.font(size: 13, weight: .bold))
                    .foregroundStyle(hasText ? theme.onAccent : theme.textTertiary)
                    .frame(width: theme.z(30), height: theme.z(30))
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
                .font(theme.font(size: 13.5))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(30), height: theme.z(30))
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
            HStack(spacing: theme.z(5)) {
                if let symbol {
                    Image(systemName: symbol).font(theme.font(size: 11.5))
                }
                Text(title).font(theme.font(size: 12.5))
                Image(systemName: "chevron.down")
                    .font(theme.font(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(tint ?? (hovering ? theme.textPrimary : theme.textSecondary))
            .padding(.horizontal, theme.z(9))
            .frame(height: theme.z(28))
            .background(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
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
