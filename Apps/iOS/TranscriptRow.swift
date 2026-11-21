import EnsembleKit
import SwiftUI

/// Renders one row in a session or room transcript.
struct TranscriptRow: View {
    let item: TranscriptItem
    let agents: [UUID: RemoteAgent]
    let client: RemoteClient
    var modelLabel: String? = nil
    var secondOpinions: [RemoteSecondOpinion] = []
    var availableModels: [RemoteModelOption] = []
    var currentModelID: String? = nil
    var onRequestSecondOpinion: ((String, String, RemoteModelOption) -> Void)? = nil
    var retrySecondOpinion: ((RemoteSecondOpinion, String) -> (() -> Void)?)? = nil
    var continueWithOpinionModel: ((RemoteSecondOpinion) -> (() -> Void)?)? = nil
    var onRetryError: (() -> Void)? = nil
    var onError: (String) -> Void

    var body: some View {
        switch item {
        case .user(let id, let text, _):
            let attached = client.openTranscript?.attachments[id] ?? []
            UserMessageBubble(text: client.openTranscript?.showsText(of: id, text: text) == false ? "" : text,
                              attachments: attached,
                              sessionID: client.openTranscript?.sessionID,
                              client: client)
        case .agentText(let id, let text, let agentID, let streaming):
            AgentTextRow(
                itemID: id,
                text: text,
                agent: agentID.flatMap { agents[$0] },
                modelLabel: modelLabel,
                streaming: streaming,
                opinions: secondOpinions.filter { $0.itemID == id },
                availableModels: availableModels,
                currentModelID: currentModelID,
                onRequestSecondOpinion: onRequestSecondOpinion,
                retrySecondOpinion: retrySecondOpinion,
                continueWithOpinionModel: continueWithOpinionModel
            )
        case .reasoning(_, let text, let streaming):
            RemoteReasoningRow(text: text, streaming: streaming)
        case .tool(let tool):
            RemoteToolRow(tool: tool)
        case .permission(let request):
            if request.isQuestion {
                RemoteQuestionCard(request: request, client: client, onError: onError)
            } else if request.isPlan {
                RemotePlanCard(request: request, client: client, onError: onError)
            } else {
                PermissionCard(
                    request: request,
                    client: client,
                    onError: onError,
                    agent: agents.values.first { $0.sessionID == request.sessionID }
                )
            }
        case .board(_, let from, let to, let text, _):
            BoardMessage(from: agents[from], to: to.compactMap { agents[$0] }, text: text)
        case .error(_, let message):
            RemoteErrorRow(message: message, onRetry: onRetryError)
        case .notice(_, let text):
            RemoteNoticeRow(text: text)
        }
    }
}

// MARK: - User & Assistant Rows

private struct UserMessageBubble: View {
    let text: String
    var attachments: [MessageAttachment] = []
    var sessionID: String? = nil
    var client: RemoteClient? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(attachments) { attachment in
                        AttachmentChipRow(attachment: attachment, sessionID: sessionID, client: client)
                    }
                }
                .padding(.leading, 48)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !text.isEmpty || attachments.isEmpty {
                bubble
            }
        }
    }

    private var bubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(RemoteTheme.font(size: 15, relativeTo: .body))
                .foregroundStyle(RemoteTheme.primaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RemoteTheme.userBubble,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(RemoteTheme.border.opacity(0.6), lineWidth: 0.75)
                )
                .textSelection(.enabled)
        }
    }
}

/// A picture or file attached to a message. Pictures fetch a cached preview from the Mac and open full-screen on tap;
/// files (or pictures on older Macs) render as a chip with their name.
private struct AttachmentChipRow: View {
    let attachment: MessageAttachment
    var sessionID: String? = nil
    var client: RemoteClient? = nil

    @State private var previewImage: UIImage?
    @State private var showLightbox = false

    var body: some View {
        Group {
            if attachment.kind == .image, let image = previewImage {
                Button {
                    showLightbox = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(RemoteTheme.border.opacity(0.75), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View picture \(attachment.label)")
                .sheet(isPresented: $showLightbox) {
                    RemoteImageLightboxSheet(title: attachment.label, image: image)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: attachment.kind == .image ? "photo" : "doc")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)
                    Text(attachment.label)
                        .font(RemoteTheme.font(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RemoteTheme.userBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RemoteTheme.border.opacity(0.6), lineWidth: 0.75)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(attachment.kind == .image ? "Picture \(attachment.name ?? "")" : "File \(attachment.label)")
            }
        }
        .task(id: attachment.id) {
            guard attachment.kind == .image, previewImage == nil else { return }
            if let cached = RemoteAttachmentImageCache.shared.cachedImage(for: attachment.id) {
                previewImage = cached
                return
            }
            guard let sessionID, let client, client.state.isConnected else { return }
            previewImage = await RemoteAttachmentImageCache.shared.loadImage(
                attachmentID: attachment.id,
                sessionID: sessionID,
                client: client
            )
        }
    }
}

private struct AgentTextRow: View {
    let itemID: String
    let text: String
    let agent: RemoteAgent?
    let modelLabel: String?
    let streaming: Bool
    let opinions: [RemoteSecondOpinion]
    let availableModels: [RemoteModelOption]
    let currentModelID: String?
    let onRequestSecondOpinion: ((String, String, RemoteModelOption) -> Void)?
    let retrySecondOpinion: ((RemoteSecondOpinion, String) -> (() -> Void)?)?
    let continueWithOpinionModel: ((RemoteSecondOpinion) -> (() -> Void)?)?

    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 15
    @State private var copied = false
    @State private var copyHaptic = 0

    private var orderedModels: [RemoteModelOption] {
        guard let currentModelID else { return availableModels }
        let other = availableModels.filter { $0.modelID != currentModelID }
        let same = availableModels.filter { $0.modelID == currentModelID }
        return other + same
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent {
                AgentTag(agent: agent, showModel: true)
            } else if let modelLabel, !modelLabel.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(RemoteTheme.font(size: 10, weight: .medium, relativeTo: .caption2))
                    Text(modelLabel)
                        .font(RemoteTheme.font(size: 11.5, weight: .medium, relativeTo: .caption))
                        .lineLimit(1)
                }
                .foregroundStyle(RemoteTheme.tertiaryText)
            }
            MarkdownView(text, fontSize: messageSize, streaming: streaming)
            if streaming {
                ConstellationSpinner(size: 18)
                    .padding(.top, 2)
            } else if hasText {
                HStack(spacing: 8) {
                    Button {
                        copyToPasteboard(text)
                        copyHaptic += 1
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(RemoteTheme.font(size: 11, weight: .medium, relativeTo: .caption))
                            Text(copied ? "Copied" : "Copy")
                                .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                        }
                        .foregroundStyle(copied ? RemoteTheme.success : RemoteTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RemoteTheme.cardRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
                        .frame(minHeight: RemoteTheme.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Copied reply" : "Copy reply")

                    if let onRequestSecondOpinion, !availableModels.isEmpty {
                        Menu {
                            Section("Ask another model") {
                                ForEach(orderedModels) { option in
                                    Button {
                                        onRequestSecondOpinion(itemID, text, option)
                                    } label: {
                                        Text(option.makerName.isEmpty ? option.name : "\(option.name) (\(option.makerName))")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "text.bubble")
                                    .font(RemoteTheme.font(size: 11, weight: .medium, relativeTo: .caption))
                                Text("Second opinion")
                                    .font(RemoteTheme.font(size: 12, weight: .medium, relativeTo: .caption))
                            }
                            .foregroundStyle(RemoteTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RemoteTheme.cardRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
                            .frame(minHeight: RemoteTheme.minTapTarget)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }

            ForEach(opinions) { opinion in
                RemoteSecondOpinionCard(
                    opinion: opinion,
                    onRetry: retrySecondOpinion?(opinion, text),
                    onContinueWithModel: continueWithOpinionModel?(opinion)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(.selection, trigger: copyHaptic)
    }
}

/// What an agent wrote, in the same tuned serif as the Mac app (`MessageType`), following Dynamic Type.
struct AgentMessageText: View {
    let text: String
    @ScaledMetric private var size: CGFloat

    init(text: String, size: CGFloat = 15) {
        self.text = text
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        MarkdownView(text, fontSize: self.size)
    }
}

struct AgentTag: View {
    let agent: RemoteAgent
    var showModel = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(remoteHex: agent.colorHex))
                .frame(width: 8, height: 8)
            Text(agent.name)
                .font(RemoteTheme.font(size: 13, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.primaryText)
            if showModel && !agent.model.isEmpty {
                Text(shortModelLabel(agent.model))
                    .font(RemoteTheme.font(size: 11.5, relativeTo: .caption2))
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
    }

    private func shortModelLabel(_ full: String) -> String {
        let modelPart = full.split(separator: "/").last.map(String.init) ?? full
        return modelPart.split(separator: "#").first.map(String.init) ?? modelPart
    }
}

// MARK: - Reasoning & Tool Calls

private struct RemoteReasoningRow: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(RemoteTheme.font(size: 12.5, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.tertiaryText)
                    Text(streaming ? "Thinking" : "Thought")
                        .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.secondaryText)
                    if streaming {
                        ConstellationSpinner(size: 18)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(RemoteTheme.font(size: 10, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(RemoteTheme.tertiaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: RemoteTheme.minTapTarget)
                .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(RemoteTheme.border)
                        .frame(width: 2)
                    MarkdownView(text, fontSize: 13.5, textColor: RemoteTheme.secondaryText, serif: false)
                }
                .padding(.leading, 6)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Tool call card inspired by Ensemble Mac's `ToolCardView`, with visible status pill and tap-to-expand details.
struct RemoteToolRow: View {
    let tool: ToolCallInfo
    @State private var expanded = false
    @Environment(\.sessionDirectory) private var baseDirectory

    private var summary: ToolSummary { ToolSummary(tool, baseDirectory: baseDirectory) }

    private var hasDetails: Bool {
        if let diff = tool.diff, !diff.isEmpty { return true }
        if let out = tool.outputPreview, !out.isEmpty { return true }
        let name = tool.name.lowercased()
        if ["bash", "shell", "run", "command"].contains(name) { return true }
        return tool.inputJSON != "{}" && !["read", "grep", "glob", "list"].contains(name)
    }

    var body: some View {
        let info = summary
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetails else { return }
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                header(info)
            }
            .buttonStyle(.plain)
            .disabled(!hasDetails)

            if expanded {
                Rectangle().fill(RemoteTheme.separator).frame(height: 1)
                detail
                    .padding(11)
            }
        }
        .background(RemoteTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
        )
    }

    private func header(_ info: ToolSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: info.symbol)
                .font(RemoteTheme.font(size: 12, relativeTo: .footnote))
                .foregroundStyle(RemoteTheme.tertiaryText)
                .frame(width: 16)

            HStack(spacing: 5) {
                Text(info.verb)
                    .font(RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .fixedSize()
                if !info.subject.isEmpty {
                    Text(info.subject)
                        .font(
                            info.monospacedSubject
                                ? RemoteTheme.font(size: 12.5, design: .monospaced, relativeTo: .footnote)
                                : RemoteTheme.font(size: 13, weight: .medium, relativeTo: .footnote)
                        )
                        .foregroundStyle(RemoteTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let add = info.additions, let del = info.deletions, add + del > 0 {
                HStack(spacing: 4) {
                    Text("+\(add)").foregroundStyle(RemoteTheme.success)
                    Text("-\(del)").foregroundStyle(RemoteTheme.danger)
                }
                .font(RemoteTheme.font(size: 11.5, weight: .semibold, relativeTo: .caption).monospacedDigit())
                .fixedSize()
            }

            statusPill

            if hasDetails {
                Image(systemName: "chevron.right")
                    .font(RemoteTheme.font(size: 10, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusPill: some View {
        switch tool.status {
        case .pending, .running:
            HStack(spacing: 4) {
                Spinner(size: 10)
                Text("Running")
            }
            .font(RemoteTheme.font(size: 11, weight: .semibold, relativeTo: .caption2))
            .foregroundStyle(RemoteTheme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RemoteTheme.cardRaised, in: Capsule())
        case .succeeded:
            Image(systemName: "checkmark")
                .font(RemoteTheme.font(size: 10, weight: .bold, relativeTo: .caption2))
                .foregroundStyle(RemoteTheme.success)
                .frame(width: 20, height: 20)
                .background(RemoteTheme.success.opacity(0.14), in: Circle())
        case .failed:
            Text("Failed")
                .font(RemoteTheme.font(size: 11, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(RemoteTheme.danger)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RemoteTheme.danger.opacity(0.14), in: Capsule())
        }
    }

    @ViewBuilder
    private var detail: some View {
        let name = tool.name.lowercased()
        if let diff = tool.diff, !diff.isEmpty {
            DiffView(diff: diff)
                .background(RemoteTheme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if ["bash", "shell", "run", "command"].contains(name) {
            VStack(alignment: .leading, spacing: 8) {
                Text("$ \(tool.title)")
                    .font(RemoteTheme.font(size: 12.5, design: .monospaced, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let output = tool.outputPreview, !output.isEmpty {
                    outputBox(output)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let output = tool.outputPreview, !output.isEmpty {
            outputBox(output)
        } else {
            outputBox(tool.inputJSON)
        }
    }

    private func outputBox(_ text: String) -> some View {
        Text(text)
            .font(RemoteTheme.font(size: 12, design: .monospaced, relativeTo: .caption))
            .foregroundStyle(RemoteTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(RemoteTheme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .textSelection(.enabled)
    }
}

// MARK: - Permission Card

/// A permission prompt with Allow once, Always, and Reject.
struct PermissionCard: View {
    let request: PermissionRequest
    let client: RemoteClient
    var onError: (String) -> Void
    var agent: RemoteAgent?
    @State private var busy = false
    @State private var allowHaptic = 0
    @State private var rejectHaptic = 0

    private var decision: PermissionDecision? { client.permissionDecisions[request.id] }
    private var answered: Bool {
        client.isAnswered(request.id) || (!client.permissions.contains { $0.id == request.id } && decision != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(RemoteTheme.warning)
                Text("Permission needed")
                    .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(RemoteTheme.primaryText)
                if let agent {
                    AgentTag(agent: agent)
                }
                Spacer(minLength: 4)
                Chip(text: request.kind)
            }

            RemoteCommandBox(text: PermissionDisplay.visible(request.title), maxHeight: 220)

            if let detail = request.detail.map({ PermissionDisplay.visible($0) }), !detail.isEmpty {
                Text(detail)
                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.secondaryText)
            }

            let patterns = PermissionDisplay.patterns(request)
            if !patterns.isEmpty {
                Label {
                    Text("Always allows " + patterns.joined(separator: "; "))
                        .font(RemoteTheme.font(size: 12, design: .monospaced, relativeTo: .caption))
                } icon: {
                    Image(systemName: "infinity")
                }
                .font(RemoteTheme.font(size: 12, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.tertiaryText)
            }

            if answered {
                Label(answerText, systemImage: decision == .reject ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(RemoteTheme.font(size: 13.5, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(decision == .reject ? RemoteTheme.danger : RemoteTheme.success)
            } else {
                FlowRow(spacing: 8, lineSpacing: 8) {
                    Button("Allow once") { reply(.once) }
                        .buttonStyle(RemotePrimaryButtonStyle())
                    Button("Always") { reply(.always) }
                        .buttonStyle(RemoteSecondaryButtonStyle())
                    Button("Reject", role: .destructive) { reply(.reject) }
                        .buttonStyle(
                            RemoteSecondaryButtonStyle(
                                foreground: RemoteTheme.danger,
                                border: RemoteTheme.danger.opacity(0.4)
                            )
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(busy || !client.state.isConnected)
            }
        }
        .remoteCard(padding: 14, attention: !answered)
        .sensoryFeedback(.success, trigger: allowHaptic)
        .sensoryFeedback(.warning, trigger: rejectHaptic)
    }

    private var answerText: String {
        switch decision {
        case .once: "Allowed once"
        case .always: "Always allowed"
        case .reject: "Rejected"
        case nil: "Answered"
        }
    }

    private func reply(_ d: PermissionDecision) {
        if d == .reject { rejectHaptic += 1 } else { allowHaptic += 1 }
        busy = true
        Task {
            do { try await client.reply(to: request, decision: d) } catch { onError(error.localizedDescription) }
            busy = false
        }
    }
}

// MARK: - Board, Error, Notice Rows

/// A message one agent posted to the room board.
struct BoardMessage: View {
    let from: RemoteAgent?
    let to: [RemoteAgent]
    let text: String

    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 14.5

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(from.map { Color(remoteHex: $0.colorHex) } ?? RemoteTheme.border)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if let from {
                        AgentTag(agent: from)
                    }
                    if !to.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(RemoteTheme.font(size: 10, weight: .semibold, relativeTo: .caption2))
                            .foregroundStyle(RemoteTheme.tertiaryText)
                        Text(to.map(\.name).joined(separator: ", "))
                            .font(RemoteTheme.font(size: 12.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(RemoteTheme.secondaryText)
                    }
                }
                MarkdownView(text, fontSize: messageSize)
            }
        }
        .padding(.vertical, 3)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RemoteErrorRow: View {
    let message: String
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.danger)
                Text(message)
                    .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                    .foregroundStyle(RemoteTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if let onRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RemoteTheme.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(RemoteTheme.danger.opacity(0.32), lineWidth: 1)
        )
    }
}

private struct RemoteNoticeRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(RemoteTheme.font(size: 12, relativeTo: .caption))
            Text(text)
                .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
        }
        .foregroundStyle(RemoteTheme.tertiaryText)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}
