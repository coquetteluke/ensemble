#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// End to end through `ClaudeCodeEngine` with the real `claude` CLI on the user's own subscription, on haiku, in a
/// temporary folder. Runs only with `ENSEMBLE_LIVE_CLAUDE=1` and uses about a dozen short haiku turns.
enum ClaudeLive {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ENSEMBLE_LIVE_CLAUDE"] == "1" }
    static let haiku = ModelRef(providerID: ClaudeModels.subscriptionProviderID, id: "haiku")
}

struct ClaudeLiveTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

actor ClaudeLiveRecorder {
    private(set) var events: [EngineEvent] = []
    func append(_ event: EngineEvent) { events.append(event) }
    func mark() -> Int { events.count }

    func wait(_ what: String, after mark: Int, timeout: Double = 120,
              _ predicate: @escaping @Sendable (EngineEvent) -> Bool) async throws -> EngineEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = events.dropFirst(mark).first(where: predicate) { return match }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClaudeLiveTimeout(what: what)
    }

    func texts(after mark: Int, session: String) -> [String] {
        events.dropFirst(mark).compactMap { if case .textEnded(session, _, let text) = $0 { text } else { nil } }
    }
}

final class ClaudeLiveHarness: @unchecked Sendable {
    let folder: URL
    let project: URL
    let store: URL
    let recorder = ClaudeLiveRecorder()
    private var tasks: [Task<Void, Never>] = []

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ens-claude-live-\(UUID().uuidString.prefix(8))")
        project = folder.appendingPathComponent("proj")
        store = folder.appendingPathComponent("claude-sessions.json")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "alpha\nsecond line\n".write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }

    func engine() -> ClaudeCodeEngine {
        let engine = ClaudeCodeEngine(configuration: .init(storeURL: store))
        let stream = engine.events()
        let recorder = recorder
        tasks.append(Task { for await event in stream { await recorder.append(event) } })
        return engine
    }

    var notes: String { (try? String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8)) ?? "" }

    func finish() {
        for task in tasks { task.cancel() }
        try? FileManager.default.removeItem(at: folder)
    }

    func ended(_ session: String, after mark: Int, timeout: Double = 180) async throws -> String {
        let event = try await recorder.wait("turn end", after: mark, timeout: timeout) {
            if case .executionEnded(session, _, _) = $0 { true } else { false }
        }
        guard case .executionEnded(_, let outcome, _) = event else { return "" }
        return outcome
    }
}

@Suite("Claude Code live", .serialized, .enabled(if: ClaudeLive.enabled))
struct ClaudeCodeLiveTests {
    @Test func promptPermissionsResumeInterruptForkRewind() async throws {
        let harness = try ClaudeLiveHarness()
        defer { harness.finish() }
        var engine = harness.engine()

        let auth = await engine.authState(refresh: true)
        #expect(auth.installed)
        #expect(auth.loggedIn)
        let info = try await engine.serverInfo()
        #expect(info.version.hasPrefix("2."))
        #expect(try await engine.models().contains { $0.ref.id == "haiku" && $0.available })

        let session = try await engine.createSession(directory: harness.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        let id = session.id

        // 1. Prompt and stream.
        var mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Reply with exactly: pong", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        #expect(await harness.recorder.texts(after: mark, session: id).joined().contains("pong"))
        let deltas = await harness.recorder.events.dropFirst(mark).contains { if case .textDelta(id, _, _) = $0 { true } else { false } }
        #expect(deltas)
        let usage = await harness.recorder.events.dropFirst(mark).contains { if case .usageUpdated(id, let u) = $0 { u.outputTokens > 0 } else { false } }
        #expect(usage)
        let context = try await engine.context(id)
        #expect(context.usedTokens > 0)
        #expect(!context.categories.isEmpty)

        // 2. A permission prompt answered once.
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Read notes.txt, then use the Edit tool to change the word alpha to beta in it. Use no other tools. Then reply: done", files: [])
        let asked = try await harness.recorder.wait("permission", after: mark) { if case .permissionAsked = $0 { true } else { false } }
        guard case .permissionAsked(let request) = asked else { return }
        #expect(request.kind == "edit")
        #expect(request.sessionID == id)
        #expect(try await engine.pendingPermissions().map(\.id) == [request.id])
        try await engine.replyPermission(sessionID: id, requestID: request.id, decision: .once, message: nil)
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        #expect(harness.notes.hasPrefix("beta"))
        let changes = try await engine.changedFiles(id)
        #expect(changes.first?.path == "notes.txt")

        // 3. A permission prompt rejected.
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Use the Edit tool to change the word beta to gamma in notes.txt. If the edit is rejected, do not retry; reply: rejected", files: [])
        let second = try await harness.recorder.wait("permission", after: mark) { if case .permissionAsked = $0 { true } else { false } }
        guard case .permissionAsked(let rejectRequest) = second else { return }
        try await engine.replyPermission(sessionID: id, requestID: rejectRequest.id, decision: .reject, message: nil)
        _ = try await harness.ended(id, after: mark)
        #expect(harness.notes.hasPrefix("beta"))

        // 3b. "Always" on a command: Ensemble remembers the rule (the CLI is not told) and answers the repeat itself.
        try await engine.setEffort(id, effort: .low)
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Use the Bash tool to run exactly: touch made.txt . Then run exactly the same command again as a second, separate Bash call. Use no other tools. Then reply: done", files: [])
        let third = try await harness.recorder.wait("permission", after: mark) { if case .permissionAsked = $0 { true } else { false } }
        guard case .permissionAsked(let alwaysRequest) = third else { return }
        #expect(alwaysRequest.kind == "bash")
        #expect(alwaysRequest.title == "touch made.txt")
        try await engine.replyPermission(sessionID: id, requestID: alwaysRequest.id, decision: .always, message: nil)
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        let asks = await harness.recorder.events.dropFirst(mark).filter { if case .permissionAsked = $0 { true } else { false } }
        #expect(asks.count == 1)
        let bashRuns = await harness.recorder.events.dropFirst(mark).compactMap { event -> String? in
            if case .toolUpdated(id, let tool) = event, tool.name == "Bash", tool.status == .succeeded { tool.id } else { nil }
        }
        #expect(Set(bashRuns).count == 2)
        #expect(FileManager.default.fileExists(atPath: harness.project.appendingPathComponent("made.txt").path))

        // 4. Resume after restart: a new engine on the same session list.
        await engine.shutdown()
        try await Task.sleep(for: .seconds(2))
        engine = harness.engine()
        let reloaded = try await engine.transcript(id)
        #expect(reloaded.contains { if case .user(_, "Reply with exactly: pong", _) = $0 { true } else { false } })
        #expect(reloaded.contains { if case .tool(let tool) = $0 { tool.name == "Edit" && tool.diff != nil } else { false } })
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "What single word did I first ask you to reply with? Answer with just that word.", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        #expect(await harness.recorder.texts(after: mark, session: id).joined().lowercased().contains("pong"))

        // 5. Interrupt without ending the session, then keep talking in the same process.
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Write the numbers from 1 to 300 as words, one per line, no other text.", files: [])
        _ = try await harness.recorder.wait("text", after: mark) { if case .textDelta(id, _, _) = $0 { true } else { false } }
        try await engine.interrupt(id)
        #expect(try await harness.ended(id, after: mark, timeout: 30) == "interrupted")
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Reply with exactly: still here", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        #expect(await harness.recorder.texts(after: mark, session: id).joined().contains("still here"))

        // 6. Fork at the first reply: the fork only knows the history up to there.
        let items = try await engine.transcript(id)
        let firstReply = try #require(items.first { if case .agentText(_, let text, _, _) = $0 { text.contains("pong") } else { false } })
        let fork = try await engine.fork(id, atMessageID: firstReply.id)
        mark = await harness.recorder.mark()
        try await engine.prompt(fork.id, text: "Repeat exactly the last reply you gave before this message, nothing else.", files: [])
        #expect(try await harness.ended(fork.id, after: mark) == "succeeded")
        let forkText = await harness.recorder.texts(after: mark, session: fork.id).joined().lowercased()
        #expect(forkText.contains("pong"))
        #expect(!forkText.contains("still here"))

        // 7. Rewind to before the last prompt; the next turn continues from there.
        let lastPrompt = try #require(items.last { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })
        try await engine.rewind(id, toBeforeMessageID: lastPrompt.id)
        let rewound = try await engine.transcript(id)
        #expect(!rewound.contains { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Reply with exactly: rewound", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        let after = try await engine.transcript(id)
        #expect(after.contains { if case .user(_, "Reply with exactly: rewound", _) = $0 { true } else { false } })
        #expect(!after.contains { if case .user(_, "Reply with exactly: still here", _) = $0 { true } else { false } })

        // 8. Rewind restores files: an edit in Accept edits mode (switched live), then a rewind to before its prompt.
        try await engine.setPermissionMode(id, mode: .acceptEdits)
        mark = await harness.recorder.mark()
        try await engine.prompt(id, text: "Use the Edit tool to change the word beta to delta in notes.txt (read it first). Then reply: done", files: [])
        #expect(try await harness.ended(id, after: mark) == "succeeded")
        #expect(harness.notes.hasPrefix("delta"))
        let beforeEdit = try await engine.transcript(id)
        let editPrompt = try #require(beforeEdit.last { if case .user(_, let text, _) = $0 { text.contains("beta to delta") } else { false } })
        try await engine.rewind(id, toBeforeMessageID: editPrompt.id)
        #expect(harness.notes.hasPrefix("beta"))
        #expect(try await engine.changedFiles(id).allSatisfy { !($0.diff ?? "").contains("+delta") })

        // 9. Commands from the CLI (no tokens).
        let commands = try await engine.commands(directory: harness.project.path)
        #expect(commands.contains { $0.name == "compact" })
        #expect(!commands.contains { $0.name == "clear" })

        await engine.shutdown()
        if let limits = await engine.planLimits() { #expect(!limits.status.isEmpty) }
    }
}
#endif
