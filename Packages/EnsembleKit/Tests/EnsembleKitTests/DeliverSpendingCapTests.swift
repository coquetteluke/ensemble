import Foundation
import Testing
@testable import EnsembleKit

/// `SessionStore.deliver` checks the provider's daily spending cap first, so a message to a capped API-key session never
/// reaches the engine (sent now, sent from the queue or by auto-continue), and subscriptions are never capped.
@Suite("Spending caps when sending")
struct DeliverSpendingCapTests {
    static let openai = ModelRef(providerID: "openai", id: "gpt-5")
    static let claude = ModelRef(providerID: ClaudeModels.subscriptionProviderID, id: "sonnet")

    @MainActor
    private func makeStore() -> (SessionStore, RouterFakeEngine, UsageTracker) {
        let engine = RouterFakeEngine(name: "fake")
        let store = SessionStore(engine: engine)
        let now = Date()
        store.seed(StoreSeed(sessions: [
            EngineSession(id: "api", title: "On an API key", directory: "/tmp/app", model: Self.openai,
                          usage: Usage(inputTokens: 1000, costUSD: 0.75), updated: now),
            EngineSession(id: "plan", title: "On a plan", directory: "/tmp/app", model: Self.claude,
                          usage: Usage(inputTokens: 1000, costUSD: 4), updated: now),
        ], providers: [ProviderInfo(id: "openai", name: "OpenAI", connected: true)]))
        store.background.timerEnabled = false
        let tracker = UsageTracker(storage: InMemoryUsageStorage(), now: { now })
        tracker.setBilling(["openai": .apiKey, ClaudeModels.subscriptionProviderID: .subscription])
        tracker.attach(to: store, sampling: false)
        tracker.setCap(0.5, for: "openai")
        tracker.setCap(1, for: ClaudeModels.subscriptionProviderID)
        return (store, engine, tracker)
    }

    @Test @MainActor func aCappedAPIKeySessionRefusesAndASubscriptionSessionSends() async {
        let (store, engine, tracker) = makeStore()
        await store.send("Hello", to: "api")
        #expect(!engine.calls.contains("prompt:api"))
        let items = store.session("api")?.items ?? []
        if case .error(_, let message)? = items.last {
            #expect(message.hasPrefix("Not sent. OpenAI reached its daily spending cap"))
        } else {
            Issue.record("no refusal row")
        }
        #expect(store.session("api")?.isWorking == false)

        await store.send("Hello", to: "plan")
        #expect(engine.calls.contains("prompt:plan"))

        // Raising the cap lets the next message through.
        tracker.setCap(2, for: "openai")
        await store.send("Again", to: "api")
        #expect(engine.calls.contains("prompt:api"))
        withExtendedLifetime(tracker) {}
    }
}
