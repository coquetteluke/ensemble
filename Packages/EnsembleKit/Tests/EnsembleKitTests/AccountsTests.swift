import Foundation
import Testing
@testable import EnsembleKit

@Suite struct AccountsTests {
    /// Shapes copied from a live OpenCode 2.3.0 `integration.list` answer (trimmed).
    static let integrationList = #"""
    {"location":{"directory":"/tmp/project dir"},"data":[
      {"id":"openai","name":"OpenAI","methods":[
        {"type":"key"},{"type":"env","names":["OPENAI_API_KEY"]},
        {"type":"oauth","id":"chatgpt-token-sharing","label":"Sign in with ChatGPT"},
        {"type":"oauth","id":"chatgpt-browser","label":"Codex browser (legacy)"}],
       "connections":[
        {"type":"credential","id":"crd_oauth","label":"Ensemble","method":"oauth"},
        {"type":"credential","id":"crd_key","label":"Ensemble","method":"key","status":{"status":"needs_auth","message":"Expired","url":"https://example.test"}},
        {"type":"env","name":"OPENAI_API_KEY"}]},
      {"id":"github-copilot","name":"GitHub Copilot","methods":[
        {"type":"env","names":["GITHUB_TOKEN"]},
        {"type":"oauth","id":"device","label":"Login with GitHub Copilot","form":[
          {"key":"deploymentType","title":"Select GitHub deployment type","required":true,"type":"string","options":[
            {"value":"github.com","label":"GitHub.com","description":"Public"},
            {"value":"enterprise","label":"GitHub Enterprise"}]},
          {"key":"enterpriseUrl","title":"Enter your GitHub Enterprise URL or domain","required":true,
           "when":[{"key":"deploymentType","op":"eq","value":"enterprise"}],"type":"string","placeholder":"company.ghe.com"}]}],
       "connections":[]},
      {"id":"opencode","name":"OpenCode Console","methods":[
        {"type":"key","label":"API key (service account)"},
        {"type":"oauth","id":"device","label":"OpenCode Console account","form":[
          {"key":"server","hidden":true,"type":"string","format":"uri","default":"https://opencode.ai/console"}]}],
       "connections":[]},
      {"id":"amazon-bedrock","name":"Amazon Bedrock","methods":[
        {"type":"key","label":"Bedrock API key"},
        {"type":"external","id":"aws-profile","label":"AWS profile (SSO or named profile)","form":[
          {"key":"profile","title":"AWS profile","required":true,"type":"string","minLength":1,"pattern":"\\S","placeholder":"Profile name","options":[],"custom":true}]}],
       "connections":[]},
      {"id":"zai-coding-plan","name":"Z.AI Coding Plan","methods":[{"type":"key"},{"type":"env","names":["ZHIPU_API_KEY"]}],"connections":[]},
      {"id":"future","name":"Future","methods":[{"type":"brand-new"},{"type":"key","form":[{"key":"n","type":"number","default":3}]}],"connections":[{"type":"other"}]}
    ]}
    """#

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (OpenCodeClient, String) {
        let host = "accounts-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = OpenCodeClient(baseURL: URL(string: "http://\(host):4096")!, password: "secret",
                                    defaultDirectory: "/tmp/project dir", configuration: configuration)
        return (client, host)
    }

    private func body(_ request: StubURLProtocol.Recorded) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
    }

    @Test func decodesIntegrations() async throws {
        let (client, host) = makeClient { _ in (200, Self.integrationList) }
        let list = try await client.integrations()
        #expect(list.map(\.id) == ["openai", "github-copilot", "opencode", "amazon-bedrock", "zai-coding-plan", "future"])
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url.path == "/api/integration")
        #expect(request.url.query?.contains("location%5Bdirectory%5D=%2Ftmp%2Fproject%20dir") == true)

        let openai = list[0]
        #expect(openai.oauthMethods.map(\.methodID) == ["chatgpt-token-sharing", "chatgpt-browser"])
        #expect(openai.oauthMethods.map(\.isLegacy) == [false, true])
        #expect(openai.keyMethod != nil)
        #expect(openai.environmentNames == ["OPENAI_API_KEY"])
        #expect(openai.isSignedIn && openai.hasKey && openai.needsAuth)
        #expect(openai.connections(method: .key).first?.statusMessage == "Expired")
        #expect(openai.environmentConnections.first?.environmentName == "OPENAI_API_KEY")
        #expect(openai.environmentConnections.first?.credentialID == nil)

        let copilot = list[1]
        let fields = try #require(copilot.oauthMethods.first?.fields)
        #expect(fields.map(\.key) == ["deploymentType", "enterpriseUrl"])
        #expect(fields[0].options.map(\.value) == ["github.com", "enterprise"])
        #expect(fields[1].conditions == [.init(key: "deploymentType", equals: true, value: "enterprise")])
        #expect(!copilot.isConnected)

        #expect(list[2].oauthMethods.first?.fields.first?.hidden == true)
        #expect(list[3].externalMethods.first?.fields.first?.allowsCustom == true)
        #expect(list[4].isCodingPlan && !list[0].isCodingPlan)
        #expect(list[5].methods.map(\.kind) == [.unknown, .key])
        #expect(list[5].keyMethod?.fields.first?.defaultValue == "3")
    }

    @Test func formAnswersFollowFieldRules() throws {
        let copilot = OpenCodeIntegration.FormField.self
        let fields = [
            copilot.init(key: "deploymentType", kind: .string, required: true,
                         options: [.init(value: "github.com", label: "GitHub.com"), .init(value: "enterprise", label: "Enterprise")]),
            copilot.init(key: "enterpriseUrl", kind: .string, required: true,
                         conditions: [.init(key: "deploymentType", equals: true, value: "enterprise")]),
            copilot.init(key: "server", kind: .string, hidden: true, defaultValue: "https://opencode.ai/console"),
            copilot.init(key: "count", kind: .integer, defaultValue: "2"),
            copilot.init(key: "fast", kind: .boolean),
            copilot.init(key: "tags", kind: .multiselect),
        ]
        // The enterprise URL is hidden until the deployment type asks for it.
        #expect(copilot.missing(in: fields, values: [:]).map(\.key) == ["deploymentType"])
        #expect(copilot.missing(in: fields, values: ["deploymentType": "enterprise"]).map(\.key) == ["enterpriseUrl"])
        #expect(copilot.missing(in: fields, values: ["deploymentType": "github.com"]).isEmpty)

        let answer = copilot.answer(for: fields, values: ["deploymentType": "github.com", "enterpriseUrl": "ignored.example",
                                                          "fast": "true", "tags": "a, b,"])
        #expect(answer == .object(["deploymentType": "github.com", "server": "https://opencode.ai/console", "count": .number(2),
                                   "fast": .bool(true), "tags": .array(["a", "b"])]))
        #expect(copilot.answer(for: [], values: [:]) == nil)
    }

    @Test func oauthFlowCalls() async throws {
        let (client, host) = makeClient { request in
            switch (request.method, request.url.path) {
            case ("POST", "/api/integration/xai/connect/oauth"):
                return (200, #"{"location":{"directory":"/tmp/project dir"},"data":{"attemptID":"att_1","url":"https://accounts.x.ai/device","instructions":"Enter code ABCD-1234","mode":"auto","time":{"created":1795000000000,"expires":1795000600000}}}"#)
            case ("GET", "/api/integration/xai/connect/oauth/att_1"):
                return (200, #"{"location":{"directory":"/tmp/project dir"},"data":{"status":"failed","message":"Denied","time":{"created":1,"expires":2}}}"#)
            case ("POST", "/api/integration/xai/connect/oauth/att_1/complete"), ("DELETE", "/api/integration/xai/connect/oauth/att_1"):
                return (204, "")
            default:
                return (404, #"{"_tag":"NotFound","message":"no"}"#)
            }
        }
        let attempt = try await client.startOAuth(integrationID: "xai", methodID: "device")
        #expect(attempt.attemptID == "att_1")
        #expect(attempt.url == URL(string: "https://accounts.x.ai/device"))
        #expect(attempt.instructions == "Enter code ABCD-1234")
        #expect(attempt.mode == .auto && !attempt.acceptsPaste)
        #expect(attempt.expires == Date(timeIntervalSince1970: 1_795_000_600))
        #expect(try await client.oauthStatus(integrationID: "xai", attemptID: "att_1") == .failed("Denied"))
        try await client.completeOAuth(integrationID: "xai", attemptID: "att_1", code: "  pasted-code \n")
        try await client.cancelOAuth(integrationID: "xai", attemptID: "att_1")

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.method) == ["POST", "GET", "POST", "DELETE"])
        #expect(try body(requests[0]) == ["methodID": "device", "label": "Ensemble"])
        #expect(try body(requests[2]) == ["code": "pasted-code"])
        #expect(requests.allSatisfy { $0.url.query?.contains("location%5Bdirectory%5D") == true })
    }

    @Test func attemptStatusesMap() async throws {
        for (wire, expected) in [("pending", OAuthAttemptStatus.pending), ("complete", .complete), ("expired", .expired)] {
            let (client, _) = makeClient { _ in (200, #"{"data":{"status":"\#(wire)","time":{"created":1,"expires":"Infinity"}}}"#) }
            #expect(try await client.oauthStatus(integrationID: "poe", attemptID: "a") == expected)
        }
    }

    @Test func keyAndExternalConnections() async throws {
        let (client, host) = makeClient { _ in (204, "") }
        try await client.connectKey(integrationID: "azure", key: " sk-test \n", answer: ["resourceName": "my-models"])
        try await client.connectExternal(integrationID: "amazon-bedrock", methodID: "aws-profile", answer: ["profile": "dev"])
        await #expect(throws: OpenCodeError.invalidArgument("The key is empty.")) {
            try await client.connectKey(integrationID: "azure", key: "   ")
        }
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.url.path) == ["/api/integration/azure/connect/key", "/api/integration/amazon-bedrock/connect/external"])
        #expect(try body(requests[0]) == ["key": "sk-test", "label": "Ensemble", "answer": ["resourceName": "my-models"]])
        #expect(try body(requests[1]) == ["methodID": "aws-profile", "label": "Ensemble", "answer": ["profile": "dev"]])
    }

    @Test func removingAKeyKeepsTheSignIn() async throws {
        let one = #"{"location":{"directory":"/tmp"},"data":{"id":"openai","name":"OpenAI","methods":[],"connections":[{"type":"credential","id":"crd_oauth","label":"E","method":"oauth"},{"type":"credential","id":"crd_key","label":"E","method":"key"},{"type":"env","name":"OPENAI_API_KEY"}]}}"#
        let (client, host) = makeClient { request in
            request.method == "GET" ? (200, one) : (204, "")
        }
        let removed = try await client.removeCredentials(integrationID: "openai", method: .key)
        #expect(removed == 1)
        let deletes = StubURLProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletes.map(\.url.path) == ["/api/credential/crd_key"])
    }

    @Test func credentialListNeverDecodesSecrets() async throws {
        let (client, _) = makeClient { _ in
            (200, #"{"data":[{"id":"crd_1","integrationID":"openai","label":"Ensemble","active":true,"value":{"type":"key","key":"sk-secret"}}]}"#)
        }
        let list = try await client.credentials()
        #expect(list == [OpenCodeCredential(id: "crd_1", integrationID: "openai", label: "Ensemble", active: true)])
        #expect(!String(describing: list).contains("sk-secret"))
    }

    @Test func billingRules() {
        let signedIn = OpenCodeIntegration(id: "xai", name: "xAI", methods: [],
                                           connections: [.init(kind: .credential, credentialID: "c", method: .oauth)])
        let keyed = OpenCodeIntegration(id: "anthropic", name: "Anthropic", methods: [],
                                        connections: [.init(kind: .credential, credentialID: "k", method: .key)])
        let none = OpenCodeIntegration(id: "opencode", name: "OpenCode", methods: [], connections: [])
        let zero: JSONValue = [["input": 0, "output": 0, "cache": ["read": 0, "write": 0]]]
        let paid: JSONValue = [["input": 3, "output": 15]]
        #expect(ModelBillingRules.billing(integrationID: "xai", integration: signedIn, baseURL: nil, apiKey: nil, cost: paid) == .subscription)
        #expect(ModelBillingRules.billing(integrationID: "anthropic", integration: keyed, baseURL: nil, apiKey: nil, cost: paid) == .apiKey)
        #expect(ModelBillingRules.billing(integrationID: "opencode", integration: none, baseURL: nil, apiKey: "public", cost: zero) == .free)
        #expect(ModelBillingRules.billing(integrationID: "opencode", integration: none, baseURL: nil, apiKey: nil, cost: zero) == .free)
        #expect(ModelBillingRules.billing(integrationID: "zai-coding-plan", integration: nil, baseURL: nil, apiKey: nil, cost: paid) == .subscription)
        #expect(ModelBillingRules.billing(integrationID: "lmstudio", integration: none, baseURL: "http://127.0.0.1:1234/v1",
                                          apiKey: nil, cost: zero) == .local)
        #expect(ModelBillingRules.billing(integrationID: "claude-agent", integration: nil, baseURL: nil, apiKey: nil, cost: nil) == .subscription)
        #expect(ModelBillingRules.billing(integrationID: "anthropic", integration: keyed, baseURL: nil, apiKey: nil, cost: zero) == .apiKey)
        #expect(!ModelBillingRules.isZero(nil))
    }

    @Test func modelBillingFromTheEngine() async throws {
        let models = #"{"location":{"directory":"/tmp"},"data":[{"id":"big-pickle","providerID":"opencode","name":"Big Pickle","settings":{"apiKey":"public","baseURL":"https://opencode.ai/inference/openai/v1"},"cost":[{"input":0,"output":0}]},{"id":"grok-5","providerID":"xai","name":"Grok","cost":[{"input":3,"output":15}]}]}"#
        let providers = #"{"location":{"directory":"/tmp"},"data":[{"id":"opencode","integrationID":"opencode","name":"OpenCode"},{"id":"xai","integrationID":"xai","name":"xAI"}]}"#
        let integrations = #"{"location":{"directory":"/tmp"},"data":[{"id":"opencode","name":"OpenCode","methods":[],"connections":[]},{"id":"xai","name":"xAI","methods":[],"connections":[{"type":"credential","id":"c","label":"E","method":"oauth"}]}]}"#
        let (client, _) = makeClient { request in
            switch request.url.path {
            case "/api/model": (200, models)
            case "/api/provider": (200, providers)
            case "/api/integration": (200, integrations)
            default: (404, "{}")
            }
        }
        let billing = try await client.modelBilling()
        #expect(billing == ["opencode/big-pickle": .free, "xai/grok-5": .subscription])
    }

    @Test func groupsKeepOrderAndSkipEmptyGroups() {
        let models = [
            ModelInfo(ref: ModelRef(providerID: "openai", id: "a"), name: "A", providerName: "OpenAI"),
            ModelInfo(ref: ModelRef(providerID: "claude-code", id: "opus"), name: "Opus", providerName: "Claude"),
            ModelInfo(ref: ModelRef(providerID: "opencode", id: "free"), name: "Free", providerName: "OpenCode"),
            ModelInfo(ref: ModelRef(providerID: "claude-code", id: "haiku", variant: "high"), name: "Haiku", providerName: "Claude"),
        ]
        let groups = ModelGroup.groups(models, billing: ["claude-code": .subscription, "opencode/free": .free])
        #expect(groups.map(\.billing) == [.subscription, .apiKey, .free])
        #expect(groups[0].models.map(\.name) == ["Opus", "Haiku"])
        #expect(ModelBilling.key(for: ModelRef(providerID: "p", id: "m", variant: "v")) == "p/m")
    }
}
