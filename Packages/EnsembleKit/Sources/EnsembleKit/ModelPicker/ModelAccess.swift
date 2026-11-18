import Foundation

// How the user pays for a model they pick: their subscription or an API key (or free, or on this Mac). The picker
// lists the options of a model, remembers the one chosen, and asks for a key when the chosen option needs one.
// Nothing here reads, keeps or logs a key: keys go one way, from the entry field to the engine.

/// Where a maker's API key is saved.
public struct ModelKeyTarget: Hashable, Sendable {
    public enum Storage: String, Sendable {
        /// Ensemble's own item in the login Keychain (Claude agents on an API key).
        case keychain
        /// OpenCode's credential store, through its integration API.
        case openCode
    }

    /// What `SessionStore.setAPIKey(providerID:key:)` takes.
    public var providerID: String
    /// "Anthropic API key".
    public var title: String
    public var storage: Storage

    public init(providerID: String, title: String, storage: Storage) {
        self.providerID = providerID
        self.title = title
        self.storage = storage
    }
}

/// One way to run a model the picker offers.
public struct ModelAccessOption: Hashable, Sendable, Identifiable {
    /// `claude-code`, `claude-code-api`, `openai#oauth`, `openai#key`, `google#add-key`.
    public var id: String
    public var billing: ModelBilling
    /// "Claude subscription", "Anthropic API key", "ChatGPT sign-in".
    public var title: String
    /// The model to switch to. Nil when it is known only once the key is saved (the picker looks it up again).
    public var ref: ModelRef?
    /// The key to enter first; nil when the option is ready to use.
    public var missingKey: ModelKeyTarget?
    /// For a provider signed in both with a browser sign-in and a key: the credential to make active first.
    public var credential: OpenCodeIntegration.Method.Kind?
    /// False when the engine cannot run it now (the `claude` CLI is not signed in, for example).
    public var available: Bool

    public init(id: String, billing: ModelBilling, title: String, ref: ModelRef?, missingKey: ModelKeyTarget? = nil,
                credential: OpenCodeIntegration.Method.Kind? = nil, available: Bool = true) {
        self.id = id
        self.billing = billing
        self.title = title
        self.ref = ref
        self.missingKey = missingKey
        self.credential = credential
        self.available = available
    }

    public var isReady: Bool { available && missingKey == nil && ref != nil }
}

/// What the picker needs to know about an OpenCode provider's sign-ins. Ids and kinds only, never a secret.
public struct ModelProviderAccess: Hashable, Sendable {
    public var hasSignIn: Bool
    public var hasKey: Bool
    public var acceptsKey: Bool
    /// Which kind of credential the engine uses now, when known.
    public var activeMethod: OpenCodeIntegration.Method.Kind?

    public init(hasSignIn: Bool, hasKey: Bool, acceptsKey: Bool, activeMethod: OpenCodeIntegration.Method.Kind? = nil) {
        self.hasSignIn = hasSignIn
        self.hasKey = hasKey
        self.acceptsKey = acceptsKey
        self.activeMethod = activeMethod
    }

    public init(integration: OpenCodeIntegration, activeCredentialIDs: Set<String> = []) {
        hasSignIn = integration.isSignedIn
        hasKey = !integration.connections(method: .key).isEmpty
        acceptsKey = integration.keyMethod != nil
        activeMethod = integration.connections.first { $0.credentialID.map(activeCredentialIDs.contains) ?? false }?.method
    }

    /// Signed in with the browser and able to use a key too: the picker offers both.
    var offersBoth: Bool { hasSignIn && acceptsKey }
}

public enum ModelAccess {
    /// Where a maker's own API key goes. Claude agents run the `claude` CLI with Ensemble's Keychain key; the others
    /// run on OpenCode with a key stored by OpenCode.
    public static func keyTarget(for maker: ModelMaker) -> ModelKeyTarget? {
        switch maker.id {
        case ModelMaker.claude.id:
            return ModelKeyTarget(providerID: ClaudeModels.apiKeyProviderID, title: "Anthropic API key", storage: .keychain)
        case ModelMaker.gemini.id: return ModelKeyTarget(providerID: "google", title: "Gemini API key", storage: .openCode)
        case ModelMaker.chatGPT.id: return ModelKeyTarget(providerID: "openai", title: "OpenAI API key", storage: .openCode)
        case ModelMaker.grok.id: return ModelKeyTarget(providerID: "xai", title: "xAI API key", storage: .openCode)
        case ModelMaker.deepSeek.id: return ModelKeyTarget(providerID: "deepseek", title: "DeepSeek API key", storage: .openCode)
        case ModelMaker.qwen.id: return ModelKeyTarget(providerID: "alibaba", title: "Alibaba Cloud API key", storage: .openCode)
        case ModelMaker.kimi.id: return ModelKeyTarget(providerID: "moonshotai", title: "Moonshot AI API key", storage: .openCode)
        case ModelMaker.glm.id: return ModelKeyTarget(providerID: "zhipuai", title: "Zhipu AI API key", storage: .openCode)
        case ModelMaker.mistral.id: return ModelKeyTarget(providerID: "mistral", title: "Mistral API key", storage: .openCode)
        case ModelMaker.miniMax.id: return ModelKeyTarget(providerID: "minimax", title: "MiniMax API key", storage: .openCode)
        default: return nil
        }
    }

    /// The ways to run `choice`: one per route, both sign-in and key for a provider that takes both, and the maker's
    /// own API key (to be entered) when no option bills a key yet. `providers` are the engines' providers (the maker's
    /// key is offered only when its provider is among them); `access` is OpenCode's sign-in state by provider id.
    public static func options(for choice: ModelChoice, providers: [ProviderInfo],
                               access: [String: ModelProviderAccess] = [:]) -> [ModelAccessOption] {
        var options: [ModelAccessOption] = []
        for route in choice.routes {
            let provider = route.ref.providerID
            if let state = access[provider], state.offersBoth {
                let target = ModelKeyTarget(providerID: provider, title: keyTitle(provider, name: route.providerName), storage: .openCode)
                options.append(ModelAccessOption(id: "\(provider)#oauth", billing: .subscription,
                                                 title: signInTitle(provider, name: route.providerName), ref: route.ref,
                                                 credential: state.hasKey ? .oauth : nil, available: route.available))
                options.append(ModelAccessOption(id: "\(provider)#key", billing: .apiKey, title: target.title, ref: route.ref,
                                                 missingKey: state.hasKey ? nil : target, credential: .key))
            } else {
                options.append(ModelAccessOption(id: provider, billing: route.billing, title: title(route), ref: route.ref,
                                                 available: route.available))
            }
        }
        if !options.contains(where: { $0.billing == .apiKey }), let target = keyTarget(for: choice.maker),
           let provider = providers.first(where: { $0.id == target.providerID }) {
            if target.providerID == ClaudeModels.apiKeyProviderID {
                // Same CLI and model ids on the key: the model is known before the key is saved.
                if let subscription = choice.routes.first(where: { $0.ref.providerID == ClaudeModels.subscriptionProviderID }) {
                    options.append(ModelAccessOption(
                        id: target.providerID, billing: .apiKey, title: target.title,
                        ref: ModelRef(providerID: target.providerID, id: subscription.ref.id),
                        missingKey: provider.connected ? nil : target))
                }
            } else if !provider.connected {
                // With the key saved, OpenCode lists the provider's models and the picker finds this one among them.
                options.append(ModelAccessOption(id: "\(target.providerID)#add-key", billing: .apiKey, title: target.title,
                                                 ref: nil, missingKey: target))
            }
        }
        return options
    }

    /// The option the session uses now: the one whose model is `ref` (and, for a provider signed in both ways, whose
    /// credential is the active one).
    public static func current(_ options: [ModelAccessOption], ref: ModelRef?,
                               access: [String: ModelProviderAccess] = [:]) -> ModelAccessOption? {
        guard let ref else { return nil }
        let matching = options.filter { option in
            guard let model = option.ref, option.missingKey == nil else { return false }
            return model.providerID == ref.providerID && ModelCatalog.baseID(model.id) == ModelCatalog.baseID(ref.id)
        }
        if matching.count > 1, let active = access[ref.providerID]?.activeMethod,
           let match = matching.first(where: { $0.credential == active }) {
            return match
        }
        return matching.first
    }

    /// The option a click uses without asking: the remembered one while it is still ready, else the only option.
    /// Nil means the picker shows the options.
    public static func automatic(_ options: [ModelAccessOption], remembered: String?) -> ModelAccessOption? {
        if let remembered, let option = options.first(where: { $0.id == remembered }), option.isReady { return option }
        return options.count == 1 && options[0].isReady ? options[0] : nil
    }

    // MARK: Titles

    static func title(_ route: ModelRoute) -> String {
        let provider = route.ref.providerID
        switch provider {
        case ClaudeModels.subscriptionProviderID: return "Claude subscription"
        case ClaudeModels.apiKeyProviderID: return "Anthropic API key"
        case "antigravity": return "Google AI subscription"
        default: break
        }
        switch route.billing {
        case .subscription: return route.providerName
        case .apiKey: return keyTitle(provider, name: route.providerName)
        case .free: return "Free with \(route.providerName)"
        case .local: return "\(route.providerName) on this Mac"
        }
    }

    static func signInTitle(_ provider: String, name: String) -> String {
        switch provider {
        case "openai": "ChatGPT sign-in"
        case "xai": "SuperGrok sign-in"
        default: "\(name) sign-in"
        }
    }

    static func keyTitle(_ provider: String, name: String) -> String {
        switch provider {
        case "anthropic": return "Anthropic API key"
        case "openai": return "OpenAI API key"
        case "google": return "Gemini API key"
        case "xai": return "xAI API key"
        default: return name.localizedCaseInsensitiveContains("api key") ? name : "\(name) API key"
        }
    }
}

// MARK: OpenCode sign-in state for the picker

extension OpenCodeClient {
    /// Sign-in state of every provider that has at least one connection. The credential list (which one is active) is
    /// read only when a provider is signed in both ways; its secret values are never decoded.
    public func modelProviderAccess() async throws -> [String: ModelProviderAccess] {
        let connected = try await integrations().filter(\.isConnected)
        var activeIDs = Set<String>()
        if connected.contains(where: { $0.isSignedIn && !$0.connections(method: .key).isEmpty }) {
            activeIDs = Set(try await credentials().filter(\.active).map(\.id))
        }
        return Dictionary(connected.map { ($0.id, ModelProviderAccess(integration: $0, activeCredentialIDs: activeIDs)) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Makes the provider's credential of `method` the one the engine uses (`credential.activate`), for a provider
    /// signed in with both a browser sign-in and a key.
    public func activateCredential(integrationID: String, method: OpenCodeIntegration.Method.Kind) async throws {
        let integration = try await integration(integrationID)
        guard let credentialID = integration.connections(method: method).first?.credentialID else {
            throw OpenCodeError.invalidArgument("No \(method == .key ? "API key" : "sign-in") is saved for \(integration.name).")
        }
        try await sendIgnoringBody("POST", "/api/credential/\(Self.pathComponent(credentialID))/activate")
    }
}
