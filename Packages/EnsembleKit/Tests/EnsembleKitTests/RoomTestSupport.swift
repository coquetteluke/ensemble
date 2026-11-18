import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// A scripted `OpenCodeAPI` for room tests.
///
/// It learns which agent owns a session from the room briefing (`[Room] You are <Name>, ...`). Every input
/// that wakes a session (`prompt`, or `injectSynthetic` with `wake: true`) starts an execution: the first
/// rule for that agent whose `contains` text is in the input picks the reply, and the fake emits
/// `activity(.working)`, two `textDelta`s, `textEnded`, `usageUpdated` and `executionEnded` through
/// `events()`. Inputs to a busy session queue, like the real service. `hold` rules stop after
/// `activity(.working)` (and their usage) until `release` or `interrupt`. Every call is recorded, with whether the
/// session was in an execution at the time. It also records `allowWorktreeEdits` calls (`EngineWorktreeAccess`).
final class FakeEngine: OpenCodeAPI, EngineWorktreeAccess, EngineFolderModels {
    struct Rule: Sendable {
        var agent: String
        var contains: String
        var reply: String
        var cost: Double
        var remaining: Int?
        var hold: Bool
        var textEvents: Bool
    }

    struct Sent: Sendable, Equatable, CustomStringConvertible {
        enum Channel: String, Sendable { case prompt, synthetic }
        var sessionID: String
        var agent: String?
        var channel: Channel
        var text: String
        var wake: Bool
        /// The session was in an execution when this arrived.
        var busy = false

        var description: String { "\(agent ?? sessionID) \(channel.rawValue)\(wake ? " wake" : "")\(busy ? " (busy)" : ""): \(text.prefix(80))" }
    }

    struct Created: Sendable, Equatable {
        var sessionID: String
        var directory: String
        var model: ModelRef?
        var permissionMode: PermissionMode
    }

    private struct State {
        var nextSession = 1
        var nextItem = 1
        var created: [Created] = []
        var agentBySession: [String: String] = [:]
        var rules: [Rule] = []
        var sent: [Sent] = []
        var unmatched: [String] = []
        var interrupts: [String] = []
        var renames: [String: String] = [:]
        var busy: Set<String> = []
        var queued: [String: [String]] = [:]
        var held: [String: Rule] = [:]
        var cost: [String: Double] = [:]
        var transcripts: [String: [TranscriptItem]] = [:]
        var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
        /// Per listener: events sent but not yet taken, and whether the last one taken is still being handled.
        var unhandled: [UUID: Int] = [:]
        var handling: Set<UUID> = []
        var changedFiles: [String: [String]] = [:]
        var worktreeGrants: [(sessionID: String, path: String, sentCount: Int)] = []
        var models: [ModelInfo] = []
        var modelDirectories: [String?] = []
        var sessionPrefix = "ses_"
        var defaultReply = "OK."

        func session(of agent: String) -> String? {
            agentBySession.first { $0.value.caseInsensitiveCompare(agent) == .orderedSame }?.key
        }

        mutating func takeRule(session: String, text: String) -> Rule {
            let agent = agentBySession[session] ?? ""
            if let i = rules.firstIndex(where: {
                $0.agent.caseInsensitiveCompare(agent) == .orderedSame
                    && ($0.contains.isEmpty || text.contains($0.contains))
                    && ($0.remaining ?? 1) > 0
            }) {
                let rule = rules[i]
                if let n = rules[i].remaining { rules[i].remaining = n - 1 }
                return rule
            }
            unmatched.append("\(agent): \(text.prefix(120))")
            return Rule(agent: agent, contains: "", reply: defaultReply, cost: 0, remaining: nil, hold: false, textEvents: true)
        }
    }

    private let state = Mutex(State())

    /// `sessionPrefix` keeps session ids apart when two fakes sit behind one engine router.
    init(sessionPrefix: String = "ses_", models: [ModelInfo] = []) {
        state.withLock {
            $0.sessionPrefix = sessionPrefix
            $0.models = models
        }
    }

    /// Folders `models(directory:)` was asked for.
    var modelDirectories: [String?] { state.withLock { $0.modelDirectories } }

    // MARK: Scripting

    /// Adds a reply rule. `times: nil` means unlimited. Rules are tried in the order they were added.
    func on(_ agent: String, _ contains: String = "", reply: String, cost: Double = 0.01, times: Int? = nil,
            hold: Bool = false, textEvents: Bool = true) {
        state.withLock {
            $0.rules.append(Rule(agent: agent, contains: contains, reply: reply, cost: cost, remaining: times,
                                 hold: hold, textEvents: textEvents))
        }
    }

    func setChangedFiles(_ agent: String, _ files: [String]) {
        state.withLock { $0.changedFiles[agent.lowercased()] = files }
    }

    /// Finishes a held execution with its rule's reply (or `reply`).
    func release(_ agent: String, reply: String? = nil) async {
        let found: (String, Rule)? = state.withLock { s in
            guard let sid = s.session(of: agent), let rule = s.held.removeValue(forKey: sid) else { return nil }
            return (sid, rule)
        }
        guard let (sid, rule) = found else { return }
        await finish(sid, reply: reply ?? rule.reply, textEvents: rule.textEvents, reportCost: false)
    }

    /// Sends a raw event to every listener.
    func emit(_ event: EngineEvent) {
        let continuations = state.withLock { s in
            for id in s.continuations.keys { s.unhandled[id, default: 0] += 1 }
            return Array(s.continuations.values)
        }
        for c in continuations { c.yield(event) }
    }

    // MARK: Inspecting

    var sent: [Sent] { state.withLock { $0.sent } }
    var created: [Created] { state.withLock { $0.created } }
    var interrupts: [String] { state.withLock { $0.interrupts } }
    var unmatched: [String] { state.withLock { $0.unmatched } }
    /// `allowWorktreeEdits` calls: agent, worktree path, and how many inputs had been sent before it.
    var worktreeGrants: [(agent: String?, path: String, sentCount: Int)] {
        state.withLock { s in s.worktreeGrants.map { (s.agentBySession[$0.sessionID], $0.path, $0.sentCount) } }
    }

    func sessionID(of agent: String) -> String? {
        state.withLock { $0.session(of: agent) }
    }

    func sent(to agent: String) -> [Sent] {
        sent.filter { $0.agent?.caseInsensitiveCompare(agent) == .orderedSame }
    }

    /// Inputs that woke the agent (prompts and wake synthetics).
    func wakes(to agent: String) -> [Sent] {
        sent(to: agent).filter(\.wake)
    }

    func isHeld(_ agent: String) -> Bool {
        state.withLock { s in s.session(of: agent).map { s.held[$0] != nil } ?? false }
    }

    func isBusy(_ agent: String) -> Bool {
        state.withLock { s in s.session(of: agent).map { s.busy.contains($0) } ?? false }
    }

    /// No turn is running or queued here, and every listener has handled every event sent so far: whatever a listener
    /// does in response has been done (a listener handles one event at a time and asks for the next when it is done).
    var isQuiet: Bool {
        state.withLock { s in
            s.busy.isEmpty && s.handling.isEmpty && s.unhandled.values.allSatisfy { $0 == 0 }
        }
    }

    // MARK: OpenCodeAPI

    func serverInfo() async throws -> (version: String, url: URL) {
        ("2.3.0", URL(string: "http://127.0.0.1:4096")!)
    }

    func listSessions() async throws -> [EngineSession] { [] }

    func createSession(directory: String, model: ModelRef?, agent: String?, permissionMode: PermissionMode,
                       parentID: String?) async throws -> EngineSession {
        let id: String = state.withLock { s in
            let id = "\(s.sessionPrefix)\(s.nextSession)"
            s.nextSession += 1
            s.created.append(Created(sessionID: id, directory: directory, model: model, permissionMode: permissionMode))
            return id
        }
        return EngineSession(id: id, title: "", directory: directory, model: model)
    }

    func deleteSession(_ sessionID: String) async throws {}

    func renameSession(_ sessionID: String, title: String) async throws {
        state.withLock { $0.renames[sessionID] = title }
    }

    func setArchived(_ sessionID: String, archived: Bool) async throws {}
    func setPermissionMode(_ sessionID: String, mode: PermissionMode) async throws {}
    func switchModel(_ sessionID: String, model: ModelRef) async throws {}

    func transcript(_ sessionID: String) async throws -> [TranscriptItem] {
        state.withLock { $0.transcripts[sessionID] ?? [] }
    }

    func children(_ sessionID: String) async throws -> [EngineSession] { [] }

    func prompt(_ sessionID: String, text: String, files: [URL]) async throws {
        record(sessionID, .prompt, text, wake: true)
        input(sessionID, text)
    }

    func injectSynthetic(_ sessionID: String, text: String, wake: Bool) async throws {
        record(sessionID, .synthetic, text, wake: wake)
        if wake {
            input(sessionID, text)
        } else {
            state.withLock { s in
                s.transcripts[sessionID, default: []].append(.notice(id: "n\(s.nextItem)", text: text))
                s.nextItem += 1
            }
        }
    }

    func interrupt(_ sessionID: String) async throws {
        let wasHeld: Bool = state.withLock { s in
            s.interrupts.append(sessionID)
            guard s.held.removeValue(forKey: sessionID) != nil else { return false }
            s.busy.remove(sessionID)
            s.queued[sessionID] = nil
            return true
        }
        if wasHeld { emit(.executionEnded(sessionID: sessionID, outcome: "interrupted", error: nil)) }
    }

    func replyPermission(sessionID: String, requestID: String, decision: PermissionDecision, message: String?) async throws {}
    func pendingPermissions() async throws -> [PermissionRequest] { [] }

    func allowWorktreeEdits(_ sessionID: String, worktreePath: String) async throws -> Bool {
        state.withLock { $0.worktreeGrants.append((sessionID, worktreePath, $0.sent.count)) }
        return true
    }

    func context(_ sessionID: String) async throws -> ContextBreakdown {
        ContextBreakdown(usedTokens: 0, limitTokens: 1, categories: [])
    }

    func changedFiles(_ sessionID: String) async throws -> [FileChange] {
        state.withLock { s in
            let agent = s.agentBySession[sessionID]?.lowercased() ?? ""
            return (s.changedFiles[agent] ?? []).map { FileChange(path: $0, kind: .modified) }
        }
    }

    func connectors() async throws -> [ConnectorInfo] { [] }
    func models() async throws -> [ModelInfo] { state.withLock { $0.models } }

    func models(directory: String?) async throws -> [ModelInfo] {
        state.withLock { s in
            s.modelDirectories.append(directory)
            return s.models
        }
    }
    func providers() async throws -> [ProviderInfo] { [] }
    func setAPIKey(providerID: String, key: String) async throws {}
    func removeAPIKey(providerID: String) async throws {}
    func schedules() async throws -> [ScheduleInfo] { [] }

    func createSchedule(title: String, prompt: String, directory: String, schedule: String, model: ModelRef?) async throws -> ScheduleInfo {
        ScheduleInfo(id: "sch_1", title: title, prompt: prompt, directory: directory, schedule: schedule)
    }

    func setSchedulePaused(_ scheduleID: String, paused: Bool) async throws {}
    func deleteSchedule(_ scheduleID: String) async throws {}

    func events() -> AsyncStream<EngineEvent> {
        let (inner, continuation) = AsyncStream<EngineEvent>.makeStream()
        let id = UUID()
        state.withLock {
            $0.continuations[id] = continuation
            $0.unhandled[id] = 0
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { s in
                s.continuations[id] = nil
                s.unhandled[id] = nil
                s.handling.remove(id)
            }
        }
        // The listener asks for the next event only after it has handled the previous one, so each request marks
        // the previous event as handled.
        let source = EventSource(inner)
        return AsyncStream(unfolding: { [weak self] in
            self?.state.withLock { _ = $0.handling.remove(id) }
            guard let event = await source.next() else { return nil }
            self?.state.withLock { s in
                guard let count = s.unhandled[id] else { return }
                s.unhandled[id] = count - 1
                s.handling.insert(id)
            }
            return event
        })
    }

    // MARK: Executions

    private func record(_ sessionID: String, _ channel: Sent.Channel, _ text: String, wake: Bool) {
        state.withLock { s in
            if text.hasPrefix("[Room] You are "), s.agentBySession[sessionID] == nil {
                let rest = text.dropFirst("[Room] You are ".count)
                if let comma = rest.firstIndex(of: ",") { s.agentBySession[sessionID] = String(rest[..<comma]) }
            }
            s.sent.append(Sent(sessionID: sessionID, agent: s.agentBySession[sessionID], channel: channel, text: text, wake: wake,
                               busy: s.busy.contains(sessionID)))
        }
    }

    private func input(_ sessionID: String, _ text: String) {
        let rule: Rule? = state.withLock { s in
            s.transcripts[sessionID, default: []].append(.user(id: "u\(s.nextItem)", text: text, date: Date()))
            s.nextItem += 1
            if s.busy.contains(sessionID) {
                s.queued[sessionID, default: []].append(text)
                return nil
            }
            s.busy.insert(sessionID)
            return s.takeRule(session: sessionID, text: text)
        }
        if let rule {
            Task { await self.execute(sessionID, rule) }
        }
    }

    private func execute(_ sessionID: String, _ rule: Rule) async {
        emit(.activity(sessionID: sessionID, .working))
        await Task.yield()
        let total: Double = state.withLock { s in
            s.cost[sessionID, default: 0] += rule.cost
            if rule.hold { s.held[sessionID] = rule }
            return s.cost[sessionID] ?? 0
        }
        if rule.hold {
            if rule.cost > 0 { emit(.usageUpdated(sessionID: sessionID, Usage(outputTokens: 10, costUSD: total))) }
            return
        }
        await finish(sessionID, reply: rule.reply, textEvents: rule.textEvents, reportCost: rule.cost > 0)
    }

    private func finish(_ sessionID: String, reply: String, textEvents: Bool, reportCost: Bool) async {
        let (item, total): (String, Double) = state.withLock { s in
            s.nextItem += 1
            return ("t\(s.nextItem)", s.cost[sessionID] ?? 0)
        }
        if textEvents && !reply.isEmpty {
            let mid = reply.index(reply.startIndex, offsetBy: reply.count / 2)
            emit(.textDelta(sessionID: sessionID, itemID: item, delta: String(reply[..<mid])))
            await Task.yield()
            emit(.textDelta(sessionID: sessionID, itemID: item, delta: String(reply[mid...])))
            emit(.textEnded(sessionID: sessionID, itemID: item, text: reply))
        }
        let next: Rule? = state.withLock { s in
            s.transcripts[sessionID, default: []].append(.agentText(id: item, text: reply, agentID: nil, streaming: false))
            s.busy.remove(sessionID)
            guard var queue = s.queued[sessionID], !queue.isEmpty else { return nil }
            let text = queue.removeFirst()
            s.queued[sessionID] = queue
            s.busy.insert(sessionID)
            return s.takeRule(session: sessionID, text: text)
        }
        if reportCost { emit(.usageUpdated(sessionID: sessionID, Usage(outputTokens: 10, costUSD: total))) }
        emit(.executionEnded(sessionID: sessionID, outcome: "succeeded", error: nil))
        if let next { await execute(sessionID, next) }
    }
}

/// The fake's own event stream, read by one listener at a time.
private final class EventSource: @unchecked Sendable {
    private var iterator: AsyncStream<EngineEvent>.Iterator

    init(_ stream: AsyncStream<EngineEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> EngineEvent? {
        var it = iterator
        let event = await it.next()
        iterator = it
        return event
    }
}

/// `GitOps` that records calls. Worktrees are `<repo>/.ensemble/worktrees/<branch>`.
final class FakeGitOps: GitOps {
    struct Merge: Sendable, Equatable {
        var branch: String
        var base: String
    }

    private struct State {
        var isRepository = true
        var base = "main"
        var worktrees: [String] = []
        var merges: [Merge] = []
        var commits: [String] = []
        var conflictsOnce: [String: [String]] = [:]
    }

    private let state = Mutex(State())

    init(isRepository: Bool = true, base: String = "main") {
        state.withLock {
            $0.isRepository = isRepository
            $0.base = base
        }
    }

    /// The first merge of `branch` stops with conflicts in `files`.
    func conflictOnce(branch: String, files: [String]) {
        state.withLock { $0.conflictsOnce[branch] = files }
    }

    var worktrees: [String] { state.withLock { $0.worktrees } }
    var merges: [Merge] { state.withLock { $0.merges } }
    var commits: [String] { state.withLock { $0.commits } }

    func isRepository(_ directory: String) async -> Bool { state.withLock { $0.isRepository } }

    func currentBranch(repo: String) async throws -> String { state.withLock { $0.base } }

    func createWorktree(repo: String, branch: String) async throws -> String {
        state.withLock { $0.worktrees.append(branch) }
        return "\(repo)/.ensemble/worktrees/\(branch.replacingOccurrences(of: "/", with: "-"))"
    }

    func changedFiles(worktree: String, base: String) async throws -> [String] {
        ["\((worktree as NSString).lastPathComponent).txt"]
    }

    func commitAll(worktree: String, message: String) async throws -> Bool {
        state.withLock { $0.commits.append(worktree) }
        return true
    }

    func merge(branch: String, into base: String, repo: String) async throws -> GitMergeResult {
        state.withLock { s in
            s.merges.append(Merge(branch: branch, base: base))
            if let files = s.conflictsOnce.removeValue(forKey: branch) {
                return GitMergeResult(merged: false, conflicts: files, message: "CONFLICT")
            }
            return GitMergeResult(merged: true)
        }
    }
}

// MARK: - Helpers

enum RoomFixtures {
    static func agents(_ names: [String], caps: [String: Double] = [:]) -> [AgentSpec] {
        names.map { name in
            AgentSpec(name: name, model: ModelRef(providerID: "mock", id: name.lowercased()), role: "\(name) role",
                      colorHex: "#888888", spendingCapUSD: caps[name])
        }
    }

    static func spec(_ mode: RoomMode, _ names: [String], lead: Int? = 0, permission: PermissionMode = .auto,
                     rounds: Int = 3, caps: [String: Double] = [:], directory: String = "/tmp/ensemble-room-test") -> RoomSpec {
        let list = agents(names, caps: caps)
        return RoomSpec(title: "Test Room", directory: directory, agents: list, mode: mode,
                        leadAgentID: lead.map { list[$0].id }, permissionMode: permission, debateRounds: rounds)
    }

    @MainActor
    static func engine(_ spec: RoomSpec, fake: FakeEngine, store: InMemoryRoomStore = InMemoryRoomStore(),
                       git: (any GitOps)? = nil) async throws -> RoomEngine {
        try await RoomEngine.create(spec: spec, api: fake, store: store, git: git)
    }
}

extension RoomEngine {
    func id(of name: String) -> UUID {
        agents.first { $0.name == name }!.id
    }

    var boardDump: String {
        state.board.map { m in
            let from: String
            switch m.from {
            case .agent(let id): from = agent(id)?.name ?? "?"
            case .user: from = "user"
            case .room: from = "room"
            }
            let to = m.to.isEmpty ? "" : " -> " + m.to.map { agent($0)?.name ?? "?" }.joined(separator: ",")
            return "[\(m.kind.rawValue)\(m.round.map { " r\($0)" } ?? "")] \(from)\(to): \(m.text)"
        }.joined(separator: "\n")
    }

    /// Waits until `condition` holds (see `waitUntil`), or fails with the board and phase.
    func waitFor(_ what: String, timeout: Duration = TestWait.ceiling, fake: FakeEngine? = nil,
                 sourceLocation: SourceLocation = #_sourceLocation, _ condition: (RoomEngine) -> Bool) async throws {
        try await waitUntil(what, timeout: timeout, sourceLocation: sourceLocation, details: {
            let extra = fake.map { "\nUnmatched inputs:\n" + $0.unmatched.joined(separator: "\n") } ?? ""
            return "Phase: \(state.phase), paused: \(state.isPaused), decision: \(String(describing: state.pendingDecision))\nBoard:\n\(boardDump)\(extra)"
        }) {
            condition(self)
        }
    }

    /// Waits until no turn runs and the room has handled every event the fake sent: whatever the room does in
    /// response to what has happened so far has happened. Messages may still wait in outboxes (for a paused room or an
    /// agent whose subagents work).
    func waitForQuiet(fake: FakeEngine, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitFor("the room to go quiet", fake: fake, sourceLocation: sourceLocation) { engine in
            engine.busy.isEmpty && fake.isQuiet
        }
    }

    /// Quiet, and nothing waits in an outbox: the room has settled.
    func waitForSettled(fake: FakeEngine, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitFor("the room to settle", fake: fake, sourceLocation: sourceLocation) { engine in
            engine.busy.isEmpty && engine.state.outbox.values.allSatisfy(\.isEmpty) && fake.isQuiet
        }
    }

    func messages(from name: String) -> [BoardMessage] {
        let id = id(of: name)
        return state.board.filter { $0.from == .agent(id) }
    }

    var notices: [String] {
        state.board.filter { $0.kind == .notice }.map(\.text)
    }
}
