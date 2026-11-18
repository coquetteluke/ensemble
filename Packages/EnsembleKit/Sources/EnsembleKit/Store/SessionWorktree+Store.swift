import Foundation

/// "Work in a copy": per-session git worktrees (`SessionWorktreeModels.swift`), the branch picker and Settings' list.
extension SessionStore {
    // MARK: Queries

    /// The copy a session runs in, or nil.
    public func worktree(for sessionID: String) -> SessionWorktreeRecord? {
        worktrees.loadIfNeeded()
        return worktrees.record(forSession: sessionID)
    }

    /// True when the session runs in a copy (one Ensemble saved, or a folder inside one).
    public func isInWorktree(_ sessionID: String) -> Bool {
        guard let session = byID[sessionID] else { return false }
        return worktree(for: sessionID) != nil || SessionWorktreePaths.isInCopy(session.directory)
    }

    /// The project folder a session belongs to (the folder its copy was made from, for a session in a copy).
    public func projectFolder(for session: SessionModel) -> String {
        worktree(for: session.id)?.home ?? SessionWorktreePaths.projectFolder(for: session.directory)
    }

    /// Why the switch is off and cannot be turned on for this session, or nil when it can change. The copy is chosen
    /// when a session starts, so it can change only before the first message.
    public func worktreeSwitchUnavailableReason(_ sessionID: String) -> String? {
        guard let session = byID[sessionID] else { return "No session" }
        if session.isSubagent { return "A subagent works where its parent does" }
        if session.items.contains(where: { if case .user = $0 { true } else { false } }) {
            return isInWorktree(sessionID) ? "This session works in its copy. The copy is set before the first message"
                : "Set before the first message. Start a new session to work in a copy"
        }
        if session.isWorking { return RewindReason.working }
        if worktrees.busy.contains(sessionID) { return "Working on it" }
        if isInWorktree(sessionID) { return nil }
        let folder = projectFolder(for: session)
        guard let reason = worktrees.availability[folder] else { return "Checking the folder" }
        return reason.isEmpty ? nil : reason
    }

    /// Reads whether a folder can get a copy (git repository, trusted, has a commit), for the switch.
    public func checkWorktreeAvailability(_ folder: String) async {
        let reason = await worktrees.git.unavailableReason(folder) ?? ""
        worktrees.availability[folder] = reason
    }

    // MARK: Starting in a copy

    /// Creates a session, in its own copy when `inWorktree` (made first; removed again if the session cannot start).
    @discardableResult
    public func newSession(directory: String, model: ModelRef?, permissionMode: PermissionMode,
                           inWorktree: Bool) async throws -> SessionModel {
        guard inWorktree else { return try await newSession(directory: directory, model: model, permissionMode: permissionMode) }
        worktrees.loadIfNeeded()
        let record = try await worktrees.git.create(home: directory)
        do {
            let session = try await newSession(directory: record.sessionDirectory, model: model, permissionMode: permissionMode)
            var attached = record
            attached.sessionID = session.id
            worktrees.upsert(attached)
            return session
        } catch {
            #if os(macOS)
            try? await worktrees.git.remove(record, force: true)
            #endif
            throw error
        }
    }

    /// The composer's switch, before the first message: starts the session over in a new copy (on) or back in the
    /// project folder (off), with the same model and mode, and deletes the empty session it replaces. Returns the new
    /// session (the composer moves its draft over), or nil when nothing changed.
    @discardableResult
    public func setWorkInCopy(_ on: Bool, for sessionID: String) async -> SessionModel? {
        guard let session = byID[sessionID], on != isInWorktree(sessionID) else { return nil }
        if let reason = worktreeSwitchUnavailableReason(sessionID) {
            worktrees.errors[sessionID] = reason
            return nil
        }
        worktrees.busy.insert(sessionID)
        defer { worktrees.busy.remove(sessionID) }
        worktrees.errors[sessionID] = nil
        let model = session.info.model
        let mode = session.permissionMode
        let old = worktree(for: sessionID)
        do {
            let replacement = try await newSession(directory: projectFolder(for: session), model: model, permissionMode: mode,
                                                   inWorktree: on)
            if let effort = session.effort { await setEffort(effort, for: replacement.id) }
            if session.fastMode { await setFastMode(true, for: replacement.id) }
            await delete(sessionID)
            if let old {
                // The copy was made for this empty session moments ago; it goes too, unless something was written there.
                #if os(macOS)
                if (try? await worktrees.git.remove(old, force: false)) != nil { worktrees.remove(old.id) } else {
                    var kept = old
                    kept.sessionID = nil
                    worktrees.upsert(kept)
                }
                #endif
            }
            return replacement
        } catch {
            worktrees.errors[sessionID] = "Could not \(on ? "make a copy" : "move back to the project folder"): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Branch picker

    /// Reads the session folder's branch and, for a session in a copy, the local branches it can switch to.
    public func loadBranches(for sessionID: String) async {
        guard let session = byID[sessionID] else { return }
        let directory = session.directory
        if let branch = await worktrees.git.currentBranch(directory) {
            worktrees.currentBranch[sessionID] = branch
        } else {
            worktrees.currentBranch[sessionID] = nil
        }
        #if os(macOS)
        guard isInWorktree(sessionID) else { return }
        if let list = try? await worktrees.git.branches(directory) { worktrees.branches[sessionID] = list }
        #endif
    }

    /// Why branches cannot be switched for this session now, or nil.
    public func branchSwitchUnavailableReason(_ sessionID: String) -> String? {
        guard let session = byID[sessionID] else { return "No session" }
        guard isInWorktree(sessionID) else { return "Turn on Work in a copy to switch branches for one session" }
        if session.isWorking { return "Unavailable while the agent is working" }
        if worktrees.busy.contains(sessionID) { return "Working on it" }
        return nil
    }

    /// Files with uncommitted changes in the session's copy (asked before switching branches).
    public func uncommittedChanges(in sessionID: String) async -> [String] {
        #if os(macOS)
        guard let session = byID[sessionID] else { return [] }
        return (try? await worktrees.git.uncommittedChanges(session.directory)) ?? []
        #else
        return []
        #endif
    }

    /// Checks out another local branch in the session's copy, while the session is idle.
    @discardableResult
    public func switchBranch(_ branch: String, for sessionID: String) async -> Bool {
        #if os(macOS)
        guard let session = byID[sessionID] else { return false }
        if let reason = branchSwitchUnavailableReason(sessionID) {
            worktrees.errors[sessionID] = reason
            return false
        }
        worktrees.busy.insert(sessionID)
        defer { worktrees.busy.remove(sessionID) }
        do {
            try await worktrees.git.switchBranch(session.directory, to: branch)
            worktrees.errors[sessionID] = nil
            touchWorktree(sessionID)
            await loadBranches(for: sessionID)
            await refreshPanels(sessionID)
            return true
        } catch {
            worktrees.errors[sessionID] = "Could not switch to \(branch): \(error.localizedDescription)"
            await loadBranches(for: sessionID)
            return false
        }
        #else
        return false
        #endif
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func touchWorktree(_ sessionID: String) {
        guard var record = worktree(for: sessionID) else { return }
        record.lastUsed = Date()
        worktrees.upsert(record)
    }

    // MARK: Settings list

    /// When a copy was last used: its session's newest activity, or when Ensemble last touched it.
    public func lastUse(of record: SessionWorktreeRecord) -> Date {
        guard let id = record.sessionID, let session = byID[id] else { return record.lastUsed }
        return max(record.lastUsed, session.info.updated)
    }

    /// The session title for a copy, when the session still exists.
    public func sessionTitle(for record: SessionWorktreeRecord) -> String? {
        record.sessionID.flatMap { byID[$0]?.title }
    }

    /// True for a copy whose session is gone or archived, or a room copy whose room is finished. "Remove unused"
    /// removes these when they hold no uncommitted changes.
    public func isUnused(_ record: SessionWorktreeRecord) -> Bool {
        if let room = record.room { return room.finished }
        guard let id = record.sessionID, let session = byID[id] else { return true }
        return session.info.archived
    }

    /// Why a copy cannot be removed now, or nil. A room's copies stay until the room is finished.
    public func removeWorktreeUnavailableReason(_ record: SessionWorktreeRecord) -> String? {
        if worktrees.busy.contains(record.id) { return "Working on it" }
        if let room = record.room, !room.finished { return "Remove it once the room is finished" }
        if let id = record.sessionID, isRunning(id) { return "Its session is working" }
        return nil
    }

    /// Team room agents' copies that are still on disk, from the saved rooms.
    func roomCopies() -> [SessionWorktreeRecord] {
        guard let rooms = try? worktrees.roomStore?.list() else { return [] }
        return rooms.flatMap { room in
            room.assignments.compactMap { SessionWorktreeRecord.roomCopy($0, in: room) }
        }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A listed copy by id: one of the saved session copies, or a room copy from the last refresh.
    func listedWorktree(_ id: String) -> SessionWorktreeRecord? {
        worktrees.records[id] ?? worktrees.statuses.first { $0.id == id }?.record
    }

    /// Reads each copy's branch, uncommitted changes and size for Settings.
    public func refreshWorktreeList() async {
        worktrees.loadIfNeeded()
        #if os(macOS)
        let git = worktrees.git
        let records = worktrees.records.values.sorted { lastUse(of: $0) > lastUse(of: $1) }
            + roomCopies().sorted { $0.created > $1.created }
        var statuses: [SessionWorktreeStatus] = []
        for record in records {
            let exists = FileManager.default.fileExists(atPath: record.path)
            guard exists else {
                statuses.append(SessionWorktreeStatus(record: record, exists: false, branch: nil, changedFiles: [], sizeBytes: nil))
                continue
            }
            async let branch = git.currentBranch(record.path)
            async let changes = try? git.uncommittedChanges(record.path)
            let path = record.path
            let size = await Task.detached(priority: .utility) { SessionWorktreeGit.size(of: path) }.value
            var record = record
            if record.room != nil, let modified = Self.modificationDate(path) { record.lastUsed = modified }
            statuses.append(SessionWorktreeStatus(record: record, exists: true, branch: await branch,
                                                  changedFiles: await changes ?? [], sizeBytes: size))
        }
        worktrees.statuses = statuses
        #endif
        worktrees.listLoaded = true
    }

    /// Removes one copy. Without `force`, a copy with uncommitted changes stays (the caller confirms first and passes
    /// `force`).
    @discardableResult
    public func removeWorktree(_ id: String, force: Bool) async -> Bool {
        #if os(macOS)
        guard let record = listedWorktree(id) else { return false }
        if let reason = removeWorktreeUnavailableReason(record) {
            worktrees.errors[id] = reason
            return false
        }
        worktrees.busy.insert(id)
        defer { worktrees.busy.remove(id) }
        do {
            try await worktrees.git.remove(record, force: force)
            worktrees.remove(id)
            worktrees.errors[id] = nil
            return true
        } catch {
            worktrees.errors[id] = "Could not remove the copy: \(error.localizedDescription)"
            return false
        }
        #else
        return false
        #endif
    }

    /// Removes every unused copy without uncommitted changes. Returns how many went and how many stayed because of
    /// uncommitted changes.
    @discardableResult
    public func removeUnusedWorktrees() async -> (removed: Int, kept: Int) {
        worktrees.loadIfNeeded()
        var removed = 0
        var kept = 0
        if worktrees.roomStore != nil, !worktrees.listLoaded { await refreshWorktreeList() }
        let rooms = worktrees.statuses.map(\.record).filter { $0.room != nil }
        for record in Array(worktrees.records.values) + rooms where isUnused(record) && removeWorktreeUnavailableReason(record) == nil {
            if await removeWorktree(record.id, force: false) {
                removed += 1
            } else {
                kept += 1
            }
        }
        await refreshWorktreeList()
        return (removed, kept)
    }
}
