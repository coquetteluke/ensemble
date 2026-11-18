import Foundation
import Synchronization

/// A fake engine with realistic sample data. `prompt()` streams a reply with reasoning, tool calls,
/// a permission prompt (in Ask mode) and Markdown through `events()`, so the whole UI can be used
/// without a running OpenCode service.
public final class PreviewEngine: OpenCodeAPI, Sendable {
    public enum PreviewError: LocalizedError {
        case unknownSession(String)
        public var errorDescription: String? {
            switch self {
            case .unknownSession(let id): "No session with id \(id)."
            }
        }
    }

    private struct State {
        var seed: StoreSeed
        var sessions: [String: EngineSession] = [:]
        var transcripts: [String: [TranscriptItem]] = [:]
        var activities: [String: SessionActivity] = [:]
        var permissions: [PermissionRequest] = []
        var replies: [String: PermissionDecision] = [:]
        var contexts: [String: ContextBreakdown] = [:]
        var changes: [String: [FileChange]] = [:]
        var modes: [String: PermissionMode] = [:]
        var connectors: [ConnectorInfo] = []
        var models: [ModelInfo] = []
        var providers: [ProviderInfo] = []
        var schedules: [ScheduleInfo] = []
        var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
        var running: [String: Task<Void, Never>] = [:]
        var counter = 0
    }

    private let state: Mutex<State>
    /// Multiplies every simulated delay. 0 makes replies instant (tests).
    private let delayScale: Double

    public init(seed: StoreSeed = PreviewData.seed(), delayScale: Double = 1) {
        var s = State(seed: seed)
        for session in seed.sessions { s.sessions[session.id] = session }
        s.transcripts = seed.transcripts
        s.activities = seed.activities
        s.permissions = seed.permissions
        s.contexts = seed.contexts
        s.changes = seed.changes
        s.modes = seed.modes
        s.connectors = seed.connectors
        s.models = seed.models
        s.providers = seed.providers
        s.schedules = seed.schedules
        self.state = Mutex(s)
        self.delayScale = delayScale
    }

    // MARK: - Info

    public func serverInfo() async throws -> (version: String, url: URL) {
        ("2.3.0", URL(string: "http://127.0.0.1:4096")!)
    }

    // MARK: - Sessions

    public func listSessions() async throws -> [EngineSession] {
        state.withLock { Array($0.sessions.values) }.sorted { $0.updated > $1.updated }
    }

    public func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                              parentID: String?) async throws -> EngineSession {
        let session = state.withLock { s -> EngineSession in
            s.counter += 1
            let id = "ses_new_\(s.counter)_\(UUID().uuidString.prefix(6).lowercased())"
            let session = EngineSession(id: id, parentID: parentID, title: "New session", directory: directory,
                                        model: model ?? s.models.first(where: \.available)?.ref, agent: agent)
            s.sessions[id] = session
            s.transcripts[id] = []
            s.modes[id] = permissionMode
            s.contexts[id] = PreviewData.makeContext(messages: 0, limit: limit(for: session.model, in: s))
            return session
        }
        emit(.sessionCreated(session))
        return session
    }

    public func deleteSession(_ sessionID: String) async throws {
        try requireSession(sessionID)
        state.withLock { s in
            s.running[sessionID]?.cancel()
            s.sessions[sessionID] = nil
            s.transcripts[sessionID] = nil
        }
        emit(.sessionDeleted(sessionID: sessionID))
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        try updateSession(sessionID) { $0.title = title }
    }

    public func setArchived(_ sessionID: String, archived: Bool) async throws {
        try updateSession(sessionID) { $0.archived = archived }
    }

    public func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws {
        try requireSession(sessionID)
        state.withLock { $0.modes[sessionID] = mode }
    }

    public func switchModel(_ sessionID: String, model: ModelRef) async throws {
        try updateSession(sessionID) { $0.model = model }
    }

    public func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        try requireSession(sessionID)
        return state.withLock { $0.transcripts[sessionID] ?? [] }
    }

    public func children(_ sessionID: String) async throws -> [EngineSession] {
        state.withLock { s in s.sessions.values.filter { $0.parentID == sessionID } }.sorted { $0.created < $1.created }
    }

    // MARK: - Talking

    public func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        try requireSession(sessionID)
        let (mode, isFirst) = state.withLock { s -> (PermissionMode, Bool) in
            var shown = text
            if !files.isEmpty { shown += "\n\nAttached: " + files.map(\.lastPathComponent).joined(separator: ", ") }
            let isFirst = !(s.transcripts[sessionID] ?? []).contains { if case .user = $0 { true } else { false } }
            s.transcripts[sessionID, default: []].append(.user(id: "user-\(UUID().uuidString)", text: shown, date: Date()))
            return (s.modes[sessionID] ?? .ask, isFirst)
        }
        if isFirst {
            let title = String(text.split(separator: "\n").first ?? "New session").prefix(48)
            try? updateSession(sessionID) { $0.title = String(title) }
        }
        start(sessionID) { engine in await engine.simulateReply(sessionID: sessionID, prompt: text, mode: mode) }
    }

    public func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        try requireSession(sessionID)
        let mode = state.withLock { s -> PermissionMode in
            s.transcripts[sessionID, default: []].append(.notice(id: "syn-\(UUID().uuidString)", text: text))
            return s.modes[sessionID] ?? .ask
        }
        if wake {
            start(sessionID) { engine in await engine.simulateReply(sessionID: sessionID, prompt: text, mode: mode) }
        }
    }

    public func interrupt(_ sessionID: String) async throws {
        try requireSession(sessionID)
        let (task, pending) = state.withLock { s -> (Task<Void, Never>?, [PermissionRequest]) in
            let task = s.running.removeValue(forKey: sessionID)
            let pending = s.permissions.filter { $0.sessionID == sessionID }
            return (task, pending)
        }
        task?.cancel()
        for request in pending { emit(.permissionReplied(sessionID: sessionID, requestID: request.id)) }
        emit(.executionEnded(sessionID: sessionID, outcome: "interrupted", error: nil))
        emit(.activity(sessionID: sessionID, .idle))
    }

    public func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {
        let request = state.withLock { s -> PermissionRequest? in
            guard let request = s.permissions.first(where: { $0.id == requestID }) else { return nil }
            s.replies[requestID] = decision
            return request
        }
        guard let request else { return }
        emit(.permissionReplied(sessionID: sessionID, requestID: requestID))
        // Seeded prompts have no running turn waiting on them; continue the story here.
        let waiting = state.withLock { $0.running[sessionID] != nil }
        if !waiting {
            start(sessionID) { engine in await engine.continueAfterSeededPermission(request, decision: decision) }
        }
    }

    public func pendingPermissions() async throws -> [PermissionRequest] {
        state.withLock { $0.permissions }
    }

    // MARK: - Panels

    public func context(_ sessionID: String) async throws -> ContextBreakdown {
        try requireSession(sessionID)
        return state.withLock { s in
            s.contexts[sessionID] ?? PreviewData.makeContext(messages: 0, limit: limit(for: s.sessions[sessionID]?.model, in: s))
        }
    }

    public func changedFiles(_ sessionID: String) async throws -> [FileChange] {
        state.withLock { $0.changes[sessionID] ?? [] }
    }

    public func connectors() async throws -> [ConnectorInfo] {
        state.withLock { $0.connectors }
    }

    // MARK: - Models and keys

    public func models() async throws -> [ModelInfo] {
        state.withLock { $0.models }
    }

    public func providers() async throws -> [ProviderInfo] {
        state.withLock { $0.providers }
    }

    /// Marks the provider connected. The key itself is never stored or logged.
    public func setAPIKey(providerID: String, key: String) async throws {
        state.withLock { s in
            setConnected(providerID, true, in: &s)
        }
    }

    public func removeAPIKey(providerID: String) async throws {
        state.withLock { s in
            setConnected(providerID, false, in: &s)
        }
    }

    // MARK: - Schedules

    public func schedules() async throws -> [ScheduleInfo] {
        state.withLock { $0.schedules }
    }

    public func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        let info = ScheduleInfo(id: "sch_\(UUID().uuidString.prefix(8).lowercased())", title: title, prompt: prompt,
                                directory: directory, schedule: schedule)
        state.withLock { $0.schedules.append(info) }
        return info
    }

    public func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {
        state.withLock { s in
            if let index = s.schedules.firstIndex(where: { $0.id == scheduleID }) { s.schedules[index].paused = paused }
        }
    }

    public func deleteSchedule(_ scheduleID: String) async throws {
        state.withLock { $0.schedules.removeAll { $0.id == scheduleID } }
    }

    // MARK: - Events

    public func events() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let busy = state.withLock { s -> [(String, SessionActivity)] in
                s.subscribers[id] = continuation
                return s.activities.filter { $0.value != .idle }.map { ($0.key, $0.value) }
            }
            // Like the real stream's status snapshot on connect.
            for (sessionID, activity) in busy { continuation.yield(.activity(sessionID: sessionID, activity)) }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { s in s.subscribers[id] = nil }
            }
        }
    }

    // MARK: - Simulation

    private func start(_ sessionID: String, _ body: @escaping @Sendable (PreviewEngine) async -> Void) {
        let task = Task { [self] in
            await body(self)
            _ = state.withLock { $0.running.removeValue(forKey: sessionID) }
        }
        let previous = state.withLock { s -> Task<Void, Never>? in
            let previous = s.running[sessionID]
            s.running[sessionID] = task
            return previous
        }
        previous?.cancel()
    }

    func simulateReply(sessionID: String, prompt: String, mode: PermissionMode) async {
        let turn = UUID().uuidString.prefix(8).lowercased()
        let short = prompt.count > 60 ? String(prompt.prefix(60)) + "..." : prompt
        emit(.activity(sessionID: sessionID, .working))

        guard await stream(reasoning: "The request: \"\(short)\". I'll look at the project layout, build it, then answer with what I found.",
                           sessionID: sessionID, itemID: "r-\(turn)") else { return }
        guard await stream(text: "I'll look at the project first.", sessionID: sessionID, itemID: "t1-\(turn)") else { return }

        var grep = ToolCallInfo(id: "grep-\(turn)", name: "grep", title: "TODO",
                                inputJSON: #"{"pattern": "TODO", "path": "."}"#, status: .running)
        emit(.toolUpdated(sessionID: sessionID, grep))
        guard await pause(700) else { return }
        grep.status = .succeeded
        grep.outputPreview = "Sources/App/AppModel.swift:18: // TODO: persist window size\nSources/App/Settings.swift:52: // TODO: validate URL"
        emit(.toolUpdated(sessionID: sessionID, grep))

        if mode == .ask {
            let request = PermissionRequest(id: "perm-\(turn)", sessionID: sessionID, kind: "bash", title: "swift build",
                                            detail: "Builds the package in the project folder.")
            state.withLock { $0.permissions.append(request) }
            emit(.permissionAsked(request))
            emit(.activity(sessionID: sessionID, .waitingForPermission))
            guard let decision = await waitForReply(request.id) else { return }
            emit(.activity(sessionID: sessionID, .working))
            if decision == .reject {
                guard await stream(text: "Understood, I won't build. The two TODOs above are the only open items I found.",
                                   sessionID: sessionID, itemID: "t2-\(turn)") else { return }
                finishTurn(sessionID, tokens: 2_400)
                return
            }
        }

        var build = ToolCallInfo(id: "bash-\(turn)", name: "bash", title: "swift build",
                                 inputJSON: #"{"command": "swift build", "description": "Build the package"}"#, status: .running,
                                 outputPreview: "Building for debugging...")
        emit(.toolUpdated(sessionID: sessionID, build))
        guard await pause(1200) else { return }
        build.status = .succeeded
        build.outputPreview = "Building for debugging...\n[9/9] Compiling App Settings.swift\nBuild complete! (3.08s)"
        emit(.toolUpdated(sessionID: sessionID, build))

        let directory = state.withLock { $0.sessions[sessionID]?.directory ?? "" }
        let path = directory + "/Sources/App/Settings.swift"
        let diff = """
        @@ -50,6 +50,10 @@ struct Settings {
             var serverURL: String
        -    // TODO: validate URL
        +    var isValidURL: Bool {
        +        guard let url = URL(string: serverURL) else { return false }
        +        return url.scheme == "http" || url.scheme == "https"
        +    }
         }
        """
        var edit = ToolCallInfo(id: "edit-\(turn)", name: "edit", title: path, inputJSON: #"{"filePath": "Sources/App/Settings.swift"}"#,
                                status: .running)
        emit(.toolUpdated(sessionID: sessionID, edit))
        guard await pause(600) else { return }
        edit.status = .succeeded
        edit.diff = diff
        emit(.toolUpdated(sessionID: sessionID, edit))
        state.withLock { s in
            s.changes[sessionID, default: []].removeAll { $0.path == path }
            s.changes[sessionID, default: []].insert(FileChange(path: path, kind: .modified, additions: 4, deletions: 1, diff: diff), at: 0)
        }
        emit(.filesChanged(paths: [path]))

        let answer = """
        Done. I found two open TODOs and fixed the URL one:

        - `Settings.isValidURL` now accepts only **http** and **https** URLs.
        - The window size TODO in `AppModel.swift` is still open.

        ```swift
        var isValidURL: Bool {
            guard let url = URL(string: serverURL) else { return false }
            return url.scheme == "http" || url.scheme == "https"
        }
        ```

        The build passes. Want me to persist the window size next?
        """
        guard await stream(text: answer, sessionID: sessionID, itemID: "t3-\(turn)") else { return }
        finishTurn(sessionID, tokens: 9_800)
    }

    func continueAfterSeededPermission(_ request: PermissionRequest, decision: PermissionDecision) async {
        let sessionID = request.sessionID
        let turn = UUID().uuidString.prefix(8).lowercased()
        emit(.activity(sessionID: sessionID, .working))
        if decision == .reject {
            guard await stream(text: "OK, I won't run that. Tell me when you want to continue.",
                               sessionID: sessionID, itemID: "t-\(turn)") else { return }
            finishTurn(sessionID, tokens: 900)
            return
        }
        let isEdit = request.kind == "edit" || request.kind == "write"
        var tool = ToolCallInfo(id: "tool-\(turn)", name: isEdit ? "write" : "bash", title: request.title,
                                inputJSON: isEdit ? #"{"filePath": "\#(request.title)"}"# : #"{"command": "\#(request.title)"}"#,
                                status: .running, outputPreview: isEdit ? nil : "Building for debugging...")
        emit(.toolUpdated(sessionID: sessionID, tool))
        guard await pause(1400) else { return }
        tool.status = .succeeded
        if isEdit {
            tool.diff = "@@ -0,0 +1,5 @@\n+export function ThemeToggle() {\n+  const [theme, setTheme] = useTheme()\n+  return <button onClick={() => setTheme(theme === \"dark\" ? \"light\" : \"dark\")}>Theme</button>\n+}\n+"
        } else {
            tool.outputPreview = "Test Suite 'All tests' passed.\n     Executed 24 tests, with 0 failures (0 unexpected) in 1.92 seconds"
        }
        emit(.toolUpdated(sessionID: sessionID, tool))
        let text = isEdit
            ? "The toggle is in place. It stores the choice in `localStorage` and sets `data-theme` on `<html>`."
            : "All **24 tests** pass. Next I'll fill in the Outputs list with file type icons and a *Show more* row."
        guard await stream(text: text, sessionID: sessionID, itemID: "t-\(turn)") else { return }
        finishTurn(sessionID, tokens: 3_200)
    }

    private func finishTurn(_ sessionID: String, tokens: Int) {
        let usage = state.withLock { s -> Usage in
            var usage = s.sessions[sessionID]?.usage ?? .zero
            usage.inputTokens += tokens
            usage.outputTokens += tokens / 6
            usage.costUSD += Double(tokens) * 0.000_006
            s.sessions[sessionID]?.usage = usage
            s.sessions[sessionID]?.updated = Date()
            if var context = s.contexts[sessionID] {
                context.usedTokens += tokens
                if let i = context.categories.firstIndex(where: { $0.key == "messages" }) { context.categories[i].tokens += tokens }
                if let i = context.categories.firstIndex(where: { $0.key == "free" }) {
                    context.categories[i].tokens = max(0, context.categories[i].tokens - tokens)
                }
                s.contexts[sessionID] = context
            }
            return usage
        }
        emit(.usageUpdated(sessionID: sessionID, usage))
        emit(.executionEnded(sessionID: sessionID, outcome: "succeeded", error: nil))
        emit(.activity(sessionID: sessionID, .idle))
    }

    private func stream(text: String, sessionID: String, itemID: String) async -> Bool {
        for chunk in chunks(text) {
            guard await pause(28) else { return false }
            emit(.textDelta(sessionID: sessionID, itemID: itemID, delta: chunk))
        }
        emit(.textEnded(sessionID: sessionID, itemID: itemID, text: text))
        return true
    }

    private func stream(reasoning: String, sessionID: String, itemID: String) async -> Bool {
        for chunk in chunks(reasoning) {
            guard await pause(22) else { return false }
            emit(.reasoningDelta(sessionID: sessionID, itemID: itemID, delta: chunk))
        }
        return true
    }

    /// Splits text into small word groups, like a model streaming tokens.
    private func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var words = 0
        for ch in text {
            current.append(ch)
            if ch == " " || ch == "\n" {
                words += 1
                if words >= 2 {
                    result.append(current)
                    current = ""
                    words = 0
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func pause(_ milliseconds: Double) async -> Bool {
        let scaled = milliseconds * delayScale
        if scaled > 0 {
            do { try await Task.sleep(for: .milliseconds(Int(scaled))) } catch { return false }
        } else {
            await Task.yield()
        }
        return !Task.isCancelled
    }

    private func waitForReply(_ requestID: String) async -> PermissionDecision? {
        while !Task.isCancelled {
            if let decision = state.withLock({ s -> PermissionDecision? in
                guard let decision = s.replies[requestID] else { return nil }
                s.permissions.removeAll { $0.id == requestID }
                return decision
            }) {
                return decision
            }
            do { try await Task.sleep(for: .milliseconds(delayScale == 0 ? 2 : 50)) } catch { return nil }
        }
        return nil
    }

    // MARK: - Helpers

    private func emit(_ event: EngineEvent) {
        let subscribers = state.withLock { s -> [AsyncStream<EngineEvent>.Continuation] in
            apply(event, to: &s)
            return Array(s.subscribers.values)
        }
        for continuation in subscribers { continuation.yield(event) }
    }

    /// Keeps the engine's own copy of transcripts and sessions in step with the events it sends.
    private func apply(_ event: EngineEvent, to s: inout State) {
        switch event {
        case .sessionCreated(let info), .sessionUpdated(let info):
            s.sessions[info.id] = info
        case .sessionDeleted(let id):
            s.sessions[id] = nil
        case .activity(let id, let activity):
            s.activities[id] = activity
            if activity == .idle || activity == .failed { TranscriptReducer.finishStreaming(&s.transcripts[id, default: []]) }
        case .textDelta(let id, let itemID, let delta):
            TranscriptReducer.appendText(&s.transcripts[id, default: []], itemID: itemID, delta: delta, agentID: nil)
        case .textEnded(let id, let itemID, let text):
            TranscriptReducer.endText(&s.transcripts[id, default: []], itemID: itemID, text: text, agentID: nil)
        case .reasoningDelta(let id, let itemID, let delta):
            TranscriptReducer.appendReasoning(&s.transcripts[id, default: []], itemID: itemID, delta: delta)
        case .toolUpdated(let id, let tool):
            TranscriptReducer.upsertTool(&s.transcripts[id, default: []], tool)
        case .permissionAsked(let request):
            TranscriptReducer.addPermission(&s.transcripts[request.sessionID, default: []], request)
        case .permissionReplied(_, let requestID):
            s.permissions.removeAll { $0.id == requestID }
        case .usageUpdated(let id, let usage):
            s.sessions[id]?.usage = usage
        case .executionEnded(let id, let outcome, let error):
            TranscriptReducer.finishStreaming(&s.transcripts[id, default: []])
            if let error {
                s.transcripts[id, default: []].append(.error(id: "error-\(UUID().uuidString)", message: error))
            } else if outcome == "interrupted" {
                s.transcripts[id, default: []].append(.notice(id: "notice-\(UUID().uuidString)", text: "Interrupted"))
            }
        case .filesChanged, .connectorsChanged, .other:
            break
        }
    }

    private func requireSession(_ id: String) throws {
        guard state.withLock({ $0.sessions[id] != nil }) else { throw PreviewError.unknownSession(id) }
    }

    private func updateSession(_ id: String, _ change: (inout EngineSession) -> Void) throws {
        let updated = try state.withLock { s -> EngineSession in
            guard var session = s.sessions[id] else { throw PreviewError.unknownSession(id) }
            change(&session)
            session.updated = Date()
            s.sessions[id] = session
            return session
        }
        emit(.sessionUpdated(updated))
    }

    private func setConnected(_ providerID: String, _ connected: Bool, in s: inout State) {
        if let index = s.providers.firstIndex(where: { $0.id == providerID }) {
            s.providers[index].connected = connected
        } else {
            s.providers.append(ProviderInfo(id: providerID, name: providerID, connected: connected))
        }
        for index in s.models.indices where s.models[index].ref.providerID == providerID {
            s.models[index].available = connected
        }
    }

    private func limit(for model: ModelRef?, in s: State) -> Int {
        guard let model else { return 200_000 }
        return s.models.first { $0.ref.providerID == model.providerID && $0.ref.id == model.id }?.contextLimit ?? 200_000
    }
}
