import Foundation

// Accounts: OpenCode's integrations (sign-in methods per provider), the OAuth sign-in flow, key and external
// connections, and who pays for each model. Secrets never pass through here: key values go one way to the engine,
// credential listings are read from the integration's connections (ids, labels, methods), never from the
// credential store's values.

/// One provider integration from `GET /api/integration`, with its sign-in methods and current connections.
public struct OpenCodeIntegration: Hashable, Sendable, Identifiable {
    /// A field of a sign-in method's form (an AWS profile, a GitHub Enterprise URL, an Azure resource name...).
    public struct FormField: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case string, number, integer, boolean, multiselect, external, unknown }

        public struct Option: Hashable, Sendable {
            public var value: String
            public var label: String
            public var summary: String?
        }

        /// The field is shown only when another field has (or does not have) a value.
        public struct Condition: Hashable, Sendable {
            public var key: String
            public var equals: Bool
            public var value: String
        }

        public var key: String
        public var kind: Kind
        public var title: String?
        public var summary: String?
        public var required: Bool
        public var hidden: Bool
        public var placeholder: String?
        public var defaultValue: String?
        public var options: [Option]
        /// True when a value outside `options` is allowed.
        public var allowsCustom: Bool
        /// For `external` fields: a page to open.
        public var url: String?
        public var conditions: [Condition]
        public var id: String { key }

        public init(key: String, kind: Kind, title: String? = nil, summary: String? = nil, required: Bool = false,
                    hidden: Bool = false, placeholder: String? = nil, defaultValue: String? = nil, options: [Option] = [],
                    allowsCustom: Bool = false, url: String? = nil, conditions: [Condition] = []) {
            self.key = key
            self.kind = kind
            self.title = title
            self.summary = summary
            self.required = required
            self.hidden = hidden
            self.placeholder = placeholder
            self.defaultValue = defaultValue
            self.options = options
            self.allowsCustom = allowsCustom
            self.url = url
            self.conditions = conditions
        }

        /// Whether the field applies, given the other fields' values (defaults count).
        public func isVisible(in values: [String: String], fields: [FormField]) -> Bool {
            guard !hidden else { return false }
            return conditions.allSatisfy { condition in
                let other = values[condition.key].flatMap { $0.isEmpty ? nil : $0 }
                    ?? fields.first { $0.key == condition.key }?.defaultValue ?? ""
                return (other == condition.value) == condition.equals
            }
        }

        /// The engine's answer object for a form: visible fields with a value (or their default) and hidden fields'
        /// defaults, typed per field. Nil when there is nothing to send.
        public static func answer(for fields: [FormField], values: [String: String]) -> JSONValue? {
            var answer: [String: JSONValue] = [:]
            for field in fields {
                let raw: String?
                if field.hidden {
                    raw = field.defaultValue
                } else if field.isVisible(in: values, fields: fields) {
                    let typed = values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    raw = (typed?.isEmpty == false) ? typed : field.defaultValue
                } else {
                    raw = nil
                }
                guard let raw, !raw.isEmpty else { continue }
                switch field.kind {
                case .boolean:
                    answer[field.key] = .bool(["true", "yes", "1", "on"].contains(raw.lowercased()))
                case .number, .integer:
                    if let number = Double(raw) { answer[field.key] = .number(number) }
                case .multiselect:
                    let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    answer[field.key] = .array(items.map(JSONValue.string))
                case .external:
                    continue
                case .string, .unknown:
                    answer[field.key] = .string(raw)
                }
            }
            return answer.isEmpty ? nil : .object(answer)
        }

        /// Required, visible fields that have neither a value nor a default.
        public static func missing(in fields: [FormField], values: [String: String]) -> [FormField] {
            fields.filter { field in
                guard field.required, field.kind != .external, field.isVisible(in: values, fields: fields) else { return false }
                let typed = values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return typed.isEmpty && (field.defaultValue ?? "").isEmpty
            }
        }
    }

    /// One way to connect: browser sign-in (`oauth`), an API key, existing cloud credentials (`external`), a command,
    /// or environment variables.
    public struct Method: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case oauth, key, external, command, env, unknown }

        public var kind: Kind
        /// Needed to start `oauth`, `external` and `command` methods.
        public var methodID: String?
        public var label: String?
        public var fields: [FormField]
        /// For `env`: the variable names the engine reads.
        public var environmentNames: [String]
        public var id: String { "\(kind.rawValue):\(methodID ?? "")" }

        public init(kind: Kind, methodID: String? = nil, label: String? = nil, fields: [FormField] = [], environmentNames: [String] = []) {
            self.kind = kind
            self.methodID = methodID
            self.label = label
            self.fields = fields
            self.environmentNames = environmentNames
        }

        /// Methods OpenCode keeps for old setups (their labels say "legacy").
        public var isLegacy: Bool { label?.lowercased().contains("legacy") ?? false }
    }

    /// A stored credential or an environment variable the engine uses for this provider.
    public struct Connection: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case credential, env, unknown }

        public var kind: Kind
        public var credentialID: String?
        public var label: String?
        /// How the credential was made: `key`, `oauth` or `external`. Nil for environment variables.
        public var method: Method.Kind?
        /// For `env` connections: the variable's name (never its value).
        public var environmentName: String?
        /// The engine says the connection must sign in again.
        public var needsAuth: Bool
        public var statusMessage: String?
        public var statusURL: String?
        public var id: String { credentialID ?? "env:\(environmentName ?? label ?? "")" }

        public init(kind: Kind, credentialID: String? = nil, label: String? = nil, method: Method.Kind? = nil,
                    environmentName: String? = nil, needsAuth: Bool = false, statusMessage: String? = nil, statusURL: String? = nil) {
            self.kind = kind
            self.credentialID = credentialID
            self.label = label
            self.method = method
            self.environmentName = environmentName
            self.needsAuth = needsAuth
            self.statusMessage = statusMessage
            self.statusURL = statusURL
        }
    }

    public var id: String
    public var name: String
    public var methods: [Method]
    public var connections: [Connection]

    public init(id: String, name: String, methods: [Method], connections: [Connection]) {
        self.id = id
        self.name = name
        self.methods = methods
        self.connections = connections
    }

    public var oauthMethods: [Method] { methods.filter { $0.kind == .oauth } }
    public var keyMethod: Method? { methods.first { $0.kind == .key } }
    public var externalMethods: [Method] { methods.filter { $0.kind == .external } }
    public var environmentNames: [String] { methods.filter { $0.kind == .env }.flatMap(\.environmentNames) }

    /// Credentials made by one kind of method.
    public func connections(method: Method.Kind) -> [Connection] {
        connections.filter { $0.kind == .credential && $0.method == method }
    }

    public var environmentConnections: [Connection] { connections.filter { $0.kind == .env } }

    /// Signed in through the browser.
    public var isSignedIn: Bool { !connections(method: .oauth).isEmpty }
    /// Has a stored key or a key from an environment variable.
    public var hasKey: Bool { !connections(method: .key).isEmpty || !environmentConnections.isEmpty }
    public var isExternallyConnected: Bool { !connections(method: .external).isEmpty }
    public var isConnected: Bool { !connections.isEmpty }
    public var needsAuth: Bool { connections.contains(where: \.needsAuth) }

    /// Subscription-style plans sold with a key (Kimi For Coding, Z.AI and Zhipu coding plans, MiniMax, Alibaba,
    /// Tencent, Volcengine and Xiaomi token plans, StepFun step plans, KUAE, Umans, OpenCode Go, Ollama Cloud,
    /// Synthetic).
    public var isCodingPlan: Bool { Self.isCodingPlan(id: id) }

    public static let codingPlanMarkers = ["coding-plan", "code-plan", "token-plan", "step-plan"]
    public static let codingPlanIDs: Set<String> = ["opencode-go", "ollama-cloud", "synthetic"]

    public static func isCodingPlan(id: String) -> Bool {
        codingPlanIDs.contains(id) || codingPlanMarkers.contains { id.contains($0) }
    }
}

/// A browser sign-in started with `startOAuth`.
public struct OAuthAttempt: Hashable, Sendable {
    public enum Mode: String, Sendable {
        /// The engine finishes by itself once the browser step is done (device code or local callback).
        case auto
        /// The browser shows a code that the user pastes back (`completeOAuth(code:)`).
        case code
    }

    public var integrationID: String
    public var attemptID: String
    /// The page to open (as sent by the engine).
    public var urlString: String
    /// What the user does in the browser, for example a device code to enter.
    public var instructions: String
    public var mode: Mode
    /// For `auto`: the redirect URL may also be pasted back if the browser cannot reach the engine.
    public var acceptsPaste: Bool
    public var expires: Date?

    public var url: URL? { URL(string: urlString) }
}

public enum OAuthAttemptStatus: Equatable, Sendable {
    case pending
    case complete
    case failed(String)
    case expired
}

/// A stored credential, without its secret.
public struct OpenCodeCredential: Hashable, Sendable, Identifiable {
    public var id: String
    public var integrationID: String
    public var label: String?
    public var active: Bool
}

// MARK: Wire shapes (decoded here so the shared wire types stay as they are)

enum AccountsWire {
    struct FormOption: Decodable {
        let value: String
        let label: String?
        let description: String?
    }

    struct FormWhen: Decodable {
        let key: String
        let op: String?
        let value: JSONValue?
    }

    struct FormField: Decodable {
        let key: String
        let type: String
        let title: String?
        let description: String?
        let required: Bool?
        let hidden: Bool?
        let placeholder: String?
        let `default`: JSONValue?
        let options: [FormOption]?
        let custom: Bool?
        let url: String?
        let when: [FormWhen]?
    }

    struct Method: Decodable {
        let type: String
        let id: String?
        let label: String?
        let names: [String]?
        let form: [Wire.Lossy<FormField>]?
    }

    struct Status: Decodable {
        let status: String?
        let message: String?
        let url: String?
    }

    struct Connection: Decodable {
        let type: String
        let id: String?
        let label: String?
        let name: String?
        let method: String?
        let status: Status?
    }

    struct Integration: Decodable {
        let id: String
        let name: String
        let methods: [Wire.Lossy<Method>]
        let connections: [Wire.Lossy<Connection>]
    }

    struct Attempt: Decodable {
        struct Time: Decodable {
            let created: JSONValue?
            let expires: JSONValue?
        }

        let attemptID: String
        let url: String
        let instructions: String?
        let mode: String?
        let paste: Bool?
        let time: Time?
    }

    struct AttemptStatus: Decodable {
        let status: String
        let message: String?
    }

    struct BillingModel: Decodable {
        let id: String
        let providerID: String
        let cost: JSONValue?
        let settings: JSONValue?
    }

    struct BillingProvider: Decodable {
        let id: String
        let integrationID: String?
    }
}

extension OpenCodeIntegration {
    init(wire: AccountsWire.Integration) {
        let methods = wire.methods.compactMap(\.value).map { method in
            Method(kind: Method.Kind(rawValue: method.type) ?? .unknown, methodID: method.id, label: method.label,
                   fields: (method.form ?? []).compactMap(\.value).map(FormField.init(wire:)), environmentNames: method.names ?? [])
        }
        let connections = wire.connections.compactMap(\.value).map { connection in
            Connection(kind: Connection.Kind(rawValue: connection.type) ?? .unknown,
                       credentialID: connection.type == "credential" ? connection.id : nil,
                       label: connection.label,
                       method: connection.method.flatMap(Method.Kind.init(rawValue:)),
                       environmentName: connection.type == "env" ? connection.name : nil,
                       needsAuth: connection.status?.status == "needs_auth",
                       statusMessage: connection.status?.message, statusURL: connection.status?.url)
        }
        self.init(id: wire.id, name: wire.name, methods: methods, connections: connections)
    }
}

extension OpenCodeIntegration.FormField {
    init(wire: AccountsWire.FormField) {
        func text(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let string): string
            case .number(let number): number.rounded() == number ? String(Int64(number)) : String(number)
            case .bool(let flag): flag ? "true" : "false"
            case .array(let items): items.compactMap(\.stringValue).joined(separator: ", ")
            default: nil
            }
        }
        self.init(key: wire.key, kind: Kind(rawValue: wire.type) ?? .unknown, title: wire.title, summary: wire.description,
                  required: wire.required ?? false, hidden: wire.hidden ?? false, placeholder: wire.placeholder,
                  defaultValue: text(wire.default),
                  options: (wire.options ?? []).map { Option(value: $0.value, label: $0.label ?? $0.value, summary: $0.description) },
                  allowsCustom: wire.custom ?? false, url: wire.url,
                  conditions: (wire.when ?? []).map { Condition(key: $0.key, equals: $0.op != "neq", value: text($0.value) ?? "") })
    }
}

extension OAuthAttempt {
    init(wire: AccountsWire.Attempt, integrationID: String) {
        var expires: Date?
        if let value = wire.time?.expires?.doubleValue, value.isFinite { expires = Date(timeIntervalSince1970: value / 1000) }
        self.init(integrationID: integrationID, attemptID: wire.attemptID, urlString: wire.url, instructions: wire.instructions ?? "",
                  mode: Mode(rawValue: wire.mode ?? "auto") ?? .auto, acceptsPaste: wire.paste ?? false, expires: expires)
    }
}

// MARK: Client calls

extension OpenCodeClient {
    /// Every integration (330+), with methods and connections. The first request for a new folder can answer before
    /// the catalogue has loaded, so an empty answer is asked again once.
    public func integrations(directory: String? = nil) async throws -> [OpenCodeIntegration] {
        let location = Self.location(directory ?? defaultDirectory)
        var response: Wire.LocationEnvelope<[Wire.Lossy<AccountsWire.Integration>]> = try await get("/api/integration", query: location)
        if response.data.isEmpty {
            try await Task.sleep(for: .milliseconds(500))
            response = try await get("/api/integration", query: location)
        }
        return response.data.compactMap(\.value).map(OpenCodeIntegration.init(wire:))
    }

    public func integration(_ integrationID: String, directory: String? = nil) async throws -> OpenCodeIntegration {
        let response: Wire.LocationEnvelope<AccountsWire.Integration> = try await get(
            "/api/integration/\(Self.pathComponent(integrationID))", query: Self.location(directory ?? defaultDirectory))
        return OpenCodeIntegration(wire: response.data)
    }

    /// Starts a browser sign-in (`integration.oauth.connect`). Open `url`, show `instructions`, then poll
    /// `oauthStatus` (mode `auto`) or send the code the browser shows to `completeOAuth` (mode `code`).
    public func startOAuth(integrationID: String, methodID: String, answer: JSONValue? = nil,
                           directory: String? = nil) async throws -> OAuthAttempt {
        var body: [String: JSONValue] = ["methodID": .string(methodID), "label": "Ensemble"]
        if let answer { body["answer"] = answer }
        let response: Wire.LocationEnvelope<AccountsWire.Attempt> = try await send(
            "POST", "/api/integration/\(Self.pathComponent(integrationID))/connect/oauth",
            query: Self.location(directory ?? defaultDirectory), body: .object(body))
        return OAuthAttempt(wire: response.data, integrationID: integrationID)
    }

    public func oauthStatus(integrationID: String, attemptID: String, directory: String? = nil) async throws -> OAuthAttemptStatus {
        let response: Wire.LocationEnvelope<AccountsWire.AttemptStatus> = try await get(
            "/api/integration/\(Self.pathComponent(integrationID))/connect/oauth/\(Self.pathComponent(attemptID))",
            query: Self.location(directory ?? defaultDirectory))
        switch response.data.status {
        case "complete": return .complete
        case "failed": return .failed(response.data.message ?? "The sign-in failed.")
        case "expired": return .expired
        default: return .pending
        }
    }

    /// Finishes a `code` sign-in with the code from the browser. For an `auto` attempt that accepts a paste, `code`
    /// is the redirect URL copied from the browser and the result arrives through `oauthStatus`.
    public func completeOAuth(integrationID: String, attemptID: String, code: String?, directory: String? = nil) async throws {
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: JSONValue = ["code": trimmed.map(JSONValue.string) ?? .null]
        try await sendIgnoringBody("POST",
                                   "/api/integration/\(Self.pathComponent(integrationID))/connect/oauth/\(Self.pathComponent(attemptID))/complete",
                                   query: Self.location(directory ?? defaultDirectory), body: body)
    }

    public func cancelOAuth(integrationID: String, attemptID: String, directory: String? = nil) async throws {
        try await sendIgnoringBody("DELETE",
                                   "/api/integration/\(Self.pathComponent(integrationID))/connect/oauth/\(Self.pathComponent(attemptID))",
                                   query: Self.location(directory ?? defaultDirectory))
    }

    /// Stores a key (`integration.connect.key`), with the key method's form answers when it has a form (Azure
    /// resource name, Cloudflare account id...). The key goes only to the engine.
    public func connectKey(integrationID: String, key: String, answer: JSONValue? = nil, directory: String? = nil) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenCodeError.invalidArgument("The key is empty.") }
        var body: [String: JSONValue] = ["key": .string(trimmed), "label": "Ensemble"]
        if let answer { body["answer"] = answer }
        try await sendIgnoringBody("POST", "/api/integration/\(Self.pathComponent(integrationID))/connect/key",
                                   query: Self.location(directory ?? defaultDirectory), body: .object(body))
    }

    /// Connects existing cloud credentials (`integration.connect.external`): an AWS profile, gcloud credentials, the
    /// claude command's own sign-in.
    public func connectExternal(integrationID: String, methodID: String, answer: JSONValue? = nil, directory: String? = nil) async throws {
        var body: [String: JSONValue] = ["methodID": .string(methodID), "label": "Ensemble"]
        if let answer { body["answer"] = answer }
        try await sendIgnoringBody("POST", "/api/integration/\(Self.pathComponent(integrationID))/connect/external",
                                   query: Self.location(directory ?? defaultDirectory), body: .object(body))
    }

    /// Stored credentials (ids and labels only; the secret values are never decoded).
    public func credentials() async throws -> [OpenCodeCredential] {
        let response: Wire.DataEnvelope<[Wire.Credential]> = try await get("/api/credential")
        return response.data.map { OpenCodeCredential(id: $0.id, integrationID: $0.integrationID, label: $0.label, active: $0.active ?? false) }
    }

    /// Removes the integration's stored credentials made by `method` (all of them when nil). An API key and a
    /// browser sign-in for the same provider are separate, so removing one keeps the other. Returns how many were
    /// removed. Environment variables cannot be removed here.
    @discardableResult
    public func removeCredentials(integrationID: String, method: OpenCodeIntegration.Method.Kind?, directory: String? = nil) async throws -> Int {
        let integration = try await integration(integrationID, directory: directory)
        let targets = integration.connections.filter { $0.kind == .credential && (method == nil || $0.method == method) }
        for credentialID in targets.compactMap(\.credentialID) {
            try await sendIgnoringBody("DELETE", "/api/credential/\(Self.pathComponent(credentialID))")
        }
        return targets.count
    }
}

// MARK: Billing

extension OpenCodeClient: EngineModelBilling {
    /// Browser sign-ins, coding plans and the Claude Agent login are subscriptions; models on a local address run on
    /// this Mac; models that cost nothing on a provider with no connection (OpenCode's free models) are free;
    /// everything else is billed to a key or cloud account.
    public func modelBilling() async throws -> [String: ModelBilling] {
        let location = Self.location(defaultDirectory)
        async let modelList: Wire.LocationEnvelope<[Wire.Lossy<AccountsWire.BillingModel>]> = get("/api/model", query: location)
        async let providerList: Wire.LocationEnvelope<[Wire.Lossy<AccountsWire.BillingProvider>]> = get("/api/provider", query: location)
        async let integrationList = integrations()
        let models = try await modelList.data.compactMap(\.value)
        let providers = Dictionary(((try? await providerList.data) ?? []).compactMap(\.value).map { ($0.id, $0.integrationID ?? $0.id) },
                                   uniquingKeysWith: { a, _ in a })
        let integrations = Dictionary(((try? await integrationList) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var map: [String: ModelBilling] = [:]
        for model in models {
            let integration = integrations[providers[model.providerID] ?? model.providerID]
            map["\(model.providerID)/\(model.id)"] = ModelBillingRules.billing(
                integrationID: integration?.id ?? model.providerID, integration: integration,
                baseURL: model.settings?["baseURL"]?.stringValue, apiKey: model.settings?["apiKey"]?.stringValue, cost: model.cost)
        }
        return map
    }
}

enum ModelBillingRules {
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    static func billing(integrationID: String, integration: OpenCodeIntegration?, baseURL: String?, apiKey: String?,
                        cost: JSONValue?) -> ModelBilling {
        if let host = baseURL.flatMap(URL.init(string:))?.host?.lowercased(), localHosts.contains(host) || host.hasSuffix(".local") {
            return .local
        }
        if integration?.isSignedIn == true { return .subscription }
        if OpenCodeIntegration.isCodingPlan(id: integrationID) || integrationID == "claude-agent" { return .subscription }
        let connected = integration?.isConnected ?? false
        if !connected, apiKey == "public" || isZero(cost) { return .free }
        return .apiKey
    }

    /// True when every price in the cost list is 0 (and there is at least one).
    static func isZero(_ cost: JSONValue?) -> Bool {
        var numbers: [Double] = []
        func collect(_ value: JSONValue) {
            switch value {
            case .number(let number): numbers.append(number)
            case .array(let items): items.forEach(collect)
            case .object(let object): object.values.forEach(collect)
            default: break
            }
        }
        if let cost { collect(cost) }
        return !numbers.isEmpty && numbers.allSatisfy { $0 == 0 }
    }
}
