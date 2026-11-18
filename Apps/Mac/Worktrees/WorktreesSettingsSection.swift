import SwiftUI
import EnsembleKit

/// Settings > General > Worktrees: the copies Ensemble made for sessions that work in their own git worktree, and the
/// copies Team rooms made for their agents, with size and last use, Remove (asking first, and naming uncommitted
/// changes; a room's copies only once the room is finished) and Remove unused. For a grouped `Form`.
struct WorktreesSettingsSection: View {
    let store: SessionStore
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var confirmRemove: SessionWorktreeStatus?
    @State private var confirmUnused = false
    @State private var result: String?

    var body: some View {
        Section {
            if !store.worktrees.listLoaded {
                HStack(spacing: theme.z(8)) {
                    Spinner(size: 10)
                    Text("Reading copies")
                        .foregroundStyle(theme.textSecondary)
                }
            } else if store.worktrees.statuses.isEmpty {
                Text("No session copies")
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(store.worktrees.statuses) { status in
                    WorktreeRow(status: status, lastUse: store.lastUse(of: status.record),
                                sessionTitle: store.sessionTitle(for: status.record), unused: store.isUnused(status.record),
                                busy: store.worktrees.busy.contains(status.id),
                                removeUnavailableReason: store.removeWorktreeUnavailableReason(status.record),
                                error: store.worktrees.errors[status.id]) {
                        confirmRemove = status
                    }
                }
            }
            HStack(spacing: theme.z(8)) {
                if let result {
                    Text(result)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
                Button("Remove Unused\u{2026}") { confirmUnused = true }
                    .disabled(unused.isEmpty)
                    .help(unused.isEmpty ? "No copy is unused: each belongs to a session you still have or a room still running"
                          : "Removes copies whose session is gone or archived, and copies of finished rooms. Copies with uncommitted changes stay")
            }
        } header: {
            Text("Worktrees")
        } footer: {
            Text("Copies of a project that sessions and Team room agents work in, in .ensemble/worktrees inside the project folder. A copy is unused once its session is deleted or archived, or its room is finished.")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
        }
        .task {
            guard !isSnapshot else { return }
            await store.refreshWorktreeList()
        }
        .confirmationDialog(confirmRemove.map(Self.removeTitle) ?? "",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { status in
            Button(status.changedFiles.isEmpty ? "Remove Copy" : "Remove Copy and Changes", role: .destructive) {
                Task {
                    await store.removeWorktree(status.id, force: !status.changedFiles.isEmpty)
                    await store.refreshWorktreeList()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { status in
            Text(Self.removeMessage(status))
        }
        .confirmationDialog(unused.count == 1 ? "Remove 1 unused copy?" : "Remove \(unused.count) unused copies?",
                            isPresented: $confirmUnused) {
            Button("Remove Unused", role: .destructive) {
                Task {
                    let outcome = await store.removeUnusedWorktrees()
                    result = Self.unusedResult(outcome)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.unusedMessage(unused))
        }
    }

    private var unused: [SessionWorktreeStatus] {
        store.worktrees.statuses.filter { store.isUnused($0.record) && store.removeWorktreeUnavailableReason($0.record) == nil }
    }

    static func removeTitle(_ status: SessionWorktreeStatus) -> String {
        status.changedFiles.isEmpty ? "Remove this copy?" : "Remove this copy and its uncommitted changes?"
    }

    static func removeMessage(_ status: SessionWorktreeStatus) -> String {
        let branch = status.branch ?? status.record.branch
        let keep = "The branch \(branch) is deleted too, unless it has commits that are not merged."
        guard !status.changedFiles.isEmpty else { return keep }
        let count = status.changedFiles.count == 1 ? "1 file" : "\(status.changedFiles.count) files"
        let names = status.changedFiles.prefix(6).joined(separator: ", ")
            + (status.changedFiles.count > 6 ? " and \(status.changedFiles.count - 6) more" : "")
        return "Uncommitted changes in \(count) are lost: \(names). \(keep)"
    }

    static func unusedMessage(_ list: [SessionWorktreeStatus]) -> String {
        let withChanges = list.filter { !$0.changedFiles.isEmpty }.count
        let base = "Removes copies whose session is gone or archived, and copies of finished rooms."
        guard withChanges > 0 else { return base }
        return base + (withChanges == 1 ? " 1 of them has uncommitted changes and stays." : " \(withChanges) of them have uncommitted changes and stay.")
    }

    static func unusedResult(_ outcome: (removed: Int, kept: Int)) -> String {
        let removed = outcome.removed == 1 ? "Removed 1 copy" : "Removed \(outcome.removed) copies"
        guard outcome.kept > 0 else { return removed }
        return removed + (outcome.kept == 1 ? ", kept 1 with uncommitted changes" : ", kept \(outcome.kept) with uncommitted changes")
    }
}

/// One copy: its project, branch, session, size, last use and uncommitted changes, with Remove.
struct WorktreeRow: View {
    let status: SessionWorktreeStatus
    let lastUse: Date
    let sessionTitle: String?
    let unused: Bool
    let busy: Bool
    let removeUnavailableReason: String?
    let error: String?
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(4)) {
            HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                Image(systemName: status.record.room == nil ? "square.on.square" : "person.2")
                    .foregroundStyle(theme.textSecondary)
                VStack(alignment: .leading, spacing: theme.z(3)) {
                    HStack(spacing: theme.z(6)) {
                        Text(Format.folderName(status.record.home))
                            .font(theme.font(size: 13, weight: .medium))
                        Text(status.branch ?? status.record.branch)
                            .font(theme.font(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(details)
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !status.changedFiles.isEmpty {
                        Text(status.changedFiles.count == 1 ? "1 uncommitted change" : "\(status.changedFiles.count) uncommitted changes")
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.warning)
                            .help(status.changedFiles.prefix(20).joined(separator: "\n"))
                    }
                }
                Spacer(minLength: theme.z(8))
                if busy {
                    Spinner(size: 10)
                } else {
                    Button("Remove", action: onRemove)
                        .disabled(removeUnavailableReason != nil)
                        .help(removeUnavailableReason ?? "Remove this copy from disk")
                }
            }
            if let error {
                Text(error)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(status.record.path)
    }

    private var details: String {
        var parts: [String] = []
        if !status.exists {
            parts.append("Folder is gone")
        } else if let size = status.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        let relative = Format.relative(lastUse)
        parts.append(relative == "now" ? "used just now" : "used \(relative) ago")
        if let room = status.record.room {
            let agent = room.agentName.map { ", \($0)" } ?? ""
            parts.append("Room \(room.roomTitle)\(agent)" + (room.finished ? " (finished)" : ""))
        } else if let sessionTitle {
            parts.append(unused ? "\(sessionTitle) (archived)" : sessionTitle)
        } else {
            parts.append("session deleted")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
