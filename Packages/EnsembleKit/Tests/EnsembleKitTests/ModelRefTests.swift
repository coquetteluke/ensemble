import Testing
@testable import EnsembleKit

@Suite struct ModelRefTests {
    @Test func parsesProviderAndModel() throws {
        let ref = try #require(ModelRef(string: "anthropic/claude-opus-5-5"))
        #expect(ref.providerID == "anthropic")
        #expect(ref.id == "claude-opus-5-5")
        #expect(ref.variant == nil)
        #expect(ref.description == "anthropic/claude-opus-5-5")
    }

    @Test func keepsSlashesInsideOpenRouterModelIDs() throws {
        let ref = try #require(ModelRef(string: "openrouter/x-ai/grok-5#high"))
        #expect(ref.providerID == "openrouter")
        #expect(ref.id == "x-ai/grok-5")
        #expect(ref.variant == "high")
        #expect(ref.description == "openrouter/x-ai/grok-5#high")
    }

    @Test func rejectsMissingParts() {
        #expect(ModelRef(string: "no-slash") == nil)
        #expect(ModelRef(string: "/model") == nil)
        #expect(ModelRef(string: "provider/") == nil)
    }

    @Test func usageAdds() {
        let a = Usage(inputTokens: 10, outputTokens: 5, costUSD: 0.01)
        let b = Usage(inputTokens: 1, outputTokens: 2, costUSD: 0.02)
        let sum = a + b
        #expect(sum.inputTokens == 11)
        #expect(sum.outputTokens == 7)
        #expect(abs(sum.costUSD - 0.03) < 1e-9)
    }
}
