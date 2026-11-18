import Foundation

// Rewind with choices for Claude agents, from what the CLI offers headless (claude 2.1.319, read from its stream-json
// control schema):
// - `rewind_files` with `user_message_id` and `dry_run` answers `canRewind`, `error`, `filesChanged` (paths) and line
//   totals; without `dry_run` it puts those files back as they were before that prompt. Only files the CLI's own edit
//   tools changed are tracked (file checkpointing, `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING`).
// - The conversation goes back by resuming the next launch at an earlier entry (`--resume-session-at`); the old branch
//   stays in the transcript file, so Redo resumes at the old entry again.
// - The CLI has no undo for `rewind_files`, so before putting files back Ensemble keeps a private copy of each one, and
//   Redo writes those copies back (until the next prompt).
// - "Summarize from here" (partial compaction) exists only in the CLI's own terminal: there is no control request for
//   it.

/// The CLI's dry run of putting files back.
struct ClaudeFileRewindCheck: Equatable, Sendable {
    var canRewind: Bool
    /// As the CLI reports them (absolute paths).
    var files: [String]
    var error: String?

    static let checkpointsOff = "File snapshots are off for Claude agents"
    static let noSnapshot = "No file snapshots for this message"
    static let noSummary = "Claude offers this only in its own terminal"
}

/// What Redo needs to undo a Claude session's last rewind.
struct ClaudeRewindUndo: Sendable {
    /// The record from before a conversation rewind.
    var record: ClaudeSessionRecord?
    /// Copies of the files from before a code rewind.
    var files: FileCopy?

    static func absolute(_ path: String, directory: String) -> String {
        path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    }

    /// Private copies of files, in a folder only the user can read, and which of them did not exist.
    struct FileCopy: Sendable {
        struct Entry: Sendable, Equatable {
            /// Absolute path of the file.
            var path: String
            /// Name of its copy in `folder`, or nil when the path held no file.
            var copy: String?
        }

        var folder: URL
        var entries: [Entry]

        /// Copies each regular file or link at `paths` (a folder is left alone and not restored later).
        static func save(_ paths: [String]) throws -> FileCopy {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("ensemble-rewind-\(UUID().uuidString.lowercased())")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var entries: [Entry] = []
            do {
                for (index, path) in paths.enumerated() {
                    switch kind(path) {
                    case .file, .link:
                        let name = String(index)
                        try fm.copyItem(atPath: path, toPath: folder.appendingPathComponent(name).path)
                        entries.append(Entry(path: path, copy: name))
                    case .missing:
                        entries.append(Entry(path: path, copy: nil))
                    case .folder:
                        continue
                    }
                }
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
            return FileCopy(folder: folder, entries: entries)
        }

        /// Puts each file back as it was copied; a path that held no file is emptied again (only a file or link there
        /// is removed, never a folder).
        func restore() throws {
            let fm = FileManager.default
            for entry in entries {
                let current = Self.kind(entry.path)
                if current == .folder { continue }
                if current != .missing { try fm.removeItem(atPath: entry.path) }
                guard let copy = entry.copy else { continue }
                let parent = (entry.path as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: folder.appendingPathComponent(copy).path, toPath: entry.path)
            }
        }

        func discard() {
            try? FileManager.default.removeItem(at: folder)
        }

        enum Kind { case file, link, folder, missing }

        static func kind(_ path: String) -> Kind {
            var info = stat()
            guard lstat(path, &info) == 0 else { return .missing }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: return .folder
            case S_IFLNK: return .link
            default: return .file
            }
        }
    }
}

extension ClaudeCodeEngine: EngineRewindControl {
    static let shellNote = "Changes made by shell commands are not put back."

    /// Files the CLI would put back, as the rewind changes them. `agentChanges` are the agent's own edits after the
    /// cut (for line counts and to tell a file it created); a path that holds no file now comes back as `.added`.
    static func rewindFiles(_ paths: [String], agentChanges: [FileChange], directory: String,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [FileChange] {
        let byPath = Dictionary(agentChanges.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return paths.compactMap { path in
            let absolute = ClaudeRewindUndo.absolute(path, directory: directory)
            let display = ClaudeFormatting.displayPath(absolute, directory: directory)
            guard seen.insert(display).inserted else { return nil }
            let agent = byPath[display]
            if !exists(absolute) { return FileChange(path: display, kind: .added) }
            let kind: FileChange.Kind = agent?.kind == .added ? .deleted : .modified
            return FileChange(path: display, kind: kind, additions: agent?.deletions ?? 0, deletions: agent?.additions ?? 0)
        }
    }

    #if os(macOS)

    /// The cut, the entries it removes and the session folder, for a rewind to before `messageID`.
    private func rewindContext(_ sessionID: String, _ messageID: String) async throws
        -> (cut: ClaudeHistory.Cut, removed: [JSONValue], builder: ClaudeTranscriptBuilder) {
        let source = try await core.historySource(sessionID)
        let chain = ClaudeTranscriptFiles.read(source.file).activeChain(leafOverride: source.leafOverride)
        guard let cut = ClaudeHistory.cut(before: messageID, in: chain) else {
            throw ClaudeCodeError.invalidArgument("That message is not in this session's history.")
        }
        let start = cut.keep.flatMap { keep in chain.firstIndex { $0["uuid"]?.stringValue == keep } }.map { $0 + 1 } ?? 0
        let builder = try await core.transcriptSource(sessionID).builder
        return (cut, Array(chain[min(start, chain.count)...]), builder)
    }

    public func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan {
        let (cut, removed, builder) = try await rewindContext(sessionID, messageID)
        let directory = builder.directory ?? ""
        let messages = removed.filter(ClaudeHistory.isPrompt).count
        var files: [FileChange] = []
        var codeReason: String?
        do {
            let check = try await core.fileRewindCheck(sessionID, cut: cut)
            if check.canRewind {
                files = Self.rewindFiles(check.files, agentChanges: builder.changedFiles(from: removed), directory: directory)
            } else {
                codeReason = check.error ?? ClaudeFileRewindCheck.noSnapshot
            }
        } catch {
            codeReason = "Could not check the files: \(error.localizedDescription)"
        }
        return RewindPlan(choices: [
            RewindChoice(.codeAndConversation, unavailableReason: codeReason),
            RewindChoice(.conversationOnly),
            RewindChoice(.codeOnly, unavailableReason: codeReason ?? (files.isEmpty ? RewindReason.noFiles : nil)),
            RewindChoice(.summarizeFromHere, unavailableReason: ClaudeFileRewindCheck.noSummary),
        ], files: files, filesKnown: codeReason == nil, filesNote: codeReason == nil ? Self.shellNote : nil,
           messagesRemoved: messages, canRedo: true)
    }

    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome {
        let (cut, removed, builder) = try await rewindContext(sessionID, messageID)
        let directory = builder.directory ?? ""
        let agentChanges = scope.restoresFiles ? builder.changedFiles(from: removed) : []
        // Read which files exist before the CLI changes them, so the outcome describes the rewind itself.
        var existed: [String: Bool] = [:]
        if scope.restoresFiles, let check = try? await core.fileRewindCheck(sessionID, cut: cut), check.canRewind {
            for path in check.files {
                let absolute = ClaudeRewindUndo.absolute(path, directory: directory)
                existed[absolute] = FileManager.default.fileExists(atPath: absolute)
            }
        }
        let restored = try await core.applyRewind(sessionID, cut: cut, scope: scope)
        let files = Self.rewindFiles(restored, agentChanges: agentChanges, directory: directory) {
            existed[$0] ?? FileManager.default.fileExists(atPath: $0)
        }
        return RewindOutcome(scope: scope, files: files,
                             messagesRemoved: scope.removesMessages ? removed.filter(ClaudeHistory.isPrompt).count : 0,
                             canRedo: await core.canRedoRewind(sessionID))
    }

    public func redoRewind(_ sessionID: String) async throws {
        try await core.redoRewind(sessionID)
    }

    #else

    public func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan {
        throw ClaudeCodeError.unsupportedPlatform
    }

    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome {
        throw ClaudeCodeError.unsupportedPlatform
    }

    public func redoRewind(_ sessionID: String) async throws { throw ClaudeCodeError.unsupportedPlatform }

    #endif
}
