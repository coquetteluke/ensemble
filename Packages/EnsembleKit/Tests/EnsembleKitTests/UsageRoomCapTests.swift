import Foundation
import Testing
@testable import EnsembleKit

/// Daily spending caps stop room agents on API-key providers too.
@MainActor
@Suite("Spending caps in rooms")
struct UsageRoomCapTests {
    final class CapSwitch {
        var reached = true
    }

    @Test func aCappedProviderPausesTheRoomAndResumeSendsOnceTheCapAllows() async throws {
        let fake = FakeEngine()
        fake.on("Alpha", "Write hello", reply: "Wrote hello.swift.")
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        let cap = CapSwitch()
        engine.spendingCapCheck = { model in
            guard cap.reached, model.providerID == "mock" else { return nil }
            return SpendingCapRefusal(providerID: "mock", providerName: "Mock", capUSD: 1, spentUSD: 1.25)
        }

        await engine.send("Write hello")
        #expect(fake.wakes(to: "Alpha").isEmpty, "nothing reaches a capped provider")
        #expect(engine.state.isPaused)
        #expect(engine.state.pauseReason?.contains("Mock reached its daily spending cap: $1.25 of $1.00 spent today.") == true)
        #expect(engine.activity[engine.id(of: "Alpha")] == .idle)

        // Still capped: resume pauses again and still sends nothing.
        await engine.resume()
        #expect(engine.state.isPaused)
        #expect(fake.wakes(to: "Alpha").isEmpty)

        cap.reached = false
        await engine.resume()
        try await engine.waitFor("the reply", fake: fake) { $0.state.phase == .finished }
        #expect(fake.wakes(to: "Alpha").map(\.text) == ["Write hello"])
        #expect(engine.messages(from: "Alpha").map(\.text) == ["Wrote hello.swift."])
    }

    @Test func roomsUseTheAppsTrackerAndSubscriptionsAreNeverCapped() async throws {
        let store = SessionStore(engine: RouterFakeEngine(name: "fake"))
        store.seed(StoreSeed(sessions: [
            EngineSession(id: "api", title: "Spend", directory: "/tmp", model: ModelRef(providerID: "acme-api", id: "m1"),
                          usage: Usage(inputTokens: 10, costUSD: 3), updated: Date()),
        ]))
        let tracker = UsageTracker(storage: InMemoryUsageStorage())
        tracker.setBilling(["acme-api": .apiKey, ClaudeModels.subscriptionProviderID: .subscription])
        tracker.attach(to: store, sampling: false, appWide: true)
        tracker.setCap(2, for: "acme-api")
        tracker.setCap(2, for: ClaudeModels.subscriptionProviderID)

        let fake = FakeEngine()
        let engine = try await RoomFixtures.engine(RoomFixtures.spec(.solo, ["Alpha"]), fake: fake)
        #expect(engine.spendingCapCheck(ModelRef(providerID: "acme-api", id: "m1"))?.providerName == "acme-api")
        #expect(engine.spendingCapCheck(ModelRef(providerID: ClaudeModels.subscriptionProviderID, id: "claude-opus-5-5")) == nil)
        #expect(engine.spendingCapCheck(ModelRef(providerID: "mock", id: "alpha")) == nil)
        tracker.detach()
    }
}
