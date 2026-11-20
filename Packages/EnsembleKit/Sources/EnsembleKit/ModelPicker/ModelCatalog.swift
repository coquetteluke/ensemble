import Foundation

// The model picker's folders: who makes each model, its tier, how new it is, and every way to run it. Decided from
// model ids, names and the engines' billing alone, so the rules are tested without an engine.

/// Who makes a model. Each maker is one folder in the model picker.
public struct ModelMaker: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Tiers from most to least capable. Tiers not listed come first, in the order the engines list them.
    let tierRank: [String]
    /// Words in model ids that name the maker and are dropped from the tier ("claude", "gemini", "gpt").
    let brandWords: [String]
    /// Words that name the maker and are the tier ("opus", "codestral").
    let tierWords: [String]
    /// Providers whose models are this maker's when no word in the id names a maker.
    let providers: [String]
    /// For makers that number every tier together (Claude 5.5 Opus and Sonnet): a tier whose newest model is more
    /// than this many major versions behind the maker's newest model is listed under Older models. Nil turns it off.
    let generationTolerance: Int?

    public static func == (a: ModelMaker, b: ModelMaker) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let claude = ModelMaker(
        id: "claude", name: "Claude", tierRank: ["fable", "opus", "sonnet", "haiku"], brandWords: ["claude"],
        tierWords: ["fable", "opus", "sonnet", "haiku"], providers: ["anthropic", "claude-code", "claude-code-api"],
        generationTolerance: 0)
    public static let gemini = ModelMaker(
        id: "gemini", name: "Gemini", tierRank: ["ultra", "pro", "flash", "flash-lite", "nano"], brandWords: ["gemini"],
        tierWords: ["gemma"], providers: ["google", "google-vertex", "antigravity"], generationTolerance: 1)
    public static let chatGPT = ModelMaker(
        id: "chatgpt", name: "ChatGPT", tierRank: ["pro", "gpt", "codex", "mini", "nano"], brandWords: ["gpt", "chatgpt"],
        tierWords: ["codex"], providers: ["openai", "azure"], generationTolerance: 0)
    public static let grok = ModelMaker(
        id: "grok", name: "Grok", tierRank: [], brandWords: ["grok"], tierWords: [], providers: ["xai"], generationTolerance: nil)
    public static let deepSeek = ModelMaker(
        id: "deepseek", name: "DeepSeek", tierRank: [], brandWords: ["deepseek"], tierWords: [], providers: ["deepseek"],
        generationTolerance: nil)
    public static let qwen = ModelMaker(
        id: "qwen", name: "Qwen", tierRank: [], brandWords: ["qwen"], tierWords: ["qwq"], providers: ["alibaba", "alibaba-cn"],
        generationTolerance: nil)
    public static let kimi = ModelMaker(
        id: "kimi", name: "Kimi", tierRank: [], brandWords: ["kimi", "moonshot"], tierWords: [],
        providers: ["moonshotai", "moonshotai-cn"], generationTolerance: nil)
    public static let glm = ModelMaker(
        id: "glm", name: "GLM", tierRank: [], brandWords: ["glm", "zhipu"], tierWords: [], providers: ["zhipuai", "zai"],
        generationTolerance: nil)
    public static let mistral = ModelMaker(
        id: "mistral", name: "Mistral", tierRank: [], brandWords: ["mistral"],
        tierWords: ["codestral", "devstral", "magistral", "ministral", "pixtral"], providers: ["mistral"], generationTolerance: nil)
    public static let meta = ModelMaker(
        id: "meta", name: "Meta", tierRank: [], brandWords: ["llama", "meta"], tierWords: [], providers: ["meta"],
        generationTolerance: nil)
    public static let miniMax = ModelMaker(
        id: "minimax", name: "MiniMax", tierRank: [], brandWords: ["minimax"], tierWords: [], providers: ["minimax", "minimax-cn"],
        generationTolerance: nil)
    /// Free models from makers not listed above (OpenCode's own free models).
    public static let free = ModelMaker(
        id: "free", name: "Free", tierRank: [], brandWords: [], tierWords: [], providers: [], generationTolerance: nil)
    /// Models running on this Mac (LM Studio, Ollama).
    public static let local = ModelMaker(
        id: "local", name: "On this Mac", tierRank: [], brandWords: [], tierWords: [], providers: [], generationTolerance: nil)
    public static let other = ModelMaker(
        id: "other", name: "Other", tierRank: [], brandWords: [], tierWords: [], providers: [], generationTolerance: nil)

    /// Makers recognised by name, in folder order.
    public static let known: [ModelMaker] = [claude, gemini, chatGPT, grok, deepSeek, qwen, kimi, glm, mistral, meta, miniMax]
    /// Every folder, in order.
    public static let all: [ModelMaker] = known + [free, local, other]
}

/// One way to run a model: a provider of one engine, and who pays.
public struct ModelRoute: Hashable, Sendable, Identifiable {
    public var ref: ModelRef
    public var billing: ModelBilling
    public var providerName: String
    public var available: Bool
    public var contextLimit: Int?
    public var id: String { ref.providerID }

    public init(ref: ModelRef, billing: ModelBilling, providerName: String, available: Bool = true, contextLimit: Int? = nil) {
        self.ref = ref
        self.billing = billing
        self.providerName = providerName
        self.available = available
        self.contextLimit = contextLimit
    }
}

/// One model as the picker shows it, with every engine and provider that runs it.
public struct ModelChoice: Hashable, Sendable, Identifiable {
    /// Stable across launches: maker, tier and version (`claude|opus|5.5`).
    public var id: String
    public var name: String
    public var maker: ModelMaker
    public var tier: String
    public var version: [Int]
    /// One per provider: subscriptions first, then free, on this Mac, API keys.
    public var routes: [ModelRoute]
    /// Every model id that names this model, including other ids of the same provider (`claude-code/default`).
    public var refs: [ModelRef]
    public var contextLimit: Int?

    public var available: Bool { routes.contains(where: \.available) }
    /// The route used when nothing else is chosen: the first available one.
    public var primary: ModelRoute? { routes.first(where: \.available) ?? routes.first }

    /// True when `ref` names this model (the variant and a `[1m]` suffix are ignored).
    public func contains(_ ref: ModelRef?) -> Bool {
        guard let ref else { return false }
        let id = ModelCatalog.baseID(ref.id)
        return refs.contains { $0.providerID == ref.providerID && ModelCatalog.baseID($0.id) == id }
    }

    /// The route of `ref`'s provider.
    public func route(for ref: ModelRef?) -> ModelRoute? {
        guard let ref, contains(ref) else { return nil }
        return routes.first { $0.ref.providerID == ref.providerID }
    }
}

/// A maker's models: the newest of each tier, then the rest under Older models.
public struct ModelFolder: Hashable, Sendable, Identifiable {
    public var maker: ModelMaker
    public var current: [ModelChoice]
    public var older: [ModelChoice]
    public var id: String { maker.id }
    public var all: [ModelChoice] { current + older }
}

/// What the rules read from one model id and name.
public struct ModelIdentity: Hashable, Sendable {
    /// Nil when no maker is recognised.
    public var maker: ModelMaker?
    public var tier: String
    public var version: [Int]
    /// The name without engine tags ("(Thinking)", "(Medium)", "Free") and, for Claude, without "Claude ".
    public var name: String
    /// True when the id or name carried a tag that is not part of the model (an effort level, "latest", "free").
    public var tagged: Bool
}

public enum ModelCatalog {
    /// Words that tag an id without naming a different model.
    static let dropWords: Set<String> = ["latest", "preview", "exp", "experimental", "free", "thinking", "beta"]
    /// Effort words some engines add to ids ("gemini-4-carbon-medium" for "Gemini 4 Carbon (Medium)").
    static let effortWords: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// The id without the `[1m]` suffix Claude ids may carry.
    static func baseID(_ id: String) -> String {
        id.lowercased().hasSuffix("[1m]") ? String(id.dropLast(4)) : id
    }

    // MARK: Reading an id

    /// Maker, tier and version of one model.
    public static func identity(of model: ModelInfo) -> ModelIdentity {
        var raw = baseID(model.ref.id).lowercased()
        if let slash = raw.lastIndex(of: "/") { raw = String(raw[raw.index(after: slash)...]) }
        var tagged = false
        if let colon = raw.firstIndex(of: ":") {
            raw = String(raw[..<colon])
            tagged = true
        }
        let nameTags = parenthesized(model.name)
        var tokens = expand(raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init))
        // An effort word at the end is a tag when the name shows it in parentheses ("Gemini 4 Carbon (Medium)").
        if let last = tokens.last, effortWords.contains(last), nameTags.contains(last) {
            tokens.removeLast()
            tagged = true
        }
        if tokens.contains(where: { dropWords.contains($0) }) || nameTags.contains(where: { dropWords.contains($0) || effortWords.contains($0) }) {
            tagged = true
        }
        tokens.removeAll { dropWords.contains($0) }

        var parsed = parse(tokens, providerID: model.ref.providerID)
        if parsed.version.isEmpty {
            // CLI aliases carry no version (`opus`, `default`); their names do ("Opus 5.5").
            var nameText = model.name.lowercased()
            for tag in nameTags { nameText = nameText.replacingOccurrences(of: "(\(tag))", with: " ") }
            let nameTokens = expand(nameText.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init))
                .filter { !dropWords.contains($0) }
            let fromName = parse(nameTokens, providerID: model.ref.providerID)
            if !fromName.version.isEmpty, fromName.maker == parsed.maker || parsed.maker == nil,
               fromName.tier == parsed.tier || tokens.count == 1 {
                parsed = fromName
            }
        }
        let tier = parsed.tier.isEmpty ? raw : parsed.tier
        return ModelIdentity(maker: parsed.maker, tier: tier, version: parsed.version,
                             name: displayName(model.name, maker: parsed.maker), tagged: tagged)
    }

    /// Maker, tier and version from an id's or a name's words.
    static func parse(_ tokens: [String], providerID: String) -> (maker: ModelMaker?, tier: String, version: [Int]) {
        let maker = maker(tokens: tokens, providerID: providerID)
        var version: [Int] = []
        var tierTokens: [String] = []
        var index = 0
        var versionDone = false
        while index < tokens.count {
            let token = tokens[index]
            if isDate(token) {
                // A date stamp (`20251001`, `2024-08-06`, `2411`): skipped with the parts that follow it.
                index += 1
                if token.count == 4, token.hasPrefix("20") {
                    while index < tokens.count, tokens[index].count == 2, Int(tokens[index]) != nil { index += 1 }
                }
                continue
            }
            if !versionDone, let parts = versionParts(token) {
                version = parts
                index += 1
                while version.count < 3, index < tokens.count, tokens[index].count <= 2, let minor = Int(tokens[index]) {
                    version.append(minor)
                    index += 1
                }
                versionDone = true
                continue
            }
            if !versionDone, token.count >= 2, let letter = token.first, letter.isLetter, letter != "v",
               let parts = versionParts(String(token.dropFirst())), token.dropFirst().first?.isNumber == true {
                // `k2.5`, `r1`, `o3`: the letter is the tier, the number the version.
                tierTokens.append(String(letter))
                version = parts
                versionDone = true
                index += 1
                continue
            }
            if let maker, maker.brandWords.contains(token) {
                index += 1
                continue
            }
            tierTokens.append(token)
            index += 1
        }
        var tier = tierTokens.joined(separator: "-")
        if tier.isEmpty { tier = maker?.brandWords.first ?? "" }
        return (maker, tier, version)
    }

    /// Lowercased words inside parentheses in a name.
    static func parenthesized(_ name: String) -> Set<String> {
        var result = Set<String>()
        var rest = Substring(name)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            result.insert(rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased())
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// Splits a maker word fused to its version (`qwen3`, `glm4.6`) and a version fused to a word (`4o`).
    static func expand(_ tokens: [String]) -> [String] {
        let words = Set(ModelMaker.known.flatMap(\.brandWords))
        var result: [String] = []
        for token in tokens {
            if let word = words.first(where: { token.hasPrefix($0) && token.count > $0.count }),
               token.dropFirst(word.count).first?.isNumber == true {
                result.append(word)
                result.append(String(token.dropFirst(word.count)))
                continue
            }
            // `4o`, `3n`: a number then a word that is not a size unit (`120b`, `8x7b` stay whole).
            if let firstLetter = token.firstIndex(where: \.isLetter), firstLetter != token.startIndex,
               token[..<firstLetter].allSatisfy({ $0.isNumber || $0 == "." }),
               token[firstLetter...].allSatisfy(\.isLetter), !["b", "m", "k", "x", "t"].contains(String(token[firstLetter...])) {
                result.append(String(token[..<firstLetter]))
                result.append(String(token[firstLetter...]))
                continue
            }
            result.append(token)
        }
        return result
    }

    /// `5`, `3.5`, `v4.1` as numbers; nil for anything else (sizes such as `120b` are not versions).
    static func versionParts(_ token: String) -> [Int]? {
        var text = Substring(token)
        if text.first == "v", text.dropFirst().first?.isNumber == true { text = text.dropFirst() }
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." }), text.first?.isNumber == true else { return nil }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == text.split(separator: ".").count, parts[0] < 1000 else { return nil }
        return Array(parts.prefix(3))
    }

    /// A date stamp in an id: six or more digits (`20251001`), or four (`2024` of `2024-08-06`, `2411`).
    static func isDate(_ token: String) -> Bool {
        guard token.allSatisfy(\.isNumber) else { return false }
        if token.count >= 6 { return true }
        return token.count == 4
    }

    static func maker(tokens: [String], providerID: String) -> ModelMaker? {
        for maker in ModelMaker.known where tokens.contains(where: { maker.brandWords.contains($0) || maker.tierWords.contains($0) }) {
            return maker
        }
        return ModelMaker.known.first { $0.providers.contains(providerID) }
    }

    /// The name to show: engine tags removed ("(Thinking)", "(Medium)", a trailing "Free"), and "Claude " removed in
    /// the Claude folder, where the reference app says "Opus 5.5".
    static func displayName(_ name: String, maker: ModelMaker?) -> String {
        var result = name
        for tag in parenthesized(name) where dropWords.contains(tag) || effortWords.contains(tag) {
            if let range = result.range(of: "(\(tag))", options: .caseInsensitive) { result.removeSubrange(range) }
        }
        result = result.trimmingCharacters(in: .whitespaces)
        for suffix in [" Free", " free", " (free)"] where result.hasSuffix(suffix) && result.count > suffix.count {
            result = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if maker == .claude, result.hasPrefix("Claude "), result.count > 7 { result = String(result.dropFirst(7)) }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Folders

    /// Every model in folders by maker: Claude, Gemini, ChatGPT, Grok, then the others the engines list, then free
    /// models of other makers, models on this Mac, and the rest. The same model from several engines or providers is one
    /// choice with several routes. Empty folders are left out.
    public static func folders(_ models: [ModelInfo], billing: [String: ModelBilling]?) -> [ModelFolder] {
        struct Entry {
            var identity: ModelIdentity
            var key: String
            var models: [(info: ModelInfo, billing: ModelBilling, tagged: Bool)]
            var order: Int
        }
        var entries: [String: Entry] = [:]
        var keys: [String] = []
        for (position, model) in models.enumerated() {
            let kind = billing.map { ModelBilling.lookup(model.ref, in: $0) } ?? defaultBilling(model.ref)
            let identity = identity(of: model)
            let version = identity.version.map(String.init).joined(separator: ".")
            let makerKey = kind == .local ? "local" : (identity.maker?.id ?? "?")
            let key = "\(makerKey)|\(identity.tier)|\(version)"
            if entries[key] == nil {
                entries[key] = Entry(identity: identity, key: key, models: [], order: position)
                keys.append(key)
            }
            entries[key]?.models.append((model, kind, identity.tagged))
        }

        var choices: [ModelChoice] = []
        for key in keys {
            guard let entry = entries[key] else { continue }
            // One route per provider: an id that is not the CLI's "default" and carries no tag wins.
            var byProvider: [String: (info: ModelInfo, billing: ModelBilling, tagged: Bool)] = [:]
            var providerOrder: [String] = []
            for item in entry.models {
                let provider = item.info.ref.providerID
                if let existing = byProvider[provider] {
                    if score(item) < score(existing) { byProvider[provider] = item }
                } else {
                    byProvider[provider] = item
                    providerOrder.append(provider)
                }
            }
            let routes = providerOrder.compactMap { byProvider[$0] }
                .map { ModelRoute(ref: $0.info.ref, billing: $0.billing, providerName: $0.info.providerName,
                                  available: $0.info.available, contextLimit: $0.info.contextLimit) }
                .enumerated()
                .sorted { a, b in
                    let ra = billingOrder(a.element.billing), rb = billingOrder(b.element.billing)
                    return ra != rb ? ra < rb : a.offset < b.offset
                }
                .map(\.element)
            let maker: ModelMaker
            if entry.key.hasPrefix("local|") {
                maker = .local
            } else if let known = entry.identity.maker {
                maker = known
            } else {
                maker = routes.contains(where: { $0.billing == .free }) ? .free : .other
            }
            let primary = routes.first(where: \.available) ?? routes.first
            let primaryInfo = primary.flatMap { route in byProvider[route.ref.providerID]?.info }
            let name = primaryInfo.map { displayName($0.name, maker: entry.identity.maker) } ?? entry.identity.name
            choices.append(ModelChoice(
                id: entry.key.hasPrefix("?|") ? "\(maker.id)|" + entry.key.dropFirst(2) : entry.key,
                name: name.isEmpty ? (primary?.ref.id ?? entry.key) : name, maker: maker, tier: entry.identity.tier,
                version: entry.identity.version, routes: routes, refs: entry.models.map(\.info.ref),
                contextLimit: primary?.contextLimit ?? routes.compactMap(\.contextLimit).max()))
        }

        let firstSeen = Dictionary(choices.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return ModelMaker.all.compactMap { maker in
            let list = choices.filter { $0.maker == maker }
            guard !list.isEmpty else { return nil }
            return folder(maker, list, firstSeen: firstSeen)
        }
    }

    /// Splits a maker's models into the newest of each tier and the rest.
    static func folder(_ maker: ModelMaker, _ choices: [ModelChoice], firstSeen: [String: Int]) -> ModelFolder {
        var tierOrder: [String] = []
        var byTier: [String: [ModelChoice]] = [:]
        for choice in choices {
            if byTier[choice.tier] == nil { tierOrder.append(choice.tier) }
            byTier[choice.tier, default: []].append(choice)
        }
        // Unranked tiers first, in the engines' order, then ranked tiers from most to least capable.
        let unranked = tierOrder.filter { !maker.tierRank.contains($0) }
        let ranked = maker.tierRank.filter { tierOrder.contains($0) }
        let tiers = unranked + ranked
        let newestMajor = choices.compactMap(\.version.first).max()

        var current: [ModelChoice] = []
        var older: [ModelChoice] = []
        for tier in tiers {
            let list = (byTier[tier] ?? []).sorted { a, b in
                if a.version != b.version { return isNewer(a.version, than: b.version) }
                return (firstSeen[a.id] ?? 0) < (firstSeen[b.id] ?? 0)
            }
            guard let newest = list.first else { continue }
            var isCurrent = true
            if let tolerance = maker.generationTolerance, let newestMajor, let major = newest.version.first {
                isCurrent = newestMajor - major <= tolerance
            }
            if isCurrent {
                current.append(newest)
                older += list.dropFirst()
            } else {
                older += list
            }
        }
        return ModelFolder(maker: maker, current: current, older: older)
    }

    /// Lexicographic on the version parts; a versioned model is newer than an unversioned one.
    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count > b.count
    }

    private static func score(_ item: (info: ModelInfo, billing: ModelBilling, tagged: Bool)) -> Int {
        (item.info.ref.id == "default" ? 2 : 0) + (item.tagged ? 1 : 0)
    }

    private static func billingOrder(_ billing: ModelBilling) -> Int {
        switch billing {
        case .subscription: 0
        case .free: 1
        case .local: 2
        case .apiKey: 3
        }
    }

    /// Without a billing map: Claude's own providers are known, everything else is billed to a key.
    static func defaultBilling(_ ref: ModelRef) -> ModelBilling {
        switch ref.providerID {
        case "claude-code", "antigravity": .subscription
        default: .apiKey
        }
    }

    // MARK: Lookups

    /// The choice that `ref` names.
    public static func choice(for ref: ModelRef?, in folders: [ModelFolder]) -> ModelChoice? {
        guard let ref else { return nil }
        return folders.lazy.flatMap(\.all).first { $0.contains(ref) }
    }

    /// The route a single-selection picker uses for `choice`: the route matching `selected` when it is usable (or the
    /// whole choice is unavailable), otherwise `choice.primary`.
    public static func pickerRoute(for choice: ModelChoice, selected: ModelRef? = nil) -> ModelRoute? {
        if let selected, let matched = choice.route(for: selected), matched.available || !choice.available {
            return matched
        }
        return choice.primary
    }

    /// Normalizes `ref` to its deduplicated picker route inside `folders` (for example turning `claude-code/default`
    /// into `claude-code/opus`), so single-selection pickers always match a row's tag.
    public static func resolvedRef(for ref: ModelRef?, in folders: [ModelFolder]) -> ModelRef? {
        guard let ref else { return nil }
        guard let choice = choice(for: ref, in: folders) else { return ref }
        return pickerRoute(for: choice, selected: ref)?.ref ?? ref
    }

    /// The folder of the model `ref` names.
    public static func folder(for ref: ModelRef?, in folders: [ModelFolder]) -> ModelFolder? {
        guard let ref else { return nil }
        return folders.first { $0.all.contains { $0.contains(ref) } }
    }

    /// The folder shown open at the top of the picker: the current model's maker. Free, On this Mac and Other always
    /// stay folders, so with one of those models the first maker's folder is on top instead.
    public static func topFolder(for ref: ModelRef?, in folders: [ModelFolder]) -> ModelFolder? {
        let staysFolded: Set<String> = [ModelMaker.free.id, ModelMaker.local.id, ModelMaker.other.id]
        if let current = folder(for: ref, in: folders), !staysFolded.contains(current.maker.id) { return current }
        return folders.first { !staysFolded.contains($0.maker.id) } ?? folders.first
    }

    /// Choices whose name, tier, maker, provider or id contain every word of `query`, newest models first within each
    /// folder.
    public static func search(_ query: String, in folders: [ModelFolder]) -> [ModelChoice] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return folders.flatMap(\.all).filter { choice in
            let text = ([choice.name, choice.tier, choice.maker.name] + choice.routes.flatMap { [$0.providerName, $0.ref.description] })
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}
