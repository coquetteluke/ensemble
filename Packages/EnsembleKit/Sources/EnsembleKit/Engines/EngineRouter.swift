import Foundation
import Synchronization

// MARK: Billing groups

/// Who pays for a model. The model picker groups models by it ("Your subscriptions", "API keys", ...).
public enum ModelBilling: String, Codable, Sendable, CaseIterable {
    /// A plan the user already pays for: Claude Pro or Max, ChatGPT, SuperGrok, Google AI, coding plans.
    case subscription
    /// Billed per token to an API key or a cloud account.
    case apiKey
    /// Free models that need no key (OpenCode's free models).
    case free
    /// Models running on this Mac (LM Studio, Ollama).
    case local

    public var groupTitle: String {
        switch self {
        case .subscription: "Your subscriptions"
        case .apiKey: "API keys"
        case .free: "Free"
        case .local: "On this Mac"
        }
    }

    /// The key a billing map uses for a model: `providerID/modelID`, without the variant.
    public static func key(for ref: ModelRef) -> String { "\(ref.providerID)/\(ref.id)" }

    /// Looks a model up in a billing map: the model's own entry, then its provider's entry, else `fallback`.
    public static func lookup(_ ref: ModelRef, in map: [String: ModelBilling], fallback: ModelBilling = .apiKey) -> ModelBilling {
        map[key(for: ref)] ?? map[ref.providerID] ?? fallback
    }
}

/// Models with the same billing, for the model picker.
public struct ModelGroup: Hashable, Sendable, Identifiable {
    public var billing: ModelBilling
    public var models: [ModelInfo]
    public var id: String { billing.rawValue }
    public var title: String { billing.groupTitle }

    public init(billing: ModelBilling, models: [ModelInfo]) {
        self.billing = billing
        self.models = models
    }

    /// Groups in picker order (subscriptions, API keys, free, on this Mac). Empty groups are left out and each
    /// group keeps the order of `models`.
    public static func groups(_ models: [ModelInfo], billing: [String: ModelBilling]) -> [ModelGroup] {
        var buckets: [ModelBilling: [ModelInfo]] = [:]
        for model in models { buckets[ModelBilling.lookup(model.ref, in: billing), default: []].append(model) }
        return ModelBilling.allCases.compactMap { kind in
            guard let list = buckets[kind], !list.isEmpty else { return nil }
            return ModelGroup(billing: kind, models: list)
        }
    }
}

/// Engines that know who pays for their models.
public protocol EngineModelBilling: Sendable {
    /// Keys are `ModelBilling.key(for:)` (one model) or a bare provider id (every model of that provider).
    /// Models not in the map are billed to an API key.
    func modelBilling() async throws -> [String: ModelBilling]
}

// MARK: Errors

public enum EngineRouterError: Error, LocalizedError, Equatable, Sendable {
    /// No registered engine has a session with this id.
    case unknownSession(String)
    case unknownSchedule(String)
    /// The engine that owns the session does not have this optional ability.
    case notSupported(engine: String, feature: String)
    /// A session cannot move to a model that runs on another engine.
    case engineMismatch(sessionEngine: String, modelEngine: String, model: String)

    public var errorDescription: String? {
        switch self {
        case .unknownSession(let id):
            "No engine has a session with id \(id)."
        case .unknownSchedule(let id):
            "No engine has a scheduled task with id \(id)."
        case .notSupported(let engine, let feature):
            "\(engine) sessions cannot \(feature)."
        case .engineMismatch(let sessionEngine, let modelEngine, let model):
            "This session runs on \(sessionEngine), and \(model) runs on \(modelEngine). Start a new session to use it."
        }
    }
}

// MARK: Router

/// The one engine the app talks to. It holds every engine Ensemble can run (OpenCode, the Claude subscription engine,
/// ACP agents such as Google's Antigravity) and sends each call to the engine that owns the session, or, for a new
/// session, to the engine that serves the model's provider. Lists (sessions, models, providers, connectors, pending
/// permissions, schedules) are merged from all engines, and their live events are merged into one stream.
///
/// The fallback engine (OpenCode) serves every provider no other engine claims. Engines registered later with
/// `register(_:providers:)` claim their provider ids (for example `claude-code` and `claude-code-api`).
///
/// Session ownership is learned from what engines return (created, listed, forked, child sessions) and from their
/// events. A session id nobody claims triggers one fresh listing of every engine before the call fails with
/// `EngineRouterError.unknownSession`.
public final class EngineRouter: OpenCodeAPI, EngineHistoryControl, EngineModelOptionsControl, EngineCommandsControl,
    EngineModelBilling, Sendable {

    /// One engine and the providers it serves.
    public struct Registration: Sendable, Identifiable {
        public let id: String
        /// Shown in errors ("OpenCode sessions cannot ...").
        public let name: String
        public let engine: any OpenCodeAPI
        /// Provider ids this engine serves, and who pays for each. Empty for the fallback engine.
        public let providers: [String: ModelBilling]
        public let isFallback: Bool
    }

    private struct Forwarder {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct Subscriber {
        let continuation: AsyncStream<EngineEvent>.Continuation
        var forwarders: [String: Forwarder] = [:]
        /// Forwarders that ended before they were stored.
        var endedEarly: Set<UUID> = []
        /// True while `events()` is still starting the first forwarders; the stream cannot end yet.
        var starting = true
    }

    private struct State {
        /// The fallback engine first, then the others in registration order.
        var registrations: [Registration]
        var sessionOwners: [String: String] = [:]
        var scheduleOwners: [String: String] = [:]
        /// Each engine's last good session list, used when that engine fails a later listing.
        var lastSessions: [String: [EngineSession]] = [:]
        var subscribers: [UUID: Subscriber] = [:]
    }

    private let state: Mutex<State>

    /// `fallback` serves every provider no registered engine claims (normally the OpenCode client).
    public init(fallback: any OpenCodeAPI, id: String = "opencode", name: String = "OpenCode") {
        let registration = Registration(id: id, name: name, engine: fallback, providers: [:], isFallback: true)
        state = Mutex(State(registrations: [registration]))
    }

    /// The usual setup: OpenCode for everything, plus the Claude engine for `claude-code` (subscription) and
    /// `claude-code-api` (API key) when given.
    public static func standard(openCode: any OpenCodeAPI, claude: ClaudeCodeEngine?) -> EngineRouter {
        let router = EngineRouter(fallback: openCode)
        if let claude {
            router.register(claude, providers: [ClaudeModels.subscriptionProviderID: .subscription,
                                                ClaudeModels.apiKeyProviderID: .apiKey],
                            id: "claude", name: "Claude")
        }
        return router
    }

    // MARK: Registration

    /// Adds an engine that serves `providers`, all billed the same way. Registering again with the same id replaces
    /// that engine (and its live events) in place.
    public func register(_ engine: any OpenCodeAPI, providers: [String], billing: ModelBilling = .subscription,
                         id: String? = nil, name: String? = nil) {
        register(engine, providers: Dictionary(providers.map { ($0, billing) }, uniquingKeysWith: { a, _ in a }), id: id, name: name)
    }

    /// Adds an engine that serves `providers`, each with its own billing. A provider already claimed by an earlier
    /// engine stays with that engine.
    public func register(_ engine: any OpenCodeAPI, providers: [String: ModelBilling], id: String? = nil, name: String? = nil) {
        let typeName = String(describing: type(of: engine))
        let engineID = id ?? typeName
        let subscribers: [UUID] = state.withLock { state in
            if let index = state.registrations.firstIndex(where: { $0.id == engineID }) {
                let old = state.registrations[index]
                state.registrations[index] = Registration(id: engineID, name: name ?? old.name, engine: engine,
                                                          providers: old.isFallback ? [:] : providers, isFallback: old.isFallback)
                state.lastSessions[engineID] = nil
            } else {
                state.registrations.append(Registration(id: engineID, name: name ?? typeName, engine: engine,
                                                        providers: providers, isFallback: false))
            }
            return Array(state.subscribers.keys)
        }
        guard let registration = self.registration(id: engineID) else { return }
        for subscriber in subscribers { startForwarder(registration, subscriber: subscriber) }
    }

    /// Every engine, the fallback first.
    public var registrations: [Registration] { state.withLock { $0.registrations } }

    /// The first registered engine of a type (for engine-specific screens such as Accounts).
    public func engine<T>(_ type: T.Type) -> T? {
        registrations.lazy.compactMap { $0.engine as? T }.first
    }

    public func registration(id: String) -> Registration? {
        state.withLock { state in state.registrations.first { $0.id == id } }
    }

    /// The engine that serves a provider (the fallback when no engine claims it).
    public func registration(forProvider providerID: String) -> Registration {
        state.withLock { Self.registration(forProvider: providerID, in: $0) }
    }

    /// The engine that owns a session, after a fresh listing if needed; nil when no engine has it.
    public func registration(forSession sessionID: String) async -> Registration? {
        try? await owner(of: sessionID)
    }

    private static func registration(forProvider providerID: String, in state: State) -> Registration {
        state.registrations.first { $0.providers[providerID] != nil } ?? state.registrations[0]
    }

    private var fallback: Registration { state.withLock { $0.registrations[0] } }

    // MARK: Ownership

    private func record(_ sessionID: String, owner engineID: String) {
        state.withLock { $0.sessionOwners[sessionID] = engineID }
    }

    private func knownOwner(_ sessionID: String) -> Registration? {
        state.withLock { state in
            var engineID = state.sessionOwners[sessionID]
            if engineID == nil, let dot = sessionID.firstIndex(of: ".") {
                // Claude subagent sessions are `<root>.<tool use id>` and belong to the root's engine.
                engineID = state.sessionOwners[String(sessionID[..<dot])]
            }
            guard let engineID else { return nil }
            return state.registrations.first { $0.id == engineID }
        }
    }

    private func owner(of sessionID: String) async throws -> Registration {
        if let known = knownOwner(sessionID) { return known }
        _ = try? await listSessions()
        if let known = knownOwner(sessionID) { return known }
        throw EngineRouterError.unknownSession(sessionID)
    }

    private func learn(_ event: EngineEvent, from engineID: String) {
        switch event {
        case .sessionCreated(let session), .sessionUpdated(let session):
            record(session.id, owner: engineID)
        case .sessionDeleted(let sessionID):
            state.withLock { _ = $0.sessionOwners.removeValue(forKey: sessionID) }
        case .permissionAsked(let request):
            state.withLock { state in
                if state.sessionOwners[request.sessionID] == nil { state.sessionOwners[request.sessionID] = engineID }
            }
        default:
            break
        }
    }

    /// Runs `body` on every engine at once and returns the answers in registration order. Fails only when every
    /// engine fails, with the fallback engine's error first.
    private func gather<T: Sendable>(_ body: @escaping @Sendable (Registration) async throws -> T)
        async throws -> [(Registration, T)] {
        let list = registrations
        let results = await withTaskGroup(of: (Int, Result<T, any Error>).self) { group in
            for (index, registration) in list.enumerated() {
                group.addTask {
                    do { return (index, .success(try await body(registration))) } catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<T, any Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var answers: [(Registration, T)] = []
        var firstError: (any Error)?
        for (index, result) in results {
            switch result {
            case .success(let value): answers.append((list[index], value))
            case .failure(let error): if firstError == nil { firstError = error }
            }
        }
        if answers.isEmpty, let firstError { throw firstError }
        return answers
    }

    private func capability<C>(_ type: C.Type, of registration: Registration, feature: String) throws -> C {
        guard let control = registration.engine as? C else {
            throw EngineRouterError.notSupported(engine: registration.name, feature: feature)
        }
        return control
    }

    // MARK: Server

    /// The fallback engine's version and address.
    public func serverInfo() async throws -> (version: String, url: URL) {
        try await fallback.engine.serverInfo()
    }

    // MARK: Sessions

    /// Every engine's sessions. An engine that fails contributes its last good list, so a passing error does not
    /// make its sessions vanish; the call fails only when no engine answers and none has answered before.
    public func listSessions() async throws -> [EngineSession] {
        let list = registrations
        let results = await withTaskGroup(of: (Int, Result<[EngineSession], any Error>).self) { group in
            for (index, registration) in list.enumerated() {
                group.addTask {
                    do { return (index, .success(try await registration.engine.listSessions())) } catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<[EngineSession], any Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var merged: [EngineSession] = []
        var answered = false
        var firstError: (any Error)?
        for (index, result) in results {
            let registration = list[index]
            switch result {
            case .success(let sessions):
                answered = true
                merged += sessions
                state.withLock { state in
                    state.lastSessions[registration.id] = sessions
                    for session in sessions { state.sessionOwners[session.id] = registration.id }
                }
            case .failure(let error):
                if firstError == nil { firstError = error }
                if let cached = state.withLock({ $0.lastSessions[registration.id] }) {
                    answered = true
                    merged += cached
                }
            }
        }
        if !answered, let firstError { throw firstError }
        return merged
    }

    /// Subagents go to their parent's engine, new sessions to the engine of the model's provider, and sessions
    /// without a model to the fallback engine (which picks its default model).
    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                              parentID: String?) async throws -> EngineSession {
        let target: Registration
        if let parentID {
            target = try await owner(of: parentID)
        } else if let model {
            target = registration(forProvider: model.providerID)
        } else {
            target = fallback
        }
        let session = try await target.engine.createSession(directory: directory, model: model, agent: agent,
                                                            permissionMode: permissionMode, parentID: parentID)
        record(session.id, owner: target.id)
        return session
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await owner(of: sessionID).engine.deleteSession(sessionID)
        state.withLock { _ = $0.sessionOwners.removeValue(forKey: sessionID) }
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        try await owner(of: sessionID).engine.renameSession(sessionID, title: title)
    }

    public func setArchived(_ sessionID: String, archived: Bool) async throws {
        try await owner(of: sessionID).engine.setArchived(sessionID, archived: archived)
    }

    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws {
        try await owner(of: sessionID).engine.setPermissionMode(sessionID, mode: mode)
    }

    /// Only within the session's engine: a session cannot move from one engine to another.
    public func switchModel(_ sessionID: String, model: ModelRef) async throws {
        let current = try await owner(of: sessionID)
        let target = registration(forProvider: model.providerID)
        guard target.id == current.id else {
            throw EngineRouterError.engineMismatch(sessionEngine: current.name, modelEngine: target.name, model: model.description)
        }
        try await current.engine.switchModel(sessionID, model: model)
    }

    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        try await owner(of: sessionID).engine.transcript(sessionID)
    }

    public func children(_ sessionID: String) async throws -> [EngineSession] {
        let registration = try await owner(of: sessionID)
        let children = try await registration.engine.children(sessionID)
        state.withLock { state in
            for child in children { state.sessionOwners[child.id] = registration.id }
        }
        return children
    }

    // MARK: Talking

    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        try await owner(of: sessionID).engine.prompt(sessionID, text: text, files: files)
    }

    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        try await owner(of: sessionID).engine.injectSynthetic(sessionID, text: text, wake: wake)
    }

    public func interrupt(_ sessionID: String) async throws {
        try await owner(of: sessionID).engine.interrupt(sessionID)
    }

    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        try await owner(of: sessionID).engine.replyPermission(sessionID: sessionID, requestID: requestID, decision: decision, message: message)
    }

    public func pendingPermissions() async throws -> [PermissionRequest] {
        let answers = try await gather { try await $0.engine.pendingPermissions() }
        state.withLock { state in
            for (registration, requests) in answers {
                for request in requests where state.sessionOwners[request.sessionID] == nil {
                    state.sessionOwners[request.sessionID] = registration.id
                }
            }
        }
        return answers.flatMap(\.1).sorted { $0.created < $1.created }
    }

    // MARK: Panels

    public func context(_ sessionID: String) async throws -> ContextBreakdown {
        try await owner(of: sessionID).engine.context(sessionID)
    }

    public func changedFiles(_ sessionID: String) async throws -> [FileChange] {
        try await owner(of: sessionID).engine.changedFiles(sessionID)
    }

    /// MCP servers of every engine. A server two engines both run is listed once, with the better state.
    public func connectors() async throws -> [ConnectorInfo] {
        let answers = try await gather { try await $0.engine.connectors() }
        var merged: [ConnectorInfo] = []
        var index: [String: Int] = [:]
        for connector in answers.flatMap(\.1) {
            if let at = index[connector.id] {
                if merged[at].state != .connected, connector.state == .connected { merged[at] = connector }
            } else {
                index[connector.id] = merged.count
                merged.append(connector)
            }
        }
        return merged
    }

    // MARK: Models and keys

    /// Every engine's models, the fallback engine's first (its default model leads). Use `modelBilling()` or
    /// `modelGroups()` to group them for the picker.
    public func models() async throws -> [ModelInfo] {
        var seen = Set<String>()
        return try await gather { try await $0.engine.models() }.flatMap(\.1).filter { seen.insert($0.id).inserted }
    }

    public func providers() async throws -> [ProviderInfo] {
        var seen = Set<String>()
        return try await gather { try await $0.engine.providers() }.flatMap(\.1).filter { seen.insert($0.id).inserted }
    }

    public func setAPIKey(providerID: String, key: String) async throws {
        try await registration(forProvider: providerID).engine.setAPIKey(providerID: providerID, key: key)
    }

    public func removeAPIKey(providerID: String) async throws {
        try await registration(forProvider: providerID).engine.removeAPIKey(providerID: providerID)
    }

    /// Billing from engines that report it, plus the billing each engine was registered with for its providers.
    public func modelBilling() async throws -> [String: ModelBilling] {
        var map: [String: ModelBilling] = [:]
        for registration in registrations {
            for (provider, billing) in registration.providers { map[provider] = billing }
        }
        let reported = (try? await gather { registration -> [String: ModelBilling] in
            guard let billing = registration.engine as? any EngineModelBilling else { return [:] }
            return try await billing.modelBilling()
        }) ?? []
        for (_, entries) in reported {
            map.merge(entries) { current, _ in current }
        }
        return map
    }

    /// Every model, grouped for the picker ("Your subscriptions", "API keys", "Free", "On this Mac").
    public func modelGroups() async throws -> [ModelGroup] {
        async let models = models()
        async let billing = modelBilling()
        return ModelGroup.groups(try await models, billing: (try? await billing) ?? [:])
    }

    // MARK: Schedules

    public func schedules() async throws -> [ScheduleInfo] {
        let answers = try await gather { try await $0.engine.schedules() }
        state.withLock { state in
            for (registration, schedules) in answers {
                for schedule in schedules { state.scheduleOwners[schedule.id] = registration.id }
            }
        }
        return answers.flatMap(\.1).sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
    }

    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        let target = model.map { registration(forProvider: $0.providerID) } ?? fallback
        let info = try await target.engine.createSchedule(title: title, prompt: prompt, directory: directory, schedule: schedule, model: model)
        state.withLock { $0.scheduleOwners[info.id] = target.id }
        return info
    }

    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {
        try await scheduleOwner(scheduleID).engine.setSchedulePaused(scheduleID, paused: paused)
    }

    public func deleteSchedule(_ scheduleID: String) async throws {
        try await scheduleOwner(scheduleID).engine.deleteSchedule(scheduleID)
        state.withLock { _ = $0.scheduleOwners.removeValue(forKey: scheduleID) }
    }

    private func scheduleOwner(_ scheduleID: String) async throws -> Registration {
        func known() -> Registration? {
            state.withLock { state in
                state.scheduleOwners[scheduleID].flatMap { id in state.registrations.first { $0.id == id } }
            }
        }
        if let registration = known() { return registration }
        _ = try? await schedules()
        if let registration = known() { return registration }
        throw EngineRouterError.unknownSchedule(scheduleID)
    }

    // MARK: Events

    /// Every engine's live events in one stream. Engines registered later join open streams. The stream ends when
    /// the caller stops listening, or when every engine's stream has ended.
    public func events() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(20_000))
        let id = UUID()
        let list = state.withLock { state -> [Registration] in
            state.subscribers[id] = Subscriber(continuation: continuation)
            return state.registrations
        }
        continuation.onTermination = { [weak self] _ in self?.dropSubscriber(id) }
        for registration in list { startForwarder(registration, subscriber: id) }
        state.withLock { $0.subscribers[id]?.starting = false }
        finishIfIdle(id)
        return stream
    }

    /// Number of open `events()` streams (for tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    private func startForwarder(_ registration: Registration, subscriber id: UUID) {
        guard let continuation = state.withLock({ $0.subscribers[id]?.continuation }) else { return }
        let source = registration.engine.events()
        let token = UUID()
        let engineID = registration.id
        let task = Task { [weak self] in
            for await event in source {
                self?.learn(event, from: engineID)
                continuation.yield(event)
            }
            self?.forwarderEnded(engineID: engineID, token: token, subscriber: id)
        }
        let replaced: Task<Void, Never>? = state.withLock { state in
            guard var subscriber = state.subscribers[id] else {
                task.cancel()
                return nil
            }
            if subscriber.endedEarly.remove(token) != nil {
                state.subscribers[id] = subscriber
                return nil
            }
            let old = subscriber.forwarders[engineID]?.task
            subscriber.forwarders[engineID] = Forwarder(token: token, task: task)
            state.subscribers[id] = subscriber
            return old
        }
        replaced?.cancel()
        finishIfIdle(id)
    }

    private func forwarderEnded(engineID: String, token: UUID, subscriber id: UUID) {
        state.withLock { state in
            guard var subscriber = state.subscribers[id] else { return }
            if subscriber.forwarders[engineID]?.token == token {
                subscriber.forwarders[engineID] = nil
            } else if !subscriber.forwarders.values.contains(where: { $0.token == token }) {
                subscriber.endedEarly.insert(token)
            }
            state.subscribers[id] = subscriber
        }
        finishIfIdle(id)
    }

    /// Ends a stream whose engines have all stopped sending.
    private func finishIfIdle(_ id: UUID) {
        let continuation: AsyncStream<EngineEvent>.Continuation? = state.withLock { state in
            guard let subscriber = state.subscribers[id], !subscriber.starting, subscriber.forwarders.isEmpty else { return nil }
            state.subscribers[id] = nil
            return subscriber.continuation
        }
        continuation?.finish()
    }

    private func dropSubscriber(_ id: UUID) {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            let tasks = state.subscribers[id]?.forwarders.values.map(\.task) ?? []
            state.subscribers[id] = nil
            return tasks
        }
        for task in tasks { task.cancel() }
    }

    // MARK: Fork and rewind

    /// True when every engine that can rewind also restores files. Use `rewindRestoresFiles(for:)` for one session.
    public var rewindRestoresFiles: Bool {
        let controls = registrations.compactMap { $0.engine as? any EngineHistoryControl }
        return !controls.isEmpty && controls.allSatisfy(\.rewindRestoresFiles)
    }

    public func rewindRestoresFiles(for sessionID: String) async -> Bool {
        guard let registration = try? await owner(of: sessionID),
              let control = registration.engine as? any EngineHistoryControl else { return false }
        return control.rewindRestoresFiles
    }

    public func fork(_ sessionID: String, atMessageID messageID: String?) async throws -> EngineSession {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineHistoryControl).self, of: registration, feature: "be forked")
        let session = try await control.fork(sessionID, atMessageID: messageID)
        record(session.id, owner: registration.id)
        return session
    }

    public func rewind(_ sessionID: String, toBeforeMessageID messageID: String) async throws {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineHistoryControl).self, of: registration, feature: "be rewound")
        try await control.rewind(sessionID, toBeforeMessageID: messageID)
    }

    // MARK: Effort and fast mode

    public func modelOptions(for model: ModelRef) async throws -> ModelOptions {
        let registration = registration(forProvider: model.providerID)
        let control = try capability((any EngineModelOptionsControl).self, of: registration, feature: "change effort or fast mode")
        return try await control.modelOptions(for: model)
    }

    public func setEffort(_ sessionID: String, effort: EffortLevel?) async throws {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineModelOptionsControl).self, of: registration, feature: "change effort")
        try await control.setEffort(sessionID, effort: effort)
    }

    public func setFastMode(_ sessionID: String, enabled: Bool) async throws {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineModelOptionsControl).self, of: registration, feature: "use fast mode")
        try await control.setFastMode(sessionID, enabled: enabled)
    }

    // MARK: Slash commands and skills

    /// Commands and skills of every engine for a folder, the fallback engine's first; a name two engines share is
    /// listed once. Use `commands(directory:forSession:)` for the commands one session can run.
    public func commands(directory: String?) async throws -> [EngineCommand] {
        let answers = try await gather { registration -> [EngineCommand] in
            guard let control = registration.engine as? any EngineCommandsControl else { return [] }
            return try await control.commands(directory: directory)
        }
        var seen = Set<String>()
        return answers.flatMap(\.1).filter { seen.insert($0.id).inserted }
    }

    /// The commands and skills of the engine that owns the session.
    public func commands(directory: String?, forSession sessionID: String) async throws -> [EngineCommand] {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineCommandsControl).self, of: registration, feature: "run slash commands")
        return try await control.commands(directory: directory)
    }

    public func runCommand(_ sessionID: String, name: String, arguments: String) async throws {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineCommandsControl).self, of: registration, feature: "run slash commands")
        try await control.runCommand(sessionID, name: name, arguments: arguments)
    }
}

// MARK: Steering and fork availability (composer queue and side questions)

extension EngineRouter: EngineSteeringControl, EngineForkAvailability {
    public func steer(_ sessionID: String, text: String, files: [URL]) async throws {
        let registration = try await owner(of: sessionID)
        let control = try capability((any EngineSteeringControl).self, of: registration, feature: "take messages during a turn")
        try await control.steer(sessionID, text: text, files: files)
    }

    public func canSteer(_ sessionID: String) -> Bool {
        (knownOwner(sessionID)?.engine as? any EngineSteeringControl)?.canSteer(sessionID) ?? false
    }

    public func queuedDelivery(for sessionID: String) -> QueuedDelivery {
        (knownOwner(sessionID)?.engine as? any EngineSteeringControl)?.queuedDelivery(for: sessionID) ?? .inOrder
    }

    public func canFork(_ sessionID: String) -> Bool {
        guard let engine = knownOwner(sessionID)?.engine else { return false }
        if let availability = engine as? any EngineForkAvailability { return availability.canFork(sessionID) }
        return engine is any EngineHistoryControl
    }
}
