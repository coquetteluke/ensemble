import SwiftUI

/// What a tool card says in its collapsed line, e.g. "Ran" + "npm test".
public struct ToolSummary: Equatable, Sendable {
    public var symbol: String
    public var verb: String
    public var subject: String
    /// Command-like subjects are set in a monospaced font.
    public var monospacedSubject: Bool
    public var additions: Int?
    public var deletions: Int?

    public init(_ tool: ToolCallInfo, baseDirectory: String = "") {
        let running = tool.status == .running || tool.status == .pending
        let path = Format.relativePath(tool.title, base: baseDirectory)
        additions = nil
        deletions = nil
        monospacedSubject = false
        // Every engine's plan or todo tool (`TodoParser`) reads the same way, whatever it is called.
        switch TodoParser.isPlanTool(tool.name) ? "todowrite" : tool.name.lowercased() {
        case "bash", "shell", "run", "command":
            symbol = "terminal"
            verb = running ? "Running" : "Ran"
            subject = tool.title
            monospacedSubject = true
        case "edit", "multiedit", "patch", "apply_patch":
            symbol = "pencil"
            verb = running ? "Editing" : "Edited"
            subject = path
        case "write", "create":
            symbol = "doc.badge.plus"
            verb = running ? "Writing" : "Wrote"
            subject = path
        case "read", "view":
            symbol = "doc.text"
            verb = running ? "Reading" : "Read"
            subject = path
        case "grep", "search":
            symbol = "magnifyingglass"
            verb = running ? "Searching for" : "Searched for"
            subject = tool.title
            monospacedSubject = true
        case "glob", "find":
            symbol = "folder.badge.questionmark"
            verb = running ? "Finding" : "Found"
            subject = tool.title
            monospacedSubject = true
        case "list", "ls":
            symbol = "list.bullet"
            verb = running ? "Listing" : "Listed"
            subject = path
        case "webfetch", "fetch":
            symbol = "globe"
            verb = running ? "Fetching" : "Fetched"
            subject = tool.title
        case "websearch":
            symbol = "globe"
            verb = running ? "Searching the web for" : "Searched the web for"
            subject = tool.title
        case "todowrite", "todoread", "todo":
            symbol = "checklist"
            verb = "Updated the plan"
            subject = ""
        case "task", "agent", "subagent":
            symbol = "person.2"
            verb = "Subagent"
            subject = tool.title
        default:
            symbol = "wrench.and.screwdriver"
            verb = tool.name
            subject = tool.title
        }
        if let diff = tool.diff {
            let stats = Format.diffStats(diff)
            additions = stats.additions
            deletions = stats.deletions
        }
    }
}

/// A tool call: a one-line summary ("Ran `swift build`", "Edited ContextBar.swift +12 -3")
/// that expands to its input, output or diff.
public struct ToolCardView: View {
    let tool: ToolCallInfo
    @State private var expanded: Bool
    @Environment(\.theme) private var theme
    @Environment(\.sessionDirectory) private var baseDirectory
    @State private var hovering = false

    public init(tool: ToolCallInfo, expanded: Bool = false) {
        self.tool = tool
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        let summary = ToolSummary(tool, baseDirectory: baseDirectory)
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header(summary)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityHint(expanded ? "Collapse" : "Expand")

            if expanded {
                detail
                    .padding(.leading, theme.z(24))
                    .transition(.opacity)
            }
        }
    }

    private func header(_ summary: ToolSummary) -> some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: summary.symbol)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(16))
            titleText(summary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let add = summary.additions, let del = summary.deletions, add + del > 0 {
                HStack(spacing: theme.z(4)) {
                    Text("+\(add)").foregroundStyle(theme.diffAddText)
                    Text("-\(del)").foregroundStyle(theme.diffRemoveText)
                }
                .font(theme.font(size: 12, weight: .medium).monospacedDigit())
            }
            SafetyCheckToolBadge(toolCallID: tool.id)
            switch tool.status {
            case .running, .pending:
                Spinner(size: 11)
            case .failed:
                Text("Failed")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.danger)
            case .succeeded:
                EmptyView()
            }
            Image(systemName: "chevron.right")
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(hovering || expanded ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(minHeight: theme.z(22))
        .contentShape(Rectangle())
    }

    private func titleText(_ summary: ToolSummary) -> Text {
        let verb = Text(summary.verb).foregroundStyle(theme.textSecondary)
        guard !summary.subject.isEmpty else { return verb.font(theme.font(size: 13)) }
        let subject = Text(summary.subject)
            .font(summary.monospacedSubject ? theme.font(size: 12.5, design: .monospaced) : theme.font(size: 13))
            .foregroundStyle(theme.textPrimary)
        return Text("\(verb) \(subject)").font(theme.font(size: 13))
    }

    @ViewBuilder private var detail: some View {
        let name = tool.name.lowercased()
        if let diff = tool.diff, !diff.isEmpty {
            ToolDetailBox(title: Format.relativePath(tool.title, base: baseDirectory)) {
                DiffView(diff: diff)
            }
        } else if ["bash", "shell", "run", "command"].contains(name) {
            ToolDetailBox(title: nil) {
                VStack(alignment: .leading, spacing: theme.z(8)) {
                    Text("$ \(tool.title)")
                        .font(theme.font(size: 12.5, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableText()
                    if let output = tool.outputPreview, !output.isEmpty {
                        OutputText(text: output)
                    }
                }
                .padding(theme.z(12))
            }
        } else {
            VStack(alignment: .leading, spacing: theme.z(8)) {
                if !["read", "grep", "glob", "list"].contains(name), tool.inputJSON != "{}" {
                    ToolDetailBox(title: "Input") {
                        OutputText(text: prettyJSON(tool.inputJSON))
                            .padding(theme.z(12))
                    }
                }
                if let output = tool.outputPreview, !output.isEmpty {
                    ToolDetailBox(title: name == "read" ? Format.relativePath(tool.title, base: baseDirectory) : "Output") {
                        OutputText(text: output)
                            .padding(theme.z(12))
                    }
                } else if tool.status == .running {
                    Text("Waiting for output")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }
}

/// Rounded box for expanded tool details, with an optional file or section title.
struct ToolDetailBox<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, theme.z(12))
                    .padding(.vertical, theme.z(7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HLine()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).fill(theme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: theme.z(9), style: .continuous))
    }
}

/// Monospaced tool output, trimmed to 14 lines until expanded (shown whole in the Verbose transcript view).
struct OutputText: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.transcriptViewMode) private var mode
    @State private var showAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = mode == .verbose ? Int.max : 14
        VStack(alignment: .leading, spacing: theme.z(6)) {
            Text(showAll || lines.count <= limit ? text : lines.prefix(limit).joined(separator: "\n"))
                .font(theme.font(size: 12, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(theme.z(2))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableText()
            if lines.count > limit, !showAll {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

/// A subagent started by a tool call. "Open" shows the child session.
public struct SubagentCardView: View {
    let tool: ToolCallInfo
    /// Inside an activity group: no card background or border of its own.
    var compact: Bool
    @Environment(\.theme) private var theme
    @Environment(\.transcriptActions) private var actions
    @State private var hovering = false

    public init(tool: ToolCallInfo, compact: Bool = false) {
        self.tool = tool
        self.compact = compact
    }

    public var body: some View {
        Button {
            if let child = tool.childSessionID { actions.openSession(child) }
        } label: {
            HStack(spacing: theme.z(10)) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.z(6), style: .continuous)
                        .fill(theme.accent.opacity(0.16))
                    Image(systemName: "person.2.fill")
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.accent)
                }
                .frame(width: theme.z(26), height: theme.z(26))

                VStack(alignment: .leading, spacing: theme.z(2)) {
                    Text("Subagent")
                        .font(theme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    Text(tool.title)
                        .font(theme.font(size: 13))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: theme.z(8))
                status
                if tool.childSessionID != nil {
                    HStack(spacing: theme.z(3)) {
                        Text("Open")
                        Image(systemName: "chevron.right").font(theme.font(size: 9, weight: .semibold))
                    }
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                }
            }
            .padding(.horizontal, compact ? 0 : theme.z(10))
            .padding(.vertical, compact ? 0 : theme.z(8))
            .background(
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .fill(compact ? .clear : (hovering ? theme.elevatedHover : theme.elevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.z(10), style: .continuous)
                    .strokeBorder(compact ? .clear : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tool.outputPreview ?? tool.title)
    }

    @ViewBuilder private var status: some View {
        switch tool.status {
        case .running, .pending:
            HStack(spacing: theme.z(5)) {
                Spinner(size: 10)
                Text("Running")
            }
            .font(theme.font(size: 12))
            .foregroundStyle(theme.textSecondary)
        case .succeeded:
            Label("Done", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textTertiary)
        case .failed:
            Label("Failed", systemImage: "xmark")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.danger)
        }
    }
}

/// The small "Checked" mark on a tool card the safety check for Auto allowed (the reason shows on hover), or
/// "Checking" while the check runs. Reads `SafetyCheckBadges.shared`, which the store's safety check fills.
struct SafetyCheckToolBadge: View {
    let toolCallID: String
    var badges: SafetyCheckBadges = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        if let decision = badges.decision(forToolCall: toolCallID) {
            label("Checked")
                .help(Self.help(decision))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Checked by the safety check")
                .accessibilityValue(decision.reason)
        } else if badges.isChecking(toolCallID) {
            label("Checking")
                .help("The safety check is deciding whether this can run without asking")
        }
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: theme.z(3)) {
            Image(systemName: "checkmark.shield")
                .font(theme.font(size: 10, weight: .medium))
            Text(text)
                .font(theme.font(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.textTertiary)
        .fixedSize()
        .padding(.horizontal, theme.z(7))
        .padding(.vertical, theme.z(2))
        .background(theme.hover, in: RoundedRectangle(cornerRadius: theme.z(6), style: .continuous))
    }

    /// "Allowed by the safety check: <reason> (<model>)".
    static func help(_ decision: SafetyCheckDecision) -> String {
        var text = "Allowed by the safety check: \(decision.reason)"
        if decision.basis == .cache { text += " (same as an earlier answer in this session)" }
        if let model = decision.model { text += "\nModel: \(model.description)" }
        return text
    }
}
