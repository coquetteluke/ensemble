import SwiftUI
import EnsembleKit

/// Transcript, composer and status line for one session.
struct ConversationView: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var pinnedToBottom = true
    @State private var position = ScrollPosition(edge: .bottom)

    static let columnWidth: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            transcript
            VStack(spacing: 0) {
                ComposerView(store: store, session: session, window: window)
                StatusLine(store: store, session: session, window: window)
            }
            .frame(maxWidth: theme.z(Self.columnWidth + 24))
            .padding(.horizontal, theme.z(20))
        }
        .environment(\.sessionDirectory, session.directory)
        // Plan cards in the transcript answer through the store (`PlanCardView`).
        .environment(\.interactionStore, store)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.z(16)) {
            if session.isSubagent, let parentID = session.info.parentID {
                SubagentBanner(store: store, parentID: parentID, window: window)
            }
            TranscriptList(items: session.items, resolutions: session.resolutions, agents: store.agents)
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
        .padding(.horizontal, theme.z(32))
        .padding(.top, theme.z(12))
        .padding(.bottom, theme.z(22))
        .frame(maxWidth: .infinity)
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
