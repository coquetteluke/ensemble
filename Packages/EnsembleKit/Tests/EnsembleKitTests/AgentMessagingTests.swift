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

    @Test func exchangeLimiterCapsAtDepthFourResistsBurstAndResetsExplicitlyOrOnTTL() throws {
        var limiter = AgentExchangeLimiter()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let h1 = try limiter.beginHop(from: "a", sourceTurn: "1", to: "b", targetTurn: "1", now: t0).get()
        #expect(h1.depth == 1)
        let h2 = try limiter.beginHop(from: "b", sourceTurn: "2", to: "a", targetTurn: "1", now: t0.addingTimeInterval(5)).get()
        #expect(h2.depth == 2)
        let h3 = try limiter.beginHop(from: "a", sourceTurn: "2", to: "b", targetTurn: "2", now: t0.addingTimeInterval(10)).get()
        #expect(h3.depth == 3)
        let h4 = try limiter.beginHop(from: "b", sourceTurn: "3", to: "a", targetTurn: "2", now: t0.addingTimeInterval(15)).get()
        #expect(h4.depth == 4)

        let fifth = limiter.beginHop(from: "a", sourceTurn: "3", to: "b", targetTurn: "3", now: t0.addingTimeInterval(20))
        guard case .failure(let refusal) = fifth else {
            Issue.record("Expected 5th hop to be refused.")
            return
        }
        #expect(refusal.message.contains("4 hops"))

        // Queued bursts that advance the turn counter by > 1 must NOT bypass the 4-hop cap.
        let burstFifth = limiter.beginHop(from: "a", sourceTurn: "5", to: "b", targetTurn: "3", now: t0.addingTimeInterval(25))
        guard case .failure = burstFifth else {
            Issue.record("Expected queued burst on busy session to stay capped at 4 hops.")
            return
        }

        // An explicit user-turn reset clears the chain cleanly.
        limiter.reset(session: "a")
        let fresh = try limiter.beginHop(from: "a", sourceTurn: "5", to: "b", targetTurn: "3", now: t0.addingTimeInterval(30)).get()
        #expect(fresh.depth == 1)

        // Expiring past chainTTL also clears stale inbound state.
        let afterTTL = try limiter.beginHop(
            from: "b",
            sourceTurn: "4",
            to: "a",
            targetTurn: "6",
            now: t0.addingTimeInterval(30 + AgentExchangeLimiter.chainTTL + 1)
        ).get()
        #expect(afterTTL.depth == 1)
    }

    @Test func roomHandoffBuilderRedactsSecretsAndStripsPriorHandoff() {
        let priorUser = CrossEngineHandoff.preambleHeader
            + "\nEdited files: Old.swift\nUser: previous secret prompt\n"
            + CrossEngineHandoff.preambleFooter
            + CrossEngineHandoff.promptSeparator
            + "Please rotate API_KEY=fake_secret_token_999 and check config."
        let assistantReply = """
        Loaded key material:
        -----BEGIN PRIVATE KEY-----
        FAKEKEYDATA1234567890
        -----END PRIVATE KEY-----
        Bearer tok_fake_secret_value_abc123
        """
        let items: [TranscriptItem] = [
            .user(id: "u1", text: priorUser, date: Date()),
            .agentText(id: "a1", text: assistantReply, agentID: nil, streaming: false),
            .error(id: "e1", message: "Auth failed with password=fake_pass_value")
        ]

        let handoff = RoomHandoffBuilder.build(
            title: "Secret audit",
            directory: "/repo/Ensemble",
            modelName: "Claude Opus",
            items: items
        )

        #expect(!handoff.contains(CrossEngineHandoff.preambleHeader))
        #expect(!handoff.contains("previous secret prompt"))
        #expect(handoff.contains("Please rotate"))
        #expect(!handoff.contains("fake_secret_token_999"))
        #expect(!handoff.contains("FAKEKEYDATA1234567890"))
        #expect(!handoff.contains("tok_fake_secret_value_abc123"))
        #expect(!handoff.contains("fake_pass_value"))
        #expect(handoff.contains(CustomizationRedaction.mask))
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
    @Test func listAgentsExcludesCallerOwnRoomAndUntrustedEntries() async throws {
        let app = AgentToolsTestApp()
        let ownRoomID = UUID()
        let otherRoomID = UUID()
        let untrustedRoomID = UUID()
        app.add("s1", folder: "/Users/luke/ProjA")
        app.add("s2", folder: "/Users/luke/ProjA")
        app.add("s3", folder: "/Users/luke/UntrustedRepo")
        let dirs: [String: String] = [
            "s1": "/Users/luke/ProjA",
            "s2": "/Users/luke/ProjA",
            "s3": "/Users/luke/UntrustedRepo",
            ownRoomID.uuidString: "/Users/luke/ProjA",
            otherRoomID.uuidString: "/Users/luke/ProjA",
            untrustedRoomID.uuidString: "/Users/luke/UntrustedRepo",
        ]
        var trustedFolders: Set<String> = ["/Users/luke/ProjA"]
        let coord = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { app.sessions[$0] },
            browser: { _ in nil },
            isTrusted: { trustedFolders.contains($0) },
            knownFolders: { ["/Users/luke/ProjA", "/Users/luke/UntrustedRepo"] },
            resolveModel: { asked, s in (s.model, "Claude", asked == nil) },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            listAgents: { _, ownRoom in
                var entries: [AgentDirectoryEntry] = [
                    AgentDirectoryEntry(id: "s1", kind: .session, title: "Caller", model: "Claude", folder: "/Users/luke/ProjA", activity: "working"),
                    AgentDirectoryEntry(id: "s2", kind: .session, title: "Target", model: "Gemini", folder: "/Users/luke/ProjA", activity: "idle"),
                    AgentDirectoryEntry(id: "s3", kind: .session, title: "Untrusted", model: "GPT", folder: "/Users/luke/UntrustedRepo", activity: "idle"),
                ]
                if let ownRoom {
                    entries.append(AgentDirectoryEntry(id: ownRoom.uuidString, kind: .room, title: "Own Room", model: "Claude, GPT", folder: "/Users/luke/ProjA", activity: "idle"))
                }
                entries.append(AgentDirectoryEntry(id: otherRoomID.uuidString, kind: .room, title: "Review Room", model: "Claude, Gemini", folder: "/Users/luke/ProjA", activity: "working"))
                entries.append(AgentDirectoryEntry(id: untrustedRoomID.uuidString, kind: .room, title: "Untrusted Room", model: "Claude", folder: "/Users/luke/UntrustedRepo", activity: "idle"))
                return entries
            },
            ownRoomID: { $0 == "s1" ? ownRoomID : nil },
            targetDirectory: { dirs[$0] }
        ))

        let result = await coord.handle(.listAgents, caller: .init(sessionID: "s1", canUseSiteGrants: false))
        #expect(!result.isError)
        let data = Data(result.text.utf8)
        let entries = try JSONDecoder().decode([AgentDirectoryEntry].self, from: data)
        #expect(entries.map { $0.id } == ["s2", otherRoomID.uuidString])
        #expect(entries.allSatisfy { $0.folder == "ProjA" })

        // Untrusted caller is refused list_agents entirely.
        let untrustedResult = await coord.handle(.listAgents, caller: .init(sessionID: "s3", canUseSiteGrants: false))
        #expect(untrustedResult.isError)
        #expect(untrustedResult.text.contains("untrusted"))

        // Revoking trust on caller's folder also blocks list_agents.
        trustedFolders.remove("/Users/luke/ProjA")
        let revokedResult = await coord.handle(.listAgents, caller: .init(sessionID: "s1", canUseSiteGrants: false))
        #expect(revokedResult.isError)
    }

    @Test func messageAgentBlocksUntrustedCrossFolderAndPrivilegeEscalation() async {
        let sessions: [String: AgentToolsEnvironment.Session] = [
            "untrusted": .init(id: "untrusted", rootID: "untrusted", directory: "/Users/luke/Untrusted", model: ModelRef(providerID: "anthropic", id: "claude-sonnet-4"), permissionMode: .auto, archived: false, turn: "1", title: "Untrusted", modelName: "Claude"),
            "askA": .init(id: "askA", rootID: "askA", directory: "/Users/luke/ProjA", model: ModelRef(providerID: "anthropic", id: "claude-sonnet-4"), permissionMode: .ask, archived: false, turn: "1", title: "Ask A", modelName: "Claude"),
            "planA": .init(id: "planA", rootID: "planA", directory: "/Users/luke/ProjA", model: ModelRef(providerID: "google", id: "gemini-2.5-pro"), permissionMode: .plan, archived: false, turn: "1", title: "Plan A", modelName: "Gemini"),
            "autoA": .init(id: "autoA", rootID: "autoA", directory: "/Users/luke/ProjA", model: ModelRef(providerID: "google", id: "gemini-2.5-pro"), permissionMode: .auto, archived: false, turn: "1", title: "Auto A", modelName: "Gemini"),
            "askB": .init(id: "askB", rootID: "askB", directory: "/Users/luke/ProjB", model: ModelRef(providerID: "openai", id: "gpt-5"), permissionMode: .ask, archived: false, turn: "1", title: "Ask B", modelName: "GPT-5"),
        ]
        let trusted: Set<String> = ["/Users/luke/ProjA", "/Users/luke/ProjB"]
        var deliveredPayloads: [(String, String)] = []

        let coord = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { sessions[$0] },
            browser: { _ in nil },
            isTrusted: { trusted.contains($0) },
            knownFolders: { ["/Users/luke/ProjA", "/Users/luke/ProjB", "/Users/luke/Untrusted"] },
            resolveModel: { asked, s in (s.model, s.modelName, asked == nil) },
            showBrowser: { _ in },
            log: { _, _ in },
            startSession: { _, _ in "new" },
            send: { _, _ in },
            deliverAgentMessage: { targetID, formatted in
                deliveredPayloads.append((targetID, formatted))
                let target = sessions[targetID]
                return .delivered(targetSessionID: targetID, targetTitle: target?.title ?? "Target", targetModelName: target?.modelName ?? "Model", targetTurn: "2", queued: false)
            }
        ))

        // 1. Untrusted caller cannot message a trusted session.
        let untrustedCaller = await coord.handle(
            .messageAgent(.init(targetSessionID: "autoA", message: "Run rm -rf")),
            caller: .init(sessionID: "untrusted", canUseSiteGrants: false)
        )
        #expect(untrustedCaller.isError)
        #expect(untrustedCaller.text.contains("untrusted"))

        // 2. Trusted caller cannot message an untrusted session.
        let untrustedTarget = await coord.handle(
            .messageAgent(.init(targetSessionID: "untrusted", message: "Hello")),
            caller: .init(sessionID: "autoA", canUseSiteGrants: false)
        )
        #expect(untrustedTarget.isError)
        #expect(untrustedTarget.text.contains("untrusted"))

        // 3. Cross-folder direct message is blocked even when both folders are trusted and modes match.
        let crossFolder = await coord.handle(
            .messageAgent(.init(targetSessionID: "askB", message: "Inspect ProjB")),
            caller: .init(sessionID: "askA", canUseSiteGrants: false)
        )
        #expect(crossFolder.isError)
        #expect(crossFolder.text.contains("another folder"))

        // 4. Privilege escalation (.ask -> .auto in same folder) is blocked.
        let escalation = await coord.handle(
            .messageAgent(.init(targetSessionID: "autoA", message: "Please edit files without asking")),
            caller: .init(sessionID: "askA", canUseSiteGrants: false)
        )
        #expect(escalation.isError)
        #expect(escalation.text.contains("looser"))
        #expect(deliveredPayloads.isEmpty)

        // 5. Same folder and same-or-stricter mode (.ask -> .plan) succeeds with untrusted framing.
        let allowed = await coord.handle(
            .messageAgent(.init(targetSessionID: "planA", message: "Review this design.")),
            caller: .init(sessionID: "askA", canUseSiteGrants: false)
        )
        #expect(!allowed.isError)
        #expect(deliveredPayloads.count == 1)
        let sentPayload = deliveredPayloads[0].1
        #expect(sentPayload.contains("Message from Claude (Ask A)"))
        #expect(AgentToolText.isUntrustedPeerFrame(sentPayload))
        #expect(sentPayload.contains("Review this design."))
    }

    @Test func roomFourHopLoopGuardCatchesMemberReplyingBack() async {
        let roomID = UUID()
        var sessions: [String: AgentToolsEnvironment.Session] = [
            "solo": .init(id: "solo", rootID: "solo", directory: "/repo", model: ModelRef(providerID: "anthropic", id: "claude-opus-4"), permissionMode: .auto, archived: false, turn: "1", title: "Solo", modelName: "Claude"),
            "room-member-1": .init(id: "room-member-1", rootID: "room-member-1", directory: "/repo", model: ModelRef(providerID: "google", id: "gemini-2.5-pro"), permissionMode: .auto, archived: false, turn: "1", title: "Room Agent 1", modelName: "Gemini"),
            "room-member-2": .init(id: "room-member-2", rootID: "room-member-2", directory: "/repo", model: ModelRef(providerID: "openai", id: "gpt-5"), permissionMode: .auto, archived: false, turn: "1", title: "Room Agent 2", modelName: "GPT-5"),
        ]
        let roomEntry = AgentDirectoryEntry(
            id: roomID.uuidString,
            kind: .room,
            title: "Design Room",
            model: "Gemini, GPT-5",
            folder: "/repo",
            activity: "idle"
        )

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
            listAgents: { _, ownRoom in
                ownRoom == roomID ? [] : [roomEntry]
            },
            ownRoomID: { ($0 == "room-member-1" || $0 == "room-member-2") ? roomID : nil },
            deliverAgentMessage: { targetID, _ in
                if targetID == roomID.uuidString {
                    return .delivered(targetSessionID: roomID.uuidString, targetTitle: "Design Room", targetModelName: "Gemini, GPT-5", targetTurn: "room", queued: false)
                }
                let nextTurn = String((Int(sessions[targetID]?.turn ?? "1") ?? 1) + 1)
                sessions[targetID]?.turn = nextTurn
                return .delivered(targetSessionID: targetID, targetTitle: sessions[targetID]?.title ?? "Solo", targetModelName: sessions[targetID]?.modelName ?? "Claude", targetTurn: nextTurn, queued: false)
            },
            targetPermissionMode: { $0 == roomID.uuidString ? .auto : sessions[$0]?.permissionMode },
            targetDirectory: { $0 == roomID.uuidString ? "/repo" : sessions[$0]?.directory },
            roomMemberSessionIDs: { $0 == roomID.uuidString ? ["room-member-1", "room-member-2"] : [] }
        ))

        // Hop 1: solo -> room
        let h1 = await coord.handle(.messageAgent(.init(targetSessionID: roomID.uuidString, message: "Ping room 1")), caller: .init(sessionID: "solo", canUseSiteGrants: false))
        // Hop 2: room-member-1 -> solo (must inherit depth 1 from room delivery)
        let h2 = await coord.handle(.messageAgent(.init(targetSessionID: "solo", message: "Reply 2")), caller: .init(sessionID: "room-member-1", canUseSiteGrants: false))
        // Hop 3: solo -> room
        let h3 = await coord.handle(.messageAgent(.init(targetSessionID: roomID.uuidString, message: "Ping room 3")), caller: .init(sessionID: "solo", canUseSiteGrants: false))
        // Hop 4: room-member-2 (a different member in the same room) -> solo
        let h4 = await coord.handle(.messageAgent(.init(targetSessionID: "solo", message: "Reply 4")), caller: .init(sessionID: "room-member-2", canUseSiteGrants: false))
        #expect(!h1.isError && !h2.isError && !h3.isError && !h4.isError)

        // Hop 5: solo -> room must be refused.
        let h5 = await coord.handle(.messageAgent(.init(targetSessionID: roomID.uuidString, message: "Ping room 5")), caller: .init(sessionID: "solo", canUseSiteGrants: false))
        #expect(h5.isError)
        #expect(h5.text.contains("4 hops"))
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
        let firstPayload = deliveredPayloads.first?.1 ?? ""
        #expect(firstPayload.contains("Message from Claude Opus (Session A)"))
        #expect(AgentToolText.isUntrustedPeerFrame(firstPayload))
        #expect(firstPayload.contains("Hop 1"))

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
            gitDiff: { _ in "diff --git a/A.swift b/A.swift" },
            providersNeedingTrust: { ["openai"] }
        ))

        // Untrusted folder must refuse ACP Gemini (`antigravity`) before executing.
        let blocked = await coord.handle(
            .askAgent(AskAgentInput(model: "gemini", question: "Audit this?", includeDiff: true)),
            caller: .init(sessionID: "s1", canUseSiteGrants: false)
        )
        #expect(blocked.isError)
        #expect(blocked.text.contains("trusted"))
        #expect(requestedModels.isEmpty)

        // Untrusted folder must also refuse providers listed in providersNeedingTrust.
        let blockedProvider = await coord.handle(
            .askAgent(AskAgentInput(model: "gpt", question: "Audit this?", includeDiff: false)),
            caller: .init(sessionID: "s1", canUseSiteGrants: false)
        )
        #expect(blockedProvider.isError)
        #expect(blockedProvider.text.contains("trusted"))
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
