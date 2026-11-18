#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// The router over the real OpenCode service and the real `claude` CLI on the user's own subscription. Runs only with
/// `ENSEMBLE_LIVE_ROUTER=1` (needs `opencode service start` and a signed-in `claude`), and uses two short haiku turns.
@Suite("Router live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_ROUTER"] == "1"))
struct RouterLiveTests {
    @Test func listsBothEnginesAndRunsAClaudeSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-router-live-\(UUID().uuidString.prefix(8))")
        let project = folder.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let openCode = try OpenCodeClient.fromServiceFile(defaultDirectory: project.path)
        let claude = ClaudeCodeEngine(configuration: .init(storeURL: folder.appendingPathComponent("claude-sessions.json"),
                                                           trust: WorkspaceTrust(fileURL: folder.appendingPathComponent("trusted.json"))))
        let router = EngineRouter.standard(openCode: openCode, claude: claude)
        let recorder = ClaudeLiveRecorder()
        let listener = Task { for await event in router.events() { await recorder.append(event) } }
        defer { listener.cancel() }

        // Models from both engines, grouped by who pays.
        let models = try await router.models()
        let free = models.filter { $0.ref.providerID == "opencode" }
        let subscription = models.filter { $0.ref.providerID == ClaudeModels.subscriptionProviderID }
        #expect(!free.isEmpty)
        #expect(subscription.contains { $0.ref.id == "haiku" && $0.available })
        let groups = try await router.modelGroups()
        let byBilling = Dictionary(uniqueKeysWithValues: groups.map { ($0.billing, $0.models.map(\.id)) })
        #expect(byBilling[.subscription]?.contains("claude-code/haiku") == true)
        #expect(byBilling[.free]?.contains { $0.hasPrefix("opencode/") } == true)
        print("router live: \(models.count) models; groups:", groups.map { "\($0.title) \($0.models.count)" })

        // Providers and integrations from OpenCode, with Claude's two providers added.
        let providers = try await router.providers()
        #expect(providers.contains { $0.id == "claude-code" && $0.connected })
        #expect(providers.contains { $0.id == "anthropic" })
        let integrations = try await openCode.integrations()
        #expect(integrations.count > 300)
        #expect(integrations.contains { $0.id == "xai" && !$0.oauthMethods.isEmpty })
        #expect(integrations.contains { $0.id == "amazon-bedrock" && !$0.externalMethods.isEmpty })
        #expect(integrations.contains { $0.isCodingPlan })

        // A browser sign-in can start and be cancelled without opening anything.
        let attempt = try await openCode.startOAuth(integrationID: "gitlab", methodID: "pkce",
                                                    answer: OpenCodeIntegration.FormField.answer(
                                                        for: integrations.first { $0.id == "gitlab" }?.oauthMethods.first?.fields ?? [], values: [:]))
        #expect(attempt.url?.host != nil)
        #expect(try await openCode.oauthStatus(integrationID: "gitlab", attemptID: attempt.attemptID) == .pending)
        try await openCode.cancelOAuth(integrationID: "gitlab", attemptID: attempt.attemptID)
        print("router live: oauth attempt mode \(attempt.mode), expires \(attempt.expires.map { "\($0)" } ?? "none")")

        // A Claude session through the router: created on the Claude engine, prompted twice, listed, deleted.
        let session = try await router.createSession(directory: project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        #expect(router.registration(forProvider: "claude-code").id == "claude")
        #expect(await router.registration(forSession: session.id)?.id == "claude")

        var mark = await recorder.mark()
        try await router.prompt(session.id, text: "Reply with exactly the word pong and nothing else.", files: [])
        let first = try await recorder.wait("first turn", after: mark, timeout: 180) {
            if case .executionEnded(session.id, _, _) = $0 { true } else { false }
        }
        #expect(first == .executionEnded(sessionID: session.id, outcome: "succeeded", error: nil))
        #expect(await recorder.texts(after: mark, session: session.id).joined().lowercased().contains("pong"))

        mark = await recorder.mark()
        try await router.prompt(session.id, text: "Now reply with exactly the word ping.", files: [])
        _ = try await recorder.wait("second turn", after: mark, timeout: 180) {
            if case .executionEnded(session.id, _, _) = $0 { true } else { false }
        }
        #expect(await recorder.texts(after: mark, session: session.id).joined().lowercased().contains("ping"))

        let transcript = try await router.transcript(session.id)
        let replies = transcript.compactMap { if case .agentText(_, let text, _, _) = $0 { text } else { nil } }
        #expect(replies.count >= 2)
        #expect(try await router.listSessions().contains { $0.id == session.id })
        #expect(await router.planLimitsSummary(claude) != nil)
        print("router live: replies \(replies)")

        try await router.deleteSession(session.id)
        await claude.shutdown()
        await #expect(throws: EngineRouterError.unknownSession(session.id)) {
            try await router.prompt(session.id, text: "gone", files: [])
        }
    }
}

private extension EngineRouter {
    /// The plan limits the Claude engine reported during the turns.
    func planLimitsSummary(_ claude: ClaudeCodeEngine) async -> String? {
        guard let limits = await claude.planLimits() else { return nil }
        return "\(limits.status) \(limits.windows.map { "\($0.name) \(Int($0.utilization * 100))%" })"
    }
}
#endif
