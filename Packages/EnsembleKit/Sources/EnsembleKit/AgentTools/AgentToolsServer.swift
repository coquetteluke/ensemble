import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// The session a tool call comes from, as the server established it (never from the call's own arguments).
public struct AgentToolsCaller: Equatable, Sendable {
    public var sessionID: String
    /// The bridge is tied to the exact engine process its key was issued to (`AgentToolsBinding`), so "Always for this
    /// site" grants may be used. False for bridges of engines that serve several sessions from one process.
    public var canUseSiteGrants: Bool

    public init(sessionID: String, canUseSiteGrants: Bool = true) {
        self.sessionID = sessionID
        self.canUseSiteGrants = canUseSiteGrants
    }
}

/// One line in a session's transcript about a tool call.
public struct AgentToolsLogEntry: Equatable, Sendable {
    public var sessionID: String
    /// The tool's name as the agent sent it.
    public var tool: String
    public var summary: String
    public var refused: Bool
    /// The first line of the answer.
    public var outcome: String

    public var transcriptText: String {
        let line = outcome.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let shown = line.count > 160 ? String(line.prefix(159)) + "\u{2026}" : line
        return "Ensemble tool \(tool): \(summary)" + (shown.isEmpty ? "" : (refused ? ". Refused: " : ". ") + shown)
    }
}

/// What the app does with tool calls: shows proposal cards, asks for browser permission and drives the browser pane.
public protocol AgentToolsHost: AnyObject, Sendable {
    func handle(_ call: AgentToolCall, caller: AgentToolsCaller) async -> AgentToolResult
    /// For folder bridges (OpenCode): whether `sessionID` is one of Ensemble's sessions in `folder` on that server.
    func session(_ sessionID: String, isIn folder: String, server: String) async -> Bool
    /// The top-level session above a subagent (itself for a top-level session), or nil when Ensemble does not know it.
    func rootSession(of sessionID: String) async -> String?
    /// Every call, refused ones included, for the session's transcript.
    func record(_ entry: AgentToolsLogEntry) async
}

/// Ensemble's MCP server for agents: one Unix socket for the whole app, reached through the `ensemble-agent-tools`
/// helper that each engine starts as a stdio MCP server (`AgentToolsBridge`).
///
/// - Each session (or OpenCode folder) gets its own random key, handed to its engine in the bridge's environment. The
///   first line on a connection must carry a known key, or the connection is closed; the key decides which session
///   every later call belongs to. Another session's bridge, or any other process, cannot act for a session without
///   its key. Peers running as another user are refused before that.
/// - Only `initialize`, `ping`, `tools/list` and `tools/call` are answered, and only for `AgentToolName`; anything else
///   is refused. Calls are rate-limited per session and every call is logged to the session's transcript.
public final class AgentToolsServer: AgentToolsAttaching, Sendable {
    public struct Limits: Sendable {
        public var perMinute: Int
        public var perSecond: Int
        /// Bytes in one incoming line.
        public var maxLine: Int
        /// Requests one connection may have open at once.
        public var maxInFlight: Int
        public var helloTimeout: Duration

        public init(perMinute: Int = 60, perSecond: Int = 5, maxLine: Int = 1 << 20, maxInFlight: Int = 8,
                    helloTimeout: Duration = .seconds(10)) {
            self.perMinute = perMinute
            self.perSecond = perSecond
            self.maxLine = maxLine
            self.maxInFlight = maxInFlight
            self.helloTimeout = helloTimeout
        }
    }

    public enum StartError: Error, LocalizedError {
        case socket(String)

        public var errorDescription: String? {
            switch self {
            case .socket(let reason): "Ensemble's agent tools could not start: \(reason)"
            }
        }
    }

    /// The app's server. Engines attach it by default; it hands out nothing until the app starts it.
    public static let shared = AgentToolsServer()

    private struct State {
        var host: (any AgentToolsHost)?
        var executable: String?
        var folder: URL?
        var socketPath: String?
        var listener: Int32 = -1
        var wake: (read: Int32, write: Int32) = (-1, -1)
        var keys: [String: AgentToolsTarget] = [:]
        var targetKeys: [AgentToolsTarget: String] = [:]
        var connections: [ObjectIdentifier: AgentToolsConnection] = [:]
        var calls: [String: [ContinuousClock.Instant]] = [:]
        /// Who checks peers (`AgentToolsPeerCheck`).
        var processes: (any AgentToolsProcesses)?
        /// The engine process each session key belongs to; a session key with none is `.appChild`.
        var bindings: [AgentToolsTarget: AgentToolsBinding] = [:]
        /// The OpenCode sessions each folder key may speak for: sessions Ensemble prompted on that server, in that folder.
        var openCodeSessions: [AgentToolsTarget: Set<String>] = [:]
    }

    public let limits: Limits
    private let state = Mutex(State())

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var isRunning: Bool { state.withLock { $0.listener >= 0 } }
    public var isAttaching: Bool { isRunning }
    public var socketPath: String? { state.withLock { $0.socketPath } }

    // MARK: Starting and stopping

    #if canImport(Darwin)
    /// Opens the socket in a new private folder under the user's temporary folder and starts accepting bridges.
    /// `executable` is the helper engines start (`Ensemble.app/Contents/MacOS/ensemble-agent-tools`); every peer must be
    /// that signed binary, started by the engine process its key belongs to. `processes` replaces the system lookups
    /// (tests only).
    public func start(host: any AgentToolsHost, executable: String, parent: URL = FileManager.default.temporaryDirectory,
                      processes: (any AgentToolsProcesses)? = nil) throws {
        stop()
        #if os(macOS)
        let checker: any AgentToolsProcesses = processes ?? SystemAgentToolsProcesses(helperPath: executable)
        #else
        guard let checker = processes else { throw StartError.socket("no process checks on this system") }
        #endif
        let fm = FileManager.default
        let folder = parent.appendingPathComponent("ensemble-tools-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder that already existed keeps its mode; insist on 0700.
        chmod(folder.path, 0o700)
        let path = folder.appendingPathComponent("s").path
        guard path.utf8.count <= AgentToolsBridge.maxSocketPathLength else {
            try? fm.removeItem(at: folder)
            throw StartError.socket("the socket path is too long")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            try? fm.removeItem(at: folder)
            throw StartError.socket("no socket")
        }
        let oldMask = umask(0o177)
        let bound = AgentToolsBridge.withUnixAddress(path) { bind(fd, $0, $1) }
        umask(oldMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            try? fm.removeItem(at: folder)
            throw StartError.socket("could not listen on \(path)")
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            close(fd)
            try? fm.removeItem(at: folder)
            throw StartError.socket("no wake pipe")
        }
        state.withLock {
            $0.host = host
            $0.processes = checker
            $0.executable = executable
            $0.folder = folder
            $0.socketPath = path
            $0.listener = fd
            $0.wake = (pipeFDs[0], pipeFDs[1])
        }
        let wakeRead = pipeFDs[0]
        let thread = Thread { [weak self] in self?.acceptLoop(listener: fd, wake: wakeRead) }
        thread.name = "Ensemble agent tools"
        thread.start()
    }
    #endif

    /// Closes the socket and every connection and forgets all keys.
    public func stop() {
        let (listener, wake, folder, connections) = state.withLock { state -> (Int32, (read: Int32, write: Int32), URL?, [AgentToolsConnection]) in
            let result = (state.listener, state.wake, state.folder, Array(state.connections.values))
            state = State()
            return result
        }
        if wake.write >= 0 {
            var byte: UInt8 = 1
            _ = write(wake.write, &byte, 1)
        }
        for connection in connections { connection.close() }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        // The accept loop closes the listener and the pipe's read end when it wakes.
        if listener < 0, wake.read >= 0 { close(wake.read) }
        if wake.write >= 0 { close(wake.write) }
    }

    // MARK: Keys

    public func attachment(for target: AgentToolsTarget) -> AgentToolsAttachment? {
        state.withLock { state in
            guard state.listener >= 0, let executable = state.executable, let path = state.socketPath else { return nil }
            let key: String
            if let existing = state.targetKeys[target] {
                key = existing
            } else {
                key = AgentToolsBridge.newKey()
                state.targetKeys[target] = key
                state.keys[key] = target
            }
            return AgentToolsAttachment(executable: executable, socketPath: path, key: key)
        }
    }

    /// Sessions that have a key (Claude and ACP sessions whose agent was started with the tools).
    public var sessionsWithKeys: [String] {
        state.withLock { $0.targetKeys.keys.compactMap { if case .session(let id) = $0 { id } else { nil } } }
    }

    /// Ties a key to the engine process it was issued to (a Claude session's `--mcp-config` file).
    public func expect(_ binding: AgentToolsBinding, for target: AgentToolsTarget) {
        state.withLock { $0.bindings[target] = binding }
    }

    /// Lets a folder key speak for this OpenCode session (called by the OpenCode client before each prompt).
    public func allow(openCodeSession sessionID: String, on target: AgentToolsTarget) {
        guard case .folder = target else { return }
        state.withLock { _ = $0.openCodeSessions[target, default: []].insert(sessionID) }
    }

    /// The binding a peer of this target must satisfy.
    func binding(for target: AgentToolsTarget) -> AgentToolsBinding {
        switch target {
        case .session: state.withLock { $0.bindings[target] } ?? .appChild
        case .folder(_, let server): .openCode(url: server)
        }
    }

    /// Forgets a target's key and closes its bridges (a session that was deleted or archived).
    public func revoke(_ target: AgentToolsTarget) {
        let closing = state.withLock { state -> [AgentToolsConnection] in
            state.bindings[target] = nil
            state.openCodeSessions[target] = nil
            if let key = state.targetKeys.removeValue(forKey: target) { state.keys[key] = nil }
            if case .session(let id) = target { state.calls[id] = nil }
            return state.connections.values.filter { $0.target == target }
        }
        for connection in closing { connection.close() }
    }

    /// The target a hello line proves, or nil. Every known key is compared in full, in constant time.
    func authenticate(_ line: Data) -> AgentToolsTarget? {
        guard line.count < 512, let hello = JSONValue.parse(data: line), hello["ensembleAgentTools"]?.doubleValue == 1,
              let key = hello["key"]?.stringValue, AgentToolsBridge.isValidKey(key) else { return nil }
        let given = Array(key.utf8)
        return state.withLock { state in
            var found: AgentToolsTarget?
            for (candidate, target) in state.keys {
                let bytes = Array(candidate.utf8)
                var difference: UInt8 = bytes.count == given.count ? 0 : 1
                for index in 0..<min(bytes.count, given.count) { difference |= bytes[index] ^ given[index] }
                if difference == 0 { found = target }
            }
            return found
        }
    }

    /// Bridges that proved this target's key, are still open and (with `listed`) have fetched the tool list.
    func openBridges(for target: AgentToolsTarget, listed: Bool = false) -> Int {
        state.withLock { $0.connections.values.filter { $0.target == target && !$0.isClosed && (!listed || $0.listedTools) }.count }
    }

    // MARK: Rate limit

    /// Records a call for the session and says whether it is within the limits.
    func admit(_ sessionID: String, now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { state in
            var recent = (state.calls[sessionID] ?? []).filter { now - $0 < .seconds(60) }
            let lastSecond = recent.filter { now - $0 < .seconds(1) }.count
            guard recent.count < limits.perMinute, lastSecond < limits.perSecond else {
                state.calls[sessionID] = recent
                return false
            }
            recent.append(now)
            state.calls[sessionID] = recent
            return true
        }
    }

    // MARK: Connections

    #if canImport(Darwin)
    private func acceptLoop(listener: Int32, wake: Int32) {
        var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if fds[1].revents != 0 { break }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let connection = AgentToolsConnection(fd: client, maxInFlight: limits.maxInFlight)
            #if os(macOS)
            connection.peer = SystemAgentToolsProcesses.peer(of: client)
            #endif
            let accepted = state.withLock { state -> Bool in
                guard state.listener == listener else { return false }
                state.connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else {
                connection.release()
                break
            }
            let thread = Thread { [weak self] in
                self?.serve(connection)
                _ = self?.state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
                connection.release()
            }
            thread.name = "Ensemble agent tools connection"
            thread.start()
        }
        close(listener)
        close(wake)
    }

    /// Reads one connection's lines until it closes: the hello first (within `helloTimeout`), then MCP messages.
    private func serve(_ connection: AgentToolsConnection) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let helloDeadline = ContinuousClock.now + limits.helloTimeout
        while !connection.isClosed {
            if connection.target == nil {
                let remaining = helloDeadline - .now
                guard remaining > .zero else { return }
                var pfd = pollfd(fd: connection.fd, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(clamping: remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)
                let ready = poll(&pfd, 1, max(1, milliseconds))
                if ready == 0 { return }
                if ready < 0 { if errno == EINTR { continue } else { return } }
            }
            let count = chunk.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if connection.target == nil {
                    guard let target = authenticate(Data(line)), verify(connection, for: target) else { return }
                    connection.target = target
                } else if !line.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) {
                    receive(Data(line), on: connection)
                }
            }
            if buffer.count > (connection.target == nil ? 512 : limits.maxLine) { return }
        }
    }
    #endif

    /// Whether the connection's peer may use a key for `target`: the signed helper, started by the key's engine process.
    private func verify(_ connection: AgentToolsConnection, for target: AgentToolsTarget) -> Bool {
        guard let peer = connection.peer, let processes = state.withLock({ $0.processes }) else { return false }
        let binding = binding(for: target)
        guard AgentToolsPeerCheck.refusal(peer, binding: binding, processes: processes) == nil else { return false }
        connection.siteGrants = binding.isExact
        return true
    }

    private func receive(_ line: Data, on connection: AgentToolsConnection) {
        guard let message = JSONValue.parse(data: line) else {
            connection.send(AgentToolsMCP.error(id: .null, code: -32700, message: "Not JSON."))
            return
        }
        // Notifications get no answer; a cancel ends the matching call (and with it any permission card it waits on).
        guard let id = message["id"], id != .null else {
            if message["method"]?.stringValue == "notifications/cancelled", let requestID = message["params"]?["requestId"] {
                connection.cancel(requestID)
            }
            return
        }
        guard message["method"] != nil else { return }
        switch connection.start(id) { [weak self] in
            guard let self, let response = await self.respond(to: message, on: connection) else { return }
            connection.send(response)
        } {
        case .started, .closed:
            break
        case .duplicateID:
            connection.send(AgentToolsMCP.error(id: id, code: -32600, message: "Duplicate in-flight request id."))
        case .tooManyInFlight:
            connection.send(AgentToolsMCP.error(id: id, code: -32000, message: "Too many requests at once."))
        }
    }

    /// The answer to one request.
    func respond(to message: JSONValue, on connection: AgentToolsConnection) async -> JSONValue? {
        guard let id = message["id"], id != .null else { return nil }
        guard let method = message["method"]?.stringValue else {
            return AgentToolsMCP.error(id: id, code: -32600, message: "Invalid request.")
        }
        switch method {
        case "initialize":
            return AgentToolsMCP.result(id: id, AgentToolsMCP.initializeResult(requested: message["params"]?["protocolVersion"]?.stringValue))
        case "ping":
            return AgentToolsMCP.result(id: id, [:])
        case "tools/list":
            connection.listedTools = true
            return AgentToolsMCP.result(id: id, AgentToolsMCP.toolsList)
        case "tools/call":
            return await callTool(id: id, params: message["params"], target: connection.target, siteGrants: connection.siteGrants)
        default:
            return AgentToolsMCP.error(id: id, code: -32601,
                                       message: "Ensemble's agent tools answer only initialize, ping, tools/list and tools/call.")
        }
    }

    func callTool(id: JSONValue, params: JSONValue?, target: AgentToolsTarget?, siteGrants: Bool = false) async -> JSONValue {
        let name = params?["name"]?.stringValue ?? ""
        let host = state.withLock { $0.host }
        guard let target, let host else {
            return AgentToolsMCP.result(id: id, AgentToolResult.refused("Ensemble's agent tools are not running.").mcpValue)
        }
        guard let caller = await resolveCaller(target, meta: params?["_meta"], host: host, siteGrants: siteGrants) else {
            return AgentToolsMCP.result(id: id, AgentToolResult.refused("This call does not come from one of Ensemble's sessions.").mcpValue)
        }
        let shownName = AgentToolText.clean(name, limit: 60)
        let call: AgentToolCall
        do {
            call = try AgentToolCall.parse(name: name, arguments: params?["arguments"])
        } catch {
            await host.record(AgentToolsLogEntry(sessionID: caller.sessionID, tool: shownName.isEmpty ? "(no name)" : shownName,
                                                 summary: error == .unknownTool(name) ? "unknown tool" : "invalid arguments",
                                                 refused: true, outcome: error.message))
            if case .unknownTool = error {
                return AgentToolsMCP.error(id: id, code: -32602, message: error.message)
            }
            return AgentToolsMCP.result(id: id, AgentToolResult.refused(error.message).mcpValue)
        }
        guard admit(caller.sessionID) else {
            let text = "Too many Ensemble tool calls: at most \(limits.perMinute) a minute and \(limits.perSecond) a second. Wait before calling again."
            await host.record(AgentToolsLogEntry(sessionID: caller.sessionID, tool: name, summary: call.summary, refused: true, outcome: text))
            return AgentToolsMCP.result(id: id, AgentToolResult.refused(text).mcpValue)
        }
        let result = await host.handle(call, caller: caller)
        await host.record(AgentToolsLogEntry(sessionID: caller.sessionID, tool: name, summary: call.summary,
                                             refused: result.isError, outcome: result.text))
        return AgentToolsMCP.result(id: id, result.mcpValue)
    }

    /// The session a call belongs to. A session bridge always speaks for its own session. A folder bridge (OpenCode)
    /// speaks for the session OpenCode names in `_meta` only if that is an OpenCode session Ensemble prompted on this
    /// exact server in this folder (`allow(openCodeSession:on:)`), or a subagent of one; Claude and ACP sessions in the
    /// same folder, and OpenCode sessions on another server, are refused.
    func resolveCaller(_ target: AgentToolsTarget, meta: JSONValue?, host: any AgentToolsHost, siteGrants: Bool) async -> AgentToolsCaller? {
        switch target {
        case .session(let id):
            return AgentToolsCaller(sessionID: id, canUseSiteGrants: siteGrants)
        case .folder(let folder, let server):
            guard let sessionID = meta?["ai.opencode/sessionID"]?.stringValue, !sessionID.isEmpty, sessionID.count < 200 else { return nil }
            let allowed = state.withLock { $0.openCodeSessions[target] ?? [] }
            var known = allowed.contains(sessionID)
            if !known, let root = await host.rootSession(of: sessionID), root != sessionID { known = allowed.contains(root) }
            guard known, await host.session(sessionID, isIn: folder, server: server) else { return nil }
            return AgentToolsCaller(sessionID: sessionID, canUseSiteGrants: siteGrants)
        }
    }
}

/// One bridge's socket: reads happen on its own thread, writes from any task under a lock. `close()` only shuts the
/// socket down (which ends the reader); the reader's thread releases the descriptor with `release()`, so a descriptor
/// number is never reused while a read may still use it.
final class AgentToolsConnection: @unchecked Sendable {
    let fd: Int32
    private let maxInFlight: Int
    private let lock = NSLock()
    private var closed = false
    private var released = false
    private var proven: AgentToolsTarget?
    private var tasks: [JSONValue: Task<Void, Never>] = [:]
    private var inFlight = 0

    init(fd: Int32, maxInFlight: Int) {
        self.fd = fd
        self.maxInFlight = maxInFlight
    }

    var target: AgentToolsTarget? {
        get { lock.withLock { proven } }
        set { lock.withLock { proven = newValue } }
    }

    var isClosed: Bool { lock.withLock { closed } }

    private var peerInfo: AgentToolsPeer?
    private var exact = false
    /// The process on the other end, read when the connection was accepted.
    var peer: AgentToolsPeer? {
        get { lock.withLock { peerInfo } }
        set { lock.withLock { peerInfo = newValue } }
    }
    /// The key's binding is tied to one engine process (`AgentToolsBinding.isExact`).
    var siteGrants: Bool {
        get { lock.withLock { exact } }
        set { lock.withLock { exact = newValue } }
    }

    private var listed = false
    /// The engine has fetched the tool list on this connection.
    var listedTools: Bool {
        get { lock.withLock { listed } }
        set { lock.withLock { listed = newValue } }
    }

    enum StartResult {
        case started
        case duplicateID
        case tooManyInFlight
        case closed
    }

    /// Runs one request's work, unless closed, duplicate in-flight id, or too many are open already.
    func start(_ id: JSONValue, _ work: @escaping @Sendable () async -> Void) -> StartResult {
        lock.withLock {
            guard !closed else { return .closed }
            guard tasks[id] == nil else { return .duplicateID }
            guard inFlight < maxInFlight else { return .tooManyInFlight }
            inFlight += 1
            tasks[id] = Task { [weak self] in
                await work()
                self?.finish(id)
            }
            return .started
        }
    }

    private func finish(_ id: JSONValue) {
        lock.withLock {
            inFlight -= 1
            tasks[id] = nil
        }
    }

    func cancel(_ id: JSONValue) {
        let task = lock.withLock { tasks[id] }
        task?.cancel()
    }

    /// Writes one message as a line. Dropped once the connection is closed.
    func send(_ message: JSONValue) {
        var data = message.lineData
        if data.last != 10 { data.append(10) }
        lock.withLock {
            guard !closed else { return }
            #if canImport(Darwin)
            if !AgentToolsBridge.writeAll(fd, Array(data)) {
                closed = true
                Darwin.shutdown(fd, SHUT_RDWR)
            }
            #endif
        }
    }

    /// Shuts the socket down and cancels the calls still running on it (and the permission cards they wait on).
    func close() {
        let running: [Task<Void, Never>] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            #if canImport(Darwin)
            Darwin.shutdown(fd, SHUT_RDWR)
            #endif
            return Array(tasks.values)
        }
        for task in running { task.cancel() }
    }

    /// Closes the descriptor; called once by the thread that reads it, after its last read.
    func release() {
        close()
        lock.withLock {
            guard !released else { return }
            released = true
            #if canImport(Darwin)
            Darwin.close(fd)
            #endif
        }
    }
}
