import Foundation
import Testing
@testable import EnsembleKit

@Suite struct OpenCodeDecodingTests {
    @Test func decodesSession() throws {
        let wire = try Fixtures.decode(Wire.DataEnvelope<Wire.Session>.self, "session.json").data
        let session = EngineSession(wire: wire)
        #expect(session.id == "ses_e13556bb5ffeY1uEs1EG2lGeBf")
        #expect(session.parentID == nil)
        #expect(session.title == "Mock session")
        #expect(session.directory == "/tmp/ensemble-probe")
        // The engine's implicit "default" variant becomes no variant.
        #expect(session.model == ModelRef(providerID: "mock", id: "mock-1"))
        #expect(session.usage.inputTokens == 117_266)
        #expect(session.usage.outputTokens == 55)
        #expect(session.archived == false)
        #expect(abs(session.created.timeIntervalSince1970 - 1_794_971_964.492) < 0.001)
    }

    @Test func decodesSessionListWithChildAndArchived() throws {
        let page = try Fixtures.decode(Wire.Page<Wire.Session>.self, "sessions.json")
        let sessions = page.data.map(EngineSession.init(wire:))
        #expect(sessions.count >= 4)
        let child = try #require(sessions.first { $0.id == "ses_e13556affffeFEMwurgCjXZ3b3" })
        #expect(child.parentID == "ses_e13556bb5ffeY1uEs1EG2lGeBf")
        #expect(child.agent == "general")
        #expect(child.title == "Mock helper task")
        #expect(sessions.contains { $0.archived })

        let children = try Fixtures.decode(Wire.Page<Wire.Session>.self, "children.json").data.map(EngineSession.init(wire:))
        #expect(children.map(\.id) == ["ses_e13556affffeFEMwurgCjXZ3b3"])
    }

    @Test func mapsTranscript() throws {
        let messages = try Fixtures.decode(Wire.Page<Wire.Message>.self, "messages.json").data
        let items = TranscriptMapper.items(from: messages)

        guard case .user(let firstID, let firstText, _) = items.first else {
            Issue.record("first item is not the user prompt")
            return
        }
        #expect(firstID == "msg_1ecaa94a2001pls8Yt1ZDseMvL")
        #expect(firstText == "please start a helper")

        let tools = items.compactMap { item -> ToolCallInfo? in
            if case .tool(let info) = item { return info }
            return nil
        }
        let subagent = try #require(tools.first { $0.name == "subagent" })
        #expect(subagent.status == .succeeded)
        #expect(subagent.title == "Mock helper task")
        #expect(subagent.childSessionID == "ses_e13556affffeFEMwurgCjXZ3b3")
        #expect(subagent.inputJSON.contains("\"agent\" : \"general\""))

        let edit = try #require(tools.first { $0.name == "edit" })
        #expect(edit.title == "hello.txt")
        #expect(edit.diff?.contains("+hello from mock") == true)
        #expect(edit.outputPreview == "Edited hello.txt (1 replacement)")

        let read = try #require(tools.first { $0.name == "read" })
        #expect(read.status == .failed)
        #expect(read.outputPreview?.contains("File not found: does-not-exist.txt") == true)

        #expect(items.contains(.agentText(id: "msg_1ecaa9517001YyeHzAZuJJrSPY:text:0", text: "I started a helper.", agentID: nil, streaming: false)))
        #expect(items.contains(.notice(id: "msg_1ecaa9502002k4XlbUG1OF405N", text: "Subagent Mock helper task: completed")))
        #expect(items.contains(.notice(id: "msg_1ecab08d20010ZddDk4LLBp5PE", text: "[Board] Alice says: hello team, think first please")))

        // Reasoning and text in one message are numbered per kind, matching the event ordinals.
        #expect(items.contains(.reasoning(id: "msg_1ecadf72f001X1Y5N2W68fnkc2:reasoning:0", text: "Let me think about this carefully.", streaming: false)))
        #expect(items.contains(.agentText(id: "msg_1ecadf72f001X1Y5N2W68fnkc2:text:0", text: "Thought about it.", agentID: nil, streaming: false)))

        // An interrupted step keeps its partial text, shows no error row, and the idle marker says Interrupted.
        #expect(items.contains(.agentText(id: "msg_1ecabc2b2001pMcHYXhKK7Exye:text:0", text: "This reply streams", agentID: nil, streaming: false)))
        #expect(!items.contains { if case .error(let id, _) = $0 { return id.hasPrefix("msg_1ecabc2b2001") } else { return false } })
        #expect(items.contains(.notice(id: "msg_1ecabcebc001xC52NP4syXtvAz", text: "Interrupted")))

        // Attachments are listed under the prompt text.
        #expect(items.contains { item in
            if case .user(_, let text, _) = item { return text.hasPrefix("look at this attachment") && text.contains("Attached: hello.txt") }
            return false
        })

        // Successful idle markers add nothing.
        #expect(!items.contains { $0.id == "msg_1ecaa95f9001JJR3rKuM4l3Hu1" })
    }

    @Test func mapsPermissionTranscriptAndRequest() throws {
        let messages = try Fixtures.decode(Wire.Page<Wire.Message>.self, "messages-permission.json").data
        let items = TranscriptMapper.items(from: messages)
        let shell = try #require(items.compactMap { item -> ToolCallInfo? in
            if case .tool(let info) = item { return info }
            return nil
        }.first)
        #expect(shell.name == "shell")
        #expect(shell.title == "echo ensemble-ok")
        #expect(shell.status == .succeeded)
        #expect(shell.outputPreview == "ensemble-ok\n")
    }

    @Test func buildsContextBreakdown() throws {
        let messages = try Fixtures.decode(Wire.DataEnvelope<[Wire.Message]>.self, "context.json").data
        let context = ContextEstimator.breakdown(messages: messages, contextLimit: 128_000, outputLimit: 4096)
        #expect(context.limitTokens == 128_000)
        // The newest step's real prompt size: 10050 input + 4 output.
        #expect(context.usedTokens == 10_054)
        let keys = context.categories.map(\.key)
        #expect(keys == ["messages", "tools", "systemPrompt", "buffer", "free"])
        let byKey = Dictionary(uniqueKeysWithValues: context.categories.map { ($0.key, $0.tokens) })
        #expect(byKey["messages"]! > 0)
        #expect(byKey["tools"]! > 0)
        #expect(byKey["messages"]! + byKey["tools"]! + byKey["systemPrompt"]! == context.usedTokens)
        #expect(byKey["buffer"] == 4096)
        #expect(byKey["free"] == 128_000 - 10_054 - 4096)
        #expect(context.fractionUsed > 0.07 && context.fractionUsed < 0.08)
    }

    @Test func contextWithoutLimitHasNoFreeSpace() {
        let context = ContextEstimator.breakdown(messages: [], contextLimit: nil, outputLimit: nil)
        #expect(context.usedTokens == 0)
        #expect(context.limitTokens == 0)
        #expect(!context.categories.contains { $0.key == "free" })
    }

    @Test func mapsModelsWithProviderNames() throws {
        let wire = try Fixtures.decode(Wire.LocationEnvelope<[Wire.Model]>.self, "models.json").data
        let models = wire.map { ModelInfo(wire: $0, providerName: $0.providerID == "mock" ? "Mock LLM" : "OpenCode") }
        let mock = try #require(models.first { $0.ref.providerID == "mock" })
        #expect(mock.id == "mock/mock-1")
        #expect(mock.name == "Mock 1")
        #expect(mock.providerName == "Mock LLM")
        #expect(mock.contextLimit == 128_000)
        #expect(mock.variants == ["low", "medium", "high"])
        #expect(mock.available)

        let defaultModel = try Fixtures.decode(Wire.LocationEnvelope<Wire.Model?>.self, "model-default.json").data
        #expect(defaultModel?.providerID == "opencode")
    }

    @Test func mapsIntegrationsToProviders() throws {
        let wire = try Fixtures.decode(Wire.LocationEnvelope<[Wire.Integration]>.self, "integrations.json").data
        let providers = ProviderList.providers(from: wire)
        #expect(Array(providers.prefix(5).map(\.id)) == ["anthropic", "openai", "xai", "google", "openrouter"])
        #expect(providers.first { $0.id == "anthropic" }?.connected == false)
        // The fixture was captured with a fake key stored for 50X.
        #expect(providers.first { $0.id == "fiftyx" }?.connected == true)
        #expect(providers.first { $0.id == "fiftyx" }?.name == "50X")
    }

    @Test func credentialsNeverDecodeTheSecret() throws {
        let credentials = try Fixtures.decode(Wire.DataEnvelope<[Wire.Credential]>.self, "integration-accounts.json").data
        #expect(credentials.count == 1)
        #expect(credentials[0].integrationID == "fiftyx")
        #expect(!String(describing: credentials[0]).contains("fake-test-key"))
    }

    @Test func mapsConnectorsDiffAndSchedules() throws {
        let servers = try Fixtures.decode(Wire.LocationEnvelope<[Wire.McpServer]>.self, "mcp.json").data
        #expect(servers.map(ConnectorInfo.init(wire:)) == [ConnectorInfo(id: "bogus", name: "bogus", state: .failed)])

        let diffs = try Fixtures.decode(Wire.DataEnvelope<[Wire.FileDiff]>.self, "diff.json").data.map(FileChange.init(wire:))
        #expect(diffs.count == 1)
        #expect(diffs[0].path == "hello.txt")
        #expect(diffs[0].kind == .added)
        #expect(diffs[0].additions == 1)
        #expect(diffs[0].diff?.contains("+hello from mock") == true)

        let schedules = try Fixtures.decode(Wire.DataEnvelope<[Wire.Schedule]>.self, "schedules.json").data
        let info = ScheduleInfo(wire: schedules[0], directory: "/tmp/ensemble-probe")
        #expect(info.id == "sch_1ecabff7f00153ZKPr2lI3lUr4")
        #expect(info.title == "nightly check")
        #expect(info.prompt == "run the nightly check")
        #expect(info.schedule == "0 3 * * *")
        #expect(info.paused)
        #expect(info.nextRun == Date(timeIntervalSince1970: 1_794_988_800))
    }

    @Test func parsesScheduleText() {
        #expect(ScheduleText.when(from: "0 9 * * 1-5", timeZone: nil) == ["cron": "0 9 * * 1-5"])
        #expect(ScheduleText.when(from: "every 30 minutes", timeZone: "Europe/London") == ["every": "30 minutes", "tz": "Europe/London"])
        #expect(ScheduleText.when(from: "in 2 hours", timeZone: nil) == ["in": "2 hours"])
        #expect(ScheduleText.when(from: "at 2026-12-01T09:00", timeZone: nil) == ["at": "2026-12-01T09:00"])
        #expect(ScheduleText.when(from: "tomorrow", timeZone: nil) == nil)
        #expect(ScheduleText.when(from: "", timeZone: nil) == nil)
    }

    @Test func decodesServerInfoAndServiceFile() throws {
        let info = try Fixtures.decode(Wire.ServerInfo.self, "info.json")
        #expect(info.version == "2.3.0")

        let json = #"{"id":"x","version":"2.3.0","url":"http://127.0.0.1:4096","pid":123,"password":"hunter2"}"#
        let file = try JSONDecoder().decode(ServiceFile.self, from: Data(json.utf8))
        #expect(file.url.absoluteString == "http://127.0.0.1:4096")
        #expect(file.pid == 123)
        #expect(!file.description.contains("hunter2"))
        #expect(!String(reflecting: file).contains("hunter2"))
    }

    @Test func comparesEngineVersions() throws {
        #expect(EngineVersion("opencode v2.3.0") == EngineVersion(components: [2, 3, 0]))
        #expect(EngineVersion("2.3") == EngineVersion("2.3.0"))
        #expect(try #require(EngineVersion("2.2.9")) < .minimum)
        #expect(try #require(EngineVersion("2.10.0")) > .minimum)
        #expect(try #require(EngineVersion("v3.0.0-beta.1")) > .minimum)
        #expect(EngineVersion("no version here") == nil)
    }
}
