import Foundation
import Testing
@testable import EnsembleKit

@Suite struct EngineCapabilitiesTests {
    private func model(_ json: String) throws -> Wire.Model {
        try JSONDecoder().decode(Wire.Model.self, from: Data(json.utf8))
    }

    @Test func mapsVariantsToEffortLevels() throws {
        let models = try Fixtures.decode(Wire.LocationEnvelope<[Wire.Model]>.self, "models.json").data
        let mock = try #require(models.first { $0.providerID == "mock" })
        #expect(ModelVariantMapping.options(for: mock) == ModelOptions(effortLevels: [.low, .medium, .high], defaultEffort: nil, supportsFastMode: false))
        #expect(ModelVariantMapping.variantID(for: .high, in: mock) == "high")
        #expect(ModelVariantMapping.variantID(for: .max, in: mock) == nil)

        // "none" is not an effort level; only "high" maps.
        let hy = try #require(models.first { $0.id == "hy4-flash-free" })
        #expect(ModelVariantMapping.options(for: hy).effortLevels == [.high])

        let plain = try #require(models.first { $0.id == "big-pickle" })
        #expect(ModelVariantMapping.options(for: plain) == ModelOptions())
    }

    @Test func mapsCustomVariantNamesAndFastMode() throws {
        let wire = try model(#"""
            {"id":"m","providerID":"p","name":"M","variants":[
              {"id":"max"},{"id":"thinking","settings":{"reasoningEffort":"medium"}},{"id":"xhigh"},{"id":"fast"},{"id":"minimal"}]}
            """#)
        let options = ModelVariantMapping.options(for: wire)
        #expect(options.effortLevels == [.medium, .xhigh, .max])
        #expect(options.supportsFastMode)
        #expect(ModelVariantMapping.variantID(for: .medium, in: wire) == "thinking")
        #expect(ModelVariantMapping.fastVariantID(in: wire) == "fast")
        #expect(ModelVariantMapping.effort(named: "Extra-High") == .xhigh)
        #expect(ModelVariantMapping.effort(named: "none") == nil)
    }

    @Test func forkBoundaryIsTheNextMessage() {
        let ids = ["msg_1", "msg_2", "msg_3"]
        #expect(HistoryBoundary.messageAfter(0, in: ids) == "msg_2")
        #expect(HistoryBoundary.messageAfter(2, in: ids) == nil)
    }

    @Test func mapsCommandsAndSkills() {
        #expect(CommandMapping.argumentHint(from: "review changes [commit|branch|pr], defaults to uncommitted") == "[commit|branch|pr]")
        #expect(CommandMapping.argumentHint(from: "guided AGENTS.md setup") == nil)
        let commands = CommandMapping.commands(
            [Wire.Command(name: "init", description: "guided AGENTS.md setup"),
             Wire.Command(name: "review", description: "review changes [commit|branch|pr], defaults to uncommitted")],
            skills: [Wire.Skill(id: "zeta", name: "Zeta", description: "Last skill"),
                     Wire.Skill(id: "opencode", name: "OpenCode", description: nil),
                     Wire.Skill(id: "review", name: "Review", description: "Same name as a command")])
        #expect(commands.map(\.id) == ["command:init", "command:review", "skill:opencode", "skill:zeta"])
        #expect(commands[1].argumentHint == "[commit|branch|pr]")
        #expect(commands[2].summary == "OpenCode")
    }

    // MARK: Requests

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (OpenCodeClient, String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (OpenCodeClient(baseURL: URL(string: "http://\(host):4096")!, password: "secret", defaultDirectory: "/tmp/ensemble-probe",
                               configuration: configuration), host)
    }

    private func body(_ request: StubURLProtocol.Recorded) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
    }

    @Test func forkPassesTheMessageAfterTheChosenOne() async throws {
        let messages = try Fixtures.text("messages.json")
        let session = try Fixtures.text("session.json")
        let (client, host) = makeClient { request in
            request.url.path.hasSuffix("/message") ? (200, messages) : (200, session)
        }
        _ = try await client.fork("ses_1", atMessageID: "msg_1ecaa9517001YyeHzAZuJJrSPY")
        _ = try await client.fork("ses_1", atMessageID: nil)
        let forks = StubURLProtocol.requests(host: host).filter { $0.url.path == "/api/session/ses_1/fork" }
        #expect(forks.count == 2)
        #expect(try body(forks[0]) == ["before": "msg_1ecaa9502002k4XlbUG1OF405N"])
        #expect(try body(forks[1]) == [:])
        await #expect(throws: OpenCodeError.self) { _ = try await client.fork("ses_1", atMessageID: "msg_missing") }
    }

    @Test func rewindStagesWithFilesThenCommits() async throws {
        let (client, host) = makeClient { _ in (200, #"{"data":{"messageID":"msg_9"}}"#) }
        try await client.rewind("ses_1", toBeforeMessageID: "msg_9")
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.url.path) == ["/api/session/ses_1/revert/stage", "/api/session/ses_1/revert/commit"])
        #expect(try body(requests[0]) == ["messageID": "msg_9", "files": true])
        #expect(client.rewindRestoresFiles)
    }

    @Test func rewindClearsTheStageWhenCommitFails() async throws {
        let (client, host) = makeClient { request in
            request.url.path.hasSuffix("/commit") ? (409, #"{"_tag":"ConflictError","message":"busy"}"#) : (200, "{}")
        }
        await #expect(throws: OpenCodeError.self) { try await client.rewind("ses_1", toBeforeMessageID: "msg_9") }
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.last?.method == "DELETE")
        #expect(requests.last?.url.path == "/api/session/ses_1/revert")
    }

    @Test func setEffortSwitchesTheVariant() async throws {
        let session = #"{"data":{"id":"ses_1","projectID":"global","model":{"id":"mock-1","providerID":"mock","variant":"default"},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1,"updated":1},"location":{"directory":"/tmp/ensemble-probe"}}}"#
        let models = try Fixtures.text("models.json")
        let (client, host) = makeClient { request in
            switch request.url.path {
            case "/api/session/ses_1": (200, session)
            case "/api/model": (200, models)
            default: (200, "{}")
            }
        }
        try await client.setEffort("ses_1", effort: .high)
        try await client.setEffort("ses_1", effort: nil)
        await #expect(throws: OpenCodeError.self) { try await client.setEffort("ses_1", effort: .max) }
        await #expect(throws: OpenCodeError.self) { try await client.setFastMode("ses_1", enabled: true) }
        try await client.setFastMode("ses_1", enabled: false)
        let switches = StubURLProtocol.requests(host: host).filter { $0.url.path == "/api/session/ses_1/model" }
        #expect(switches.count == 2)
        #expect(try body(switches[0]) == ["model": ["providerID": "mock", "id": "mock-1", "variant": "high"]])
        #expect(try body(switches[1]) == ["model": ["providerID": "mock", "id": "mock-1"]])
        #expect(try await client.modelOptions(for: ModelRef(providerID: "mock", id: "mock-1")).effortLevels == [.low, .medium, .high])
    }

    @Test func runCommandPicksCommandOrSkill() async throws {
        let session = try Fixtures.text("session.json")
        let (client, host) = makeClient { request in
            switch request.url.path {
            case "/api/command": (200, #"{"location":{"directory":"/tmp/ensemble-probe"},"data":[{"name":"review","description":"review changes"}]}"#)
            case "/api/skill": (200, #"{"location":{"directory":"/tmp/ensemble-probe"},"data":[{"id":"opencode","name":"OpenCode","path":"skill://opencode/SKILL.md","content":"long"}]}"#)
            case "/api/session/ses_e13556bb5ffeY1uEs1EG2lGeBf": (200, session)
            default: (200, "{}")
            }
        }
        let id = "ses_e13556bb5ffeY1uEs1EG2lGeBf"
        try await client.runCommand(id, name: "/review", arguments: " branch ")
        try await client.runCommand(id, name: "opencode", arguments: "")
        try await client.runCommand(id, name: "opencode", arguments: "how do agents work?")
        await #expect(throws: OpenCodeError.self) { try await client.runCommand(id, name: "nope", arguments: "") }
        let posts = StubURLProtocol.requests(host: host).filter { $0.method == "POST" }
        #expect(posts.map(\.url.path) == [
            "/api/session/\(id)/command",
            "/api/experimental/session/\(id)/skill",
            "/api/experimental/session/\(id)/skill",
            "/api/session/\(id)/prompt",
        ])
        #expect(try body(posts[0]) == ["name": "review", "text": "branch"])
        #expect(try body(posts[1]) == ["id": "opencode", "resume": true])
        #expect(try body(posts[2]) == ["id": "opencode", "resume": false])
        #expect(try body(posts[3]) == ["text": "how do agents work?"])
    }
}
