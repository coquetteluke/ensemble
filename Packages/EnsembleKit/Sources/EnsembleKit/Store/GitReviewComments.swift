import Foundation

/// A comment on one line of a reviewed diff, waiting to be sent to the agent.
public struct ReviewComment: Identifiable, Hashable, Sendable, Codable {
    /// Which side of the diff the line number counts: the new file (added and unchanged lines) or the old
    /// one (removed lines).
    public enum Side: String, Hashable, Sendable, Codable {
        case old
        case new
    }

    public var id: UUID
    /// `ReviewFileDiff.id` of the file.
    public var fileID: String
    /// Path as the agent knows it (relative to the project or worktree).
    public var path: String
    public var line: Int
    public var side: Side
    /// The line's text, quoted in the message.
    public var quoted: String
    public var text: String
    /// The room agent whose file this is (comments go to that agent).
    public var agentID: UUID?
    public var created: Date

    public init(id: UUID = UUID(), fileID: String, path: String, line: Int, side: Side, quoted: String, text: String,
                agentID: UUID? = nil, created: Date = Date()) {
        self.id = id
        self.fileID = fileID
        self.path = path
        self.line = line
        self.side = side
        self.quoted = quoted
        self.text = text
        self.agentID = agentID
        self.created = created
    }

    /// Key of the diff line the comment belongs to.
    public var lineKey: ReviewLineKey { ReviewLineKey(fileID: fileID, side: side, line: line) }
}

/// Identifies one line of one file's diff.
public struct ReviewLineKey: Hashable, Sendable {
    public var fileID: String
    public var side: ReviewComment.Side
    public var line: Int

    public init(fileID: String, side: ReviewComment.Side, line: Int) {
        self.fileID = fileID
        self.side = side
        self.line = line
    }
}

/// Turns pending comments into the message the agent receives.
public enum ReviewCommentFormatter {
    /// All comments as one message: each with its file, line, the quoted line and the comment, in file and
    /// line order.
    public static func message(_ comments: [ReviewComment]) -> String {
        let sorted = comments.sorted { a, b in
            if a.path != b.path { return a.path.localizedStandardCompare(b.path) == .orderedAscending }
            if a.line != b.line { return a.line < b.line }
            return a.created < b.created
        }
        let count = sorted.count
        var parts = ["Review comments on your changes (\(count)). Please address each one:"]
        for (index, comment) in sorted.enumerated() {
            let removed = comment.side == .old ? " (a removed line)" : ""
            let quoted = comment.quoted.trimmingCharacters(in: .whitespaces).isEmpty ? "(empty line)" : comment.quoted
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("\(index + 1). \(comment.path), line \(comment.line)\(removed):\n> \(quoted)\n\n\(text)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// One message per agent (rooms send each agent the comments on its own files). Comments without an
    /// agent come first, under `nil`.
    public static func messagesByAgent(_ comments: [ReviewComment]) -> [(agentID: UUID?, text: String)] {
        let groups = Dictionary(grouping: comments, by: \.agentID)
        let order = groups.keys.sorted { a, b in
            switch (a, b) {
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return (groups[x]?.first?.created ?? .distantPast) < (groups[y]?.first?.created ?? .distantPast)
            }
        }
        return order.compactMap { key in
            guard let list = groups[key], !list.isEmpty else { return nil }
            return (key, message(list))
        }
    }
}
