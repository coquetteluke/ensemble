#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Whole rooms against the real local OpenCode service and the mock model with `tools/mock-llm/rooms/room-script.json`.
/// Run only with `ENSEMBLE_LIVE_TESTS=1`. Each test works in a fresh temporary git repository with its own
/// `opencode.json`, and deletes the sessions it creates.
enum RoomLiveConfig {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_TESTS"] == "1" }

    static var repoRoot: URL {
        if let root = ProcessInfo.processInfo.environment["ENSEMBLE_REPO_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static let mockModel = ModelRef(providerID: "mock", id: "mock-1")
}

struct RoomLiveFailure: Error, CustomStringConvertible {
    let description: String
}

/// Temporary git repo + mock model + client for one room test.
final class RoomLiveHarness: @unchecked Sendable {
    let directory: URL
    let client: OpenCodeClient
    let mockLog: URL
    private let mock: Process
    private let lock = NSLock()
    private var sessions: [String] = []

    var path: String { directory.path }

    private init(directory: URL, client: OpenCodeClient, mock: Process, mockLog: URL) {
        self.directory = directory
        self.client = client
        self.mock = mock
        self.mockLog = mockLog
    }

    static func start(script: String = "tools/mock-llm/rooms/room-script.json") async throws -> RoomLiveHarness {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("ensemble-room-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let root = RoomLiveConfig.repoRoot
        let portFile = directory.appendingPathComponent(".mock-port")
        let log = directory.appendingPathComponent(".mock-requests.jsonl")
        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        mock.arguments = [root.appendingPathComponent("tools/mock-llm/mock_llm.py").path, "--port", "0", "--port-file", portFile.path,
                          "--script", root.appendingPathComponent(script).path, "--log", log.path]
        mock.standardOutput = FileHandle.nullDevice
        mock.standardError = FileHandle.nullDevice
        try mock.run()
        var port: String?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), !text.isEmpty { port = text; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let port else {
            mock.terminate()
            throw RoomLiveFailure(description: "The mock model did not start")
        }
        let template = try String(contentsOf: root.appendingPathComponent("tools/mock-llm/opencode.json.example"), encoding: .utf8)
        try template.replacingOccurrences(of: "PORT", with: port)
            .write(to: directory.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        try "opencode.json\n.mock-port\n.mock-requests.jsonl\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "# Mock project\n".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: directory.path)
        try git(["add", "-A"], in: directory.path)
        try git(["-c", "user.name=Ensemble Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "Start"], in: directory.path)

        let client = try OpenCodeClient.fromServiceFile(defaultDirectory: directory.path)
        return RoomLiveHarness(directory: directory, client: client, mock: mock, mockLog: log)
    }

    func track(_ ids: some Sequence<String>) {
        lock.withLock { sessions.append(contentsOf: ids) }
    }

    func cleanup() async {
        let ids = lock.withLock { sessions }
        for id in ids.reversed() { try? await client.deleteSession(id) }
        mock.terminate()
        // `waitUntilExit()` can block a cooperative thread for good after a pause test (seen with OpenCode 2.3 and
        // the slow pause script), so poll instead and give up after three seconds.
        for _ in 0..<30 where mock.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if mock.isRunning { kill(mock.processIdentifier, SIGKILL) }
        if ProcessInfo.processInfo.environment["ENSEMBLE_KEEP_ROOM_DIR"] == "1" {
            print("Kept \(directory.path)")
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The newest user message of every request the mock received, in order (for failure messages).
    func mockPrompts() -> [String] {
        guard let text = try? String(contentsOf: mockLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = object["body"] as? [String: Any], body["tools"] != nil,
                  let messages = body["messages"] as? [[String: Any]],
                  let user = messages.last(where: { $0["role"] as? String == "user" }) else { return nil }
            if let content = user["content"] as? String { return String(content.prefix(160)) }
            if let parts = user["content"] as? [[String: Any]] {
                return String(parts.compactMap { $0["text"] as? String }.joined(separator: " ").prefix(160))
            }
            return nil
        }
    }

    @discardableResult
    static func git(_ args: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw RoomLiveFailure(description: "git \(args.joined(separator: " ")) failed: \(output)")
        }
        return output
    }

    func git(_ args: [String]) throws -> String { try Self.git(args, in: path) }
}

@MainActor
func withRoomHarness(script: String = "tools/mock-llm/rooms/room-script.json",
                     _ body: (RoomLiveHarness) async throws -> Void) async throws {
    let harness = try await RoomLiveHarness.start(script: script)
    do {
        try await body(harness)
    } catch {
        await harness.cleanup()
        throw error
    }
    await harness.cleanup()
}

/// Polls `condition` on the main actor until it holds. The room engine runs on the main actor, so sleeping here
/// lets it handle events.
@MainActor
func waitForRoom(_ what: String, timeout: Double, engine: RoomEngine, harness: RoomLiveHarness,
                 _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    let board = engine.state.board.map { message -> String in
        let from: String
        switch message.from {
        case .agent(let id): from = engine.agent(id)?.name ?? "agent"
        case .user: from = "user"
        case .room: from = "room"
        }
        return "  [\(message.kind.rawValue)] \(from): \(message.text.prefix(140))"
    }.joined(separator: "\n")
    let prompts = harness.mockPrompts().map { "  > \($0)" }.joined(separator: "\n")
    throw RoomLiveFailure(description: """
        Timed out waiting for \(what). Phase \(engine.state.phase.rawValue), paused \(engine.state.isPaused) \
        (\(engine.state.pauseReason ?? "")), error \(engine.lastError ?? "none"), duties \(engine.state.duties.mapValues { $0.map(\.purpose) })
        Board:
        \(board)
        Mock prompts:
        \(prompts)
        """)
}

/// Runs until `done` holds, answering every permission prompt from the room's sessions with Allow once (as the
/// room view's card does). Returns the prompts it answered.
@MainActor
func runAnsweringPrompts(_ what: String, timeout: Double, engine: RoomEngine, harness: RoomLiveHarness,
                         until done: () -> Bool) async throws -> [PermissionRequest] {
    let roomSessions = Set(engine.state.sessions.values)
    var answered: [PermissionRequest] = []
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline {
        let pending = try await harness.client.pendingPermissions().filter { roomSessions.contains($0.sessionID) }
        for request in pending where !answered.contains(where: { $0.id == request.id }) {
            if let agentID = engine.state.sessions.first(where: { $0.value == request.sessionID })?.key {
                #expect(engine.activity[agentID] == .waitingForPermission)
            }
            try await harness.client.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: .once, message: nil)
            answered.append(request)
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    try await waitForRoom(what, timeout: 1, engine: engine, harness: harness, done)
    return answered
}

/// Notices the room posts when an agent ignored the room format and the engine fell back or had to ask again.
@MainActor
func fallbackNotices(_ engine: RoomEngine) -> [String] {
    engine.state.board.filter { $0.from == .room }.map(\.text).filter {
        $0.contains("did not") || $0.contains("gave no argument") || $0.contains("passed its turn")
            || $0.contains("no usable ASSIGN") || $0.contains("sent no summary") || $0.contains("empty build update")
    }
}

/// Prints the board and the mock's prompts when `ENSEMBLE_ROOM_DEBUG=1`.
@MainActor
func dumpRoom(_ engine: RoomEngine, _ harness: RoomLiveHarness) {
    guard ProcessInfo.processInfo.environment["ENSEMBLE_ROOM_DEBUG"] == "1" else { return }
    for message in engine.state.board {
        let from: String
        switch message.from {
        case .agent(let id): from = engine.agent(id)?.name ?? "agent"
        case .user: from = "user"
        case .room: from = "room"
        }
        let to = message.to.compactMap { engine.agent($0)?.name }.joined(separator: ",")
        print("BOARD [\(message.kind.rawValue)] \(from)\(to.isEmpty ? "" : " -> \(to)"): \(message.text.replacingOccurrences(of: "\n", with: " | "))")
    }
    for prompt in harness.mockPrompts() { print("MOCK > \(prompt.replacingOccurrences(of: "\n", with: " | "))") }
}

@Suite(.serialized, .enabled(if: RoomLiveConfig.enabled))
@MainActor
struct RoomLiveTests {
    private func agents() -> (AgentSpec, AgentSpec) {
        (AgentSpec(name: "Ada", model: RoomLiveConfig.mockModel, role: "Argues for files", colorHex: "#A78BFA"),
         AgentSpec(name: "Byron", model: RoomLiveConfig.mockModel, role: "Argues for a server", colorHex: "#34D399"))
    }

    @Test func debateReachesAVerdict() async throws {
        try await withRoomHarness { h in
            let (ada, byron) = agents()
            let spec = RoomSpec(title: "Mock Debate", directory: h.path, agents: [ada, byron], mode: .debate,
                                leadAgentID: ada.id, permissionMode: .auto, debateRounds: 2)
            let store = InMemoryRoomStore()
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: store, git: ProcessGitOps.trustingEverything)
            defer { engine.close() }
            h.track(engine.state.sessions.values)
            #expect(engine.state.sessions.count == 2)

            await engine.start(task: "Should rooms be saved as JSON files or in a database?")
            try await waitForRoom("the verdict", timeout: 120, engine: engine, harness: h) { engine.state.phase == .verdict }

            let debate = try #require(engine.state.debate)
            #expect(debate.arguments.count == 4)
            #expect(Set(debate.arguments(inRound: 1).map(\.agentID)) == [ada.id, byron.id])
            #expect(Set(debate.arguments(inRound: 2).map(\.agentID)) == [ada.id, byron.id])
            #expect(debate.arguments(inRound: 1).allSatisfy { $0.text.contains("JSON file per room is simplest") })
            #expect(debate.arguments(inRound: 2).allSatisfy { $0.text.contains("I read the other argument") })
            #expect(debate.verdict?.hasPrefix("Keep one plain JSON file per room.") == true)

            let board = engine.state.board
            #expect(board.first?.from == .user)
            #expect(board.filter { $0.kind == .argument }.count == 4)
            #expect(board.filter { $0.kind == .argument && $0.round == 2 }.count == 2)
            let verdict = try #require(board.last { $0.kind == .verdict })
            #expect(verdict.from == .agent(ada.id))
            #expect(verdict.text.contains("VERDICT:"))
            #expect(engine.state.pendingDecision == nil)
            #expect(engine.lastError == nil)
            #expect(fallbackNotices(engine).isEmpty, "\(fallbackNotices(engine))")
            dumpRoom(engine, h)
            #expect(store.saveCount > 0)
            let saved = try #require(try store.load(spec.id))
            #expect(saved.phase == .verdict)
        }
    }

    @Test func teamBuildsReviewsAndMergesInGitWorktrees() async throws {
        try await withRoomHarness { h in
            let (adaBase, byronBase) = agents()
            var ada = adaBase
            ada.role = "Leads and writes ada.txt"
            var byron = byronBase
            byron.role = "Writes byron.txt"
            let spec = RoomSpec(title: "Mock Team", directory: h.path, agents: [ada, byron], mode: .team,
                                leadAgentID: ada.id, permissionMode: .auto)
            let store = InMemoryRoomStore()
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: store, git: ProcessGitOps.trustingEverything)
            defer { engine.close() }
            h.track(engine.state.sessions.values)

            await engine.start(task: "Each agent writes one greeting file.")
            let prompts = try await runAnsweringPrompts("the team to finish", timeout: 180, engine: engine, harness: h) {
                engine.state.phase == .finished
            }
            // Each agent's session allows edits in its own worktree (`PermissionRules.worktreeEditRules`), so in Auto
            // nobody's own work asks.
            #expect(prompts.isEmpty, "\(prompts.map(\.title))")

            // Plan and assignments.
            let state = engine.state
            #expect(state.git == GitContext(isRepository: true, baseBranch: "main"))
            #expect(state.assignments.map(\.agentID) == [ada.id, byron.id])
            #expect(state.assignments.allSatisfy { $0.status == .merged })
            #expect(state.assignments.first { $0.agentID == ada.id }?.reviewerID == byron.id)
            #expect(state.assignments.first { $0.agentID == byron.id }?.reviewerID == ada.id)
            #expect(state.assignments.first { $0.agentID == ada.id }?.branch == engine.expectedBranch("Ada", roomSlug: "mock-team"))
            #expect(state.assignments.first { $0.agentID == ada.id }?.changedFiles == ["ada.txt"])
            #expect(state.assignments.first { $0.agentID == byron.id }?.changedFiles == ["byron.txt"])

            // Board: plan, assignments, updates, reviews, merges, summary.
            let board = state.board
            #expect(board.contains { $0.kind == .plan && $0.from == .agent(ada.id) && $0.text.contains("ASSIGN @Byron") })
            #expect(board.filter { $0.kind == .assignment }.map(\.to) == [[ada.id], [byron.id]])
            #expect(board.filter { $0.kind == .review }.count == 2)
            #expect(board.filter { $0.kind == .review }.allSatisfy { $0.text.contains("APPROVE") })
            #expect(board.contains { $0.from == .room && $0.text == "Merged \(engine.expectedBranch("Ada", roomSlug: "mock-team")) into main." })
            #expect(board.contains { $0.from == .room && $0.text == "Merged \(engine.expectedBranch("Byron", roomSlug: "mock-team")) into main." })
            #expect(board.last { $0.from == .agent(ada.id) }?.text.hasPrefix("Summary:") == true)
            // Messages for a busy agent's information wait until its turn ends (`RoomState.held`). Before, OpenCode read
            // them inside the running turn and the agent answered there, so a review gained the mock's "OK." reply.
            let expected = "I read the change and it does what the assignment asks.\nAPPROVE"
            #expect(board.filter { $0.kind == .review }.allSatisfy { $0.text == expected },
                    "\(board.filter { $0.kind == .review }.map(\.text))")
            #expect(state.held.isEmpty)

            // Branches, worktrees and the merged files on main.
            let branches = try h.git(["branch", "--list", "ensemble/*"])
            #expect(branches.contains(engine.expectedBranch("Ada", roomSlug: "mock-team")))
            #expect(branches.contains(engine.expectedBranch("Byron", roomSlug: "mock-team")))
            #expect(try h.git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) == "main")
            #expect(try String(contentsOfFile: h.path + "/ada.txt", encoding: .utf8) == "Hello from Ada\n")
            #expect(try String(contentsOfFile: h.path + "/byron.txt", encoding: .utf8) == "Hello from Byron\n")
            let log = try h.git(["log", "--format=%s", "main"])
            #expect(log.contains("Merge \(engine.expectedBranch("Ada", roomSlug: "mock-team"))"))
            #expect(log.contains("Merge \(engine.expectedBranch("Byron", roomSlug: "mock-team"))"))
            #expect(try h.git(["status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(engine.lastError == nil)
            #expect(fallbackNotices(engine).isEmpty, "\(fallbackNotices(engine))")
            dumpRoom(engine, h)
        }
    }

    @Test func teamInAskModeWaitsForThePlanAndPermissions() async throws {
        try await withRoomHarness { h in
            let (ada, byron) = agents()
            let spec = RoomSpec(title: "Mock Team", directory: h.path, agents: [ada, byron], mode: .team,
                                leadAgentID: ada.id, permissionMode: .ask)
            let store = InMemoryRoomStore()
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: store, git: ProcessGitOps.trustingEverything)
            defer { engine.close() }
            h.track(engine.state.sessions.values)
            let roomSessions = Set(engine.state.sessions.values)

            await engine.start(task: "Each agent writes one greeting file.")
            try await waitForRoom("the plan to wait for approval", timeout: 60, engine: engine, harness: h) {
                engine.state.pendingDecision == .approvePlan
            }
            #expect(engine.state.phase == .awaitingApproval)
            #expect(engine.state.assignments.count == 2)
            #expect(engine.state.needsUser)
            await engine.approvePlan()

            // In Ask mode every write asks. Answer each prompt the way the room view does, until the run ends.
            let answered = try await runAnsweringPrompts("the team to finish", timeout: 180, engine: engine, harness: h) {
                engine.state.phase == .finished
            }
            #expect(answered.count == 2)
            #expect(answered.allSatisfy { $0.kind == "edit" })
            #expect(Set(answered.map(\.sessionID)) == roomSessions)
            #expect(engine.state.assignments.allSatisfy { $0.status == .merged })
            #expect(try String(contentsOfFile: h.path + "/ada.txt", encoding: .utf8) == "Hello from Ada\n")
            #expect(try String(contentsOfFile: h.path + "/byron.txt", encoding: .utf8) == "Hello from Byron\n")
            #expect(fallbackNotices(engine).isEmpty, "\(fallbackNotices(engine))")
            dumpRoom(engine, h)
        }
    }
    @Test func pauseInterruptsAndResumeContinuesTheDebate() async throws {
        try await withRoomHarness(script: "tools/mock-llm/rooms/pause-script.json") { h in
            let (ada, byron) = agents()
            let spec = RoomSpec(title: "Mock Pause", directory: h.path, agents: [ada, byron], mode: .debate,
                                leadAgentID: ada.id, permissionMode: .auto, debateRounds: 1)
            let store = InMemoryRoomStore()
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: store, git: ProcessGitOps.trustingEverything)
            defer { engine.close() }
            h.track(engine.state.sessions.values)

            await engine.start(task: "Should rooms be saved as JSON files or in a database?")
            try await waitForRoom("both agents to stream", timeout: 30, engine: engine, harness: h) {
                !(engine.liveText[ada.id] ?? "").isEmpty && !(engine.liveText[byron.id] ?? "").isEmpty
            }
            await engine.pause()
            #expect(engine.state.isPaused)
            #expect(Set(engine.state.interruptedAgents) == [ada.id, byron.id])
            try await waitForRoom("both turns to stop", timeout: 30, engine: engine, harness: h) {
                engine.activity[ada.id] == .idle && engine.activity[byron.id] == .idle
            }
            // Interrupted turns post nothing, and the round still waits for both arguments.
            #expect(engine.state.board.filter { $0.kind == .argument }.isEmpty)
            #expect(engine.state.debate?.arguments.isEmpty == true)
            #expect(engine.state.phase == .debating)

            await engine.resume()
            #expect(!engine.state.isPaused)
            try await waitForRoom("the verdict after resuming", timeout: 60, engine: engine, harness: h) { engine.state.phase == .verdict }
            let arguments = engine.state.debate?.arguments ?? []
            #expect(arguments.count == 2)
            #expect(arguments.allSatisfy { $0.text.hasPrefix("After the pause") })
            #expect(engine.state.debate?.verdict?.hasPrefix("Keep one plain JSON file per room.") == true)
            #expect(engine.state.board.contains { $0.from == .room && $0.text == "Paused." })
            #expect(engine.state.board.contains { $0.from == .room && $0.text == "Resumed." })
            #expect(fallbackNotices(engine).isEmpty, "\(fallbackNotices(engine))")
            dumpRoom(engine, h)
        }
    }

    /// Auto lets each Team agent edit its own worktree without asking, but a real `.git/config` edit and an edit in
    /// another agent's worktree still ask.
    @Test func teamAgentInAutoEditsOnlyItsOwnWorktreeWithoutAsking() async throws {
        try await withRoomHarness { h in
            let (ada, byron) = agents()
            let spec = RoomSpec(title: "Mock Team", directory: h.path, agents: [ada, byron], mode: .team,
                                leadAgentID: ada.id, permissionMode: .auto)
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: InMemoryRoomStore(), git: ProcessGitOps.trustingEverything)
            defer { engine.close() }
            h.track(engine.state.sessions.values)

            await engine.start(task: "Each agent writes one greeting file.")
            let prompts = try await runAnsweringPrompts("the team to finish", timeout: 180, engine: engine, harness: h) {
                engine.state.phase == .finished
            }
            #expect(prompts.isEmpty, "\(prompts.map(\.title))")
            #expect(try String(contentsOfFile: h.path + "/byron.txt", encoding: .utf8) == "Hello from Byron\n")
            let byronSession = try #require(engine.sessionID(for: byron.id))
            let rules = try await h.client.permissionRules(byronSession)
            #expect(PermissionRules.mode(for: rules) == .auto)
            #expect(PermissionRules.worktree(in: rules) == ".ensemble/worktrees/" + engine.expectedWorktreeFolder("Byron", roomSlug: "mock-team"))

            // The same agent, same session: a real dot path asks, and so does another agent's worktree.
            let config = h.path + "/.git/config"
            let configBefore = try String(contentsOfFile: config, encoding: .utf8)
            for (marker, path) in [("git config marker", ".git/config"),
                                   ("other worktree marker", ".ensemble/worktrees/ensemble-mock-team-ada/byron.txt")] {
                await engine.send("@Byron \(marker): please do it")
                var asked: PermissionRequest?
                let deadline = Date().addingTimeInterval(60)
                while asked == nil && Date() < deadline {
                    asked = try await h.client.pendingPermissions().first { $0.sessionID == byronSession }
                    if asked == nil { try await Task.sleep(for: .milliseconds(200)) }
                }
                let request = try #require(asked, "no prompt for \(path)")
                #expect(request.kind == "edit")
                #expect(request.title.contains(path), "\(request.title)")
                try await h.client.replyPermission(sessionID: byronSession, requestID: request.id, decision: .reject, message: nil)
                try await waitForRoom("Byron's turn to end", timeout: 60, engine: engine, harness: h) {
                    engine.activity[byron.id] == .idle
                }
            }
            #expect(try String(contentsOfFile: config, encoding: .utf8) == configBefore)
            #expect(!FileManager.default.fileExists(atPath: h.path + "/.ensemble/worktrees/ensemble-mock-team-ada/byron.txt"))
            dumpRoom(engine, h)
        }
    }

    /// Byron's work starts a background subagent, so his turn ends at once without DONE. The room waits for the
    /// subagent (which writes byron.txt in Byron's worktree without asking, under his rules), holds Ada's review
    /// request for Byron, and takes DONE from the turn the subagent's result starts. No format nudge goes out.
    @Test func teamWaitsForABackgroundSubagent() async throws {
        try await withRoomHarness(script: "tools/mock-llm/rooms/subagent-script.json") { h in
            let (ada, byron) = agents()
            let spec = RoomSpec(title: "Mock Team", directory: h.path, agents: [ada, byron], mode: .team,
                                leadAgentID: ada.id, permissionMode: .auto)
            let engine = try await RoomEngine.create(spec: spec, api: h.client, store: InMemoryRoomStore(), git: ProcessGitOps.trustingEverything)
            defer { engine.close() }
            h.track(engine.state.sessions.values)

            await engine.start(task: "Each agent writes one greeting file.")
            try await waitForRoom("Byron's subagent to start", timeout: 60, engine: engine, harness: h) {
                engine.hasWorkingSubagents(byron.id)
            }
            let prompts = try await runAnsweringPrompts("the team to finish", timeout: 180, engine: engine, harness: h) {
                engine.state.phase == .finished
            }
            h.track(try await h.client.children(try #require(engine.sessionID(for: byron.id))).map(\.id))
            #expect(prompts.isEmpty, "\(prompts.map(\.title))")
            let mockPrompts = h.mockPrompts()
            #expect(!mockPrompts.contains { $0.contains("Reply DONE on its own line") }, "\(mockPrompts)")
            #expect(fallbackNotices(engine).isEmpty, "\(fallbackNotices(engine))")
            let state = engine.state
            #expect(state.assignments.allSatisfy { $0.status == .merged })
            #expect(state.assignments.first { $0.agentID == byron.id }?.changedFiles == ["byron.txt"])
            #expect(engine.messages(from: "Byron").contains { $0.text.hasPrefix("My helper wrote byron.txt") })
            #expect(try String(contentsOfFile: h.path + "/byron.txt", encoding: .utf8) == "Hello from Byron's helper\n")
            #expect(engine.workingSubagents.isEmpty)
            dumpRoom(engine, h)
        }
    }
}
#endif
