import Foundation
import Observation

/// The safety check's state in a store (`SessionStore.safetyCheck`): settings, the models it can use, the decisions and
/// classifier usage per top-level session, the prompts being checked, and the per-session cache.
@MainActor @Observable
public final class SafetyCheckState {
    /// The user's settings. The Mac app's Settings section saves them in `UserDefaults` (`SafetyCheckSettings.Key`) and
    /// sets them here; a new store reads the saved ones.
    public var settings: SafetyCheckSettings
    /// Models the check can use (from the engine), loaded on first use and by the Settings section.
    public internal(set) var models: [SafetyCheckModel] = []
    /// True once the model list was asked for (even if it came back empty or failed).
    public internal(set) var modelsLoaded = false
    /// Decisions by top-level session id, oldest first.
    public internal(set) var decisionsBySession: [String: [SafetyCheckDecision]] = [:]
    /// Classifier usage by top-level session id.
    public internal(set) var usageBySession: [String: SafetyCheckUsage] = [:]
    /// Prompts being checked now (request ids); they are not shown until the check leaves them for the user.
    public internal(set) var checking: Set<String> = []

    /// Prompts the check has finished with (shown, answered or dropped); never held again.
    @ObservationIgnored var released: Set<String> = []
    @ObservationIgnored private var visiblePermissionContinuations: [UUID: AsyncStream<PermissionRequest>.Continuation] = [:]
    @ObservationIgnored var cache: [String: [String: CachedAnswer]] = [:]
    @ObservationIgnored var cacheOrder: [String: [String]] = [:]
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var modelsLoadedAt: Date?
    @ObservationIgnored var modelsTask: Task<Void, Never>?
    /// Makes each request's marker code (tests pass a fixed one).
    @ObservationIgnored public var makeNonce: @Sendable () -> String = { SafetyCheckClassifier.makeNonce() }
    /// Where allowed tool calls get their badge (tests and snapshots may pass their own).
    @ObservationIgnored public var badges: SafetyCheckBadges = .shared

    struct CachedAnswer: Hashable, Sendable {
        var verdict: SafetyCheckVerdict
        var reason: String
        var model: ModelRef?
    }

    /// Decisions kept per session.
    public static let decisionLimit = 200
    /// Cached answers kept per session.
    public static let cacheLimit = 200
    /// How long a model list is used before it is asked for again (a new API key adds models).
    public static let modelListLifetime: TimeInterval = 600

    /// `defaults` nil starts from the default settings; otherwise the saved settings are read once. By default they are
    /// read only inside the app (not in test runners), like the store's other saved files.
    public init(settings: SafetyCheckSettings? = nil, defaults: UserDefaults? = SafetyCheckState.appDefaults()) {
        self.settings = settings ?? defaults.map(SafetyCheckSettings.load(from:)) ?? SafetyCheckSettings()
    }

    /// `UserDefaults.standard` inside an app bundle, else nil.
    public nonisolated static func appDefaults(bundle: Bundle = .main) -> UserDefaults? {
        bundle.bundleURL.pathExtension == "app" ? .standard : nil
    }

    // MARK: Model and switch

    /// The model the check uses for a session on `sessionModel`: the one chosen in Settings while it is available, else
    /// one from the session's own provider (`SafetyCheckClassifier.choose`).
    public func classifierModel(forSession sessionModel: ModelRef?) -> SafetyCheckModel? {
        SafetyCheckClassifier.choose(from: models, preferred: settings.model, sessionModel: sessionModel)
    }

    /// Whether checks run: on, off, or not known until the model list is loaded (switch not chosen).
    public enum Readiness: Sendable { case on, off, unknown }

    /// Whether a session on `sessionModel` is checked. Switch not chosen: only when its check model is cheap.
    public func readiness(forSession sessionModel: ModelRef?) -> Readiness {
        switch settings.enabled {
        case true?: return .on
        case false?: return .off
        case nil:
            guard modelsLoaded else { return .unknown }
            return (classifierModel(forSession: sessionModel)?.isCheap ?? false) ? .on : .off
        }
    }

    /// The Settings switch: on unless turned off.
    public var isOn: Bool { settings.enabled != false }

    // MARK: Reading

    /// A session's decisions, newest first. `rootSessionID` is the top-level session.
    public func decisions(forRoot rootSessionID: String) -> [SafetyCheckDecision] {
        (decisionsBySession[rootSessionID] ?? []).reversed()
    }

    public func usage(forRoot rootSessionID: String) -> SafetyCheckUsage {
        usageBySession[rootSessionID] ?? SafetyCheckUsage()
    }

    // MARK: Recording

    func record(_ decision: SafetyCheckDecision, rootSessionID: String) {
        var list = decisionsBySession[rootSessionID] ?? []
        list.removeAll { $0.requestID == decision.requestID }
        list.append(decision)
        if list.count > Self.decisionLimit { list.removeFirst(list.count - Self.decisionLimit) }
        decisionsBySession[rootSessionID] = list
        if let toolCallID = decision.toolCallID {
            badges.setChecking(toolCallID, false)
            if decision.allowed { badges.setAllowed(decision, for: toolCallID) }
        }
    }

    func addUsage(rootSessionID: String, prompt: String, answer: String?, model: SafetyCheckModel) {
        let input = SafetyCheckClassifier.estimatedTokens(prompt)
        let output = answer.map(SafetyCheckClassifier.estimatedTokens) ?? 0
        var usage = usageBySession[rootSessionID] ?? SafetyCheckUsage()
        usage.checks += 1
        usage.inputTokens += input
        usage.outputTokens += output
        usage.costUSD += (Double(input) * model.inputCostPerMillion + Double(output) * model.outputCostPerMillion) / 1_000_000
        usageBySession[rootSessionID] = usage
    }

    func cachedAnswer(rootSessionID: String, key: String) -> CachedAnswer? {
        cache[rootSessionID]?[key]
    }

    func remember(_ answer: CachedAnswer, rootSessionID: String, key: String) {
        var entries = cache[rootSessionID] ?? [:]
        var order = cacheOrder[rootSessionID] ?? []
        if entries[key] == nil { order.append(key) }
        entries[key] = answer
        while order.count > Self.cacheLimit {
            entries[order.removeFirst()] = nil
        }
        cache[rootSessionID] = entries
        cacheOrder[rootSessionID] = order
    }

    /// Forgets the cached answers (all sessions, or one).
    public func clearCache(rootSessionID: String? = nil) {
        if let rootSessionID {
            cache[rootSessionID] = nil
            cacheOrder[rootSessionID] = nil
        } else {
            cache = [:]
            cacheOrder = [:]
        }
    }

    func markReleased(_ requestID: String) {
        if released.count > 5000 { released.removeAll() }
        released.insert(requestID)
    }

    /// True while the safety check is deciding `requestID` and keeping it out of the session's open prompts.
    public func isHolding(_ requestID: String) -> Bool {
        checking.contains(requestID)
    }

    /// Live stream of permission prompts that cleared the safety check and entered a session's `pendingPermissions`.
    public func visiblePermissions() -> AsyncStream<PermissionRequest> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: PermissionRequest.self, bufferingPolicy: .bufferingNewest(512))
        visiblePermissionContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.visiblePermissionContinuations[id] = nil }
        }
        return stream
    }

    func notifyPermissionVisible(_ request: PermissionRequest) {
        for continuation in visiblePermissionContinuations.values { continuation.yield(request) }
    }

    // MARK: Previews and snapshots

    /// Fills the state without an engine. Allowed decisions with a tool call get their badge.
    public func seed(models: [SafetyCheckModel] = [], decisions: [String: [SafetyCheckDecision]] = [:],
                     usage: [String: SafetyCheckUsage] = [:]) {
        self.models = models
        modelsLoaded = true
        modelsLoadedAt = Date()
        for (root, list) in decisions {
            for decision in list { record(decision, rootSessionID: root) }
        }
        usageBySession.merge(usage) { _, new in new }
    }

    /// Sets the model list directly (tests).
    public func setModels(_ list: [SafetyCheckModel]) {
        models = list
        modelsLoaded = true
        modelsLoadedAt = Date()
    }
}

/// The "Checked" badges on tool cards: the decisions that allowed each tool call, by tool call id, and the calls being
/// checked. One shared registry, because tool cards are drawn without a store; the store's safety check writes to it.
@MainActor @Observable
public final class SafetyCheckBadges {
    public static let shared = SafetyCheckBadges()

    public private(set) var allowed: [String: SafetyCheckDecision] = [:]
    public private(set) var checking: Set<String> = []

    public init() {}

    /// The decision that allowed this tool call, if the safety check did.
    public func decision(forToolCall id: String) -> SafetyCheckDecision? { allowed[id] }

    public func isChecking(_ toolCallID: String) -> Bool { checking.contains(toolCallID) }

    public func setAllowed(_ decision: SafetyCheckDecision, for toolCallID: String) {
        if allowed.count > 5000 { allowed.removeAll() }
        allowed[toolCallID] = decision
    }

    public func setChecking(_ toolCallID: String, _ on: Bool) {
        if on { checking.insert(toolCallID) } else { checking.remove(toolCallID) }
    }
}
