import SwiftUI
import EnsembleKit

/// The review pane: every file the session (or room) changed with its diff, comments on lines that go to the
/// agent as one message, and stage, discard and commit. Shown in the window's side pane.
struct ReviewPane: View {
    @Bindable var model: ReviewModel
    /// Space above the header (the window's title bar), when the host needs it.
    var topInset: CGFloat = 0
    var onClose: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    /// The review of one session.
    init(store: SessionStore, session: SessionModel, topInset: CGFloat = 0, onClose: (() -> Void)? = nil) {
        self.model = ReviewCenter.shared.model(for: session, store: store)
        self.topInset = topInset
        self.onClose = onClose
    }

    /// The review of a room.
    init(store: SessionStore, room: RoomEngine, topInset: CGFloat = 0, onClose: (() -> Void)? = nil) {
        self.model = ReviewCenter.shared.model(for: room, store: store)
        self.topInset = topInset
        self.onClose = onClose
    }

    init(model: ReviewModel, topInset: CGFloat = 0, onClose: (() -> Void)? = nil) {
        self.model = model
        self.topInset = topInset
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            ReviewHeader(model: model, onClose: onClose)
            HLine()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ReviewFooter(model: model)
        }
        .background(theme.background)
        .task(id: model.target.id) {
            guard !isSnapshot else { return }
            await model.loadIfNeeded()
        }
        // The agent's turn just ended: show what it changed.
        .onChange(of: model.environment.isAgentWorking(nil)) { _, working in
            if !working, !isSnapshot { Task { await model.reload() } }
        }
        .alert(discardTitle, isPresented: discardShown, presenting: model.discardCandidate) { file in
            Button("Discard", role: .destructive) { Task { await model.discard(file) } }
            Button("Cancel", role: .cancel) { model.discardCandidate = nil }
        } message: { file in
            Text(discardMessage(file))
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.loadError, model.result == nil {
            ReviewMessage(symbol: "exclamationmark.triangle", title: "Could not load the changes", detail: error) {
                Button("Try again") { Task { await model.reload() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        } else if model.result == nil {
            VStack(spacing: theme.z(10)) {
                Spinner(size: 14)
                Text("Loading changes")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.files.isEmpty {
            ReviewMessage(symbol: "checkmark.circle", title: "No changes", detail: model.result?.comparison ?? "") { EmptyView() }
        } else {
            ScrollViewReader { proxy in
                AdaptiveScroll(.vertical) {
                    ReviewStack(spacing: 0) {
                        if !model.isGit {
                            notGitNotice
                        }
                        ReviewFileList(model: model) { file in
                            model.collapsed.remove(file.id)
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(file.id, anchor: .top) }
                        }
                        ForEach(model.files) { file in
                            ReviewFileSection(model: model, file: file)
                                .id(file.id)
                        }
                        Color.clear.frame(height: theme.z(12))
                    }
                }
            }
        }
    }

    private var notGitNotice: some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: "info.circle")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
            Text("This folder is not a git repository, so these diffs come from the agent's own record of its edits. Staging and commits need git.")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel)
        .overlay(alignment: .bottom) { HLine() }
    }

    private var discardShown: Binding<Bool> {
        Binding(get: { model.discardCandidate != nil && !isSnapshot }, set: { if !$0 { model.discardCandidate = nil } })
    }

    private var discardTitle: String {
        model.discardCandidate.map { "Discard changes to \($0.fileName)?" } ?? "Discard changes?"
    }

    private func discardMessage(_ file: ReviewFileDiff) -> String {
        switch file.stage {
        case .untracked:
            "\(file.path) is a new file, so it moves to the Trash."
        default:
            file.kind == .added
                ? "\(file.path) is a new file, so it leaves the index and moves to the Trash."
                : "\(file.path) goes back to its last committed version, staged changes included. This cannot be undone."
        }
    }
}

/// Lazy in the app, plain in snapshots (`ImageRenderer` draws only what a lazy stack has loaded).
struct ReviewStack<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

/// Title row: what is shown (scope menu), the totals, refresh and close.
struct ReviewHeader: View {
    @Bindable var model: ReviewModel
    var onClose: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Text("Changes")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            ReviewScopeMenu(model: model)
            Spacer(minLength: theme.z(8))
            if !model.files.isEmpty {
                ReviewCounts(additions: model.totals.additions, deletions: model.totals.deletions, size: 12)
            }
            if model.isLoading && model.result != nil {
                Spinner(size: 11)
            }
            IconButton("arrow.clockwise", help: "Reload the changes", size: 24) {
                Task { await model.reload() }
            }
            if let onClose {
                IconButton("xmark", help: "Close (Option-Command-R)", size: 24, action: onClose)
            }
        }
        .padding(.leading, theme.z(14))
        .padding(.trailing, theme.z(8))
        .frame(height: theme.z(44))
    }
}

/// "Whole session", "Last turn" and, in rooms, each agent.
struct ReviewScopeMenu: View {
    @Bindable var model: ReviewModel
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Button(wholeTitle) { model.scope = .all }
                Button("Last turn") { model.scope = .lastTurn }
                if model.target.isRoom {
                    Divider()
                    ForEach(model.target.agents) { agent in
                        Button(agent.name) { model.scope = .agent(agent.id) }
                    }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.result?.comparison ?? "Choose which changes to show")
        }
    }

    private var wholeTitle: String { model.target.isRoom ? "Whole room" : "Whole session" }

    private var title: String {
        switch model.scope {
        case .all: wholeTitle
        case .lastTurn: "Last turn"
        case .agent(let id): model.target.agent(id)?.name ?? "Agent"
        }
    }

    private var label: some View {
        HStack(spacing: theme.z(5)) {
            if case .agent(let id) = model.scope, let agent = model.target.agent(id) {
                StatusDot(Color(hexString: agent.colorHex), size: 7)
            }
            Text(title)
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textSecondary)
            Image(systemName: "chevron.down")
                .font(theme.font(size: 8.5, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, theme.z(8))
        .frame(height: theme.z(24))
        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).strokeBorder(theme.border))
        .contentShape(Rectangle())
    }
}

/// "+12 -3" in the diff colours.
struct ReviewCounts: View {
    let additions: Int
    let deletions: Int
    var size: CGFloat = 11.5
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(5)) {
            Text("+\(additions)").foregroundStyle(theme.diffAddText)
            Text("-\(deletions)").foregroundStyle(theme.diffRemoveText)
        }
        .font(theme.font(size: size, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .accessibilityLabel("\(additions) lines added, \(deletions) removed")
    }
}

/// Centred empty or error state.
struct ReviewMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.z(10)) {
            Image(systemName: symbol)
                .font(theme.font(size: 22, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .font(theme.font(size: 13.5, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            if !detail.isEmpty {
                Text(detail)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(theme.z(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
