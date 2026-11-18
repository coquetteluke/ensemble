import Foundation

/// The "Write description" button: asks a hidden copy of the session for a pull request title and description.
public enum GitHubPullRequestDraft {
    /// Longest diff text sent with the request; the rest is cut.
    public static let diffLimit = 10_000

    public static func prompt(_ context: GitHubPullRequestContext, diffLimit: Int = GitHubPullRequestDraft.diffLimit) -> String {
        var lines = [
            "Write a pull request title and description for the changes on branch \(context.branch), to be merged into \(context.base). "
                + "Reply in exactly this form and nothing else:",
            "",
            "Title: <one line under 72 characters in plain language, with no prefix such as \"feat:\" and no full stop>",
            "",
            "<the description in Markdown: one short paragraph saying what changed and why, then a list of the main changes, "
                + "then how it was tested if you know>",
            "",
            "Do not use em dashes. Do not use tools.",
        ]
        if !context.commits.isEmpty {
            lines += ["", "Commits:"] + context.commits.map { "- \($0)" }
        }
        if !context.files.isEmpty {
            lines += ["", "Files:"]
            for file in context.files {
                let letter = switch file.kind {
                case .added: "A"
                case .deleted: "D"
                case .renamed: "R"
                case .modified: "M"
                }
                let name = file.oldPath.map { "\($0) -> \(file.path)" } ?? file.path
                lines.append(file.isBinary ? "\(letter) \(name) (binary)" : "\(letter) \(name) (+\(file.additions) -\(file.deletions))")
            }
            var diff = context.files.filter { !$0.isBinary }.map(\.patch).joined()
            if diff.count > diffLimit { diff = String(diff.prefix(diffLimit)) + "\n[diff cut short]" }
            if !diff.isEmpty { lines += ["", "Diff:", diff] }
        }
        return lines.joined(separator: "\n")
    }

    /// The title and description from an agent's reply. The title is the "Title:" line (or the first line),
    /// without quotes, heading marks, em dashes or a closing full stop; the description is everything after it.
    /// Nil when no title is left.
    public static func clean(_ answer: String) -> GitHubPullRequestText? {
        var lines = answer.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        // A reply wrapped in one code fence.
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let first = nonEmpty.first, let last = nonEmpty.last, nonEmpty.count >= 2,
           first.trimmingCharacters(in: .whitespaces).hasPrefix("```"), last.trimmingCharacters(in: .whitespaces) == "```" {
            let start = lines.firstIndex(of: first)!
            let end = lines.lastIndex(of: last)!
            lines = Array(lines[(start + 1)..<end])
        }
        let titleIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("title:") }
            ?? lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let titleIndex else { return nil }
        var title = lines[titleIndex].trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)) }
        title = title.trimmingCharacters(in: .whitespaces)
        while title.hasPrefix("#") { title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let wrappers: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("\u{201C}", "\u{201D}"), ("*", "*")]
        var changed = true
        while changed, title.count >= 2 {
            changed = false
            for (open, close) in wrappers where title.first == open && title.last == close {
                title = String(title.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        title = noEmDashes(title)
        while title.hasSuffix(".") && !title.hasSuffix("..") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        var bodyLines = Array(lines[(titleIndex + 1)...])
        while let first = bodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeFirst() }
        if let first = bodyLines.first {
            let label = first.trimmingCharacters(in: .whitespaces).lowercased()
            if ["description:", "body:", "description", "**description**", "**description:**"].contains(label) {
                bodyLines.removeFirst()
            } else if label.hasPrefix("description:") || label.hasPrefix("body:") {
                let colon = first.firstIndex(of: ":")!
                bodyLines[0] = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let body = noEmDashes(bodyLines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubPullRequestText(title: title, body: body)
    }

    static func noEmDashes(_ text: String) -> String {
        text.replacingOccurrences(of: " \u{2014} ", with: ", ").replacingOccurrences(of: "\u{2014}", with: ", ")
    }
}

extension SessionStore {
    /// Asks the agent of `sessionID` for a pull request title and description. Like the commit message, the
    /// question goes to a hidden copy of the session (or a new hidden session in `directory` when its engine
    /// cannot copy sessions) in Ask mode with every permission prompt rejected, so nothing is added to the
    /// session and nothing is run. The copy is deleted afterwards.
    public func draftPullRequest(sessionID: String?, directory: String, context: GitHubPullRequestContext,
                                 timeout: Duration = .seconds(180)) async throws -> GitHubPullRequestText {
        let answer = try await askHiddenCopy(GitHubPullRequestDraft.prompt(context), title: "Pull request description",
                                             sessionID: sessionID, directory: directory, timeout: timeout)
        guard let text = GitHubPullRequestDraft.clean(answer.text) else {
            throw GitHubError(answer.error ?? "The agent did not write a description")
        }
        return text
    }

    /// The hidden-copy question behind Write description: the agent's text after the question, and the last
    /// error when it wrote none.
    func askHiddenCopy(_ prompt: String, title: String, sessionID: String?, directory: String,
                       timeout: Duration) async throws -> (text: String, error: String?) {
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
        defer { Task { [weak self] in await self?.deleteHiddenCopy(info.id) } }

        // A copy keeps the source's permission mode; the request must not run in Bypass or Auto.
        do {
            try await engine.setPermissionMode(info.id, mode: .ask)
        } catch {
            throw GitHubError("Could not set the copy to Ask: \(error.localizedDescription)")
        }
        try? await engine.renameSession(info.id, title: title)
        await deliver(prompt, to: info.id)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while helper.isWorking, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if helper.isWorking { throw GitHubError("The agent took too long to answer") }
        let afterQuestion = helper.items.lastIndex { if case .user = $0 { true } else { false } }
            .map { helper.items.index(after: $0) } ?? helper.items.endIndex
        let text = helper.items[afterQuestion...].compactMap { item -> String? in
            if case .agentText(_, let text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
        var lastError: String?
        if case .error(_, let message)? = helper.items.last { lastError = message }
        return (text, lastError)
    }

    private func deleteHiddenCopy(_ id: String) async {
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
