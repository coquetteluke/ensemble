import Foundation
import Observation

// Rewind with choices: what a rewind to before one of your messages puts back (code, conversation or both), the files
// it changes, and a notice with Redo afterwards. Engines adopt `EngineRewindControl`; the store falls back to
// `EngineHistoryControl` (one behaviour, no file list) for engines that only have that.

/// What a rewind puts back.
public enum RewindScope: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// Removes the message and everything after it, and puts the files back.
    case codeAndConversation
    /// Removes the message and everything after it; files stay as they are.
    case conversationOnly
    /// Puts the files back; the conversation stays.
    case codeOnly
    /// Replaces the message and everything after it with a summary.
    case summarizeFromHere

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codeAndConversation: "Code and conversation"
        case .conversationOnly: "Conversation only"
        case .codeOnly: "Code only"
        case .summarizeFromHere: "Summarize from here"
        }
    }

    /// What it does, in a line.
    public var detail: String {
        switch self {
        case .codeAndConversation: "Removes this message and everything after it, and puts the files back"
        case .conversationOnly: "Removes this message and everything after it, and keeps the files as they are"
        case .codeOnly: "Puts the files back, and keeps the whole conversation"
        case .summarizeFromHere: "Replaces this message and everything after it with a summary"
        }
    }

    public var symbol: String {
        switch self {
        case .codeAndConversation: "arrow.counterclockwise"
        case .conversationOnly: "text.bubble"
        case .codeOnly: "doc.badge.clock"
        case .summarizeFromHere: "text.append"
        }
    }

    /// True when files on disk change.
    public var restoresFiles: Bool { self == .codeAndConversation || self == .codeOnly }
    /// True when messages leave the conversation.
    public var removesMessages: Bool { self != .codeOnly }
}

/// One choice in the rewind sheet, with the reason when the session's engine cannot do it.
public struct RewindChoice: Hashable, Sendable, Identifiable {
    public var scope: RewindScope
    /// Why this is not available, or nil when it is.
    public var unavailableReason: String?

    public init(_ scope: RewindScope, unavailableReason: String? = nil) {
        self.scope = scope
        self.unavailableReason = unavailableReason
    }

    public var id: String { scope.rawValue }
    public var isAvailable: Bool { unavailableReason == nil }
}

/// What a rewind to before one message would do: the confirm sheet's content.
public struct RewindPlan: Hashable, Sendable {
    /// All four scopes in `RewindScope.allCases` order.
    public var choices: [RewindChoice]
    /// Files a code rewind changes, as the rewind changes them: a file the agent created is `.deleted`, one it
    /// deleted is `.added`, and the counts are lines the rewind adds and removes.
    public var files: [FileChange]
    /// True when `files` is known. Engines that cannot list files first leave it false.
    public var filesKnown: Bool
    /// What the file list leaves out (for example changes made by shell commands).
    public var filesNote: String?
    /// Your messages a conversation rewind removes (this one and every later one).
    public var messagesRemoved: Int
    /// True when the engine can undo the rewind afterwards (Redo in the notice).
    public var canRedo: Bool

    public init(choices: [RewindChoice], files: [FileChange] = [], filesKnown: Bool = true, filesNote: String? = nil,
                messagesRemoved: Int = 0, canRedo: Bool = false) {
        self.choices = RewindScope.allCases.map { scope in
            choices.first { $0.scope == scope } ?? RewindChoice(scope, unavailableReason: RewindReason.notOffered)
        }
        self.files = files
        self.filesKnown = filesKnown
        self.filesNote = filesNote
        self.messagesRemoved = messagesRemoved
        self.canRedo = canRedo
    }

    public func choice(_ scope: RewindScope) -> RewindChoice {
        choices.first { $0.scope == scope } ?? RewindChoice(scope, unavailableReason: RewindReason.notOffered)
    }

    /// The first available choice, preferring code and conversation.
    public var defaultScope: RewindScope? { choices.first(where: \.isAvailable)?.scope }

    /// Every choice unavailable for the same reason (an engine without rewind).
    public static func unavailable(_ reason: String) -> RewindPlan {
        RewindPlan(choices: RewindScope.allCases.map { RewindChoice($0, unavailableReason: reason) }, filesKnown: false)
    }

    /// For engines with only `EngineHistoryControl`: its one behaviour, without a file list or Redo.
    public static func basic(restoresFiles: Bool, messagesRemoved: Int) -> RewindPlan {
        let only = restoresFiles ? RewindScope.codeAndConversation : .conversationOnly
        let reason = restoresFiles ? RewindReason.alwaysRestoresFiles : RewindReason.neverRestoresFiles
        return RewindPlan(choices: RewindScope.allCases.map { scope in
            scope == only ? RewindChoice(scope) : RewindChoice(scope, unavailableReason: scope == .summarizeFromHere ? RewindReason.noSummary : reason)
        }, filesKnown: false, messagesRemoved: messagesRemoved)
    }
}

/// Reasons shown for choices an engine cannot do.
public enum RewindReason {
    public static let notOffered = "This engine does not offer this"
    public static let alwaysRestoresFiles = "This engine always puts the files back when it rewinds"
    public static let neverRestoresFiles = "This engine cannot put files back"
    public static let noSummary = "This engine cannot summarize part of a conversation"
    public static let working = "Unavailable while the agent is working"
    public static let noFiles = "No files changed after this message"
    public static func noRewind(_ engine: String) -> String { "\(engine) sessions cannot rewind" }
}

/// What a rewind did.
public struct RewindOutcome: Hashable, Sendable {
    public var scope: RewindScope
    /// Files put back, as in `RewindPlan.files`.
    public var files: [FileChange]
    public var messagesRemoved: Int
    /// True when `EngineRewindControl.redoRewind` can undo it now.
    public var canRedo: Bool

    public init(scope: RewindScope, files: [FileChange] = [], messagesRemoved: Int = 0, canRedo: Bool = false) {
        self.scope = scope
        self.files = files
        self.messagesRemoved = messagesRemoved
        self.canRedo = canRedo
    }
}

/// Rewind with choices. An engine adopts it when it can say what a rewind would change before doing it; the store
/// checks with `as?`.
public protocol EngineRewindControl: Sendable {
    /// What a rewind to before `messageID` (one of your messages, by engine id) would do. Changes nothing.
    func rewindPlan(_ sessionID: String, toBeforeMessageID messageID: String) async throws -> RewindPlan
    /// Rewinds. Throws for a scope the plan marks unavailable.
    func rewind(_ sessionID: String, toBeforeMessageID messageID: String, scope: RewindScope) async throws -> RewindOutcome
    /// Undoes the session's last rewind, while nothing was sent since. Throws when there is nothing to undo.
    func redoRewind(_ sessionID: String) async throws
}

extension FileChange {
    /// The same change seen from the rewind: what the agent added the rewind removes, and the other way round.
    public var reversed: FileChange {
        let kind: Kind = switch self.kind {
        case .added: .deleted
        case .deleted: .added
        case .modified: .modified
        }
        return FileChange(path: path, kind: kind, additions: deletions, deletions: additions, diff: nil)
    }
}

// MARK: Store state

/// The rewind sheet while it is open.
public struct RewindRequest: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready(RewindPlan)
        /// The plan could not be read.
        case failed(String)
        /// A rewind is running.
        case working(RewindPlan, RewindScope)
    }

    public var id: String
    public var sessionID: String
    /// The message's id in the transcript (may be a local id until the transcript reloads).
    public var messageID: String
    /// The message's first line, for the sheet's header.
    public var messageText: String
    public var phase: Phase
    /// The choice the sheet has selected.
    public var selected: RewindScope?
    /// Why the last confirm failed.
    public var error: String?

    public init(id: String = UUID().uuidString, sessionID: String, messageID: String, messageText: String,
                phase: Phase = .loading, selected: RewindScope? = nil, error: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.messageText = messageText
        self.phase = phase
        self.selected = selected
        self.error = error
    }

    public var plan: RewindPlan? {
        switch phase {
        case .ready(let plan), .working(let plan, _): plan
        case .loading, .failed: nil
        }
    }

    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }
}

/// The line left in the transcript after a rewind, with Redo while the engine can undo it.
public struct RewindNotice: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case done
        case redoing
        /// Redo ran.
        case redone
    }

    /// The transcript item id (`rewind-<uuid>`).
    public var id: String
    public var sessionID: String
    public var outcome: RewindOutcome
    public var state: State
    /// A newer rewind in the same session replaced this one's Redo.
    public var superseded = false
    public var error: String?

    public init(id: String, sessionID: String, outcome: RewindOutcome, state: State = .done) {
        self.id = id
        self.sessionID = sessionID
        self.outcome = outcome
        self.state = state
    }

    /// "Rewound code and conversation: 2 messages removed, 3 files put back".
    public var text: String {
        if state == .redone { return "Rewind undone: the conversation and files are back as they were" }
        let messages = outcome.messagesRemoved == 1 ? "1 message removed" : "\(outcome.messagesRemoved) messages removed"
        let files = outcome.files.count == 1 ? "1 file put back" : "\(outcome.files.count) files put back"
        switch outcome.scope {
        case .codeAndConversation:
            return outcome.files.isEmpty ? "Rewound the conversation: \(messages), no files to put back"
                : "Rewound code and conversation: \(messages), \(files)"
        case .conversationOnly: return "Rewound the conversation: \(messages), files kept"
        case .codeOnly: return outcome.files.isEmpty ? "No files to put back" : "Rewound code: \(files), conversation kept"
        case .summarizeFromHere: return "Summarized from here: \(messages)"
        }
    }

    public static func makeID() -> String { "rewind-\(UUID().uuidString)" }
}

/// Rewind state of one store: the open sheet and the notices left after rewinds. Held by `SessionStore.rewinds`; the
/// logic lives in `Rewind+Store.swift`.
@Observable @MainActor
public final class SessionRewindState {
    /// The open rewind sheet.
    public internal(set) var request: RewindRequest?
    /// Notices by transcript item id.
    public internal(set) var notices: [String: RewindNotice] = [:]
    @ObservationIgnored var planTask: Task<Void, Never>?

    nonisolated public init() {}

    /// Fills the state without an engine (previews and snapshots).
    public func seedPreview(request: RewindRequest? = nil, notices: [RewindNotice] = []) {
        self.request = request
        self.notices = Dictionary(notices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
