import Foundation

/// Finds and reads the CLI's own transcript files: `<projects>/<folder>/<session>.jsonl`, with subagents in
/// `<projects>/<folder>/<session>/subagents/agent-<id>.jsonl` plus a `.meta.json` naming the Agent tool call.
/// The folder name is derived from the working directory (long paths are shortened with a hash), so files are
/// found by session id instead of by recomputing the folder name.
struct ClaudeTranscriptFiles: Sendable {
    let projectsDirectory: URL

    static func defaultProjectsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// The transcript file of a root session, or nil when the CLI has not written one.
    func sessionFile(_ sessionID: String, hint: URL? = nil) -> URL? {
        let fm = FileManager.default
        if let hint, fm.fileExists(atPath: hint.path) { return hint }
        guard let folders = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    struct Subagent: Sendable, Equatable {
        var toolUseID: String
        var description: String
        var agentType: String?
        var file: URL
        var created: Date
        var updated: Date
    }

    /// Subagents the CLI recorded for a root session.
    func subagents(sessionFile: URL) -> [Subagent] {
        let folder = sessionFile.deletingPathExtension().appendingPathComponent("subagents")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]) else {
            return []
        }
        var result: [Subagent] = []
        for meta in entries where meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta), let json = JSONValue.parse(data: data),
                  let toolUseID = json["toolUseId"]?.stringValue else { continue }
            let base = String(meta.lastPathComponent.dropLast(".meta.json".count))
            let file = folder.appendingPathComponent(base + ".jsonl")
            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            result.append(Subagent(toolUseID: toolUseID, description: json["description"]?.stringValue ?? "Subagent",
                                   agentType: json["agentType"]?.stringValue, file: file,
                                   created: values?.creationDate ?? Date(), updated: values?.contentModificationDate ?? Date()))
        }
        return result.sorted { $0.created < $1.created }
    }

    static func read(_ url: URL) -> ClaudeTranscriptData {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return ClaudeTranscriptData() }
        return parse(data)
    }

    private struct Head: Decodable {
        let type: String?
        let uuid: String?
        let parentUuid: String?
        let logicalParentUuid: String?
    }

    private static let wanted: Set<String> = ["user", "assistant", "system"]
    private static let typePrefix = Array(#"{"type":""#.utf8)
    /// Bookkeeping lines that can be megabytes long (full request snapshots) and never take part in the conversation.
    private static let skippedPrefixes = [Array("api-request".utf8), Array("file-history".utf8)]

    /// Parses a transcript file. Transcripts can be very large (request snapshots, attachments): request snapshot lines
    /// are skipped unread, and other lines that are not conversation entries are only read for their place in the
    /// parent chain, never built into a full JSON tree.
    static func parse(_ data: Data) -> ClaudeTranscriptData {
        var result = ClaudeTranscriptData()
        let decoder = JSONDecoder()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let count = bytes.count
            while start < count {
                var end = start
                while end < count, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }
                guard end > start else { continue }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                if line.count > typePrefix.count, line.starts(with: typePrefix) {
                    let rest = line[(line.startIndex + typePrefix.count)...]
                    if skippedPrefixes.contains(where: { rest.starts(with: $0) }) { continue }
                }
                let chunk = Data(line)
                guard let head = try? decoder.decode(Head.self, from: chunk) else { continue }
                if let uuid = head.uuid { result.parents[uuid] = head.parentUuid ?? head.logicalParentUuid ?? "" }
                guard let type = head.type, wanted.contains(type), let json = try? decoder.decode(JSONValue.self, from: chunk) else { continue }
                result.entries.append(json)
            }
        }
        return result
    }
}

/// The conversation entries of a transcript file plus the parent links of every entry.
///
/// A transcript is a tree: a rewind (`--resume-session-at`) continues from an earlier entry, so the old branch stays
/// in the file. The active conversation is the chain of parents from the newest entry.
struct ClaudeTranscriptData: Sendable {
    /// user, assistant and system lines, in file order.
    var entries: [JSONValue] = []
    /// uuid to parent uuid ("" for none) for every line with a uuid, including skipped ones such as attachments.
    var parents: [String: String] = [:]

    /// The entries on the active chain, oldest first. `leafOverride` is the entry a pending rewind or fork keeps (the
    /// engine clears it once the first turn after the rewind has ended); when it is in the file it is the leaf.
    func activeChain(leafOverride: String? = nil, includeSidechains: Bool = false) -> [JSONValue] {
        let candidates = entries.filter { includeSidechains || $0["isSidechain"]?.boolValue != true }
        guard let latest = candidates.last(where: { $0["uuid"]?.stringValue != nil })?["uuid"]?.stringValue else { return candidates }
        let leaf = leafOverride.flatMap { parents[$0] != nil ? $0 : nil } ?? latest
        let (members, broken) = chain(from: leaf)
        var firstMember = candidates.count
        if broken, let index = candidates.firstIndex(where: { $0["uuid"]?.stringValue.map(members.contains) ?? false }) {
            firstMember = index
        }
        return candidates.enumerated().compactMap { offset, entry in
            guard let uuid = entry["uuid"]?.stringValue else { return entry }
            if members.contains(uuid) { return entry }
            // A parent link the file does not contain: keep everything before the chain rather than lose history.
            return broken && offset < firstMember ? entry : nil
        }
    }

    private func chain(from leaf: String) -> (Set<String>, broken: Bool) {
        var members: Set<String> = []
        var current: String? = leaf
        while let uuid = current, !uuid.isEmpty, !members.contains(uuid) {
            guard let parent = parents[uuid] else { return (members, true) }
            members.insert(uuid)
            current = parent
        }
        return (members, false)
    }
}

/// Builds Ensemble transcript rows from the CLI's transcript lines (and parses edits for the Outputs panel).
struct ClaudeTranscriptBuilder {
    var rootID: String
    var directory: String?
    /// Texts Ensemble injected as synthetic messages; shown as notices, not as the user speaking.
    var syntheticTexts: Set<String> = []
    /// True when no turn is running: tool calls without a result were cut off.
    var finished = true
    /// Subagent files: every line is a sidechain line.
    var includeSidechains = false

    static let interruptedPrefix = "[Request interrupted by user"

    func items(from lines: [JSONValue]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var index: [String: Int] = [:]
        var tools: [String: (name: String, input: JSONValue?)] = [:]
        var counters: [String: Int] = [:]

        func upsert(_ item: TranscriptItem) {
            if let existing = index[item.id] {
                items[existing] = item
            } else {
                index[item.id] = items.count
                items.append(item)
            }
        }

        for line in lines {
            guard let type = line["type"]?.stringValue else { continue }
            if !includeSidechains, line["isSidechain"]?.boolValue == true { continue }
            let uuid = line["uuid"]?.stringValue ?? UUID().uuidString
            let date = ClaudeDates.parse(line["timestamp"]?.stringValue) ?? Date()
            switch type {
            case "user":
                if line["isMeta"]?.boolValue == true { continue }
                if line["isCompactSummary"]?.boolValue == true {
                    upsert(.notice(id: uuid, text: "Conversation compacted"))
                    continue
                }
                let content = line["message"]?["content"]
                let blocks: [JSONValue]
                if let text = content?.stringValue { blocks = [["type": "text", "text": .string(text)]] } else { blocks = content?.arrayValue ?? [] }
                var spoken: [String] = []
                for (offset, block) in blocks.enumerated() {
                    switch block["type"]?.stringValue {
                    case "text":
                        let text = Self.cleanUserText(block["text"]?.stringValue ?? "")
                        guard !text.isEmpty else { continue }
                        if text.hasPrefix(Self.interruptedPrefix) {
                            upsert(.notice(id: "\(uuid):\(offset)", text: "Interrupted"))
                        } else if syntheticTexts.contains(text) {
                            upsert(.notice(id: "\(uuid):\(offset)", text: text))
                        } else {
                            spoken.append(text)
                        }
                    case "image":
                        spoken.append("[image]")
                    case "tool_result":
                        guard let id = block["tool_use_id"]?.stringValue, let position = index[id],
                              case .tool(var info) = items[position] else { continue }
                        let isError = block["is_error"]?.boolValue ?? false
                        info.status = isError ? .failed : .succeeded
                        let text = ClaudeFormatting.resultText(block["content"])
                        info.outputPreview = text.isEmpty ? nil : ClaudeFormatting.trimmed(text)
                        let result = line["toolUseResult"] ?? line["tool_use_result"]
                        if !isError, case .object? = result {
                            info.diff = ClaudeFormatting.diff(toolName: info.name, input: tools[id]?.input, result: result, directory: directory)
                        }
                        items[position] = .tool(info)
                    default:
                        continue
                    }
                }
                if !spoken.isEmpty { upsert(.user(id: uuid, text: spoken.joined(separator: "\n\n"), date: date)) }

            case "assistant":
                guard let message = line["message"] else { continue }
                if line["isApiErrorMessage"]?.boolValue == true {
                    let text = ClaudeFormatting.resultText(message["content"])
                    upsert(.error(id: uuid, message: ClaudeStreamDecoder.friendlyError(text.isEmpty ? "The model request failed" : text)))
                    continue
                }
                guard let content = message["content"]?.arrayValue else { continue }
                let messageID = message["id"]?.stringValue ?? uuid
                let base: Int
                if content.count == 1, let explicit = line["apiBlockIndex"]?.intValue {
                    base = explicit
                } else {
                    base = counters[messageID] ?? 0
                }
                counters[messageID] = max(counters[messageID] ?? 0, base + content.count)
                for (offset, block) in content.enumerated() {
                    let itemID = ClaudeSessionIDs.block(messageID: messageID, index: base + offset)
                    switch block["type"]?.stringValue {
                    case "text":
                        guard let text = block["text"]?.stringValue, !text.isEmpty else { continue }
                        upsert(.agentText(id: itemID, text: text, agentID: nil, streaming: false))
                    case "thinking":
                        guard let text = block["thinking"]?.stringValue, !text.isEmpty else { continue }
                        upsert(.reasoning(id: itemID, text: text, streaming: false))
                    case "tool_use", "server_tool_use":
                        guard let id = block["id"]?.stringValue else { continue }
                        let name = block["name"]?.stringValue ?? "tool"
                        let input = block["input"]
                        tools[id] = (name, input)
                        if let position = index[id], case .tool = items[position] { continue }
                        var info = ToolCallInfo(id: id, name: name, title: ClaudeFormatting.title(name: name, input: input, directory: directory),
                                                inputJSON: ClaudeFormatting.inputJSON(input), status: .running)
                        if ClaudeFormatting.agentToolNames.contains(name) {
                            info.childSessionID = ClaudeSessionIDs.child(root: rootID, toolUseID: id)
                        }
                        upsert(.tool(info))
                    default:
                        continue
                    }
                }

            case "system":
                switch line["subtype"]?.stringValue {
                case "compact_boundary":
                    upsert(.notice(id: uuid, text: "Conversation compacted"))
                case "api_error":
                    upsert(.error(id: uuid, message: line["content"]?.stringValue ?? "The model request failed"))
                default:
                    if line["level"]?.stringValue == "error", let text = line["content"]?.stringValue, !text.isEmpty {
                        upsert(.error(id: uuid, message: text))
                    }
                }

            default:
                continue
            }
        }

        if finished {
            for position in items.indices {
                if case .tool(var info) = items[position], info.status == .running || info.status == .pending {
                    info.status = .failed
                    if info.outputPreview == nil { info.outputPreview = "No result: the turn ended before this finished." }
                    items[position] = .tool(info)
                }
            }
        }
        return items
    }

    /// Removes the CLI's injected tags from a user message.
    static func cleanUserText(_ text: String) -> String {
        var result = text
        for tag in ["system-reminder", "local-command-caveat"] {
            while let open = result.range(of: "<\(tag)>"), let close = result.range(of: "</\(tag)>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files changed by successful edit tool calls, newest content last.
    func changedFiles(from lines: [JSONValue]) -> [FileChange] {
        var tools: [String: (name: String, input: JSONValue?)] = [:]
        var order: [String] = []
        var changes: [String: FileChange] = [:]
        for line in lines {
            switch line["type"]?.stringValue {
            case "assistant":
                for block in line["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                    guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue,
                          ClaudeFormatting.editToolNames.contains(name) else { continue }
                    tools[id] = (name, block["input"])
                }
            case "user":
                for block in line["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                    guard let id = block["tool_use_id"]?.stringValue, let tool = tools[id], block["is_error"]?.boolValue != true else { continue }
                    let result = line["toolUseResult"] ?? line["tool_use_result"]
                    let rawPath = result?["filePath"]?.stringValue ?? tool.input?["file_path"]?.stringValue ?? tool.input?["notebook_path"]?.stringValue
                    guard let rawPath else { continue }
                    let path = ClaudeFormatting.displayPath(rawPath, directory: directory)
                    var additions = 0
                    var deletions = 0
                    for hunk in result?["structuredPatch"]?.arrayValue ?? [] {
                        for hunkLine in hunk["lines"]?.arrayValue ?? [] {
                            guard let text = hunkLine.stringValue else { continue }
                            if text.hasPrefix("+") { additions += 1 } else if text.hasPrefix("-") { deletions += 1 }
                        }
                    }
                    let created = result?["type"]?.stringValue == "create"
                    if created, additions == 0, let content = result?["content"]?.stringValue ?? tool.input?["content"]?.stringValue {
                        additions = content.split(separator: "\n", omittingEmptySubsequences: false).count
                        if content.hasSuffix("\n") { additions -= 1 }
                    }
                    let diff = ClaudeFormatting.diff(toolName: tool.name, input: tool.input, result: result, directory: directory)
                    if var existing = changes[path] {
                        existing.additions += additions
                        existing.deletions += deletions
                        if let diff { existing.diff = [existing.diff, diff].compactMap { $0 }.joined(separator: "\n") }
                        changes[path] = existing
                    } else {
                        order.append(path)
                        changes[path] = FileChange(path: path, kind: created ? .added : .modified, additions: additions,
                                                   deletions: deletions, diff: diff)
                    }
                }
            default:
                continue
            }
        }
        return order.compactMap { changes[$0] }
    }

    /// Agent tool calls in a transcript (to find which subagent started which).
    static func agentToolIDs(in lines: [JSONValue]) -> [String] {
        var ids: [String] = []
        for line in lines where line["type"]?.stringValue == "assistant" {
            for block in line["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                if let name = block["name"]?.stringValue, ClaudeFormatting.agentToolNames.contains(name), let id = block["id"]?.stringValue {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// The first user text of a transcript, for a title.
    static func firstPrompt(in lines: [JSONValue]) -> String? {
        for line in lines where line["type"]?.stringValue == "user" && line["isMeta"]?.boolValue != true {
            let content = line["message"]?["content"]
            let text = content?.stringValue ?? content?.arrayValue?.first(where: { $0["type"]?.stringValue == "text" })?["text"]?.stringValue
            if let text, !cleanUserText(text).isEmpty { return cleanUserText(text) }
        }
        return nil
    }
}

/// Where to cut a conversation for fork and rewind, in terms of the CLI's chain entries.
enum ClaudeHistory {
    static func isPrompt(_ entry: JSONValue) -> Bool {
        guard entry["type"]?.stringValue == "user", entry["isMeta"]?.boolValue != true,
              entry["isCompactSummary"]?.boolValue != true else { return false }
        let content = entry["message"]?["content"]
        if let text = content?.stringValue { return !text.isEmpty }
        return (content?.arrayValue ?? []).contains { ["text", "image"].contains($0["type"]?.stringValue ?? "") }
    }

    private static func toolResultIDs(_ entry: JSONValue) -> [String] {
        guard entry["type"]?.stringValue == "user" else { return [] }
        return (entry["message"]?["content"]?.arrayValue ?? []).compactMap {
            $0["type"]?.stringValue == "tool_result" ? $0["tool_use_id"]?.stringValue : nil
        }
    }

    private static func toolUseIDs(_ entry: JSONValue) -> [String] {
        guard entry["type"]?.stringValue == "assistant" else { return [] }
        return (entry["message"]?["content"]?.arrayValue ?? []).compactMap {
            ["tool_use", "server_tool_use"].contains($0["type"]?.stringValue ?? "") ? $0["id"]?.stringValue : nil
        }
    }

    private static func messageID(_ entry: JSONValue) -> String? {
        entry["type"]?.stringValue == "assistant" ? entry["message"]?["id"]?.stringValue : nil
    }

    /// The chain index of a transcript row id: an entry uuid (`uuid` or `uuid:n`), a text or thinking row
    /// (`msg_id:block`), or a tool call id. For tool calls, `preferResult` picks the entry with the result.
    static func index(of itemID: String, in chain: [JSONValue], preferResult: Bool) -> Int? {
        if let index = chain.firstIndex(where: { $0["uuid"]?.stringValue == itemID }) { return index }
        if let colon = itemID.lastIndex(of: ":") {
            let head = String(itemID[..<colon])
            let tail = Int(itemID[itemID.index(after: colon)...])
            if let index = chain.firstIndex(where: { $0["uuid"]?.stringValue == head }) { return index }
            if let tail {
                if let index = chain.firstIndex(where: { messageID($0) == head && $0["apiBlockIndex"]?.intValue == tail }) { return index }
                if let index = chain.lastIndex(where: { messageID($0) == head }) { return index }
            }
        }
        if preferResult, let index = chain.firstIndex(where: { toolResultIDs($0).contains(itemID) }) { return index }
        return chain.firstIndex(where: { toolUseIDs($0).contains(itemID) })
    }

    /// The entry a fork at `itemID` keeps (inclusive). The cut is moved forward to the end of that model message and
    /// past the results of its tool calls, so the kept history is always complete.
    static func forkPoint(at itemID: String, in chain: [JSONValue]) -> String? {
        guard var index = index(of: itemID, in: chain, preferResult: true) else { return nil }
        var open = Set(chain[...index].flatMap(toolUseIDs)).subtracting(chain[...index].flatMap(toolResultIDs))
        while index + 1 < chain.count {
            let next = chain[index + 1]
            let sameMessage = messageID(next) != nil && messageID(next) == messageID(chain[index])
            let results = toolResultIDs(next)
            let answersOpen = !results.isEmpty && !open.isDisjoint(with: results)
            guard sameMessage || answersOpen else { break }
            open.formUnion(toolUseIDs(next))
            open.subtract(results)
            index += 1
        }
        return chain[index]["uuid"]?.stringValue
    }

    struct Cut: Equatable, Sendable {
        /// The last entry kept, or nil when nothing is kept.
        var keep: String?
        /// The first removed user prompt: file checkpoints are taken per prompt, so files go back to this point.
        var restorePrompt: String?
    }

    /// Where a rewind to before `itemID` cuts. A cut inside a model message moves back to the start of that message.
    static func cut(before itemID: String, in chain: [JSONValue]) -> Cut? {
        guard var index = index(of: itemID, in: chain, preferResult: false) else { return nil }
        if !isPrompt(chain[index]), let firstTool = toolResultIDs(chain[index]).first,
           let issuer = chain.firstIndex(where: { toolUseIDs($0).contains(firstTool) }) {
            index = issuer
        }
        if let id = messageID(chain[index]) {
            while index > 0, messageID(chain[index - 1]) == id { index -= 1 }
        }
        let keep = index > 0 ? chain[index - 1]["uuid"]?.stringValue : nil
        let prompt = chain[index...].first(where: isPrompt)?["uuid"]?.stringValue
        return Cut(keep: keep, restorePrompt: prompt)
    }
}
