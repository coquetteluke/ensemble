import Foundation

/// Formats a conversation transcript as GitHub-flavored Markdown and parses model-switch notices.
public enum TranscriptExport {
    /// Renders a transcript as clean GitHub-flavored Markdown.
    public static func markdown(
        title: String,
        directory: String? = nil,
        modelName: String? = nil,
        items: [TranscriptItem],
        agents: [UUID: AgentSpec] = [:]
    ) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = ["# \(heading.isEmpty ? "Conversation" : heading)"]

        var metadataParts: [String] = []
        if let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            metadataParts.append("Folder: `\(directory)`")
        }
        if let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !modelName.isEmpty {
            metadataParts.append("Model: \(modelName)")
        }
        if !metadataParts.isEmpty {
            sections.append(metadataParts.joined(separator: " \u{00B7} "))
        }

        var pendingToolLines: [String] = []
        func flushTools() {
            guard !pendingToolLines.isEmpty else { return }
            sections.append(pendingToolLines.joined(separator: "\n"))
            pendingToolLines.removeAll()
        }

        for item in items {
            switch item {
            case .user(_, let text, _):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                flushTools()
                sections.append("## You\n\n\(body)")

            case .agentText(_, let text, let agentID, _):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                flushTools()
                let speaker = agentID.flatMap { agents[$0]?.name } ?? "Assistant"
                sections.append("## \(speaker)\n\n\(body)")

            case .tool(let tool):
                let rawTitle = tool.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = rawTitle.isEmpty ? (fallback.isEmpty ? "Tool" : fallback) : rawTitle
                pendingToolLines.append("- Tool: \(label) (\(tool.status.rawValue))")

            case .board(_, let fromAgentID, let toAgentIDs, let text, _):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                flushTools()
                let sender = agents[fromAgentID]?.name ?? "Agent"
                let recipients = toAgentIDs.compactMap { agents[$0]?.name }
                let content = recipients.isEmpty
                    ? "\(sender): \(body)"
                    : "\(sender) to \(recipients.joined(separator: ", ")): \(body)"
                sections.append(italicBlockquote(content))

            case .notice(_, let text):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                flushTools()
                sections.append(italicBlockquote(body))

            case .error(_, let message):
                let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                flushTools()
                sections.append(blockquote("Error: \(body)"))

            case .reasoning, .permission:
                continue
            }
        }

        flushTools()
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Extracts the target model name from a mid-chat switch notice such as
    /// `"Switched to Gemini 4"` or `"Switched to Haiku 5.5 for this message"`.
    public static func switchedModelName(fromNotice text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Switched to "
        guard trimmed.hasPrefix(prefix) else { return nil }

        var remainder = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = remainder.lowercased()
        if lowercased == "agent" || lowercased.hasPrefix("agent ") {
            return nil
        }
        if remainder == "for this message" {
            return nil
        }

        let suffix = " for this message"
        if remainder.hasSuffix(suffix) {
            remainder = String(remainder.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !remainder.isEmpty else { return nil }
        return remainder
    }

    private static func blockquote(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in line.isEmpty ? ">" : "> \(line)" }
            .joined(separator: "\n")
    }

    private static func italicBlockquote(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? ">" : "> *\(trimmed)*"
            }
            .joined(separator: "\n")
    }
}
