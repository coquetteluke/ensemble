import SwiftUI
import AppKit
import EnsembleKit

/// Transcript, composer and status line for one session.
struct ConversationView: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    /// A split pane narrower than the composer's narrowest row passes a smaller zoom for the composer, its cards and the
    /// status line, so every control stays on screen; nil uses the window's zoom.
    var composerZoom: CGFloat?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.zoom) private var zoom
    @State private var pinnedToBottom = true
    @State private var position = ScrollPosition(edge: .bottom)
    /// The status line is too narrow for the "Work in a copy" switch; the composer's More menu offers it instead.
    @State private var worktreeSwitchInMore = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findScrollToken = 0
    @FocusState private var findFieldFocused: Bool
    @Environment(\.transcriptActions) private var parentActions

    static let columnWidth: CGFloat = 760
    /// Below this width (before zoom) the transcript, the composer and the status line use tighter side padding.
    static let narrowWidth: CGFloat = 480

    var body: some View {
        let findResult = showFind ? TranscriptFinder.search(findQuery, in: session.items) : .empty
        let findHighlight: TranscriptFindHighlight? = showFind && !findResult.isEmpty
            ? findResult.highlight(at: findIndex, scrollToken: findScrollToken)
            : nil

        VStack(spacing: 0) {
            transcript
                .environment(\.transcriptActions, enrichedTranscriptActions)
                .environment(\.transcriptFindHighlight, findHighlight)
                .environment(\.messageAttachments, session.attachments)
                .overlay(alignment: .topTrailing) {
                    if showFind && !isSnapshot {
                        TranscriptFindBar(
                            query: $findQuery,
                            focused: $findFieldFocused,
                            statusText: findResult.statusText(at: findIndex),
                            hasMatches: !findResult.isEmpty,
                            onPrevious: {
                                findIndex = findResult.previousIndex(before: findIndex)
                                findScrollToken &+= 1
                            },
                            onNext: {
                                findIndex = findResult.nextIndex(after: findIndex)
                                findScrollToken &+= 1
                            },
                            onClose: closeFind
                        )
                        .padding(.top, theme.z(10))
                        .padding(.trailing, theme.z(16))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            ComposerColumn {
                // "Trust this folder?" when the session's engine skips or refuses the folder's own settings.
                SessionTrustCard(store: store, session: session)
                PullRequestBarHost(store: store, session: session)
                AgentBrowserPermissionHost(session: session)
                ComposerView(store: store, session: session, window: window, worktreeSwitchInMore: worktreeSwitchInMore)
                StatusLine(store: store, session: session, window: window,
                           onWorktreeSwitchHidden: { hidden in
                               if worktreeSwitchInMore != hidden { worktreeSwitchInMore = hidden }
                           })
            }
            // Always applied (at the window's zoom when there is no override) so the composer keeps its identity, and
            // its focus, while a split pane is resized.
            .ensembleTheme()
            .environment(\.zoom, composerZoom ?? zoom)
        }
        .environment(\.sessionDirectory, session.directory)
        // Plan cards in the transcript answer through the store (`PlanCardView`).
        .environment(\.interactionStore, store)
        .onChange(of: window.findRequestToken) {
            guard !isSnapshot else { return }
            withAnimation(.easeOut(duration: 0.14)) { showFind = true }
            findFieldFocused = true
        }
        .onChange(of: session.id) {
            closeFind()
        }
        .onChange(of: findQuery) {
            findIndex = 0
            findScrollToken &+= 1
        }
        .onChange(of: findResult.matchCount) { _, count in
            if count == 0 {
                findIndex = 0
            } else if findIndex >= count {
                findIndex = count - 1
            }
        }
        .background(FindEscapeMonitor(isActive: showFind, shouldHandle: { showFind }, onEscape: closeFind))
    }

    private func closeFind() {
        withAnimation(.easeOut(duration: 0.12)) { showFind = false }
        findQuery = ""
        findIndex = 0
        findFieldFocused = false
    }

    private var activeRooms: RoomsController? {
        RoomsController.live ?? AgentToolsCenter.shared.rooms
    }

    private var retryLastMessage: (() -> Void)? {
        guard !session.isWorking else { return nil }
        guard let text = session.items.reversed().compactMap({ item -> String? in
            guard case .user(_, let text, _) = item else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }).first else { return nil }
        return {
            Task { await store.send(text, to: session.id) }
        }
    }

    private var enrichedTranscriptActions: TranscriptActions {
        var updated = parentActions
        let session = self.session
        let window = self.window
        let openParent = parentActions.openSession
        let rooms = activeRooms
        updated.currentSessionID = session.id
        updated.agentExchanges = AgentToolsCenter.shared.coordinator?.exchanges(for: session.id) ?? []
        updated.secondOpinions = AgentToolsCenter.shared.secondOpinions.opinions(for: session.id)
        updated.secondOpinionModels = SecondOpinionModels.options(from: store.models, current: session.info.model)
        updated.canShowSecondOpinion = !isSnapshot
        updated.openSession = { targetID in
            if let roomID = UUID(uuidString: targetID),
               let rooms,
               rooms.state(roomID) != nil {
                window.openRoom(roomID, rooms: rooms)
            } else {
                openParent(targetID)
            }
        }
        updated.requestSecondOpinion = { itemID, replyText, model in
            AgentToolsCenter.shared.requestSecondOpinion(in: session, itemID: itemID, replyText: replyText, model: model)
        }
        updated.retrySecondOpinion = { opinion in
            AgentToolsCenter.shared.retrySecondOpinion(opinion, in: session)
        }
        updated.dismissSecondOpinion = { opinion in
            AgentToolsCenter.shared.dismissSecondOpinion(opinion)
        }
        updated.dismissAgentExchange = { exchange in
            AgentToolsCenter.shared.coordinator?.dismissExchange(exchange.id, for: session.id)
        }
        return updated
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.z(16)) {
            if session.isSubagent, let parentID = session.info.parentID {
                SubagentBanner(store: store, parentID: parentID, window: window)
            }
            TranscriptList(
                items: session.items,
                resolutions: session.resolutions,
                agents: store.agents,
                onRetry: retryLastMessage,
                onContinueWithModel: { ref in
                    Task { _ = await store.changeModel(ref, for: session.id) }
                }
            )
            ProposalCardsHost(session: session)
            if let todos = TodoParser.latest(in: session.items), !todos.isEmpty,
               session.isWorking || todos.contains(where: { $0.status == .pending || $0.status == .inProgress }) {
                // Background work under this session's top-level session; a subagent does not count itself.
                TaskListCard(items: todos, runningTasks: store.backgroundWork(forSession: session.id)
                    .filter { $0.openSessionID != session.id || $0.kind != .subagent }.count)
            }
            if session.isWorking {
                WorkingRow(items: session.items, since: session.workingSince,
                           waitingForPermission: session.activity == .waitingForPermission)
            }
        }
        .frame(maxWidth: theme.z(Self.columnWidth), alignment: .leading)
        .padding(.top, theme.z(12))
        .padding(.bottom, theme.z(22))
        .modifier(AdaptiveInsetModifier(wide: 32, narrow: 16))
    }

    @ViewBuilder private var transcript: some View {
        if isSnapshot {
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
                .clipped()
        } else {
            ScrollView {
                content
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atBottom in
                pinnedToBottom = atBottom
            }
            .onChange(of: session.revision) {
                if pinnedToBottom { position.scrollTo(edge: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(theme.font(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: theme.z(30), height: theme.z(30))
                            .background(Circle().fill(theme.elevated))
                            .overlay(Circle().strokeBorder(theme.border))
                            .shadow(color: .black.opacity(0.25), radius: theme.z(6), y: theme.z(2))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the newest message")
                    .padding(.bottom, theme.z(10))
                }
            }
            .clipped()
            .id(session.id)
        }
    }
}

/// The composer's column under the transcript, sized with its own theme (the composer's zoom).
private struct ComposerColumn<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) { content }
            .modifier(AdaptiveInsetModifier(wide: 20, narrow: 10, maxContentWidth: ConversationView.columnWidth + 24))
    }
}

/// `AdaptiveInset` at the theme's zoom: the narrow padding below `threshold` (before zoom).
struct AdaptiveInsetModifier: ViewModifier {
    let wide: CGFloat
    let narrow: CGFloat
    var threshold: CGFloat = ConversationView.narrowWidth
    var maxContentWidth: CGFloat = .infinity
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        AdaptiveInset(wide: theme.z(wide), narrow: theme.z(narrow), below: theme.z(threshold),
                      maxContentWidth: theme.z(maxContentWidth)) {
            content
        }
    }
}

/// Top of a subagent transcript: which session started it.
struct SubagentBanner: View {
    let store: SessionStore
    let parentID: String
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "person.2.fill")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.accent)
            Text("Subagent of")
                .foregroundStyle(theme.textSecondary)
            Button(store.session(parentID)?.title ?? "parent session") {
                window.open(parentID, store: store)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textPrimary)
            .underline()
            Spacer(minLength: 0)
        }
        .font(theme.font(size: 12.5))
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(8))
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.accent.opacity(0.08)))
    }
}

/// Floating live Find bar anchored to the top trailing corner of a session transcript.
private struct TranscriptFindBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let statusText: String
    let hasMatches: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            TextField("", text: $query, prompt: Text("Find in transcript").foregroundStyle(theme.textTertiary))
                .textFieldStyle(.plain)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .focused(focused)
                .frame(minWidth: theme.z(110), idealWidth: theme.z(170), maxWidth: theme.z(210))
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) {
                        onPrevious()
                    } else {
                        onNext()
                    }
                }
                .onExitCommand(perform: onClose)
                .onAppear { focused.wrappedValue = true }
            if !statusText.isEmpty {
                Text(statusText)
                    .font(theme.font(size: 11.5).monospacedDigit())
                    .foregroundStyle(hasMatches ? theme.textSecondary : theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1, height: theme.z(14))
            HStack(spacing: theme.z(2)) {
                FindBarButton(symbol: "chevron.up", help: "Previous match (Shift-Return)", disabled: !hasMatches, action: onPrevious)
                FindBarButton(symbol: "chevron.down", help: "Next match (Return)", disabled: !hasMatches, action: onNext)
                FindBarButton(symbol: "xmark", help: "Close find (Esc)", disabled: false, action: onClose)
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(34))
        .background(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .fill(theme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.32 : 0.12), radius: theme.z(10), y: theme.z(3))
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}

private struct FindBarButton: View {
    let symbol: String
    let help: String
    let disabled: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size: 10.5, weight: .semibold))
                .foregroundStyle(disabled ? theme.textTertiary.opacity(0.45) : (hovering ? theme.textPrimary : theme.textSecondary))
                .frame(width: theme.z(22), height: theme.z(22))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                        .fill(!disabled && hovering ? theme.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Intercepts bare Escape while the live Find bar is open so closing Find never triggers `Session > Stop`.
private struct FindEscapeMonitor: View {
    let isActive: Bool
    let shouldHandle: () -> Bool
    let onEscape: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .onAppear { sync() }
            .onChange(of: isActive) { sync() }
            .onDisappear { remove() }
    }

    private func sync() {
        if isActive && !isSnapshot {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard shouldHandle(), event.keyCode == 53 else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        onEscape()
        return true
    }
}
