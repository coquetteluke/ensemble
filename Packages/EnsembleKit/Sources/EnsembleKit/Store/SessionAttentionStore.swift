import Foundation

extension SessionStore {
    /// One attention snapshot per top-level, non-archived session, with its subagents folded in.
    /// Reads only sessions, activity, prompts and titles (not transcripts), so observers of it are not
    /// woken by streaming text.
    public func attentionSnapshots() -> [SessionAttentionSnapshot] {
        var children: [String: [SessionModel]] = [:]
        for session in sessions {
            if let parent = session.info.parentID { children[parent, default: []].append(session) }
        }
        func family(of root: SessionModel) -> [SessionModel] {
            var result = [root]
            var seen: Set<String> = [root.id]
            var index = 0
            while index < result.count {
                for child in children[result[index].id] ?? [] where seen.insert(child.id).inserted {
                    result.append(child)
                }
                index += 1
            }
            return result
        }
        return sessions.filter { $0.info.parentID == nil && !$0.info.archived }.map { root in
            let members = family(of: root)
            let prompts = members.flatMap(\.pendingPermissions).sorted { ($0.created, $0.id) < ($1.created, $1.id) }
            return SessionAttentionSnapshot(
                id: root.id,
                title: root.title,
                directory: root.directory,
                prompts: prompts,
                active: members.contains { $0.isWorking },
                working: prompts.isEmpty && members.contains { $0.activity == .working },
                failed: root.activity == .failed)
        }
    }

    /// Sidebar entries for every top-level, non-archived session, with the user's marks applied.
    public func sidebarEntries(marks: SessionAttentionMarks) -> [SidebarEntry] {
        sidebarEntries(snapshots: attentionSnapshots(), marks: marks)
    }

    public func sidebarEntries(snapshots: [SessionAttentionSnapshot], marks: SessionAttentionMarks) -> [SidebarEntry] {
        snapshots.compactMap { snapshot in
            guard let session = session(snapshot.id) else { return nil }
            let status = SidebarRowStatus.resolve(prompts: snapshot.prompts.count, running: snapshot.active,
                                                  failed: snapshot.failed, unread: marks.isUnread(snapshot.id),
                                                  completed: marks.isCompleted(snapshot.id))
            return SidebarEntry(id: snapshot.id, title: snapshot.title, directory: snapshot.directory,
                                created: session.info.created, updated: session.info.updated,
                                status: status, pinned: marks.isPinned(snapshot.id))
        }
    }

    /// The newest agent text in a session, for a "finished" alert.
    public func lastAgentText(_ sessionID: String) -> String? {
        guard let session = session(sessionID) else { return nil }
        for item in session.items.reversed() {
            if case .agentText(_, let text, _, _) = item, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// The newest error row in a session, for a "failed" alert.
    public func lastErrorText(_ sessionID: String) -> String? {
        guard let session = session(sessionID) else { return nil }
        for item in session.items.reversed() {
            if case .error(_, let message) = item { return message }
            if case .user = item { return nil }
        }
        return nil
    }
}
