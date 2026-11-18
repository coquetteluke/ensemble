import Foundation

// Optional engine abilities. An engine adopts the ones it supports; the UI checks with `as?` and
// greys out what an engine cannot do. Kept separate from `OpenCodeAPI` so adding them never breaks
// an engine that does not have them yet.

/// Fork, rewind and edit-and-resend from a point in a session's history.
public protocol EngineHistoryControl: Sendable {
    /// A new session with the history up to and including `messageID` (the whole session when nil).
    func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession
    /// Removes `messageID` and everything after it from the session, and restores files the agent
    /// changed after that point when the engine can.
    func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws
    /// Whether rewind also restores files (otherwise only the conversation goes back).
    var rewindRestoresFiles: Bool { get }
}

/// How hard a model thinks, where the model supports it.
public enum EffortLevel: String, Codable, CaseIterable, Sendable {
    case low, medium, high, xhigh, max

    public var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
}

/// Per-model options shown in the composer.
public struct ModelOptions: Codable, Hashable, Sendable {
    /// Effort levels this model accepts, in order. Empty means the model has no effort setting.
    public var effortLevels: [EffortLevel]
    public var defaultEffort: EffortLevel?
    /// True when the model has a faster mode (for example Claude's fast mode).
    public var supportsFastMode: Bool

    public init(effortLevels: [EffortLevel] = [], defaultEffort: EffortLevel? = nil, supportsFastMode: Bool = false) {
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
        self.supportsFastMode = supportsFastMode
    }
}

/// Effort and fast mode for a session.
public protocol EngineModelOptionsControl: Sendable {
    func modelOptions(for model: ModelRef) async throws -> ModelOptions
    /// Applies to the session's next turn.
    func setEffort(_ sessionID: String, effort: EffortLevel?) async throws
    func setFastMode(_ sessionID: String, enabled: Bool) async throws
}

/// A slash command or skill the engine offers in the composer's `/` menu.
public struct EngineCommand: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case command, skill }
    /// Without the leading slash.
    public var name: String
    public var summary: String
    public var kind: Kind
    /// Shown greyed after the name, e.g. "<file>".
    public var argumentHint: String?
    public var id: String { "\(kind.rawValue):\(name)" }

    public init(name: String, summary: String, kind: Kind, argumentHint: String? = nil) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.argumentHint = argumentHint
    }
}

/// The engine's own slash commands and skills.
public protocol EngineCommandsControl: Sendable {
    func commands(directory: String?) async throws -> [EngineCommand]
    func runCommand(_ sessionID: String, name: String, arguments: String) async throws
}
