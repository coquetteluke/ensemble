import Foundation
import Testing
@testable import EnsembleKit

/// The model picker's folders and payment options, from model lists shaped like the real engines' (the Claude CLI's
/// `initialize` models of 2.1.319, `agy acp` 1.5.10's config options, OpenCode 2.3's free models, and API models).
@Suite struct ModelCatalogTests {
    static func info(_ provider: String, _ id: String, _ name: String, providerName: String = "", context: Int? = nil,
                     available: Bool = true) -> ModelInfo {
        ModelInfo(ref: ModelRef(providerID: provider, id: id), name: name, providerName: providerName.isEmpty ? provider : providerName,
                  contextLimit: context, available: available)
    }

    /// The Claude CLI's list, in its order.
    static let claudeCLI: [ModelInfo] = [
        ("default", "Opus 5.5"), ("opus", "Opus 5.5"), ("claude-fable-5-2", "Fable 5.2"), ("sonnet", "Sonnet 5.5"),
        ("haiku", "Haiku 5.5"), ("fable", "Fable 5.1"), ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("claude-sonnet-5", "Sonnet 5"),
        ("claude-opus-5", "Opus 5"), ("claude-fable-5", "Fable 5"), ("claude-opus-4-8", "Opus 4.8"), ("claude-opus-4-7", "Opus 4.7"),
        ("claude-opus-4-6", "Opus 4.6"), ("claude-sonnet-4-6", "Sonnet 4.6"),
    ].map { info("claude-code", $0.0, $0.1, providerName: "Claude (your subscription)", context: 1_000_000) }

    /// `agy acp`'s model option.
    static let antigravity: [ModelInfo] = [
        ("gemini-4-carbon", "Gemini 4 Carbon"), ("gemini-4-argon", "Gemini 4 Argon"), ("gemini-4-hydrogen", "Gemini 4 Hydrogen"),
        ("gemini-pro-orchestrator", "Orchestrator (Carbon)"), ("gemini-pro-orchestrator-argon", "Orchestrator (Argon)"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash"), ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Thinking)"),
        ("claude-opus-4-6-thinking", "Claude Opus 4.6 (Thinking)"), ("gpt-oss-120b-medium", "GPT-OSS 120B (Medium)"),
    ].map { info("antigravity", $0.0, $0.1, providerName: "Gemini (your Google AI subscription)") }

    static let openCodeFree: [ModelInfo] = [
        ("big-pickle", "Big Pickle"), ("deepseek-v4.1-flash-free", "DeepSeek V4.1 Flash Free"), ("hy4-flash-free", "Hy4 flash Free"),
        ("nemotron-3.5-super-vl-free", "Nemotron 3.5 Super VL Free"), ("nemotron-3.5-lightning-free", "Nemotron 3.5 Lightning Free"),
    ].map { info("opencode", $0.0, $0.1, providerName: "OpenCode Zen") }

    static let apiModels: [ModelInfo] = [
        info("openai", "gpt-5.5", "GPT-5.5", providerName: "OpenAI"),
        info("openai", "gpt-5.5-mini", "GPT-5.5 mini", providerName: "OpenAI"),
        info("openai", "gpt-4.1", "GPT-4.1", providerName: "OpenAI"),
        info("openai", "o3", "o3", providerName: "OpenAI"),
        info("xai", "grok-5", "Grok 5", providerName: "xAI"),
        info("xai", "grok-code-fast-1", "Grok Code Fast 1", providerName: "xAI"),
        info("google", "gemini-2.5-pro", "Gemini 2.5 Pro", providerName: "Google"),
        info("anthropic", "claude-opus-5-5", "Claude Opus 5.5", providerName: "Anthropic"),
        info("deepseek", "deepseek-v4.1-flash", "DeepSeek V4.1 Flash", providerName: "DeepSeek"),
        info("ollama", "llama3.3:70b", "Llama 3.3 70B", providerName: "Ollama"),
    ]

    static let billing: [String: ModelBilling] = [
        "claude-code": .subscription, "claude-code-api": .apiKey, "antigravity": .subscription,
        "opencode": .free, "openai": .subscription, "ollama": .local,
    ]

    static var everything: [ModelInfo] { claudeCLI + antigravity + openCodeFree + apiModels }

    private func folder(_ id: String, _ folders: [ModelFolder]) -> ModelFolder? { folders.first { $0.id == id } }

    // MARK: Reading ids

    @Test func readsMakerTierAndVersionFromIDs() {
        func identity(_ provider: String, _ id: String, _ name: String = "") -> ModelIdentity {
            ModelCatalog.identity(of: Self.info(provider, id, name.isEmpty ? id : name))
        }
        let sonnet = identity("anthropic", "claude-3-5-sonnet-20241022")
        #expect(sonnet.maker == .claude && sonnet.tier == "sonnet" && sonnet.version == [3, 5])
        let haiku = identity("claude-code", "claude-haiku-4-5-20251001", "Haiku 4.5")
        #expect(haiku.tier == "haiku" && haiku.version == [4, 5])
        let alias = identity("claude-code", "opus", "Opus 5.5")
        #expect(alias.maker == .claude && alias.tier == "opus" && alias.version == [5, 5] && alias.name == "Opus 5.5")
        let defaultModel = identity("claude-code", "default", "Opus 5.5")
        #expect(defaultModel.tier == "opus" && defaultModel.version == [5, 5])
        let routed = identity("openrouter", "anthropic/claude-opus-5.5", "Anthropic: Claude Opus 5.5")
        #expect(routed.maker == .claude && routed.tier == "opus" && routed.version == [5, 5])
        let gpt = identity("openai", "gpt-4o-2024-08-06")
        #expect(gpt.maker == .chatGPT && gpt.version == [4])
        let qwen = identity("openrouter", "qwen/qwen3-coder-480b-a35b-instruct")
        #expect(qwen.maker == .qwen && qwen.version == [3] && qwen.tier == "coder-480b-a35b-instruct")
        let kimi = identity("moonshotai", "kimi-k2.5")
        #expect(kimi.maker == .kimi && kimi.version == [2, 5])
        let grok = identity("xai", "grok-code-fast-1")
        #expect(grok.maker == .grok && grok.tier == "code-fast" && grok.version == [1])
        let deepseek = identity("opencode", "deepseek-v4.1-flash-free", "DeepSeek V4.1 Flash Free")
        #expect(deepseek.maker == .deepSeek && deepseek.tier == "flash" && deepseek.version == [4, 1])
        #expect(deepseek.name == "DeepSeek V4.1 Flash" && deepseek.tagged)
        let lite = identity("google", "gemini-2.5-flash-lite")
        #expect(lite.maker == .gemini && lite.tier == "flash-lite" && lite.version == [2, 5])
        let effort = identity("antigravity", "gemini-4-carbon-medium", "Gemini 4 Carbon (Medium)")
        #expect(effort.tier == "carbon" && effort.version == [4] && effort.name == "Gemini 4 Carbon")
        // An effort word that is part of the model's name stays.
        let codexMax = identity("openai", "gpt-5.1-codex-max", "GPT-5.1 Codex Max")
        #expect(codexMax.tier == "codex-max")
        let thinking = identity("antigravity", "claude-opus-4-6-thinking", "Claude Opus 4.6 (Thinking)")
        #expect(thinking.maker == .claude && thinking.tier == "opus" && thinking.version == [4, 6] && thinking.name == "Opus 4.6")
        let unknown = identity("opencode", "big-pickle", "Big Pickle")
        #expect(unknown.maker == nil && unknown.tier == "big-pickle")
        let oss = identity("antigravity", "gpt-oss-120b-medium", "GPT-OSS 120B (Medium)")
        #expect(oss.maker == .chatGPT && oss.tier == "oss-120b" && oss.version.isEmpty)
    }

    // MARK: Folders

    @Test func foldersFollowTheMakersInOrder() {
        let folders = ModelCatalog.folders(Self.everything, billing: Self.billing)
        #expect(folders.map(\.id) == ["claude", "gemini", "chatgpt", "grok", "deepseek", "free", "local"])
        #expect(folders.map(\.maker.name) == ["Claude", "Gemini", "ChatGPT", "Grok", "DeepSeek", "Free", "On this Mac"])
    }

    @Test func claudeShowsTheNewestOfEachTierOnceThenOlderModels() throws {
        let folders = ModelCatalog.folders(Self.everything, billing: Self.billing)
        let claude = try #require(folder("claude", folders))
        #expect(claude.current.map(\.name) == ["Fable 5.2", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        #expect(claude.older.map(\.name) == ["Fable 5.1", "Fable 5", "Opus 5", "Opus 4.8", "Opus 4.7", "Opus 4.6", "Sonnet 5",
                                             "Sonnet 4.6", "Haiku 4.5"])
        // `default` folds into Opus 5.5; the alias is the route used.
        let opus = claude.current[1]
        #expect(opus.contains(ModelRef(providerID: "claude-code", id: "default")))
        #expect(opus.contains(ModelRef(providerID: "claude-code", id: "opus", variant: "high")))
        #expect(opus.contains(ModelRef(providerID: "claude-code", id: "opus[1m]")))
        #expect(opus.routes.map(\.ref.description) == ["claude-code/opus", "anthropic/claude-opus-5-5"])
        #expect(opus.routes.map(\.billing) == [.subscription, .apiKey])
        #expect(opus.contextLimit == 1_000_000)
        #expect(opus.id == "claude|opus|5.5")
        // The same Claude model through Google's plan is one entry with two subscriptions.
        let sonnet46 = try #require(claude.older.first { $0.name == "Sonnet 4.6" })
        #expect(sonnet46.routes.map(\.ref.providerID) == ["claude-code", "antigravity"])
        #expect(!folders.contains { $0.id == "other" })
    }

    @Test func geminiAndOtherMakersKeepEngineOrderForTheirOwnTiers() throws {
        let folders = ModelCatalog.folders(Self.everything, billing: Self.billing)
        let gemini = try #require(folder("gemini", folders))
        #expect(gemini.current.map(\.name) == ["Gemini 4 Carbon", "Gemini 4 Argon", "Gemini 4 Hydrogen", "Orchestrator (Carbon)",
                                               "Orchestrator (Argon)", "Gemini 3.8 Flash"])
        // Two major versions behind the newest Gemini: older, although it is the newest Pro on the API.
        #expect(gemini.older.map(\.name) == ["Gemini 2.5 Pro"])

        let chatGPT = try #require(folder("chatgpt", folders))
        #expect(chatGPT.current.map(\.name) == ["GPT-OSS 120B", "GPT-5.5", "GPT-5.5 mini"])
        #expect(Set(chatGPT.older.map(\.name)) == ["GPT-4.1", "o3"])

        let grok = try #require(folder("grok", folders))
        #expect(grok.current.map(\.name) == ["Grok 5", "Grok Code Fast 1"])

        // The free DeepSeek model is the same model as the API one: one entry, free first.
        let deepSeek = try #require(folder("deepseek", folders))
        #expect(deepSeek.all.map(\.name) == ["DeepSeek V4.1 Flash"])
        #expect(deepSeek.all[0].routes.map(\.billing) == [.free, .apiKey])

        let free = try #require(folder("free", folders))
        #expect(free.current.map(\.name) == ["Big Pickle", "Hy4 flash", "Nemotron 3.5 Super VL", "Nemotron 3.5 Lightning"])
        #expect(free.older.isEmpty)

        let local = try #require(folder("local", folders))
        #expect(local.all.map(\.name) == ["Llama 3.3 70B"])
    }

    @Test func effortVariantsOfOneModelAreOneEntry() throws {
        let models = [("gemini-4-carbon-medium", "Gemini 4 Carbon (Medium)"), ("gemini-4-carbon-high", "Gemini 4 Carbon (High)"),
                      ("gemini-4-carbon-low", "Gemini 4 Carbon (Low)"), ("gemini-3.8-flash-high", "Gemini 3.8 Flash (High)")]
            .map { Self.info("antigravity", $0.0, $0.1) }
        let gemini = try #require(ModelCatalog.folders(models, billing: nil).first)
        #expect(gemini.current.map(\.name) == ["Gemini 4 Carbon", "Gemini 3.8 Flash"])
        #expect(gemini.current[0].routes.count == 1)
        #expect(gemini.current[0].refs.count == 3)
        #expect(gemini.current[0].contains(ModelRef(providerID: "antigravity", id: "gemini-4-carbon-low")))
    }

    @Test func lookupsAndSearch() throws {
        let folders = ModelCatalog.folders(Self.everything, billing: Self.billing)
        #expect(ModelCatalog.folder(for: ModelRef(providerID: "claude-code", id: "sonnet"), in: folders)?.id == "claude")
        #expect(ModelCatalog.choice(for: ModelRef(providerID: "antigravity", id: "gemini-3.8-flash"), in: folders)?.name == "Gemini 3.8 Flash")
        #expect(ModelCatalog.choice(for: ModelRef(providerID: "nowhere", id: "x"), in: folders) == nil)
        #expect(ModelCatalog.search("sonnet 4.6", in: folders).map(\.name) == ["Sonnet 4.6"])
        #expect(ModelCatalog.search("GOOGLE AI", in: folders).count == 9)
        #expect(ModelCatalog.search("fable", in: folders).map(\.name) == ["Fable 5.2", "Fable 5.1", "Fable 5"])
        #expect(ModelCatalog.search("  ", in: folders).isEmpty)
    }

    @Test func freeAndLocalModelsStayInTheirFolders() throws {
        let folders = ModelCatalog.folders(Self.everything, billing: Self.billing)
        // A maker's model opens its own folder at the top.
        #expect(ModelCatalog.topFolder(for: ModelRef(providerID: "claude-code", id: "sonnet"), in: folders)?.id == "claude")
        // A free or local model keeps its folder closed; the first maker's folder is on top instead.
        #expect(ModelCatalog.folder(for: ModelRef(providerID: "opencode", id: "big-pickle"), in: folders)?.id == "free")
        #expect(ModelCatalog.topFolder(for: ModelRef(providerID: "opencode", id: "big-pickle"), in: folders)?.id == "claude")
        #expect(ModelCatalog.topFolder(for: ModelRef(providerID: "ollama", id: "llama3.3:70b"), in: folders)?.id == "claude")
        #expect(ModelCatalog.topFolder(for: nil, in: folders)?.id == "claude")
        // With only free models there is nothing else to show, so the Free folder is on top.
        let onlyFree = ModelCatalog.folders(Array(Self.openCodeFree.prefix(1)), billing: Self.billing)
        #expect(onlyFree.map(\.id) == ["free"])
        #expect(ModelCatalog.topFolder(for: nil, in: onlyFree)?.id == "free")
    }

    @Test func withoutBillingClaudeAndGoogleAreSubscriptions() throws {
        let folders = ModelCatalog.folders(Self.claudeCLI + [Self.info("claude-code-api", "opus", "Opus 5.5")], billing: nil)
        let opus = try #require(folders.first?.current.first { $0.tier == "opus" })
        #expect(opus.routes.map(\.billing) == [.subscription, .apiKey])
        #expect(opus.primary?.ref.providerID == "claude-code")
    }

    // MARK: Paying

    @Test func claudeOffersTheSubscriptionAndAnAPIKeyToEnter() throws {
        let folders = ModelCatalog.folders(Self.claudeCLI, billing: Self.billing)
        let opus = try #require(folders.first?.current.first { $0.tier == "opus" })
        let providers = [ProviderInfo(id: "claude-code", name: "Claude (your subscription)", connected: true),
                         ProviderInfo(id: "claude-code-api", name: "Claude (API key)", connected: false)]
        let options = ModelAccess.options(for: opus, providers: providers)
        #expect(options.map(\.title) == ["Claude subscription", "Anthropic API key"])
        #expect(options[0].isReady && options[0].ref == ModelRef(providerID: "claude-code", id: "opus"))
        #expect(options[1].missingKey == ModelKeyTarget(providerID: "claude-code-api", title: "Anthropic API key", storage: .keychain))
        #expect(options[1].ref == ModelRef(providerID: "claude-code-api", id: "opus"))
        #expect(ModelAccess.automatic(options, remembered: nil) == nil)
        #expect(ModelAccess.automatic(options, remembered: "claude-code")?.id == "claude-code")
        // A remembered option that still needs its key is not used without asking.
        #expect(ModelAccess.automatic(options, remembered: "claude-code-api") == nil)

        // With the key saved, the engine lists the API models too: both options are ready.
        let withKey = ModelCatalog.folders(Self.claudeCLI + [Self.info("claude-code-api", "opus", "Opus 5.5")], billing: Self.billing)
        let opusWithKey = try #require(withKey.first?.current.first { $0.tier == "opus" })
        let ready = ModelAccess.options(for: opusWithKey, providers: providers)
        #expect(ready.map(\.id) == ["claude-code", "claude-code-api"])
        #expect(ready.allSatisfy { $0.isReady })
        #expect(ModelAccess.current(ready, ref: ModelRef(providerID: "claude-code-api", id: "opus", variant: "max"))?.id == "claude-code-api")
    }

    @Test func chatGPTSignInAndOpenAIKeyAreTwoOptionsOfOneProvider() throws {
        let gpt = try #require(ModelCatalog.folders([Self.info("openai", "gpt-5.5", "GPT-5.5", providerName: "OpenAI")],
                                                    billing: ["openai": .subscription]).first?.current.first)
        let providers = [ProviderInfo(id: "openai", name: "OpenAI", connected: true)]
        let signedIn = ["openai": ModelProviderAccess(hasSignIn: true, hasKey: false, acceptsKey: true)]
        let options = ModelAccess.options(for: gpt, providers: providers, access: signedIn)
        #expect(options.map(\.title) == ["ChatGPT sign-in", "OpenAI API key"])
        #expect(options[0].credential == nil && options[0].isReady)
        #expect(options[1].missingKey?.providerID == "openai" && options[1].credential == .key)

        let both = ["openai": ModelProviderAccess(hasSignIn: true, hasKey: true, acceptsKey: true, activeMethod: .key)]
        let ready = ModelAccess.options(for: gpt, providers: providers, access: both)
        #expect(ready.map(\.credential) == [.oauth, .key])
        #expect(ready.allSatisfy { $0.isReady })
        #expect(ModelAccess.current(ready, ref: gpt.routes[0].ref, access: both)?.id == "openai#key")
    }

    @Test func geminiOnTheGooglePlanOffersAGeminiKeyToAdd() throws {
        let folders = ModelCatalog.folders(Self.antigravity, billing: Self.billing)
        let carbon = try #require(folder("gemini", folders)?.current.first)
        let providers = [ProviderInfo(id: "antigravity", name: "Gemini (your Google AI subscription)", connected: true),
                         ProviderInfo(id: "google", name: "Google", connected: false)]
        let options = ModelAccess.options(for: carbon, providers: providers)
        #expect(options.map(\.title) == ["Google AI subscription", "Gemini API key"])
        #expect(options[1].ref == nil && options[1].missingKey?.storage == .openCode)
        // Once a Google key is saved, a model the API does not list gets no key option.
        let connected = [providers[0], ProviderInfo(id: "google", name: "Google", connected: true)]
        #expect(ModelAccess.options(for: carbon, providers: connected).map(\.id) == ["antigravity"])
        // Without the provider at all, nothing is offered beyond the subscription.
        #expect(ModelAccess.options(for: carbon, providers: [providers[0]]).count == 1)
        #expect(ModelAccess.automatic(ModelAccess.options(for: carbon, providers: [providers[0]]), remembered: nil)?.id == "antigravity")
    }

    @Test func providerAccessComesFromConnectionsWithoutSecrets() {
        let integration = OpenCodeIntegration(
            id: "openai", name: "OpenAI",
            methods: [.init(kind: .key), .init(kind: .oauth, methodID: "chatgpt", label: "Sign in with ChatGPT")],
            connections: [.init(kind: .credential, credentialID: "crd_oauth", method: .oauth),
                          .init(kind: .credential, credentialID: "crd_key", method: .key)])
        let access = ModelProviderAccess(integration: integration, activeCredentialIDs: ["crd_oauth"])
        #expect(access == ModelProviderAccess(hasSignIn: true, hasKey: true, acceptsKey: true, activeMethod: .oauth))
    }

    @Test func singlePickersDeduplicateOpusAndResolveAliases() throws {
        let folders = ModelCatalog.folders(Self.everything, billing: Self.billing)
        let allChoices = folders.flatMap(\.all)
        let opusChoices = allChoices.filter { $0.tier == "opus" && $0.version == [5, 5] }
        #expect(opusChoices.count == 1)
        let opus = try #require(opusChoices.first)
        // `claude-code/default` resolves to the canonical `claude-code/opus` subscription route.
        #expect(ModelCatalog.resolvedRef(for: ModelRef(providerID: "claude-code", id: "default"), in: folders)
                == ModelRef(providerID: "claude-code", id: "opus"))
        // Choosing an alternate available provider keeps that route selected.
        #expect(ModelCatalog.resolvedRef(for: ModelRef(providerID: "anthropic", id: "claude-opus-5-5"), in: folders)
                == ModelRef(providerID: "anthropic", id: "claude-opus-5-5"))
        #expect(ModelCatalog.pickerRoute(for: opus, selected: nil)?.ref == ModelRef(providerID: "claude-code", id: "opus"))
        // An unavailable selected route falls back to the ready primary route.
        let withUnavailableAPI = ModelCatalog.folders(
            Self.claudeCLI + [Self.info("anthropic", "claude-opus-5-5", "Claude Opus 5.5", available: false)],
            billing: Self.billing
        )
        let resolvedFallback = ModelCatalog.resolvedRef(
            for: ModelRef(providerID: "anthropic", id: "claude-opus-5-5"),
            in: withUnavailableAPI
        )
        #expect(resolvedFallback == ModelRef(providerID: "claude-code", id: "opus"))
    }
}
