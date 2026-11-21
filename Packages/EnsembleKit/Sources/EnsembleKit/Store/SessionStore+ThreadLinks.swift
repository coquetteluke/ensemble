import Foundation
import Observation

/// One backing session on an engine linked to a primary conversation thread.
public struct ThreadBackingLink: Codable, Hashable, Sendable {
    public var engineID: String
    public var backingSessionID: String
    public var model: ModelRef?
    public var permissionMode: PermissionMode?
    /// Number of items in the primary transcript that this backing session has already seen
    /// (natively or via an earlier handoff), used as a fallback for delta handoffs when switching back.
    public var lastHandedOffItemCount: Int
    /// ID of the last substantive transcript item (user, assistant reply, tool, or board message)
    /// already seen by this backing session, anchoring delta handoffs against index drift.
    public var lastHandedOffItemID: String?
    public var createdAt: Date

    public init(engineID: String, backingSessionID: String, model: ModelRef? = nil,
                permissionMode: PermissionMode? = nil, lastHandedOffItemCount: Int = 0,
                lastHandedOffItemID: String? = nil, createdAt: Date = Date()) {
        self.engineID = engineID
        self.backingSessionID = backingSessionID
        self.model = model
        self.permissionMode = permissionMode
        self.lastHandedOffItemCount = lastHandedOffItemCount
        self.lastHandedOffItemID = lastHandedOffItemID
        self.createdAt = createdAt
    }
}

/// All cross-engine links for one primary conversation session.
public struct SessionThreadRecord: Codable, Hashable, Sendable {
    public var primarySessionID: String
    public var activeBackingSessionID: String
    public var activeModel: ModelRef?
    public var links: [ThreadBackingLink]

    public init(primarySessionID: String, activeBackingSessionID: String,
                activeModel: ModelRef? = nil, links: [ThreadBackingLink] = []) {
        self.primarySessionID = primarySessionID
        self.activeBackingSessionID = activeBackingSessionID
        self.activeModel = activeModel
        self.links = links
    }
}

/// Persisted mapping between a primary session and its cross-engine backing sessions.
/// Backing sessions stay out of the sidebar and Hub so a multi-engine thread reads as one conversation.
@Observable @MainActor
public final class SessionThreadLinks {
    public private(set) var threads: [String: SessionThreadRecord] = [:]
    /// Backing sessions (other than the primary session itself) hidden from visible session lists.
    public private(set) var hiddenLinkedSessionIDs: Set<String> = []

    @ObservationIgnored private var primaryByBackingID: [String: String] = [:]
    @ObservationIgnored public private(set) var fileURL: URL?
    @ObservationIgnored private var loaded = false

    nonisolated public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Ensemble/session-threads.json` for the app; nil for previews and test runners.
    nonisolated public static func defaultURL(isPreview: Bool, bundle: Bundle = .main) -> URL? {
        guard !isPreview, bundle.bundleURL.pathExtension == "app" else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/session-threads.json")
    }

    /// Sets the persistence file URL and loads existing links from disk.
    public func configure(fileURL: URL?) {
        self.fileURL = fileURL
        loaded = false
        loadIfNeeded()
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            rebuildIndexes()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([SessionThreadRecord].self, from: data) {
            threads = Dictionary(list.map { ($0.primarySessionID, $0) }, uniquingKeysWith: { first, _ in first })
        }
        rebuildIndexes()
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let list = threads.values.sorted { $0.primarySessionID < $1.primarySessionID }
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func rebuildIndexes() {
        var reverse: [String: String] = [:]
        var hidden: Set<String> = []
        for record in threads.values {
            for link in record.links where link.backingSessionID != record.primarySessionID {
                reverse[link.backingSessionID] = record.primarySessionID
                hidden.insert(link.backingSessionID)
            }
            if record.activeBackingSessionID != record.primarySessionID {
                reverse[record.activeBackingSessionID] = record.primarySessionID
                hidden.insert(record.activeBackingSessionID)
            }
        }
        primaryByBackingID = reverse
        hiddenLinkedSessionIDs = hidden
    }

    // MARK: Queries

    /// Primary session id owning `backingID`, or nil if `backingID` is not a linked backing session.
    public func primarySessionID(for backingID: String) -> String? {
        loadIfNeeded()
        return primaryByBackingID[backingID]
    }

    public func isLinkedBackingSession(_ sessionID: String) -> Bool {
        primarySessionID(for: sessionID) != nil
    }

    /// Currently active backing session id for `primaryID` (defaults to `primaryID` when unlinked).
    public func activeBackingID(for primaryID: String) -> String? {
        loadIfNeeded()
        return threads[primaryID]?.activeBackingSessionID
    }

    public func activeModel(for primaryID: String) -> ModelRef? {
        loadIfNeeded()
        return threads[primaryID]?.activeModel
    }

    public func hasLinks(for primaryID: String) -> Bool {
        loadIfNeeded()
        guard let record = threads[primaryID] else { return false }
        return record.links.contains { $0.backingSessionID != primaryID } || record.activeBackingSessionID != primaryID
    }

    public func links(for primaryID: String) -> [ThreadBackingLink] {
        loadIfNeeded()
        return threads[primaryID]?.links ?? []
    }

    public func allBackingIDs(for primaryID: String) -> [String] {
        loadIfNeeded()
        var ids = [primaryID]
        for link in threads[primaryID]?.links ?? [] where !ids.contains(link.backingSessionID) {
            ids.append(link.backingSessionID)
        }
        return ids
    }

    public func link(forBackingID backingID: String, primaryID: String) -> ThreadBackingLink? {
        loadIfNeeded()
        return threads[primaryID]?.links.first { $0.backingSessionID == backingID }
    }

    public func record(for primaryID: String) -> SessionThreadRecord? {
        loadIfNeeded()
        return threads[primaryID]
    }

    public func restoreRecord(_ record: SessionThreadRecord?, for primaryID: String) {
        loadIfNeeded()
        if let record {
            threads[primaryID] = record
        } else {
            threads.removeValue(forKey: primaryID)
        }
        rebuildIndexes()
        save()
    }

    // MARK: Mutations

    /// Ensures the primary session itself has a link entry before switching away to another engine.
    public func ensurePrimaryLink(primaryID: String, engineID: String, model: ModelRef?,
                                  permissionMode: PermissionMode, handedOffCount: Int,
                                  handedOffItemID: String? = nil) {
        loadIfNeeded()
        var record = threads[primaryID] ?? SessionThreadRecord(primarySessionID: primaryID, activeBackingSessionID: primaryID, activeModel: model)
        if !record.links.contains(where: { $0.backingSessionID == primaryID }) {
            record.links.insert(ThreadBackingLink(engineID: engineID, backingSessionID: primaryID, model: model,
                                                  permissionMode: permissionMode, lastHandedOffItemCount: handedOffCount,
                                                  lastHandedOffItemID: handedOffItemID), at: 0)
            threads[primaryID] = record
            rebuildIndexes()
            save()
        }
    }

    /// Registers or updates a backing session link and optionally makes it active.
    public func upsertLink(_ link: ThreadBackingLink, forPrimary primaryID: String, makeActive: Bool) {
        loadIfNeeded()
        var record = threads[primaryID] ?? SessionThreadRecord(primarySessionID: primaryID, activeBackingSessionID: primaryID, activeModel: link.model)
        if let index = record.links.firstIndex(where: { $0.backingSessionID == link.backingSessionID }) {
            record.links[index] = link
        } else {
            record.links.append(link)
        }
        if makeActive {
            record.activeBackingSessionID = link.backingSessionID
            if let model = link.model { record.activeModel = model }
        }
        threads[primaryID] = record
        rebuildIndexes()
        save()
    }

    public func updateHandedOffCount(_ count: Int, lastItemID: String? = nil, forBackingID backingID: String, primaryID: String) {
        loadIfNeeded()
        guard var record = threads[primaryID],
              let index = record.links.firstIndex(where: { $0.backingSessionID == backingID }) else { return }
        record.links[index].lastHandedOffItemCount = count
        record.links[index].lastHandedOffItemID = lastItemID
        threads[primaryID] = record
        save()
    }

    public func updateModel(_ model: ModelRef, forBackingID backingID: String, primaryID: String) {
        loadIfNeeded()
        guard var record = threads[primaryID] else { return }
        if let index = record.links.firstIndex(where: { $0.backingSessionID == backingID }) {
            record.links[index].model = model
        }
        if record.activeBackingSessionID == backingID {
            record.activeModel = model
        }
        threads[primaryID] = record
        save()
    }

    public func updatePermissionMode(_ mode: PermissionMode, forBackingID backingID: String, primaryID: String) {
        loadIfNeeded()
        guard var record = threads[primaryID],
              let index = record.links.firstIndex(where: { $0.backingSessionID == backingID }) else { return }
        record.links[index].permissionMode = mode
        threads[primaryID] = record
        save()
    }

    /// Removes a deleted backing session from its thread, falling back to `primaryID` if it was active.
    public func unlinkBackingSession(_ backingID: String) {
        loadIfNeeded()
        guard let primaryID = primaryByBackingID[backingID], var record = threads[primaryID] else { return }
        record.links.removeAll { $0.backingSessionID == backingID }
        if record.activeBackingSessionID == backingID {
            record.activeBackingSessionID = primaryID
            record.activeModel = record.links.first(where: { $0.backingSessionID == primaryID })?.model
        }
        if record.links.allSatisfy({ $0.backingSessionID == primaryID }) && record.activeBackingSessionID == primaryID {
            threads.removeValue(forKey: primaryID)
        } else {
            threads[primaryID] = record
        }
        rebuildIndexes()
        save()
    }

    public func removeThread(primaryID: String) {
        loadIfNeeded()
        guard threads.removeValue(forKey: primaryID) != nil else { return }
        rebuildIndexes()
        save()
    }
}

/// Builds a compact, secret-free summary of earlier conversation turns when switching engines mid-thread.
public enum CrossEngineHandoff {
    public static let defaultMaxChars = 12_000
    public static let preambleHeader = "[Conversation context from earlier in this thread]"
    public static let preambleFooter = "[End context]"
    public static let promptSeparator = "\n\nUser message:\n"

    private static let editToolNames: Set<String> = [
        "edit", "write", "patch", "apply_patch", "multiedit", "str_replace_editor", "create_file", "edit_file", "write_file"
    ]

    private static let pemBlockPattern = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#
    )

    /// ID of the last substantive item (user, assistant reply, tool, or board message) in `items`.
    public static func lastAnchorItemID(in items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            switch item {
            case .user, .agentText, .tool, .board:
                return item.id
            case .reasoning, .permission, .error, .notice:
                continue
            }
        }
        return nil
    }

    /// Computes the delta slice of `items` strictly after `lastHandedOffItemID` when found, falling back to
    /// `lastHandedOffItemCount` only when no anchor ID is recorded or present in `items`.
    public static func deltaItems(
        from items: [TranscriptItem],
        lastHandedOffItemID: String?,
        lastHandedOffItemCount: Int
    ) -> [TranscriptItem] {
        if let anchorID = lastHandedOffItemID,
           let anchorIndex = items.lastIndex(where: { $0.id == anchorID }) {
            let nextIndex = items.index(after: anchorIndex)
            return nextIndex < items.endIndex ? Array(items[nextIndex...]) : []
        }
        let startIndex = min(max(0, lastHandedOffItemCount), items.count)
        return Array(items[startIndex...])
    }

    /// Summarizes recent user prompts, assistant conclusions, and edited files/tools within `maxChars`.
    public static func build(items: [TranscriptItem], maxChars: Int = defaultMaxChars, isDelta: Bool = false) -> String {
        guard maxChars > 0 else { return "" }
        let entries = collectEntries(from: items)
        guard !entries.isEmpty else { return "" }

        let editedFiles = collectEditedFiles(from: items)
        var headerLines = [preambleHeader]
        if isDelta {
            headerLines.append("New turns since the last message on this engine:")
        }
        if !editedFiles.isEmpty {
            let fileList = editedFiles.prefix(20).joined(separator: ", ")
            let suffix = editedFiles.count > 20 ? " (+\(editedFiles.count - 20) more)" : ""
            headerLines.append("Edited files: \(fileList)\(suffix)")
        }

        let header = headerLines.joined(separator: "\n") + "\n"
        let footer = "\n" + preambleFooter
        let overhead = header.count + footer.count
        guard overhead < maxChars else {
            return String((preambleHeader + footer).prefix(maxChars))
        }

        var budget = maxChars - overhead
        var selected: [String] = []
        var omitted = false

        for entry in entries.reversed() {
            let lineCost = entry.count + (selected.isEmpty ? 0 : 1)
            if lineCost <= budget {
                selected.append(entry)
                budget -= lineCost
            } else if selected.isEmpty {
                // Keep at least the newest entry, truncated to fit within the budget.
                let allowed = max(0, budget - 3)
                if allowed > 0 {
                    selected.append(String(entry.prefix(allowed)) + "...")
                }
                omitted = entries.count > 1
                break
            } else {
                omitted = true
                break
            }
        }

        selected.reverse()
        if omitted {
            let note = "(Earlier turns omitted to fit context budget)\n"
            if note.count <= budget {
                return header + note + selected.joined(separator: "\n") + footer
            }
            // Drop oldest selected entry if needed so the omission note fits cleanly inside maxChars.
            while selected.count > 1 && (selected.joined(separator: "\n").count + note.count + overhead) > maxChars {
                selected.removeFirst()
            }
            let body = selected.joined(separator: "\n")
            if header.count + note.count + body.count + footer.count <= maxChars {
                return header + note + body + footer
            }
        }

        return header + selected.joined(separator: "\n") + footer
    }

    /// Removes a handoff preamble from a stored user message so reloaded transcripts stay clean.
    /// Requires the text to start with `preambleHeader` and matches the neutralized `preambleFooter + promptSeparator`
    /// boundary so earlier entries cannot spoof the end of context or the user bubble.
    public static func stripHandoff(from userText: String) -> String {
        guard userText.hasPrefix(preambleHeader) else { return userText }
        let afterHeader = userText.index(userText.startIndex, offsetBy: preambleHeader.count)
        let boundary = preambleFooter + promptSeparator
        guard let range = userText.range(of: boundary, range: afterHeader..<userText.endIndex) else { return userText }
        return String(userText[range.upperBound...])
    }

    /// Redacts secrets from text using `CustomizationRedaction` plus PEM private key removal.
    public static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        let ns = input as NSString
        let stripped = pemBlockPattern.stringByReplacingMatches(
            in: input,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: CustomizationRedaction.mask
        )
        return CustomizationRedaction.text(stripped)
    }

    /// Neutralizes handoff delimiter markers inside untrusted entry text so earlier turns cannot forge
    /// the closing boundary or a spoofed `User message:` separator.
    static func neutralizeMarkers(_ text: String) -> String {
        text
            .replacingOccurrences(of: preambleHeader, with: "(Conversation context from earlier in this thread)", options: .caseInsensitive)
            .replacingOccurrences(of: preambleFooter, with: "(End context)", options: .caseInsensitive)
            .replacingOccurrences(of: "User message:", with: "User-message:", options: .caseInsensitive)
    }

    private static func collectEntries(from items: [TranscriptItem]) -> [String] {
        var entries: [String] = []
        var pendingTools: [String] = []

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            entries.append("Tools: " + pendingTools.joined(separator: "; "))
            pendingTools.removeAll()
        }

        for item in items {
            switch item {
            case .user(_, let text, _):
                flushTools()
                let clean = neutralizeMarkers(redact(stripHandoff(from: text))).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { entries.append("User: \(compact(clean, limit: 1_800))") }
            case .agentText(_, let text, _, _):
                flushTools()
                let clean = neutralizeMarkers(redact(text)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { entries.append("Assistant: \(compact(clean, limit: 2_400))") }
            case .tool(let tool):
                let summary = summarize(tool)
                if !summary.isEmpty { pendingTools.append(summary) }
            case .board(_, _, _, let text, _):
                flushTools()
                let clean = neutralizeMarkers(redact(text)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { entries.append("Board: \(compact(clean, limit: 800))") }
            case .reasoning, .permission, .error, .notice:
                break
            }
        }
        flushTools()
        return entries
    }

    private static func summarize(_ tool: ToolCallInfo) -> String {
        let name = neutralizeMarkers(tool.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = neutralizeMarkers(redact(tool.title)).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty || title == name ? name : "\(name) \(compact(title, limit: 160))"
        return "\(label) (\(tool.status.rawValue))"
    }

    private static func collectEditedFiles(from items: [TranscriptItem]) -> [String] {
        var files: [String] = []
        var seen: Set<String> = []
        for item in items {
            guard case .tool(let tool) = item,
                  editToolNames.contains(tool.name.lowercased()),
                  tool.status == .succeeded || tool.status == .running else { continue }
            let candidate = extractedPath(from: tool) ?? tool.title
            let clean = neutralizeMarkers(redact(candidate))
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean != tool.name, seen.insert(clean).inserted else { continue }
            files.append(clean)
        }
        return files
    }

    private static func extractedPath(from tool: ToolCallInfo) -> String? {
        guard let data = tool.inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["file_path", "filePath", "path", "Path", "target_file"] {
            if let path = object[key] as? String, !path.isEmpty { return path }
        }
        return nil
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}

extension SessionStore {
    /// Active backing session id for `sessionID` (returns `sessionID` when no cross-engine backing link is active).
    public func backingSessionID(for sessionID: String) -> String {
        threadLinks.activeBackingID(for: sessionID) ?? sessionID
    }

    /// Primary conversation id for `sessionID` (returns `sessionID` when it is not a linked backing session).
    public func primarySessionID(for sessionID: String) -> String {
        threadLinks.primarySessionID(for: sessionID) ?? sessionID
    }

    func backingSessionID(forPermissionID requestID: String, fallback sessionID: String) -> String {
        if let recorded = permissionBackingSessions[requestID] { return recorded }
        if threadLinks.isLinkedBackingSession(sessionID) { return sessionID }
        return backingSessionID(for: sessionID)
    }

    func syncRouterThreadLinks() {
        guard let router = engine as? EngineRouter else { return }
        var map: [String: String] = [:]
        for (primaryID, record) in threadLinks.threads where record.activeBackingSessionID != primaryID {
            map[primaryID] = record.activeBackingSessionID
        }
        router.setActiveBackingSessions(map)
    }

    /// Reconstructs a unified transcript across `primaryID` and its linked backing sessions in turn order.
    func loadMergedTranscript(for primaryID: String, links: [ThreadBackingLink]) async throws -> [TranscriptItem] {
        struct Turn {
            var date: Date
            var order: Int
            var sourceID: String
            var items: [TranscriptItem]
        }

        let primaryRaw = try await fetchTranscript(primaryID, for: primaryID)
        var rawBySession: [(id: String, items: [TranscriptItem])] = [(primaryID, primaryRaw)]
        for link in links where link.backingSessionID != primaryID {
            let items = (try? await fetchTranscript(link.backingSessionID, for: primaryID)) ?? []
            if !items.isEmpty { rawBySession.append((link.backingSessionID, items)) }
        }

        var turns: [Turn] = []
        var order = 0
        for (sourceID, rawItems) in rawBySession {
            var currentItems: [TranscriptItem] = []
            var currentDate: Date?
            for item in rawItems {
                if case .user(let id, let text, let date) = item {
                    if !currentItems.isEmpty {
                        turns.append(Turn(date: currentDate ?? .distantPast, order: order, sourceID: sourceID, items: currentItems))
                        order += 1
                        currentItems = []
                    }
                    currentDate = date
                    let cleanText = CrossEngineHandoff.stripHandoff(from: text)
                    currentItems.append(.user(id: id, text: cleanText, date: date))
                } else {
                    currentItems.append(item)
                }
            }
            if !currentItems.isEmpty {
                turns.append(Turn(date: currentDate ?? .distantPast, order: order, sourceID: sourceID, items: currentItems))
                order += 1
            }
        }

        turns.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.order < rhs.order
        }

        var merged: [TranscriptItem] = []
        var previousSource: String?
        for (index, turn) in turns.enumerated() {
            if let previousSource, previousSource != turn.sourceID {
                let model = links.first(where: { $0.backingSessionID == turn.sourceID })?.model
                let label = model.map { modelName($0) } ?? "another model"
                let noticeText = "Switched to \(label) for this message"
                if case .notice(_, let lastText) = merged.last, lastText == noticeText {
                    // Already has a matching divider.
                } else {
                    merged.append(.notice(id: "switch-\(turn.sourceID)-\(index)", text: noticeText))
                }
            }
            merged.append(contentsOf: turn.items)
            previousSource = turn.sourceID
        }
        return merged
    }
}
