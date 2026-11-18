import Foundation
import Synchronization

/// The real `OpenCodeAPI`: talks to the OpenCode 2.3 background service over HTTP with Basic auth
/// (user `opencode`, the service password) and reads its live event stream.
///
/// Location-scoped calls (models, providers, connectors) use `defaultDirectory`, or the engine's own
/// default location when it is `nil`. Methods that take a `directory:` let callers ask about one project.
public final class OpenCodeClient: OpenCodeAPI, Sendable {
    public let baseURL: URL
    /// Project folder used for location-scoped calls that do not name one.
    public let defaultDirectory: String?

    private let authorization: String
    private let session: URLSession
    private let streamSession: URLSession
    private let state = Mutex(State())
    /// Plans waiting for an answer and the live event streams that hear about them (`OpenCodeClient+Interactions`).
    let interactions = Mutex(OpenCodeInteractionState())

    private struct State {
        var modelCache: [String: (date: Date, models: [Wire.Model])] = [:]
        var permissionFirstSeen: [String: Date] = [:]
    }

    /// How a prompt joins a running turn: `steer` adds it to the current turn, `queue` waits for the next one.
    public enum Delivery: String, Sendable {
        case steer
        case queue
    }

    public init(baseURL: URL, password: String, defaultDirectory: String? = nil,
                configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.defaultDirectory = defaultDirectory
        let token = Data("opencode:\(password)".utf8).base64EncodedString()
        self.authorization = "Basic \(token)"
        let requestConfiguration = configuration.copy() as! URLSessionConfiguration
        requestConfiguration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: requestConfiguration)
        let streamConfiguration = configuration.copy() as! URLSessionConfiguration
        // The event stream sends heartbeats; a long silence means the connection is gone.
        streamConfiguration.timeoutIntervalForRequest = 120
        streamConfiguration.timeoutIntervalForResource = 60 * 60 * 24 * 365
        self.streamSession = URLSession(configuration: streamConfiguration)
    }

    public convenience init(serviceFile: ServiceFile, defaultDirectory: String? = nil) {
        self.init(baseURL: serviceFile.url, password: serviceFile.password, defaultDirectory: defaultDirectory)
    }

    /// A client for the service described by `service.json`.
    public static func fromServiceFile(at url: URL = ServiceFile.defaultURL, defaultDirectory: String? = nil) throws -> OpenCodeClient {
        OpenCodeClient(serviceFile: try ServiceFile.read(from: url), defaultDirectory: defaultDirectory)
    }

    // MARK: Server

    public func serverInfo() async throws -> (version: String, url: URL) {
        let info: Wire.ServerInfo = try await get("/api/info")
        return (info.version, baseURL)
    }

    /// Sessions running right now (the engine's foreground drains).
    public func activeSessionIDs() async throws -> Set<String> {
        let response: Wire.DataEnvelope<[String: JSONValue]> = try await get("/api/session/active")
        return Set(response.data.keys)
    }

    /// Project folders the engine has loaded.
    public func loadedDirectories() async throws -> [String] {
        let locations: [Wire.LocationRef] = try await get("/api/debug/location")
        return locations.map(\.directory)
    }

    // MARK: Sessions

    public func listSessions() async throws -> [EngineSession] {
        try await sessions(query: [])
    }

    /// Sessions filtered the way `GET /api/session` allows (`directory`, `parentID`, `archived`, `search`).
    public func sessions(directory: String? = nil, rootsOnly: Bool = false, archived: Bool? = nil, search: String? = nil,
                         limit: Int = 2000) async throws -> [EngineSession] {
        var query: [URLQueryItem] = []
        if let directory { query.append(URLQueryItem(name: "directory", value: directory)) }
        if rootsOnly { query.append(URLQueryItem(name: "parentID", value: "null")) }
        if let archived { query.append(URLQueryItem(name: "archived", value: archived ? "true" : "false")) }
        if let search { query.append(URLQueryItem(name: "search", value: search)) }
        return try await sessions(query: query, limit: limit)
    }

    private func sessions(query: [URLQueryItem], limit: Int = 2000) async throws -> [EngineSession] {
        let pages: [Wire.Lossy<Wire.Session>] = try await paged("/api/session", query: query, pageSize: 100, limit: limit)
        return pages.compactMap(\.value).map(EngineSession.init(wire:))
    }

    public func session(_ sessionID: String) async throws -> EngineSession {
        let response: Wire.DataEnvelope<Wire.Session> = try await get("/api/session/\(sessionID)")
        return EngineSession(wire: response.data)
    }

    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                              parentID: String?) async throws -> EngineSession {
        try await createSession(directory: directory, model: model, agent: agent, permissionMode: permissionMode,
                                parentID: parentID, title: nil, metadata: nil)
    }

    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                              parentID: String?, title: String?, metadata: JSONValue?) async throws -> EngineSession {
        var body: [String: JSONValue] = [
            "location": ["directory": .string(directory)],
            "permissions": try JSONValue(encoding: PermissionRules.ruleset(for: permissionMode)),
        ]
        if let model { body["model"] = try JSONValue(encoding: model.wire) }
        if let agent {
            body["agent"] = .string(agent)
        } else if permissionMode == .plan {
            body["agent"] = .string(PermissionRules.agent(for: .plan))
        }
        if let parentID { body["parentID"] = .string(parentID) }
        if let title { body["title"] = .string(title) }
        if let metadata { body["metadata"] = metadata }
        let response: Wire.DataEnvelope<Wire.Session> = try await send("POST", "/api/session", body: .object(body))
        return EngineSession(wire: response.data)
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await sendIgnoringBody("DELETE", "/api/session/\(sessionID)")
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        try await sendIgnoringBody("PATCH", "/api/session/\(sessionID)", body: ["title": .string(title)])
    }

    public func setArchived(_ sessionID: String, archived: Bool) async throws {
        try await sendIgnoringBody("PATCH", "/api/session/\(sessionID)", body: ["archived": .bool(archived)])
    }

    /// Sets the session's ruleset and the ruleset of every subagent session under it. OpenCode copies a parent's
    /// rules into a child when the child is created, but later changes to the parent do not reach existing children
    /// (and a parent can send follow-ups to an existing child), so they are updated here as well.
    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws {
        let rules = try JSONValue(encoding: PermissionRules.ruleset(for: mode))
        try await sendIgnoringBody("PATCH", "/api/session/\(sessionID)", body: ["permissions": rules])
        try await switchAgentForMode(sessionID, mode: mode)
        var pending = [sessionID]
        var seen: Set<String> = [sessionID]
        while let parent = pending.popLast() {
            for child in try await children(parent) where seen.insert(child.id).inserted {
                try await sendIgnoringBody("PATCH", "/api/session/\(child.id)", body: ["permissions": rules])
                pending.append(child.id)
            }
        }
    }

    /// The session's own permission rules (empty when it has none, which means the agent's rules apply).
    public func permissionRules(_ sessionID: String) async throws -> [PermissionRule] {
        let response: Wire.DataEnvelope<Wire.Session> = try await get("/api/session/\(sessionID)")
        return (response.data.permissions ?? []).map { PermissionRule($0.action, $0.resource, $0.effect) }
    }

    /// The Ensemble mode a session's rules match, or `nil` when they were set some other way.
    public func permissionMode(_ sessionID: String) async throws -> PermissionMode? {
        PermissionRules.mode(for: try await permissionRules(sessionID))
    }

    public func switchModel(_ sessionID: String, model: ModelRef) async throws {
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/model", body: ["model": try JSONValue(encoding: model.wire)])
    }

    /// A staged revert (a rewind Redo can still undo) hides its message and everything after it, as OpenCode's own
    /// views do (`OpenCodeClient+Rewind.swift`).
    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        async let boundary = try? stagedRevertMessageID(sessionID)
        let all = try await messages(sessionID)
        return TranscriptMapper.items(from: Self.hidingStagedRevert(all, boundary: await boundary ?? nil))
    }

    /// Raw engine messages, oldest first (the endpoint defaults to newest first, so `order=asc` is set).
    func messages(_ sessionID: String, type: String? = nil) async throws -> [Wire.Message] {
        var query = [URLQueryItem(name: "order", value: "asc")]
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        let items: [Wire.Lossy<Wire.Message>] = try await paged("/api/session/\(sessionID)/message", query: query, pageSize: 200, limit: 100_000)
        return items.compactMap(\.value)
    }

    public func children(_ sessionID: String) async throws -> [EngineSession] {
        try await sessions(query: [URLQueryItem(name: "parentID", value: sessionID)])
    }

    // MARK: Talking

    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        try await prompt(sessionID, text: text, files: files, delivery: nil)
    }

    public func prompt(_ sessionID: String, text: String, files: [URL], delivery: Delivery?) async throws {
        var body: [String: JSONValue] = ["text": .string(text)]
        if !files.isEmpty {
            body["files"] = .array(try files.map { url in
                guard url.isFileURL else { throw OpenCodeError.invalidArgument("Attachments must be local files: \(url)") }
                return ["uri": .string(url.absoluteString), "name": .string(url.lastPathComponent)]
            })
        }
        if let delivery { body["delivery"] = .string(delivery.rawValue) }
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/prompt", body: .object(body))
    }

    /// With `wake` the agent responds now (and a busy agent gets it in its current turn). Without it the text waits
    /// in the session inbox and is delivered with the next prompt; it is not in the transcript until then.
    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        try await injectSynthetic(sessionID, text: text, wake: wake, metadata: nil)
    }

    /// `metadata` is stored on the synthetic message (for example the sending agent), and comes back in the transcript.
    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool, metadata: JSONValue?) async throws {
        var body: [String: JSONValue] = ["text": .string(text), "resume": .bool(wake)]
        if let metadata { body["metadata"] = metadata }
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/synthetic", body: .object(body))
    }

    public func interrupt(_ sessionID: String) async throws {
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/interrupt")
    }

    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        var body: [String: JSONValue] = ["decision": .string(decision.rawValue)]
        if let message { body["message"] = .string(message) }
        try await sendIgnoringBody("POST", "/api/session/\(sessionID)/permission/\(requestID)/reply", body: .object(body))
    }

    /// Open permission prompts in every project the engine has loaded (requests are kept per location).
    public func pendingPermissions() async throws -> [PermissionRequest] {
        var directories = (try? await loadedDirectories()) ?? []
        if directories.isEmpty { directories = [defaultDirectory].compactMap { $0 } }
        var wire: [Wire.PermissionRequest] = []
        if directories.isEmpty {
            let response: Wire.LocationEnvelope<[Wire.PermissionRequest]> = try await get("/api/permission/request")
            wire = response.data
        } else {
            await withTaskGroup(of: [Wire.PermissionRequest].self) { group in
                for directory in directories {
                    group.addTask {
                        // A location that was just unloaded answers with an error; it has no open prompts.
                        let response: Wire.LocationEnvelope<[Wire.PermissionRequest]>? =
                            try? await self.get("/api/permission/request", query: Self.location(directory))
                        return response?.data ?? []
                    }
                }
                for await batch in group { wire += batch }
            }
        }
        var seen = Set<String>()
        let unique = wire.filter { seen.insert($0.id).inserted }
        let questions = await pendingForms(directories: directories)
        let plans = interactions.withLock { Array($0.pendingPlans.values) }
        let now = Date()
        let firstSeen = state.withLock { state -> [String: Date] in
            for request in unique where state.permissionFirstSeen[request.id] == nil {
                state.permissionFirstSeen[request.id] = now
            }
            let open = Set(unique.map(\.id))
            state.permissionFirstSeen = state.permissionFirstSeen.filter { open.contains($0.key) }
            return state.permissionFirstSeen
        }
        return (unique.map { PermissionRequest(wire: $0, created: firstSeen[$0.id] ?? now) } + questions + plans)
            .sorted { $0.created < $1.created }
    }

    /// Open permission prompts of one session.
    public func pendingPermissions(sessionID: String) async throws -> [PermissionRequest] {
        let response: Wire.DataEnvelope<[Wire.PermissionRequest]> = try await get("/api/session/\(sessionID)/permission")
        return response.data.map { PermissionRequest(wire: $0) }
    }

    // MARK: Panels

    public func context(_ sessionID: String) async throws -> ContextBreakdown {
        async let sessionInfo: Wire.DataEnvelope<Wire.Session> = get("/api/session/\(sessionID)")
        async let contextMessages: Wire.DataEnvelope<[Wire.Lossy<Wire.Message>]> = get("/api/session/\(sessionID)/context")
        let info = try await sessionInfo.data
        let messages = try await contextMessages.data.compactMap(\.value)
        var limit: Wire.ModelLimit?
        let lastModel = messages.last(where: { $0.type == "assistant" })?.model ?? info.model
        if let model = lastModel {
            let models = (try? await wireModels(directory: info.location?.directory)) ?? []
            limit = models.first { $0.providerID == model.providerID && $0.id == model.id }?.limit
        }
        return ContextEstimator.breakdown(messages: messages, contextLimit: limit?.context, outputLimit: limit?.output)
    }

    /// Files changed over the whole session (from its first prompt to its newest one).
    public func changedFiles(_ sessionID: String) async throws -> [FileChange] {
        async let first: Wire.Page<Wire.Message> = get("/api/session/\(sessionID)/message", query: [
            URLQueryItem(name: "type", value: "user"), URLQueryItem(name: "order", value: "asc"), URLQueryItem(name: "limit", value: "1"),
        ])
        async let last: Wire.Page<Wire.Message> = get("/api/session/\(sessionID)/message", query: [
            URLQueryItem(name: "type", value: "user"), URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "limit", value: "1"),
        ])
        guard let from = try await first.data.first?.id, let to = try await last.data.first?.id else { return [] }
        let response: Wire.DataEnvelope<[Wire.FileDiff]> = try await get("/api/session/\(sessionID)/diff", query: [
            URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to), URLQueryItem(name: "context", value: "3"),
        ])
        return response.data.map(FileChange.init(wire:))
    }

    public func connectors() async throws -> [ConnectorInfo] {
        try await connectors(directory: defaultDirectory)
    }

    public func connectors(directory: String?) async throws -> [ConnectorInfo] {
        let response: Wire.LocationEnvelope<[Wire.McpServer]> = try await get("/api/mcp", query: Self.location(directory))
        return response.data.map(ConnectorInfo.init(wire:))
    }

    /// Asks the engine to publish `filesystem.changed` for one file (relative to `directory`) for the next 24 hours.
    public func watchFile(_ path: String, directory: String) async throws {
        try await sendIgnoringBody("POST", "/api/experimental/fs/watch", query: Self.location(directory), body: ["path": .string(path)])
    }

    // MARK: Models and keys

    public func models() async throws -> [ModelInfo] {
        try await models(directory: defaultDirectory)
    }

    /// Models with an active provider for `directory`, the default model first.
    public func models(directory: String?) async throws -> [ModelInfo] {
        async let providerList: Wire.LocationEnvelope<[Wire.Provider]> = get("/api/provider", query: Self.location(directory))
        async let defaultResponse: Wire.LocationEnvelope<Wire.Model?> = get("/api/model/default", query: Self.location(directory))
        let models = try await wireModels(directory: directory, refresh: true)
        let names = Dictionary((try? await providerList.data)?.map { ($0.id, $0.name) } ?? [], uniquingKeysWith: { a, _ in a })
        let defaultModel = try? await defaultResponse.data
        var infos = models.map { ModelInfo(wire: $0, providerName: names[$0.providerID]) }
        if let defaultModel, let index = infos.firstIndex(where: { $0.ref.providerID == defaultModel.providerID && $0.ref.id == defaultModel.id }) {
            infos.insert(infos.remove(at: index), at: 0)
        }
        return infos
    }

    /// The model a new session uses when none is chosen.
    public func defaultModel(directory: String? = nil) async throws -> ModelRef? {
        let response: Wire.LocationEnvelope<Wire.Model?> = try await get("/api/model/default", query: Self.location(directory ?? defaultDirectory))
        return response.data.map { ModelRef(providerID: $0.providerID, id: $0.id) }
    }

    func wireModels(directory: String?, refresh: Bool = false) async throws -> [Wire.Model] {
        let key = directory ?? ""
        if !refresh, let cached = state.withLock({ $0.modelCache[key] }), Date().timeIntervalSince(cached.date) < 60 {
            return cached.models
        }
        var response: Wire.LocationEnvelope<[Wire.Model]> = try await get("/api/model", query: Self.location(directory))
        if response.data.isEmpty {
            // A location's first request can answer before its providers have loaded.
            try await Task.sleep(for: .milliseconds(500))
            response = try await get("/api/model", query: Self.location(directory))
        }
        let models = response.data
        state.withLock { $0.modelCache[key] = (Date(), models) }
        return models
    }

    public func providers() async throws -> [ProviderInfo] {
        try await providers(directory: defaultDirectory)
    }

    public func providers(directory: String?) async throws -> [ProviderInfo] {
        var response: Wire.LocationEnvelope<[Wire.Integration]> = try await get("/api/integration", query: Self.location(directory))
        if response.data.isEmpty {
            // The first request for a location answers before its provider catalogue has loaded.
            try await Task.sleep(for: .milliseconds(500))
            response = try await get("/api/integration", query: Self.location(directory))
        }
        return ProviderList.providers(from: response.data)
    }

    /// Stores an API key for a provider (an OpenCode integration with the same id, e.g. `anthropic`, `openai`,
    /// `xai`, `google`, `openrouter`). The new key becomes the provider's active credential.
    public func setAPIKey(providerID: String, key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenCodeError.invalidArgument("The API key is empty.") }
        try await sendIgnoringBody("POST", "/api/integration/\(Self.pathComponent(providerID))/connect/key",
                                   query: Self.location(defaultDirectory),
                                   body: ["key": .string(trimmed), "label": "Ensemble"])
    }

    /// Removes every stored credential for the provider.
    public func removeAPIKey(providerID: String) async throws {
        let response: Wire.DataEnvelope<[Wire.Credential]> = try await get("/api/credential")
        for credential in response.data where credential.integrationID == providerID {
            try await sendIgnoringBody("DELETE", "/api/credential/\(Self.pathComponent(credential.id))")
        }
    }

    // MARK: Schedules

    /// Schedules on every root session (the engine keeps schedules per session). Sessions whose project does not
    /// enable `experimental.schedules` are skipped.
    public func schedules() async throws -> [ScheduleInfo] {
        let sessions = try await self.sessions(query: [URLQueryItem(name: "parentID", value: "null")], limit: 300)
        var results: [ScheduleInfo] = []
        try await withThrowingTaskGroup(of: [ScheduleInfo].self) { group in
            var iterator = sessions.makeIterator()
            func addNext() {
                guard let session = iterator.next() else { return }
                group.addTask {
                    guard let response: Wire.DataEnvelope<[Wire.Schedule]> = try? await self.get(
                        "/api/experimental/schedule", query: [URLQueryItem(name: "sessionID", value: session.id)]) else { return [] }
                    return response.data.map { ScheduleInfo(wire: $0, directory: session.directory) }
                }
            }
            for _ in 0..<8 { addNext() }
            while let batch = try await group.next() {
                results += batch
                addNext()
            }
        }
        return results.sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
    }

    public func schedules(sessionID: String) async throws -> [ScheduleInfo] {
        async let sessionInfo = session(sessionID)
        let response: Wire.DataEnvelope<[Wire.Schedule]> = try await get(
            "/api/experimental/schedule", query: [URLQueryItem(name: "sessionID", value: sessionID)])
        let directory = (try? await sessionInfo.directory) ?? ""
        return response.data.map { ScheduleInfo(wire: $0, directory: directory) }
    }

    /// Creates a session for the schedule (Auto permission mode, titled `title`) and schedules `prompt` on it.
    /// `schedule` is a cron expression, `every 30 minutes`, `in 2 hours` or `at 2026-12-01T09:00`.
    /// The project must enable `experimental.schedules` in its OpenCode config, or this throws a 403 error.
    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        guard let when = ScheduleText.when(from: schedule) else {
            throw OpenCodeError.invalidArgument("Use a cron expression, \"every 30 minutes\", \"in 2 hours\" or \"at <date>\".")
        }
        let session = try await createSession(directory: directory, model: model, agent: nil, permissionMode: .auto, parentID: nil,
                                              title: title, metadata: ["ensemble": ["schedule": true]])
        do {
            let body: JSONValue = [
                "sessionID": .string(session.id),
                "name": .string(title),
                "when": try JSONValue(encoding: when),
                "prompt": .string(prompt),
            ]
            let response: Wire.DataEnvelope<Wire.Schedule> = try await send("POST", "/api/experimental/schedule", body: body)
            return ScheduleInfo(wire: response.data, directory: session.directory)
        } catch {
            try? await deleteSession(session.id)
            throw error
        }
    }

    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {
        try await sendIgnoringBody("POST", "/api/experimental/schedule/\(scheduleID)/\(paused ? "pause" : "resume")")
    }

    public func deleteSchedule(_ scheduleID: String) async throws {
        try await sendIgnoringBody("DELETE", "/api/experimental/schedule/\(scheduleID)")
    }

    // MARK: Events

    public func events() -> AsyncStream<EngineEvent> {
        events(types: [])
    }

    /// Live events, optionally only some types (`session.text.delta`, ...). Each (re)connection first yields
    /// `.other(type: "server.connected")`; the engine does not replay missed events, so refresh state then.
    public func events(types: [String]) -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(20_000))
        let task = Task { [self] in
            await self.runEventLoop(types: types, continuation: continuation)
        }
        // Full streams also hear the plans this client makes itself (`OpenCodeClient+Interactions`).
        let subscriber = types.isEmpty ? addInteractionSubscriber(continuation) : nil
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            if let subscriber { self?.removeInteractionSubscriber(subscriber) }
        }
        return stream
    }

    private func runEventLoop(types: [String], continuation: AsyncStream<EngineEvent>.Continuation) async {
        var backoff: Double = 0.5
        var lastEventID: String?
        var decoder = EngineEventDecoder()
        while !Task.isCancelled {
            do {
                var request = try makeRequest("GET", "/api/event", query: types.map { URLQueryItem(name: "types", value: $0) })
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
                let (bytes, response) = try await streamSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw OpenCodeError.invalidResponse("no HTTP response") }
                guard http.statusCode == 200 else { throw OpenCodeError.http(status: http.statusCode, tag: nil, message: "event stream") }
                var parser = SSEParser()
                for try await byte in bytes {
                    guard let message = parser.feed(byte: byte) else { continue }
                    backoff = 0.5
                    if let id = message.id { lastEventID = id }
                    for output in decoder.decode(message.data) {
                        switch output {
                        case .event(let event):
                            continuation.yield(event)
                            if types.isEmpty { await afterEvent(event) }
                        case .refreshSession(let id, let type):
                            if let updated = try? await session(id) {
                                continuation.yield(.sessionUpdated(updated))
                            } else {
                                continuation.yield(.other(type: type))
                            }
                        }
                    }
                }
            } catch {
                if Task.isCancelled { break }
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
        continuation.finish()
    }

    // MARK: HTTP

    static func location(_ directory: String?) -> [URLQueryItem] {
        guard let directory else { return [] }
        return [URLQueryItem(name: "location[directory]", value: directory)]
    }

    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeError.invalidArgument("Bad engine URL")
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { item in
                let name = item.name.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? item.name
                let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? ""
                return "\(name)=\(value)"
            }.joined(separator: "&")
        }
        guard let url = components.url else { throw OpenCodeError.invalidArgument("Bad request path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.invalidResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(Wire.ErrorBody.self, from: data)
            let message = body?.message ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw OpenCodeError.http(status: http.statusCode, tag: body?.tag, message: message)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query)
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> T {
        let data = try await perform(try makeRequest(method, path, query: query, body: body))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenCodeError.decoding("\(method) \(path): \(Self.describe(error))")
        }
    }

    func sendIgnoringBody(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws {
        _ = try await perform(try makeRequest(method, path, query: query, body: body))
    }

    /// Follows `cursor.next` until a short page or `limit` items.
    private func paged<T: Decodable>(_ path: String, query: [URLQueryItem], pageSize: Int, limit: Int) async throws -> [T] {
        var items: [T] = []
        var cursor: String?
        repeat {
            var pageQuery = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor {
                // The engine rejects `order` together with a cursor; the cursor already carries it.
                pageQuery += query.filter { $0.name != "order" }
                pageQuery.append(URLQueryItem(name: "cursor", value: cursor))
            } else {
                pageQuery += query
            }
            let page: Wire.Page<T> = try await get(path, query: pageQuery)
            items += page.data
            guard page.data.count >= pageSize, let next = page.cursor?.next, next != cursor else { break }
            cursor = next
        } while items.count < limit
        return items
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            return "\(context.debugDescription) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            return String(describing: error)
        }
    }
}
