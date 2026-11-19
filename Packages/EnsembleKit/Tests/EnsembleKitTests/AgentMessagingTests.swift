import Foundation
import Testing
@testable import EnsembleKit

@Suite struct AgentMessagingProtocolAndPolicyTests {
    @Test func mcpToolsListIncludesCrossSessionToolsAndSchemas() throws {
        let tools = try #require(AgentToolsMCP.toolsList["tools"]?.arrayValue)
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { entry -> (String, JSONValue)? in
            guard let name = entry["name"]?.stringValue else { return nil }
            return (name, entry)
        })

        let listAgents = try #require(byName["list_agents"])
        #expect(listAgents["inputSchema"]?["required"]?.arrayValue?.isEmpty == true)

        let messageAgent = try #require(byName["message_agent"])
        let msgRequired = messageAgent["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(msgRequired) == ["target_session_id", "message"])

        let askAgent = try #require(byName["ask_agent"])
        let askRequired = askAgent["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(askRequired) == ["model", "question"])
        #expect(askAgent["inputSchema"]?["properties"]?["include_diff"]?["type"]?.stringValue == "boolean")
    }

    @Test func toolCallParseValidatesArguments() throws {
        let listCall = try AgentToolCall.parse(name: "list_agents", arguments: .object([:]))
        #expect(listCall == .listAgents)

        let msgCall = try AgentToolCall.parse(
            name: "message_agent",
            arguments: .object([
                "target_session_id": .string("sess-2"),
                "message": .string("Hello from agent 1")
            ])
        )
        #expect(msgCall == .messageAgent(AgentMessageInput(targetSessionID: "sess-2", message: "Hello from agent 1")))

        let askCall = try AgentToolCall.parse(
            name: "ask_agent",
            arguments: .object([
                "model": .string("gemini"),
                "question": .string("Any race conditions?"),
                "include_diff": .bool(true)
            ])
        )
        #expect(askCall == .askAgent(AskAgentInput(model: "gemini", question: "Any race conditions?", includeDiff: true)))

        #expect(throws: AgentToolCallError.self) {
            try AgentToolCall.parse(
                name: "message_agent",
                arguments: .object([
                    "target_session_id": .string("sess-2"),
                    "message": .string(String(repeating: "a", count: AgentMessageInput.maxMessage + 1))
                ])
            )
        }
        #expect(throws: AgentToolCallError.self) {
            try AgentToolCall.parse(
                name: "ask_agent",
                arguments: .object([
                    "model": .string("gpt"),
                    "question": .string("Check diff"),
                    "include_diff": .string("yes")
                ])
            )
        }
    }

    @Test func directoryEntryStripsFullPaths() {
        let entry = AgentDirectoryEntry(
            id: "s-1",
            kind: .session,
            title: "Build auth",
            model: "Claude Sonnet",
            folder: "/Users/luke/SecretClient/AppRepo",
            activity: "idle"
        )
        #expect(entry.folder == "AppRepo")
        let encoded = AgentDirectoryEntry.encodeList([entry])
        #expect(!encoded.contains("/Users/"))
        #expect(!encoded.contains("SecretClient"))
        #expect(encoded.contains("\"kind\":\"session\""))
    }

    @Test func exchangeLimiterCapsAtDepthFourAndResetsOnNewUserTurn() throws {
        var limiter = AgentExchangeLimiter()

        let h1 = try limiter.beginHop(from: "a", sourceTurn: "1", to: "b", targetTurn: "1").get()
        #expect(h1.depth == 1)
        let h2 = try limiter.beginHop(from: "b", sourceTurn: "2", to: "a", targetTurn: "1").get()
        #expect(h2.depth == 2)
        let h3 = try limiter.beginHop(from: "a", sourceTurn: "2", to: "b", targetTurn: "2").get()
        #expect(h3.depth == 3)
        let h4 = try limiter.beginHop(from: "b", sourceTurn: "3", to: "a", targetTurn: "2").get()
        #expect(h4.depth == 4)

        let fifth = limiter.beginHop(from: "a", sourceTurn: "3", to: "b", targetTurn: "3")
        guard case .failure(let refusal) = fifth else {
            Issue.record("Expected 5th hop to be refused.")
            return
        }
        #expect(refusal.message.contains("4 hops"))

        // A direct new user turn advances beyond a single increment and resets the chain cleanly.
        let fresh = try limiter.beginHop(from: "a", sourceTurn: "5", to: "b", targetTurn: "3").get()
        #expect(fresh.depth == 1)
    }

    @Test func roomHandoffBuilderFormatsAndRespectsCap() {
        var items: [TranscriptItem] = []
        for i in 1...18 {
            items.append(.user(id: "u\(i)", text: "Turn \(i): " + String(repeating: "context ", count: 90), date: Date()))
            items.append(.agentText(id: "a\(i)", text: "Answer \(i): " + String(repeating: "details ", count: 90), agentID: nil, streaming: false))
        }
        let changes = [
            FileChange(path: "/repo/Sources/Feature.swift", kind: .modified, additions: 12, deletions: 4)
        ]

        let handoff = RoomHandoffBuilder.build(
            title: "Concurrency fix",
            directory: "/repo/Ensemble",
            modelName: "Claude Opus",
            items: items,
            changedFiles: changes
        )

        #expect(handoff.count <= RoomHandoffBuilder.maxCharacters)
        #expect(handoff.contains("Concurrency fix"))
        #expect(handoff.contains("Ensemble"))
        #expect(handoff.contains("Claude Opus"))
        #expect(handoff.contains("Sources/Feature.swift"))
        #expect(handoff.contains("Answer 18:"))
        #expect(handoff.contains("[Earlier turns trimmed]"))
    }

    @MainActor
    @Test func secondOpinionOrderingParserAndStoreTransitions() {
        let models = [
            ModelInfo(ref: ModelRef(providerID: "anthropic", id: "claude-opus-4"), name: "Claude Opus 4", providerName: "Anthropic", available: true),
            ModelInfo(ref: ModelRef(providerID: "anthropic", id: "claude-sonnet-4"), name: "Claude Sonnet 4", providerName: "Anthropic", available: true),
            ModelInfo(ref: ModelRef(providerID: "google", id: "gemini-2.5-pro"), name: "Gemini 2.5 Pro", providerName: "Google", available: true),
            ModelInfo(ref: ModelRef(providerID: "openai", id: "gpt-5"), name: "GPT-5", providerName: "OpenAI", available: false),
        ]

        let options = SecondOpinionModels.options(
            from: models,
            current: ModelRef(providerID: "anthropic", id: "claude-opus-4")
        )
        #expect(options.count == 2)
        #expect(options[0].ref == ModelRef(providerID: "google", id: "gemini-2.5-pro"))
        #expect(options[0].isOtherMaker == true)
        #expect(options[1].ref == ModelRef(providerID: "anthropic", id: "claude-sonnet-4"))
        #expect(options[1].isOtherMaker == false)

        let prompt = SecondOpinionPromptBuilder.build(
            replyText: "Use an actor to serialize state.",
            diffSummary: "diff --git a/File.swift b/File.swift",
            directory: "/Users/luke/Ensemble"
        )
        #expect(prompt.contains("Use an actor to serialize state."))
        #expect(prompt.contains("diff --git"))

        let parsed = SecondOpinionParser.parse("""
        VERDICT: MIXED
        SUMMARY: Actor isolation is right, though cleanup can race on cancellation.
        CONCERNS:
        - Delete helper session inside a detached task.
        - Avoid sleeping inside defer.
        DETAILS:
        More context here.
        """)
        #expect(parsed.verdict == .mixed)
        #expect(parsed.summary == "Actor isolation is right, though cleanup can race on cancellation.")
        #expect(parsed.concerns == [
            "Delete helper session inside a detached task.",
            "Avoid sleeping inside defer."
        ])

        let store = SecondOpinionStore()
        let entry = store.begin(
            sessionID: "s1",
            itemID: "m1",
            replyText: "Original reply",
            model: options[0].ref,
            modelName: options[0].name,
            makerName: options[0].makerName
        )
        #expect(store.opinions(for: "s1")["m1"]?.first?.status == .loading)

        store.markFailed(id: entry.id, sessionID: "s1", itemID: "m1", error: "Network error")
        #expect(store.opinions(for: "s1")["m1"]?.first?.status == .failed("Network error"))

        let retried = store.prepareRetry(id: entry.id, sessionID: "s1", itemID: "m1")
        #expect(retried?.status == .loading)

        store.markAnswered(id: entry.id, sessionID: "s1", itemID: "m1", rawText: "VERDICT: AGREE\nSUMMARY: Solid change.")
        let answered = store.opinions(for: "s1")["m1"]?.first
        #expect(answered?.status == .answered)
        #expect(answered?.verdict == .agrees)
        #expect(answered?.summary == "Solid change.")

        store.dismiss(id: entry.id, sessionID: "s1", itemID: "m1")
        #expect(store.opinions(for: "s1")["m1"] == nil)
    }
}

#if os(macOS)
@MainActor
@Suite(.serialized) struct AgentMessagingCoordinatorTests {
    @Test func listAgentsExcludesCallerAndOwnRoom() async throws {
        let app = AgentToolsTestApp()
        let ownRoomID = UUID()
        let otherRoomID = UUID()
        app.add("s1", folder: "/Users/luke/ProjA")
        app.add("s2", folder: "/Users/luke/ProjB")
        let coord = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { app.sessions[$0] },
            browser: { _ in nil },
            isTrusted: { _ in true },
            knownFolders: { ["/Users/luke/ProjA", "/Users/luke/ProjB"] },
            resolveModel: { asked, s in (s.model, "Claude", asked == nil) },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            listAgents: { _, ownRoom in
                var entries: [AgentDirectoryEntry] = [
                    AgentDirectoryEntry(id: "s1", kind: .session, title: "Caller", model: "Claude", folder: "/Users/luke/ProjA", activity: "working"),
                    AgentDirectoryEntry(id: "s2", kind: .session, title: "Target", model: "Gemini", folder: "/Users/luke/ProjB", activity: "idle"),
                ]
                if let ownRoom {
                    entries.append(AgentDirectoryEntry(id: ownRoom.uuidString, kind: .room, title: "Own Room", model: "Claude, GPT", folder: "/Users/luke/ProjA", activity: "idle"))
                }
                entries.append(AgentDirectoryEntry(id: otherRoomID.uuidString, kind: .room, title: "Review Room", model: "Claude, Gemini", folder: "/Users/luke/ProjB", activity: "working"))
                return entries
            },
            ownRoomID: { $0 == "s1" ? ownRoomID : nil }
        ))

        let result = await coord.handle(.listAgents, caller: .init(sessionID: "s1", canUseSiteGrants: false))
        #expect(!result.isError)
        let data = Data(result.text.utf8)
        let entries = try JSONDecoder().decode([AgentDirectoryEntry].self, from: data)
        #expect(entries.map { $0.id } == ["s2", otherRoomID.uuidString])
        #expect(entries.allSatisfy { $0.folder == "ProjB" })
    }

    @Test func messageAgentDeliversVisibleInBothTranscriptsAndRefusesFifthHop() async {
        var sessions: [String: AgentToolsEnvironment.Session] = [
            "a": .init(id: "a", rootID: "a", directory: "/repo", model: ModelRef(providerID: "anthropic", id: "claude-opus-4"), permissionMode: .auto, archived: false, turn: "1", title: "Session A", modelName: "Claude Opus"),
            "b": .init(id: "b", rootID: "b", directory: "/repo", model: ModelRef(providerID: "google", id: "gemini-2.5-pro"), permissionMode: .auto, archived: false, turn: "1", title: "Session B", modelName: "Gemini 2.5 Pro"),
        ]
        var deliveredPayloads: [(String, String)] = []
        let coord = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { sessions[$0] },
            browser: { _ in nil },
            isTrusted: { _ in true },
            knownFolders: { ["/repo"] },
            resolveModel: { asked, s in (s.model, s.modelName, asked == nil) },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            latestItemID: { "\($0)-item-latest" },
            deliverAgentMessage: { targetID, formatted in
                deliveredPayloads.append((targetID, formatted))
                let nextTurn = String((Int(sessions[targetID]?.turn ?? "1") ?? 1) + 1)
                sessions[targetID]?.turn = nextTurn
                let title = sessions[targetID]?.title ?? "Target"
                let modelName = sessions[targetID]?.modelName ?? "Model"
                return .delivered(targetSessionID: targetID, targetTitle: title, targetModelName: modelName, targetTurn: nextTurn, queued: false)
            }
        ))

        let selfRefusal = await coord.handle(
            .messageAgent(AgentMessageInput(targetSessionID: "a", message: "Ping self")),
            caller: .init(sessionID: "a", canUseSiteGrants: false)
        )
        #expect(selfRefusal.isError)

        // Hops 1..4 bounce between A and B cleanly.
        let r1 = await coord.handle(.messageAgent(.init(targetSessionID: "b", message: "Hop 1")), caller: .init(sessionID: "a", canUseSiteGrants: false))
        let r2 = await coord.handle(.messageAgent(.init(targetSessionID: "a", message: "Hop 2")), caller: .init(sessionID: "b", canUseSiteGrants: false))
        let r3 = await coord.handle(.messageAgent(.init(targetSessionID: "b", message: "Hop 3")), caller: .init(sessionID: "a", canUseSiteGrants: false))
        let r4 = await coord.handle(.messageAgent(.init(targetSessionID: "a", message: "Hop 4")), caller: .init(sessionID: "b", canUseSiteGrants: false))
        #expect(!r1.isError && !r2.isError && !r3.isError && !r4.isError)
        #expect(deliveredPayloads.first?.1 == "[From Claude Opus (Session A)] Hop 1")

        // Visible in BOTH caller and target transcripts.
        #expect(coord.exchanges(for: "a").count == 4)
        #expect(coord.exchanges(for: "b").count == 4)
        #expect(coord.exchanges(for: "a").first?.anchors["a"] == "a-item-latest")
        #expect(coord.exchanges(for: "b").first?.anchors["b"] == "b-item-latest")
        #expect(coord.exchanges(for: "a").first?.status == .delivered)

        // 5th hop is refused cleanly.
        let r5 = await coord.handle(.messageAgent(.init(targetSessionID: "b", message: "Hop 5")), caller: .init(sessionID: "a", canUseSiteGrants: false))
        #expect(r5.isError)
        #expect(r5.text.contains("4 hops"))
    }

    @Test func askAgentRespectsTrustDiffAndExchanges() async {
        let claude = ModelInfo(ref: ModelRef(providerID: "anthropic", id: "claude-sonnet-4"), name: "Claude Sonnet 4", providerName: "Anthropic", available: true)
        let gemini = ModelInfo(ref: ModelRef(providerID: "antigravity", id: "gemini-3-pro"), name: "Gemini 3 Pro", providerName: "Google", available: true)
        let gpt = ModelInfo(ref: ModelRef(providerID: "openai", id: "gpt-5"), name: "GPT-5", providerName: "OpenAI", available: true)

        var trusted = false
        var seenDiffs: [String?] = []
        var requestedModels: [ModelRef] = []

        let session = AgentToolsEnvironment.Session(
            id: "s1",
            rootID: "s1",
            directory: "/untrusted/repo",
            model: claude.ref,
            permissionMode: .auto,
            archived: false,
            turn: "1",
            title: "Main",
            modelName: claude.name
        )

        let coord = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { $0 == "s1" ? session : nil },
            browser: { _ in nil },
            isTrusted: { _ in trusted },
            knownFolders: { ["/untrusted/repo"] },
            resolveModel: { asked, s in
                let outcome = ProposalModelMatch.resolve(asked: asked, models: [claude, gemini, gpt], current: s.model)
                return (outcome.model, outcome.name, outcome.matched)
            },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            availableModels: { [claude, gemini, gpt] },
            askAgent: { request in
                requestedModels.append(request.model)
                seenDiffs.append(request.diffSummary)
                return .answered("Checked by \(request.modelName).")
            },
            gitDiff: { _ in "diff --git a/A.swift b/A.swift" }
        ))

        // Untrusted folder must refuse ACP Gemini (`antigravity`) before executing.
        let blocked = await coord.handle(
            .askAgent(AskAgentInput(model: "gemini", question: "Audit this?", includeDiff: true)),
            caller: .init(sessionID: "s1", canUseSiteGrants: false)
        )
        #expect(blocked.isError)
        #expect(blocked.text.contains("trusted"))
        #expect(requestedModels.isEmpty)

        // Trust folder now and ask with include_diff: true.
        trusted = true
        let ok = await coord.handle(
            .askAgent(AskAgentInput(model: "gpt", question: "Check diff", includeDiff: true)),
            caller: .init(sessionID: "s1", canUseSiteGrants: false)
        )
        #expect(!ok.isError)
        #expect(ok.text == "Checked by GPT-5.")
        #expect(requestedModels == [gpt.ref])
        #expect(seenDiffs == ["diff --git a/A.swift b/A.swift"])
        #expect(coord.exchanges(for: "s1").count == 1)
        #expect(coord.exchanges(for: "s1").first?.status == .answered)
        #expect(coord.exchanges(for: "s1").first?.replyPreview == "Checked by GPT-5.")
    }

    @Test func oneShotPromptRunnerAnswersAndDeletesHelperSession() async throws {
        let engine = PreviewEngine(delayScale: 0)
        let model = ModelRef(providerID: "openai", id: "gpt-5")
        let initialIDs = Set(try await engine.listSessions().map(\.id))

        let result = await OneShotPromptRunner.run(
            api: engine,
            directory: "/tmp",
            model: model,
            prompt: "Summarize any risks without editing files.",
            timeout: .seconds(10)
        )

        guard case .answered(let answer) = result else {
            Issue.record("Expected answered outcome from PreviewEngine helper run, got \(result)")
            return
        }
        #expect(!answer.isEmpty)

        let remainingIDs = Set(try await engine.listSessions().map(\.id))
        #expect(remainingIDs == initialIDs)
    }
}
#endif
