import Foundation

/// One of your messages in a session's outline: where a turn starts. Pinned ones are the session's chapters.
public struct OutlineEntry: Identifiable, Equatable, Sendable {
    /// The transcript item id of the message; the transcript scrolls to it.
    public var id: String
    /// The turn's number in the session, from 1.
    public var number: Int
    /// The message's first line, shortened.
    public var title: String
    public var date: Date
    /// Files the agent changed in answer to it.
    public var filesChanged: Int
    public var pinned: Bool

    public init(id: String, number: Int, title: String, date: Date, filesChanged: Int = 0, pinned: Bool = false) {
        self.id = id
        self.number = number
        self.title = title
        self.date = date
        self.filesChanged = filesChanged
        self.pinned = pinned
    }
}

/// The outline of a transcript: one entry per message you sent, in order, for a list that jumps to any turn.
public enum TranscriptOutline {
    public static func entries(_ items: [TranscriptItem], pinned: Set<String> = []) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        var starts: [Int] = []
        for (index, item) in items.enumerated() {
            guard case .user(let id, let text, let date) = item else { continue }
            starts.append(index)
            entries.append(OutlineEntry(id: id, number: entries.count + 1, title: title(text), date: date,
                                        pinned: pinned.contains(id)))
        }
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : items.count
            guard start + 1 < end else { continue }
            entries[position].filesChanged = NextStepBuilder.work(in: items[(start + 1)..<end]).filesChanged
        }
        return entries
    }

    /// The message's first line with text, spaces collapsed, cut to `limit` characters with an ellipsis. A message
    /// of attachments only (no text) is "Attachment".
    public static func title(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return "Attachment" }
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The entries a filter shows: every turn, or the pinned chapters only.
    public static func visible(_ entries: [OutlineEntry], chaptersOnly: Bool) -> [OutlineEntry] {
        chaptersOnly ? entries.filter(\.pinned) : entries
    }
}
