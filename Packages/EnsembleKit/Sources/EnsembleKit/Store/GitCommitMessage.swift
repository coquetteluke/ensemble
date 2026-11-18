import Foundation

/// The "Write message" button: asks the session's agent for a one-line commit message.
public enum GitCommitMessage {
    /// Longest diff text sent with the request; the rest is cut.
    public static let diffLimit = 12_000

    /// The request: the files with their counts and as much of the diff as fits.
    public static func prompt(files: [ReviewFileDiff], diffLimit: Int = GitCommitMessage.diffLimit) -> String {
        var lines = [
            "Write a git commit message for the changes below. Reply with only the message: one line under 72 characters, "
                + "in plain language saying what changed, with no prefix such as \"feat:\", no quotes, no em dashes and no full stop "
                + "at the end. Do not use tools.",
            "",
            "Files:",
        ]
        for file in files {
            let letter = switch file.kind {
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .modified: "M"
            }
            let name = file.oldPath.map { "\($0) -> \(file.path)" } ?? file.path
            lines.append(file.isBinary ? "\(letter) \(name) (binary)" : "\(letter) \(name) (+\(file.additions) -\(file.deletions))")
        }
        var diff = files.filter { !$0.isBinary }.map(\.patch).joined()
        if diff.count > diffLimit {
            diff = String(diff.prefix(diffLimit)) + "\n[diff cut short]"
        }
        if !diff.isEmpty {
            lines += ["", "Diff:", diff]
        }
        return lines.joined(separator: "\n")
    }

    /// The message from an agent's reply: its first real line, without fences, labels, quotes, em dashes or
    /// a closing full stop. Nil when nothing usable is left.
    public static func clean(_ answer: String) -> String? {
        let candidates = answer
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard var line = candidates.first else { return nil }
        for label in ["commit message:", "message:", "commit:", "subject:"] where line.lowercased().hasPrefix(label) {
            line = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
        let wrappers: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("\u{201C}", "\u{201D}"), ("*", "*")]
        var changed = true
        while changed, line.count >= 2 {
            changed = false
            for (open, close) in wrappers where line.first == open && line.last == close {
                line = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        line = line.replacingOccurrences(of: " \u{2014} ", with: ", ").replacingOccurrences(of: "\u{2014}", with: ", ")
        while line.hasSuffix(".") && !line.hasSuffix("..") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}

public struct CommitMessageError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension SessionStore {
    /// Asks the agent of `sessionID` for a one-line commit message for `files`. The question goes to a hidden
    /// copy of the session (or, when its engine cannot copy sessions, a new hidden session in `directory`) that
    /// runs in Ask mode with every permission prompt rejected, so nothing is added to the session and nothing
    /// is run. The copy is deleted afterwards.
    public func draftCommitMessage(sessionID: String?, directory: String, files: [ReviewFileDiff],
                                   timeout: Duration = .seconds(120)) async throws -> String {
        let source = sessionID.flatMap { byID[$0] }
        let info: EngineSession
        if let sessionID, let history = historyControl,
           (engine as? any EngineForkAvailability)?.canFork(sessionID) ?? true,
           let fork = try? await history.fork(sessionID, atMessageID: nil) {
            info = fork
        } else {
            info = try await engine.createSession(directory: source?.directory ?? directory,
                                                  model: source?.info.model ?? defaultModel, agent: nil,
                                                  permissionMode: .ask, parentID: nil)
        }
        hiddenSessionIDs.insert(info.id)
        rememberSideQuestionCopy(info.id, source: sessionID ?? "")
        let helper = upsertSession(info)
        helper.permissionMode = .ask
        permissionRulesChecked.insert(info.id)
        defer { Task { [weak self] in await self?.deleteCommitMessageSession(info.id) } }

        // A copy keeps the source's permission mode; the request must not run in Bypass or Auto.
        do {
            try await engine.setPermissionMode(info.id, mode: .ask)
        } catch {
            throw CommitMessageError("Could not set the copy to Ask: \(error.localizedDescription)")
        }
        try? await engine.renameSession(info.id, title: "Commit message")
        await deliver(GitCommitMessage.prompt(files: files), to: info.id)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while helper.isWorking, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if helper.isWorking {
            throw CommitMessageError("The agent took too long to answer")
        }
        let afterQuestion = helper.items.lastIndex { if case .user = $0 { true } else { false } }
            .map { helper.items.index(after: $0) } ?? helper.items.endIndex
        let answer = helper.items[afterQuestion...].compactMap { item -> String? in
            if case .agentText(_, let text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
        guard let message = GitCommitMessage.clean(answer) else {
            if case .error(_, let message)? = helper.items.last { throw CommitMessageError(message) }
            throw CommitMessageError("The agent did not write a message")
        }
        return message
    }

    private func deleteCommitMessageSession(_ id: String) async {
        if byID[id]?.isWorking == true { try? await engine.interrupt(id) }
        do {
            try await engine.deleteSession(id)
            apply(.sessionDeleted(sessionID: id))
            hiddenSessionIDs.remove(id)
            forgetSideQuestionCopy(id)
        } catch {
            // Stays hidden and on the list of copies; the next launch deletes it.
        }
    }
}
