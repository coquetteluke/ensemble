import SwiftUI
import EnsembleKit

/// The list of changed files at the top of the pane. Clicking a file jumps to its diff.
struct ReviewFileList: View {
    @Bindable var model: ReviewModel
    let open: (ReviewFileDiff) -> Void
    @Environment(\.theme) private var theme

    static let collapsedCount = 8

    var body: some View {
        let files = model.files
        let shown = model.showAllFiles ? files : Array(files.prefix(Self.collapsedCount))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text(files.count == 1 ? "1 file changed" : "\(files.count) files changed")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if model.isGit, !model.uncommittedFiles.isEmpty {
                    if model.stagedFiles.count == model.uncommittedFiles.count {
                        smallButton("Unstage all") { Task { await model.unstageAll() } }
                    } else {
                        smallButton("Stage all") { Task { await model.stageAll() } }
                    }
                }
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(30))
            ForEach(shown) { file in
                ReviewFileRow(model: model, file: file) { open(file) }
            }
            if files.count > Self.collapsedCount {
                Button(model.showAllFiles ? "Show fewer files" : "Show all \(files.count) files") { model.showAllFiles.toggle() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.z(14))
                    .frame(height: theme.z(26))
            }
        }
        .padding(.vertical, theme.z(4))
        .overlay(alignment: .bottom) { HLine() }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(theme.font(size: 12))
            .foregroundStyle(theme.accent)
    }
}

/// One file in the list: stage box, icon, name and folder, agent, counts, discard on hover.
struct ReviewFileRow: View {
    @Bindable var model: ReviewModel
    let file: ReviewFileDiff
    let open: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            StageBox(model: model, file: file)
            Button(action: open) {
                HStack(spacing: theme.z(7)) {
                    Glyph(Glyph.kind(forPath: file.path), size: 15)
                    ReviewPathText(file: file, size: 12.5)
                    Spacer(minLength: theme.z(4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.oldPath.map { "\($0) to \(file.path)" } ?? file.path)
            if let agent = model.agent(file.agentID), model.focusedAgentID == nil {
                ReviewAgentChip(agent: agent)
            }
            ReviewKindTag(file: file)
            if hovering, file.stage.hasUncommittedChanges, model.isGit {
                IconButton("arrow.uturn.backward", help: "Discard changes to \(file.fileName)", size: 20) {
                    model.confirmDiscard(file)
                }
            }
            if file.isBinary {
                Text("binary")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ReviewCounts(additions: file.additions, deletions: file.deletions)
            }
        }
        .padding(.horizontal, theme.z(14))
        .frame(height: theme.z(26))
        .background(hovering ? theme.hover : .clear)
        .onHover { hovering = $0 }
        .opacity(model.busyFiles.contains(file.id) ? 0.55 : 1)
    }
}

/// File name in the primary colour and its folder after it, dimmed; renames show the old name.
struct ReviewPathText: View {
    let file: ReviewFileDiff
    var size: CGFloat = 12.5
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(6)) {
            Text(file.fileName)
                .font(theme.font(size: size, weight: .medium))
                .foregroundStyle(file.kind == .deleted ? theme.textSecondary : theme.textPrimary)
                .strikethrough(file.kind == .deleted, color: theme.textTertiary)
                .lineLimit(1)
                .layoutPriority(1)
            if !file.directoryPart.isEmpty {
                Text(file.directoryPart)
                    .font(theme.font(size: size - 1))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

/// A checkbox for "staged": empty, partly staged (dash) or fully staged (tick). Hidden when the file has
/// nothing left to commit; committed files say so.
struct StageBox: View {
    @Bindable var model: ReviewModel
    let file: ReviewFileDiff
    @Environment(\.theme) private var theme

    var body: some View {
        let size = theme.z(14)
        if model.isGit, file.stage.hasUncommittedChanges {
            Button {
                Task { await model.toggleStage(file) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.z(3.5), style: .continuous)
                        .fill(filled ? theme.accent : Color.clear)
                    RoundedRectangle(cornerRadius: theme.z(3.5), style: .continuous)
                        .strokeBorder(filled ? theme.accent : theme.textTertiary.opacity(0.8), lineWidth: theme.z(1.2))
                    if file.stage == .staged {
                        Image(systemName: "checkmark")
                            .font(theme.font(size: 8.5, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                    } else if file.stage == .partial {
                        Image(systemName: "minus")
                            .font(theme.font(size: 8.5, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busyFiles.contains(file.id))
            .help(help)
            .accessibilityLabel(help)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private var filled: Bool { file.stage == .staged || file.stage == .partial }

    private var help: String {
        switch file.stage {
        case .staged: "Unstage \(file.fileName)"
        case .partial: "Stage the rest of \(file.fileName)"
        default: "Stage \(file.fileName)"
        }
    }
}

/// "New", "Deleted", "Renamed", "Committed" or "Conflict"; nothing for a plain change.
struct ReviewKindTag: View {
    let file: ReviewFileDiff
    @Environment(\.theme) private var theme

    var body: some View {
        if let (text, color) = tag {
            Text(text)
                .font(theme.font(size: 10.5, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, theme.z(5))
                .frame(height: theme.z(16))
                .background(Capsule().fill(color.opacity(0.12)))
        }
    }

    private var tag: (String, Color)? {
        if file.stage == .conflicted { return ("Conflict", theme.danger) }
        if file.stage == .committed { return ("Committed", theme.textTertiary) }
        switch file.kind {
        case .added: return ("New", theme.diffAddText)
        case .deleted: return ("Deleted", theme.diffRemoveText)
        case .renamed: return ("Renamed", theme.accent)
        case .modified: return nil
        }
    }
}

/// An agent's colour dot and name.
struct ReviewAgentChip: View {
    let agent: ReviewAgentSource
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(4)) {
            StatusDot(Color(hexString: agent.colorHex), size: 6)
            Text(agent.name)
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
    }
}

/// One file's diff: a header row (collapse, name, tags, stage, discard) and the diff with comments.
struct ReviewFileSection: View {
    @Bindable var model: ReviewModel
    let file: ReviewFileDiff
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    var body: some View {
        let collapsed = model.collapsed.contains(file.id)
        VStack(alignment: .leading, spacing: 0) {
            header(collapsed: collapsed)
            if !collapsed {
                HLine()
                bodyContent
            }
        }
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border))
        .padding(.horizontal, theme.z(10))
        .padding(.top, theme.z(10))
        .opacity(model.busyFiles.contains(file.id) ? 0.6 : 1)
    }

    private func header(collapsed: Bool) -> some View {
        HStack(spacing: theme.z(8)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if collapsed { model.collapsed.remove(file.id) } else { model.collapsed.insert(file.id) }
                }
            } label: {
                HStack(spacing: theme.z(7)) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(theme.font(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(10))
                    VStack(alignment: .leading, spacing: theme.z(1)) {
                        ReviewPathText(file: file, size: 12.5)
                        if let oldPath = file.oldPath {
                            Text("from \(oldPath)")
                                .font(theme.font(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: theme.z(4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the diff" : "Hide the diff")
            if let agent = model.agent(file.agentID), model.focusedAgentID == nil {
                ReviewAgentChip(agent: agent)
            }
            ReviewKindTag(file: file)
            if file.stage.hasUncommittedChanges, model.isGit {
                IconButton("arrow.uturn.backward", help: "Discard changes to \(file.fileName)", size: 22) {
                    model.confirmDiscard(file)
                }
                .opacity(hovering || isSnapshot ? 1 : 0.55)
            }
            if !file.isBinary {
                ReviewCounts(additions: file.additions, deletions: file.deletions)
            }
            StageBox(model: model, file: file)
        }
        .padding(.leading, theme.z(10))
        .padding(.trailing, theme.z(10))
        .padding(.vertical, theme.z(6))
        .frame(minHeight: theme.z(36))
        .background(theme.elevated)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var bodyContent: some View {
        let parsed = model.parsed[file.id] ?? ParsedDiff(file.patch)
        if file.isBinary {
            note("Binary file, not shown")
        } else if parsed.lines.isEmpty {
            note(file.kind == .renamed ? "Renamed, content unchanged" : (file.patch.isEmpty ? "No diff to show" : "Only the file mode changed"))
        } else {
            DiffView(parsed: parsed, options: options, interaction: interaction)
                .padding(.bottom, theme.z(2))
        }
    }

    private var options: DiffDisplayOptions {
        DiffDisplayOptions(wrapLines: true, showGaps: file.fromGit, newLineCount: model.lineCounts[file.id], maxLines: 400,
                           hoveredLine: isSnapshot ? snapshotHoveredLine : nil)
    }

    /// Snapshots draw the gutter button on the first added line without a comment.
    private var snapshotHoveredLine: Int? {
        guard let parsed = model.parsed[file.id] else { return nil }
        return parsed.lines.indices.first { index in
            let line = parsed.lines[index]
            guard line.kind == .addition, let number = line.newNumber else { return false }
            return model.comments(at: ReviewLineKey(fileID: file.id, side: .new, line: number)).isEmpty
                && model.draft?.key != ReviewLineKey(fileID: file.id, side: .new, line: number)
        }
    }

    private var interaction: DiffInteraction {
        let model = model
        let file = file
        let tap: @MainActor (DiffLine) -> Void = { line in model.beginComment(file: file, line: line) }
        let comments: @MainActor (DiffLine) -> AnyView? = { line in
            guard let key = Self.key(for: line, file: file) else { return nil }
            let list = model.comments(at: key)
            let editing = model.draft?.key == key
            guard !list.isEmpty || editing else { return nil }
            return AnyView(ReviewLineComments(model: model, key: key, comments: list))
        }
        let hunk: @MainActor (Int) -> AnyView? = { index in
            guard let action = file.hunkActions[index], model.isGit else { return nil }
            return AnyView(ReviewHunkButton(model: model, file: file, action: action))
        }
        var load: (@MainActor () -> [String]?)?
        if file.fromGit, file.kind != .deleted {
            let path = file.absolutePath
            load = { ReviewModel.readLines(path) }
        }
        return DiffInteraction(onGutterTap: tap, lineAccessory: comments, hunkAccessory: hunk, loadNewText: load)
    }

    static func key(for line: DiffLine, file: ReviewFileDiff) -> ReviewLineKey? {
        switch line.kind {
        case .deletion: line.oldNumber.map { ReviewLineKey(fileID: file.id, side: .old, line: $0) }
        case .addition, .context: line.newNumber.map { ReviewLineKey(fileID: file.id, side: .new, line: $0) }
        case .hunk: nil
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 12))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, theme.z(14))
            .padding(.vertical, theme.z(12))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Stage hunk" or "Unstage hunk" at the end of a hunk header.
struct ReviewHunkButton: View {
    @Bindable var model: ReviewModel
    let file: ReviewFileDiff
    let action: ReviewHunkAction
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action.kind == .stage ? "Stage hunk" : "Unstage hunk") {
            Task { await model.applyHunk(action, in: file) }
        }
        .buttonStyle(.plain)
        .font(theme.font(size: 11, weight: .medium))
        .foregroundStyle(action.kind == .stage ? theme.accent : theme.textSecondary)
        .disabled(model.busyFiles.contains(file.id))
        .help(action.kind == .stage ? "Stage only this hunk" : "Take only this hunk out of the index")
    }
}
