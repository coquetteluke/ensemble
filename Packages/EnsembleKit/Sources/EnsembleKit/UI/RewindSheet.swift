import SwiftUI

/// The rewind sheet: what to put back (code and conversation, conversation only, code only, summarize from here), the
/// files that will change with their line counts, and Rewind. Choices the session's engine cannot do stay visible,
/// greyed, with the reason. Nothing changes until Rewind.
public struct RewindSheet: View {
    let request: RewindRequest
    /// Why Rewind is off (the agent is working, nothing chosen), or nil.
    let confirmUnavailableReason: String?
    let onSelect: (RewindScope) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.theme) private var theme

    public init(request: RewindRequest, confirmUnavailableReason: String?, onSelect: @escaping (RewindScope) -> Void,
                onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.request = request
        self.confirmUnavailableReason = confirmUnavailableReason
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(16)) {
            header
            switch request.phase {
            case .loading:
                HStack(spacing: theme.z(8)) {
                    Spinner(size: 11)
                    Text("Reading what a rewind would change")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: theme.z(120))
            case .failed(let message):
                Text(message)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .ready(let plan), .working(let plan, _):
                choices(plan)
                consequences(plan)
            }
            if let reason = confirmUnavailableReason, request.plan != nil, request.selected != nil, !request.isWorking {
                HStack(spacing: theme.z(7)) {
                    Image(systemName: "exclamationmark.circle")
                        .font(theme.font(size: 11.5))
                    Text(reason)
                        .font(theme.font(size: 12))
                }
                .foregroundStyle(theme.warning)
            }
            if let error = request.error {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            buttons
        }
        .padding(theme.z(22))
        .frame(width: theme.z(500))
        .background(theme.background)
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.z(5)) {
            Text("Rewind")
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if !request.messageText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: theme.z(5)) {
                    Text("To before")
                        .foregroundStyle(theme.textTertiary)
                    Text("\u{201C}\(request.messageText)\u{201D}")
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(theme.font(size: 12.5))
                .help(request.messageText)
            }
        }
    }

    private func choices(_ plan: RewindPlan) -> some View {
        VStack(spacing: theme.z(2)) {
            ForEach(plan.choices) { choice in
                RewindChoiceRow(choice: choice, selected: request.selected == choice.scope,
                                enabled: choice.isAvailable && !request.isWorking) {
                    onSelect(choice.scope)
                }
            }
        }
        .padding(theme.z(4))
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
    }

    /// What the selected choice does to files and messages.
    @ViewBuilder private func consequences(_ plan: RewindPlan) -> some View {
        let scope = request.selected ?? plan.defaultScope
        VStack(alignment: .leading, spacing: theme.z(8)) {
            if let scope, scope.restoresFiles {
                RewindFileList(files: plan.files, known: plan.filesKnown, note: plan.filesNote)
            } else if scope != nil, plan.filesKnown, !plan.files.isEmpty {
                summaryLine(symbol: "doc", plan.files.count == 1 ? "1 changed file stays as it is"
                            : "\(plan.files.count) changed files stay as they are")
            }
            if let scope, scope.removesMessages {
                summaryLine(symbol: "text.bubble", plan.messagesRemoved == 1 ? "1 message leaves the conversation"
                            : "\(plan.messagesRemoved) messages leave the conversation")
            } else if scope == .codeOnly {
                summaryLine(symbol: "text.bubble", "The conversation stays as it is")
            }
            if plan.canRedo, scope.map({ plan.choice($0).isAvailable }) == true {
                summaryLine(symbol: "arrow.uturn.forward", "Redo in the transcript undoes this until you send another message")
            }
        }
    }

    private func summaryLine(symbol: String, _ text: String) -> some View {
        HStack(spacing: theme.z(7)) {
            Image(systemName: symbol)
                .font(theme.font(size: 11))
                .frame(width: theme.z(14))
            Text(text)
                .font(theme.font(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.textTertiary)
    }

    private var buttons: some View {
        HStack(spacing: theme.z(8)) {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(request.isWorking)
            Button(action: onConfirm) {
                HStack(spacing: theme.z(6)) {
                    if request.isWorking { Spinner(size: 10, color: theme.onAccent) }
                    Text(request.isWorking ? "Rewinding" : "Rewind")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm)
            .help(confirmUnavailableReason ?? "Rewind with the chosen option")
        }
    }

    private var canConfirm: Bool {
        guard case .ready = request.phase, confirmUnavailableReason == nil, let scope = request.selected else { return false }
        return request.plan?.choice(scope).isAvailable == true
    }
}

/// One choice: a radio, the title and what it does, or why it is unavailable.
struct RewindChoiceRow: View {
    let choice: RewindChoice
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            if enabled { action() }
        } label: {
            HStack(alignment: .top, spacing: theme.z(10)) {
                ZStack {
                    Circle()
                        .strokeBorder(selected && choice.isAvailable ? theme.accent : theme.textTertiary.opacity(0.7),
                                      lineWidth: selected && choice.isAvailable ? theme.z(4.5) : 1)
                        .frame(width: theme.z(14), height: theme.z(14))
                }
                .padding(.top, theme.z(1.5))
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    HStack(spacing: theme.z(6)) {
                        Image(systemName: choice.scope.symbol)
                            .font(theme.font(size: 11))
                            .foregroundStyle(choice.isAvailable ? theme.textSecondary : theme.textTertiary.opacity(0.7))
                            .frame(width: theme.z(14))
                        Text(choice.scope.title)
                            .font(theme.font(size: 13, weight: .medium))
                            .foregroundStyle(choice.isAvailable ? theme.textPrimary : theme.textTertiary)
                    }
                    if let reason = choice.unavailableReason {
                        Text(reason)
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(choice.scope.detail)
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(8))
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                    .fill(selected && choice.isAvailable ? theme.raisedSelection : (hovering && enabled ? theme.raisedHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(choice.unavailableReason ?? choice.scope.detail)
        .accessibilityLabel(choice.scope.title)
        .accessibilityValue(choice.unavailableReason ?? (selected ? "Selected" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The files a code rewind changes: what happens to each (added back, modified, deleted) and the lines it adds and
/// removes.
public struct RewindFileList: View {
    let files: [FileChange]
    let known: Bool
    let note: String?
    @Environment(\.theme) private var theme

    public init(files: [FileChange], known: Bool, note: String?) {
        self.files = files
        self.known = known
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            HStack(spacing: theme.z(6)) {
                Text(title)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if known, !files.isEmpty {
                    Text(totals)
                        .font(theme.font(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            if known, !files.isEmpty {
                Group {
                    if files.count <= 6 {
                        rows
                    } else {
                        AdaptiveScroll { rows }
                            .frame(height: theme.z(180))
                    }
                }
                .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.border))
                .clipShape(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous))
            }
            if let note, known {
                Text(note)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                if index > 0 { HLine() }
                row(file)
            }
        }
    }

    private var title: String {
        guard known else { return "The engine puts the files back without listing them first" }
        if files.isEmpty { return "No files changed after this message" }
        return files.count == 1 ? "1 file changes" : "\(files.count) files change"
    }

    private var totals: String {
        let added = files.reduce(0) { $0 + $1.additions }
        let removed = files.reduce(0) { $0 + $1.deletions }
        return "+\(added) \u{2212}\(removed)"
    }

    private func row(_ file: FileChange) -> some View {
        HStack(spacing: theme.z(10)) {
            Text(label(file.kind))
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(color(file.kind))
                .lineLimit(1)
                .fixedSize()
                .frame(width: theme.z(70), alignment: .leading)
            Text(file.path)
                .font(theme.font(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.path)
            Spacer(minLength: theme.z(8))
            if file.additions > 0 || file.deletions > 0 {
                HStack(spacing: theme.z(6)) {
                    if file.additions > 0 {
                        Text("+\(file.additions)").foregroundStyle(theme.diffAddText)
                    }
                    if file.deletions > 0 {
                        Text("\u{2212}\(file.deletions)").foregroundStyle(theme.diffRemoveText)
                    }
                }
                .font(theme.font(size: 11.5, design: .monospaced))
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(28))
        .accessibilityElement(children: .combine)
    }

    private func label(_ kind: FileChange.Kind) -> String {
        switch kind {
        case .added: "Added back"
        case .modified: "Modified"
        case .deleted: "Deleted"
        }
    }

    private func color(_ kind: FileChange.Kind) -> Color {
        switch kind {
        case .added: theme.success
        case .modified: theme.warning
        case .deleted: theme.danger
        }
    }
}

/// The line a rewind leaves in the transcript, with Redo while the engine can undo it.
public struct RewindNoticeRow: View {
    let notice: RewindNotice
    /// Why Redo is off now, or nil when it can run.
    let redoUnavailableReason: String?
    let onRedo: () -> Void
    @Environment(\.theme) private var theme

    public init(notice: RewindNotice, redoUnavailableReason: String?, onRedo: @escaping () -> Void) {
        self.notice = notice
        self.redoUnavailableReason = redoUnavailableReason
        self.onRedo = onRedo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(3)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: notice.state == .redone ? "arrow.uturn.forward" : "arrow.counterclockwise")
                    .font(theme.font(size: 11.5))
                    .frame(width: theme.z(16))
                Text(notice.text)
                    .font(theme.font(size: 12.5))
                    .help(fileList)
                if showsRedo {
                    if notice.state == .redoing {
                        Spinner(size: 10)
                    } else {
                        Button("Redo", action: onRedo)
                            .buttonStyle(.plain)
                            .font(theme.font(size: 12.5, weight: .medium))
                            .foregroundStyle(redoUnavailableReason == nil ? theme.accent : theme.textTertiary)
                            .disabled(redoUnavailableReason != nil)
                            .help(redoUnavailableReason ?? "Undo this rewind: the conversation and files go back to how they were")
                    }
                }
            }
            .foregroundStyle(theme.textTertiary)
            .frame(minHeight: theme.z(20))
            if let error = notice.error {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
                    .padding(.leading, theme.z(24))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Redo is offered while it means something: the engine can undo, nothing replaced this rewind, and the
    /// conversation has not moved on (a working agent only greys it out).
    private var showsRedo: Bool {
        guard notice.outcome.canRedo, notice.state == .done || notice.state == .redoing, !notice.superseded else { return false }
        return redoUnavailableReason == nil || redoUnavailableReason == RewindReason.working
    }

    private var fileList: String {
        notice.outcome.files.isEmpty ? notice.text : notice.outcome.files.map(\.path).joined(separator: "\n")
    }
}

/// Presents the store's rewind sheet. Attach once per visible session (the composer does); only the sheet for
/// `sessionID` shows there.
public struct RewindSheetPresenter: ViewModifier {
    let store: SessionStore
    let sessionID: String

    public init(store: SessionStore, sessionID: String) {
        self.store = store
        self.sessionID = sessionID
    }

    public func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { store.rewinds.request?.sessionID == sessionID },
            set: { if !$0 { store.cancelRewind() } })) {
            if let request = store.rewinds.request {
                RewindSheet(request: request, confirmUnavailableReason: store.rewindConfirmUnavailableReason(),
                            onSelect: { store.selectRewindScope($0) }, onCancel: { store.cancelRewind() },
                            onConfirm: { Task { await store.confirmRewind() } })
                    .interactiveDismissDisabled(request.isWorking)
                    .ensembleTheme()
            }
        }
    }
}
