import Foundation

// Daily spending caps per provider, for API keys only. When a provider's sessions have cost its cap today, new turns on
// that provider are refused with a message saying so, until local midnight or until the cap is raised. A turn already
// running finishes. Caps never apply to subscriptions (Claude, Google AI, ChatGPT and other plans), free models or
// models on this Mac.

/// Why a new turn was not started.
public struct SpendingCapRefusal: Equatable, Sendable {
    public var providerID: String
    public var providerName: String
    public var capUSD: Double
    public var spentUSD: Double

    public init(providerID: String, providerName: String, capUSD: Double, spentUSD: Double) {
        self.providerID = providerID
        self.providerName = providerName
        self.capUSD = capUSD
        self.spentUSD = spentUSD
    }

    public var message: String {
        "\(providerName) reached its daily spending cap: \(Format.usd(spentUSD)) of \(Format.usd(capUSD)) spent today. "
            + "New turns on \(providerName) wait until midnight, or raise the cap in Usage."
    }
}

/// A provider's cap and what it spent today, for the Usage view.
public struct UsageCapStatus: Equatable, Sendable, Identifiable {
    public var providerID: String
    public var providerName: String
    public var capUSD: Double?
    public var spentUSD: Double

    public var id: String { providerID }

    /// Spent over cap, 0...1 (0 without a cap).
    public var fraction: Double {
        guard let capUSD, capUSD > 0 else { return 0 }
        return min(max(spentUSD / capUSD, 0), 1)
    }

    public var isReached: Bool { capUSD.map { spentUSD >= $0 } ?? false }
}

extension UsageTracker {
    /// The refusal for a new turn on `model`, or nil when it may run. Only API-key providers are ever refused.
    public func refusal(for model: ModelRef?) -> SpendingCapRefusal? {
        guard let model, let cap = caps[model.providerID] else { return nil }
        guard billing(providerID: model.providerID, modelID: model.id) == .apiKey else { return nil }
        sample()
        let spent = spentToday(providerID: model.providerID)
        guard spent >= cap else { return nil }
        return SpendingCapRefusal(providerID: model.providerID, providerName: providerName(model.providerID), capUSD: cap,
                                  spentUSD: spent)
    }

    /// Providers that can have a cap: billed to an API key and either usable now (a connected provider, an available
    /// model), used in the last 30 days, or already capped. Sorted by name.
    public var cappableProviders: [UsageCapStatus] {
        var ids = Set(caps.keys)
        if let store {
            for provider in store.providers where provider.connected { ids.insert(provider.id) }
            for model in store.models where model.available { ids.insert(model.ref.providerID) }
        }
        let monthDays = Set(UsageLedger.dayKeys(.month, now: now(), calendar: calendar))
        for entry in ledger.entries where monthDays.contains(entry.day) && entry.usage.costUSD > 0 { ids.insert(entry.providerID) }
        return ids.filter { !$0.isEmpty && billing(providerID: $0) == .apiKey }
            .map { capStatus(providerID: $0) }
            .sorted { $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending }
    }

    public func capStatus(providerID: String) -> UsageCapStatus {
        UsageCapStatus(providerID: providerID, providerName: providerName(providerID), capUSD: caps[providerID],
                       spentUSD: spentToday(providerID: providerID))
    }
}

extension SessionStore {
    /// The usage tracker following this store, if the app attached one.
    public var usageTracker: UsageTracker? { UsageTracker.attached(to: self) }

    /// The cap refusal for a new turn on `model`, or nil when it may run.
    public func spendingCapRefusal(model: ModelRef?) -> SpendingCapRefusal? {
        usageTracker?.refusal(for: model ?? defaultModel)
    }

    /// The cap refusal for a new turn in a session, or nil when it may run.
    public func spendingCapRefusal(for sessionID: String) -> SpendingCapRefusal? {
        spendingCapRefusal(model: byID[sessionID]?.info.model)
    }

    /// Call before sending: when the session's provider is over its daily cap, shows the message (and the text that was
    /// not sent) in the transcript and returns true; the caller then sends nothing.
    @discardableResult
    public func refuseOverSpendingCap(_ text: String, files: [URL] = [], to sessionID: String) -> Bool {
        guard let refusal = spendingCapRefusal(for: sessionID), let session = byID[sessionID] else { return false }
        var shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !files.isEmpty {
            let names = files.map(\.lastPathComponent).joined(separator: ", ")
            shown += shown.isEmpty ? "Attached: \(names)" : "\n\nAttached: \(names)"
        }
        if !shown.isEmpty { session.items.append(.user(id: "user-\(UUID().uuidString)", text: shown, date: Date())) }
        session.items.append(.error(id: "cap-\(UUID().uuidString)", message: "Not sent. " + refusal.message))
        session.touch()
        return true
    }
}
