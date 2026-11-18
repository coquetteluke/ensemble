import Foundation
import Testing
@testable import EnsembleKit

/// Rooms through the engine router: agents on different engines in one room, per-folder model lists, and worktree
/// access forwarded to the engine that owns each session.
@Suite @MainActor struct RoomRouterTests {
    static func model(_ provider: String, _ id: String) -> ModelInfo {
        ModelInfo(ref: ModelRef(providerID: provider, id: id), name: id, providerName: provider)
    }

    /// Alpha runs on the fallback engine (OpenCode's place), Beta on the engine that claims `claude-code`.
    @Test func teamMixesEnginesThroughTheRouter() async throws {
        let openCode = FakeEngine(sessionPrefix: "oc_")
        let claude = FakeEngine(sessionPrefix: "cl_")
        let router = EngineRouter(fallback: openCode)
        router.register(claude, providers: ["claude-code"], billing: .subscription, id: "claude", name: "Claude")

        openCode.on("Alpha", "Task for the room", reply: "PLAN: p\nASSIGN @Alpha: part a\nASSIGN @Beta: part b")
        openCode.on("Alpha", "Your assignment", reply: "Part a is in.\nDONE")
        claude.on("Beta", "Your assignment", reply: "@Alpha: is part a merged first?\nDONE")
        openCode.on("Alpha", "is part a merged first", reply: "@Beta: yes, in plan order.")
        claude.on("Beta", "yes, in plan order", reply: "Thanks.")
        claude.on("Beta", "Please review Alpha", reply: "APPROVE")
        openCode.on("Alpha", "Please review Beta", reply: "APPROVE")
        openCode.on("Alpha", "Post a short summary", reply: "Summary.")

        let agents = [
            AgentSpec(name: "Alpha", model: ModelRef(providerID: "mock", id: "alpha"), role: "Leads", colorHex: "#888888"),
            AgentSpec(name: "Beta", model: ModelRef(providerID: "claude-code", id: "opus"), role: "Builds", colorHex: "#999999"),
        ]
        let spec = RoomSpec(title: "Test Room", directory: "/tmp/ensemble-room-test", agents: agents, mode: .team,
                            leadAgentID: agents[0].id, permissionMode: .auto)
        let git = FakeGitOps()
        let engine = try await RoomEngine.create(spec: spec, api: router, store: InMemoryRoomStore(), git: git)
        defer { engine.close() }

        #expect(openCode.created.map(\.sessionID) == [engine.sessionID(for: agents[0].id)])
        #expect(claude.created.map(\.sessionID) == [engine.sessionID(for: agents[1].id)])
        #expect(claude.created.first?.model == ModelRef(providerID: "claude-code", id: "opus"))

        await engine.start(task: "Build both parts")
        try await engine.waitFor("the run to finish", fake: openCode) { $0.state.phase == .finished }

        // Beta's question crossed engines and Alpha's answer came back.
        #expect(openCode.wakes(to: "Alpha").contains { $0.text == "[Room] Beta (claude-code/opus) to you: is part a merged first?" })
        #expect(claude.wakes(to: "Beta").contains { $0.text == "[Room] Alpha (mock/alpha) to you: yes, in plan order." })
        #expect(engine.state.assignments.allSatisfy { $0.status == .merged })
        // Each engine was asked to open its own agent's worktree.
        #expect(openCode.worktreeGrants.map(\.agent) == ["Alpha"])
        #expect(claude.worktreeGrants.map(\.agent) == ["Beta"])
        #expect(openCode.unmatched.isEmpty && claude.unmatched.isEmpty, "\(openCode.unmatched) \(claude.unmatched)")
    }

    @Test func folderModelsComeFromEveryEngine() async throws {
        let openCode = FakeEngine(sessionPrefix: "oc_", models: [Self.model("mock", "a"), Self.model("openai", "gpt")])
        let claude = FakeEngine(sessionPrefix: "cl_", models: [Self.model("claude-code", "opus"), Self.model("openai", "gpt")])
        let router = EngineRouter(fallback: openCode)
        router.register(claude, providers: ["claude-code"], billing: .subscription, id: "claude", name: "Claude")

        let models = try await router.models(directory: "/tmp/project")
        #expect(models.map(\.id) == ["mock/a", "openai/gpt", "claude-code/opus"])
        #expect(openCode.modelDirectories == ["/tmp/project"])
        #expect(claude.modelDirectories == ["/tmp/project"])
    }

    @Test func worktreeAccessGoesToTheSessionsEngine() async throws {
        let openCode = FakeEngine(sessionPrefix: "oc_")
        let router = EngineRouter(fallback: openCode)
        let session = try await router.createSession(directory: "/tmp", model: nil, agent: nil, permissionMode: .auto, parentID: nil)
        #expect(try await router.allowWorktreeEdits(session.id, worktreePath: "/tmp/.ensemble/worktrees/x"))
        #expect(openCode.worktreeGrants.map(\.path) == ["/tmp/.ensemble/worktrees/x"])
        await #expect(throws: EngineRouterError.unknownSession("nope")) {
            try await router.allowWorktreeEdits("nope", worktreePath: "/tmp/.ensemble/worktrees/x")
        }
    }
}
