import Foundation
import Testing
@testable import EnsembleKit

@Suite("Usage ledger")
struct UsageLedgerTests {
    let utc = ScheduleTestTime.calendar("UTC")
    let now = ScheduleTestTime.utc(2026, 11, 18, 15)

    func sample(_ id: String, root: String? = nil, provider: String = "openai", model: String = "gpt-5.5", agent: String = "GPT-5.5",
                input: Int, output: Int = 0, cost: Double = 0) -> UsageSample {
        UsageSample(sessionID: id, rootSessionID: root ?? id, title: "Session \(root ?? id)", directory: "/tmp/app",
                    providerID: provider, modelID: model, agentName: agent,
                    total: Usage(inputTokens: input, outputTokens: output, costUSD: cost), updated: now)
    }

    @Test func countsGrowthOnceAndRestartsFromALowerTotal() {
        var ledger = UsageLedger()
        let first = ledger.record(sample("a", input: 100, cost: 0.5), day: "2026-11-17")
        let same = ledger.record(sample("a", input: 100, cost: 0.5), day: "2026-11-18")
        let grown = ledger.record(sample("a", input: 250, output: 40, cost: 1.25), day: "2026-11-18")
        #expect(first)
        #expect(!same, "the same total adds nothing")
        #expect(grown)
        #expect(ledger.entries.count == 2)
        #expect(ledger.entries.first { $0.day == "2026-11-18" }?.usage == Usage(inputTokens: 150, outputTokens: 40, costUSD: 0.75))

        // A total that went down (a restarted engine process) is the new starting point.
        let lower = ledger.record(sample("a", input: 20, cost: 0.1), day: "2026-11-18")
        #expect(lower)
        #expect(ledger.entries.first { $0.day == "2026-11-18" }?.usage.inputTokens == 150)
        ledger.record(sample("a", input: 50, cost: 0.2), day: "2026-11-18")
        #expect(ledger.entries.first { $0.day == "2026-11-18" }?.usage.inputTokens == 180)
        #expect(abs(ledger.spent(providerID: "openai", day: "2026-11-18") - 0.85) < 0.0001)
    }

    @Test func dayKeysCoverTheRangeInTheLocalCalendar() {
        #expect(UsageLedger.dayKeys(.today, now: now, calendar: utc) == ["2026-11-18"])
        let week = UsageLedger.dayKeys(.week, now: now, calendar: utc)
        #expect(week.count == 7)
        #expect(week.last == "2026-11-12")
        #expect(UsageLedger.dayKeys(.month, now: now, calendar: utc).last == "2026-10-20")
        // 23:30 UTC on the 18th is already the 19th in Tokyo.
        #expect(UsageLedger.dayKey(ScheduleTestTime.utc(2026, 11, 18, 23, 30), calendar: ScheduleTestTime.calendar("Asia/Tokyo"))
            == "2026-11-19")
    }

    @Test func reportsGroupByProviderAgentAndSessionWithAPICostOnly() {
        var ledger = UsageLedger()
        ledger.record(sample("api", input: 1000, output: 200, cost: 2.0), day: "2026-11-18")
        ledger.record(sample("api-child", root: "api", provider: "anthropic", model: "claude-sonnet-5", agent: "Reviewer",
                             input: 500, output: 100, cost: 1.0), day: "2026-11-18")
        ledger.record(sample("plan", provider: "claude-code", model: "claude-opus-5-5", agent: "Claude Opus 5.5",
                             input: 9000, output: 900, cost: 4.0), day: "2026-11-15")
        ledger.record(sample("old", input: 10, cost: 0.01), day: "2026-10-25")
        ledger.record(sample("ancient", input: 10, cost: 9.0), day: "2026-09-01")

        let billing: (String, String) -> ModelBilling = { provider, _ in provider == "claude-code" ? .subscription : .apiKey }
        let names: (String) -> String = { ["openai": "OpenAI", "anthropic": "Anthropic", "claude-code": "Claude subscription"][$0] ?? $0 }

        let today = ledger.report(.today, now: now, calendar: utc, billing: billing, providerName: names)
        #expect(today.total.tokens == 1800)
        #expect(today.total.apiCostUSD == 3.0)
        #expect(today.providers.map(\.name) == ["OpenAI", "Anthropic"])
        #expect(today.sessions.count == 1, "the subagent counts toward its session")
        #expect(today.sessions.first?.tokens == 1800)
        #expect(today.sessions.first?.name == "Session api")
        #expect(today.agents.map(\.name) == ["GPT-5.5", "Reviewer"])
        #expect(today.agents.last?.detail == "Anthropic")

        let week = ledger.report(.week, now: now, calendar: utc, billing: billing, providerName: names)
        #expect(week.total.apiCostUSD == 3.0, "subscription use shows tokens, not cost")
        #expect(week.total.usage.costUSD == 7.0)
        let plan = week.providers.first { $0.id == "claude-code" }
        #expect(plan?.hasAPICost == false)
        #expect(plan?.billingLabel == "Plan")
        #expect(plan?.tokens == 9900)
        #expect(week.sessionCount == 2)

        let month = ledger.report(.month, now: now, calendar: utc, billing: billing, providerName: names)
        #expect(abs(month.total.apiCostUSD - 3.01) < 0.0001)
        #expect(month.sessionCount == 3)
    }

    @Test func pruningKeepsRecentEntriesAndLiveSessions() {
        var ledger = UsageLedger()
        ledger.record(sample("gone", input: 10), day: "2026-08-01")
        ledger.record(sample("live", input: 10), day: "2026-08-01")
        ledger.record(sample("recent", input: 10), day: "2026-11-01")
        ledger.prune(before: "2026-09-19", keepingSessions: ["live"])
        #expect(ledger.entries.map(\.sessionID) == ["recent"])
        #expect(Set(ledger.counted.keys) == ["live", "recent"])
    }
}

@MainActor
@Suite("Usage tracker and spending caps")
struct UsageTrackerTests {
    let utc = ScheduleTestTime.calendar("UTC")
    let now = ScheduleTestTime.utc(2026, 11, 18, 15)
    static let openai = ModelRef(providerID: "openai", id: "gpt-5.5")
    static let claude = ModelRef(providerID: ClaudeModels.subscriptionProviderID, id: "claude-opus-5-5")

    func makeStore() -> SessionStore {
        let store = SessionStore(engine: RouterFakeEngine(name: "fake"))
        let room = UUID()
        store.seed(StoreSeed(
            sessions: [
                EngineSession(id: "api", title: "Fix the parser", directory: "/tmp/app", model: Self.openai,
                              usage: Usage(inputTokens: 4000, outputTokens: 1000, costUSD: 0.75), updated: now),
                EngineSession(id: "api-old", title: "Old work", directory: "/tmp/app", model: Self.openai,
                              usage: Usage(inputTokens: 2000, costUSD: 3.0), updated: now.addingTimeInterval(-3 * 86_400)),
                EngineSession(id: "plan", title: "Design review", directory: "/tmp/app", model: Self.claude,
                              usage: Usage(inputTokens: 50_000, outputTokens: 5000, costUSD: 12.0), updated: now),
                EngineSession(id: "idle", title: "Nothing yet", directory: "/tmp/app", model: Self.openai, updated: now),
            ],
            providers: [ProviderInfo(id: "openai", name: "OpenAI", connected: true)],
            agents: [AgentSpec(id: room, name: "Opus", model: Self.claude, colorHex: "#D97757")],
            sessionAgentIDs: ["plan": [room]]
        ))
        store.background.timerEnabled = false
        return store
    }

    func makeTracker(_ store: SessionStore, storage: InMemoryUsageStorage = InMemoryUsageStorage()) -> UsageTracker {
        let fixed = now
        let tracker = UsageTracker(storage: storage, now: { fixed }, calendar: utc)
        tracker.setBilling(["openai": .apiKey, ClaudeModels.subscriptionProviderID: .subscription])
        tracker.attach(to: store, sampling: false)
        return tracker
    }

    @Test func firstLookCountsEachSessionOnItsLastActiveDayThenGrowthToday() {
        let store = makeStore()
        let tracker = makeTracker(store)
        #expect(store.usageTracker === tracker)
        let today = tracker.report(.today)
        #expect(today.sessions.map(\.name).sorted() == ["Design review", "Fix the parser"])
        #expect(today.total.apiCostUSD == 0.75)
        #expect(today.agents.contains { $0.name == "Opus" }, "room agents are named")
        #expect(tracker.report(.week).total.apiCostUSD == 3.75)

        // The old session grows now: the growth counts today.
        store.apply(.usageUpdated(sessionID: "api-old", Usage(inputTokens: 2500, costUSD: 3.5)))
        #expect(tracker.sample())
        #expect(abs(tracker.report(.today).total.apiCostUSD - 1.25) < 0.0001)
        #expect(!tracker.sample(), "nothing new")
    }

    @Test func capsRefuseNewTurnsOnlyForAPIKeyProviders() {
        let store = makeStore()
        let tracker = makeTracker(store)
        #expect(store.spendingCapRefusal(model: Self.openai) == nil)

        tracker.setCap(0.5, for: "openai")
        tracker.setCap(1.0, for: ClaudeModels.subscriptionProviderID)
        let refusal = store.spendingCapRefusal(model: Self.openai)
        #expect(refusal?.providerName == "OpenAI")
        #expect(refusal?.capUSD == 0.5)
        #expect(refusal?.spentUSD == 0.75)
        #expect(refusal?.message.contains("OpenAI reached its daily spending cap: $0.75 of $0.50 spent today.") == true)
        #expect(refusal?.message.contains("\u{2014}") == false)
        #expect(store.spendingCapRefusal(model: Self.claude) == nil, "subscriptions are never capped")
        #expect(store.spendingCapRefusal(for: "plan") == nil)

        // The status rows list API-key providers only.
        #expect(tracker.cappableProviders.map(\.providerID) == ["openai"])
        #expect(tracker.capStatus(providerID: "openai").isReached)

        // A raised cap lets turns through again.
        tracker.setCap(2, for: "openai")
        #expect(store.spendingCapRefusal(for: "api") == nil)
        tracker.setCap(nil, for: "openai")
        #expect(tracker.caps["openai"] == nil)
    }

    @Test func aRefusedMessageStaysVisibleAndIsNotSent() {
        let store = makeStore()
        let tracker = makeTracker(store)
        tracker.setCap(0.5, for: "openai")
        #expect(store.refuseOverSpendingCap("Try again", to: "idle"))
        let items = store.session("idle")?.items ?? []
        #expect(items.count == 2)
        if case .user(_, let text, _) = items.first { #expect(text == "Try again") } else { Issue.record("text not shown") }
        if case .error(_, let message) = items.last { #expect(message.hasPrefix("Not sent. OpenAI reached")) } else { Issue.record("no error") }
        #expect(!store.refuseOverSpendingCap("Hello", to: "plan"))

        // A scheduled run on that provider is skipped with the same reason.
        let task = ScheduledTask(name: "Nightly", prompt: "p", directory: "/tmp/app", model: Self.openai)
        #expect(store.scheduleRefusal(for: task)?.hasPrefix("OpenAI reached its daily spending cap") == true)
    }

    @Test func ledgerAndCapsAreSaved() throws {
        let storage = InMemoryUsageStorage()
        let store = makeStore()
        let tracker = makeTracker(store, storage: storage)
        tracker.setCap(5, for: "openai")
        tracker.saveNow()
        let saved = try #require(storage.saved)
        #expect(saved.caps == ["openai": 5])
        #expect(saved.ledger.entries.count == 3)

        let reopened = UsageTracker(storage: storage, now: { Date() }, calendar: utc)
        #expect(reopened.caps == ["openai": 5])
        #expect(reopened.ledger == tracker.ledger)
        tracker.detach()
        #expect(store.usageTracker == nil)
    }

    @Test func unknownProvidersCountAsAPIKeysExceptTheSubscriptionEngines() {
        let tracker = UsageTracker(storage: InMemoryUsageStorage(), now: { Date() }, calendar: utc)
        #expect(tracker.billing(providerID: "somewhere", modelID: "m") == .apiKey)
        #expect(tracker.billing(providerID: ClaudeModels.subscriptionProviderID, modelID: "m") == .subscription)
        #expect(tracker.billing(providerID: "antigravity", modelID: "gemini") == .subscription)
        tracker.setBilling(["github-copilot/gpt-5.5": .subscription])
        #expect(tracker.billing(providerID: "github-copilot") == .subscription)
        #expect(tracker.billing(providerID: "github-copilot", modelID: "gpt-5.5") == .subscription)
    }
}
