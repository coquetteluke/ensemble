import SwiftUI

public extension EnvironmentValues {
    /// The store plan and question cards answer through (`SessionStore+Interactions.swift`). Without it the cards are
    /// shown but cannot be answered.
    @Entry var interactionStore: SessionStore? = nil
}

/// A plan the agent presents before changing anything, in the agent's serif, one row per line. Hovering a line shows a
/// comment button; comments open in boxes under their lines. Proceed switches to the mode named on the button and the
/// agent carries out the plan; Keep planning sends the comments back as one message and stays in Plan mode.
/// Answered, the card shows how it was resolved and keeps the plan behind Show plan.
public struct PlanCardView: View {
    let request: PermissionRequest
    let resolution: PermissionResolution?
    @Environment(\.theme) private var theme
    @Environment(\.interactionStore) private var store
    @Environment(\.transcriptActions) private var actions
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var expanded: Bool
    @FocusState private var focusedLine: Int?

    public init(request: PermissionRequest, resolution: PermissionResolution? = nil, expanded: Bool = false) {
        self.request = request
        self.resolution = resolution
        self._expanded = State(initialValue: expanded)
    }

    private var plan: PlanProposal { request.plan ?? PlanProposal(markdown: "") }
    private var lines: [String] { PlanLines.split(plan.markdown) }
    private var outcome: InteractionOutcome? { store?.interactionOutcomes[request.id] }
    private var isOpen: Bool { resolution == nil }
    private var proceedModes: [PermissionMode] { plan.allowedProceedModes }

    private var drafts: [Int: String] { store?.planCommentDrafts[request.id] ?? [:] }
    private var writtenComments: [PlanComment] {
        let lines = lines
        return drafts.compactMap { index, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, index < lines.count else { return nil }
            return PlanComment(lineIndex: index, line: lines[index], text: trimmed)
        }
        .sorted { $0.lineIndex < $1.lineIndex }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen || expanded {
                HLine(color: theme.border)
                document
            }
            if isOpen {
                HLine(color: theme.border)
                footer
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                .strokeBorder(isOpen ? theme.accent.opacity(0.5) : theme.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isOpen ? "Plan ready for review: \(plan.title)" : "Plan: \(plan.title)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: headerSymbol)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(headerTint)
                .frame(width: theme.z(16))
            Text("Plan")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if let outcome, !isOpen {
                Text(outcome.label)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            } else if !isOpen {
                Text(resolution?.label ?? "")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
            } else if let file = plan.filePath.map({ ($0 as NSString).lastPathComponent }) {
                Text(file)
                    .font(theme.font(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(plan.filePath ?? "")
            }
            Spacer(minLength: theme.z(8))
            if isOpen, !writtenComments.isEmpty {
                Text(writtenComments.count == 1 ? "1 comment" : "\(writtenComments.count) comments")
                    .font(theme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            if !isOpen {
                Button(expanded ? "Hide plan" : "Show plan") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(10))
    }

    private var headerSymbol: String {
        switch outcome {
        case .proceeded?: "checkmark.circle"
        case .keptPlanning?: "arrow.uturn.backward.circle"
        default: isOpen ? "list.bullet.clipboard" : "checkmark.circle"
        }
    }

    private var headerTint: Color {
        isOpen ? theme.accent : theme.textTertiary
    }

    // MARK: Document

    private var document: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            if lines.isEmpty {
                Text("The agent sent an empty plan.")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.z(8))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                PlanLineRow(line: line, comment: commentBinding(index), commentable: isOpen && store != nil,
                            focus: $focusedLine, index: index)
            }
        }
        .padding(.horizontal, theme.z(6))
        .padding(.vertical, theme.z(10))
    }

    private func commentBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { drafts[index] },
            set: { value in
                guard let store else { return }
                var all = store.planCommentDrafts[request.id] ?? [:]
                all[index] = value
                store.planCommentDrafts[request.id] = all.isEmpty ? nil : all
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        // Wraps in a narrow pane rather than cutting the labels short.
        FlowRow(spacing: theme.z(8)) {
            ForEach(Array(proceedModes.enumerated()), id: \.element) { position, mode in
                Button("Proceed in \(mode.shortLabel)") { decide(.proceed(mode)) }
                    .modifier(PlanButtonStyle(primary: position == 0))
                    .modifier(ProceedShortcut(enabled: position == 0 && hasShortcut))
                    .help(position == 0 && hasShortcut ? "Proceed in \(mode.label) (Command-Return)" : "Proceed in \(mode.label)")
            }
            Button("Keep planning") { decide(.keepPlanning(comments: writtenComments)) }
                .buttonStyle(SecondaryButtonStyle())
                .help(keepPlanningHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(store == nil)
        .padding(.horizontal, theme.z(14))
        .padding(.vertical, theme.z(12))
    }

    private var hasShortcut: Bool { !isSnapshot && actions.shortcutPermissionID == request.id }

    private var keepPlanningHelp: String {
        switch writtenComments.count {
        case 0: "Stay in Plan mode and ask for a revised plan"
        case 1: "Send your comment and stay in Plan mode"
        default: "Send your \(writtenComments.count) comments as one message and stay in Plan mode"
        }
    }

    private func decide(_ decision: PlanDecision) {
        guard let store else { return }
        let request = request
        Task {
            await store.respondToPlan(request, decision: decision)
            if store.interactionOutcomes[request.id] != nil { store.planCommentDrafts[request.id] = nil }
        }
    }
}

/// One line of a plan with its comment button and comment box.
private struct PlanLineRow: View {
    let line: String
    @Binding var comment: String?
    let commentable: Bool
    var focus: FocusState<Int?>.Binding
    let index: Int
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            HStack(alignment: .top, spacing: theme.z(6)) {
                MarkdownView(line, fontSize: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if commentable {
                    Button {
                        if comment == nil { comment = "" }
                        focus.wrappedValue = index
                    } label: {
                        Image(systemName: comment == nil ? "plus.bubble" : "bubble.left.fill")
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(comment == nil ? theme.textSecondary : theme.accent)
                            .frame(width: theme.z(24), height: theme.z(22))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || comment != nil ? 1 : 0)
                    .help("Comment on this line")
                    .accessibilityLabel("Comment on this line")
                }
            }
            .padding(.leading, theme.z(8))
            .padding(.trailing, theme.z(2))
            .padding(.vertical, theme.z(3))
            .background(
                RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                    .fill(comment != nil ? theme.accent.opacity(0.08) : (hovering && commentable ? theme.hover : .clear))
            )
            if let text = comment {
                commentBox(text)
                    .padding(.leading, theme.z(8))
                    .padding(.trailing, theme.z(2))
                    .padding(.bottom, theme.z(4))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func commentBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.z(6)) {
            Group {
                if isSnapshot {
                    Text(text.isEmpty ? "Comment on this line" : text)
                        .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("", text: Binding(get: { comment ?? "" }, set: { comment = $0 }),
                              prompt: Text("Comment on this line").foregroundStyle(theme.textTertiary), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .foregroundStyle(theme.textPrimary)
                        .focused(focus, equals: index)
                }
            }
            .font(theme.font(size: 13))
            Button {
                comment = nil
            } label: {
                Image(systemName: "xmark")
                    .font(theme.font(size: 9.5, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: theme.z(18), height: theme.z(18))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this comment")
            .accessibilityLabel("Remove this comment")
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(7))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.background))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1)
        )
    }
}

/// The first Proceed button is filled, the rest bordered.
private struct PlanButtonStyle: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        if primary {
            content.buttonStyle(PrimaryButtonStyle())
        } else {
            content.buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// Command-Return proceeds on the plan that owns the session's shortcuts.
private struct ProceedShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.return, modifiers: .command)
        } else {
            content
        }
    }
}
