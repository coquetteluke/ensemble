#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Rewind with choices on the Claude engine against a stand-in `claude` that answers the stream-json control channel
/// like claude 2.1.319 does for `rewind_files` (its schema: `user_message_id`, `dry_run`; answer `canRewind`,
/// `filesChanged`, `insertions`, `deletions`). It records every frame it reads, so the tests check exactly which
/// requests Ensemble sends for each choice. No real CLI, login or model is used.
@Suite("Claude rewind with choices", .serialized)
struct RewindClaudeTests {
    typealias F = ClaudeFixtures
    /// The first (and only) prompt of `transcript-edit.jsonl`; the agent then edits notes.txt (alpha to beta).
    static let prompt = "c6da0560-0b2b-45ba-960b-6fc0878d0526"

    final class Rig: @unchecked Sendable {
        let box: ClaudeCodeEngineOfflineTests.Sandbox
        let script: URL
        let log: URL
        let notes: URL
        let engine: ClaudeCodeEngine

        init() throws {
            box = try ClaudeCodeEngineOfflineTests.Sandbox()
            script = box.folder.appendingPathComponent("fake-claude")
            log = box.folder.appendingPathComponent("frames.jsonl")
            notes = box.project.appendingPathComponent("notes.txt")
            try Data("beta\nsecond line\n".utf8).write(to: notes)
            let body = """
            #!/usr/bin/python3 -u
            import sys, json
            log = '\(log.path)'
            target = '\(notes.path)'
            while True:
                line = sys.stdin.readline()
                if not line:
                    break
                with open(log, 'a') as f:
                    f.write(line if line.endswith('\\n') else line + '\\n')
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                if msg.get('type') != 'control_request':
                    continue
                req = msg.get('request', {})
                resp = {}
                if req.get('subtype') == 'rewind_files':
                    if req.get('dry_run'):
                        resp = {'canRewind': True, 'filesChanged': [target], 'insertions': 1, 'deletions': 1}
                    else:
                        open(target, 'w').write('alpha\\nsecond line\\n')
                        resp = {'canRewind': True}
                out = {'type': 'control_response', 'response': {'subtype': 'success', 'request_id': msg.get('request_id'), 'response': resp}}
                sys.stdout.write(json.dumps(out) + '\\n')
                sys.stdout.flush()
            """
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            // The recorded edit session, moved into this sandbox's project folder.
            let folder = box.projects.appendingPathComponent("-sandbox-proj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let transcript = try Fixtures.text("claude-code/transcript-edit.jsonl")
                .replacingOccurrences(of: F.directory, with: box.project.path)
            try Data(transcript.utf8).write(to: folder.appendingPathComponent("\(F.root).jsonl"))
            let record = """
            {"version":1,"sessions":[{"id":"\(F.root)","title":"Edit","directory":"\(box.project.path)","permissionMode":"ask",
            "created":"2026-11-18T04:00:00Z","updated":"2026-11-18T04:10:00Z","started":true,
            "model":{"providerID":"claude-code","id":"haiku"}}]}
            """
            try Data(record.utf8).write(to: box.store)
            engine = ClaudeCodeEngine(configuration: .init(
                executablePath: script.path, storeURL: box.store, projectsDirectory: box.projects, fileCheckpointing: true,
                keychainService: "Ensemble test \(UUID().uuidString)",
                baseEnvironment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], trust: box.trust))
        }

        /// `rewind_files` requests the stand-in read, in order, as (dry run, prompt id).
        func rewindFrames() -> [(dryRun: Bool, prompt: String)] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                guard let json = JSONValue.parse(line: String(line)), json["type"]?.stringValue == "control_request",
                      json["request"]?["subtype"]?.stringValue == "rewind_files" else { return nil }
                return (json["request"]?["dry_run"]?.boolValue == true, json["request"]?["user_message_id"]?.stringValue ?? "")
            }
        }

        var notesText: String { (try? String(contentsOf: notes, encoding: .utf8)) ?? "<missing>" }

        func hasPrompt() async throws -> Bool {
            try await engine.transcript(F.root).contains { if case .user = $0 { true } else { false } }
        }
    }

    @Test func planAsksTheCLIForADryRunAndListsTheFile() async throws {
        let rig = try Rig()
        defer { Task { await rig.engine.shutdown() } }
        let plan = try await rig.engine.rewindPlan(F.root, toBeforeMessageID: Self.prompt)
        #expect(plan.files == [FileChange(path: "notes.txt", kind: .modified, additions: 1, deletions: 1)])
        #expect(plan.filesKnown)
        #expect(plan.filesNote == ClaudeCodeEngine.shellNote)
        #expect(plan.messagesRemoved == 1)
        #expect(plan.canRedo)
        #expect(plan.choices.filter(\.isAvailable).map(\.scope) == [.codeAndConversation, .conversationOnly, .codeOnly])
        #expect(plan.choice(.summarizeFromHere).unavailableReason == ClaudeFileRewindCheck.noSummary)
        let frames = rig.rewindFrames()
        #expect(frames.count == 1)
        #expect(frames.first?.dryRun == true)
        #expect(frames.first?.prompt == Self.prompt)
        #expect(rig.notesText == "beta\nsecond line\n")
    }

    @Test func codeAndConversationPutsTheFileBackAndRedoUndoesBoth() async throws {
        let rig = try Rig()
        defer { Task { await rig.engine.shutdown() } }
        let outcome = try await rig.engine.rewind(F.root, toBeforeMessageID: Self.prompt, scope: .codeAndConversation)
        #expect(outcome.files == [FileChange(path: "notes.txt", kind: .modified, additions: 1, deletions: 1)])
        #expect(outcome.messagesRemoved == 1)
        #expect(outcome.canRedo)
        #expect(rig.notesText == "alpha\nsecond line\n")
        #expect(try await !rig.hasPrompt())
        // A dry run first, then the real one, both for the removed prompt.
        let frames = rig.rewindFrames().filter { !$0.dryRun }
        #expect(frames.map(\.prompt) == [Self.prompt])
        #expect(rig.rewindFrames().first?.dryRun == true)

        try await rig.engine.redoRewind(F.root)
        #expect(rig.notesText == "beta\nsecond line\n")
        #expect(try await rig.hasPrompt())
        await #expect(throws: ClaudeCodeError.self) { try await rig.engine.redoRewind(F.root) }
    }

    @Test func conversationOnlyNeverTouchesFiles() async throws {
        let rig = try Rig()
        defer { Task { await rig.engine.shutdown() } }
        let outcome = try await rig.engine.rewind(F.root, toBeforeMessageID: Self.prompt, scope: .conversationOnly)
        #expect(outcome.files.isEmpty)
        #expect(outcome.messagesRemoved == 1)
        #expect(rig.rewindFrames().isEmpty)
        #expect(rig.notesText == "beta\nsecond line\n")
        #expect(try await !rig.hasPrompt())
        try await rig.engine.redoRewind(F.root)
        #expect(try await rig.hasPrompt())
    }

    @Test func codeOnlyKeepsTheConversation() async throws {
        let rig = try Rig()
        defer { Task { await rig.engine.shutdown() } }
        let outcome = try await rig.engine.rewind(F.root, toBeforeMessageID: Self.prompt, scope: .codeOnly)
        #expect(outcome.messagesRemoved == 0)
        #expect(outcome.files.map(\.path) == ["notes.txt"])
        #expect(rig.notesText == "alpha\nsecond line\n")
        #expect(try await rig.hasPrompt())
        try await rig.engine.redoRewind(F.root)
        #expect(rig.notesText == "beta\nsecond line\n")
        await #expect(throws: ClaudeCodeError.self) {
            _ = try await rig.engine.rewind(F.root, toBeforeMessageID: Self.prompt, scope: .summarizeFromHere)
        }
    }

    @Test func sendingAgainEndsRedo() async throws {
        let rig = try Rig()
        defer { Task { await rig.engine.shutdown() } }
        _ = try await rig.engine.rewind(F.root, toBeforeMessageID: Self.prompt, scope: .codeOnly)
        try await rig.engine.prompt(F.root, text: "carry on", files: [])
        await #expect(throws: ClaudeCodeError.self) { try await rig.engine.redoRewind(F.root) }
        #expect(rig.notesText == "alpha\nsecond line\n")
    }
}
/// The same against the real `claude` CLI on haiku with the user's own subscription: one short turn that edits a file,
/// then every rewind step (dry run, rewind, Redo) runs locally without another model call. Runs only with
/// `ENSEMBLE_LIVE_CLAUDE=1`.
@Suite("Claude rewind live", .serialized, .enabled(if: ClaudeLive.enabled))
struct RewindClaudeLiveTests {
    @Test func rewindsCodeAndConversationAndRedoes() async throws {
        let harness = try ClaudeLiveHarness()
        defer { harness.finish() }
        let engine = harness.engine()
        defer { Task { await engine.shutdown() } }
        let session = try await engine.createSession(directory: harness.project.path, model: ClaudeLive.haiku, agent: nil,
                                                     permissionMode: .acceptEdits, parentID: nil)
        let mark = await harness.recorder.mark()
        try await engine.prompt(session.id, text: "Use the Edit tool to change the word alpha to beta in notes.txt. Use no other tools. Then reply: done", files: [])
        #expect(try await harness.ended(session.id, after: mark) == "succeeded")
        #expect(harness.notes == "beta\nsecond line\n")
        let prompt = try #require(try await engine.transcript(session.id).compactMap { item -> String? in
            if case .user(let id, _, _) = item { return id }
            return nil
        }.first)

        let plan = try await engine.rewindPlan(session.id, toBeforeMessageID: prompt)
        #expect(plan.choice(.codeAndConversation).isAvailable)
        #expect(plan.files.map(\.path) == ["notes.txt"])
        #expect(plan.files.first?.kind == .modified)
        #expect(harness.notes == "beta\nsecond line\n")

        let outcome = try await engine.rewind(session.id, toBeforeMessageID: prompt, scope: .codeAndConversation)
        #expect(outcome.files.map(\.path) == ["notes.txt"])
        #expect(harness.notes == "alpha\nsecond line\n")
        #expect(try await engine.transcript(session.id).isEmpty)

        try await engine.redoRewind(session.id)
        #expect(harness.notes == "beta\nsecond line\n")
        #expect(try await engine.transcript(session.id).contains { if case .user = $0 { true } else { false } })

        let conversationOnly = try await engine.rewind(session.id, toBeforeMessageID: prompt, scope: .conversationOnly)
        #expect(conversationOnly.files.isEmpty)
        #expect(harness.notes == "beta\nsecond line\n")
    }
}
#endif
