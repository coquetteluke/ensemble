#if os(macOS)
import Foundation

/// What an import needs from one CLI transcript, read without parsing the whole file: transcripts can be hundreds of
/// megabytes (request snapshots, tool output), so only the first lines (folder, first prompt, start time) and the
/// last lines (end time, model, newest `/rename` title) are decoded. Request snapshot and bookkeeping lines are
/// skipped unread. The file is mapped read-only and never written.
struct ClaudeImportProbe: Sendable {
    var sessionID: String
    var file: URL
    /// Folders recorded in the transcript (`cwd`, `relocatedCwd`), in the order seen, without repeats.
    var cwds: [String] = []
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var firstPrompt: String?
    var lastPrompt: String?
    /// The newest `custom-title` line (a `/rename`, or the desktop app's title).
    var customTitle: String?
    /// The `summary` line older CLI versions wrote at the top.
    var summary: String?
    /// The model of the newest assistant message.
    var model: String?
    /// User and assistant lines of the main conversation.
    var conversationLines = 0
    /// User and assistant lines of subagents (sidechains).
    var sidechainLines = 0
    var modified: Date?
    var created: Date?

    /// How far the first pass reads at most before giving up on a first prompt.
    static let headBudget = 8 << 20
    /// The last part of the file read for end time, model and title; widened once when it holds no timestamp.
    static let tailWindow = 256 << 10
    static let tailWindowMax = 4 << 20

    /// Line types that never matter here; skipped without decoding (some are megabytes long).
    private static let skippedTypes: Set<String> = [
        "api-request", "api-request-blob", "api-request-shape", "file-history-snapshot", "file-history-delta",
        "queue-operation", "atis-latch", "cost-state", "tools-used", "bridge-session", "session-owner", "mode",
        "agent-name", "isolation-latch",
    ]
    private static let typePrefix = Array(#"{"type":""#.utf8)
    private static let titleNeedle = Array(#"{"type":"custom-title""#.utf8)

    /// Reads a transcript. `searchTitle` scans the whole file for the newest `/rename` line when the last lines hold
    /// none (only needed when no better title is known, such as the desktop app's).
    static func read(_ file: URL, searchTitle: Bool) -> ClaudeImportProbe? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        var probe = ClaudeImportProbe(sessionID: file.deletingPathExtension().lastPathComponent, file: file)
        probe.modified = values?.contentModificationDate
        probe.created = values?.creationDate
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            probe.scan(bytes, searchTitle: searchTitle)
        }
        return probe
    }

    /// Reads transcript bytes (tests and `read`).
    static func parse(_ data: Data, sessionID: String = "test", searchTitle: Bool = true) -> ClaudeImportProbe {
        var probe = ClaudeImportProbe(sessionID: sessionID, file: URL(fileURLWithPath: "/dev/null"))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            probe.scan(raw.bindMemory(to: UInt8.self), searchTitle: searchTitle)
        }
        return probe
    }

    private mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>, searchTitle: Bool) {
        let count = bytes.count
        let decoder = JSONDecoder()
        // First lines: folder, start time, first prompt (and the old summary line, which comes first).
        var start = 0
        var reachedEnd = true
        while start < count {
            if start >= Self.headBudget || (firstPrompt != nil && !cwds.isEmpty && firstTimestamp != nil) {
                reachedEnd = false
                break
            }
            let end = Self.lineEnd(bytes, from: start)
            consume(bytes, start, end, decoder)
            start = end + 1
        }
        // Last lines: end time, model, newest title and folder (a relocated session records its new folder there).
        var readAll = reachedEnd
        if !reachedEnd {
            var window = Self.tailWindow
            while true {
                let from = Self.lineStart(bytes, atOrAfter: max(start, count - window))
                if from <= start { readAll = true }
                var position = from
                let hadTimestamp = lastTimestamp
                lastTimestamp = nil
                while position < count {
                    let end = Self.lineEnd(bytes, from: position)
                    consume(bytes, position, end, decoder)
                    position = end + 1
                }
                if lastTimestamp == nil { lastTimestamp = hadTimestamp }
                if lastTimestamp != nil || window >= Self.tailWindowMax || from <= start { break }
                window = Self.tailWindowMax
            }
        }
        if customTitle == nil, searchTitle, !readAll, let title = Self.lastTitle(bytes) {
            customTitle = title
        }
    }

    // MARK: Lines

    private static func lineEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        guard let base = bytes.baseAddress, start < bytes.count else { return bytes.count }
        guard let hit = memchr(base + start, 0x0A, bytes.count - start) else { return bytes.count }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
    }

    /// The start of the first whole line at or after `offset`.
    private static func lineStart(_ bytes: UnsafeBufferPointer<UInt8>, atOrAfter offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        if bytes[offset - 1] == 0x0A { return offset }
        return min(bytes.count, lineEnd(bytes, from: offset) + 1)
    }

    /// The type of a line that starts with `{"type":"`, else nil.
    private static func leadingType(_ line: UnsafeBufferPointer<UInt8>) -> String? {
        guard line.count > typePrefix.count, line.starts(with: typePrefix) else { return nil }
        var end = typePrefix.count
        while end < line.count, end < typePrefix.count + 40, line[end] != 0x22 { end += 1 }
        guard end < line.count, line[end] == 0x22 else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: line[typePrefix.count..<end]), as: UTF8.self)
    }

    private mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ decoder: JSONDecoder) {
        guard end > start else { return }
        let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
        if let type = Self.leadingType(line), Self.skippedTypes.contains(type) { return }
        guard let entry = try? decoder.decode(Line.self, from: Data(line)) else { return }
        apply(entry)
    }

    private mutating func apply(_ entry: Line) {
        if let cwd = entry.cwd { remember(cwd) }
        switch entry.type {
        case "custom-title":
            if let title = entry.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { customTitle = title }
            return
        case "summary":
            if summary == nil, let text = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { summary = text }
            return
        case "last-prompt":
            if let text = entry.lastPrompt.flatMap(Self.promptText) { lastPrompt = text }
            return
        case "relocated":
            if let cwd = entry.relocatedCwd { remember(cwd) }
            return
        default:
            break
        }
        if let date = ClaudeDates.parse(entry.timestamp) {
            if firstTimestamp == nil { firstTimestamp = date }
            lastTimestamp = date
        }
        guard entry.type == "user" || entry.type == "assistant" else { return }
        if entry.isSidechain == true {
            sidechainLines += 1
            return
        }
        conversationLines += 1
        if entry.type == "assistant" {
            if let model = entry.message?.model, !model.isEmpty, !model.hasPrefix("<") { self.model = model }
            return
        }
        guard entry.isMeta != true, entry.isCompactSummary != true, let text = entry.message?.text.flatMap(Self.promptText) else { return }
        if firstPrompt == nil { firstPrompt = text }
        lastPrompt = text
    }

    private mutating func remember(_ cwd: String) {
        guard !cwd.isEmpty, cwd.hasPrefix("/") else { return }
        cwds.removeAll { $0 == cwd }
        cwds.append(cwd)
    }

    /// The user's own words in a prompt line, or nil for a slash command echo, command output or an interruption.
    static func promptText(_ raw: String) -> String? {
        let text = ClaudeTranscriptBuilder.cleanUserText(raw)
        guard !text.isEmpty else { return nil }
        for prefix in ["<command-", "<local-command-", ClaudeTranscriptBuilder.interruptedPrefix, "Caveat: "] where text.hasPrefix(prefix) {
            return nil
        }
        return text
    }

    /// The newest `custom-title` anywhere in the file (a byte search; only matching lines are decoded).
    private static func lastTitle(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        guard let base = bytes.baseAddress, bytes.count >= titleNeedle.count else { return nil }
        var last: Int?
        var offset = 0
        titleNeedle.withUnsafeBytes { needle in
            while offset < bytes.count, let hit = memmem(base + offset, bytes.count - offset, needle.baseAddress, needle.count) {
                let position = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if position == 0 || bytes[position - 1] == 0x0A { last = position }
                offset = position + needle.count
            }
        }
        guard let last else { return nil }
        let end = lineEnd(bytes, from: last)
        let line = Data(UnsafeBufferPointer(rebasing: bytes[last..<end]))
        let title = (try? JSONDecoder().decode(Line.self, from: line))?.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    // MARK: Results

    /// The folder the session belongs to. The CLI files a transcript under its working folder with every character
    /// that is not a letter or digit turned into `-` (long names are cut to 200 characters plus a hash), so the
    /// recorded folder whose name matches the transcript's folder is the one `claude --resume` finds it from. A
    /// relocated session records its new folder later, so the newest match wins. Without a match (another naming
    /// scheme), the newest recorded folder is used.
    func directory(projectFolderName: String) -> String? {
        if let match = cwds.last(where: { Self.matches(cwd: $0, folderName: projectFolderName) }) { return match }
        return cwds.last
    }

    static let folderNameLimit = 200

    /// The CLI's folder name for a working folder, without the hash it adds to long names.
    static func encodedFolderName(_ path: String) -> String {
        // The CLI replaces UTF-16 code units, so a character outside the BMP becomes two dashes.
        let units = path.utf16.map { unit -> UInt8 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: UInt8(unit)
            default: 0x2D
            }
        }
        return String(decoding: units, as: UTF8.self)
    }

    static func matches(cwd: String, folderName: String) -> Bool {
        let encoded = encodedFolderName(cwd)
        if encoded.count <= folderNameLimit { return encoded == folderName }
        return folderName.count > folderNameLimit && encoded.prefix(folderNameLimit) == folderName.prefix(folderNameLimit)
    }

    /// The title for the session list: the newest rename, the old summary line, else the first prompt.
    var bestTitle: (text: String, source: ClaudeImportSession.TitleSource)? {
        if let customTitle { return (customTitle, .renamed) }
        if let summary { return (summary, .summary) }
        if let firstPrompt { return (Self.shortTitle(firstPrompt), .firstPrompt) }
        if let lastPrompt { return (Self.shortTitle(lastPrompt), .lastPrompt) }
        return nil
    }

    /// First line, at most 60 characters (the engine's rule for titles from a prompt).
    static func shortTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 60 ? String(collapsed.prefix(57)) + "..." : collapsed
    }
}

/// The fields of a transcript line the import reads. Each is decoded on its own, so an unexpected type in one field
/// never loses the line.
private struct Line: Decodable {
    var type: String?
    var cwd: String?
    var timestamp: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var isCompactSummary: Bool?
    var customTitle: String?
    var summary: String?
    var lastPrompt: String?
    var relocatedCwd: String?
    var message: Message?

    struct Message: Decodable {
        var model: String?
        var text: String?

        private enum CodingKeys: String, CodingKey { case model, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            if let string = try? c.decodeIfPresent(String.self, forKey: .content) {
                text = string
            } else if let blocks = try? c.decodeIfPresent([LenientBlock].self, forKey: .content) {
                text = blocks.first(where: { $0.type == "text" && $0.text?.isEmpty == false })?.text
            }
        }

        private struct LenientBlock: Decodable {
            var type: String?
            var text: String?
            private enum CodingKeys: String, CodingKey { case type, text }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try? c.decodeIfPresent(String.self, forKey: .type)
                text = try? c.decodeIfPresent(String.self, forKey: .text)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, cwd, timestamp, isSidechain, isMeta, isCompactSummary, customTitle, summary, lastPrompt, relocatedCwd, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        isMeta = try? c.decodeIfPresent(Bool.self, forKey: .isMeta)
        isCompactSummary = try? c.decodeIfPresent(Bool.self, forKey: .isCompactSummary)
        customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        lastPrompt = try? c.decodeIfPresent(String.self, forKey: .lastPrompt)
        relocatedCwd = try? c.decodeIfPresent(String.self, forKey: .relocatedCwd)
        message = try? c.decodeIfPresent(Message.self, forKey: .message)
    }
}
#endif
