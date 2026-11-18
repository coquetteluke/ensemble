import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the composer's model picker with the models the real engines list (the Claude CLI, `agy acp`,
/// OpenCode's free models, a ChatGPT sign-in and a local model): the default view, open folders, the pay options of a
/// model, the key entry, a search, and the "start a new session" bar. Dark and light at the requested zoom. Called
/// from `SnapshotRenderer.run`.
@MainActor
enum ModelPickerSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        var seed = PreviewData.seed()
        let opus = ModelRef(providerID: "claude-code", id: "opus")
        seed.models = models
        seed.providers = providers
        if let index = seed.sessions.firstIndex(where: { $0.id == PreviewData.mainSessionID }) { seed.sessions[index].model = opus }
        let store = SessionStore(engine: PickerSnapshotEngine(base: PreviewEngine(seed: seed, delayScale: 0.01)))
        store.seed(seed)
        Task { @MainActor in await store.loadModelOptions(for: opus) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let session = store.session(PreviewData.mainSessionID) else { return [] }
        let window = WindowState()
        let context = ModelPickerView.SessionContext(store: store, session: session)
        let folders = ModelCatalog.folders(models, billing: billing)
        let opusID = ModelCatalog.choice(for: opus, in: folders)?.id
        let carbon = folders.first { $0.id == "gemini" }?.current.first
        let carbonKey = carbon.flatMap { choice in
            ModelAccess.options(for: choice, providers: providers).first { $0.missingKey != nil }.map {
                ModelPickerView.KeyEntry(choiceID: choice.id, option: $0)
            }
        }

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("model-picker-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card { ModelPickerView(models: models, billing: billing, current: opus, context: context) { _ in } }
            }
            written += save("model-picker-older-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card {
                    ModelPickerView(models: models, billing: billing, current: opus, context: context,
                                    initialOpen: ["older:claude"]) { _ in }
                }
            }
            written += save("model-picker-folders-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card {
                    ModelPickerView(models: models, billing: billing, current: opus, context: context,
                                    initialOpen: ["gemini", "chatgpt"]) { _ in }
                }
            }
            written += save("model-picker-pay-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card {
                    ModelPickerView(models: models, billing: billing, current: opus, context: context,
                                    initialOptionsFor: opusID) { _ in }
                }
            }
            written += save("model-picker-key-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card {
                    ModelPickerView(models: models, billing: billing, current: opus, context: context, initialOpen: ["gemini"],
                                    initialOptionsFor: carbon?.id, initialKeyEntry: carbonKey) { _ in }
                }
            }
            // A free model is current: its folder stays closed with a check, and Claude is on top.
            written += save("model-picker-free-current-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card { ModelPickerView(models: models, billing: billing, current: ModelRef(providerID: "opencode", id: "big-pickle"),
                                       context: context) { _ in } }
            }
            written += save("model-picker-search-\(tone)\(suffix)", to: directory, width: 360, zoom: zoom, scheme: scheme) {
                card {
                    ModelPickerView(models: models, billing: billing, current: opus, context: context, initialQuery: "sonnet") { _ in }
                }
            }
            written += save("model-change-offer-\(tone)\(suffix)", to: directory, width: 784, zoom: zoom, scheme: scheme) {
                ComposerView(store: store, session: session, window: window, snapshotDraft: "Add a retry to the upload step",
                             snapshotModelOffer: ModelChangeOffer(
                                sessionID: session.id, model: ModelRef(providerID: "antigravity", id: "gemini-4-carbon"),
                                modelName: "Gemini 4 Carbon", change: EngineChange(sessionEngine: "Claude", modelEngine: "Google Antigravity")))
                    .padding(24)
            }
        }
        print("Rendered \(written.count) model picker snapshots:")
        for path in written { print(path) }
        return written
    }

    // MARK: Samples (shaped like the engines' real lists on 2026-11-18)

    static let billing: [String: ModelBilling] = [
        "claude-code": .subscription, "claude-code-api": .apiKey, "antigravity": .subscription, "openai": .subscription,
        "opencode": .free, "ollama": .local,
    ]

    static let providers: [ProviderInfo] = [
        ProviderInfo(id: "claude-code", name: "Claude (your subscription)", connected: true),
        ProviderInfo(id: "claude-code-api", name: "Claude (API key)", connected: false),
        ProviderInfo(id: "antigravity", name: "Gemini (your Google AI subscription)", connected: true),
        ProviderInfo(id: "anthropic", name: "Anthropic", connected: false),
        ProviderInfo(id: "openai", name: "OpenAI", connected: true),
        ProviderInfo(id: "xai", name: "xAI", connected: false),
        ProviderInfo(id: "google", name: "Google", connected: false),
        ProviderInfo(id: "deepseek", name: "DeepSeek", connected: false),
        ProviderInfo(id: "opencode", name: "OpenCode Zen", connected: true),
    ]

    static let models: [ModelInfo] = {
        func list(_ provider: String, _ providerName: String, _ context: Int?, _ items: [(String, String)]) -> [ModelInfo] {
            items.map { ModelInfo(ref: ModelRef(providerID: provider, id: $0.0), name: $0.1, providerName: providerName, contextLimit: context) }
        }
        let claude = list("claude-code", "Claude (your subscription)", 1_000_000, [
            ("default", "Opus 5.5"), ("opus", "Opus 5.5"), ("claude-fable-5-2", "Fable 5.2"), ("sonnet", "Sonnet 5.5"),
            ("haiku", "Haiku 5.5"), ("fable", "Fable 5.1"), ("claude-sonnet-5", "Sonnet 5"), ("claude-opus-5", "Opus 5"),
            ("claude-fable-5", "Fable 5"), ("claude-opus-4-8", "Opus 4.8"), ("claude-opus-4-7", "Opus 4.7"),
        ]) + list("claude-code", "Claude (your subscription)", 200_000, [
            ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("claude-opus-4-6", "Opus 4.6"), ("claude-sonnet-4-6", "Sonnet 4.6"),
        ])
        let gemini = list("antigravity", "Gemini (your Google AI subscription)", 1_048_576, [
            ("gemini-4-carbon", "Gemini 4 Carbon"), ("gemini-4-argon", "Gemini 4 Argon"), ("gemini-4-hydrogen", "Gemini 4 Hydrogen"),
            ("gemini-pro-orchestrator", "Orchestrator (Carbon)"), ("gemini-3.8-flash", "Gemini 3.8 Flash"),
            ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Thinking)"), ("gpt-oss-120b-medium", "GPT-OSS 120B (Medium)"),
        ])
        let chatGPT = list("openai", "OpenAI", 400_000, [("gpt-5.5", "GPT-5.5"), ("gpt-5.5-codex", "GPT-5.5 Codex"),
                                                         ("gpt-5.5-mini", "GPT-5.5 mini"), ("gpt-5.1", "GPT-5.1")])
        let free = list("opencode", "OpenCode Zen", 200_000, [
            ("big-pickle", "Big Pickle"), ("deepseek-v4.1-flash-free", "DeepSeek V4.1 Flash Free"), ("beam-free", "Beam Free"),
            ("nemotron-3.5-super-vl-free", "Nemotron 3.5 Super VL Free"),
        ])
        let local = list("ollama", "Ollama", 131_072, [("llama3.3:70b", "Llama 3.3 70B")])
        return claude + gemini + chatGPT + free + local
    }()

    // MARK: Drawing

    private static func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        CardFrame(content: content())
    }

    private struct CardFrame<C: View>: View {
        let content: C
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .clipShape(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).strokeBorder(theme.border))
                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: theme.z(14), y: theme.z(6))
                .padding(theme.z(20))
        }
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = Canvas(width: w) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }

    private struct Canvas<Content: View>: View {
        let width: CGFloat
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.background)
        }
    }
}

/// The preview engine with Claude's effort levels and fast mode for `claude-code` models, so the picker's Effort and
/// Fast mode rows draw as they do for a real Claude session.
private final class PickerSnapshotEngine: OpenCodeAPI, EngineModelOptionsControl, Sendable {
    let base: PreviewEngine
    init(base: PreviewEngine) { self.base = base }

    func modelOptions(for model: ModelRef) async throws -> ModelOptions {
        if model.providerID == "claude-code" {
            return ModelOptions(effortLevels: EffortLevel.allCases, defaultEffort: .high, supportsFastMode: model.id == "opus")
        }
        return try await base.modelOptions(for: model)
    }
    func setEffort(_ sessionID: String, effort: EffortLevel?) async throws { try await base.setEffort(sessionID, effort: effort) }
    func setFastMode(_ sessionID: String, enabled: Bool) async throws { try await base.setFastMode(sessionID, enabled: enabled) }

    func serverInfo() async throws -> (version: String, url: URL) { try await base.serverInfo() }
    func listSessions() async throws -> [EngineSession] { try await base.listSessions() }
    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                       parentID: String?) async throws -> EngineSession {
        try await base.createSession(directory: directory, model: model, agent: agent, permissionMode: permissionMode, parentID: parentID)
    }
    func deleteSession(_ sessionID: String) async throws { try await base.deleteSession(sessionID) }
    func renameSession(_ sessionID: String, title: String) async throws { try await base.renameSession(sessionID, title: title) }
    func setArchived(_ sessionID: String, archived: Bool) async throws { try await base.setArchived(sessionID, archived: archived) }
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws { try await base.setPermissionMode(sessionID, mode: mode) }
    func switchModel(_ sessionID: String, model: ModelRef) async throws { try await base.switchModel(sessionID, model: model) }
    func transcript(_ sessionID: String) async throws -> [TranscriptItem] { try await base.transcript(sessionID) }
    func children(_ sessionID: String) async throws -> [EngineSession] { try await base.children(sessionID) }
    func prompt(_ sessionID: String, text: String, files: [URL]) async throws { try await base.prompt(sessionID, text: text, files: files) }
    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        try await base.injectSynthetic(sessionID, text: text, wake: wake)
    }
    func interrupt(_ sessionID: String) async throws { try await base.interrupt(sessionID) }
    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await base.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision, message: message)
    }
    func pendingPermissions() async throws -> [PermissionRequest] { try await base.pendingPermissions() }
    func context(_ sessionID: String) async throws -> ContextBreakdown { try await base.context(sessionID) }
    func changedFiles(_ sessionID: String) async throws -> [FileChange] { try await base.changedFiles(sessionID) }
    func connectors() async throws -> [ConnectorInfo] { try await base.connectors() }
    func models() async throws -> [ModelInfo] { try await base.models() }
    func providers() async throws -> [ProviderInfo] { try await base.providers() }
    func setAPIKey(providerID: String, key: String) async throws { try await base.setAPIKey(providerID: providerID, key: key) }
    func removeAPIKey(providerID: String) async throws { try await base.removeAPIKey(providerID: providerID) }
    func schedules() async throws -> [ScheduleInfo] { try await base.schedules() }
    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        try await base.createSchedule(title: title, prompt: prompt, directory: directory, schedule: schedule, model: model)
    }
    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws { try await base.setSchedulePaused(scheduleID, paused: paused) }
    func deleteSchedule(_ scheduleID: String) async throws { try await base.deleteSchedule(scheduleID) }
    func events() -> AsyncStream<EngineEvent> { base.events() }
}
