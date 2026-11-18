import Foundation
import Observation
import Synchronization

/// Keeps the usage ledger (`UsageLedger`) up to date from a store's sessions, saves it with the spending caps, and
/// answers the Usage view and the cap checks.
///
/// `attach(to:)` reads every session's running total once (counting growth since the last launch on each session's
/// last activity day), then every few seconds (counting growth on the day it is seen). Who pays for each model comes
/// from the engine (`EngineModelBilling`), re-read every ten minutes; costs count only for models billed to API keys.
@MainActor @Observable
public final class UsageTracker {
    public private(set) var ledger = UsageLedger()
    /// Daily spending caps in US dollars, by provider id. They only ever apply to providers billed to an API key.
    public private(set) var caps: [String: Double] = [:]
    /// Who pays for each model (`ModelBilling.key`) or provider, from the engine.
    public private(set) var billing: [String: ModelBilling] = [:]
    /// The last problem reading or saving the file, in a line.
    public var lastError: String?

    @ObservationIgnored public let storage: any UsageStorage
    @ObservationIgnored public private(set) weak var store: SessionStore?
    @ObservationIgnored public var now: () -> Date
    @ObservationIgnored public var calendar: Calendar
    @ObservationIgnored public var sampleInterval: Duration = .seconds(5)
    @ObservationIgnored public var billingInterval: TimeInterval = 600
    @ObservationIgnored var sampledOnce = false
    @ObservationIgnored var loopTask: Task<Void, Never>?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var billingLoadedAt: Date?
    @ObservationIgnored var lastPrunedDay: String?
    @ObservationIgnored var dirty = false

    /// Days of entries kept (the view needs 30).
    public static let keepDays = 60

    public init(storage: any UsageStorage, now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.storage = storage
        self.now = now
        self.calendar = calendar
        do {
            if let contents = try storage.load() {
                ledger = contents.ledger
                caps = contents.caps.filter { $0.value > 0 }
            }
        } catch {
            lastError = "Could not read the usage history: \(error.localizedDescription)"
        }
    }

    // MARK: Attaching

    private static var registry: [ObjectIdentifier: WeakTracker] = [:]

    private struct WeakTracker {
        weak var tracker: UsageTracker?
        /// Checked on lookup, so a new store at a freed store's address never gets its tracker.
        weak var store: SessionStore?
    }

    /// The tracker attached to a store, if any (the store's cap checks use it).
    public static func attached(to store: SessionStore) -> UsageTracker? {
        guard let entry = registry[ObjectIdentifier(store)], entry.store === store else { return nil }
        return entry.tracker
    }

    /// Follows the store's sessions. `sampling: false` reads them only when asked (tests, snapshots).
    public func attach(to store: SessionStore, sampling: Bool = true) {
        self.store = store
        Self.registry = Self.registry.filter { $0.value.tracker != nil && $0.value.store != nil }
        Self.registry[ObjectIdentifier(store)] = WeakTracker(tracker: self, store: store)
        sample()
        if sampling {
            loopTask?.cancel()
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.sample()
                    if self.billingLoadedAt.map({ self.now().timeIntervalSince($0) > self.billingInterval }) ?? true {
                        await self.refreshBilling()
                    }
                    try? await Task.sleep(for: self.sampleInterval)
                }
            }
        }
    }

    public func detach() {
        loopTask?.cancel()
        loopTask = nil
        if let store { Self.registry[ObjectIdentifier(store)] = nil }
        saveNow()
    }

    /// Re-reads who pays for each model.
    public func refreshBilling() async {
        billingLoadedAt = now()
        guard let source = store?.engine as? any EngineModelBilling, let map = try? await source.modelBilling() else { return }
        billing = map
    }

    /// Sets the billing map directly (previews, snapshots, tests).
    public func setBilling(_ map: [String: ModelBilling]) {
        billing = map
        billingLoadedAt = now()
    }

    /// Replaces the ledger (previews and snapshots). Nothing is saved.
    public func seed(_ ledger: UsageLedger, caps: [String: Double] = [:]) {
        self.ledger = ledger
        self.caps = caps
        sampledOnce = true
    }

    // MARK: Sampling

    /// Counts what every session added since the last look. Returns true when anything changed.
    @discardableResult
    public func sample() -> Bool {
        guard let store, store.isLoaded else { return false }
        let current = now()
        let today = UsageLedger.dayKey(current, calendar: calendar)
        let firstLook = !sampledOnce
        sampledOnce = true
        var changed = false
        for session in store.sessions {
            let total = session.usage
            let seenBefore = ledger.counted[session.id] != nil
            guard total != .zero || seenBefore else { continue }
            let root = rootSession(of: session, in: store)
            let model = session.info.model
            let sample = UsageSample(sessionID: session.id, rootSessionID: root.id, title: root.title, directory: root.directory,
                                     providerID: model?.providerID ?? "", modelID: model?.id ?? "",
                                     agentName: agentName(for: session, in: store), total: total, updated: session.info.updated)
            // Growth from before this launch, and sessions seen for the first time, go on their last activity day.
            let day = (firstLook || !seenBefore) ? UsageLedger.dayKey(min(session.info.updated, current), calendar: calendar) : today
            if ledger.record(sample, day: day) { changed = true }
        }
        if lastPrunedDay != today {
            lastPrunedDay = today
            if let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: current)) {
                let before = ledger
                ledger.prune(before: UsageLedger.dayKey(cutoff, calendar: calendar), keepingSessions: Set(store.sessions.map(\.id)))
                if ledger != before { changed = true }
            }
        }
        if changed { scheduleSave() }
        return changed
    }

    private func rootSession(of session: SessionModel, in store: SessionStore) -> SessionModel {
        var current = session
        var hops = 0
        while let parentID = current.info.parentID, let parent = store.session(parentID), hops < 16 {
            current = parent
            hops += 1
        }
        return current
    }

    private func agentName(for session: SessionModel, in store: SessionStore) -> String {
        let agentID = session.agentID ?? store.sessionAgentIDs[session.id].flatMap { $0.count == 1 ? $0.first : nil }
        if let agentID, let agent = store.agents[agentID] { return agent.name }
        return store.modelName(session.info.model)
    }

    // MARK: Reading

    public func report(_ range: UsageRange) -> UsageReport {
        ledger.report(range, now: now(), calendar: calendar,
                      billing: { [self] provider, model in billing(providerID: provider, modelID: model) },
                      providerName: { [self] in providerName($0) })
    }

    /// Who pays for a model. Unknown models count as API-key billed, except the subscription engines' own providers.
    public func billing(providerID: String, modelID: String) -> ModelBilling {
        let fallback: ModelBilling = Self.subscriptionProviders.contains(providerID) ? .subscription : .apiKey
        return ModelBilling.lookup(ModelRef(providerID: providerID, id: modelID), in: billing, fallback: fallback)
    }

    /// Who pays for a provider's models: its own entry, else its models' (API key if any model is), else the fallback.
    public func billing(providerID: String) -> ModelBilling {
        if let own = billing[providerID] { return own }
        let models = billing.filter { $0.key.hasPrefix(providerID + "/") }.map(\.value)
        if models.contains(.apiKey) { return .apiKey }
        if let first = models.first { return first }
        return Self.subscriptionProviders.contains(providerID) ? .subscription : .apiKey
    }

    /// Providers that are always subscriptions (the Claude and Gemini engines register them so).
    static let subscriptionProviders: Set<String> = [ClaudeModels.subscriptionProviderID, ACPAgentRegistry.antigravity.id]

    public func providerName(_ providerID: String) -> String {
        if providerID.isEmpty { return "Default model" }
        if let store {
            if let provider = store.providers.first(where: { $0.id == providerID }) { return provider.name }
            if let model = store.models.first(where: { $0.ref.providerID == providerID }) { return model.providerName }
        }
        switch providerID {
        case ClaudeModels.subscriptionProviderID: return "Claude subscription"
        case ClaudeModels.apiKeyProviderID: return "Claude API key"
        case ACPAgentRegistry.antigravity.id: return "Google AI subscription"
        default: return providerID
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.saveTask = nil
            self.saveNow()
        }
    }

    /// Saves now if anything changed (quit, tests).
    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        persist()
    }

    func persist() {
        dirty = false
        do {
            try storage.save(UsageFileContents(ledger: ledger, caps: caps))
        } catch {
            lastError = "Could not save the usage history: \(error.localizedDescription)"
        }
    }

    // MARK: Caps

    /// Sets a provider's daily cap in US dollars; nil, zero or less removes it.
    public func setCap(_ usd: Double?, for providerID: String) {
        if let usd, usd > 0 { caps[providerID] = usd } else { caps[providerID] = nil }
        persist()
    }

    /// What the provider's sessions cost today.
    public func spentToday(providerID: String) -> Double {
        ledger.spent(providerID: providerID, day: UsageLedger.dayKey(now(), calendar: calendar))
    }
}

// MARK: Storage

/// The usage file: the ledger and the caps.
public struct UsageFileContents: Codable, Equatable, Sendable {
    public var version: Int
    public var ledger: UsageLedger
    public var caps: [String: Double]

    public init(version: Int = 1, ledger: UsageLedger = UsageLedger(), caps: [String: Double] = [:]) {
        self.version = version
        self.ledger = ledger
        self.caps = caps
    }
}

public protocol UsageStorage: Sendable {
    func load() throws -> UsageFileContents?
    func save(_ contents: UsageFileContents) throws
}

/// `~/Library/Application Support/Ensemble/usage.json`, readable only by the user.
public struct UsageFileStorage: UsageStorage {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: UsageFileStorage {
        UsageFileStorage(url: EnsembleSupportFolder.url.appendingPathComponent("usage.json"))
    }

    public func load() throws -> UsageFileContents? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(UsageFileContents.self, from: data)
        } catch {
            // Kept aside so the next save does not overwrite it.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            throw ScheduleStorageError.unreadable(keptAs: aside.lastPathComponent)
        }
    }

    public func save(_ contents: UsageFileContents) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try EnsembleSupportFolder.write(try encoder.encode(contents), to: url)
    }
}

public final class InMemoryUsageStorage: UsageStorage {
    private let contents: Mutex<UsageFileContents?>

    public init(_ initial: UsageFileContents? = nil) {
        contents = Mutex(initial)
    }

    public func load() throws -> UsageFileContents? { contents.withLock { $0 } }

    public func save(_ new: UsageFileContents) throws { contents.withLock { $0 = new } }

    public var saved: UsageFileContents? { contents.withLock { $0 } }
}
