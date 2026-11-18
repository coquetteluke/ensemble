import SwiftUI
import EnsembleKit

/// In the line under the composer, for sessions in a git repository: the "Work in a copy (git worktree)" switch (before
/// the first message) and the branch chip. In a copy, the chip switches the copy to another local branch while the
/// session is idle, asking first when the copy has uncommitted changes.
struct WorktreeStatusControls: View {
    let store: SessionStore
    let session: SessionModel
    @Bindable var window: WindowState
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showBranches = false
    @State private var pendingSwitch: PendingSwitch?

    struct PendingSwitch: Identifiable {
        let branch: String
        let changes: [String]
        var id: String { branch }
    }

    var body: some View {
        let inCopy = store.isInWorktree(session.id)
        let folder = store.projectFolder(for: session)
        let availability = store.worktrees.availability[folder]
        let showsSwitch = !hasMessages && !session.isSubagent && (inCopy || (availability != nil && availability != Self.notRepository))
        WorktreeControlsRow(
            showsSwitch: showsSwitch,
            isOn: inCopy,
            switchUnavailableReason: store.worktreeSwitchUnavailableReason(session.id),
            busy: store.worktrees.busy.contains(session.id),
            branch: store.worktrees.currentBranch[session.id],
            inCopy: inCopy,
            copyPath: store.worktree(for: session.id)?.path ?? (inCopy ? session.directory : nil),
            branchUnavailableReason: store.branchSwitchUnavailableReason(session.id),
            showBranches: $showBranches,
            onToggle: toggle,
            branchMenu: {
                BranchMenuContent(branches: store.worktrees.branches[session.id] ?? [],
                                  current: store.worktrees.currentBranch[session.id]) { branch in
                    showBranches = false
                    pick(branch)
                }
                .ensembleTheme()
            })
        .task(id: session.id) {
            guard !isSnapshot else { return }
            await store.checkWorktreeAvailability(folder)
            await store.loadBranches(for: session.id)
        }
        // The agent can change branches itself; read it again after each turn.
        .onChange(of: session.isWorking) {
            guard !session.isWorking, !isSnapshot else { return }
            Task { await store.loadBranches(for: session.id) }
        }
        .onChange(of: showBranches) {
            if showBranches { Task { await store.loadBranches(for: session.id) } }
        }
        .confirmationDialog(pendingSwitch.map { "Switch the copy to \($0.branch)?" } ?? "",
                            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
                            presenting: pendingSwitch) { pending in
            Button("Switch to \(pending.branch)") { run(pending.branch) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(Self.uncommittedMessage(pending))
        }
    }

    static let notRepository = "Not a git repository"

    private var hasMessages: Bool {
        session.items.contains { if case .user = $0 { true } else { false } }
    }

    static func uncommittedMessage(_ pending: PendingSwitch) -> String {
        let count = pending.changes.count == 1 ? "1 file" : "\(pending.changes.count) files"
        let list = pending.changes.prefix(4).joined(separator: ", ") + (pending.changes.count > 4 ? " and \(pending.changes.count - 4) more" : "")
        return "The copy has uncommitted changes in \(count) (\(list)). They come along to \(pending.branch). If they conflict with it, git stops and nothing changes."
    }

    private func toggle(_ on: Bool) {
        let oldID = session.id
        Task {
            if let replacement = await store.setWorkInCopy(on, for: oldID) {
                window.drafts[replacement.id] = window.drafts[oldID]
                window.attachments[replacement.id] = window.attachments[oldID]
                window.drafts[oldID] = nil
                window.attachments[oldID] = nil
                window.open(replacement.id, store: store)
            } else if let error = store.worktrees.errors[oldID] {
                store.lastError = error
            }
        }
    }

    private func pick(_ branch: String) {
        Task {
            let changes = await store.uncommittedChanges(in: session.id)
            if changes.isEmpty {
                run(branch)
            } else {
                pendingSwitch = PendingSwitch(branch: branch, changes: changes)
            }
        }
    }

    private func run(_ branch: String) {
        let id = session.id
        Task {
            if !(await store.switchBranch(branch, for: id)), let error = store.worktrees.errors[id] {
                store.lastError = error
            }
        }
    }
}

/// The switch and the branch chip, drawn from plain values (snapshots use it directly).
struct WorktreeControlsRow<Menu: View>: View {
    let showsSwitch: Bool
    let isOn: Bool
    let switchUnavailableReason: String?
    let busy: Bool
    let branch: String?
    let inCopy: Bool
    let copyPath: String?
    let branchUnavailableReason: String?
    @Binding var showBranches: Bool
    let onToggle: (Bool) -> Void
    @ViewBuilder let branchMenu: () -> Menu
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.z(10)) {
            if showsSwitch { workInCopySwitch }
            if let branch { branchChip(branch) }
        }
    }

    private var workInCopySwitch: some View {
        HStack(spacing: theme.z(6)) {
            Toggle(isOn: Binding(get: { isOn }, set: { onToggle($0) })) {
                HStack(spacing: theme.z(4)) {
                    Text("Work in a copy")
                        .foregroundStyle(switchUnavailableReason == nil ? theme.textSecondary : theme.textTertiary)
                    Text("(git worktree)")
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .toggleStyle(CompactSwitchStyle())
            .fixedSize()
            .disabled(switchUnavailableReason != nil || busy)
            .opacity(switchUnavailableReason == nil ? 1 : 0.6)
            if busy { Spinner(size: 9) }
        }
        .help(switchUnavailableReason ?? (isOn ? "This session works in its own git worktree, on its own branch. Turn off to work in the project folder"
            : "Runs this session in its own git worktree on a new branch, so other sessions in this project keep their own files"))
        .accessibilityLabel("Work in a copy (git worktree)")
    }

    @ViewBuilder private func branchChip(_ branch: String) -> some View {
        let switchable = branchUnavailableReason == nil
        Button {
            if switchable { showBranches.toggle() }
        } label: {
            HStack(spacing: theme.z(4)) {
                Image(systemName: inCopy ? "square.on.square" : "arrow.triangle.branch")
                    .font(theme.font(size: 10))
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: theme.z(160), alignment: .leading)
                if switchable {
                    Image(systemName: "chevron.down")
                        .font(theme.font(size: 7, weight: .bold))
                        .opacity(0.7)
                }
            }
            .fixedSize()
            .padding(.horizontal, theme.z(6))
            .frame(height: theme.z(20))
            .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(inCopy ? theme.accent.opacity(0.12) : .clear))
            .foregroundStyle(inCopy ? theme.accent : theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chipHelp(branch))
        .accessibilityLabel("Branch \(branch)")
        .popover(isPresented: $showBranches, arrowEdge: .top) { branchMenu() }
    }

    private func chipHelp(_ branch: String) -> String {
        if inCopy, let copyPath {
            let base = "Works in its own copy on \(branch): \(Format.abbreviatedPath(copyPath))"
            return branchUnavailableReason.map { "\(base). \($0)" } ?? "\(base). Click to switch branches"
        }
        return "This folder is on \(branch). \(branchUnavailableReason ?? "")"
    }
}

/// The branch picker: local branches, the current one ticked, ones checked out elsewhere greyed with where.
struct BranchMenuContent: View {
    let branches: [SessionBranch]
    let current: String?
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(2)) {
            Text("Switch the copy to")
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, theme.z(10))
                .padding(.top, theme.z(4))
                .padding(.bottom, theme.z(2))
            if branches.isEmpty {
                Text("No other local branches")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, theme.z(10))
                    .frame(height: theme.z(28))
            }
            if branches.count <= 9 {
                list
            } else {
                AdaptiveScroll { list }
                    .frame(height: theme.z(280))
            }
        }
        .padding(theme.z(6))
        .frame(width: theme.z(280))
        .background(theme.popover)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(branches) { branch in
                row(branch)
            }
        }
    }

    private func row(_ branch: SessionBranch) -> some View {
        let enabled = !branch.isCurrent && branch.checkedOutAt == nil
        return Button {
            if enabled { onPick(branch.name) }
        } label: {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "checkmark")
                    .font(theme.font(size: 10, weight: .semibold))
                    .opacity(branch.isCurrent ? 1 : 0)
                    .frame(width: theme.z(12))
                VStack(alignment: .leading, spacing: theme.z(1)) {
                    Text(branch.name)
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(enabled || branch.isCurrent ? theme.textPrimary : theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let elsewhere = branch.checkedOutAt {
                        Text("Checked out in \(Format.folderName(elsewhere))")
                            .font(theme.font(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.z(8))
            .padding(.vertical, theme.z(5))
            .frame(minHeight: theme.z(28))
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!enabled)
        .help(branch.checkedOutAt.map { "Git allows a branch in one checkout at a time. It is checked out in \($0)" }
            ?? (branch.isCurrent ? "The copy is on this branch" : "Check out \(branch.name) in this copy"))
    }
}
