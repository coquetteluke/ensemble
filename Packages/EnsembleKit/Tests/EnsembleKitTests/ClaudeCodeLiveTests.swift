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

    /// This run's own trust list, so the user's real one is never read or changed.
    lazy var trust = WorkspaceTrust(fileURL: folder.appendingPathComponent("trusted-folders.json"))

    func engine() -> ClaudeCodeEngine {
        let engine = ClaudeCodeEngine(configuration: .init(storeURL: store, trust: trust))
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

    /// A cloned repository's `.claude/settings.json` hook and `.mcp.json` server only run once its folder is trusted,
    /// and never in the command probe. Two haiku turns.
    @Test func projectSettingsRunOnlyInTrustedFolders() async throws {
        let harness = try ClaudeLiveHarness()
        defer { harness.finish() }
        let hookMarker = harness.folder.appendingPathComponent("hook-ran")
        let mcpMarker = harness.folder.appendingPathComponent("mcp-ran")
        let settings = harness.project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data("""
        {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "touch '\(hookMarker.path)'"}]}]}}
        """.utf8).write(to: settings.appendingPathComponent("settings.json"))
        try Data("""
        {"mcpServers": {"probe": {"command": "/bin/sh", "args": ["-c", "touch '\(mcpMarker.path)'; sleep 2"]}}}
        """.utf8).write(to: harness.project.appendingPathComponent(".mcp.json"))
        func ran(_ marker: URL) -> Bool { FileManager.default.fileExists(atPath: marker.path) }

        let engine = harness.engine()
        #expect(engine.ignoresProjectSettings(directory: harness.project.path))
        let session = try await engine.createSession(directory: harness.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        var mark = await harness.recorder.mark()
        try await engine.prompt(session.id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(session.id, after: mark) == "succeeded")
        #expect(!ran(hookMarker))
        #expect(!ran(mcpMarker))

        try harness.trust.trust(harness.project.path)
        #expect(!engine.ignoresProjectSettings(directory: harness.project.path))
        // The probe never loads a project's settings, even in a trusted folder.
        _ = try await engine.commands(directory: harness.project.path)
        #expect(!ran(hookMarker))
        #expect(!ran(mcpMarker))

        // The idle process restarts with the project's settings on the next prompt.
        mark = await harness.recorder.mark()
        try await engine.prompt(session.id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(session.id, after: mark) == "succeeded")
        #expect(ran(hookMarker))
        #expect(ran(mcpMarker))
        await engine.shutdown()
    }

    /// Confirmed project settings are pinned for the session: the CLI gets a private copy, so edits to the project's
    /// files while it runs do nothing (without the copy, the raw CLI picks them up on the next prompt). In a trusted
    /// folder the CLI reads itself, a base URL added mid-session is outranked by the pins, and a key the pins do not
    /// cover stops the process.
    /// Four haiku turns.
    @Test func confirmedSettingsArePinnedAndChangesAreWatched() async throws {
        let harness = try ClaudeLiveHarness()
        defer { harness.finish() }
        let marker = harness.folder.appendingPathComponent("pin")
        let lateMarker = harness.folder.appendingPathComponent("late-hook")
        func settings(pin: String, lateHook: Bool) -> String {
            var hooks = [#"{"type": "command", "command": "printf '%s\\n' \"$ENS_PIN\" >> '\#(marker.path)'"}"#]
            if lateHook { hooks.append(#"{"type": "command", "command": "touch '\#(lateMarker.path)'"}"#) }
            return #"{"env": {"ANTHROPIC_CUSTOM_HEADERS": "X-Ensemble-Probe: 1", "ENS_PIN": "\#(pin)"}, "#
                + #""hooks": {"UserPromptSubmit": [{"hooks": [\#(hooks.joined(separator: ", "))]}]}}"#
        }
        let dotClaude = harness.project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dotClaude, withIntermediateDirectories: true)
        try Data(settings(pin: "confirmed", lateHook: false).utf8).write(to: dotClaude.appendingPathComponent("settings.json"))
        try harness.trust.trust(harness.project.path)

        let engine = harness.engine()
        let session = try await engine.createSession(directory: harness.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        await #expect(throws: ClaudeCodeError.self) { try await engine.prompt(session.id, text: "Reply with exactly: ok", files: []) }
        try await engine.confirmProjectAPISettings(directory: harness.project.path)
        var mark = await harness.recorder.mark()
        try await engine.prompt(session.id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(session.id, after: mark) == "succeeded")
        func pins() -> [String] {
            ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        #expect(pins() == ["confirmed"])

        // Edit the project's settings while the process runs: a new value and a new hook. Neither takes effect.
        try Data(settings(pin: "changed", lateHook: true).utf8).write(to: dotClaude.appendingPathComponent("settings.json"))
        try await Task.sleep(for: .seconds(4))
        mark = await harness.recorder.mark()
        try await engine.prompt(session.id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(session.id, after: mark) == "succeeded")
        #expect(pins() == ["confirmed", "confirmed"])
        #expect(!FileManager.default.fileExists(atPath: lateMarker.path))
        // The next launch needs a new confirmation for the changed files.
        await engine.shutdown()
        await #expect(throws: ClaudeCodeError.self) { try await engine.prompt(session.id, text: "Reply with exactly: ok", files: []) }

        // A trusted folder with nothing to confirm: the CLI reads its files (so project commands, skills and agents
        // work), with the redirect-capable keys pinned by a command-line settings file, and the engine watches them.
        let clean = harness.folder.appendingPathComponent("clean")
        try FileManager.default.createDirectory(at: clean.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: clean.appendingPathComponent(".claude/settings.json"))
        try harness.trust.trust(clean.path)
        let watched = try await engine.createSession(directory: clean.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .ask, parentID: nil)
        mark = await harness.recorder.mark()
        try await engine.prompt(watched.id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(watched.id, after: mark) == "succeeded")
        mark = await harness.recorder.mark()
        // A fake base URL added while it runs (a closed local port, so nothing could leave the Mac). Without the pin the
        // CLI picks it up and the next turn stalls; with it, the process keeps going and the turn succeeds.
        let cleanSettings = clean.appendingPathComponent(".claude/settings.json")
        try Data(#"{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9"}}"#.utf8).write(to: cleanSettings)
        try await Task.sleep(for: .seconds(4))
        #expect(await !harness.recorder.events.dropFirst(mark).contains(.other(type: "claude.project_settings_changed")))
        try await engine.prompt(watched.id, text: "Reply with exactly: ok", files: [])
        #expect(try await harness.ended(watched.id, after: mark, timeout: 60) == "succeeded")
        // Something the pins do not cover stops the process at once, and the next launch asks.
        mark = await harness.recorder.mark()
        try Data(#"{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9"}, "apiKeyHelper": "./missing-helper.sh"}"#.utf8).write(to: cleanSettings)
        _ = try await harness.recorder.wait("the watcher", after: mark, timeout: 10) { $0 == .other(type: "claude.project_settings_changed") }
        await #expect(throws: ClaudeCodeError.projectOverridesAPISettings(directory: clean.path, keys: ["ANTHROPIC_BASE_URL", "apiKeyHelper"])) {
            try await engine.prompt(watched.id, text: "Reply with exactly: ok", files: [])
        }
        await engine.shutdown()
    }
}
#endif
