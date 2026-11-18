import Foundation

// Optional engine abilities rooms use. Like the protocols in `OpenCode/EngineCapabilities.swift`, an engine adopts
// them when it can and the room checks with `as?`, so engines without them keep working. `EngineRouter` adopts
// both and forwards each call to the engine that owns the session (or to every engine, for model lists).

/// Model lists per project folder. A folder's own engine config can add providers (OpenCode reads a project
/// `opencode.json`), so the new room sheet asks for the folder's list.
public protocol EngineFolderModels: Sendable {
    /// Models for `directory` (the engine's default folder when nil), the default model first.
    func models(directory: String?) async throws -> [ModelInfo]
}

/// Lets a Team agent edit its own git worktree the way its permission mode edits the project.
///
/// Worktrees live in `.ensemble/worktrees/<branch>` inside the room's folder (a dot folder, so tools and build systems
/// leave them alone), and Ensemble's Accept edits and Auto rules ask before any edit under a dot folder. An engine
/// that enforces those rules itself (OpenCode) adopts this to add an allow scoped to that one worktree
/// (`PermissionRules.ruleset(for:worktree:)`). Engines whose own permission modes decide (the Claude and Gemini
/// engines) do not need it.
public protocol EngineWorktreeAccess: Sendable {
    /// Lets the session (and its subagents) edit inside `worktreePath`, an absolute path, without asking when its mode
    /// allows edits in the project. Returns false when the rules were left as they are: Ask and Bypass sessions, rules
    /// Ensemble did not write, and a worktree that is not `.ensemble/worktrees/<name>` inside the session's folder.
    @discardableResult
    func allowWorktreeEdits(_ sessionID: String, worktreePath: String) async throws -> Bool
}

public enum RoomWorktreePaths {
    /// `worktreePath` relative to `directory` when it is a room worktree folder directly inside it
    /// (`.ensemble/worktrees/<name>`), comparing the real paths (symlinks resolved), else nil.
    public static func relative(_ worktreePath: String, inside directory: String) -> String? {
        guard let real = WorkspaceTrust.resolvedPath(worktreePath), let base = WorkspaceTrust.resolvedPath(directory) else { return nil }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard real.hasPrefix(prefix) else { return nil }
        let relative = String(real.dropFirst(prefix.count))
        return PermissionRules.isWorktreeFolder(relative) ? relative : nil
    }

    /// `directory`'s place inside its git repository, like `git rev-parse --show-prefix` without the trailing slash:
    /// found by walking up to the nearest folder holding `.git` (a folder or, in worktrees and submodules, a file).
    /// Empty at the top or outside any repository.
    public static func repoPrefix(of directory: String) -> String {
        guard let real = WorkspaceTrust.resolvedPath(directory) else { return "" }
        var current = real
        while current != "/" && !current.isEmpty {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return current == real ? "" : String(real.dropFirst(current.count + 1))
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return ""
    }
}

// MARK: OpenCode

extension OpenCodeClient: EngineFolderModels {}

extension OpenCodeClient: EngineWorktreeAccess {
    /// Reads the session's rules and folder, then writes `PermissionRules.ruleset(for:worktree:)` for its mode to the
    /// session and to every subagent session under it (a child copies its parent's rules only when it is created).
    public func allowWorktreeEdits(_ sessionID: String, worktreePath: String) async throws -> Bool {
        let response: Wire.DataEnvelope<Wire.Session> = try await get("/api/session/\(sessionID)")
        let session = response.data
        let current = (session.permissions ?? []).map { PermissionRule($0.action, $0.resource, $0.effect) }
        guard let directory = session.location?.directory,
              let worktree = RoomWorktreePaths.relative(worktreePath, inside: directory),
              let mode = PermissionRules.mode(for: current), mode == .acceptEdits || mode == .auto else { return false }
        let rules = PermissionRules.ruleset(for: mode, worktree: worktree,
                                            repoPrefix: RoomWorktreePaths.repoPrefix(of: directory))
        guard rules != current else { return true }
        let body = try JSONValue(encoding: rules)
        try await sendIgnoringBody("PATCH", "/api/session/\(sessionID)", body: ["permissions": body])
        var pending = [sessionID]
        var seen: Set<String> = [sessionID]
        while let parent = pending.popLast() {
            for child in try await children(parent) where seen.insert(child.id).inserted {
                try await sendIgnoringBody("PATCH", "/api/session/\(child.id)", body: ["permissions": body])
                pending.append(child.id)
            }
        }
        return true
    }
}

// MARK: Router

extension EngineRouter: EngineFolderModels {
    /// Every engine's models for the folder, the fallback engine's first (its default model leads); a model two
    /// engines list appears once. Engines without per-folder lists give their usual list. Fails only when every
    /// engine fails. Engines are picked with `registrations(forFolder:)`, so the shared OpenCode service never loads an
    /// untrusted folder's config (the private server answers for it).
    public func models(directory: String?) async throws -> [ModelInfo] {
        let list = registrations(forFolder: directory)
        let results = await withTaskGroup(of: (Int, Result<[ModelInfo], any Error>).self) { group in
            for (index, registration) in list.enumerated() {
                group.addTask {
                    do {
                        if let folders = registration.engine as? any EngineFolderModels {
                            return (index, .success(try await folders.models(directory: directory)))
                        }
                        return (index, .success(try await registration.engine.models()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[ModelInfo], any Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var merged: [ModelInfo] = []
        var seen = Set<String>()
        var answered = false
        var firstError: (any Error)?
        for (_, result) in results {
            switch result {
            case .success(let models):
                answered = true
                merged += models.filter { seen.insert($0.id).inserted }
            case .failure(let error):
                if firstError == nil { firstError = error }
            }
        }
        if !answered, let firstError { throw firstError }
        return merged
    }
}

extension EngineRouter: EngineWorktreeAccess {
    /// Forwards to the engine that owns the session; false when that engine has no such rules to change.
    public func allowWorktreeEdits(_ sessionID: String, worktreePath: String) async throws -> Bool {
        guard let registration = await registration(forSession: sessionID) else {
            throw EngineRouterError.unknownSession(sessionID)
        }
        guard let access = registration.engine as? any EngineWorktreeAccess else { return false }
        return try await access.allowWorktreeEdits(sessionID, worktreePath: worktreePath)
    }
}
