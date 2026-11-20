import SwiftUI
import AppKit
import EnsembleKit

/// Message box: text, attachments, attach button, permission-mode menu, model chip, dictation, send or stop.
/// Above it: the agent's open question (`QuestionCardView`), messages queued while the agent works, and the side
/// question panel (`/btw`, Command-semicolon).
struct ComposerView: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    /// Snapshots set the text directly.
    var snapshotDraft: String?
    /// Snapshots draw the side question panel with this question and answer.
    var snapshotSideQuestion: (question: SideQuestion, answer: String)?
    /// Snapshots draw the microphone in this state.
    var snapshotDictation: DictationController?
    /// The status line has no room for its "Work in a copy" switch, so the More menu offers it (`StatusLine`).
    var worktreeSwitchInMore = false
    /// Snapshots draw the "start a new session with this model" bar.
    var snapshotModelOffer: ModelChangeOffer?

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(PowerController.self) private var power: PowerController?
    @State private var textHeight: CGFloat = 22
    @State private var showModeMenu = false
    @State private var showModelMenu = false
    @State private var showEffortMenu = false
    @State private var dropTargeted = false
    @State private var slashSelection = 0
    /// The draft the slash menu was closed for with Esc (it stays closed until the text changes).
    @State private var slashDismissedFor: String?
    @State private var liveDictation = DictationController()
    /// Who pays for each model (from the engine), for the model menu's groups.
    @State private var modelBilling: [String: ModelBilling]?

    private var dictation: DictationController { snapshotDictation ?? liveDictation }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            if let question = store.openQuestion(in: session.id) {
                QuestionCardView(
                    request: question,
                    onAnswer: { answers in Task { await store.answerQuestion(question, answers: answers) } },
                    onDecline: { Task { await store.declineQuestion(question) } })
                    .id(question.id)
                    .padding(.bottom, theme.z(4))
            }
            if !queue.isEmpty {
                ComposerQueueStrip(
                    messages: queue, held: store.isQueueHeld(session.id), delivery: store.queuedDelivery(for: session.id),
                    sendNow: store.sendNowBehavior(for: session.id),
                    onSendNow: { message in Task { await store.sendNow(message.id, in: session.id) } },
                    onEdit: edit, onCancel: { store.cancelQueued($0.id, in: session.id) })
            }
            if let offer = snapshotModelOffer ?? ModelChangeOffers.shared.bySession[session.id] {
                ModelChangeOfferBar(
                    offer: offer,
                    onStart: { Task { await ModelSwitcher.accept(offer, store: store, window: window) } },
                    onCancel: { ModelSwitcher.decline(offer) })
            } else if let staged = store.stagedModel(for: session.id) {
                StagedModelBanner(
                    stagedName: store.modelName(staged),
                    currentName: store.modelName(session.info.model)
                ) {
                    store.clearStagedModel(for: session.id)
                }
            }
            composerBox
        }
        .overlay(alignment: .top) {
            // A zero-height anchor on the top edge; the menu or the side question panel grows upwards from it.
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    if !slashMatches.isEmpty {
                        SlashCommandMenu(commands: slashMatches, selection: min(slashSelection, slashMatches.count - 1),
                                         onHover: { slashSelection = $0 }, onPick: pick)
                            .padding(.bottom, theme.z(8))
                    } else if let panel = sideQuestionPanel {
                        panel.padding(.bottom, theme.z(8))
                    }
                }
        }
        .background { sideQuestionShortcut }
        .task(id: session.info.model?.description) { await store.loadModelOptions(for: session.info.model) }
        .task(id: session.directory) { await store.loadCommands(directory: session.directory) }
        .task(id: session.id) { await store.loadPlanModeSupport(for: session.id) }
        .task(id: store.models.count) {
            guard !isSnapshot, let billing = store.engine as? any EngineModelBilling else { return }
            modelBilling = try? await billing.modelBilling()
        }
        .onChange(of: window.requestedMenu) {
            guard let menu = window.requestedMenu else { return }
            window.requestedMenu = nil
            switch menu {
            case .model: showModelMenu = true
            case .mode: showModeMenu = true
            case .effort: showEffortMenu = true
            }
        }
        // The rewind sheet for this session (opened from a message's Rewind or `/rewind`).
        .modifier(RewindSheetPresenter(store: store, sessionID: session.id))
        .onChange(of: draft.wrappedValue) { slashSelection = 0 }
        .onChange(of: session.id) { liveDictation.cancel() }
        .onDisappear { liveDictation.cancel() }
    }

    private var composerBox: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            if let problem = dictation.problem {
                DictationProblemRow(problem: problem) { dictation.dismissProblem() }
            }
            if !attachments.isEmpty {
                attachmentChips
            }
            textArea
            controls
        }
        .modifier(AdaptiveInsetModifier(wide: 14, narrow: 10, threshold: 440))
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
    }

    // MARK: Queue

    private var queue: [QueuedMessage] { store.queue(for: session.id) }

    /// Takes a queued message out of the queue and back into the box (after anything already typed).
    private func edit(_ message: QueuedMessage) {
        guard let message = store.takeQueued(message.id, in: session.id) else { return }
        let current = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.wrappedValue = current.isEmpty ? message.text : current + "\n\n" + message.text
        if !message.files.isEmpty { window.attachments[session.id, default: []].append(contentsOf: message.files) }
        window.composerFocusToken &+= 1
    }

    // MARK: Side questions

    private var sideQuestionPanel: SideQuestionPanel? {
        if let snapshot = snapshotSideQuestion {
            return SideQuestionPanel(question: snapshot.question, answer: snapshot.answer, streaming: false,
                                     onAsk: { _ in }, onContinue: {}, onClose: {})
        }
        guard let question = store.sideQuestions[session.id] else { return nil }
        let answer = store.sideQuestionAnswer(question)
        return SideQuestionPanel(
                question: question, answer: answer.text, streaming: answer.streaming,
                onAsk: { text in Task { await store.askSideQuestion(text, about: session.id) } },
                onContinue: {
                    Task {
                        if let kept = await store.continueSideQuestion(for: session.id) { window.open(kept.id, store: store) }
                    }
                },
                onClose: {
                    Task { await store.closeSideQuestion(for: session.id) }
                    window.composerFocusToken &+= 1
                })
    }

    /// Command-semicolon opens the side question panel, or closes the open one.
    private var sideQuestionShortcut: some View {
        Button("Side question") { toggleSideQuestion() }
            .keyboardShortcut(";", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func toggleSideQuestion() {
        if store.sideQuestions[session.id] != nil {
            Task { await store.closeSideQuestion(for: session.id) }
            window.composerFocusToken &+= 1
        } else {
            askSideQuestion("")
        }
    }

    /// `/btw <question>`: asks at once; without a question, opens the panel to type one.
    private func askSideQuestion(_ question: String) {
        if let reason = store.sideQuestionUnavailableReason(session.id) {
            store.addNotice(reason, to: session.id)
            return
        }
        if question.isEmpty {
            store.openSideQuestion(for: session.id)
        } else {
            Task { await store.askSideQuestion(question, about: session.id) }
        }
    }

    /// Return or the send button: `/btw` is handled here, everything else by the window (commands, queue, send).
    private func submit() {
        liveDictation.cancel()
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, let command = SlashCommands.parse(text), command.name.lowercased() == "btw" {
            draft.wrappedValue = ""
            askSideQuestion(command.arguments)
            return
        }
        window.sendDraft(store: store)
    }

    // MARK: Slash menu

    private var currentText: String { snapshotDraft ?? draft.wrappedValue }

    private var slashMatches: [SlashCommand] {
        let text = currentText
        guard text != slashDismissedFor, let query = SlashCommands.query(in: text) else { return [] }
        let reason = store.sideQuestionUnavailableReason(session.id)
        return SlashCommands.matches(query, in: store.slashCommands(directory: session.directory)).map { command in
            guard command.source == .ensemble, command.name == "btw" else { return command }
            var copy = command
            copy.disabledReason = reason
            return copy
        }
    }

    private func handleKey(_ key: ComposerKey) -> Bool {
        let matches = slashMatches
        if matches.isEmpty, key == .escape, store.sideQuestions[session.id] != nil {
            Task { await store.closeSideQuestion(for: session.id) }
            return true
        }
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
        if command.source == .ensemble, command.name == "btw" {
            if let reason = command.disabledReason {
                draft.wrappedValue = ""
                store.addNotice(reason, to: session.id)
            } else {
                draft.wrappedValue = "/btw "
            }
            return
        }
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

    private var placeholder: String { session.isWorking ? "Queue a message for when the agent finishes" : "Send a message" }

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
                    onSubmit: submit,
                    onCycleMode: { Task { await store.setPermissionMode(store.nextPermissionMode(for: session.id), for: session.id) } },
                    onKey: handleKey,
                    dictation: liveDictation
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

    /// The bottom row at the widest level that fits (`ComposerRowLevel`). Only the level shown is in the window, so
    /// each menu's popover opens from the one control that is on screen.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            // While the More menu holds the "Work in a copy" switch, the row keeps the menu on screen.
            if !switchInMore {
                row(.full)
                row(.iconChips)
            }
            row(.more)
            row(.compact)
            row(.truncated)
            row(.twoLines)
        }
    }

    @ViewBuilder private func row(_ level: ComposerRowLevel) -> some View {
        if level == .twoLines {
            VStack(alignment: .leading, spacing: theme.z(4)) {
                HStack(spacing: theme.z(4)) {
                    modeChip(iconOnly: true)
                    modelChip(maxTitleWidth: nil)
                    Spacer(minLength: 0)
                    moreMenu(level)
                }
                HStack(spacing: theme.z(4)) {
                    attachButton
                    PowerMenuButton(holder: .session(session.id))
                    Spacer(minLength: theme.z(8))
                    DictationButton(dictation: dictation)
                    sendButton
                        .padding(.leading, theme.z(4))
                }
            }
        } else {
            HStack(spacing: theme.z(4)) {
                if !level.attachInMore { attachButton }
                modeChip(iconOnly: level != .full)
                if !level.attachInMore { PowerMenuButton(holder: .session(session.id)) }
                Spacer(minLength: theme.z(8))
                modelChip(maxTitleWidth: level == .truncated ? theme.z(ComposerRowLevel.truncatedModelWidth) : nil)
                if !level.effortInMore {
                    effortChip(iconOnly: level != .full)
                    fastToggle
                }
                moreMenu(level)
                DictationButton(dictation: dictation)
                sendButton
                    .padding(.leading, theme.z(4))
            }
        }
    }

    private var effortOptions: ModelOptions? {
        guard let options = store.options(for: session.info.model), !options.effortLevels.isEmpty else { return nil }
        return options
    }

    private var hasFastMode: Bool { store.options(for: session.info.model)?.supportsFastMode == true }

    /// The status line hid its "Work in a copy" switch and the switch applies to this session.
    private var switchInMore: Bool {
        worktreeSwitchInMore && WorktreeStatusControls.showsSwitch(store: store, session: session)
    }

    private func moreItems(_ level: ComposerRowLevel) -> ComposerMoreItems {
        ComposerMoreItems(effort: level.effortInMore && effortOptions != nil,
                          fast: level.effortInMore && hasFastMode,
                          workInCopy: switchInMore,
                          attach: level.attachInMore,
                          keepAwake: level.attachInMore && power != nil)
    }

    /// The More menu with what this level moved out of the row; nothing when it moved nothing. Effort's own menu
    /// (`/effort`, the command palette) opens from here while effort is inside.
    @ViewBuilder private func moreMenu(_ level: ComposerRowLevel) -> some View {
        let items = moreItems(level)
        if !items.isEmpty {
            ComposerMoreMenu(store: store, session: session, window: window, items: items, options: effortOptions,
                             onAttach: attachFiles)
                .popover(isPresented: items.effort ? $showEffortMenu : .constant(false), arrowEdge: .bottom) {
                    effortMenu
                }
        }
    }

    private var attachButton: some View {
        ComposerIconButton(symbol: "paperclip", help: "Attach files", action: attachFiles)
    }

    private func attachFiles() {
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

    private func modeChip(iconOnly: Bool) -> some View {
        let mode = session.permissionMode
        return ComposerChip(symbol: mode.symbolName, title: mode.label,
                            tint: mode.isDangerous ? theme.danger : nil, iconOnly: iconOnly) {
            showModeMenu.toggle()
        }
        .fixedSize()
        .help(iconOnly ? "Permission mode: \(mode.label) (Shift-Tab to switch)" : "Permission mode (Shift-Tab to switch)")
        .accessibilityLabel("Permission mode")
        .accessibilityValue(mode.label)
        .popover(isPresented: $showModeMenu, arrowEdge: .bottom) {
            ModeMenuContent(current: mode, planSupport: store.planModeSupport(for: session.id)) { newMode in
                showModeMenu = false
                Task { await store.setPermissionMode(newMode, for: session.id) }
            }
            .ensembleTheme()
        }
    }

    /// The model's name (staged next-message model when present, otherwise active); the row counts it as at most
    /// `maxTitleWidth` wide when given, and cuts it to the room left.
    private func modelChip(maxTitleWidth: CGFloat?) -> some View {
        let effective = store.effectiveModel(for: session)
        let staged = store.stagedModel(for: session.id)
        let name = store.modelName(effective)
        let helpText = staged != nil
            ? "Next message: \(name) (current: \(store.modelName(session.info.model)))"
            : "Model: \(name)"
        return ComposerChip(symbol: nil, title: name, tint: staged != nil ? theme.accent : nil,
                            badge: staged != nil ? "Next" : nil, maxTitleWidth: maxTitleWidth) {
            showModelMenu.toggle()
        }
        .help(helpText)
        .accessibilityLabel("Model")
        .accessibilityValue(staged != nil ? "\(name), next message" : name)
        .contextMenu {
            if staged != nil {
                Button("Keep \(store.modelName(session.info.model))") {
                    store.clearStagedModel(for: session.id)
                }
            }
        }
        .popover(isPresented: $showModelMenu, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ModelPickerView(models: store.models, billing: modelBilling, current: effective,
                                context: .init(store: store, session: session)) { ref in
                    showModelMenu = false
                    Task { await ModelSwitcher.pick(ref, session: session, store: store, window: window) }
                }
                if staged != nil {
                    HLine(color: theme.border)
                    Button {
                        store.clearStagedModel(for: session.id)
                        showModelMenu = false
                    } label: {
                        HStack(spacing: theme.z(6)) {
                            Image(systemName: "xmark")
                                .font(theme.font(size: 10.5, weight: .semibold))
                            Text("Keep \(store.modelName(session.info.model))")
                                .font(theme.font(size: 12.5))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, theme.z(14))
                        .frame(height: theme.z(32))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .padding(theme.z(4))
                    .background(theme.popover)
                }
            }
            .ensembleTheme()
        }
        // Offered the row's room before the spacer, so the name is only cut when the row is short of room. Last, so
        // the row sees it.
        .layoutPriority(1)
    }

    /// Effort for this model, when the engine offers it.
    @ViewBuilder private func effortChip(iconOnly: Bool) -> some View {
        if let options = effortOptions {
            let current = session.effort ?? options.defaultEffort
            ComposerChip(symbol: "gauge.with.dots.needle.50percent", title: current?.label ?? "Effort", tint: nil, iconOnly: iconOnly) {
                showEffortMenu.toggle()
            }
            .fixedSize()
            .help(iconOnly ? "Effort: \(current?.label ?? "default"). How hard the model thinks" : "How hard the model thinks")
            .accessibilityLabel("Effort")
            .accessibilityValue(current?.label ?? "Default")
            .popover(isPresented: $showEffortMenu, arrowEdge: .bottom) {
                effortMenu
            }
        }
    }

    @ViewBuilder private var effortMenu: some View {
        if let options = effortOptions {
            EffortMenuContent(levels: options.effortLevels, current: session.effort ?? options.defaultEffort) { level in
                showEffortMenu = false
                Task { await store.setEffort(level, for: session.id) }
            }
            .ensembleTheme()
        }
    }

    /// Fast mode, when the model has one.
    @ViewBuilder private var fastToggle: some View {
        if hasFastMode {
            let on = session.fastMode
            FastModeToggle(isOn: on) {
                Task { await store.setFastMode(!on, for: session.id) }
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        let hasText = !(snapshotDraft ?? draft.wrappedValue).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        if session.isWorking && !hasText {
            Button {
                Task { await store.stop(session.id) }
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
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(theme.font(size: 13, weight: .bold))
                    .foregroundStyle(hasText ? theme.onAccent : theme.textTertiary)
                    .frame(width: theme.z(30), height: theme.z(30))
                    .background(Circle().fill(hasText ? theme.accent : theme.raisedFill))
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .help(session.isWorking ? "Queue (Return): sent when the agent finishes" : "Send (Return)")
            .accessibilityLabel(session.isWorking ? "Queue" : "Send")
        }
    }
}

/// Slim dismissible bar above the composer when a model switch is staged for the next message.
private struct StagedModelBanner: View {
    let stagedName: String
    let currentName: String
    let onClear: () -> Void
    @Environment(\.theme) private var theme
    @State private var clearHovering = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "arrow.right.circle.fill")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.accent)
            Text("Next message: \(stagedName)")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: theme.z(8))
            Button(action: onClear) {
                HStack(spacing: theme.z(4)) {
                    Text(currentName.isEmpty ? "Cancel" : "Keep \(currentName)")
                        .lineLimit(1)
                    Image(systemName: "xmark")
                        .font(theme.font(size: 9, weight: .semibold))
                }
                .font(theme.font(size: 11.5))
                .foregroundStyle(clearHovering ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, theme.z(7))
                .frame(height: theme.z(22))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(clearHovering ? theme.hover : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { clearHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: clearHovering)
            .help(currentName.isEmpty ? "Cancel staged model switch" : "Keep \(currentName)")
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(5))
        .background(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next message: \(stagedName)")
    }
}

/// Fast mode button in the composer's bottom row, matching `ComposerIconButton` and `ComposerChip` hover states.
private struct FastModeToggle: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "bolt.fill" : "bolt")
                .font(theme.font(size: 13))
                .foregroundStyle(isOn ? theme.accent : (hovering ? theme.textPrimary : theme.textSecondary))
                .frame(width: theme.z(30), height: theme.z(28))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                        .fill(isOn ? theme.accent.opacity(hovering ? 0.20 : 0.14) : (hovering ? theme.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(isOn ? "Fast mode is on" : "Fast mode is off")
        .accessibilityLabel("Fast mode")
        .accessibilityValue(isOn ? "On" : "Off")
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

/// How much of the composer's bottom row fits, widest first; the row shows the first level that fits its width.
enum ComposerRowLevel: Int, Comparable {
    /// Every control with its label.
    case full
    /// Permission mode and effort show their icons only (the name is in the tooltip and the accessibility value).
    case iconChips
    /// Effort and fast mode move into the More menu.
    case more
    /// Attach and Keep awake move into the More menu too.
    case compact
    /// The model's name is counted as `truncatedModelWidth` wide, and cut to the room the row leaves it.
    case truncated
    /// Two lines: permission mode, model and More above; attach, Keep awake, dictation and send below.
    case twoLines

    /// The model name's width at `.truncated`, before zoom.
    static let truncatedModelWidth: CGFloat = 58

    static func < (lhs: ComposerRowLevel, rhs: ComposerRowLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var effortInMore: Bool { self >= .more }
    var attachInMore: Bool { self == .compact || self == .truncated }
}

/// Text chip with an optional icon and a small chevron (mode and model pickers). Icon-only drops the text (callers give
/// the full text in the tooltip and the accessibility value).
struct ComposerChip: View {
    let symbol: String?
    let title: String
    let tint: Color?
    var badge: String? = nil
    var iconOnly = false
    /// The row counts the title as at most this wide; it is cut to the room the row gives it.
    var maxTitleWidth: CGFloat?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.z(5)) {
                if let symbol {
                    Image(systemName: symbol).font(theme.font(size: 11.5))
                }
                if !iconOnly || symbol == nil {
                    CappedWidth(maxWidth: maxTitleWidth ?? .infinity) {
                        Text(title)
                            .font(theme.font(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let badge {
                        Text(badge)
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, theme.z(5))
                            .frame(height: theme.z(16))
                            .background(Capsule().fill(theme.accent.opacity(0.14)))
                            .fixedSize()
                    }
                }
                Image(systemName: "chevron.down")
                    .font(theme.font(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(tint ?? (hovering ? theme.textPrimary : theme.textSecondary))
            .padding(.horizontal, theme.z(iconOnly && symbol != nil ? 7 : 9))
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

/// Counts its content as at most `maxWidth` wide when the row measures its ideal width (so the row picks the level with
/// the cut name), but takes more of the name when the row has room for it.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: proposal.width ?? maxWidth, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
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
