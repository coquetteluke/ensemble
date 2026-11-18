import Foundation

// The safety check for Auto: OpenCode agents in Auto ask before every command outside a short read-only list
// (`PermissionRules.autoAllowedShell`). With the check on, each such prompt is first run past fixed rules that always
// ask (`SafetyCheckHardRules`, lists in `PermissionRules`), then past a small model (`SafetyCheckClassifier`) that
// answers ALLOW or ASK. ALLOW answers the prompt "once" for the user; ASK, a timeout, an error or an answer that does
// not parse leaves the prompt for the user. The model never denies anything.
//
// Claude and Gemini agents are not checked: their own auto modes already decide, and the prompts they send in Auto are
// the ones their own checks escalated.

/// What the safety check decided for one prompt.
public enum SafetyCheckVerdict: String, Codable, Hashable, Sendable {
    /// Answered "once" for the user.
    case allow
    /// Left for the user.
    case ask
}

/// What a decision rests on.
public enum SafetyCheckBasis: String, Codable, Hashable, Sendable {
    /// A fixed rule asked before any model call.
    case rule
    /// The model answered.
    case model
    /// The same prompt was answered by the model earlier in this session.
    case cache
    /// The check timed out, failed, had no model, or the answer did not parse; the prompt was left for the user.
    case failed
}

/// One decision, for the tool card badge and the session's list.
public struct SafetyCheckDecision: Identifiable, Hashable, Sendable {
    public var id: String { requestID }
    public var requestID: String
    /// The session that asked (a subagent's own id for its prompts).
    public var sessionID: String
    /// The tool call the prompt belongs to, when known.
    public var toolCallID: String?
    /// The permission action (`shell`, `edit`, `webfetch`, ...).
    public var action: String
    /// What was checked, made visible in full (the command, path or address).
    public var subject: String
    public var verdict: SafetyCheckVerdict
    public var basis: SafetyCheckBasis
    /// One line: why.
    public var reason: String
    /// The model that answered (model and cache decisions).
    public var model: ModelRef?
    public var date: Date

    public init(requestID: String, sessionID: String, toolCallID: String? = nil, action: String, subject: String,
                verdict: SafetyCheckVerdict, basis: SafetyCheckBasis, reason: String, model: ModelRef? = nil, date: Date = Date()) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.action = action
        self.subject = subject
        self.verdict = verdict
        self.basis = basis
        self.reason = reason
        self.model = model
        self.date = date
    }

    /// True when the safety check answered the prompt for the user.
    public var allowed: Bool { verdict == .allow }
}

/// What the check looks at for one prompt. Everything here except `action` and `directory` can hold text an agent or
/// a file wrote, so the classifier only ever sees it fenced as data.
public struct SafetyCheckQuery: Hashable, Sendable {
    /// The permission action (`shell`, `webfetch`, ...).
    public var action: String
    /// What the engine asks about: for `shell`, each command of the line that needs permission.
    public var resources: [String]
    /// The whole command line from the tool call, when known (it can include parts the rules already allow).
    public var command: String?
    /// The session's folder.
    public var directory: String
    /// The user's latest message in the session, cut to `SafetyCheckClassifier.instructionLimit`.
    public var instruction: String

    public init(action: String, resources: [String], command: String? = nil, directory: String, instruction: String = "") {
        self.action = action
        self.resources = resources
        self.command = command
        self.directory = directory
        self.instruction = instruction
    }

    /// The text a decision is shown and cached under: the whole command when known, else the resources.
    public var subject: String {
        if let command, !command.isEmpty { return command }
        return resources.joined(separator: "\n")
    }

    /// Identical prompts share a cache entry within a session (the instruction is left out on purpose: the same command
    /// in the same folder gets the same answer).
    var cacheKey: String {
        [action, resources.joined(separator: "\n"), command ?? "", directory].joined(separator: "\u{1F}")
    }
}

/// A model the safety check can use, with its price.
public struct SafetyCheckModel: Identifiable, Hashable, Sendable {
    public var ref: ModelRef
    public var name: String
    public var providerName: String?
    /// US dollars per million input tokens (0 for free models).
    public var inputCostPerMillion: Double
    /// US dollars per million output tokens.
    public var outputCostPerMillion: Double
    /// False for a session's own model the engine's list does not include: its price is not known (counted as 0).
    public var priceKnown: Bool

    public var id: String { ref.description }

    public init(ref: ModelRef, name: String, providerName: String? = nil, inputCostPerMillion: Double = 0,
                outputCostPerMillion: Double = 0, priceKnown: Bool = true) {
        self.ref = ref
        self.name = name
        self.providerName = providerName
        self.inputCostPerMillion = inputCostPerMillion
        self.outputCostPerMillion = outputCostPerMillion
        self.priceKnown = priceKnown
    }

    /// Typical tokens of one check (the fixed instructions plus a short command and message), for comparing prices.
    static let typicalInputTokens = 700.0
    static let typicalOutputTokens = 20.0

    /// What one typical check costs with this model, in US dollars.
    public var typicalCheckCost: Double {
        (inputCostPerMillion * Self.typicalInputTokens + outputCostPerMillion * Self.typicalOutputTokens) / 1_000_000
    }

    /// Cheap enough to turn the check on by itself: a known price of at most $1 per million input tokens and $5 per
    /// million output tokens (about a tenth of a cent per check).
    public var isCheap: Bool { priceKnown && inputCostPerMillion <= 1 && outputCostPerMillion <= 5 }
}

/// The user's settings (Settings > General > Safety check for Auto).
public struct SafetyCheckSettings: Codable, Hashable, Sendable {
    /// On or off. Nil means not chosen: on for a session whose check model (below) is cheap.
    public var enabled: Bool?
    /// The model to use for every session, whatever its provider. Nil, or a model that is no longer available, uses a
    /// model from each session's own provider (`SafetyCheckClassifier.choose`), so the check sends nothing to a provider
    /// the session does not already use.
    public var model: ModelRef?
    /// Also check shell commands in Accept edits (edits there are never sent to the model).
    public var checkAcceptEdits: Bool
    /// How long the model may take before the prompt is left for the user.
    public var timeout: Duration

    public init(enabled: Bool? = nil, model: ModelRef? = nil, checkAcceptEdits: Bool = false, timeout: Duration = .seconds(5)) {
        self.enabled = enabled
        self.model = model
        self.checkAcceptEdits = checkAcceptEdits
        self.timeout = timeout
    }

    /// `UserDefaults` keys the Mac app's Settings section writes and the store reads at start.
    public enum Key {
        /// `"on"`, `"off"`, or absent (not chosen).
        public static let enabled = "safetyCheck.enabled"
        /// A `ModelRef` description, or absent for a model from the session's own provider.
        public static let model = "safetyCheck.model"
        public static let checkAcceptEdits = "safetyCheck.acceptEdits"
    }

    /// The settings saved in `defaults`.
    public static func load(from defaults: UserDefaults) -> SafetyCheckSettings {
        var settings = SafetyCheckSettings()
        switch defaults.string(forKey: Key.enabled) {
        case "on": settings.enabled = true
        case "off": settings.enabled = false
        default: settings.enabled = nil
        }
        settings.model = defaults.string(forKey: Key.model).flatMap(ModelRef.init(string:))
        settings.checkAcceptEdits = defaults.bool(forKey: Key.checkAcceptEdits)
        return settings
    }
}

/// Classifier tokens per top-level session, shown as "Safety check" usage. OpenCode's one-off generation does not report
/// tokens, so they are estimated from the text (about four characters a token) and priced with the model's list price.
public struct SafetyCheckUsage: Hashable, Sendable {
    /// Model calls made (cache hits and rule decisions cost nothing).
    public var checks: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double

    public init(checks: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double = 0) {
        self.checks = checks
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    /// As a `Usage`, for totals that add up session usage.
    public var asUsage: Usage { Usage(inputTokens: inputTokens, outputTokens: outputTokens, costUSD: costUSD) }
}

/// Engines whose sessions the safety check decides, and what it needs from them. The OpenCode client and the router
/// adopt it; other engines (Claude, ACP agents, the preview engine) do not, so their prompts are never checked.
public protocol EngineSafetyCheckSupport: Sendable {
    /// True when the session's prompts may be decided by Ensemble's safety check (OpenCode sessions).
    func safetyCheckApplies(to sessionID: String) -> Bool
    /// The tool call a permission prompt belongs to, or nil when unknown.
    func toolCallID(forPermission requestID: String, sessionID: String) async -> String?
    /// One stateless model call with no tools and no session: `prompt` in, the model's text out.
    func generateSafetyCheckText(prompt: String, model: ModelRef) async throws -> String
    /// Models the check can use, with their prices.
    func safetyCheckModels() async throws -> [SafetyCheckModel]
}
