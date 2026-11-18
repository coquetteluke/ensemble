import Foundation

/// Context window use for the right-hand panel ("47% used, 466.9k / 1M").
public struct ContextBreakdown: Codable, Hashable, Sendable {
    public struct Category: Codable, Hashable, Sendable, Identifiable {
        /// Stable key used for the colour: messages, tools, systemPrompt, skills, mcp, memory, agents, buffer, free.
        public var key: String
        public var label: String
        public var tokens: Int
        public var id: String { key }

        public init(key: String, label: String, tokens: Int) {
            self.key = key
            self.label = label
            self.tokens = tokens
        }
    }

    public var usedTokens: Int
    public var limitTokens: Int
    public var categories: [Category]

    public init(usedTokens: Int, limitTokens: Int, categories: [Category]) {
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.categories = categories
    }

    public var fractionUsed: Double {
        limitTokens > 0 ? min(1, Double(usedTokens) / Double(limitTokens)) : 0
    }
}

/// A file a session created or changed (the "Outputs" list).
public struct FileChange: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case added, modified, deleted }
    public var path: String
    public var kind: Kind
    public var additions: Int
    public var deletions: Int
    public var diff: String?
    public var id: String { path }

    public init(path: String, kind: Kind, additions: Int = 0, deletions: Int = 0, diff: String? = nil) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.diff = diff
    }
}

/// An MCP server ("Connectors").
public struct ConnectorInfo: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case connected, needsAuth, failed, disabled, connecting }
    public var id: String
    public var name: String
    public var state: State
    public var toolCount: Int

    public init(id: String, name: String, state: State, toolCount: Int = 0) {
        self.id = id
        self.name = name
        self.state = state
        self.toolCount = toolCount
    }
}

/// Engine health shown in settings and the status line.
public enum EngineStatus: Equatable, Sendable {
    case notInstalled
    case tooOld(found: String, required: String)
    case starting
    case running(version: String, url: URL)
    case failed(String)
}
