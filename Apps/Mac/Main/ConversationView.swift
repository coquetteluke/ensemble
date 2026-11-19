import SwiftUI
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
    @Environment(\.transcriptActions) private var parentActions

    static let columnWidth: CGFloat = 760
    /// Below this width (before zoom) the transcript, the composer and the status line use tighter side padding.
    static let narrowWidth: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .environment(\.transcriptActions, enrichedTranscriptActions)
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
    }

    private var activeRooms: RoomsController? {
        RoomsController.live ?? AgentToolsCenter.shared.rooms
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
            TranscriptList(items: session.items, resolutions: session.resolutions, agents: store.agents)
            ProposalCardsHost(session: session)
            if let todos = TodoParser.latest(in: session.items), !todos.isEmpty,
               session.isWorking || todos.contains(where: { $0.status == .pending || $0.status == .inProgress }) {
                TaskListCard(items: todos)
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
