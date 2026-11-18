#if os(macOS)
import Foundation
import Testing
@testable import EnsembleKit

/// Rewind with choices and session copies against the real local OpenCode service and the scripted mock model. Run
/// with `ENSEMBLE_LIVE_TESTS=1` (`scripts/test-live.sh`).
@Suite(.serialized, .enabled(if: LiveConfig.enabled))
struct RewindLiveTests {
    /// Two turns: the first writes a.txt, the second edits it and writes b.txt.
    static let rules: [JSONValue] = [
        ["match": ["rewind probe one"], "tool": ["name": "write", "arguments": ["path": "a.txt", "content": "one\ntwo\n"]],
         "then": "Wrote a."],
        ["match": ["rewind probe two"], "steps": [
            ["tool": ["name": "edit", "arguments": ["path": "a.txt", "oldString": "two", "newString": "TWO\nthree"]]],
            ["tool": ["name": "write", "arguments": ["path": "b.txt", "content": "bee\n"]]],
            ["text": "Changed a, wrote b."],
        ]],
    ]

    /// Adds the rules to the harness's mock script (the mock reloads it when it changes).
    static func addRules(_ h: LiveHarness) throws {
        let url = h.directory.appendingPathComponent(".mock-script.json")
        guard case .object(var script)? = JSONValue.parse(data: try Data(contentsOf: url)),
              case .array(let rules)? = script["rules"] else { throw LiveTimeout(what: "the mock script") }
        script["rules"] = .array(Self.rules + rules)
        try JSONValue.object(script).lineData.write(to: url)
        Thread.sleep(forTimeInterval: 0.3)
    }

    static func read(_ h: LiveHarness, _ name: String, in folder: String? = nil) -> String? {
        try? String(contentsOfFile: ((folder ?? h.path) as NSString).appendingPathComponent(name), encoding: .utf8)
    }

    static func userIDs(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .user(let id, _, _) = $0 { id } else { nil } }
    }

    @Test func codeAndConversationRestoresFilesAndRedoPutsThemBack() async throws {
        try await withHarness { h in
            try Self.addRules(h)
            let session = try await h.createSession(.acceptEdits)
            #expect(try await h.run(session.id, "rewind probe one") == "succeeded")
            #expect(try await h.run(session.id, "rewind probe two") == "succeeded")
            #expect(Self.read(h, "a.txt") == "one\nTWO\nthree\n")
            #expect(Self.read(h, "b.txt") == "bee\n")
            let users = Self.userIDs(try await h.client.transcript(session.id))
            #expect(users.count == 2)
            let second = try #require(users.last)

            let plan = try await h.client.rewindPlan(session.id, toBeforeMessageID: second)
            #expect(plan.messagesRemoved == 1)
            #expect(plan.files.sorted { $0.path < $1.path } == [
                FileChange(path: "a.txt", kind: .modified, additions: 1, deletions: 2),
                FileChange(path: "b.txt", kind: .deleted, additions: 0, deletions: 1),
            ])
            // Nothing changed yet.
            #expect(Self.read(h, "b.txt") == "bee\n")

            let outcome = try await h.client.rewind(session.id, toBeforeMessageID: second, scope: .codeAndConversation)
            #expect(outcome.files.sorted { $0.path < $1.path } == plan.files.sorted { $0.path < $1.path })
            #expect(Self.read(h, "a.txt") == "one\ntwo\n")
            #expect(Self.read(h, "b.txt") == nil)
            #expect(Self.userIDs(try await h.client.transcript(session.id)) == Array(users.prefix(1)))

            try await h.client.redoRewind(session.id)
            #expect(Self.read(h, "a.txt") == "one\nTWO\nthree\n")
            #expect(Self.read(h, "b.txt") == "bee\n")
            #expect(Self.userIDs(try await h.client.transcript(session.id)) == users)

            // Rewound again, the next message makes it final: the old turn is gone and the files stay put back.
            _ = try await h.client.rewind(session.id, toBeforeMessageID: second, scope: .codeAndConversation)
            #expect(try await h.run(session.id, "hello there") == "succeeded")
            let after = Self.userIDs(try await h.client.transcript(session.id))
            #expect(after.count == 2 && after.first == users.first && after.last != second)
            #expect(Self.read(h, "b.txt") == nil)
            await #expect(throws: OpenCodeError.self) { try await h.client.redoRewind(session.id) }
        }
    }

    @Test func conversationOnlyKeepsTheFiles() async throws {
        try await withHarness { h in
            try Self.addRules(h)
            let session = try await h.createSession(.acceptEdits)
            #expect(try await h.run(session.id, "rewind probe one") == "succeeded")
            #expect(try await h.run(session.id, "rewind probe two") == "succeeded")
            let users = Self.userIDs(try await h.client.transcript(session.id))
            let second = try #require(users.last)
            let outcome = try await h.client.rewind(session.id, toBeforeMessageID: second, scope: .conversationOnly)
            #expect(outcome.files.isEmpty)
            #expect(outcome.messagesRemoved == 1)
            #expect(Self.read(h, "a.txt") == "one\nTWO\nthree\n")
            #expect(Self.read(h, "b.txt") == "bee\n")
            #expect(Self.userIDs(try await h.client.transcript(session.id)) == Array(users.prefix(1)))
            try await h.client.redoRewind(session.id)
            #expect(Self.userIDs(try await h.client.transcript(session.id)) == users)
        }
    }

    /// A session in its own copy edits there in Auto without asking, and the project's own checkout is untouched.
    @Test func aSessionInACopyEditsTheCopyOnly() async throws {
        try await withHarness { h in
            try Self.addRules(h)
            try await h.git(["add", "-A"])
            try await h.git(["-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false",
                             "commit", "-q", "-m", "start"])
            let trust = WorkspaceTrust(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ens-trust-\(UUID().uuidString).json"),
                                       homeDirectory: "/nonexistent-home")
            try trust.trust(h.path)
            let git = SessionWorktreeGit(trust: trust)
            let record = try await git.create(home: h.path)
            defer { Task { try? await git.remove(record, force: true) } }
            let session = try await h.client.createSession(directory: record.sessionDirectory, model: ModelRef(providerID: "mock", id: "mock-1"),
                                                           agent: nil, permissionMode: .auto, parentID: nil)
            h.track(session.id)
            #expect(session.directory == record.sessionDirectory)
            let result = try await h.promptUntilAskOrEnd(session.id, "rewind probe one")
            #expect(result == .ended("succeeded"))
            #expect(Self.read(h, "a.txt", in: record.path) == "one\ntwo\n")
            #expect(Self.read(h, "a.txt") == nil)
            #expect(try await git.uncommittedChanges(record.path) == ["a.txt"])
            #expect(try await git.uncommittedChanges(h.path).isEmpty)
        }
    }
}
#endif
