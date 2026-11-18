import Foundation

/// Context panel numbers for Claude agents.
enum ClaudeContext {
    /// Maps the CLI's own `get_context_usage` answer (the numbers `/context` shows) onto Ensemble's categories.
    /// Deferred tools (loaded on demand) are left out, as the CLI does.
    static func breakdown(from response: JSONValue) -> ContextBreakdown? {
        guard let categories = response["categories"]?.arrayValue else { return nil }
        var tokens: [String: Int] = [:]
        var order: [String] = []
        let labels = ["messages": "Messages", "tools": "Tools", "systemPrompt": "System prompt", "skills": "Skills", "mcp": "MCP",
                      "memory": "Memory files", "agents": "Agents", "buffer": "Autocompact buffer", "free": "Free space"]
        for category in categories {
            guard category["kind"]?.stringValue != "deferred", category["isDeferred"]?.boolValue != true,
                  let id = category["id"]?.stringValue, let count = category["tokens"]?.intValue else { continue }
            let key: String
            switch id {
            case "system_prompt": key = "systemPrompt"
            case "system_tools": key = "tools"
            case "mcp_tools", "mcp_instructions": key = "mcp"
            case "custom_agents": key = "agents"
            case "memory_files": key = "memory"
            case "skills": key = "skills"
            case "messages": key = "messages"
            case "autocompact_buffer": key = "buffer"
            case "free_space": key = "free"
            default: key = "systemPrompt"
            }
            if tokens[key] == nil { order.append(key) }
            tokens[key, default: 0] += count
        }
        let limit = response["maxTokens"]?.intValue ?? response["rawMaxTokens"]?.intValue ?? 0
        let used = response["totalTokens"]?.intValue
            ?? tokens.filter { $0.key != "buffer" && $0.key != "free" }.values.reduce(0, +)
        let items = order.map { ContextBreakdown.Category(key: $0, label: labels[$0] ?? $0, tokens: tokens[$0] ?? 0) }
        return ContextBreakdown(usedTokens: used, limitTokens: limit, categories: items)
    }

    /// A best estimate when no agent process is running: the newest model call's real token count against the model's
    /// context window. The CLI does not split it, so everything used is shown as Messages.
    static func estimate(usedTokens: Int?, limit: Int?) -> ContextBreakdown {
        let used = max(0, usedTokens ?? 0)
        let window = max(0, limit ?? 0)
        var categories = [ContextBreakdown.Category(key: "messages", label: "Messages", tokens: used)]
        if window > 0 {
            let buffer = min(33_000, max(0, window - used))
            categories.append(.init(key: "buffer", label: "Autocompact buffer", tokens: buffer))
            categories.append(.init(key: "free", label: "Free space", tokens: max(0, window - used - buffer)))
        }
        return ContextBreakdown(usedTokens: used, limitTokens: window, categories: categories)
    }
}
