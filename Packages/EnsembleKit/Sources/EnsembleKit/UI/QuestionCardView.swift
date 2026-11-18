import SwiftUI

/// The agent's open question, docked above the composer: the question in the agent's serif, the options as buttons
/// (checkboxes when several may be chosen), and an Other field when a typed answer is allowed. Several questions are
/// asked one at a time. Choosing an option of a single-choice question answers it at once; the last question's
/// answers go back to the agent together. Decline tells the agent the user chose not to answer.
public struct QuestionCardView: View {
    let request: PermissionRequest
    let onAnswer: ([AgentQuestionAnswer]) -> Void
    let onDecline: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var step: Int
    @State private var selections: [String: [String]]
    @State private var others: [String: String]
    @State private var collapsed = false
    @FocusState private var otherFocused: Bool

    /// `selections` and `others` preset the answers (snapshots).
    public init(request: PermissionRequest, step: Int = 0, selections: [String: [String]] = [:], others: [String: String] = [:],
                onAnswer: @escaping ([AgentQuestionAnswer]) -> Void, onDecline: @escaping () -> Void) {
        self.request = request
        self.onAnswer = onAnswer
        self.onDecline = onDecline
        self._step = State(initialValue: step)
        self._selections = State(initialValue: selections)
        self._others = State(initialValue: others)
    }

    private var questions: [AgentQuestion] { request.questions ?? [] }
    private var current: AgentQuestion? { questions.indices.contains(step) ? questions[step] : nil }
    private var isLast: Bool { step >= questions.count - 1 }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(12)) {
            header
            if !collapsed, let question = current {
                MarkdownView(question.text, fontSize: 14.5)
                    .fixedSize(horizontal: false, vertical: true)
                if !question.options.isEmpty {
                    VStack(alignment: .leading, spacing: theme.z(6)) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            optionRow(option, number: index + 1, in: question)
                        }
                    }
                }
                if question.allowsOther { otherField(question) }
                footer(question)
            }
        }
        .padding(theme.z(14))
        .background(RoundedRectangle(cornerRadius: theme.z(14), style: .continuous).fill(theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(14), style: .continuous)
                .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: theme.z(10), y: theme.z(3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The agent asks: \(current?.text ?? request.title)")
        .onChange(of: request.id) {
            step = 0
            selections = [:]
            others = [:]
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "questionmark.bubble")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(current?.header ?? "Question")
                .font(theme.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            if questions.count > 1 {
                Text("\(min(step + 1, questions.count)) of \(questions.count)")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
            if collapsed, let question = current {
                Text(question.text)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: theme.z(8))
            Button {
                withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(theme.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: theme.z(22), height: theme.z(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the question" : "Hide the question")
            .accessibilityLabel(collapsed ? "Show the question" : "Hide the question")
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, number: Int, in question: AgentQuestion) -> some View {
        let selected = (selections[question.id] ?? []).contains(option.label)
        return Button {
            choose(option, in: question)
        } label: {
            HStack(alignment: .top, spacing: theme.z(10)) {
                marker(selected: selected, multi: question.multiSelect, number: number)
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    Text(option.label)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(10))
            .padding(.vertical, theme.z(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.12) : theme.background.opacity(theme.isDark ? 0.5 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                    .strokeBorder(selected ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func marker(selected: Bool, multi: Bool, number: Int) -> some View {
        if multi {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(theme.font(size: 13))
                .foregroundStyle(selected ? theme.accent : theme.textTertiary)
                .frame(width: theme.z(18), height: theme.z(18))
        } else {
            Text("\(number)")
                .font(theme.font(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(selected ? theme.onAccent : theme.textSecondary)
                .frame(width: theme.z(18), height: theme.z(18))
                .background(Circle().fill(selected ? theme.accent : theme.hover))
        }
    }

    private func otherField(_ question: AgentQuestion) -> some View {
        let text = others[question.id] ?? ""
        return HStack(spacing: theme.z(8)) {
            Image(systemName: "pencil")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
            Group {
                if isSnapshot {
                    Text(text.isEmpty ? otherPrompt(question) : text)
                        .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: Binding(get: { others[question.id] ?? "" }, set: { others[question.id] = $0 }),
                              prompt: Text(otherPrompt(question)).foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .focused($otherFocused)
                        .onSubmit { advance(from: question) }
                }
            }
            .font(theme.font(size: 13))
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(32))
        .background(
            RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(8), style: .continuous)
                .strokeBorder(text.isEmpty ? theme.border : theme.accent.opacity(0.7), lineWidth: 1)
        )
    }

    private func otherPrompt(_ question: AgentQuestion) -> String {
        question.options.isEmpty ? "Type your answer" : "Other: type your own answer"
    }

    /// Decline and Back on the left, Send answer (or Next) on the right; in a narrow pane the buttons wrap instead of
    /// cutting their labels short.
    private func footer(_ question: AgentQuestion) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: theme.z(8)) {
                secondaryButtons
                Spacer(minLength: 0)
                primaryButton(question)
            }
            FlowRow(spacing: theme.z(8)) {
                secondaryButtons
                primaryButton(question)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        Button("Decline", action: onDecline)
            .buttonStyle(SecondaryButtonStyle())
            .help("Tell the agent you won't answer")
        if step > 0 {
            Button("Back") { step -= 1 }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// Single-choice questions answer on click; the button is for checkboxes and typed answers.
    @ViewBuilder private func primaryButton(_ question: AgentQuestion) -> some View {
        if question.multiSelect || question.allowsOther || questions.count > 1 {
            Button(isLast ? "Send answer" : "Next") { advance(from: question) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(answer(for: question) == nil)
        }
    }

    // MARK: Answering

    private func answer(for question: AgentQuestion) -> AgentQuestionAnswer? {
        question.validated(AgentQuestionAnswer(questionID: question.id, selected: selections[question.id] ?? [],
                                               other: others[question.id]))
    }

    private func choose(_ option: AgentQuestion.Option, in question: AgentQuestion) {
        var chosen = selections[question.id] ?? []
        if question.multiSelect {
            if let index = chosen.firstIndex(of: option.label) { chosen.remove(at: index) } else { chosen.append(option.label) }
            selections[question.id] = chosen
        } else {
            selections[question.id] = [option.label]
            others[question.id] = nil
            advance(from: question)
        }
    }

    private func advance(from question: AgentQuestion) {
        guard answer(for: question) != nil else { return }
        if isLast {
            let answers = questions.compactMap(answer(for:))
            if answers.count == questions.count { onAnswer(answers) }
        } else {
            step += 1
        }
    }
}

/// A question in the transcript: what was asked and, once answered, the answer. The question is answered in the card
/// docked above the composer.
public struct QuestionRecordView: View {
    let request: PermissionRequest
    let resolution: PermissionResolution?
    @Environment(\.theme) private var theme
    @Environment(\.interactionStore) private var store

    public init(request: PermissionRequest, resolution: PermissionResolution? = nil) {
        self.request = request
        self.resolution = resolution
    }

    private var outcome: InteractionOutcome? { store?.interactionOutcomes[request.id] }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(5)) {
            ForEach(Array((request.questions ?? []).enumerated()), id: \.offset) { index, question in
                HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                    Image(systemName: index == 0 ? symbol : "circle.fill")
                        .font(theme.font(size: index == 0 ? 12 : 4))
                        .foregroundStyle(index == 0 ? tint : theme.textTertiary)
                        .frame(width: theme.z(16))
                    VStack(alignment: .leading, spacing: theme.z(2)) {
                        Text(question.text)
                            .font(theme.font(size: 13))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = answerLine(for: question) {
                            Text(line)
                                .font(theme.font(size: 12.5, weight: .medium))
                                .foregroundStyle(answerTint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(minHeight: theme.z(22))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch (resolution, outcome) {
        case (nil, _): "questionmark.bubble"
        case (_, .declined?), (.rejected?, _): "xmark.circle"
        default: "checkmark.circle"
        }
    }

    private var tint: Color { resolution == nil ? theme.accent : theme.textTertiary }

    private var answerTint: Color { resolution == nil ? theme.warning : theme.textSecondary }

    private func answerLine(for question: AgentQuestion) -> String? {
        guard let resolution else { return "Waiting for your answer" }
        switch outcome {
        case .answered(let answers)?:
            return answers.first { $0.questionID == question.id }.map { "Answered: \($0.text)" }
        case .declined?:
            return "Declined"
        default:
            return resolution == .rejected ? "Declined" : "Answered"
        }
    }
}
