#if os(macOS)
import Foundation

/// The ACP engine's state for one tool: saved sessions, the tool's processes (normally one, plus one for Bypass
/// sessions when the tool has a skip-permissions switch), open sessions, turns in flight and open permission prompts.
actor ACPEngineCore {
    /// Which process a session runs in. Sessions share a process unless they need different launch switches.
    struct ConnectionKey: Hashable, Sendable {
        var bypass: Bool
        var skipWorkspaceSettings: Bool
        static let normal = ConnectionKey(bypass: false, skipWorkspaceSettings: false)
    }

    struct Connection {
        let process: ACPProcess
        var info: ACPAgentInfo?
        var nextID = 1
        var waiters: [ACPRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    }

    struct PendingPrompt: Sendable {
        var blocks: [JSONValue]
        /// Board messages queued with `injectSynthetic(wake: false)`, sent first and shown as notices.
        var queuedSynthetic: [String]
        var text: String
        var synthetic: Bool
    }

    struct RunningTurn: Sendable {
        let token: UUID
        var requestID: ACPRequestID?
        var interrupting = false
    }

    struct Live {
        var transcript: ACPTranscriptState
        /// The rows cover the whole conversation (a new session, or one replayed with `session/load`).
        var transcriptLoaded: Bool
        var connection: ConnectionKey?
        var generation: Int?
        var opened = false
        var replaying = false
        var currentModeID: String?
        var modes: [ACPMode] = []
        var configOptions: [ACPConfigOption] = []
        var models: [ACPConfigChoice] = []
        var currentModelID: String?
        var commands: [ACPCommand] = []
        var running: RunningTurn?
        var queue: [PendingPrompt] = []
        /// Move to another process (permission mode change across the Bypass switch) once the turn ends.
        var reopenWhenIdle = false
        /// The session's settings changed while a turn ran; apply them before the next turn.
        var settingsDirty = false

        init(transcript: ACPTranscriptState, loaded: Bool) {
            self.transcript = transcript
            transcriptLoaded = loaded
        }

        func option(category: String) -> ACPConfigOption? {
            configOptions.first { $0.category == category } ?? configOptions.first { $0.id == category }
        }
    }

    struct PendingPermission: Sendable {
        let requestID: String
        let rpcID: ACPRequestID
        let connection: ConnectionKey
        let generation: Int
        let sessionID: String
        let ask: ACPPermissionAsk
        /// What "always" remembers; nil when it allows this request only.
        let rule: ACPAlwaysRule?
        let request: PermissionRequest
    }

    struct Catalog: Sendable {
        var date: Date
        var models: [ACPConfigChoice]
        var efforts: [String]
        /// True when models come from a `model` config option (set with `session/set_config_option`), false when from
        /// the older `models` field (set with `session/set_model`).
        var fromConfig: Bool
    }

    let configuration: ACPEngine.Configuration
    let broadcaster: ACPEventBroadcaster
    var definition: ACPAgentDefinition { configuration.agent }

    private var store: ACPSessionStore
    private var connections: [ConnectionKey: Connection] = [:]
    private var starting: [ConnectionKey: Task<Int, Error>] = [:]
    private var opening: [String: Task<Void, Error>] = [:]
    private var lives: [String: Live] = [:]
    private var agentSessions: [String: String] = [:]
    private var probeSessions: Set<String> = []
    private var pending: [String: PendingPermission] = [:]
    private var rules: [String: Set<String>] = [:]
    private var waitingForSlot: [String] = []
    private var generation = 0
    private var catalog: Catalog?
    private var contextSizes: [String: Int] = [:]
    private var commandsByDirectory: [String: [ACPCommand]] = [:]
    private var latestCommands: [ACPCommand]?
    private var auth: (date: Date, state: ACPAuthState)?
    private var lastCost: [String: Double] = [:]

    init(configuration: ACPEngine.Configuration, broadcaster: ACPEventBroadcaster) {
        self.configuration = configuration
        self.broadcaster = broadcaster
        store = ACPSessionStore(fileURL: configuration.storeURL, agentID: configuration.agent.id)
    }

    // MARK: Helpers

    func executableURL() -> URL? {
        ACPAgentRegistry.locate(definition, override: configuration.executablePath, environment: configuration.baseEnvironment)
    }

    private func save() { try? store.save() }

    private func emit(_ event: EngineEvent) { broadcaster.yield(event) }

    private func emit(_ events: [EngineEvent]) { for event in events { broadcaster.yield(event) } }

    private func record(_ id: String) throws -> ACPSessionRecord {
        guard let record = store[id] else { throw ACPEngineError.unknownSession(id) }
        return record
    }

    private static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "..." : trimmed
    }

    private func connectionKey(for record: ACPSessionRecord) -> ConnectionKey {
        let bypass = record.permissionMode == .bypass && definition.bypassArguments != nil
        var skip = false
        if case .skippable = definition.workspaceSettings, !configuration.trust.isTrusted(record.directory) { skip = true }
        return ConnectionKey(bypass: bypass, skipWorkspaceSettings: skip)
    }

    private func isTrusted(_ directory: String) -> Bool {
        !definition.requiresTrustedFolder || configuration.trust.isTrusted(directory)
    }

    /// Throws when a session cannot run here: tool missing, folder gone, or folder not trusted.
    private func checkReady(_ record: ACPSessionRecord) throws {
        guard executableURL() != nil else {
            throw ACPEngineError.notInstalled(agent: definition.displayName, hint: definition.installHint)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ACPEngineError.invalidArgument("The project folder does not exist: \(record.directory)")
        }
        guard isTrusted(record.directory) else { throw ACPEngineError.folderNotTrusted(record.directory) }
    }

    private func liveSession(_ id: String) -> Live {
        if let live = lives[id] { return live }
        let record = store[id]
        let transcript = ACPTranscriptState(sessionID: id, directory: record?.directory ?? "",
                                            syntheticTexts: Set(record?.syntheticTexts ?? []))
        let live = Live(transcript: transcript, loaded: record?.agentSessionID == nil)
        lives[id] = live
        return live
    }

    // MARK: Connections

    private func connection(_ key: ConnectionKey) async throws -> Int {
        if let existing = connections[key], existing.process.isRunning, existing.info != nil { return existing.process.generation }
        if let task = starting[key] { return try await task.value }
        let task = Task { try await self.startConnection(key) }
        starting[key] = task
        defer { starting[key] = nil }
        return try await task.value
    }

    private func startConnection(_ key: ConnectionKey) async throws -> Int {
        if let old = connections.removeValue(forKey: key) { old.process.terminate() }
        guard let exe = executableURL() else {
            throw ACPEngineError.notInstalled(agent: definition.displayName, hint: definition.installHint)
        }
        var arguments = definition.arguments
        if key.bypass, let extra = definition.bypassArguments { arguments += extra }
        if key.skipWorkspaceSettings, case .skippable(let extra) = definition.workspaceSettings { arguments += extra }
        let forbidden = Set(definition.bypassArguments ?? [])
        arguments += configuration.extraArguments.filter { !forbidden.contains($0) }
        let directory = configuration.workDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        generation += 1
        let gen = generation
        let process = try ACPProcess.launch(executable: exe, arguments: arguments,
                                            environment: ACPEnvironment.environment(base: configuration.baseEnvironment, definition: definition),
                                            directory: directory, generation: gen)
        connections[key] = Connection(process: process)
        let lines = process.lines
        Task {
            for await line in lines { self.receive(line: line, key: key, generation: gen) }
            let status = await process.waitForExit()
            self.processExited(key: key, generation: gen, status: status)
        }
        let params: JSONValue = [
            "protocolVersion": .number(Double(acpProtocolVersion)),
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "ensemble", "title": "Ensemble", "version": .string(configuration.clientVersion)],
        ]
        let result: JSONValue
        do {
            result = try await call(key, generation: gen, method: "initialize", params: params, timeout: configuration.requestTimeout)
        } catch {
            process.terminate()
            connections[key] = nil
            throw error
        }
        let info = ACPAgentInfo(result: result)
        guard info.protocolVersion == acpProtocolVersion else {
            process.terminate()
            connections[key] = nil
            throw ACPEngineError.unsupportedProtocol(info.protocolVersion)
        }
        connections[key]?.info = info
        return gen
    }

    private func info(_ key: ConnectionKey) -> ACPAgentInfo? { connections[key]?.info }

    private func makeID(_ key: ConnectionKey) -> ACPRequestID {
        let next = connections[key]?.nextID ?? 1
        connections[key]?.nextID = next + 1
        return .number(next)
    }

    /// Sends a request and waits for its answer. `timeout` nil waits as long as it takes (prompts).
    private func call(_ key: ConnectionKey, generation gen: Int, id: ACPRequestID? = nil, method: String, params: JSONValue,
                      timeout: Duration?) async throws -> JSONValue {
        guard let connection = connections[key], connection.process.generation == gen else {
            throw ACPEngineError.processFailed("the agent is not running")
        }
        let requestID = id ?? makeID(key)
        let line = ACPMessage.request(id: requestID, method: method, params: params).lineData
        return try await withCheckedThrowingContinuation { continuation in
            connections[key]?.waiters[requestID] = continuation
            do {
                try connection.process.write(line)
            } catch {
                connections[key]?.waiters[requestID] = nil
                continuation.resume(throwing: error)
                return
            }
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    self.timeOut(key, generation: gen, id: requestID, method: method)
                }
            }
        }
    }

    private func timeOut(_ key: ConnectionKey, generation gen: Int, id: ACPRequestID, method: String) {
        guard connections[key]?.process.generation == gen, let waiter = connections[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: ACPEngineError.processFailed("no answer to \(method) in time"))
    }

    private func notify(_ key: ConnectionKey, method: String, params: JSONValue) {
        try? connections[key]?.process.write(ACPMessage.notification(method: method, params: params).lineData)
    }

    private func respond(_ key: ConnectionKey, generation gen: Int, id: ACPRequestID, result: JSONValue) {
        guard let connection = connections[key], connection.process.generation == gen else { return }
        try? connection.process.write(ACPMessage.response(id: id, result: result).lineData)
    }

    private func respondError(_ key: ConnectionKey, generation gen: Int, id: ACPRequestID, code: Int, message: String) {
        guard let connection = connections[key], connection.process.generation == gen else { return }
        try? connection.process.write(ACPMessage.failure(id: id, error: ACPRPCError(code: code, message: message)).lineData)
    }

    private func processExited(key: ConnectionKey, generation gen: Int, status: Int32) {
        guard let connection = connections[key], connection.process.generation == gen else { return }
        connections[key] = nil
        let tail = connection.process.stderrText.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        let message = tail.isEmpty ? "the agent exited with status \(status)" : String(tail.prefix(500))
        for (_, waiter) in connection.waiters { waiter.resume(throwing: ACPEngineError.processFailed(message)) }
        for (id, live) in lives where live.connection == key && live.generation == gen {
            lives[id]?.opened = false
        }
        for (requestID, prompt) in pending where prompt.connection == key && prompt.generation == gen {
            pending[requestID] = nil
            emit(.permissionReplied(sessionID: prompt.sessionID, requestID: requestID))
        }
    }

    func shutdown() {
        for (_, connection) in connections {
            for (_, waiter) in connection.waiters { waiter.resume(throwing: ACPEngineError.processFailed("Ensemble is quitting")) }
            connection.process.terminate()
        }
        connections = [:]
        for id in Array(lives.keys) { lives[id]?.opened = false }
    }

    // MARK: Reading

    private func receive(line: String, key: ConnectionKey, generation gen: Int) {
        guard connections[key]?.process.generation == gen, let message = ACPMessage.decode(line: line) else { return }
        switch message {
        case .response(let id, let result):
            connections[key]?.waiters.removeValue(forKey: id)?.resume(returning: result)
        case .failure(let id, let error):
            if let id { connections[key]?.waiters.removeValue(forKey: id)?.resume(throwing: error) }
        case .notification(let method, let params):
            if method == "session/update" { handleUpdate(params) }
        case .request(let id, let method, let params):
            if method == "session/request_permission" {
                handlePermission(id: id, params: params, key: key, generation: gen)
            } else {
                // Ensemble offers no file system, terminal or elicitation methods (none are advertised).
                respondError(key, generation: gen, id: id, code: ACPRPCError.methodNotFound, message: "\(method) is not supported by Ensemble")
            }
        }
    }

    private func handleUpdate(_ params: JSONValue) {
        guard let agentSessionID = params["sessionId"]?.acpText, let update = params["update"].flatMap(ACPSessionUpdate.init) else { return }
        if probeSessions.contains(agentSessionID) {
            switch update {
            case .availableCommands(let commands):
                latestCommands = commands
                commandsByDirectory[configuration.workDirectory.path] = commands
            case .configOptions(let options):
                updateCatalog(configOptions: options, models: [])
            default:
                break
            }
            return
        }
        guard let id = agentSessions[agentSessionID], var live = lives[id] else { return }
        switch update {
        case .availableCommands(let commands):
            live.commands = commands
            latestCommands = commands
            commandsByDirectory[live.transcript.directory] = commands
        case .currentMode(let mode):
            live.currentModeID = mode
        case .configOptions(let options):
            live.configOptions = options
            if let mode = options.first(where: { $0.category == "mode" })?.currentValue { live.currentModeID = mode }
            updateCatalog(configOptions: options, models: live.models)
        case .sessionInfo(let title):
            if let title, !title.isEmpty, var record = store[id], !record.titleIsCustom, record.title != title {
                record.title = title
                store[id] = record
                save()
                emit(.sessionUpdated(record.engineSession))
            }
        case .usage(let used, let size, let cost):
            if var record = store[id] {
                record.contextUsed = used
                if size > 0 {
                    record.contextSize = size
                    if let model = record.model?.id ?? live.option(category: "model")?.currentValue { contextSizes[model] = size }
                }
                store[id] = record
            }
            if let cost { lastCost[id] = cost }
        case .other:
            break
        default:
            let events = live.transcript.apply(update)
            if !live.replaying { emit(events) }
        }
        lives[id] = live
    }

    private func handlePermission(id rpcID: ACPRequestID, params: JSONValue, key: ConnectionKey, generation gen: Int) {
        guard let ask = ACPPermissionAsk(params: params), let sessionID = agentSessions[ask.agentSessionID],
              var live = lives[sessionID], let record = store[sessionID] else {
            respond(key, generation: gen, id: rpcID, result: ACPPermissionAsk.outcome(optionID: nil))
            return
        }
        var tool = ACPToolState(id: ask.toolCall?.id ?? "permission-\(rpcID)")
        if let call = ask.toolCall {
            let events = live.transcript.applyTool(call)
            if !live.replaying { emit(events) }
            tool = live.transcript.tools[call.id] ?? tool
        }
        lives[sessionID] = live
        // A cancelled turn answers every open prompt with "cancelled" (the protocol requires it).
        if live.running?.interrupting == true {
            respond(key, generation: gen, id: rpcID, result: ACPPermissionAsk.outcome(optionID: nil))
            return
        }
        let rule = tool.alwaysRule(directory: record.directory)
        if record.permissionMode == .bypass || rule.map({ rules[sessionID]?.contains($0.key) == true }) == true {
            respond(key, generation: gen, id: rpcID, result: ACPPermissionAsk.outcome(optionID: ask.option(for: .once)?.id))
            return
        }
        let requestID = "acp-perm-" + UUID().uuidString.lowercased()
        let request = ACPPermissionMapping.request(id: requestID, sessionID: sessionID, tool: tool, directory: record.directory)
        pending[requestID] = PendingPermission(requestID: requestID, rpcID: rpcID, connection: key, generation: gen, sessionID: sessionID,
                                               ask: ask, rule: rule, request: request)
        emit(.permissionAsked(request))
        emit(.activity(sessionID: sessionID, .waitingForPermission))
    }

    private func updateCatalog(configOptions: [ACPConfigOption], models: [ACPConfigChoice]) {
        let modelOption = configOptions.first { $0.category == "model" } ?? configOptions.first { $0.id == "model" }
        let effortOption = configOptions.first { $0.category == "thought_level" }
        if let modelOption, !modelOption.choices.isEmpty {
            catalog = Catalog(date: Date(), models: modelOption.choices, efforts: effortOption?.choices.map(\.value) ?? [], fromConfig: true)
        } else if !models.isEmpty {
            catalog = Catalog(date: Date(), models: models, efforts: effortOption?.choices.map(\.value) ?? [], fromConfig: false)
        }
    }

    // MARK: Sessions

    func listSessions() -> [EngineSession] { store.all.map(\.engineSession) }

    func createSession(directory: String, model: ModelRef?, permissionMode: PermissionMode, parentID: String?) throws -> EngineSession {
        if parentID != nil { throw ACPEngineError.notSupported("\(definition.displayName) sessions cannot have subagent sessions.") }
        if let model, model.providerID != definition.id {
            throw ACPEngineError.invalidArgument("\(model) is not a \(definition.displayName) model.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ACPEngineError.invalidArgument("The project folder does not exist: \(directory)")
        }
        guard isTrusted(directory) else { throw ACPEngineError.folderNotTrusted(directory) }
        let id = UUID().uuidString.lowercased()
        let record = ACPSessionRecord(id: id, agentID: definition.id, directory: directory, model: model, permissionMode: permissionMode)
        store[id] = record
        save()
        lives[id] = Live(transcript: ACPTranscriptState(sessionID: id, directory: directory), loaded: true)
        emit(.sessionCreated(record.engineSession))
        return record.engineSession
    }

    func deleteSession(_ id: String) async throws {
        let record = try record(id)
        if lives[id]?.running != nil { interrupt(id) }
        if let live = lives[id], live.opened, let key = live.connection, let gen = live.generation, let agentID = record.agentSessionID,
           let info = info(key) {
            if info.deleteSession {
                _ = try? await call(key, generation: gen, method: "session/delete", params: ["sessionId": .string(agentID)], timeout: .seconds(10))
            } else if info.closeSession {
                _ = try? await call(key, generation: gen, method: "session/close", params: ["sessionId": .string(agentID)], timeout: .seconds(10))
            }
        }
        if let agentID = record.agentSessionID { agentSessions[agentID] = nil }
        lives[id] = nil
        rules[id] = nil
        waitingForSlot.removeAll { $0 == id }
        clearPending(sessionID: id, answer: true)
        store.remove(id)
        save()
        emit(.sessionDeleted(sessionID: id))
    }

    func rename(_ id: String, title: String) throws {
        var record = try record(id)
        record.title = title
        record.titleIsCustom = !title.isEmpty
        record.updated = Date()
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
    }

    func setArchived(_ id: String, archived: Bool) throws {
        var record = try record(id)
        record.archived = archived
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
    }

    func setPermissionMode(_ id: String, mode: PermissionMode) async throws {
        var record = try record(id)
        record.permissionMode = mode
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        guard var live = lives[id], live.opened else { return }
        if live.connection != connectionKey(for: record) {
            if live.running != nil {
                live.reopenWhenIdle = true
                lives[id] = live
            } else {
                await closeOnAgent(id)
            }
            return
        }
        if live.running != nil {
            lives[id]?.settingsDirty = true
            return
        }
        try await applySettings(id, forceMode: true)
    }

    func switchModel(_ id: String, model: ModelRef) async throws {
        var record = try record(id)
        guard model.providerID == definition.id else {
            throw ACPEngineError.invalidArgument("\(model) is not a \(definition.displayName) model.")
        }
        record.model = model
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        try await applyLater(id)
    }

    func setEffort(_ id: String, effort: EffortLevel?) async throws {
        var record = try record(id)
        if let effort, let catalog, !catalog.efforts.isEmpty, !catalog.efforts.contains(effort.rawValue) {
            throw ACPEngineError.invalidArgument("\(definition.displayName) has no \(effort.label) effort level.")
        }
        if record.model == nil {
            guard let effort else { return }
            guard let current = lives[id]?.option(category: "model")?.currentValue else {
                throw ACPEngineError.invalidArgument("Pick a model before setting the effort.")
            }
            record.model = ModelRef(providerID: definition.id, id: current, variant: effort.rawValue)
        } else {
            record.model?.variant = effort?.rawValue
        }
        store[id] = record
        save()
        emit(.sessionUpdated(record.engineSession))
        try await applyLater(id)
    }

    private func applyLater(_ id: String) async throws {
        guard let live = lives[id], live.opened else { return }
        if live.running != nil {
            lives[id]?.settingsDirty = true
        } else {
            try await applySettings(id, forceMode: false)
        }
    }

    /// Closes the session in its agent process (it is reopened with `session/load` when needed).
    private func closeOnAgent(_ id: String) async {
        guard let live = lives[id], live.opened, let key = live.connection, let gen = live.generation else { return }
        lives[id]?.opened = false
        lives[id]?.reopenWhenIdle = false
        if let agentID = store[id]?.agentSessionID, info(key)?.closeSession == true {
            _ = try? await call(key, generation: gen, method: "session/close", params: ["sessionId": .string(agentID)], timeout: .seconds(10))
        }
    }

    // MARK: Opening sessions in the agent

    /// Makes sure the session is open in the right agent process, with Ensemble's model, effort and permission mode.
    private func ensureOpen(_ id: String) async throws {
        if let task = opening[id] { return try await task.value }
        let record = try record(id)
        let key = connectionKey(for: record)
        if let live = lives[id], live.opened, live.connection == key, let gen = live.generation,
           connections[key]?.process.generation == gen {
            return
        }
        let task = Task { try await self.open(id, key: key) }
        opening[id] = task
        defer { opening[id] = nil }
        try await task.value
    }

    private func open(_ id: String, key: ConnectionKey) async throws {
        var record = try record(id)
        try checkReady(record)
        if let live = lives[id], live.opened, live.connection != key { await closeOnAgent(id) }
        let gen = try await connection(key)
        guard let info = info(key) else { throw ACPEngineError.processFailed("the agent is not running") }
        _ = liveSession(id)
        // The folder with every symlink resolved: agy 1.5.10 runs shell commands in its own working folder, not the
        // project, when the session folder's path goes through a link (`/var/folders/...` is `/private/var/...`).
        let cwd = WorkspaceTrust.resolvedPath(record.directory) ?? record.directory
        let base: JSONValue = ["cwd": .string(cwd), "mcpServers": []]
        var setup: ACPSessionSetup?
        if let agentID = record.agentSessionID {
            agentSessions[agentID] = id
            var params = base
            if case .object(var object) = params { object["sessionId"] = .string(agentID); params = .object(object) }
            if info.loadSession {
                // Replays the conversation as updates; they rebuild the transcript and are not sent as live events.
                lives[id]?.transcript = ACPTranscriptState(sessionID: id, directory: record.directory, syntheticTexts: Set(record.syntheticTexts))
                lives[id]?.replaying = true
                do {
                    let result = try await call(key, generation: gen, method: "session/load", params: params, timeout: configuration.requestTimeout)
                    setup = ACPSessionSetup(result: result)
                    lives[id]?.transcript.finishReplay()
                    lives[id]?.transcriptLoaded = true
                } catch let error as ACPRPCError {
                    lives[id]?.transcript.finishReplay()
                    lives[id]?.transcript.appendNotice("The agent could not reopen the earlier conversation (\(error.message)), so this continues as a new one.")
                    lives[id]?.transcriptLoaded = true
                } catch {
                    lives[id]?.replaying = false
                    throw error
                }
                lives[id]?.replaying = false
            } else if info.resumeSession {
                do {
                    setup = ACPSessionSetup(result: try await call(key, generation: gen, method: "session/resume", params: params,
                                                                   timeout: configuration.requestTimeout))
                } catch is ACPRPCError {
                    lives[id]?.transcript.appendNotice("The agent could not reopen the earlier conversation, so this continues as a new one.")
                }
            } else {
                lives[id]?.transcript.appendNotice("This agent cannot reopen earlier conversations, so this continues as a new one.")
            }
            if setup == nil { agentSessions[agentID] = nil }
        }
        if setup == nil {
            let result: JSONValue
            do {
                result = try await call(key, generation: gen, method: "session/new", params: base, timeout: configuration.requestTimeout)
            } catch let error as ACPRPCError {
                throw mapAgentError(error)
            }
            let created = ACPSessionSetup(result: result)
            guard let agentID = created.sessionID else { throw ACPEngineError.processFailed("session/new returned no session id") }
            record = try self.record(id)
            record.agentSessionID = agentID
            store[id] = record
            save()
            agentSessions[agentID] = id
            if lives[id]?.transcriptLoaded == false { lives[id]?.transcriptLoaded = true }
            setup = created
        }
        if let setup, var live = lives[id] {
            if let options = setup.configOptions { live.configOptions = options }
            if !setup.modes.isEmpty { live.modes = setup.modes }
            live.currentModeID = setup.currentModeID ?? live.option(category: "mode")?.currentValue ?? live.currentModeID
            if !setup.models.isEmpty { live.models = setup.models }
            live.currentModelID = setup.currentModelID ?? live.currentModelID
            live.connection = key
            live.generation = gen
            live.opened = true
            live.transcriptLoaded = true
            live.reopenWhenIdle = false
            lives[id] = live
            updateCatalog(configOptions: live.configOptions, models: live.models)
        }
        // The agent's own defaults (for Antigravity, the user's permission preset and last model) never carry over:
        // the mode is set from Ensemble's permission mode every time a session opens.
        do {
            try await applySettings(id, forceMode: true)
        } catch {
            lives[id]?.opened = false
            throw error
        }
    }

    /// Sends the session's model, effort and permission mode to the agent. The mode is sent every time when
    /// `forceMode`, otherwise only when it differs; either way the agent must report it back, or this throws.
    private func applySettings(_ id: String, forceMode: Bool) async throws {
        let record = try record(id)
        guard let live = lives[id], live.opened, let key = live.connection, let gen = live.generation,
              let agentID = record.agentSessionID else { return }
        lives[id]?.settingsDirty = false
        let session = JSONValue.string(agentID)

        func setOption(_ option: ACPConfigOption, _ value: String) async throws {
            let result = try await call(key, generation: gen, method: "session/set_config_option",
                                        params: ["sessionId": session, "configId": .string(option.id), "value": .string(value)],
                                        timeout: configuration.requestTimeout)
            if let options = ACPConfigOption.list(result["configOptions"]), !options.isEmpty {
                lives[id]?.configOptions = options
                if let mode = options.first(where: { $0.category == "mode" })?.currentValue { lives[id]?.currentModeID = mode }
            } else if var current = lives[id] {
                if let index = current.configOptions.firstIndex(where: { $0.id == option.id }) { current.configOptions[index].currentValue = value }
                if option.category == "mode" { current.currentModeID = value }
                lives[id] = current
            }
        }

        do {
            if let model = record.model {
                if let option = lives[id]?.option(category: "model") {
                    guard option.choices.isEmpty || option.choices.contains(where: { $0.value == model.id }) else {
                        throw ACPEngineError.invalidArgument("\(model.id) is not available in \(definition.displayName).")
                    }
                    if option.currentValue != model.id { try await setOption(option, model.id) }
                } else if let models = lives[id]?.models, !models.isEmpty, lives[id]?.currentModelID != model.id {
                    _ = try await call(key, generation: gen, method: "session/set_model", params: ["sessionId": session, "modelId": .string(model.id)],
                                       timeout: configuration.requestTimeout)
                    lives[id]?.currentModelID = model.id
                }
                if let effort = model.variant, let option = lives[id]?.option(category: "thought_level"),
                   option.choices.contains(where: { $0.value == effort }), option.currentValue != effort {
                    try await setOption(option, effort)
                }
            }
            let modeOption = lives[id]?.configOptions.first { $0.category == "mode" }
            let available = modeOption.map { $0.choices.map(\.value) } ?? (lives[id]?.modes.map(\.id) ?? [])
            let wanted = available.isEmpty ? nil : ACPModes.modeID(for: record.permissionMode, definition: definition, available: available)
            // Fail closed: unless the session is Bypass, work is only sent once the agent runs in the mode
            // Ensemble asked for. An agent that offers no matching mode would otherwise keep its own default,
            // which can be a "proceed without asking" preset from the user's own config.
            if wanted == nil, record.permissionMode != .bypass {
                throw ACPEngineError.modeNotApplied(record.permissionMode.label)
            }
            if let wanted {
                if forceMode || lives[id]?.currentModeID != wanted {
                    if let modeOption {
                        try await setOption(modeOption, wanted)
                    } else {
                        _ = try await call(key, generation: gen, method: "session/set_mode", params: ["sessionId": session, "modeId": .string(wanted)],
                                           timeout: configuration.requestTimeout)
                        lives[id]?.currentModeID = wanted
                    }
                }
                // The answer (or a `current_mode_update` before it) must report the mode Ensemble asked for.
                if lives[id]?.currentModeID != wanted { throw ACPEngineError.modeNotApplied(wanted) }
            }
        } catch let error as ACPRPCError {
            throw mapAgentError(error)
        }
    }

    private func mapAgentError(_ error: ACPRPCError) -> ACPEngineError {
        let lower = error.message.lowercased()
        if error.code == ACPRPCError.authRequired || lower.contains("auth") && (lower.contains("required") || lower.contains("log in") || lower.contains("sign in"))
            || lower.contains("not logged in") || lower.contains("unauthenticated") {
            auth = (Date(), ACPAuthState(installed: true, version: auth?.state.version, signedIn: false))
            return .notSignedIn(agent: definition.displayName, hint: definition.signInHint)
        }
        return .agentError(code: error.code, message: error.message)
    }

    // MARK: Transcripts and panels

    func transcript(_ id: String) async throws -> [TranscriptItem] {
        let record = try record(id)
        let live = liveSession(id)
        if live.transcriptLoaded || record.agentSessionID == nil { return live.transcript.items }
        // Rebuilding history needs the agent (`session/load`); never start it in a folder that is not trusted.
        guard isTrusted(record.directory), executableURL() != nil, info(connectionKey(for: record))?.loadSession != false else {
            return live.transcript.items
        }
        do { try await ensureOpen(id) } catch {}
        return lives[id]?.transcript.items ?? []
    }

    func changedFiles(_ id: String) throws -> [FileChange] {
        _ = try record(id)
        return lives[id]?.transcript.changedFiles() ?? []
    }

    func context(_ id: String) throws -> ContextBreakdown {
        let record = try record(id)
        let size = record.contextSize ?? record.model.flatMap { contextSizes[$0.id] } ?? 0
        let used = record.contextUsed ?? 0
        var categories = [ContextBreakdown.Category(key: "messages", label: "Messages", tokens: used)]
        if size > used { categories.append(ContextBreakdown.Category(key: "free", label: "Free space", tokens: size - used)) }
        return ContextBreakdown(usedTokens: used, limitTokens: size, categories: categories)
    }

    // MARK: Talking

    func send(_ id: String, text: String, files: [URL], synthetic: Bool) throws {
        var record = try record(id)
        try checkReady(record)
        let queued = record.queuedSynthetic
        var blocks: [JSONValue] = queued.map(ACPContentBlock.text)
        if !text.isEmpty { blocks.append(ACPContentBlock.text(text)) }
        let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        let canImage = info(connectionKey(for: record))?.promptImage ?? true
        for url in files {
            guard url.isFileURL else { throw ACPEngineError.invalidArgument("Attachments must be local files: \(url)") }
            if canImage, let mime = imageTypes[url.pathExtension.lowercased()], let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024 {
                blocks.append(ACPContentBlock.image(data: data, mimeType: mime, uri: url.absoluteString))
            } else {
                blocks.append(ACPContentBlock.resourceLink(url))
            }
        }
        guard !blocks.isEmpty else { throw ACPEngineError.invalidArgument("The message is empty.") }
        for queuedText in queued { record.rememberSynthetic(queuedText) }
        if synthetic { record.rememberSynthetic(text) }
        var renamed = false
        if record.title.isEmpty, !synthetic, !text.hasPrefix("/"), !text.isEmpty {
            record.title = Self.title(from: text)
            renamed = true
        }
        record.queuedSynthetic = []
        record.updated = Date()
        store[id] = record
        save()
        var live = liveSession(id)
        live.transcript.syntheticTexts = Set(record.syntheticTexts)
        let shown = text.isEmpty ? files.map(\.lastPathComponent).joined(separator: ", ") : text
        live.queue.append(PendingPrompt(blocks: blocks, queuedSynthetic: queued, text: shown, synthetic: synthetic))
        lives[id] = live
        if renamed { emit(.sessionUpdated(record.engineSession)) }
        emit(.activity(sessionID: id, .working))
        pump(id)
    }

    func queueSynthetic(_ id: String, text: String) throws {
        var record = try record(id)
        record.queuedSynthetic.append(text)
        store[id] = record
        save()
    }

    private var turnLimit: Int? { configuration.maxConcurrentTurns ?? definition.maxConcurrentTurns }

    private var runningTurns: Int { lives.values.filter { $0.running != nil }.count }

    /// Starts the session's next queued prompt when no turn of it runs and a slot is free.
    private func pump(_ id: String) {
        guard var live = lives[id], live.running == nil, !live.queue.isEmpty else { return }
        if let limit = turnLimit, runningTurns >= max(1, limit) {
            if !waitingForSlot.contains(id) { waitingForSlot.append(id) }
            return
        }
        waitingForSlot.removeAll { $0 == id }
        let token = UUID()
        live.running = RunningTurn(token: token)
        lives[id] = live
        Task { await self.runTurn(id, token: token) }
    }

    private func pumpWaiting() {
        while let first = waitingForSlot.first {
            if let limit = turnLimit, runningTurns >= max(1, limit) { return }
            waitingForSlot.removeFirst()
            pump(first)
        }
    }

    private func runTurn(_ id: String, token: UUID) async {
        do {
            try await ensureOpen(id)
            if lives[id]?.settingsDirty == true { try await applySettings(id, forceMode: false) }
        } catch {
            finishTurn(id, token: token, result: nil, error: error)
            return
        }
        guard var live = lives[id], live.running?.token == token else { return }
        if live.running?.interrupting == true || live.queue.isEmpty {
            finishTurn(id, token: token, result: ["stopReason": "cancelled"], error: nil)
            return
        }
        let prompt = live.queue.removeFirst()
        var addEvents: [EngineEvent] = []
        for notice in prompt.queuedSynthetic { addEvents += live.transcript.addUser(notice, synthetic: true) }
        if !prompt.text.isEmpty { addEvents += live.transcript.addUser(prompt.text, synthetic: prompt.synthetic) }
        guard let key = live.connection, let gen = live.generation, let agentID = store[id]?.agentSessionID else {
            lives[id] = live
            finishTurn(id, token: token, result: nil, error: ACPEngineError.processFailed("the session is not open"))
            return
        }
        let requestID = makeID(key)
        live.running?.requestID = requestID
        lives[id] = live
        emit(addEvents)
        do {
            let result = try await call(key, generation: gen, id: requestID, method: "session/prompt",
                                        params: ["sessionId": .string(agentID), "prompt": .array(prompt.blocks)], timeout: nil)
            finishTurn(id, token: token, result: result, error: nil)
        } catch {
            finishTurn(id, token: token, result: nil, error: error)
        }
    }

    private func finishTurn(_ id: String, token: UUID, result: JSONValue?, error: Error?) {
        guard var live = lives[id], let running = live.running, running.token == token else { return }
        emit(live.transcript.endTurn())
        live.running = nil
        let outcome: String
        var message: String?
        if let error {
            if running.interrupting {
                outcome = "interrupted"
            } else {
                outcome = "failed"
                if let rpc = error as? ACPRPCError {
                    message = mapAgentError(rpc).localizedDescription
                } else {
                    message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            live.queue.removeAll()
        } else {
            let stop = ACPStopReason(result?["stopReason"]?.stringValue)
            let mapped = running.interrupting ? ("interrupted", nil) : stop.outcome
            outcome = mapped.0
            message = mapped.1
        }
        lives[id] = live
        if var record = store[id] {
            if let usage = ACPTurnUsage(result?["usage"]) { record.usage = record.usage + usage.usage }
            if let cost = lastCost[id] { record.usage.costUSD = cost }
            record.updated = Date()
            store[id] = record
            save()
            emit(.usageUpdated(sessionID: id, record.usage))
        }
        clearPending(sessionID: id, answer: true)
        emit(.executionEnded(sessionID: id, outcome: outcome, error: message))
        emit(.activity(sessionID: id, outcome == "failed" ? .failed : .idle))
        // A session marked `reopenWhenIdle` moves to its new process when its next turn opens it (`ensureOpen`).
        pump(id)
        pumpWaiting()
    }

    func interrupt(_ id: String) {
        guard var live = lives[id] else { return }
        if var running = live.running {
            guard !running.interrupting else { return }
            running.interrupting = true
            live.running = running
            live.queue.removeAll()
            lives[id] = live
            clearPending(sessionID: id, answer: true)
            if running.requestID != nil, let key = live.connection, let agentID = store[id]?.agentSessionID {
                notify(key, method: "session/cancel", params: ["sessionId": .string(agentID)])
            }
            // The agent must answer the prompt with `cancelled`; if it does not, end the turn here.
            let token = running.token
            let grace = configuration.interruptGrace
            Task {
                try? await Task.sleep(for: grace)
                self.finishTurn(id, token: token, result: ["stopReason": "cancelled"], error: nil)
            }
        } else if !live.queue.isEmpty {
            live.queue.removeAll()
            lives[id] = live
            waitingForSlot.removeAll { $0 == id }
            emit(.executionEnded(sessionID: id, outcome: "interrupted", error: nil))
            emit(.activity(sessionID: id, .idle))
        }
    }

    /// Withdraws a session's open permission prompts; `answer` also tells the agent "cancelled".
    private func clearPending(sessionID: String, answer: Bool) {
        for (requestID, prompt) in pending where prompt.sessionID == sessionID {
            pending[requestID] = nil
            if answer { respond(prompt.connection, generation: prompt.generation, id: prompt.rpcID, result: ACPPermissionAsk.outcome(optionID: nil)) }
            emit(.permissionReplied(sessionID: sessionID, requestID: requestID))
        }
    }

    func replyPermission(requestID: String, decision: PermissionDecision) throws {
        guard let prompt = pending.removeValue(forKey: requestID) else {
            throw ACPEngineError.invalidArgument("This permission prompt is no longer open.")
        }
        let sessionID = prompt.sessionID
        guard connections[prompt.connection]?.process.generation == prompt.generation else {
            emit(.permissionReplied(sessionID: sessionID, requestID: requestID))
            throw ACPEngineError.processFailed("the agent stopped before the answer arrived")
        }
        // "Always" is answered as a one-time allow: the agent's own "always" option would save a rule of the agent's
        // choosing that the card cannot describe. Ensemble remembers exactly the rule the card showed, if any.
        let option = prompt.ask.option(for: decision == .reject ? .reject : .once)
        respond(prompt.connection, generation: prompt.generation, id: prompt.rpcID, result: ACPPermissionAsk.outcome(optionID: option?.id))
        emit(.permissionReplied(sessionID: sessionID, requestID: requestID))
        if decision == .always, let rule = prompt.rule {
            rules[sessionID, default: []].insert(rule.key)
            for (otherID, other) in pending where other.sessionID == sessionID && other.rule?.key == rule.key {
                pending[otherID] = nil
                respond(other.connection, generation: other.generation, id: other.rpcID,
                        result: ACPPermissionAsk.outcome(optionID: other.ask.option(for: .once)?.id))
                emit(.permissionReplied(sessionID: sessionID, requestID: otherID))
            }
        }
        if !pending.values.contains(where: { $0.sessionID == sessionID }), lives[sessionID]?.running != nil {
            emit(.activity(sessionID: sessionID, .working))
        }
    }

    func pendingRequests() -> [PermissionRequest] {
        pending.values.map(\.request).sorted { $0.created < $1.created }
    }

    // MARK: Sign-in, models, commands

    /// Opens a throwaway session in Ensemble's own empty folder (no project settings there), reads the models, effort
    /// levels and commands it offers, and closes it again. A sign-in error marks the tool signed out.
    private func probe() async throws {
        let key = ConnectionKey.normal
        let gen = try await connection(key)
        let folder = configuration.workDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result: JSONValue
        do {
            result = try await call(key, generation: gen, method: "session/new", params: ["cwd": .string(folder.path), "mcpServers": []],
                                    timeout: configuration.requestTimeout)
        } catch let error as ACPRPCError {
            throw mapAgentError(error)
        }
        let setup = ACPSessionSetup(result: result)
        if let agentID = setup.sessionID { probeSessions.insert(agentID) }
        updateCatalog(configOptions: setup.configOptions ?? [], models: setup.models)
        let version = info(key)?.version
        auth = (Date(), ACPAuthState(installed: true, version: version, signedIn: true))
        // Commands arrive as an update right after the answer.
        try? await Task.sleep(for: .milliseconds(300))
        if let agentID = setup.sessionID, let info = info(key) {
            let params: JSONValue = ["sessionId": .string(agentID)]
            if info.deleteSession {
                _ = try? await call(key, generation: gen, method: "session/delete", params: params, timeout: .seconds(10))
            } else if info.closeSession {
                _ = try? await call(key, generation: gen, method: "session/close", params: params, timeout: .seconds(10))
            }
        }
    }

    func authState(refresh: Bool) async -> ACPAuthState {
        if !refresh, let cached = auth, Date().timeIntervalSince(cached.date) < 600 { return cached.state }
        guard executableURL() != nil else {
            let state = ACPAuthState(installed: false)
            auth = (Date(), state)
            return state
        }
        switch definition.signInCheck {
        case .acpSession:
            do {
                try await probe()
            } catch ACPEngineError.notSignedIn {
                // Recorded by mapAgentError.
            } catch {
                let state = ACPAuthState(installed: true, version: info(.normal)?.version, signedIn: nil, problem: error.localizedDescription)
                auth = (Date(), state)
            }
        case .none:
            if (try? await connection(.normal)) != nil {
                auth = (Date(), ACPAuthState(installed: true, version: info(.normal)?.version, signedIn: auth?.state.signedIn))
            } else {
                auth = (Date(), ACPAuthState(installed: true, signedIn: nil, problem: "The agent did not start."))
            }
        }
        return auth?.state ?? ACPAuthState(installed: true)
    }

    func version() async -> String? {
        if let version = info(.normal)?.version { return version }
        return await authState(refresh: false).version
    }

    private func currentCatalog() async -> Catalog? {
        if let catalog, Date().timeIntervalSince(catalog.date) < 600 { return catalog }
        guard executableURL() != nil else { return nil }
        try? await probe()
        return catalog
    }

    func models() async -> [ModelInfo] {
        guard let catalog = await currentCatalog() else { return [] }
        let signedIn = auth?.state.signedIn != false
        return catalog.models.map { choice in
            ModelInfo(ref: ModelRef(providerID: definition.id, id: choice.value), name: choice.name, providerName: definition.providerName,
                      contextLimit: contextSizes[choice.value], variants: catalog.efforts, available: signedIn)
        }
    }

    func providers() async -> [ProviderInfo] {
        let state = await authState(refresh: false)
        return [ProviderInfo(id: definition.id, name: definition.providerName, connected: state.installed && state.signedIn != false)]
    }

    func modelOptions(for model: ModelRef) async -> ModelOptions {
        guard model.providerID == definition.id, let catalog = await currentCatalog() else { return ModelOptions() }
        let levels = catalog.efforts.compactMap(EffortLevel.init(rawValue:))
        return ModelOptions(effortLevels: levels, defaultEffort: nil, supportsFastMode: false)
    }

    func commands(directory: String?) async -> [EngineCommand] {
        var list = directory.flatMap { commandsByDirectory[$0] } ?? latestCommands
        if list == nil, executableURL() != nil {
            try? await probe()
            list = latestCommands
        }
        return (list ?? []).map { EngineCommand(name: $0.name, summary: $0.description, kind: .command, argumentHint: $0.hint) }
    }
}
#endif
