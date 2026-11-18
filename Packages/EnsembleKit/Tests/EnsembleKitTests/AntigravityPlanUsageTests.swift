import Foundation
import Testing
@testable import EnsembleKit

/// agy's plan use: `agy -p "/usage"` answers captured on 2026-11-18 (agy 1.5.10, Fixtures/acp/agy-usage.json and
/// agy-usage-stream.jsonl), the ACP session where a "/usage" prompt went to the model (agy-usage-prompt.jsonl), and
/// limit messages taken from agy's own wording (no real limit was spent to capture one).
@Suite("Google AI plan use from agy")
struct AntigravityPlanUsageTests {
    static let now = Date(timeIntervalSince1970: 1_795_500_000)

    @Test func decodesTheJSONAnswer() throws {
        guard case .usage(let usage) = AntigravityPlanUsage.decode(try Fixtures.text("acp/agy-usage.json"), now: Self.now) else {
            Issue.record("no usage")
            return
        }
        #expect(usage.groups.map(\.name) == ["Gemini Models", "Claude and GPT models"])
        #expect(usage.updated == Self.now)
        let gemini = try #require(usage.groups.first)
        #expect(gemini.label == "Gemini models")
        #expect(gemini.models == ["Gemini 4 Carbon", "Gemini 4 Argon", "Gemini 4 Hydrogen", "Orchestrator (Carbon)", "Orchestrator (Argon)",
                                  "Gemini 3.8 Flash"])
        // agy sends weekly first; the five-hour limit comes first, as in Claude's plan.
        #expect(gemini.buckets.map(\.id) == ["gemini-5h", "gemini-weekly"])
        #expect(gemini.buckets.map(\.windowName) == ["five_hour", "seven_day"])
        let fiveHour = try #require(gemini.buckets.first)
        #expect(abs((fiveHour.remainingFraction ?? 0) - 0.9814000129699707) < 1e-9)
        #expect(abs((fiveHour.usedFraction ?? 0) - 0.0186) < 1e-4)
        #expect(fiveHour.resetsAt == ISO8601DateFormatter().date(from: "2026-11-18T18:20:35Z"))
        #expect(fiveHour.showsReset)
        #expect(!fiveHour.isUsedUp)
        let other = usage.groups[1]
        #expect(other.models == ["Claude Sonnet 4.6", "Claude Opus 4.6", "GPT-OSS 120B"])
        // Untouched limits: agy's reset time is just now plus the window, so it is not shown.
        #expect(other.buckets.allSatisfy { $0.remainingFraction == 1 && !$0.showsReset })
        #expect(!usage.isLimited)
    }

    @Test func decodesStreamJSONAndThePlainTable() throws {
        guard case .usage(let stream) = AntigravityPlanUsage.decode(try Fixtures.text("acp/agy-usage-stream.jsonl"), now: Self.now) else {
            Issue.record("no usage from stream-json")
            return
        }
        #expect(stream.groups.map(\.name) == ["Gemini Models", "Claude and GPT models"])
        #expect(stream.groups[0].buckets.count == 2)

        // Without --output-format agy prints one tab-separated line per bucket.
        let table = "Gemini Models\tWeekly Limit Remaining\t99%\t2026-11-25T02:36:19Z\nGemini Models\tFive Hour Limit Remaining\t0%\t2026-11-18T18:20:35Z\n"
        guard case .usage(let plain) = AntigravityPlanUsage.decode(table, now: Self.now) else {
            Issue.record("no usage from the table")
            return
        }
        #expect(plain.groups.count == 1)
        #expect(plain.groups[0].buckets.map(\.windowName) == ["five_hour", "seven_day"])
        #expect(plain.groups[0].buckets[0].isUsedUp)
        #expect(plain.isLimited)
        #expect(plain.groups[0].limitedUntil == ISO8601DateFormatter().date(from: "2026-11-18T18:20:35Z"))
    }

    @Test func aModelTurnIsNotAUsageAnswer() {
        // What an agy without a /usage command would print: a normal turn's result.
        let turn = #"{"conversation_id":"c-1","status":"SUCCESS","response":"Here is your usage","num_turns":1,"usage":{"input_tokens":21366}}"#
        #expect(AntigravityPlanUsage.decode(turn) == .notACommand)
        #expect(AntigravityPlanUsage.decode("") == .unreadable)
        #expect(AntigravityPlanUsage.decode("Error: not signed in") == .unreadable)
    }

    @Test func acpHasNoUsageCommandAndSendsTheSlashToTheModel() throws {
        let updates = try ACPFixtures.incoming("agy-usage-prompt.jsonl").compactMap { message -> ACPSessionUpdate? in
            guard case .notification("session/update", let params) = message else { return nil }
            return params["update"].flatMap(ACPSessionUpdate.init)
        }
        let commands = updates.flatMap { update -> [String] in
            if case .availableCommands(let list) = update { list.map(\.name) } else { [] }
        }
        #expect(!commands.isEmpty)
        #expect(!commands.contains { ["usage", "quota", "credits", "stats"].contains($0) })
        // The prompt "/usage" ran as a model turn: it used about 21k tokens.
        let result = try #require(try ACPFixtures.result("agy-usage-prompt.jsonl", method: "session/prompt"))
        #expect((ACPTurnUsage(result["usage"])?.inputTokens ?? 0) > 1000)
    }

    @Test func picksTheGroupForTheSessionsModel() throws {
        guard case .usage(let usage) = AntigravityPlanUsage.decode(try Fixtures.text("acp/agy-usage.json"), now: Self.now) else {
            Issue.record("no usage")
            return
        }
        #expect(usage.group(forModel: "gemini-4-carbon")?.name == "Gemini Models")
        #expect(usage.group(forModel: "gemini-3.8-flash-low")?.name == "Gemini Models")
        #expect(usage.group(forModel: "gemini-pro-orchestrator")?.name == "Gemini Models")
        #expect(usage.group(forModel: "claude-opus-4-6-thinking")?.name == "Claude and GPT models")
        #expect(usage.group(forModel: "claude-sonnet-4-6")?.name == "Claude and GPT models")
        #expect(usage.group(forModel: "gpt-oss-120b-medium")?.name == "Claude and GPT models")
        // A model agy adds later goes by its family name.
        #expect(usage.group(forModel: "claude-opus-5")?.name == "Claude and GPT models")
        #expect(usage.group(forModel: nil)?.name == "Gemini Models")
        #expect(usage.group(forModel: "something-new")?.name == "Gemini Models")
    }

    @Test func meterMatchesClaudesShape() {
        let reset = Self.now.addingTimeInterval(3600)
        let group = AntigravityPlanUsage.Group(name: "Gemini Models", buckets: [
            .init(id: "gemini-weekly", name: "Weekly Limit Remaining", window: "weekly", remainingFraction: 0.4),
            .init(id: "gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remainingFraction: 0, resetsAt: reset),
            .init(id: "gemini-x", name: "Disabled", window: "daily", remainingFraction: nil, disabled: true),
        ])
        let meter = PlanLimitMeter(antigravity: group)
        #expect(meter.windows.map(\.name) == ["five_hour", "seven_day"])
        #expect(meter.fiveHour?.status == "rejected")
        #expect(meter.fiveHour?.resetsAt == reset)
        #expect(abs((meter.weekly?.utilization ?? 0) - 0.6) < 1e-9)
        #expect(meter.isLimited)
        #expect(meter.level == .limited)
        #expect(meter.leading?.name == "five_hour")

        // No reading but a turn stopped on a limit: an empty meter that is red.
        let status = AntigravityPlanStatus(limitHit: AntigravityLimitHit(message: "individual quota reached", date: Self.now))
        #expect(status.meter(forModel: "gemini-4-carbon").windows.isEmpty)
        #expect(status.meter(forModel: "gemini-4-carbon").isLimited)
    }

    // Wording from agy 1.5.10 itself (its quota check, error strings and release notes); not captured from a real limit.
    @Test(arguments: [
        "RESOURCE_EXHAUSTED: You have exhausted your capacity on this model. Your quota will reset after 2h34m50s.",
        "individual quota reached",
        "Your AI credits balance is too low to continue.",
        "model gemini-4-carbon is out of quota until 2026-11-18T18:20:35Z",
        "Error 429: Quota exceeded for this model",
    ])
    func recognisesLimitMessages(_ text: String) {
        #expect(AntigravityLimitText.isLimit(text))
    }

    @Test(arguments: [
        "MODEL_CAPACITY_EXHAUSTED: Overloaded prefill queue",
        "The agent stopped: it reached its output limit.",
        "The agent stopped: it reached its limit of steps for one message.",
        "The prompt is too long for the context window.",
        "disc quota exceeded",
        "fake failure",
    ])
    func ignoresOtherFailures(_ text: String) {
        #expect(!AntigravityLimitText.isLimit(text))
    }

    @Test func readsResetTimes() {
        let now = Self.now
        let after = AntigravityLimitText.hit(in: "RESOURCE_EXHAUSTED: Your quota will reset after 2h34m50s.", now: now)
        #expect(after?.resetsAt == now.addingTimeInterval(2 * 3600 + 34 * 60 + 50))
        let words = AntigravityLimitText.resetDate(in: "Quota exhausted. It resets in 4 hours, 3 minutes.", now: now)
        #expect(words == now.addingTimeInterval(4 * 3600 + 3 * 60))
        let until = AntigravityLimitText.resetDate(in: "model gemini-4-carbon is out of quota until 2026-11-18T18:20:35Z", now: now)
        #expect(until == ISO8601DateFormatter().date(from: "2026-11-18T18:20:35Z"))
        #expect(AntigravityLimitText.hit(in: "Your AI credits balance is too low to continue.", now: now)?.resetsAt == nil)
        #expect(AntigravityLimitText.hit(in: "fake failure", now: now) == nil)
    }

    @Test func aLaterReadingOrThePassedResetClearsALimitHit() {
        let hit = AntigravityLimitHit(message: "individual quota reached", resetsAt: Self.now.addingTimeInterval(600), date: Self.now)
        let free = AntigravityPlanUsage(groups: [.init(name: "Gemini Models", buckets: [
            .init(id: "gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remainingFraction: 0.5),
        ])], updated: Self.now.addingTimeInterval(60))
        #expect(AntigravityPlanStatus(usage: free, limitHit: hit).settled(now: Self.now).limitHit == nil)
        var older = free
        older.updated = Self.now.addingTimeInterval(-60)
        #expect(AntigravityPlanStatus(usage: older, limitHit: hit).settled(now: Self.now).limitHit == hit)
        #expect(AntigravityPlanStatus(limitHit: hit).settled(now: Self.now.addingTimeInterval(601)).limitHit == nil)
        #expect(AntigravityPlanStatus(limitHit: hit).isLimited)
    }
}

@Suite("Subscription plans by session")
struct SubscriptionPlanTests {
    @Test func planFollowsTheSessionsEngine() {
        #expect(SubscriptionPlan.forSession(engineID: "antigravity", providerID: "antigravity") == .googleAI)
        #expect(SubscriptionPlan.forSession(engineID: "claude", providerID: "claude-code") == .claude)
        #expect(SubscriptionPlan.forSession(engineID: "claude", providerID: "claude-code-api") == nil)
        #expect(SubscriptionPlan.forSession(engineID: "opencode", providerID: "openai") == nil)
        // Before the router knows the owner, the model's provider decides.
        #expect(SubscriptionPlan.forSession(engineID: nil, providerID: "antigravity") == .googleAI)
        #expect(SubscriptionPlan.forSession(engineID: nil, providerID: "claude-code") == .claude)
        #expect(SubscriptionPlan.forSession(engineID: nil, providerID: nil) == nil)
    }

    @Test func currentSessionsPlanComesFirst() {
        let both: [SubscriptionPlan] = [.claude, .googleAI]
        #expect(SubscriptionPlan.ordered(both, current: .googleAI) == [.googleAI, .claude])
        #expect(SubscriptionPlan.ordered(both, current: .claude) == [.claude, .googleAI])
        #expect(SubscriptionPlan.ordered(both, current: nil) == [.claude, .googleAI])
        #expect(SubscriptionPlan.ordered([.googleAI, .claude], current: nil) == [.claude, .googleAI])
        #expect(SubscriptionPlan.ordered([.claude], current: .googleAI) == [.claude])
        #expect(SubscriptionPlan.ordered([], current: .claude).isEmpty)
        #expect(SubscriptionPlan.googleAI.title == "Google AI plan")
        #expect(SubscriptionPlan.claude.title == "Claude plan")
    }

    @Test func statusLineShowsTheSessionsOwnPlan() {
        #expect(SubscriptionPlan.statusLine(for: .googleAI) == .googleAI)
        #expect(SubscriptionPlan.statusLine(for: .claude) == .claude)
        // Sessions on API keys keep the Claude ring, as before.
        #expect(SubscriptionPlan.statusLine(for: nil) == .claude)
        let gemini = SubscriptionPlan.forSession(engineID: "antigravity", providerID: "antigravity")
        #expect(SubscriptionPlan.statusLine(for: gemini) != .claude)
    }
}

#if os(macOS)
/// The real `agy`, signed in as the Mac's user: `/usage` through the engine. No turn runs and no quota is spent (agy
/// answers the command itself). Runs only with `ENSEMBLE_LIVE_ACP=1`.
@Suite("Google AI plan live", .serialized, .enabled(if: ACPLive.enabled))
struct AntigravityPlanUsageLiveTests {
    @Test func realAgyReportsBothGroups() async throws {
        let h = try ACPLiveHarness()
        let engine = h.engine(ACPAgentRegistry.antigravity)
        let status = try #require(await engine.planStatus(refresh: true))
        let usage = try #require(status.usage, "agy answered: \(String(describing: status.problem))")
        #expect(usage.groups.contains { $0.name.lowercased().hasPrefix("gemini") })
        for group in usage.groups {
            #expect(group.buckets.map(\.windowName).contains("five_hour"))
            #expect(group.buckets.allSatisfy { ($0.remainingFraction ?? 0) >= 0 && ($0.remainingFraction ?? 0) <= 1 })
        }
        #expect(usage.group(forModel: "gemini-4-carbon")?.name.lowercased().hasPrefix("gemini") == true)
        await h.finish()
    }
}
#endif

@Suite("Google AI plan from the engine", .serialized, .enabled(if: FakeACPHarness.pythonAvailable))
struct ACPPlanUsageEngineTests {
    /// The definition's usage command prints `file` (and counts its runs in `count`) instead of asking agy.
    static func usageCommand(file: URL, count: URL) -> [String] {
        ["-c", "import sys; open(sys.argv[2], 'a').write('x'); sys.stdout.write(open(sys.argv[1]).read())", file.path, count.path]
    }

    static func runs(_ count: URL) -> Int { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").count }

    @Test func readsUsageAndTheLimitATurnStoppedOn() async throws {
        let h = try FakeACPHarness()
        let file = h.folder.appendingPathComponent("usage.json")
        let count = h.folder.appendingPathComponent("runs.txt")
        try Fixtures.data("acp/agy-usage.json").write(to: file)
        let message = "RESOURCE_EXHAUSTED: You have exhausted your capacity on this model. Your quota will reset after 2h0m0s."
        let engine = h.engine(env: ["FAKE_ACP_FAIL_MESSAGE": message]) { agent in
            agent.planUsageArguments = Self.usageCommand(file: file, count: count)
            agent.environmentPassThrough.append("FAKE_ACP_FAIL_MESSAGE")
        }
        #expect(engine.reportsPlanUsage)
        let status = try #require(await engine.planStatus())
        #expect(status.usage?.groups.count == 2)
        #expect(status.limitHit == nil)
        // A second look within a minute is answered from memory.
        _ = await engine.planStatus()
        #expect(Self.runs(count) == 1)

        let session = try await h.session(engine)
        let mark = await h.recorder.mark()
        let before = Date()
        try await engine.prompt(session.id, text: "fail", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "failed")
        let stop = try #require(await engine.usageLimitStop(session.id))
        #expect(stop.message?.contains("RESOURCE_EXHAUSTED") == true)
        let reset = try #require(stop.resetsAt)
        #expect(reset >= before.addingTimeInterval(7200) && reset <= Date().addingTimeInterval(7200))
        // The limit hit makes the next reading fresh; agy's answer shows nothing used up, so the plan is not limited.
        #expect(Self.runs(count) == 2)
        #expect(await engine.planStatus()?.isLimited == false)
        await h.finish()
    }

    @Test func aUsedUpLimitGivesTheResetAndASuccessClearsIt() async throws {
        let h = try FakeACPHarness()
        let file = h.folder.appendingPathComponent("usage.json")
        let count = h.folder.appendingPathComponent("runs.txt")
        let limited = try Fixtures.text("acp/agy-usage.json")
            .replacingOccurrences(of: "\"remaining_fraction\":0.9814000129699707", with: "\"remaining_fraction\":0")
        try limited.write(to: file, atomically: true, encoding: .utf8)
        let engine = h.engine(env: ["FAKE_ACP_FAIL_MESSAGE": "Your AI credits balance is too low to continue."]) { agent in
            agent.planUsageArguments = Self.usageCommand(file: file, count: count)
            agent.environmentPassThrough.append("FAKE_ACP_FAIL_MESSAGE")
        }
        let session = try await h.session(engine)
        var mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "fail", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "failed")
        let stop = try #require(await engine.usageLimitStop(session.id))
        #expect(stop.window == "five_hour")
        #expect(stop.resetsAt == ISO8601DateFormatter().date(from: "2026-11-18T18:20:35Z"))
        let status = try #require(await engine.planStatus())
        #expect(status.isLimited)
        #expect(status.limitHit != nil)

        mark = await h.recorder.mark()
        try await engine.prompt(session.id, text: "hello", files: [])
        #expect(try await h.recorder.ended(session.id, after: mark).outcome == "succeeded")
        #expect(await engine.usageLimitStop(session.id) == nil)
        #expect(await engine.planStatus()?.limitHit == nil)
        await h.finish()
    }

    @Test func anAgyWithoutUsageIsAskedOnceAndASignedOutOneNever() async throws {
        let h = try FakeACPHarness()
        let file = h.folder.appendingPathComponent("turn.json")
        let count = h.folder.appendingPathComponent("runs.txt")
        try #"{"conversation_id":"c-1","status":"SUCCESS","response":"I cannot run /usage","num_turns":1}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let engine = h.engine { $0.planUsageArguments = Self.usageCommand(file: file, count: count) }
        #expect(await engine.planStatus(refresh: true)?.problem == .notReported)
        #expect(await engine.planStatus(refresh: true)?.problem == .notReported)
        #expect(Self.runs(count) == 1)

        let signedOutCount = h.folder.appendingPathComponent("signed-out-runs.txt")
        let signedOut = h.engine(env: ["FAKE_ACP_SIGNED_OUT": "1"]) {
            $0.planUsageArguments = Self.usageCommand(file: file, count: signedOutCount)
        }
        #expect(await signedOut.planStatus(refresh: true)?.problem == .noAnswer)
        #expect(Self.runs(signedOutCount) == 0)

        // A tool without a usage command reports nothing.
        #expect(await h.engine().planStatus() == nil)
        await h.finish()
    }
}
